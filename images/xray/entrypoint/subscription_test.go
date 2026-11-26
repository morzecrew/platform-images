package main

import (
	"net"
	"net/http"
	"net/http/httptest"
	"net/url"
	"os"
	"path/filepath"
	"slices"
	"strings"
	"testing"
	"time"
)

const subConfig = `{"inbounds": [{"port": 10808, "protocol": "socks"}],
 "outbounds": [{"tag": "dotdash-1-reality", "protocol": "vless",
   "settings": {"address": "relay.example.net", "port": 443, "id": "6e3c4bd2-5a4f-4b8e-9d1e-0f2a3b4c5d6e", "flow": "xtls-rprx-vision"},
   "streamSettings": {"network": "raw", "security": "reality", "realitySettings": {"password": "pbk-secret-value", "fingerprint": "chrome"}}},
  {"tag": "dns-out", "protocol": "dns"}],
 "routing": {"rules": []}}`

// A server that serves body with status at /<token>, and counts its requests.
func subServer(t *testing.T, status int, body string) (*httptest.Server, string, *int) {
	t.Helper()
	n := new(int)
	srv := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		*n++
		w.WriteHeader(status)
		_, _ = w.Write([]byte(body))
	}))
	t.Cleanup(srv.Close)
	return srv, srv.URL + "/0123456789abcdef0123456789abcdef", n
}

func urlFile(t *testing.T, u string) string {
	t.Helper()
	p := filepath.Join(t.TempDir(), "subscription_url")
	if err := os.WriteFile(p, []byte(u+"\n"), 0o600); err != nil {
		t.Fatal(err)
	}
	return p
}

func TestFetchTakesTheOutbounds(t *testing.T) {
	_, u, _ := subServer(t, 200, subConfig)
	b, err := fetch(u, nil)
	if err != nil {
		t.Fatal(err)
	}
	if !strings.HasPrefix(string(b), `[{"protocol":"vless",`) || !strings.HasSuffix(string(b), `{"protocol":"dns","tag":"dns-out"}]`) {
		t.Fatalf("outbounds: %s", b)
	}
	again, _ := fetch(u, nil)
	if string(again) != string(b) {
		t.Fatal("two fetches of one config differ")
	}
}

func TestFetchRefusesWithoutTheURL(t *testing.T) {
	for _, c := range []struct {
		status int
		body   string
		want   string
	}{
		{404, "nope", "answered 404 Not Found"},
		{200, "dmxlc3M6Ly8=", "serves no Xray config"},
		{200, `{"outbounds": []}`, "no outbounds"},
		{200, `{"outbounds": [{"tag": "x"}]}`, "outbound 1 has no protocol"},
		{200, strings.Repeat(" ", subMax+1), "serves more than"},
	} {
		_, u, _ := subServer(t, c.status, c.body)
		_, err := fetch(u, nil)
		if err == nil || !strings.Contains(err.Error(), c.want) {
			t.Errorf("%d %.20q: %v, want %q", c.status, c.body, err, c.want)
		}
	}
	// A redirect is not followed, nor its Location quoted, parsable or not.
	for _, loc := range []string{"/0123456789abcdef/%zz", "/0123456789abcdef.json"} {
		redir := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
			w.Header().Set("Location", loc)
			w.WriteHeader(http.StatusFound)
		}))
		_, err := fetch(redir.URL+"/x", nil)
		redir.Close()
		if err == nil || err.Error() != "answered 302 Found" {
			t.Errorf("a redirect to %s: %v", loc, err)
		}
	}
	// Nor what a server puts in its reason phrase, or in a response so
	// malformed that Go quotes it.
	for _, answer := range []string{
		"HTTP/1.1 302 /0123456789abcdef/%zz\r\nContent-Length: 0\r\n\r\n",
		"/0123456789abcdef/%zz?fedcba9876543210\r\n\r\n",
	} {
		ln, err := net.Listen("tcp", "127.0.0.1:0")
		if err != nil {
			t.Fatal(err)
		}
		go func() {
			if c, err := ln.Accept(); err == nil {
				_, _ = c.Read(make([]byte, 4096))
				_, _ = c.Write([]byte(answer))
				c.Close()
			}
		}()
		_, err = fetch("http://"+ln.Addr().String()+"/sub/0123456789abcdef?key=fedcba9876543210", nil)
		ln.Close()
		if err == nil || strings.Contains(err.Error(), "0123456789abcdef") || strings.Contains(err.Error(), "fedcba9876543210") {
			t.Errorf("answered %.20q: %v", answer, err)
		}
	}
	srv, u, _ := subServer(t, 200, subConfig)
	srv.Close()
	_, err := fetch(u, nil)
	if err == nil || strings.Contains(err.Error(), "0123456789abcdef") {
		t.Fatalf("an unreachable URL: %v", err)
	}
}

func TestFetchThroughTheProxy(t *testing.T) {
	via := false
	proxy := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		via = r.URL.Host == "sub.example.net"
		_, _ = w.Write([]byte(subConfig))
	}))
	defer proxy.Close()
	p, _ := url.Parse(proxy.URL)
	if _, err := fetch("http://sub.example.net/0123", p); err != nil || !via {
		t.Fatalf("through the proxy: %v, via %v", err, via)
	}
}

func TestSubscriptionResolvesAndRedacts(t *testing.T) {
	subs = map[string][]byte{}
	_, u, n := subServer(t, 200, subConfig)
	f := urlFile(t, u)
	res, err := subscription(f)
	if err != nil {
		t.Fatal(err)
	}
	if outs, _ := res.Value.([]any); len(outs) != 2 || res.Note != "2 outbound(s)" {
		t.Fatalf("value %v, note %q", res.Value, res.Note)
	}
	for _, want := range []string{u, "6e3c4bd2-5a4f-4b8e-9d1e-0f2a3b4c5d6e", "pbk-secret-value", "relay.example.net"} {
		if !slices.Contains(res.Secrets, want) {
			t.Errorf("not redacted: %s", want)
		}
	}
	for _, plain := range []string{"vless", "dotdash-1-reality", "xtls-rprx-vision", "chrome", "reality"} {
		if slices.Contains(res.Secrets, plain) {
			t.Errorf("redacted, though structure: %s", plain)
		}
	}
	// Resolved again, as the loop does once it has fetched: no second fetch.
	if _, err := subscription(f); err != nil || *n != 1 {
		t.Fatalf("resolved again: %v, %d fetches", err, *n)
	}
}

func TestSubscriptionFallsBackToTheCacheThenToNothing(t *testing.T) {
	subs = map[string][]byte{}
	t.Setenv("XRAY_SUBSCRIPTION_CACHE", t.TempDir())
	_, u, _ := subServer(t, 200, subConfig)
	f := urlFile(t, u)
	if _, err := subscription(f); err != nil {
		t.Fatal(err)
	}
	writeCaches()
	if _, err := os.Stat(cacheFile(f)); err != nil {
		t.Fatal("no cache written:", err)
	}

	subs = map[string][]byte{}
	srv, gone, _ := subServer(t, 200, subConfig)
	srv.Close()
	if err := os.WriteFile(f, []byte(gone), 0o600); err != nil {
		t.Fatal(err)
	}
	res, err := subscription(f)
	if outs, _ := res.Value.([]any); err != nil || len(outs) != 2 {
		t.Fatalf("from the cache: %v, %v", res.Value, err)
	}

	subs = map[string][]byte{}
	t.Setenv("XRAY_SUBSCRIPTION_CACHE", "")
	res, err = subscription(f)
	if outs, ok := res.Value.([]any); err != nil || !ok || len(outs) != 0 || res.Note != "no outbounds yet" {
		t.Fatalf("with nothing: %v, %q, %v", res.Value, res.Note, err)
	}
	if next(subSettings{interval: 3600e9}) != subRetry {
		t.Fatal("a subscription holding nothing is not retried sooner")
	}
}

// A start on the cache, its URL down, is fetched again every subRetry, not a
// whole interval later, until a fetch succeeds; then the interval is back.
func TestSubscriptionOnItsCacheIsRetriedTillAFetch(t *testing.T) {
	subs, subStale = map[string][]byte{}, map[string]bool{}
	defer func() { subs, subStale, subsDue = map[string][]byte{}, map[string]bool{}, time.Time{} }()
	t.Setenv("XRAY_SUBSCRIPTION_CACHE", t.TempDir())
	srv, u, n := subServer(t, 200, subConfig)
	f := urlFile(t, u)
	if _, err := subscription(f); err != nil {
		t.Fatal(err)
	}
	writeCaches()

	subs = map[string][]byte{}
	gone, down, _ := subServer(t, 200, subConfig)
	gone.Close()
	if err := os.WriteFile(f, []byte(down), 0o600); err != nil {
		t.Fatal(err)
	}
	if res, err := subscription(f); err != nil || res.Note != "2 outbound(s)" {
		t.Fatalf("from the cache: %q, %v", res.Note, err)
	}
	hour := subSettings{interval: time.Hour}
	subsDue = time.Now().Add(time.Hour) // as supervise sets it at start
	if next(hour) != subRetry {
		t.Fatal("a start on the cache is not retried sooner")
	}
	if restart, _ := refreshSubs(t.TempDir(), t.TempDir(), nil, hour); restart || next(hour) != subRetry {
		t.Fatal("a failed retry ended the retries")
	}

	// The URL answers, with what the cache holds: no restart, and the
	// subscription's own interval again.
	if err := os.WriteFile(f, []byte(u), 0o600); err != nil {
		t.Fatal(err)
	}
	before := *n
	if restart, _ := refreshSubs(t.TempDir(), t.TempDir(), nil, hour); restart || *n != before+1 {
		t.Fatalf("the retry: restart %v, %d fetches", restart, *n-before)
	}
	if d := next(hour); d < 59*time.Minute {
		t.Fatalf("after a fetch: next in %s, want the interval", d)
	}
	srv.Close()
}

func TestSubscriptionURLAndSettings(t *testing.T) {
	if _, err := subscriptionURL(urlFile(t, "ftp://x/y")); err == nil || strings.Contains(err.Error(), "ftp") {
		t.Fatalf("ftp: %v", err)
	}
	for _, c := range []struct{ interval, proxy, want string }{
		{"1h", "", ""},
		{"1h", "socks5://127.0.0.1:10808", ""},
		{"500ms", "", "XRAY_SUBSCRIPTION_INTERVAL"},
		{"soon", "", "XRAY_SUBSCRIPTION_INTERVAL"},
		{"1h", "socks5://u:p@127.0.0.1:1", "login"},
		{"1h", "https://127.0.0.1:1", "XRAY_SUBSCRIPTION_PROXY"},
	} {
		t.Setenv("XRAY_SUBSCRIPTION_INTERVAL", c.interval)
		t.Setenv("XRAY_SUBSCRIPTION_PROXY", c.proxy)
		_, err := subscriptionSettings()
		if (c.want == "") != (err == nil) || (err != nil && !strings.Contains(err.Error(), c.want)) {
			t.Errorf("%s %s: %v", c.interval, c.proxy, err)
		}
	}
	t.Setenv("XRAY_SUBSCRIPTION_PROXY", "")
	for _, c := range []string{"/etc/xray", "/run", "/run/xray/cache"} {
		t.Setenv("XRAY_SUBSCRIPTION_CACHE", c)
		if _, err := subscriptionSettings(); err == nil || !strings.Contains(err.Error(), "overlaps") {
			t.Errorf("cache %s: %v", c, err)
		}
	}
}

func TestSubscriptionStartsThroughTheProxy(t *testing.T) {
	subs = map[string][]byte{}
	proxy := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		_, _ = w.Write([]byte(subConfig))
	}))
	defer proxy.Close()
	subProxy, _ = url.Parse(proxy.URL)
	defer func() { subProxy = nil }()
	// Only the proxy knows the name.
	res, err := subscription(urlFile(t, "http://sub.invalid/0123"))
	if outs, _ := res.Value.([]any); err != nil || len(outs) != 2 {
		t.Fatalf("at start through the proxy: %v, %v", res.Value, err)
	}
}

func TestSubscriptionsSharingAFileNameAreRefusedWithACache(t *testing.T) {
	subs = map[string][]byte{}
	t.Setenv("XRAY_SUBSCRIPTION_CACHE", t.TempDir())
	_, u, _ := subServer(t, 200, subConfig)
	if _, err := subscription(urlFile(t, u)); err != nil {
		t.Fatal(err)
	}
	if _, err := subscription(urlFile(t, u)); err == nil || !strings.Contains(err.Error(), "rename one") {
		t.Fatalf("a second subscription_url: %v", err)
	}
}

// While a geodata file waits the refresh runs every 30 seconds, and the
// subscriptions are fetched only when their own interval comes round.
func TestRefreshKeepsTheSubscriptionsInterval(t *testing.T) {
	_, u, n := subServer(t, 200, subConfig)
	subs = map[string][]byte{urlFile(t, u): []byte(`[]`)}
	defer func() { subs, subsDue = map[string][]byte{}, time.Time{} }()
	subsDue = time.Now().Add(time.Hour)
	if refresh(t.TempDir(), t.TempDir(), nil, subSettings{interval: time.Hour}) || *n != 0 {
		t.Fatalf("fetched before its interval: %d requests", *n)
	}
}

// Once no geodata file waits, the timer comes back at the subscriptions' own
// due time rather than a full interval later.
func TestNextKeepsTheSubscriptionsDueTime(t *testing.T) {
	subs = map[string][]byte{"/run/secrets/s": []byte(`[]`)}
	defer func() { subs, subsDue = map[string][]byte{}, time.Time{} }()
	subsDue = time.Now().Add(10 * time.Minute)
	if d := next(subSettings{interval: time.Hour}); d > 10*time.Minute || d < 9*time.Minute {
		t.Fatalf("next: %s, want about 10m", d)
	}
}
