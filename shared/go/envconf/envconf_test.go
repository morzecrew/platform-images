package envconf

import (
	"bytes"
	"io"
	"net/http"
	"net/http/httptest"
	"os"
	"path/filepath"
	"strings"
	"testing"
)

var demo = &Image{
	Name: "demo", Title: "Demo", Bin: "/usr/local/bin/demo", Prefix: "DEMO_", Readme: "images/demo/README.md",
	Settings: []Setting{
		{"DEMO_SOURCE_DIR", "/etc/demo"},
		{"DEMO_HEALTHCHECK_URL", "https://www.gstatic.com/generate_204"},
		{"DEMO_HEALTHCHECK_PROXY", ""},
		{"DEMO_HEALTHCHECK_TIMEOUT", "10s"},
		{"DEMO_HEALTHCHECK_EXPECT", ""},
	},
	Upstream: map[string]bool{"DEMO_OWN": true},
}

// Both reference forms the tests resolve: $file, and one whose value is not
// a string and is not secret.
var refs = []Reference{File, {"$count", func(string) (Resolution, error) {
	return Resolution{Value: []any{1, 2}, Note: "(2 items)"}, nil
}}}

func write(t *testing.T, path, content string, mode os.FileMode) string {
	t.Helper()
	if err := os.WriteFile(path, []byte(content), mode); err != nil {
		t.Fatal(err)
	}
	return path
}

// stderr runs f and returns what it wrote to os.Stderr.
func stderr(t *testing.T, f func()) string {
	t.Helper()
	r, w, err := os.Pipe()
	if err != nil {
		t.Fatal(err)
	}
	// Read while f runs: a pipe holds 64 KiB, and f would block on more.
	out := make(chan string)
	go func() {
		b, _ := io.ReadAll(r)
		out <- string(b)
	}()
	old := os.Stderr
	os.Stderr = w
	f()
	w.Close()
	os.Stderr = old
	return <-out
}

func TestResolveReplacesReferencesAndNothingElse(t *testing.T) {
	dir := t.TempDir()
	uuid := write(t, filepath.Join(dir, "uuid"), "6b0c7f3e-3c3a-4f43-9a63-1f0b3d1c2e77\n", 0o400)
	key := write(t, filepath.Join(dir, "key"), "line1\nline2\n\n", 0o400)
	src := write(t, filepath.Join(dir, "in.json"), `{
		"n": 12345678901234567890,
		"s": "<&>",
		"literal": {"file": "/not/a/reference"},
		"inbounds": [{"settings": {"clients": [{"id": {"$file": "`+uuid+`"}}], "decryption": {"$file": "`+key+`"}}}],
		"list": {"$count": "/any"}
	}`, 0o600)

	c, err := ResolveFile(src, refs)
	if err != nil {
		t.Fatal(err)
	}
	want := `{"inbounds":[{"settings":{"clients":[{"id":"6b0c7f3e-3c3a-4f43-9a63-1f0b3d1c2e77"}],"decryption":"line1\nline2\n"}}],"list":[1,2],"literal":{"file":"/not/a/reference"},"n":12345678901234567890,"s":"<&>"}` + "\n"
	if string(c.Out) != want {
		t.Errorf("resolved\n got %s\nwant %s", c.Out, want)
	}
	wantRefs := []Ref{
		{"inbounds[0].settings.clients[0].id", "$file", uuid, ""},
		{"inbounds[0].settings.decryption", "$file", key, ""},
		{"list", "$count", "/any", "(2 items)"},
	}
	if len(c.Refs) != 3 || c.Refs[0] != wantRefs[0] || c.Refs[1] != wantRefs[1] || c.Refs[2] != wantRefs[2] {
		t.Errorf("refs = %v, want %v", c.Refs, wantRefs)
	}
	if len(c.Values) != 2 || c.Values[0] != "6b0c7f3e-3c3a-4f43-9a63-1f0b3d1c2e77" {
		t.Errorf("values = %q", c.Values)
	}
	if m, ok := c.Doc.(map[string]any); !ok || m["s"] != "<&>" {
		t.Errorf("doc = %v", c.Doc)
	}
}

func TestResolveRefusals(t *testing.T) {
	dir := t.TempDir()
	const secret = "s3cret-value"
	ok := write(t, filepath.Join(dir, "ok"), secret, 0o400)
	big := write(t, filepath.Join(dir, "big"), strings.Repeat("a", MaxSecret+1), 0o400)
	exact := write(t, filepath.Join(dir, "exact"), strings.Repeat("a", MaxSecret), 0o400)
	nul := write(t, filepath.Join(dir, "nul"), secret+"\x00", 0o400)
	latin1 := write(t, filepath.Join(dir, "latin1"), secret+"\xe9", 0o400)
	subdir := filepath.Join(dir, "subdir")
	if err := os.Mkdir(subdir, 0o700); err != nil {
		t.Fatal(err)
	}

	for _, tc := range []struct {
		name, doc, want string
	}{
		{"missing", `{"a": {"$file": "` + dir + `/missing"}}`, "a: " + dir + "/missing does not exist"},
		{"directory", `{"a": [{"$file": "` + subdir + `"}]}`, "a[0]: " + subdir + " is a directory"},
		{"relative", `{"a": {"$file": "rel/path"}}`, `a: "$file" must be an absolute path`},
		{"not a string", `{"a": {"$file": 1}}`, `a: "$file" must be an absolute path`},
		{"other keys", `{"a": {"$file": "` + ok + `", "other": 1, "b": 2}}`, `a: an object holding "$file" holds nothing else, and this one also holds b, other`},
		{"two reference keys", `{"a": {"$count": "/x", "$file": "` + ok + `"}}`, `an object holding "$file" holds nothing else, and this one also holds $count`},
		{"top level", `{"$file": "` + ok + `", "x": 1}`, "the top level: an object"},
		{"too big", `{"a": {"$file": "` + big + `"}}`, "is larger than 65536 bytes"},
		{"NUL", `{"a": {"$file": "` + nul + `"}}`, "contains a NUL byte"},
		{"not UTF-8", `{"a": {"$file": "` + latin1 + `"}}`, "is not valid UTF-8"},
		{"comment", "{\"a\": 1 // no\n}", "is not valid JSON"},
		{"two values", `{"a": 1} {"b": 2}`, "something follows its value"},
	} {
		t.Run(tc.name, func(t *testing.T) {
			src := write(t, filepath.Join(dir, "c.json"), tc.doc, 0o600)
			_, err := ResolveFile(src, refs)
			if err == nil {
				t.Fatal("resolved; want a refusal")
			}
			if !strings.Contains(err.Error(), tc.want) || !strings.HasPrefix(err.Error(), src) {
				t.Errorf("error %q\nwant it to start with %s and contain %q", err, src, tc.want)
			}
			if strings.Contains(err.Error(), secret) {
				t.Errorf("error %q carries the secret", err)
			}
		})
	}

	src := write(t, filepath.Join(dir, "c.json"), `{"a": {"$file": "`+exact+`"}}`, 0o600)
	if _, err := ResolveFile(src, refs); err != nil {
		t.Errorf("a file of exactly %d bytes: %v", MaxSecret, err)
	}
}

func TestUnreadableReference(t *testing.T) {
	if os.Geteuid() == 0 {
		t.Skip("root reads a 000 file")
	}
	dir := t.TempDir()
	locked := write(t, filepath.Join(dir, "locked"), "x", 0o000)
	src := write(t, filepath.Join(dir, "c.json"), `{"a": {"$file": "`+locked+`"}}`, 0o600)
	if _, err := ResolveFile(src, refs); err == nil || !strings.Contains(err.Error(), locked+" is not readable by uid") {
		t.Errorf("err = %v", err)
	}
}

func TestRedact(t *testing.T) {
	got := Redact("invalid UUID: abc-123, then abc", []string{"abc", "abc-123", ""})
	if got != "invalid UUID: <redacted>, then <redacted>" {
		t.Errorf("redact = %q", got)
	}
}

func TestSummaryNamesPathsNotValues(t *testing.T) {
	t.Setenv("DEMO_HEALTHCHECK_PROXY", "http://probe:pw@127.0.0.1:10809")
	c := &Config{Src: "/etc/demo/10.json", Refs: []Ref{{"a.id", "$file", "/run/secrets/id", ""}, {"b.clients", "$count", "/run/secrets/clients", "(2 clients)"}}, Values: []string{"the-id"}}
	var b bytes.Buffer
	demo.Summary(&b, "Demo 1.2.3", []*Config{c})
	out := b.String()
	for _, want := range []string{
		"[envconf] demo: effective configuration",
		"source=env-or-default DEMO_SOURCE_DIR = /etc/demo",
		"demo = Demo 1.2.3",
		"source=config         /etc/demo/10.json",
		"a.id <- /run/secrets/id   (/etc/demo/10.json)",
		"b.clients <- $count /run/secrets/clients (2 clients)   (/etc/demo/10.json)",
		"DEMO_HEALTHCHECK_PROXY = http://probe:xxxxx@127.0.0.1:10809",
		"DEMO_HEALTHCHECK_EXPECT = (unset: any 2xx passes)",
		"[envconf] precedence: image default < environment",
	} {
		if !strings.Contains(out, want) {
			t.Errorf("summary lacks %q:\n%s", want, out)
		}
	}
	if strings.Contains(out, "the-id") || strings.Contains(out, ":pw@") {
		t.Errorf("summary carries a value:\n%s", out)
	}
	t.Setenv("DEMO_HEALTHCHECK_PROXY", "")
	b.Reset()
	demo.Summary(&b, "Demo 1.2.3", nil)
	if want := "DEMO_HEALTHCHECK_PROXY = (unset: the healthcheck checks only that Demo is running)"; !strings.Contains(b.String(), want) {
		t.Errorf("summary lacks %q:\n%s", want, b.String())
	}
}

func TestWarnUnknown(t *testing.T) {
	t.Setenv("DEMO_SOURCE_DRI", "/etc/demo")
	t.Setenv("DEMO_CONF__LOG", "debug")
	t.Setenv("DEMO_OWN", "1")
	t.Setenv("DEMO_SOURCE_DIR", "/etc/demo")
	out := stderr(t, demo.WarnUnknown)
	for _, want := range []string{
		"WARN: DEMO_SOURCE_DRI is set but neither this image nor Demo reads it. Check the spelling against images/demo/README.md.",
		"WARN: DEMO_CONF__LOG is set, but this image has no DEMO_CONF__ passthrough channel. Demo is configured by the JSON in DEMO_SOURCE_DIR",
	} {
		if !strings.Contains(out, want) {
			t.Errorf("stderr lacks %q:\n%s", want, out)
		}
	}
	if strings.Contains(out, "DEMO_OWN") || strings.Contains(out, "DEMO_SOURCE_DIR is set") {
		t.Errorf("warned about an upstream or curated name:\n%s", out)
	}
}

func TestHealthSettings(t *testing.T) {
	for _, tc := range []struct{ name, value, want string }{
		{"DEMO_HEALTHCHECK_URL", "ftp://example.com/", "DEMO_HEALTHCHECK_URL must be"},
		{"DEMO_HEALTHCHECK_URL", "/generate_204", "DEMO_HEALTHCHECK_URL must be"},
		{"DEMO_HEALTHCHECK_TIMEOUT", "10", "not a duration"},
		{"DEMO_HEALTHCHECK_TIMEOUT", "-1s", "not a duration"},
		{"DEMO_HEALTHCHECK_PROXY", "127.0.0.1:10809", "DEMO_HEALTHCHECK_PROXY must be"},
		{"DEMO_HEALTHCHECK_PROXY", "vless://127.0.0.1:443", "DEMO_HEALTHCHECK_PROXY must be"},
		{"DEMO_HEALTHCHECK_EXPECT", `^203\.0\.113\.(7\s*$`, "DEMO_HEALTHCHECK_EXPECT is not a regular expression"},
		// RE2 has no lookahead, which a PCRE habit reaches for.
		{"DEMO_HEALTHCHECK_EXPECT", `^(?!10\.)`, "DEMO_HEALTHCHECK_EXPECT is not a regular expression"},
	} {
		t.Run(tc.name+"="+tc.value, func(t *testing.T) {
			t.Setenv(tc.name, tc.value)
			if _, err := demo.HealthSettings(); err == nil || !strings.Contains(err.Error(), tc.want) {
				t.Errorf("err = %v, want %q", err, tc.want)
			}
		})
	}
}

// The probe goes through the proxy, takes a 2xx as healthy, and stops at a
// redirect instead of following it.
func TestHealthcheckThroughProxy(t *testing.T) {
	var seen []string
	status := http.StatusNoContent
	proxy := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		seen = append(seen, r.URL.String())
		if status == http.StatusFound {
			w.Header().Set("Location", "http://portal.example/")
		}
		w.WriteHeader(status)
	}))
	defer proxy.Close()
	t.Setenv("DEMO_HEALTHCHECK_URL", "http://egress.example/generate_204")
	t.Setenv("DEMO_HEALTHCHECK_PROXY", proxy.URL)
	t.Setenv("DEMO_HEALTHCHECK_TIMEOUT", "5s")

	if rc := demo.Healthcheck("/nonexistent"); rc != 0 {
		t.Errorf("204: rc = %d", rc)
	}
	if len(seen) != 1 || seen[0] != "http://egress.example/generate_204" {
		t.Errorf("the proxy saw %v", seen)
	}
	status = http.StatusFound
	if rc := demo.Healthcheck("/nonexistent"); rc != 1 {
		t.Errorf("302: rc = %d", rc)
	}
	if len(seen) != 2 {
		t.Errorf("the redirect was followed: %v", seen)
	}
	proxy.Close()
	if rc := demo.Healthcheck("/nonexistent"); rc != 1 {
		t.Errorf("proxy down: rc = %d", rc)
	}
}

// #133: with <PREFIX>HEALTHCHECK_EXPECT set, a 2xx passes only when the first
// 64 KiB of the body match it, and a mismatch shows the start of the body.
func TestHealthcheckExpect(t *testing.T) {
	status, body := http.StatusOK, ""
	proxy := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		w.WriteHeader(status)
		io.WriteString(w, body)
	}))
	defer proxy.Close()
	t.Setenv("DEMO_HEALTHCHECK_URL", "http://ip.example/")
	t.Setenv("DEMO_HEALTHCHECK_PROXY", proxy.URL)
	t.Setenv("DEMO_HEALTHCHECK_TIMEOUT", "5s")
	const anchored, bare = `^203\.0\.113\.7\s*$`, `203\.0\.113\.7`
	pad := func(n int) string { return strings.Repeat(" ", n) }

	for _, tc := range []struct {
		name, expect string
		status       int
		body         string
		rc           int
		want         string
	}{
		{"match", anchored, 200, "203.0.113.7\n", 0, "matches DEMO_HEALTHCHECK_EXPECT"},
		{"anchored", anchored, 200, "203.0.113.71", 1, `does not match DEMO_HEALTHCHECK_EXPECT: "203.0.113.71"`},
		{"control characters escaped", anchored, 200, "198.51.100.9\r\n\x1b[2J", 1, `"198.51.100.9\r\n\x1b[2J"`},
		{"excerpt of 128 bytes", anchored, 200, strings.Repeat("x", 127) + "yz", 1, `"` + strings.Repeat("x", 127) + `y"`},
		{"match ending at 64 KiB", bare, 200, pad(MaxBody-11) + "203.0.113.7", 0, "matches"},
		{"match crossing 64 KiB", bare, 200, pad(MaxBody-10) + "203.0.113.7", 1, "does not match"},
		{"non-2xx with a matching body", anchored, 503, "203.0.113.7", 1, "503 Service Unavailable"},
	} {
		t.Run(tc.name, func(t *testing.T) {
			t.Setenv("DEMO_HEALTHCHECK_EXPECT", tc.expect)
			status, body = tc.status, tc.body
			var rc int
			out := stderr(t, func() { rc = demo.Healthcheck("/nonexistent") })
			if rc != tc.rc || !strings.Contains(out, tc.want) {
				t.Errorf("rc = %d, want %d; stderr %q, want %q", rc, tc.rc, out, tc.want)
			}
			if tc.status != 200 && strings.Contains(out, "DEMO_HEALTHCHECK_EXPECT") {
				t.Errorf("the body was checked after a %d: %q", tc.status, out)
			}
		})
	}
}

// Without a proxy the probe fetches nothing, so an expression would be a
// check that silently never runs.
func TestExpectWithoutProxyIsReported(t *testing.T) {
	t.Setenv("DEMO_HEALTHCHECK_EXPECT", `^203\.0\.113\.7$`)
	t.Setenv("DEMO_HEALTHCHECK_PROXY", "")
	if out := stderr(t, demo.WarnUnknown); !strings.Contains(out, "WARN: DEMO_HEALTHCHECK_EXPECT is set, but DEMO_HEALTHCHECK_PROXY is unset") {
		t.Errorf("stderr %q", out)
	}
	t.Setenv("DEMO_HEALTHCHECK_PROXY", "http://127.0.0.1:10809")
	if out := stderr(t, demo.WarnUnknown); strings.Contains(out, "DEMO_HEALTHCHECK_EXPECT") {
		t.Errorf("warned with a proxy set: %q", out)
	}
}

// Under go test, PID 1 is never the server, so liveness fails, and says why.
func TestLivenessWithoutProxy(t *testing.T) {
	t.Setenv("DEMO_HEALTHCHECK_PROXY", "")
	var rc int
	out := stderr(t, func() { rc = demo.Healthcheck("/nonexistent") })
	if rc != 1 || !strings.Contains(out, "healthcheck: PID 1 is not Demo") {
		t.Errorf("rc = %d, stderr %q", rc, out)
	}
}

func TestOverlap(t *testing.T) {
	root := t.TempDir()
	src := filepath.Join(root, "etc", "xray")
	if err := os.MkdirAll(src, 0o755); err != nil {
		t.Fatal(err)
	}
	if err := os.Symlink(src, filepath.Join(root, "alias")); err != nil {
		t.Fatal(err)
	}
	if err := os.Symlink(filepath.Join(root, "etc"), filepath.Join(root, "etc-link")); err != nil {
		t.Fatal(err)
	}
	for _, tc := range []struct {
		name, other string
		overlaps    bool
	}{
		{"the same directory", src + "/", true},
		{"a symlink alias", filepath.Join(root, "alias"), true},
		{"its parent", filepath.Join(root, "etc"), true},
		{"the root", "/", true},
		{"inside it", filepath.Join(src, "run"), true},
		{"inside it, through a symlink, not yet created", filepath.Join(root, "alias", "run", "xray"), true},
		{"its parent, through a symlink", filepath.Join(root, "etc-link"), true},
		{"a sibling", filepath.Join(root, "run", "xray"), false},
		{"a sibling sharing a prefix", src + "-run", false},
	} {
		t.Run(tc.name, func(t *testing.T) {
			if got := Overlap(src, tc.other); got != tc.overlaps {
				t.Errorf("Overlap(%s, %s) = %v", src, tc.other, got)
			}
		})
	}
	if _, err := os.Stat(filepath.Join(src, "run")); err == nil {
		t.Error("the check created a directory")
	}
}
