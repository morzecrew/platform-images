package main

// XRAY_GEOIP and XRAY_GEOSITE: geoip.dat and geosite.dat from a URL, pinned by
// their sha256, in place of the image's own. The fetched files are kept in
// XRAY_GEODATA_DIR, and Xray finds them through XRAY_LOCATION_ASSET, set to
// its active/ directory, which links the files in use: Xray takes its own
// copy of a file not linked there. A file that is not the pinned one yet is
// fetched every 30 seconds once Xray runs, through XRAY_SUBSCRIPTION_PROXY
// first and directly when that fails, and Xray restarts on it once `xray run
// -test` passes the running config on it. With no XRAY_SUBSCRIPTION_PROXY,
// there being no tunnel to wait for, it is fetched at start too.

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
	"path/filepath"
	"strings"
	"time"

	"github.com/morzecrew/platform-images/shared/go/envconf"
)

const (
	geoTimeout = 10 * time.Minute // one fetch, the body included
	geoConnect = 10 * time.Second // to connect, and for a TLS handshake
)

var geoMax int64 = 256 << 20 // the most a file may hold; a variable for the tests

type geoFile struct {
	name   string // geoip.dat or geosite.dat
	url    string
	sha    string // lowercase hex
	ready  bool   // the file in XRAY_GEODATA_DIR is the pinned one
	failed bool   // xray run -test refused the config on the pinned one: not fetched again till a restart
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
		if b, err := hex.DecodeString(f[1]); err != nil || len(b) != sha256.Size {
			return fmt.Errorf("%s does not end in a sha256, 64 hex digits", e.env)
		}
		geo = append(geo, &geoFile{name: e.name, url: f[0], sha: strings.ToLower(f[1])})
	}
	if len(geo) == 0 {
		return nil
	}
	geoDir = filepath.Clean(img.Get("XRAY_GEODATA_DIR"))
	switch {
	case img.Get("XRAY_GEODATA_DIR") == "":
		return errors.New("XRAY_GEOIP and XRAY_GEOSITE need XRAY_GEODATA_DIR, a writable directory the fetched files are kept in, such as /var/lib/xray/geodata with a volume on /var/lib/xray")
	case os.Getenv("XRAY_LOCATION_ASSET") != "":
		return errors.New("XRAY_LOCATION_ASSET is set, and XRAY_GEOIP and XRAY_GEOSITE set it themselves: unset one or the other")
	case envconf.Overlap(geoDir, src) || envconf.Overlap(geoDir, run):
		return fmt.Errorf("XRAY_GEODATA_DIR (%s) overlaps XRAY_SOURCE_DIR or XRAY_RUNTIME_DIR: point it at a directory of its own", geoDir)
	}
	return nil
}

// geodataPrepare links each pinned file XRAY_GEODATA_DIR holds, the pinned one
// or the one fetched for an earlier pin, into active/, fetches each that is
// not the pinned one when there is no proxy, and points Xray at active/. At
// start, before anything is resolved; start's own `xray run -test` then
// judges the files.
func geodataPrepare(proxy *url.URL) error {
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
			if dir == active || strings.HasPrefix(e.Name(), ".") {
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
			return hint(err)
		default:
			g.ready = sum == g.sha
			if err := os.Symlink(p, filepath.Join(active, g.name)); err != nil {
				return hint(err)
			}
		}
		if g.ready {
			continue
		}
		have := "the image's own"
		if sum != "" {
			have = "the one fetched for an earlier pin"
		}
		if proxy != nil {
			// The proxy is an inbound of the Xray yet to start.
			fmt.Fprintf(os.Stderr, "geodata: %s: starting on %s, and fetching the pinned one through XRAY_SUBSCRIPTION_PROXY once Xray runs\n", g.name, have)
			continue
		}
		tmp, err := geoGet(g, nil)
		if err != nil {
			fmt.Fprintf(os.Stderr, "geodata: %s: %v; starting on %s, and fetching it again once Xray runs\n", g.name, err, have)
			continue
		}
		if err := install(g, tmp); err != nil {
			return hint(err)
		}
		fmt.Fprintf(os.Stderr, "geodata: %s: fetched, its sha256 the pinned one\n", g.name)
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
	g.ready = true
	if err := os.Symlink(p, filepath.Join(geoDir, "active", g.name)); err != nil && !errors.Is(err, fs.ErrExist) {
		return err
	}
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
	return fmt.Sprintf("Xray tested it on another %s than the pinned one, not fetched yet: a rule naming a list only the pinned one has can't pass until it is. Set XRAY_GEOIP or XRAY_GEOSITE first, and such rules once it is fetched", strings.Join(names, " and "))
}

// refreshGeo fetches each pinned file that is not there yet and reports
// whether Xray is to restart: one was fetched, and `xray run -test` passed the
// running config on it, read from a directory of links beside active/. A
// file the test refuses is not fetched again till a restart.
func refreshGeo(src, run string, extra []string, proxy *url.URL) bool {
	tmps := map[*geoFile]string{}
	for _, g := range geo {
		if g.ready || g.failed {
			continue
		}
		tmp, err := geoFetch(g, proxy)
		if err != nil {
			fmt.Fprintf(os.Stderr, "geodata: %s: %v; Xray keeps the one it has\n", g.name, err)
			continue
		}
		tmps[g] = tmp
	}
	if len(tmps) == 0 {
		return false
	}
	defer func() {
		for _, t := range tmps {
			os.Remove(t) // gone already once installed
		}
	}()
	keep := func(err error) bool {
		fmt.Fprintf(os.Stderr, "geodata: %v; Xray keeps the one it has\n", err)
		return false
	}
	stage, err := os.MkdirTemp(geoDir, ".next-")
	if err != nil {
		return keep(fmt.Errorf("XRAY_GEODATA_DIR is not writable (%v)", envconf.Cause(err)))
	}
	defer os.RemoveAll(stage)
	for _, g := range geo {
		p, ok := tmps[g]
		if !ok {
			if p = filepath.Join(geoDir, g.name); !exists(p) {
				continue
			}
		}
		if err := os.Symlink(p, filepath.Join(stage, g.name)); err != nil {
			return keep(fmt.Errorf("XRAY_GEODATA_DIR is not writable (%v)", envconf.Cause(err)))
		}
	}
	configs, err := resolveDir(src)
	if err != nil {
		return keep(err)
	}
	if _, err := testConfig(run, extra, configs, "XRAY_LOCATION_ASSET="+stage); err != nil {
		for g := range tmps {
			g.failed = true
			fmt.Fprintf(os.Stderr, "geodata: %s: the pinned one fails the running config (%v); Xray keeps the one it has, and it is not fetched again till a restart\n", g.name, err)
		}
		return false
	}
	for g, t := range tmps {
		if err := install(g, t); err != nil {
			return keep(fmt.Errorf("%s could not be kept (%v)", g.name, envconf.Cause(err)))
		}
		fmt.Fprintf(os.Stderr, "geodata: %s: fetched, its sha256 the pinned one; restarting Xray on it\n", g.name)
	}
	return true
}

// geoFetch fetches through proxy first when it is set, and directly when that
// fails, into a temporary file in XRAY_GEODATA_DIR.
func geoFetch(g *geoFile, proxy *url.URL) (string, error) {
	if proxy != nil {
		p, err := geoGet(g, proxy)
		if err == nil {
			return p, nil
		}
		fmt.Fprintf(os.Stderr, "geodata: %s: through XRAY_SUBSCRIPTION_PROXY: %v\n", g.name, err)
	}
	return geoGet(g, nil)
}

// geoGet GETs the pinned URL, following redirects, and keeps the body only
// when its sha256 is the pinned one.
func geoGet(g *geoFile, proxy *url.URL) (_ string, err error) {
	tr := &http.Transport{Proxy: nil, ForceAttemptHTTP2: true, TLSHandshakeTimeout: geoConnect,
		DialContext: (&net.Dialer{Timeout: geoConnect}).DialContext}
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
	n, err := io.Copy(io.MultiWriter(f, h), io.LimitReader(resp.Body, geoMax+1))
	switch {
	case err != nil:
		return "", fmt.Errorf("could not be read (%v)", err)
	case n > geoMax:
		err = fmt.Errorf("its URL serves more than %d bytes", geoMax)
		return "", err
	}
	if sum := hex.EncodeToString(h.Sum(nil)); sum != g.sha {
		err = fmt.Errorf("its URL serves a file whose sha256 is %s, not the pinned %s", sum, g.sha)
		return "", err
	}
	if err = f.Close(); err != nil {
		return "", fmt.Errorf("could not be written (%v)", err)
	}
	return f.Name(), nil
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
