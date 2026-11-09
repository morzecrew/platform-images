package envconf

import (
	"bytes"
	"errors"
	"fmt"
	"io"
	"net/http"
	"net/url"
	"os"
	"path/filepath"
	"regexp"
	"slices"
	"time"
)

// MaxBody is the most of a response body <PREFIX>HEALTHCHECK_EXPECT is
// matched against.
const MaxBody = 64 << 10

// Health is the probe's settings, from <PREFIX>HEALTHCHECK_*.
type Health struct {
	Target, Proxy *url.URL // Proxy is nil when unset
	Timeout       time.Duration
	Expect        *regexp.Regexp // nil when unset
}

// HealthSettings reads and checks <PREFIX>HEALTHCHECK_*. An entrypoint calls
// it at start as well as in the probe, so that a bad value stops the
// deployment rather than turning into an unhealthy container later.
func (im *Image) HealthSettings() (h Health, err error) {
	p := im.Prefix + "HEALTHCHECK_"
	h.Target, err = url.Parse(im.Get(p + "URL"))
	if err != nil || (h.Target.Scheme != "http" && h.Target.Scheme != "https") || h.Target.Host == "" {
		return h, errors.New(p + "URL must be an http or https URL")
	}
	t := im.Get(p + "TIMEOUT")
	if h.Timeout, err = time.ParseDuration(t); err != nil || h.Timeout <= 0 {
		return h, fmt.Errorf("%sTIMEOUT is %q, which is not a duration such as 10s", p, t)
	}
	if v := im.Get(p + "PROXY"); v != "" {
		h.Proxy, err = url.Parse(v)
		if err != nil || h.Proxy.Host == "" || !slices.Contains([]string{"http", "https", "socks5", "socks5h"}, h.Proxy.Scheme) {
			return h, errors.New(p + "PROXY must be a proxy URL such as http://127.0.0.1:10809 or socks5://127.0.0.1:10808")
		}
	}
	if e := im.Get(p + "EXPECT"); e != "" {
		if h.Expect, err = regexp.Compile(e); err != nil {
			return h, fmt.Errorf("%sEXPECT is not a regular expression in Go's RE2 syntax: %v", p, err)
		}
	}
	return h, nil
}

// Healthcheck sends one GET through the proxy and returns the exit code: 0
// for a 2xx whose body matches the expression, if one is set, and 1 for
// anything else. With no proxy set it checks only that the server is PID 1
// and that dir holds a file whose name matches pattern.
func (im *Image) Healthcheck(dir, pattern string) int {
	h, err := im.HealthSettings()
	if err != nil {
		fmt.Fprintln(os.Stderr, "healthcheck:", err)
		return 1
	}
	if h.Proxy == nil {
		return im.liveness(dir, pattern)
	}
	client := &http.Client{
		// Covers reading the body as well as the request.
		Timeout:   h.Timeout,
		Transport: &http.Transport{Proxy: http.ProxyURL(h.Proxy)},
		// A redirect is a captive portal or a block page as often as not, so
		// it is the answer rather than a step towards one.
		CheckRedirect: func(*http.Request, []*http.Request) error { return http.ErrUseLastResponse },
	}
	resp, err := client.Get(h.Target.String())
	if err != nil {
		// A *url.Error repeats the whole URL; what lies beneath it does not.
		var ue *url.Error
		if errors.As(err, &ue) {
			err = ue.Err
		}
		fmt.Fprintf(os.Stderr, "healthcheck: GET %s through %s: %v\n", shown(h.Target), shown(h.Proxy), err)
		return 1
	}
	defer resp.Body.Close()
	fmt.Fprintf(os.Stderr, "healthcheck: GET %s through %s: %s\n", shown(h.Target), shown(h.Proxy), resp.Status)
	if resp.StatusCode < 200 || resp.StatusCode > 299 {
		return 1
	}
	if h.Expect == nil {
		return 0
	}
	body, err := io.ReadAll(io.LimitReader(resp.Body, MaxBody))
	if err != nil {
		fmt.Fprintln(os.Stderr, "healthcheck: reading the response body:", err)
		return 1
	}
	if !h.Expect.Match(body) {
		// For an IP-echo endpoint the excerpt is the exit IP the traffic
		// leaves from now, which is what the operator needs to see.
		fmt.Fprintf(os.Stderr, "healthcheck: the response body does not match %sHEALTHCHECK_EXPECT: %q\n", im.Prefix, body[:min(len(body), 128)])
		return 1
	}
	fmt.Fprintf(os.Stderr, "healthcheck: the response body matches %sHEALTHCHECK_EXPECT\n", im.Prefix)
	return 0
}

// Without a proxy there is no egress to probe, and saying so is the point:
// a green check that tested nothing would read as one that did.
func (im *Image) liveness(dir, pattern string) int {
	cmdline, err := os.ReadFile("/proc/1/cmdline")
	if err != nil || !bytes.HasPrefix(cmdline, []byte(im.Bin+"\x00")) {
		fmt.Fprintf(os.Stderr, "healthcheck: PID 1 is not %s\n", im.Title)
		return 1
	}
	if !hasConfig(dir, pattern) {
		fmt.Fprintf(os.Stderr, "healthcheck: %s holds no %s\n", dir, pattern)
		return 1
	}
	fmt.Fprintf(os.Stderr, "healthcheck: %s is running. %sHEALTHCHECK_PROXY is unset, so egress was not probed\n", im.Title, im.Prefix)
	return 0
}

// Only the name is a pattern: a glob of the whole path would read a [ or a *
// in the directory as one, and find nothing.
func hasConfig(dir, pattern string) bool {
	entries, _ := os.ReadDir(dir)
	for _, e := range entries {
		if ok, _ := filepath.Match(pattern, e.Name()); ok && e.Type().IsRegular() {
			return true
		}
	}
	return false
}

// shown is u as the summary and the probe print it: the password and every
// query value masked, as an API key in a query is as common as one in the
// userinfo. The path is printed as is, being what the probe requests.
func shown(u *url.URL) string {
	c := *u
	if c.RawQuery != "" {
		q := c.Query()
		for k := range q {
			for i := range q[k] {
				q[k][i] = "xxxxx"
			}
		}
		c.RawQuery = q.Encode()
	}
	return c.Redacted()
}
