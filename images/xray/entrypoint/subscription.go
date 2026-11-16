package main

// {"$subscription": path} and the loop that keeps it current: the outbounds
// of an Xray config a URL serves, as an app's "custom config" subscription
// does, fetched at start and again every XRAY_SUBSCRIPTION_INTERVAL, with Xray
// restarted on the result when it changed and `xray run -test` passes it.

import (
	"bytes"
	"encoding/json"
	"errors"
	"fmt"
	"io"
	"maps"
	"net/http"
	"net/url"
	"os"
	"os/exec"
	"os/signal"
	"path/filepath"
	"slices"
	"syscall"
	"time"

	"github.com/morzecrew/platform-images/shared/go/envconf"
)

const (
	subTimeout = 30 * time.Second // one fetch, the body included
	subMax     = 4 << 20          // the most a subscription may serve
	subRetry   = 30 * time.Second // between fetches while one has given nothing yet
	subStop    = 10 * time.Second // for Xray to exit before it is killed
)

// What each subscription holds now, by the path of the file naming its URL:
// the outbounds array of the last good fetch (or of the cache), nil while
// there is none. The resolver reads it when set, and fetches only when not,
// which is at start.
var subs = map[string][]byte{}

// The keys whose values are an outbound's structure, shown in Xray's
// messages; every other string a subscription's outbounds hold is redacted.
var subPlain = map[string]bool{"protocol": true, "network": true, "security": true, "flow": true,
	"fingerprint": true, "mode": true, "tag": true, "type": true}

// subscription resolves {"$subscription": path}: the outbounds array of the
// Xray config the http or https URL in that file serves. A fetch that fails at
// start falls back to the copy in XRAY_SUBSCRIPTION_CACHE, and with none the
// array is empty, so Xray starts on the rest of the config alone. Its errors
// never show the URL: its path is the credential.
func subscription(name string) (envconf.Resolution, error) {
	u, err := subscriptionURL(name)
	if err != nil {
		return envconf.Resolution{}, err
	}
	body, seen := subs[name]
	if !seen {
		if body, err = fetch(u, nil); err != nil {
			fmt.Fprintf(os.Stderr, "subscription: %s: %v\n", name, err)
			if body = readCache(name); body != nil {
				fmt.Fprintf(os.Stderr, "subscription: %s: starting on the copy in XRAY_SUBSCRIPTION_CACHE\n", name)
			}
		}
		subs[name] = body
	}
	if body == nil {
		return envconf.Resolution{Value: []any{}, Secrets: []string{u}, Note: "no outbounds yet"}, nil
	}
	var outs []any
	if err := json.Unmarshal(body, &outs); err != nil {
		return envconf.Resolution{}, fmt.Errorf("holds no outbounds array: %v", err)
	}
	return envconf.Resolution{Value: outs, Secrets: append(secretsOf(outs, ""), u),
		Note: fmt.Sprintf("%d outbound(s)", len(outs))}, nil
}

func subscriptionURL(name string) (string, error) {
	s, err := envconf.ReadSecret(name)
	if err != nil {
		return "", err
	}
	u, err := url.Parse(s)
	if err != nil || (u.Scheme != "http" && u.Scheme != "https") || u.Host == "" {
		return "", errors.New("does not hold an http or https URL")
	}
	return s, nil
}

// fetch GETs the URL, through proxy when it is set, and returns the outbounds
// array of the config it serves, re-encoded, so two fetches of one config
// compare equal.
func fetch(u string, proxy *url.URL) ([]byte, error) {
	tr := &http.Transport{Proxy: nil, ForceAttemptHTTP2: true}
	if proxy != nil {
		tr.Proxy = http.ProxyURL(proxy)
	}
	defer tr.CloseIdleConnections()
	req, err := http.NewRequest(http.MethodGet, u, nil)
	if err != nil {
		return nil, errors.New("does not hold a URL Go can request")
	}
	req.Header.Set("Accept", "application/json")
	resp, err := (&http.Client{Transport: tr, Timeout: subTimeout}).Do(req)
	if err != nil {
		// A *url.Error quotes the URL.
		var ue *url.Error
		if errors.As(err, &ue) {
			err = ue.Err
		}
		return nil, fmt.Errorf("could not be fetched (%v)", err)
	}
	defer resp.Body.Close()
	if resp.StatusCode != http.StatusOK {
		return nil, fmt.Errorf("answered %s", resp.Status)
	}
	b, err := io.ReadAll(io.LimitReader(resp.Body, subMax+1))
	switch {
	case err != nil:
		return nil, fmt.Errorf("could not be read (%v)", err)
	case len(b) > subMax:
		return nil, fmt.Errorf("serves more than %d bytes", subMax)
	}
	return outbounds(b)
}

// outbounds takes the "outbounds" of an Xray config: at least one, each an
// object with a protocol.
func outbounds(b []byte) ([]byte, error) {
	var c struct {
		Outbounds []map[string]any `json:"outbounds"`
	}
	if err := json.Unmarshal(b, &c); err != nil {
		return nil, errors.New("serves no Xray config: it is not a JSON object with an outbounds array")
	}
	if len(c.Outbounds) == 0 {
		return nil, errors.New("serves an Xray config with no outbounds")
	}
	for i, o := range c.Outbounds {
		if p, _ := o["protocol"].(string); p == "" {
			return nil, fmt.Errorf("serves an Xray config whose outbound %d has no protocol", i+1)
		}
	}
	return json.Marshal(c.Outbounds)
}

// secretsOf lists every string in v but those under a subPlain key.
func secretsOf(v any, key string) []string {
	var out []string
	switch v := v.(type) {
	case map[string]any:
		for _, k := range slices.Sorted(maps.Keys(v)) {
			out = append(out, secretsOf(v[k], k)...)
		}
	case []any:
		for _, e := range v {
			out = append(out, secretsOf(e, key)...)
		}
	case string:
		if !subPlain[key] && len(v) >= 4 {
			out = append(out, v)
		}
	}
	return out
}

// The cache keeps each subscription's last outbounds Xray accepted, as
// <file name>.json in XRAY_SUBSCRIPTION_CACHE, for a start while the URL is
// unreachable. Unset, there is none.
func cacheFile(name string) string {
	dir := img.Get("XRAY_SUBSCRIPTION_CACHE")
	if dir == "" {
		return ""
	}
	return filepath.Join(dir, filepath.Base(name)+".json")
}

func readCache(name string) []byte {
	p := cacheFile(name)
	if p == "" {
		return nil
	}
	b, err := os.ReadFile(p)
	if err != nil {
		return nil
	}
	b, err = outbounds(append(append([]byte(`{"outbounds":`), b...), '}'))
	if err != nil {
		fmt.Fprintf(os.Stderr, "subscription: %s: the copy in XRAY_SUBSCRIPTION_CACHE is not used: it %v\n", name, err)
		return nil
	}
	return b
}

// writeCaches keeps every subscription that holds outbounds. A failure is
// told and not fatal: the cache only helps a later start.
func writeCaches() {
	for name, b := range subs {
		p := cacheFile(name)
		if p == "" || b == nil {
			continue
		}
		err := func() error {
			f, err := os.CreateTemp(filepath.Dir(p), ".subscription-*")
			if err != nil {
				return err
			}
			defer os.Remove(f.Name())
			if _, err := f.Write(b); err != nil {
				f.Close()
				return err
			}
			if err := f.Close(); err != nil {
				return err
			}
			return os.Rename(f.Name(), p)
		}()
		if err != nil {
			fmt.Fprintf(os.Stderr, "subscription: %s: XRAY_SUBSCRIPTION_CACHE could not be written (%v)\n", name, envconf.Cause(err))
		}
	}
}

// The loop's settings, checked before anything is fetched.
type subSettings struct {
	interval time.Duration
	proxy    *url.URL // nil: fetched directly
}

func subscriptionSettings() (subSettings, error) {
	var s subSettings
	d, err := time.ParseDuration(img.Get("XRAY_SUBSCRIPTION_INTERVAL"))
	if err != nil || d < time.Second {
		return s, errors.New("XRAY_SUBSCRIPTION_INTERVAL is not a Go duration of 1s or more, such as 1h")
	}
	s.interval = d
	if p := img.Get("XRAY_SUBSCRIPTION_PROXY"); p != "" {
		u, err := url.Parse(p)
		if err != nil || u.Host == "" || !slices.Contains([]string{"socks5", "socks5h", "http"}, u.Scheme) {
			return s, errors.New("XRAY_SUBSCRIPTION_PROXY is not a socks5://, socks5h:// or http:// URL with a host and port")
		}
		// The environment shows in docker inspect.
		if u.User != nil {
			return s, errors.New("XRAY_SUBSCRIPTION_PROXY holds a login, which the environment would show: point it at an inbound that asks for none")
		}
		s.proxy = u
	}
	return s, nil
}

// supervise runs Xray on the runtime directory and, every interval (subRetry
// while a subscription holds nothing), fetches each subscription again:
// through XRAY_SUBSCRIPTION_PROXY first when set, directly when that fails.
// When one changed, the whole source is resolved again and tested in a
// directory beside the running config; Xray restarts on it only if it passes,
// and the cache is written only then. A signal goes on to Xray, and Xray's own
// exit ends the container with its status.
func supervise(src, run string, extra []string, s subSettings) error {
	sigs := make(chan os.Signal, 1)
	signal.Notify(sigs, syscall.SIGTERM, syscall.SIGINT)
	cmd, done, err := launch(run, extra)
	if err != nil {
		return err
	}
	timer := time.NewTimer(next(s))
	for {
		select {
		case sig := <-sigs:
			_ = cmd.Process.Signal(sig)
			<-done
			os.Exit(0)
		case err := <-done:
			fmt.Fprintf(os.Stderr, "xray-entrypoint: Xray exited (%v)\n", err)
			os.Exit(cmd.ProcessState.ExitCode())
		case <-timer.C:
			if refresh(src, run, extra, s) {
				stop(cmd, done)
				if cmd, done, err = launch(run, extra); err != nil {
					return err
				}
			}
			timer.Reset(next(s))
		}
	}
}

func next(s subSettings) time.Duration {
	for _, b := range subs {
		if b == nil {
			return min(subRetry, s.interval)
		}
	}
	return s.interval
}

// refresh fetches every subscription and reports whether Xray is to restart:
// one changed, and the runtime directory now holds the config resolved on it,
// which `xray run -test` passed.
func refresh(src, run string, extra []string, s subSettings) bool {
	old := maps.Clone(subs)
	changed := false
	for _, name := range slices.Sorted(maps.Keys(subs)) {
		u, err := subscriptionURL(name)
		if err != nil {
			fmt.Fprintf(os.Stderr, "subscription: %s %v\n", name, err)
			continue
		}
		var b []byte
		if s.proxy != nil {
			if b, err = fetch(u, s.proxy); err != nil {
				fmt.Fprintf(os.Stderr, "subscription: %s: through XRAY_SUBSCRIPTION_PROXY: %v\n", name, err)
			}
		}
		if b == nil {
			if b, err = fetch(u, nil); err != nil {
				fmt.Fprintf(os.Stderr, "subscription: %s: %v; Xray keeps what it has\n", name, err)
				continue
			}
		}
		if !bytes.Equal(b, subs[name]) {
			subs[name], changed = b, true
		}
	}
	if !changed {
		return false
	}
	revert := func(err error) bool {
		fmt.Fprintf(os.Stderr, "subscription: %v; Xray keeps the config it runs\n", err)
		subs = old
		return false
	}
	configs, err := resolveDir(src)
	if err != nil {
		return revert(err)
	}
	stage, err := os.MkdirTemp(run, ".next-")
	if err != nil {
		return revert(fmt.Errorf("XRAY_RUNTIME_DIR is not writable (%v)", envconf.Cause(err)))
	}
	defer os.RemoveAll(stage)
	if err := writeRuntime(stage, configs); err != nil {
		return revert(err)
	}
	if _, err := testConfig(stage, extra, configs); err != nil {
		return revert(err)
	}
	if err := writeRuntime(run, configs); err != nil {
		return revert(err)
	}
	writeCaches()
	for _, c := range configs {
		for _, r := range c.Refs {
			if r.Kind == "$subscription" {
				fmt.Fprintf(os.Stderr, "subscription: %s: %s; restarting Xray on it\n", r.File, r.Note)
			}
		}
	}
	return true
}

func launch(run string, extra []string) (*exec.Cmd, chan error, error) {
	cmd := exec.Command(img.Bin, append([]string{"run", "-confdir", run}, extra...)...)
	cmd.Stdout, cmd.Stderr = os.Stdout, os.Stderr
	if err := cmd.Start(); err != nil {
		return nil, nil, fmt.Errorf("Xray could not be started (%v)", err)
	}
	done := make(chan error, 1)
	go func() { done <- cmd.Wait() }()
	return cmd, done, nil
}

func stop(cmd *exec.Cmd, done chan error) {
	_ = cmd.Process.Signal(syscall.SIGTERM)
	select {
	case <-done:
	case <-time.After(subStop):
		_ = cmd.Process.Kill()
		<-done
	}
}
