package main

import (
	"bytes"
	"context"
	"errors"
	"flag"
	"fmt"
	"io"
	"net/http"
	"net/url"
	"slices"
	"sync/atomic"
	"time"

	"github.com/morzecrew/platform-images/shared/go/envconf"
)

// The exit codes of `xray-entrypoint fetch`, beside 2 for a usage error.
const (
	fetchWhole   = 0 // a 2xx whose body came whole
	fetchNothing = 1 // no byte of a body: no answer, an error, or a status other than 2xx
	fetchPartial = 3 // some bytes of the body, then cut short, nothing for -read-timeout, or -timeout
)

// fetchCmd is `xray-entrypoint fetch`: one request through a proxy, timed and
// counted, for a probe in another image that runs this binary from a
// read-only mount of this one. It prints "<bytes> <milliseconds>" on stdout
// whatever the outcome, the body's bytes and the time since the request
// began, and says on stderr what ended it.
func fetchCmd(args []string, stdout, stderr io.Writer) int {
	fs := flag.NewFlagSet("fetch", flag.ContinueOnError)
	fs.SetOutput(stderr)
	proxyFlag := fs.String("proxy", "", "the proxy to go through, such as http://127.0.0.1:10809 (required)")
	readTimeout := fs.Duration("read-timeout", 10*time.Second, "nothing either way for this long ends it")
	timeout := fs.Duration("timeout", time.Minute, "the most the whole request may take")
	upload := fs.Int64("upload", 0, "send this many bytes as a POST body, in place of a GET")
	fs.Usage = func() {
		fmt.Fprintln(stderr, "usage: xray-entrypoint fetch -proxy <url> [-read-timeout 10s] [-timeout 1m] [-upload <bytes>] <http or https URL>")
		fs.PrintDefaults()
	}
	if err := fs.Parse(args); err != nil {
		return 2
	}
	usage := func(msg string) int {
		fmt.Fprintln(stderr, "fetch:", msg)
		fs.Usage()
		return 2
	}
	if fs.NArg() != 1 {
		return usage("one URL, after the flags")
	}
	target, err := url.Parse(fs.Arg(0))
	if err != nil || (target.Scheme != "http" && target.Scheme != "https") || target.Host == "" {
		return usage("the URL must be http or https")
	}
	// Required: without it the request would leave by this machine's own
	// network, which is what a probe of the tunnel must never measure.
	proxy, err := url.Parse(*proxyFlag)
	if err != nil || proxy.Host == "" || !slices.Contains([]string{"http", "https", "socks5", "socks5h"}, proxy.Scheme) {
		return usage("-proxy must be a proxy URL such as http://127.0.0.1:10809 or socks5://127.0.0.1:10808")
	}
	if *readTimeout <= 0 || *timeout <= 0 || *upload < 0 {
		return usage("the timeouts must be above 0 and -upload 0 or more")
	}

	ctx, cancel := context.WithTimeout(context.Background(), *timeout)
	defer cancel()
	var stalled atomic.Bool
	idle := time.AfterFunc(*readTimeout, func() { stalled.Store(true); cancel() })
	defer idle.Stop()
	method, body := http.MethodGet, io.Reader(nil)
	if *upload > 0 {
		// Each read of the body is a write about to happen: a write that
		// blocks stalls it as a read that waits does.
		// ponytail: the body is held in memory, fine for a probe's few KB; a
		// zero reader if anyone uploads gigabytes.
		method, body = http.MethodPost, idleReader{bytes.NewReader(make([]byte, *upload)), idle, *readTimeout}
	}
	req, err := http.NewRequestWithContext(ctx, method, target.String(), body)
	if err != nil {
		return usage("the URL is not one Go can request")
	}
	if *upload > 0 {
		req.ContentLength = *upload
		req.Header.Set("Content-Type", "application/octet-stream")
	}
	client := &http.Client{
		// No compression asked for, so the bytes counted are the bytes sent.
		Transport: &http.Transport{Proxy: http.ProxyURL(proxy), DisableCompression: true},
		// As the healthcheck: a redirect is the answer, not a step towards it.
		CheckRedirect: func(*http.Request, []*http.Request) error { return http.ErrUseLastResponse },
	}
	start := time.Now()
	var n int64
	why := func(err error) string {
		switch {
		case stalled.Load():
			return fmt.Sprintf("nothing came for %s", *readTimeout)
		case errors.Is(err, context.DeadlineExceeded):
			return fmt.Sprintf("not done within %s", *timeout)
		}
		// A *url.Error repeats the whole URL, which may hold a token.
		var ue *url.Error
		if errors.As(err, &ue) {
			err = ue.Err
		}
		return err.Error()
	}
	code := func() int {
		resp, err := client.Do(req)
		if err != nil {
			fmt.Fprintf(stderr, "fetch: %s %s through %s: %s\n", method, envconf.Shown(target), envconf.Shown(proxy), why(err))
			return fetchNothing
		}
		defer resp.Body.Close()
		if resp.StatusCode < 200 || resp.StatusCode > 299 {
			fmt.Fprintf(stderr, "fetch: %s %s through %s: %s\n", method, envconf.Shown(target), envconf.Shown(proxy), resp.Status)
			return fetchNothing
		}
		n, err = io.Copy(io.Discard, idleReader{resp.Body, idle, *readTimeout})
		switch {
		case err == nil:
			return fetchWhole
		case n == 0:
			fmt.Fprintf(stderr, "fetch: %s: no byte of the body: %s\n", resp.Status, why(err))
			return fetchNothing
		}
		fmt.Fprintf(stderr, "fetch: %s: cut short after %d bytes: %s\n", resp.Status, n, why(err))
		return fetchPartial
	}()
	fmt.Fprintf(stdout, "%d %d\n", n, time.Since(start).Milliseconds())
	return code
}
