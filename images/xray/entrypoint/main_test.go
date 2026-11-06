package main

import (
	"bytes"
	"encoding/base64"
	"encoding/hex"
	"net/http"
	"net/http/httptest"
	"os"
	"path/filepath"
	"strings"
	"testing"
)

func write(t *testing.T, path, content string, mode os.FileMode) string {
	t.Helper()
	if err := os.WriteFile(path, []byte(content), mode); err != nil {
		t.Fatal(err)
	}
	return path
}

func TestResolveReplacesReferencesAndNothingElse(t *testing.T) {
	dir := t.TempDir()
	uuid := write(t, filepath.Join(dir, "uuid"), "6b0c7f3e-3c3a-4f43-9a63-1f0b3d1c2e77\n", 0o400)
	key := write(t, filepath.Join(dir, "key"), "line1\nline2\n\n", 0o400)
	src := write(t, filepath.Join(dir, "in.json"), `{
		"n": 12345678901234567890,
		"s": "<&>",
		"literal": {"file": "/not/a/reference"},
		"inbounds": [{"settings": {"clients": [{"id": {"$file": "`+uuid+`"}}], "decryption": {"$file": "`+key+`"}}}]
	}`, 0o600)

	c, err := resolveFile(src)
	if err != nil {
		t.Fatal(err)
	}
	want := `{"inbounds":[{"settings":{"clients":[{"id":"6b0c7f3e-3c3a-4f43-9a63-1f0b3d1c2e77"}],"decryption":"line1\nline2\n"}}],"literal":{"file":"/not/a/reference"},"n":12345678901234567890,"s":"<&>"}` + "\n"
	if string(c.out) != want {
		t.Errorf("resolved\n got %s\nwant %s", c.out, want)
	}
	wantRefs := []ref{
		{"inbounds[0].settings.clients[0].id", "$file", uuid},
		{"inbounds[0].settings.decryption", "$file", key},
	}
	if len(c.refs) != 2 || c.refs[0] != wantRefs[0] || c.refs[1] != wantRefs[1] {
		t.Errorf("refs = %v, want %v", c.refs, wantRefs)
	}
}

func TestResolveRefusals(t *testing.T) {
	dir := t.TempDir()
	const secret = "s3cret-value"
	ok := write(t, filepath.Join(dir, "ok"), secret, 0o400)
	big := write(t, filepath.Join(dir, "big"), strings.Repeat("a", maxSecret+1), 0o400)
	exact := write(t, filepath.Join(dir, "exact"), strings.Repeat("a", maxSecret), 0o400)
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
		{"top level", `{"$file": "` + ok + `", "x": 1}`, "the top level: an object"},
		{"too big", `{"a": {"$file": "` + big + `"}}`, "is larger than 65536 bytes"},
		{"NUL", `{"a": {"$file": "` + nul + `"}}`, "contains a NUL byte"},
		{"not UTF-8", `{"a": {"$file": "` + latin1 + `"}}`, "is not valid UTF-8"},
		{"comment", "{\"a\": 1 // no\n}", "is not valid JSON"},
		{"two values", `{"a": 1} {"b": 2}`, "something follows its value"},
	} {
		t.Run(tc.name, func(t *testing.T) {
			src := write(t, filepath.Join(dir, "c.json"), tc.doc, 0o600)
			_, err := resolveFile(src)
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
	if _, err := resolveFile(src); err != nil {
		t.Errorf("a file of exactly %d bytes: %v", maxSecret, err)
	}
}

func TestUnreadableReference(t *testing.T) {
	if os.Geteuid() == 0 {
		t.Skip("root reads a 000 file")
	}
	dir := t.TempDir()
	locked := write(t, filepath.Join(dir, "locked"), "x", 0o000)
	src := write(t, filepath.Join(dir, "c.json"), `{"a": {"$file": "`+locked+`"}}`, 0o600)
	if _, err := resolveFile(src); err == nil || !strings.Contains(err.Error(), locked+" is not readable by uid") {
		t.Errorf("err = %v", err)
	}
}

func TestResolveDir(t *testing.T) {
	dir := t.TempDir()
	if _, err := resolveDir(dir); err == nil || !strings.Contains(err.Error(), "holds no .json file") {
		t.Errorf("empty: err = %v", err)
	}
	if _, err := resolveDir(filepath.Join(dir, "absent")); err == nil || !strings.Contains(err.Error(), "cannot be read") {
		t.Errorf("absent: err = %v", err)
	}
	write(t, filepath.Join(dir, "20-out.json"), `{"outbounds": []}`, 0o600)
	write(t, filepath.Join(dir, "10-in.json"), `{"inbounds": []}`, 0o600)
	configs, err := resolveDir(dir)
	if err != nil {
		t.Fatal(err)
	}
	if len(configs) != 2 || filepath.Base(configs[0].src) != "10-in.json" {
		t.Errorf("configs not in name order: %v", configs)
	}
	for _, other := range []string{"30-routing.yaml", "40-x.jsonc"} {
		p := write(t, filepath.Join(dir, other), "{}", 0o600)
		if _, err := resolveDir(dir); err == nil || !strings.Contains(err.Error(), p+" is not a .json file") {
			t.Errorf("%s: err = %v", other, err)
		}
		os.Remove(p)
	}
	if err := os.Mkdir(filepath.Join(dir, "d.json"), 0o700); err != nil {
		t.Fatal(err)
	}
	if _, err := resolveDir(dir); err == nil || !strings.Contains(err.Error(), "d.json is not a .json file") {
		t.Errorf("directory: err = %v", err)
	}
}

func TestWriteRuntimeReplacesWhatWasThere(t *testing.T) {
	run := filepath.Join(t.TempDir(), "run")
	if err := os.Mkdir(run, 0o755); err != nil {
		t.Fatal(err)
	}
	write(t, filepath.Join(run, "stale.json"), "{}", 0o600)
	err := writeRuntime(run, []*config{{src: "/etc/xray/10-in.json", out: []byte("{}\n")}})
	if err != nil {
		t.Fatal(err)
	}
	entries, _ := os.ReadDir(run)
	if len(entries) != 1 || entries[0].Name() != "10-in.json" {
		t.Errorf("runtime dir holds %v", entries)
	}
	info, _ := os.Stat(filepath.Join(run, "10-in.json"))
	if info.Mode().Perm() != 0o600 {
		t.Errorf("file mode %v", info.Mode().Perm())
	}
	info, _ = os.Stat(run)
	if info.Mode().Perm() != 0o700 {
		t.Errorf("dir mode %v", info.Mode().Perm())
	}
}

func TestRedact(t *testing.T) {
	got := redact("invalid UUID: abc-123, then abc", []string{"abc", "abc-123", ""})
	if got != "invalid UUID: <redacted>, then <redacted>" {
		t.Errorf("redact = %q", got)
	}
}

func TestSummaryNamesPathsNotValues(t *testing.T) {
	t.Setenv("XRAY_HEALTHCHECK_PROXY", "http://probe:pw@127.0.0.1:10809")
	c := &config{src: "/etc/xray/10.json", refs: []ref{{"inbounds[0].settings.clients[0].id", "$file", "/run/secrets/id"}, {"inbounds[0].settings.decryption", "$vlessDecryption", "/run/secrets/seed"}}, values: []string{"the-id"}}
	var b bytes.Buffer
	summary(&b, "Xray 26.10.31", []*config{c})
	out := b.String()
	for _, want := range []string{
		"[envconf] xray: effective configuration",
		"xray = Xray 26.10.31",
		"inbounds[0].settings.clients[0].id <- /run/secrets/id   (/etc/xray/10.json)",
		"inbounds[0].settings.decryption <- $vlessDecryption /run/secrets/seed   (/etc/xray/10.json)",
		"XRAY_HEALTHCHECK_PROXY = http://probe:xxxxx@127.0.0.1:10809",
		"[envconf] precedence: image default < environment",
	} {
		if !strings.Contains(out, want) {
			t.Errorf("summary lacks %q:\n%s", want, out)
		}
	}
	if strings.Contains(out, "the-id") || strings.Contains(out, ":pw@") {
		t.Errorf("summary carries a value:\n%s", out)
	}
}

func TestHealthSettings(t *testing.T) {
	for _, tc := range []struct{ name, value, want string }{
		{"XRAY_HEALTHCHECK_URL", "ftp://example.com/", "XRAY_HEALTHCHECK_URL must be"},
		{"XRAY_HEALTHCHECK_URL", "/generate_204", "XRAY_HEALTHCHECK_URL must be"},
		{"XRAY_HEALTHCHECK_TIMEOUT", "10", "not a duration"},
		{"XRAY_HEALTHCHECK_TIMEOUT", "-1s", "not a duration"},
		{"XRAY_HEALTHCHECK_PROXY", "127.0.0.1:10809", "XRAY_HEALTHCHECK_PROXY must be"},
		{"XRAY_HEALTHCHECK_PROXY", "vless://127.0.0.1:443", "XRAY_HEALTHCHECK_PROXY must be"},
	} {
		t.Run(tc.name+"="+tc.value, func(t *testing.T) {
			t.Setenv(tc.name, tc.value)
			if _, _, _, err := healthSettings(); err == nil || !strings.Contains(err.Error(), tc.want) {
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
	t.Setenv("XRAY_HEALTHCHECK_URL", "http://egress.example/generate_204")
	t.Setenv("XRAY_HEALTHCHECK_PROXY", proxy.URL)
	t.Setenv("XRAY_HEALTHCHECK_TIMEOUT", "5s")

	if rc := healthcheck(); rc != 0 {
		t.Errorf("204: rc = %d", rc)
	}
	if len(seen) != 1 || seen[0] != "http://egress.example/generate_204" {
		t.Errorf("the proxy saw %v", seen)
	}
	status = http.StatusFound
	if rc := healthcheck(); rc != 1 {
		t.Errorf("302: rc = %d", rc)
	}
	if len(seen) != 2 {
		t.Errorf("the redirect was followed: %v", seen)
	}
	proxy.Close()
	if rc := healthcheck(); rc != 1 {
		t.Errorf("proxy down: rc = %d", rc)
	}
}

// testdata/vlessenc.txt is the ML-KEM-768 pair `xray vlessenc` printed on
// 26.10.31: the decryption line, then the encryption line. The seed is the
// decryption's last field, and both halves must come back from it exactly.
func TestVlessKeysMatchUpstream(t *testing.T) {
	raw, err := os.ReadFile("testdata/vlessenc.txt")
	if err != nil {
		t.Fatal(err)
	}
	lines := strings.Split(strings.TrimSpace(string(raw)), "\n")
	if len(lines) != 2 {
		t.Fatalf("testdata holds %d lines", len(lines))
	}
	b64 := lines[0][strings.LastIndex(lines[0], ".")+1:]
	seed, err := base64.RawURLEncoding.DecodeString(b64)
	if err != nil {
		t.Fatal(err)
	}
	dir := t.TempDir()
	file := write(t, filepath.Join(dir, "seed"), hex.EncodeToString(seed)+"\n", 0o400)

	dec, err := vlessDecryption(file)
	if err != nil || dec != lines[0] {
		t.Errorf("decryption = %q, %v\nwant %q", dec, err, lines[0])
	}
	enc, err := vlessEncryption(seed)
	if err != nil || enc != lines[1] {
		t.Errorf("encryption = %q, %v\nwant %q", enc, err, lines[1])
	}

	src := write(t, filepath.Join(dir, "c.json"), `{"decryption": {"$vlessDecryption": "`+file+`"}}`, 0o600)
	c, err := resolveFile(src)
	if err != nil {
		t.Fatal(err)
	}
	if want := `{"decryption":"` + lines[0] + `"}` + "\n"; string(c.out) != want {
		t.Errorf("resolved %s", c.out)
	}
	if c.refs[0] != (ref{"decryption", "$vlessDecryption", file}) || c.values[0] != lines[0] {
		t.Errorf("refs %v", c.refs)
	}
}

func TestSeedRefusals(t *testing.T) {
	dir := t.TempDir()
	good := strings.Repeat("ab", 64)
	subdir := filepath.Join(dir, "subdir")
	if err := os.Mkdir(subdir, 0o700); err != nil {
		t.Fatal(err)
	}
	for _, tc := range []struct{ name, content, want string }{
		{"127 hex characters", good[:127], "does not hold a seed"},
		{"130 hex characters", good + "ab", "does not hold a seed"},
		{"a character that is not hex", good[:127] + "g", "does not hold a seed"},
		{"CRLF", good + "\r\n", "does not hold a seed"},
		{"empty", "", "does not hold a seed"},
	} {
		t.Run(tc.name, func(t *testing.T) {
			file := write(t, filepath.Join(dir, "seed"), tc.content, 0o600)
			if _, err := readSeed(file); err == nil || !strings.Contains(err.Error(), tc.want) || strings.Contains(err.Error(), "g'") {
				t.Errorf("err = %v", err)
			}
			src := write(t, filepath.Join(dir, "c.json"), `{"d": {"$vlessDecryption": "`+file+`"}}`, 0o600)
			if _, err := resolveFile(src); err == nil || !strings.Contains(err.Error(), "d: "+file+" does not hold a seed") {
				t.Errorf("resolve: err = %v", err)
			}
		})
	}
	if _, err := readSeed(subdir); err == nil || !strings.Contains(err.Error(), "is a directory") {
		t.Errorf("directory: err = %v", err)
	}
	src := write(t, filepath.Join(dir, "c.json"), `{"d": {"$vlessDecryption": "seed"}}`, 0o600)
	if _, err := resolveFile(src); err == nil || !strings.Contains(err.Error(), `"$vlessDecryption" must be an absolute path`) {
		t.Errorf("relative: err = %v", err)
	}
	src = write(t, filepath.Join(dir, "c.json"), `{"d": {"$vlessDecryption": "/s", "$file": "/f"}}`, 0o600)
	if _, err := resolveFile(src); err == nil || !strings.Contains(err.Error(), `an object holding "$file" holds nothing else, and this one also holds $vlessDecryption`) {
		t.Errorf("both keys: err = %v", err)
	}
	if rc := vlessEncryptionCmd(nil); rc != 2 {
		t.Errorf("no argument: rc = %d", rc)
	}
	if rc := vlessEncryptionCmd([]string{subdir}); rc != exConfig {
		t.Errorf("directory: rc = %d", rc)
	}
}
