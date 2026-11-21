package main

import (
	"crypto/sha256"
	"encoding/hex"
	"net/http"
	"net/http/httptest"
	"os"
	"path/filepath"
	"strings"
	"testing"
)

func sha(s string) string {
	h := sha256.Sum256([]byte(s))
	return hex.EncodeToString(h[:])
}

// A server that serves body at /geosite.dat, 404 elsewhere; closed, with
// gone, so a fetch fails.
func geoServer(t *testing.T, body string) *httptest.Server {
	t.Helper()
	srv := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		switch r.URL.Path {
		case "/geosite.dat":
			_, _ = w.Write([]byte(body))
		case "/moved":
			http.Redirect(w, r, "/geosite.dat", http.StatusFound)
		default:
			http.NotFound(w, r)
		}
	}))
	t.Cleanup(srv.Close)
	return srv
}

// geoSetup sets XRAY_GEOSITE to url and the sha256 of want, with a fresh
// XRAY_GEODATA_DIR, and reads the settings.
func geoSetup(t *testing.T, url, want string) string {
	t.Helper()
	dir := filepath.Join(t.TempDir(), "geodata")
	t.Setenv("XRAY_GEOIP", "")
	t.Setenv("XRAY_GEOSITE", url+" "+sha(want))
	t.Setenv("XRAY_GEODATA_DIR", dir)
	t.Setenv("XRAY_LOCATION_ASSET", "")
	if err := geodataSettings("/etc/xray", "/run/xray"); err != nil {
		t.Fatal(err)
	}
	t.Cleanup(func() { geo, geoDir = nil, "" })
	return dir
}

func read(t *testing.T, p string) string {
	t.Helper()
	b, err := os.ReadFile(p)
	if err != nil {
		t.Fatal(err)
	}
	return string(b)
}

func TestGeodataSettings(t *testing.T) {
	good := "https://cdn.example/geosite.dat " + sha("x")
	for _, c := range []struct{ geoip, geosite, dir, asset, want string }{
		{"", "", "", "", ""},
		{"", good, "/var/lib/xray/geodata", "", ""},
		{good, good, "/var/lib/xray/geodata", "", ""},
		{"", "https://cdn.example/geosite.dat", "/var/lib/xray/geodata", "", "is not \"<url> <sha256>\""},
		{"", "ftp://cdn.example/g " + sha("x"), "/var/lib/xray/geodata", "", "http or https URL"},
		{"", "https://cdn.example/g abc", "/var/lib/xray/geodata", "", "64 hex digits"},
		{"", good, "", "", "need XRAY_GEODATA_DIR"},
		{"", good, "/var/lib/xray/geodata", "/usr/local/share/xray", "XRAY_LOCATION_ASSET is set"},
		{"", good, "/run/xray/geodata", "", "overlaps"},
		{"", good, "/etc", "", "overlaps"},
	} {
		t.Setenv("XRAY_GEOIP", c.geoip)
		t.Setenv("XRAY_GEOSITE", c.geosite)
		t.Setenv("XRAY_GEODATA_DIR", c.dir)
		t.Setenv("XRAY_LOCATION_ASSET", c.asset)
		err := geodataSettings("/etc/xray", "/run/xray")
		t.Cleanup(func() { geo, geoDir = nil, "" })
		if (c.want == "") != (err == nil) || (err != nil && !strings.Contains(err.Error(), c.want)) {
			t.Errorf("%q %q %q %q: %v, want %q", c.geoip, c.geosite, c.dir, c.asset, err, c.want)
		}
	}
	t.Setenv("XRAY_GEOSITE", "https://cdn.example/g "+strings.ToUpper(sha("x")))
	t.Setenv("XRAY_GEODATA_DIR", "/var/lib/xray/geodata")
	t.Setenv("XRAY_LOCATION_ASSET", "")
	if err := geodataSettings("/etc/xray", "/run/xray"); err != nil || len(geo) != 1 || geo[0].sha != sha("x") || geo[0].name != "geosite.dat" {
		t.Fatalf("an upper-case sha256: %v, %+v", err, geo)
	}
}

func TestGeoGetKeepsOnlyThePinnedFile(t *testing.T) {
	srv := geoServer(t, "pinned data")
	dir := geoSetup(t, srv.URL+"/moved", "pinned data")
	if err := os.MkdirAll(dir, 0o700); err != nil {
		t.Fatal(err)
	}
	p, err := geoGet(geo[0], nil)
	if err != nil || read(t, p) != "pinned data" {
		t.Fatalf("through a redirect: %v", err)
	}
	os.Remove(p)

	for _, c := range []struct{ path, want string }{
		{"/geosite.dat", ""},
		{"/nope", "answered 404"},
	} {
		geo[0].url = srv.URL + c.path
		p, err := geoGet(geo[0], nil)
		if c.want == "" {
			os.Remove(p)
			continue
		}
		if err == nil || !strings.Contains(err.Error(), c.want) {
			t.Errorf("%s: %v, want %q", c.path, err, c.want)
		}
	}
	geo[0].url, geo[0].sha = srv.URL+"/geosite.dat", sha("other data")
	if _, err := geoGet(geo[0], nil); err == nil || !strings.Contains(err.Error(), "not the pinned "+sha("other data")) {
		t.Fatalf("another sha256: %v", err)
	}
	geo[0].sha = sha("pinned data")
	defer func(m int64) { geoMax = m }(geoMax)
	geoMax = 4
	if _, err := geoGet(geo[0], nil); err == nil || !strings.Contains(err.Error(), "more than 4 bytes") {
		t.Fatalf("too large: %v", err)
	}
	if left, _ := os.ReadDir(dir); len(left) != 0 {
		t.Fatalf("a refused fetch left %v", left)
	}
}

func TestGeodataPrepare(t *testing.T) {
	srv := geoServer(t, "pinned data")
	dir := geoSetup(t, srv.URL+"/geosite.dat", "pinned data")
	// What a fetch, a test and an earlier pin of geoip.dat left.
	for _, p := range []string{".geosite.dat-123", ".next-1/geosite.dat", "active/geoip.dat"} {
		if err := os.MkdirAll(filepath.Dir(filepath.Join(dir, p)), 0o700); err != nil {
			t.Fatal(err)
		}
		if err := os.WriteFile(filepath.Join(dir, p), nil, 0o600); err != nil {
			t.Fatal(err)
		}
	}
	if err := geodataPrepare(nil); err != nil {
		t.Fatal(err)
	}
	active := filepath.Join(dir, "active")
	if os.Getenv("XRAY_LOCATION_ASSET") != active || !geo[0].ready || geoWaiting() || geoHint() != "" {
		t.Fatalf("after a fetch at start: %s, %+v", os.Getenv("XRAY_LOCATION_ASSET"), geo[0])
	}
	if read(t, filepath.Join(active, "geosite.dat")) != "pinned data" {
		t.Fatal("active/geosite.dat is not the fetched file")
	}
	entries, _ := os.ReadDir(dir)
	if len(entries) != 2 || exists(filepath.Join(active, "geoip.dat")) {
		t.Fatalf("leftovers kept: %v", entries)
	}

	// A new pin, its URL unreachable: the earlier pin's file stays in use.
	srv.Close()
	t.Setenv("XRAY_GEOSITE", srv.URL+"/geosite.dat "+sha("new data"))
	t.Setenv("XRAY_LOCATION_ASSET", "")
	if err := geodataSettings("/etc/xray", "/run/xray"); err != nil {
		t.Fatal(err)
	}
	if err := geodataPrepare(nil); err != nil {
		t.Fatal(err)
	}
	if geo[0].ready || !geoWaiting() || !strings.Contains(geoHint(), "another geosite.dat than the pinned one") {
		t.Fatalf("an earlier pin's file: %+v, %q", geo[0], geoHint())
	}
	if read(t, filepath.Join(active, "geosite.dat")) != "pinned data" {
		t.Fatal("the earlier pin's file is not linked")
	}
	if next(subSettings{interval: 3600e9}) != subRetry {
		t.Fatal("a file still to fetch is not retried sooner")
	}
}

// A stand-in xray whose -test passes only on the geosite.dat it is to accept.
func fakeXray(t *testing.T, accept string) {
	t.Helper()
	bin := filepath.Join(t.TempDir(), "xray")
	script := "#!/bin/sh\n[ \"$(cat \"$XRAY_LOCATION_ASSET/geosite.dat\")\" = '" + accept + "' ] && echo 'Xray 0.0.0' && exit 0\necho 'failed to check code WHITELIST'; exit 1\n"
	if err := os.WriteFile(bin, []byte(script), 0o755); err != nil {
		t.Fatal(err)
	}
	old := img.Bin
	img.Bin = bin
	t.Cleanup(func() { img.Bin = old })
}

func TestRefreshGeoTestsBeforeInstalling(t *testing.T) {
	src, run := t.TempDir(), t.TempDir()
	if err := os.WriteFile(filepath.Join(src, "10.json"), []byte(`{"log": {}}`), 0o600); err != nil {
		t.Fatal(err)
	}
	body := "pinned data"
	srv := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		_, _ = w.Write([]byte(body))
	}))
	defer srv.Close()
	dir := geoSetup(t, srv.URL, "pinned data")
	if err := os.MkdirAll(dir, 0o700); err != nil {
		t.Fatal(err)
	}
	if err := os.WriteFile(filepath.Join(dir, "geosite.dat"), []byte("earlier data"), 0o600); err != nil {
		t.Fatal(err)
	}
	body = "not served yet"
	if err := geodataPrepare(nil); err != nil {
		t.Fatal(err)
	}

	fakeXray(t, "pinned data")
	body = "pinned data"
	if !refreshGeo(src, run, nil, nil) || !geo[0].ready {
		t.Fatalf("a fetched file the test passes: no restart, %+v", geo[0])
	}
	if read(t, filepath.Join(dir, "active", "geosite.dat")) != "pinned data" {
		t.Fatal("not installed")
	}
	if refreshGeo(src, run, nil, nil) {
		t.Fatal("a restart with nothing fetched")
	}

	// A pinned file the running config fails on: kept out, and not fetched
	// again.
	fakeXray(t, "pinned data")
	t.Setenv("XRAY_GEOSITE", srv.URL+" "+sha("refused data"))
	t.Setenv("XRAY_LOCATION_ASSET", "")
	if err := geodataSettings("/etc/xray", "/run/xray"); err != nil {
		t.Fatal(err)
	}
	if err := geodataPrepare(nil); err != nil {
		t.Fatal(err)
	}
	body = "refused data"
	if refreshGeo(src, run, nil, nil) || !geo[0].failed || geoWaiting() {
		t.Fatalf("a file the test refuses: %+v", geo[0])
	}
	if read(t, filepath.Join(dir, "active", "geosite.dat")) != "pinned data" {
		t.Fatal("the refused file replaced the one in use")
	}
	if entries, _ := os.ReadDir(dir); len(entries) != 2 {
		t.Fatalf("leftovers: %v", entries)
	}
}
