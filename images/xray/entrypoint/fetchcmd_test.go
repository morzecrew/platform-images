package main

import (
	"bytes"
	"fmt"
	"io"
	"net"
	"net/http"
	"net/http/httptest"
	"net/http/httputil"
	"strconv"
	"strings"
	"sync/atomic"
	"testing"
	"time"
)

// A forward proxy, as Xray's http inbound is one: absolute-form requests
// passed on as they stream, CONNECT tunnelled. It counts what reaches it.
func fetchProxy(t *testing.T) (string, *atomic.Int32) {
	t.Helper()
	n := new(atomic.Int32)
	rp := &httputil.ReverseProxy{
		Rewrite:       func(pr *httputil.ProxyRequest) { pr.Out.URL = pr.In.URL },
		FlushInterval: -1,
		// Asking for no compression itself, so the target sees what fetch asked.
		Transport: &http.Transport{DisableCompression: true},
	}
	srv := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		n.Add(1)
		if r.Method != http.MethodConnect {
			rp.ServeHTTP(w, r)
			return
		}
		up, err := net.Dial("tcp", r.Host)
		if err != nil {
			http.Error(w, err.Error(), http.StatusBadGateway)
			return
		}
		w.WriteHeader(http.StatusOK)
		c, _, err := w.(http.Hijacker).Hijack()
		if err != nil {
			up.Close()
			return
		}
		go func() { _, _ = io.Copy(up, c); up.Close() }()
		_, _ = io.Copy(c, up)
		c.Close()
	}))
	t.Cleanup(srv.Close)
	return srv.URL, n
}

// The target, whose handler stops at the end of the test if it blocks.
func fetchTarget(t *testing.T, h func(w http.ResponseWriter, r *http.Request, done <-chan struct{})) string {
	t.Helper()
	done := make(chan struct{})
	srv := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) { h(w, r, done) }))
	t.Cleanup(srv.Close)
	t.Cleanup(func() { close(done) })
	return srv.URL
}

// runFetch returns the exit code, the bytes and milliseconds printed, and stderr.
func runFetch(t *testing.T, args ...string) (code int, n, ms int64, stderr string) {
	t.Helper()
	var out, errb bytes.Buffer
	code = fetchCmd(args, &out, &errb)
	if code == 2 {
		return code, 0, 0, errb.String()
	}
	f := strings.Fields(out.String())
	if len(f) != 2 || !strings.HasSuffix(out.String(), "\n") {
		t.Fatalf("stdout is %q, not one line of two numbers", out.String())
	}
	n, _ = strconv.ParseInt(f[0], 10, 64)
	ms, _ = strconv.ParseInt(f[1], 10, 64)
	return code, n, ms, errb.String()
}

func TestFetchWhole(t *testing.T) {
	proxy, through := fetchProxy(t)
	target := fetchTarget(t, func(w http.ResponseWriter, r *http.Request, _ <-chan struct{}) {
		if r.Header.Get("Accept-Encoding") != "" {
			t.Errorf("asked for %q: a compressed body would count fewer bytes than were sent", r.Header.Get("Accept-Encoding"))
		}
		_, _ = w.Write(make([]byte, 100000))
	})
	code, n, _, stderr := runFetch(t, "-proxy", proxy, target+"/down?bytes=100000")
	if code != fetchWhole || n != 100000 {
		t.Fatalf("exit %d, %d bytes: %s", code, n, stderr)
	}
	if through.Load() != 1 {
		t.Fatalf("the proxy saw %d requests, not 1", through.Load())
	}
}

func TestFetchCutShort(t *testing.T) {
	proxy, _ := fetchProxy(t)
	target := fetchTarget(t, func(w http.ResponseWriter, r *http.Request, _ <-chan struct{}) {
		w.Header().Set("Content-Length", "65536")
		_, _ = w.Write(make([]byte, 20000))
		w.(http.Flusher).Flush()
		c, _, _ := w.(http.Hijacker).Hijack()
		c.Close()
	})
	code, n, _, stderr := runFetch(t, "-proxy", proxy, target)
	if code != fetchPartial || n != 20000 {
		t.Fatalf("exit %d, %d bytes: %s", code, n, stderr)
	}
}

func TestFetchStalledAfterSomeBytes(t *testing.T) {
	proxy, _ := fetchProxy(t)
	target := fetchTarget(t, func(w http.ResponseWriter, r *http.Request, done <-chan struct{}) {
		w.Header().Set("Content-Length", "65536")
		_, _ = w.Write(make([]byte, 20000))
		w.(http.Flusher).Flush()
		<-done
	})
	code, n, ms, stderr := runFetch(t, "-proxy", proxy, "-read-timeout", "300ms", target)
	if code != fetchPartial || n != 20000 || ms < 300 || !strings.Contains(stderr, "nothing came for 300ms") {
		t.Fatalf("exit %d, %d bytes, %d ms: %s", code, n, ms, stderr)
	}
}

func TestFetchCappedWhileBytesTrickle(t *testing.T) {
	proxy, _ := fetchProxy(t)
	target := fetchTarget(t, func(w http.ResponseWriter, r *http.Request, done <-chan struct{}) {
		w.Header().Set("Content-Length", "65536")
		for {
			_, _ = w.Write([]byte{0})
			w.(http.Flusher).Flush()
			select {
			case <-done:
				return
			case <-time.After(50 * time.Millisecond):
			}
		}
	})
	code, n, ms, stderr := runFetch(t, "-proxy", proxy, "-read-timeout", "1s", "-timeout", "400ms", target)
	if code != fetchPartial || n == 0 || ms > 1000 || !strings.Contains(stderr, "not done within 400ms") {
		t.Fatalf("exit %d, %d bytes, %d ms: %s", code, n, ms, stderr)
	}
}

func TestFetchNothing(t *testing.T) {
	proxy, _ := fetchProxy(t)
	dead := httptest.NewServer(http.NotFoundHandler())
	dead.Close()
	target := fetchTarget(t, func(w http.ResponseWriter, r *http.Request, done <-chan struct{}) {
		switch r.URL.Path {
		case "/missing":
			http.NotFound(w, r)
		case "/redirect":
			http.Redirect(w, r, "/elsewhere", http.StatusFound)
		case "/silent":
			<-done
		}
	})
	for _, c := range []struct {
		name string
		args []string
		says string
	}{
		{"a dead proxy", []string{"-proxy", dead.URL, target + "/missing"}, "connection refused"},
		{"a 404", []string{"-proxy", proxy, target + "/missing"}, "404 Not Found"},
		{"a redirect, not followed", []string{"-proxy", proxy, target + "/redirect"}, "302 Found"},
		{"no answer", []string{"-proxy", proxy, "-read-timeout", "300ms", target + "/silent"}, "nothing came for 300ms"},
	} {
		code, n, _, stderr := runFetch(t, c.args...)
		if code != fetchNothing || n != 0 || !strings.Contains(stderr, c.says) {
			t.Errorf("%s: exit %d, %d bytes: %s", c.name, code, n, stderr)
		}
	}
}

func TestFetchUpload(t *testing.T) {
	proxy, _ := fetchProxy(t)
	var got atomic.Int64
	target := fetchTarget(t, func(w http.ResponseWriter, r *http.Request, done <-chan struct{}) {
		if r.Method != http.MethodPost {
			t.Errorf("%s, not POST", r.Method)
		}
		b, _ := io.ReadAll(r.Body)
		got.Store(int64(len(b)))
		if r.URL.Path == "/silent" {
			<-done
			return
		}
		fmt.Fprint(w, "ok")
	})
	code, n, _, stderr := runFetch(t, "-proxy", proxy, "-upload", "65536", target+"/up")
	if code != fetchWhole || n != 2 || got.Load() != 65536 {
		t.Fatalf("exit %d, %d bytes back, %d sent: %s", code, n, got.Load(), stderr)
	}
	code, n, ms, stderr := runFetch(t, "-proxy", proxy, "-upload", "65536", "-read-timeout", "300ms", target+"/silent")
	if code != fetchNothing || n != 0 || ms < 300 || got.Load() != 65536 {
		t.Fatalf("no answer to an upload: exit %d, %d bytes, %d ms: %s", code, n, ms, stderr)
	}
}

// https goes by CONNECT, and the certificate is checked: httptest's is
// signed by no CA the system trusts.
func TestFetchTunnelsAndChecksTheCertificate(t *testing.T) {
	proxy, through := fetchProxy(t)
	tls := httptest.NewTLSServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {}))
	t.Cleanup(tls.Close)
	code, n, _, stderr := runFetch(t, "-proxy", proxy, tls.URL)
	if code != fetchNothing || n != 0 || !strings.Contains(stderr, "certificate") || through.Load() != 1 {
		t.Fatalf("exit %d, %d bytes, %d through the proxy: %s", code, n, through.Load(), stderr)
	}
}

func TestFetchUsage(t *testing.T) {
	for _, args := range [][]string{
		{"https://example.com/"},
		{"-proxy", "127.0.0.1:10809", "https://example.com/"},
		{"-proxy", "http://127.0.0.1:10809", "ftp://example.com/"},
		{"-proxy", "http://127.0.0.1:10809"},
		{"-proxy", "http://127.0.0.1:10809", "-upload", "-1", "https://example.com/"},
		{"-proxy", "http://127.0.0.1:10809", "-read-timeout", "0s", "https://example.com/"},
		{"-bogus", "https://example.com/"},
	} {
		if code, _, _, stderr := runFetch(t, args...); code != 2 || !strings.Contains(stderr, "usage: xray-entrypoint fetch") {
			t.Errorf("%q: exit %d: %s", args, code, stderr)
		}
	}
}
