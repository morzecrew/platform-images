package main

// XRAY_GEOIP and XRAY_GEOSITE: geoip.dat and geosite.dat from a URL, pinned by
// their sha256, in place of the image's own. The fetched files are kept in
// XRAY_GEODATA_DIR, and Xray finds them through XRAY_LOCATION_ASSET, set to
// its active/ directory, which links the files in use: Xray takes its own
// copy of a file not linked there. A file that is not the pinned one yet is
// fetched every 30 seconds once Xray runs, through XRAY_SUBSCRIPTION_PROXY
// first and directly when that fails, and Xray restarts on it once `xray run
// -test` passes the running config on it. At start only when the config
// fails without it (a new machine, a lost volume), directly and tested the
// same way: an untested file would replace the one that works.

import (
	"context"
	"crypto/sha256"
	"encoding/hex"
	"errors"
	"fmt"
	"io"
	"io/fs"
	"net"
	"net/http"
	"net/url"
	"os"
	"os/exec"
	"path/filepath"
	"strings"
	"sync/atomic"
	"time"

	"github.com/morzecrew/platform-images/shared/go/envconf"
)

const (
	geoTimeout = 10 * time.Minute // one fetch, the body included
	geoConnect = 10 * time.Second // to connect, and for a TLS handshake
	geoHeader  = 30 * time.Second // for the response to start
)

// A fetch gives up once nothing came for this long; a variable for the tests.
var geoIdle = time.Minute

// errFinal marks what fetching the same URL again won't change: a file of
// another sha256, or too large.
type errFinal struct{ error }

var geoMax int64 = 256 << 20 // the most a file may hold; a variable for the tests

type geoFile struct {
	name   string // geoip.dat or geosite.dat
	url    string
	sha    string // lowercase hex
	ready  bool   // the file in XRAY_GEODATA_DIR is the pinned one
	failed bool   // the URL serves another file, or the running config fails on it: not fetched again till a restart
}

// The files XRAY_GEOIP and XRAY_GEOSITE pin, and where they are kept; none
// when neither is set, and then Xray reads the image's own.
var (
	geo    []*geoFile
	geoDir string
)

// geodataSettings reads XRAY_GEOIP, XRAY_GEOSITE and XRAY_GEODATA_DIR, before
// anything is fetched.
func geodataSettings(src, run string) error {
	geo, geoDir = nil, ""
	for _, e := range []struct{ env, name string }{{"XRAY_GEOIP", "geoip.dat"}, {"XRAY_GEOSITE", "geosite.dat"}} {
		v := img.Get(e.env)
		if v == "" {
			continue
		}
		f := strings.Fields(v)
		if len(f) != 2 {
			return fmt.Errorf("%s is not \"<url> <sha256>\"", e.env)
		}
		u, err := url.Parse(f[0])
		if err != nil || (u.Scheme != "http" && u.Scheme != "https") || u.Host == "" {
			return fmt.Errorf("%s does not start with an http or https URL", e.env)
		}
		// The summary shows the environment as it is.
		if u.User != nil || u.RawQuery != "" {
			return fmt.Errorf("%s holds a login or a query, which the startup summary would show: a pinned file needs neither", e.env)
		}
		if b, err := hex.DecodeString(f[1]); err != nil || len(b) != sha256.Size {
			return fmt.Errorf("%s does not end in a sha256, 64 hex digits", e.env)
		}
		geo = append(geo, &geoFile{name: e.name, url: f[0], sha: strings.ToLower(f[1])})
	}
	if len(geo) == 0 {
		return nil
	}
	// Absolute: the links in active/ name their targets by it, and a relative
	// target would be read from inside active/.
	geoDir = filepath.Clean(img.Get("XRAY_GEODATA_DIR"))
	if abs, err := filepath.Abs(geoDir); err == nil {
		geoDir = abs
	}
	switch {
	case img.Get("XRAY_GEODATA_DIR") == "":
		return errors.New("XRAY_GEOIP and XRAY_GEOSITE need XRAY_GEODATA_DIR, a writable directory the fetched files are kept in, such as /var/lib/xray/geodata with a volume on /var/lib/xray")
	case os.Getenv("XRAY_LOCATION_ASSET") != "":
		return errors.New("XRAY_LOCATION_ASSET is set, and XRAY_GEOIP and XRAY_GEOSITE set it themselves: unset one or the other")
	case envconf.Overlap(geoDir, src) || envconf.Overlap(geoDir, run):
		return fmt.Errorf("XRAY_GEODATA_DIR (%s) overlaps XRAY_SOURCE_DIR or XRAY_RUNTIME_DIR: point it at a directory of its own", geoDir)
	case inside(img.Get("XRAY_SUBSCRIPTION_CACHE"), filepath.Join(geoDir, "active")):
		return fmt.Errorf("XRAY_SUBSCRIPTION_CACHE is inside %s/active, which every start empties", geoDir)
	}
	return nil
}

// inside tells whether p is dir or under it, through symlinks; an empty p
// never is.
func inside(p, dir string) bool {
	if p == "" {
		return false
	}
	rel, err := filepath.Rel(resolved(dir), resolved(p))
	return err == nil && rel != ".." && !strings.HasPrefix(rel, "../")
}

// resolved is p absolute, with its symlinks followed when it exists.
func resolved(p string) string {
	abs, err := filepath.Abs(p)
	if err != nil {
		return p
	}
	if r, err := filepath.EvalSymlinks(abs); err == nil {
		return r
	}
	return abs
}

// geodataPrepare links each pinned file XRAY_GEODATA_DIR holds, the pinned one
// or the one fetched for an earlier pin, into active/, and points Xray at
// active/. At start, before anything is resolved; the supervision loop
// fetches what is not the pinned one.
func geodataPrepare() error {
	active := filepath.Join(geoDir, "active")
	hint := func(err error) error {
		return fmt.Errorf("XRAY_GEODATA_DIR is %s, which is not writable by uid %d (%v)", geoDir, os.Getuid(), envconf.Cause(err))
	}
	if err := os.MkdirAll(active, 0o700); err != nil {
		return hint(err)
	}
	// Links rebuilt from the pins, and what a fetch or a test cut short left.
	for _, dir := range []string{active, geoDir} {
		entries, err := os.ReadDir(dir)
		if err != nil {
			return hint(err)
		}
		for _, e := range entries {
			n := e.Name()
			if dir == active || strings.HasPrefix(n, ".next-") ||
				strings.HasPrefix(n, ".geoip.dat-") || strings.HasPrefix(n, ".geosite.dat-") {
				if err := os.RemoveAll(filepath.Join(dir, e.Name())); err != nil {
					return hint(err)
				}
			}
		}
	}
	for _, g := range geo {
		p := filepath.Join(geoDir, g.name)
		sum, err := fileSHA(p)
		switch {
		case errors.Is(err, fs.ErrNotExist):
		case err != nil:
			return fmt.Errorf("XRAY_GEODATA_DIR's %s could not be read (%v)", g.name, envconf.Cause(err))
		default:
			g.ready = sum == g.sha
			if err := os.Symlink(p, filepath.Join(active, g.name)); err != nil {
				return hint(err)
			}
		}
		if !g.ready {
			have := "the image's own"
			if sum != "" {
				have = "the one fetched for an earlier pin"
			}
			fmt.Fprintf(os.Stderr, "geodata: %s: starting on %s, and fetching the pinned one once Xray runs\n", g.name, have)
		}
	}
	return os.Setenv("XRAY_LOCATION_ASSET", active)
}

// install moves a fetched file into XRAY_GEODATA_DIR and links it into
// active/.
func install(g *geoFile, tmp string) error {
	p := filepath.Join(geoDir, g.name)
	if err := os.Rename(tmp, p); err != nil {
		os.Remove(tmp)
		return err
	}
	// Ready only once linked: an unlinked file is fetched and linked again.
	if err := os.Symlink(p, filepath.Join(geoDir, "active", g.name)); err != nil && !errors.Is(err, fs.ErrExist) {
		return err
	}
	g.ready = true
	return nil
}

// geoWaiting tells whether a pinned file is still to be fetched.
func geoWaiting() bool {
	for _, g := range geo {
		if !g.ready && !g.failed {
			return true
		}
	}
	return false
}

// geoHint explains a refused config at start while a pinned file is not
// there yet.
func geoHint() string {
	var names []string
	for _, g := range geo {
		if !g.ready {
			names = append(names, g.name)
		}
	}
	if len(names) == 0 {
		return ""
	}
	return fmt.Sprintf("If Xray named a list above it could not find: it tested the config on another %s than the pinned one, not fetched yet, and a rule naming a list only the pinned one has can't pass until it is. Set XRAY_GEOIP or XRAY_GEOSITE first, and such rules once it is fetched", strings.Join(names, " and "))
}

// refreshGeo fetches each pinned file that is not there yet and reports
// whether Xray is to restart: one was fetched and installed. The fetched
// files are tested together, beside the files in use, in a directory of
// links beside active/, and installed if `xray run -test` passes the running
// config on them: files whose lists the config names together pass only
// together. When they fail together, each is tested alone, so a good one is
// installed though another fails. Xray restarts only on files that passed
// together. A file the test refuses, or a URL serving another file, is not
// fetched again till a restart.
func refreshGeo(run string, extra []string, proxy *url.URL) bool {
	tmps := map[*geoFile]string{}
	for _, g := range geo {
		if g.ready || g.failed {
			continue
		}
		tmp, err := geoFetch(g, proxy)
		var final errFinal
		switch {
		case errors.As(err, &final):
			g.failed = true
			fmt.Fprintf(os.Stderr, "geodata: %s: %v; Xray keeps the one it has, and it is not fetched again till a restart: check the pin\n", g.name, err)
		case err != nil:
			fmt.Fprintf(os.Stderr, "geodata: %s: %v; Xray keeps the one it has\n", g.name, err)
		default:
			tmps[g] = tmp
		}
	}
	defer func() {
		for _, t := range tmps {
			os.Remove(t) // gone already once installed
		}
	}()
	if len(tmps) == 0 {
		return false
	}
	err := geoTest(run, extra, tmps)
	if err == nil {
		return installAll(tmps)
	}
	if !refused(err) || len(tmps) == 1 {
		judge(tmps, err)
		return false
	}
	installed := false
	for _, g := range geo {
		if t, ok := tmps[g]; ok {
			one := map[*geoFile]string{g: t}
			if err := geoTest(run, extra, one); err != nil {
				judge(one, err)
				continue
			}
			installed = installAll(one) || installed
		}
	}
	return installed
}

// refused tells a refusal by `xray run -test` from a test killed or never run,
// which no file is to blame for.
func refused(err error) bool {
	var exit *exec.ExitError
	return errors.As(err, &exit) && exit.Exited()
}

// judge marks the files a refusal blames as failed, and says so.
func judge(tmps map[*geoFile]string, err error) {
	for _, g := range geo {
		if _, ok := tmps[g]; !ok {
			continue
		}
		if refused(err) {
			g.failed = true
			fmt.Fprintf(os.Stderr, "geodata: %s: the pinned one fails the running config (%v); Xray keeps the one it has, and it is not fetched again till a restart\n", g.name, err)
		} else {
			fmt.Fprintf(os.Stderr, "geodata: %s: not tested (%v); Xray keeps the one it has\n", g.name, err)
		}
	}
}

// installAll installs the files a test passed, and reports whether one was.
func installAll(tmps map[*geoFile]string) bool {
	installed := false
	for _, g := range geo {
		t, ok := tmps[g]
		if !ok {
			continue
		}
		if err := install(g, t); err != nil {
			fmt.Fprintf(os.Stderr, "geodata: %s could not be kept (%v); Xray keeps the one it has\n", g.name, envconf.Cause(err))
			continue
		}
		installed = true
		fmt.Fprintf(os.Stderr, "geodata: %s: fetched, its sha256 the pinned one, and the running config passes on it\n", g.name)
	}
	return installed
}

// geoTest runs `xray run -test` on the running config with the fetched files
// in tmps and the files in use for the others. The running config's own
// values redact Xray's output.
func geoTest(run string, extra []string, tmps map[*geoFile]string) error {
	stage, err := os.MkdirTemp(geoDir, ".next-")
	if err != nil {
		return fmt.Errorf("XRAY_GEODATA_DIR is not writable (%v)", envconf.Cause(err))
	}
	defer os.RemoveAll(stage)
	for _, h := range geo {
		p, ok := tmps[h]
		if !ok {
			if p = filepath.Join(geoDir, h.name); !exists(p) {
				continue
			}
		}
		if err := os.Symlink(p, filepath.Join(stage, h.name)); err != nil {
			return fmt.Errorf("XRAY_GEODATA_DIR is not writable (%v)", envconf.Cause(err))
		}
	}
	_, err = testConfig(run, extra, running, "XRAY_LOCATION_ASSET="+stage)
	return err
}

// geoFetch fetches through proxy first when it is set, and directly when that
// fails short of a final answer, into a temporary file in XRAY_GEODATA_DIR.
func geoFetch(g *geoFile, proxy *url.URL) (string, error) {
	if proxy == nil {
		return geoGet(g, nil)
	}
	p, err := geoGet(g, proxy)
	var final errFinal
	if err == nil || errors.As(err, &final) {
		return p, err
	}
	fmt.Fprintf(os.Stderr, "geodata: %s: through XRAY_SUBSCRIPTION_PROXY: %v\n", g.name, err)
	// Directly, a block page or a captive portal answers in the URL's place:
	// its wrong file is not final while the tunnel may come back.
	p, err = geoGet(g, nil)
	if errors.As(err, &final) {
		err = final.error
	}
	return p, err
}

// geoGet GETs the pinned URL, following redirects, and keeps the body only
// when its sha256 is the pinned one.
func geoGet(g *geoFile, proxy *url.URL) (_ string, err error) {
	tr := &http.Transport{Proxy: nil, ForceAttemptHTTP2: true, TLSHandshakeTimeout: geoConnect,
		ResponseHeaderTimeout: geoHeader, DialContext: (&net.Dialer{Timeout: geoConnect}).DialContext}
	if proxy != nil {
		tr.Proxy = http.ProxyURL(proxy)
	}
	defer tr.CloseIdleConnections()
	ctx, cancel := context.WithTimeout(context.Background(), geoTimeout)
	defer cancel()
	req, err := http.NewRequestWithContext(ctx, http.MethodGet, g.url, nil)
	if err != nil {
		return "", errors.New("its URL is not one Go can request")
	}
	resp, err := (&http.Client{Transport: tr}).Do(req)
	if err != nil {
		// A *url.Error quotes the URL, or a redirect's, query tokens included:
		// only its cause goes to the log.
		var ue *url.Error
		if errors.As(err, &ue) {
			err = ue.Err
		}
		return "", fmt.Errorf("could not be fetched (%v)", err)
	}
	defer resp.Body.Close()
	if resp.StatusCode != http.StatusOK {
		return "", fmt.Errorf("its URL answered %d %s", resp.StatusCode, http.StatusText(resp.StatusCode))
	}
	f, err := os.CreateTemp(geoDir, "."+g.name+"-*")
	if err != nil {
		return "", fmt.Errorf("could not be written (%v)", envconf.Cause(err))
	}
	defer func() {
		if err != nil {
			f.Close()
			os.Remove(f.Name())
		}
	}()
	h := sha256.New()
	// A stall cancels the request: geoTimeout alone would wait it out.
	var stalled atomic.Bool
	idle := time.AfterFunc(geoIdle, func() { stalled.Store(true); cancel() })
	defer idle.Stop()
	n, err := io.Copy(io.MultiWriter(f, h), io.LimitReader(idleReader{resp.Body, idle}, geoMax+1))
	switch {
	case err != nil && stalled.Load():
		return "", fmt.Errorf("stalled: nothing came for %s", geoIdle)
	case err != nil:
		return "", fmt.Errorf("could not be read or written (%v)", err)
	case n > geoMax:
		err = errFinal{fmt.Errorf("its URL serves more than %d bytes", geoMax)}
		return "", err
	}
	if sum := hex.EncodeToString(h.Sum(nil)); sum != g.sha {
		err = errFinal{fmt.Errorf("its URL serves a file whose sha256 is %s, not the pinned %s", sum, g.sha)}
		return "", err
	}
	// On disk before it is renamed in: a crash must not leave a short file
	// that a later start takes for an earlier pin's.
	if err = f.Sync(); err != nil {
		return "", fmt.Errorf("could not be written (%v)", err)
	}
	if err = f.Close(); err != nil {
		return "", fmt.Errorf("could not be written (%v)", err)
	}
	return f.Name(), nil
}

// idleReader pushes its timer back on every read.
type idleReader struct {
	r io.Reader
	t *time.Timer
}

func (i idleReader) Read(p []byte) (int, error) {
	n, err := i.r.Read(p)
	i.t.Reset(geoIdle)
	return n, err
}

func fileSHA(p string) (string, error) {
	f, err := os.Open(p)
	if err != nil {
		return "", err
	}
	defer f.Close()
	h := sha256.New()
	if _, err := io.Copy(h, f); err != nil {
		return "", err
	}
	return hex.EncodeToString(h.Sum(nil)), nil
}

func exists(p string) bool {
	_, err := os.Stat(p)
	return err == nil
}
