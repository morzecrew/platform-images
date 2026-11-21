package main

// {"$subscription": path} and the loop that keeps it current: the outbounds
// of an Xray config a URL serves, as an app's "custom config" subscription
// does, fetched at start and again every XRAY_SUBSCRIPTION_INTERVAL, with Xray
// restarted on the result when it changed and `xray run -test` passes it.

import (
	"bytes"
	"context"
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
	"strings"
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

// XRAY_SUBSCRIPTION_PROXY, set by start before anything is resolved, so the
// first fetch goes the way every later one does.
var subProxy *url.URL

// When the subscriptions are next fetched: the refresh runs every 30 seconds
// while a geodata file waits (geodata.go), and they keep their own interval.
var subsDue time.Time

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
	if p := cacheFile(name); p != "" {
		for other := range subs {
			if other != name && cacheFile(other) == p {
				return envconf.Resolution{}, fmt.Errorf("has the file name of %s, and XRAY_SUBSCRIPTION_CACHE keeps one copy per file name: rename one of them", other)
			}
		}
	}
	body, seen := subs[name]
	if !seen {
		if body, err = get(name, u, subProxy); err != nil {
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

// get fetches through proxy first when it is set, and directly when that
// fails.
func get(name, u string, proxy *url.URL) ([]byte, error) {
	if proxy != nil {
		b, err := fetch(u, proxy)
		if err == nil {
			return b, nil
		}
		fmt.Fprintf(os.Stderr, "subscription: %s: through XRAY_SUBSCRIPTION_PROXY: %v\n", name, err)
	}
	return fetch(u, nil)
}

// fetch GETs the URL, through proxy when it is set, and returns the outbounds
// array of the config it serves, re-encoded, so two fetches of one config
// compare equal. One round trip, no redirect followed: an http.Client's
// errors quote the URL, and a Location header it cannot parse, whatever that
// holds. What else a server or proxy can put in an error, a reason phrase or
// a malformed response quoted back, is left out or scrubbed of the URL's
// path, the credential.
func fetch(u string, proxy *url.URL) (_ []byte, err error) {
	tr := &http.Transport{Proxy: nil, ForceAttemptHTTP2: true}
	if proxy != nil {
		tr.Proxy = http.ProxyURL(proxy)
	}
	defer tr.CloseIdleConnections()
	ctx, cancel := context.WithTimeout(context.Background(), subTimeout)
	defer cancel()
	req, err := http.NewRequestWithContext(ctx, http.MethodGet, u, nil)
	if err != nil {
		return nil, errors.New("does not hold a URL Go can request")
	}
	req.Header.Set("Accept", "application/json")
	// Each part of the path and query, as sent and decoded, whichever of them
	// holds the credential and however much of it an error quotes.
	parts := strings.FieldsFunc(req.URL.EscapedPath()+"/"+req.URL.Path+"?"+req.URL.RawQuery,
		func(r rune) bool { return strings.ContainsRune("/?&=", r) })
	slices.SortFunc(parts, func(a, b string) int { return len(b) - len(a) }) // a part inside another goes after it
	defer func() {
		if err == nil {
			return
		}
		msg := err.Error()
		for _, p := range parts {
			if len(p) >= 4 {
				msg = strings.ReplaceAll(msg, p, "…")
			}
		}
		err = errors.New(msg)
	}()
	resp, err := tr.RoundTrip(req)
	if err != nil {
		return nil, fmt.Errorf("could not be fetched (%v)", err)
	}
	defer resp.Body.Close()
	if resp.StatusCode != http.StatusOK {
		return nil, fmt.Errorf("answered %d %s", resp.StatusCode, http.StatusText(resp.StatusCode))
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
	if c := img.Get("XRAY_SUBSCRIPTION_CACHE"); c != "" &&
		(envconf.Overlap(c, img.Get("XRAY_SOURCE_DIR")) || envconf.Overlap(c, img.Get("XRAY_RUNTIME_DIR"))) {
		return s, fmt.Errorf("XRAY_SUBSCRIPTION_CACHE (%s) overlaps XRAY_SOURCE_DIR or XRAY_RUNTIME_DIR, whose files it would replace: point it at a directory of its own", c)
	}
	return s, nil
}

// supervise runs Xray on the runtime directory and, every interval (subRetry
// while a subscription holds nothing or a pinned geodata file is still to be
// fetched), fetches each subscription again, and each such file:
// through XRAY_SUBSCRIPTION_PROXY first when set, directly when that fails.
// When one changed, the whole source is resolved again and tested in a
// directory beside the running config; Xray restarts on it only if it passes,
// and the cache is written only then. A signal goes on to Xray, a refresh
// under way or not, and Xray's exit ends the container with its status.
func supervise(src, run string, extra []string, s subSettings) error {
	sigs := make(chan os.Signal, 1)
	signal.Notify(sigs, syscall.SIGTERM, syscall.SIGINT)
	cmd, done, err := launch(run, extra)
	if err != nil {
		return err
	}
	subsDue = time.Now().Add(s.interval) // fetched at start
	timer := time.NewTimer(next(s))
	// Set while a refresh runs, in the background so a signal is not held up
	// by a fetch. Till it answers, subs is the refresh's alone.
	var refreshed chan bool
	for {
		select {
		case sig := <-sigs:
			_ = cmd.Process.Signal(sig)
			<-done
			os.Exit(exitCode(cmd.ProcessState))
		case err := <-done:
			fmt.Fprintf(os.Stderr, "xray-entrypoint: Xray exited (%v)\n", err)
			os.Exit(exitCode(cmd.ProcessState))
		case <-timer.C:
			refreshed = make(chan bool, 1)
			go func(c chan bool) { c <- refresh(src, run, extra, s) }(refreshed)
		case restart := <-refreshed:
			refreshed = nil
			if restart {
				stop(cmd, done)
				if cmd, done, err = launch(run, extra); err != nil {
					return err
				}
			}
			timer.Reset(next(s))
		}
	}
}

// exitCode is Xray's exit status as a shell gives it: 128+n after signal n.
func exitCode(ps *os.ProcessState) int {
	if ws, ok := ps.Sys().(syscall.WaitStatus); ok && ws.Signaled() {
		return 128 + int(ws.Signal())
	}
	return ps.ExitCode()
}

func next(s subSettings) time.Duration {
	if geoWaiting() {
		return min(subRetry, s.interval)
	}
	for _, b := range subs {
		if b == nil {
			return min(subRetry, s.interval)
		}
	}
	// The subscriptions' own due time, which a geodata wait kept running.
	if d := time.Until(subsDue); len(subs) > 0 && d < s.interval {
		return max(d, time.Second)
	}
	return s.interval
}

// refresh fetches the subscriptions when their interval came round, then each
// pinned geodata file not there yet (geodata.go), and reports whether Xray is
// to restart: a subscription changed, or a file was fetched and passed, and
// the runtime directory holds the config `xray run -test` passed. Geodata
// comes second: a slow fetch doesn't hold the subscriptions up, and its test
// runs on the config Xray restarts on.
func refresh(src, run string, extra []string, s subSettings) bool {
	restart, intact := refreshSubs(src, run, extra, s)
	if !intact {
		// Neither a restart nor a geodata test on a broken runtime directory,
		// which would blame a good file.
		fmt.Fprintln(os.Stderr, "xray-entrypoint: XRAY_RUNTIME_DIR could not be put back; Xray keeps running on the config it loaded, and geodata waits")
		return false
	}
	return refreshGeo(run, extra, s.proxy) || restart
}

// refreshSubs fetches every subscription, when due, and reports whether one
// changed and the runtime directory now holds the config resolved on it, and
// whether the runtime directory holds a whole config, the old one or the new.
func refreshSubs(src, run string, extra []string, s subSettings) (bool, bool) {
	due := !time.Now().Before(subsDue)
	for _, b := range subs {
		due = due || b == nil
	}
	if !due || len(subs) == 0 {
		return false, true
	}
	subsDue = time.Now().Add(s.interval)
	old := maps.Clone(subs)
	changed := false
	for _, name := range slices.Sorted(maps.Keys(subs)) {
		u, err := subscriptionURL(name)
		if err != nil {
			fmt.Fprintf(os.Stderr, "subscription: %s %v\n", name, err)
			continue
		}
		b, err := get(name, u, s.proxy)
		if err != nil {
			fmt.Fprintf(os.Stderr, "subscription: %s: %v; Xray keeps what it has\n", name, err)
			continue
		}
		if !bytes.Equal(b, subs[name]) {
			subs[name], changed = b, true
		}
	}
	if !changed {
		return false, true
	}
	revert := func(err error) (bool, bool) {
		fmt.Fprintf(os.Stderr, "subscription: %v; Xray keeps the config it runs\n", err)
		subs = old
		return false, true
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
		// The runtime directory is emptied before it is written: put back the
		// config Xray runs, which a later restart (geodata's) starts on.
		revert(err)
		return false, writeRuntime(run, running) == nil
	}
	running = configs
	writeCaches()
	for _, c := range configs {
		for _, r := range c.Refs {
			if r.Kind == "$subscription" {
				fmt.Fprintf(os.Stderr, "subscription: %s: %s; restarting Xray on it\n", r.File, r.Note)
			}
		}
	}
	return true, true
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
