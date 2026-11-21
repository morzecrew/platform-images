package main

import (
	"crypto/sha256"
	"encoding/hex"
	"net/http"
	"net/http/httptest"
	"net/url"
	"os"
	"path/filepath"
	"strings"
	"testing"
	"time"
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
		{"", "https://u:p@cdn.example/g " + sha("x"), "/var/lib/xray/geodata", "", "holds a login or a query"},
		{"", "https://cdn.example/g?token=t " + sha("x"), "/var/lib/xray/geodata", "", "holds a login or a query"},
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
	t.Setenv("XRAY_GEODATA_DIR", "geodata")
	if err := geodataSettings("/etc/xray", "/run/xray"); err != nil || !filepath.IsAbs(geoDir) {
		t.Fatalf("a relative XRAY_GEODATA_DIR: %v, %s", err, geoDir)
	}
	t.Setenv("XRAY_GEODATA_DIR", "/var/lib/xray/geodata")
	for cache, want := range map[string]string{"/var/lib/xray": "", "/var/lib/xray/geodata/active/c": "every start empties"} {
		t.Setenv("XRAY_SUBSCRIPTION_CACHE", cache)
		err := geodataSettings("/etc/xray", "/run/xray")
		if (want == "") != (err == nil) || (err != nil && !strings.Contains(err.Error(), want)) {
			t.Errorf("cache %s: %v", cache, err)
		}
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
			if err != nil {
				t.Errorf("%s: %v", c.path, err)
			}
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
	// Counted: nothing is fetched at start.
	n := 0
	srv := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) { n++ }))
	defer srv.Close()
	dir := geoSetup(t, srv.URL+"/geosite.dat", "pinned data")
	// What a fetch, a test and an earlier pin of geoip.dat left, and a dot
	// file that is not the entrypoint's.
	for _, p := range []string{".geosite.dat-123", ".next-1/geosite.dat", "active/geoip.dat", ".keep"} {
		if err := os.MkdirAll(filepath.Dir(filepath.Join(dir, p)), 0o700); err != nil {
			t.Fatal(err)
		}
		if err := os.WriteFile(filepath.Join(dir, p), nil, 0o600); err != nil {
			t.Fatal(err)
		}
	}
	if err := geodataPrepare(); err != nil {
		t.Fatal(err)
	}
	active := filepath.Join(dir, "active")
	if os.Getenv("XRAY_LOCATION_ASSET") != active || geo[0].ready || !geoWaiting() || n != 0 {
		t.Fatalf("with nothing kept: %s, %+v, %d requests", os.Getenv("XRAY_LOCATION_ASSET"), geo[0], n)
	}
	if !strings.Contains(geoHint(), "another geosite.dat than the pinned one") || exists(filepath.Join(active, "geosite.dat")) {
		t.Fatalf("with nothing kept, Xray's own: %q", geoHint())
	}
	if entries, _ := os.ReadDir(dir); len(entries) != 2 || exists(filepath.Join(active, "geoip.dat")) {
		t.Fatalf("leftovers kept, or .keep removed: %v", entries)
	}
	if next(subSettings{interval: 3600e9}) != subRetry {
		t.Fatal("a file still to fetch is not retried sooner")
	}

	// Kept: linked, and ready.
	if err := os.WriteFile(filepath.Join(dir, "geosite.dat"), []byte("pinned data"), 0o600); err != nil {
		t.Fatal(err)
	}
	t.Setenv("XRAY_LOCATION_ASSET", "")
	if err := geodataSettings("/etc/xray", "/run/xray"); err != nil {
		t.Fatal(err)
	}
	if err := geodataPrepare(); err != nil || !geo[0].ready || geoWaiting() || geoHint() != "" {
		t.Fatalf("kept: %v, %+v", err, geo[0])
	}
	if read(t, filepath.Join(active, "geosite.dat")) != "pinned data" {
		t.Fatal("active/geosite.dat is not the kept file")
	}

	// A new pin: the earlier pin's file stays in use till the new one is
	// fetched.
	t.Setenv("XRAY_GEOSITE", srv.URL+"/geosite.dat "+sha("new data"))
	t.Setenv("XRAY_LOCATION_ASSET", "")
	if err := geodataSettings("/etc/xray", "/run/xray"); err != nil {
		t.Fatal(err)
	}
	if err := geodataPrepare(); err != nil || geo[0].ready || !geoWaiting() || n != 0 {
		t.Fatalf("an earlier pin's file: %v, %+v", err, geo[0])
	}
	if read(t, filepath.Join(active, "geosite.dat")) != "pinned data" {
		t.Fatal("the earlier pin's file is not linked")
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
	run := t.TempDir()
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
	if err := geodataPrepare(); err != nil {
		t.Fatal(err)
	}

	fakeXray(t, "pinned data")
	body = "pinned data"
	if !refreshGeo(run, nil, nil) || !geo[0].ready {
		t.Fatalf("a fetched file the test passes: no restart, %+v", geo[0])
	}
	if read(t, filepath.Join(dir, "active", "geosite.dat")) != "pinned data" {
		t.Fatal("not installed")
	}
	if refreshGeo(run, nil, nil) {
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
	if err := geodataPrepare(); err != nil {
		t.Fatal(err)
	}
	body = "refused data"
	if refreshGeo(run, nil, nil) || !geo[0].failed || geoWaiting() {
		t.Fatalf("a file the test refuses: %+v", geo[0])
	}
	if read(t, filepath.Join(dir, "active", "geosite.dat")) != "pinned data" {
		t.Fatal("the refused file replaced the one in use")
	}
	if entries, _ := os.ReadDir(dir); len(entries) != 2 {
		t.Fatalf("leftovers: %v", entries)
	}
}

// A URL serving another file is final: not fetched again, nor directly after
// the proxy, which here is the same server, counting requests.
func TestRefreshGeoGivesUpOnAnotherFile(t *testing.T) {
	n := 0
	srv := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		n++
		_, _ = w.Write([]byte("moved on"))
	}))
	defer srv.Close()
	geoSetup(t, srv.URL+"/geosite.dat", "pinned data")
	if err := geodataPrepare(); err != nil {
		t.Fatal(err)
	}
	proxy, _ := url.Parse(srv.URL)
	if refreshGeo(t.TempDir(), nil, proxy) || !geo[0].failed || geoWaiting() || n != 1 {
		t.Fatalf("another file: %+v, %d requests", geo[0], n)
	}
	if refreshGeo(t.TempDir(), nil, proxy) || n != 1 {
		t.Fatalf("fetched again: %d requests", n)
	}
}

func TestGeoGetGivesUpOnAStall(t *testing.T) {
	release := make(chan struct{})
	srv := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		_, _ = w.Write([]byte("a start"))
		w.(http.Flusher).Flush()
		<-release
	}))
	defer srv.Close()
	defer close(release)
	dir := geoSetup(t, srv.URL+"/geosite.dat", "pinned data")
	if err := os.MkdirAll(dir, 0o700); err != nil {
		t.Fatal(err)
	}
	defer func(d time.Duration) { geoIdle = d }(geoIdle)
	geoIdle = 200 * time.Millisecond
	if _, err := geoGet(geo[0], nil); err == nil || !strings.Contains(err.Error(), "stalled") {
		t.Fatalf("a stall: %v", err)
	}
}

// A failed fetch's error names its cause, never the URL and its query.
func TestGeoGetKeepsTheURLOutOfErrors(t *testing.T) {
	srv := httptest.NewServer(http.NotFoundHandler())
	gone := srv.URL
	srv.Close()
	dir := geoSetup(t, gone+"/0123456789secret/geosite.dat", "pinned data")
	if err := os.MkdirAll(dir, 0o700); err != nil {
		t.Fatal(err)
	}
	_, err := geoGet(geo[0], nil)
	if err == nil || strings.Contains(err.Error(), "secret") || strings.Contains(err.Error(), gone) {
		t.Fatalf("an unreachable URL: %v", err)
	}
}

// A file kept but not linked is not ready, so it is fetched and linked again.
func TestInstallIsReadyOnlyOnceLinked(t *testing.T) {
	if os.Geteuid() == 0 {
		t.Skip("root writes a read-only directory")
	}
	dir := geoSetup(t, "https://cdn.example/geosite.dat", "pinned data")
	active := filepath.Join(dir, "active")
	if err := os.MkdirAll(active, 0o700); err != nil {
		t.Fatal(err)
	}
	if err := os.Chmod(active, 0o500); err != nil {
		t.Fatal(err)
	}
	defer os.Chmod(active, 0o700)
	tmp := filepath.Join(dir, ".geosite.dat-1")
	if err := os.WriteFile(tmp, []byte("pinned data"), 0o600); err != nil {
		t.Fatal(err)
	}
	if err := install(geo[0], tmp); err == nil || geo[0].ready {
		t.Fatalf("unlinked: %v, %+v", err, geo[0])
	}
}

// A cache reached through a symlink into active/ is refused too.
func TestGeodataSettingsFollowSymlinks(t *testing.T) {
	root := t.TempDir()
	dir := filepath.Join(root, "geodata")
	if err := os.MkdirAll(filepath.Join(dir, "active", "c"), 0o700); err != nil {
		t.Fatal(err)
	}
	if err := os.Symlink(filepath.Join(dir, "active", "c"), filepath.Join(root, "cache")); err != nil {
		t.Fatal(err)
	}
	t.Setenv("XRAY_GEOIP", "")
	t.Setenv("XRAY_GEOSITE", "https://cdn.example/g "+sha("x"))
	t.Setenv("XRAY_GEODATA_DIR", dir)
	t.Setenv("XRAY_LOCATION_ASSET", "")
	t.Setenv("XRAY_SUBSCRIPTION_CACHE", filepath.Join(root, "cache"))
	t.Cleanup(func() { geo, geoDir = nil, "" })
	if err := geodataSettings("/etc/xray", "/run/xray"); err == nil || !strings.Contains(err.Error(), "every start empties") {
		t.Fatalf("a cache through a symlink into active/: %v", err)
	}
}

// Directly, after the proxy failed, a wrong file (a block page) is not final.
func TestGeoFetchDirectWrongFileIsNotFinal(t *testing.T) {
	srv := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		_, _ = w.Write([]byte("blocked"))
	}))
	defer srv.Close()
	closed := httptest.NewServer(http.NotFoundHandler())
	closed.Close()
	geoSetup(t, srv.URL+"/geosite.dat", "pinned data")
	if err := geodataPrepare(); err != nil {
		t.Fatal(err)
	}
	proxy, _ := url.Parse(closed.URL)
	if refreshGeo(t.TempDir(), nil, proxy) || geo[0].failed || !geoWaiting() {
		t.Fatalf("a wrong file directly, the proxy down: %+v", geo[0])
	}
}

// Each file is tested alone beside the files in use: a good geoip.dat is
// installed though the geosite.dat fetched with it fails, and a test that was
// killed blames neither.
func TestRefreshGeoTestsEachFileAlone(t *testing.T) {
	srv := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		_, _ = w.Write([]byte(strings.TrimPrefix(r.URL.Path, "/")))
	}))
	defer srv.Close()
	dir := filepath.Join(t.TempDir(), "geodata")
	t.Setenv("XRAY_GEOIP", srv.URL+"/good "+sha("good"))
	t.Setenv("XRAY_GEOSITE", srv.URL+"/bad "+sha("bad"))
	t.Setenv("XRAY_GEODATA_DIR", dir)
	t.Setenv("XRAY_LOCATION_ASSET", "")
	t.Cleanup(func() { geo, geoDir = nil, "" })
	if err := geodataSettings("/etc/xray", "/run/xray"); err != nil {
		t.Fatal(err)
	}
	if err := geodataPrepare(); err != nil {
		t.Fatal(err)
	}
	stub := func(script string) {
		bin := filepath.Join(t.TempDir(), "xray")
		if err := os.WriteFile(bin, []byte("#!/bin/sh\n"+script), 0o755); err != nil {
			t.Fatal(err)
		}
		old := img.Bin
		img.Bin = bin
		t.Cleanup(func() { img.Bin = old })
	}
	stub("kill -9 $$\n")
	if refreshGeo(t.TempDir(), nil, nil) || geo[0].failed || geo[1].failed || !geoWaiting() {
		t.Fatalf("a killed test: %+v %+v", geo[0], geo[1])
	}
	stub("[ \"$(cat \"$XRAY_LOCATION_ASSET/geosite.dat\" 2>/dev/null)\" != bad ] && exit 0\necho 'failed to check code X'; exit 1\n")
	if !refreshGeo(t.TempDir(), nil, nil) || !geo[0].ready || geo[0].failed || !geo[1].failed || geo[1].ready {
		t.Fatalf("a good geoip.dat beside a bad geosite.dat: %+v %+v", geo[0], geo[1])
	}
	if read(t, filepath.Join(dir, "active", "geoip.dat")) != "good" || exists(filepath.Join(dir, "active", "geosite.dat")) {
		t.Fatal("not the good one alone in use")
	}
}
