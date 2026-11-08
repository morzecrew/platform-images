package main

import (
	"bytes"
	"encoding/base64"
	"encoding/hex"
	"io"
	"net/http"
	"net/http/httptest"
	"os"
	"path/filepath"
	"slices"
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
		{"inbounds[0].settings.clients[0].id", "$file", uuid, ""},
		{"inbounds[0].settings.decryption", "$file", key, ""},
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
	c := &config{src: "/etc/xray/10.json", refs: []ref{{"inbounds[0].settings.clients[0].id", "$file", "/run/secrets/id", ""}, {"inbounds[0].settings.decryption", "$vlessDecryption", "/run/secrets/seed", ""}, {"inbounds[1].settings.clients", "$vlessClients", "/run/secrets/clients", "(2 clients)"}}, values: []string{"the-id"}}
	var b bytes.Buffer
	summary(&b, "Xray 26.10.31", []*config{c})
	out := b.String()
	for _, want := range []string{
		"[envconf] xray: effective configuration",
		"xray = Xray 26.10.31",
		"inbounds[0].settings.clients[0].id <- /run/secrets/id   (/etc/xray/10.json)",
		"inbounds[0].settings.decryption <- $vlessDecryption /run/secrets/seed   (/etc/xray/10.json)",
		"inbounds[1].settings.clients <- $vlessClients /run/secrets/clients (2 clients)   (/etc/xray/10.json)",
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
		{"XRAY_HEALTHCHECK_EXPECT", `^203\.0\.113\.(7\s*$`, "XRAY_HEALTHCHECK_EXPECT is not a regular expression"},
		// RE2 has no lookahead, which a PCRE habit reaches for.
		{"XRAY_HEALTHCHECK_EXPECT", `^(?!10\.)`, "XRAY_HEALTHCHECK_EXPECT is not a regular expression"},
	} {
		t.Run(tc.name+"="+tc.value, func(t *testing.T) {
			t.Setenv(tc.name, tc.value)
			if _, err := healthSettings(); err == nil || !strings.Contains(err.Error(), tc.want) {
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

// #133: with XRAY_HEALTHCHECK_EXPECT set, a 2xx passes only when the first
// 64 KiB of the body match it, and a mismatch shows the start of the body.
func TestHealthcheckExpect(t *testing.T) {
	status, body := http.StatusOK, ""
	proxy := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		w.WriteHeader(status)
		io.WriteString(w, body)
	}))
	defer proxy.Close()
	t.Setenv("XRAY_HEALTHCHECK_URL", "http://ip.example/")
	t.Setenv("XRAY_HEALTHCHECK_PROXY", proxy.URL)
	t.Setenv("XRAY_HEALTHCHECK_TIMEOUT", "5s")
	const anchored, bare = `^203\.0\.113\.7\s*$`, `203\.0\.113\.7`
	pad := func(n int) string { return strings.Repeat(" ", n) }

	for _, tc := range []struct {
		name, expect string
		status       int
		body         string
		rc           int
		want         string
	}{
		{"match", anchored, 200, "203.0.113.7\n", 0, "matches XRAY_HEALTHCHECK_EXPECT"},
		{"anchored", anchored, 200, "203.0.113.71", 1, `does not match XRAY_HEALTHCHECK_EXPECT: "203.0.113.71"`},
		{"control characters escaped", anchored, 200, "198.51.100.9\r\n\x1b[2J", 1, `"198.51.100.9\r\n\x1b[2J"`},
		{"excerpt of 128 bytes", anchored, 200, strings.Repeat("x", 127) + "yz", 1, `"` + strings.Repeat("x", 127) + `y"`},
		{"match ending at 64 KiB", bare, 200, pad(maxBody-11) + "203.0.113.7", 0, "matches"},
		{"match crossing 64 KiB", bare, 200, pad(maxBody-10) + "203.0.113.7", 1, "does not match"},
		{"non-2xx with a matching body", anchored, 503, "203.0.113.7", 1, "503 Service Unavailable"},
	} {
		t.Run(tc.name, func(t *testing.T) {
			t.Setenv("XRAY_HEALTHCHECK_EXPECT", tc.expect)
			status, body = tc.status, tc.body
			var rc int
			out := stderr(t, func() { rc = healthcheck() })
			if rc != tc.rc || !strings.Contains(out, tc.want) {
				t.Errorf("rc = %d, want %d; stderr %q, want %q", rc, tc.rc, out, tc.want)
			}
			if tc.status != 200 && strings.Contains(out, "XRAY_HEALTHCHECK_EXPECT") {
				t.Errorf("the body was checked after a %d: %q", tc.status, out)
			}
		})
	}
}

// Without a proxy the probe fetches nothing, so an expression would be a
// check that silently never runs.
func TestExpectWithoutProxyIsReported(t *testing.T) {
	t.Setenv("XRAY_HEALTHCHECK_EXPECT", `^203\.0\.113\.7$`)
	t.Setenv("XRAY_HEALTHCHECK_PROXY", "")
	if out := stderr(t, warnUnknown); !strings.Contains(out, "WARN: XRAY_HEALTHCHECK_EXPECT is set, but XRAY_HEALTHCHECK_PROXY is unset") {
		t.Errorf("stderr %q", out)
	}
	t.Setenv("XRAY_HEALTHCHECK_PROXY", "http://127.0.0.1:10809")
	if out := stderr(t, warnUnknown); strings.Contains(out, "XRAY_HEALTHCHECK_EXPECT") {
		t.Errorf("warned with a proxy set: %q", out)
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
	if c.refs[0] != (ref{"decryption", "$vlessDecryption", file, ""}) || c.values[0] != lines[0] {
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
	if rc := printClientValue("vless-encryption", vlessEncryptionFile, nil); rc != 2 {
		t.Errorf("no argument: rc = %d", rc)
	}
	if rc := printClientValue("vless-encryption", vlessEncryptionFile, []string{subdir}); rc != exConfig {
		t.Errorf("directory: rc = %d", rc)
	}
}

func TestRuntimeMustNotOverlapSource(t *testing.T) {
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
		name, run string
		refused   bool
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
			err := overlap(src, tc.run)
			if tc.refused && (err == nil || !strings.Contains(err.Error(), "overlap")) {
				t.Errorf("XRAY_RUNTIME_DIR=%s: err = %v, want a refusal", tc.run, err)
			}
			if !tc.refused && err != nil {
				t.Errorf("XRAY_RUNTIME_DIR=%s: %v", tc.run, err)
			}
		})
	}
	if _, err := os.Stat(filepath.Join(src, "run")); err == nil {
		t.Error("the check created a directory")
	}
}

// The vector is from #127 and was checked against `xray x25519 -i` on
// 26.10.31: the "Password (PublicKey)" line for that private key. The second
// key differs only in the spare bits of its last character, which Xray drops.
// The last two carry line breaks, which Go's decoder skips; Xray decodes
// "privateKey" with the same call, so the server accepts those files too and
// its clients need the same password.
func TestRealityPasswordMatchesUpstream(t *testing.T) {
	dir := t.TempDir()
	const want = "sNLrGAfurBkhSpGRtjUYNivbHdVx0VQXvDkeWROqlkM"
	for _, key := range []string{
		"abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQ\n",
		"abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPR",
		"abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQ\r\n",
		"abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQ\n\n",
		"abcdefghijklmnopqrstuvwxyz\nABCDEFGHIJKLMNOPQ",
	} {
		file := write(t, filepath.Join(dir, "key"), key, 0o400)
		got, err := realityPassword(file)
		if err != nil || got != want {
			t.Errorf("%q: got %q, %v; want %q", key, got, err, want)
		}
		os.Remove(file)
	}
	// A pair `xray x25519` generated on 26.10.31, chosen because both keys
	// carry `-` and `_`, where base64url and standard base64 differ.
	file := write(t, filepath.Join(dir, "key"), "4A35WaHxTCmPnZo1Dyt2S_kpwgD_GAPjmJxiJvE3wX8\n", 0o400)
	if got, err := realityPassword(file); err != nil || got != "fCLp4SvcOx5r97_p-GuC5oHa7eVQulXbNkqv5FYrbW4" {
		t.Errorf("generated pair: got %q, %v", got, err)
	}
}

func TestRealityPasswordRefusals(t *testing.T) {
	dir := t.TempDir()
	const key = "abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQ"
	subdir := filepath.Join(dir, "subdir")
	if err := os.Mkdir(subdir, 0o700); err != nil {
		t.Fatal(err)
	}
	for _, tc := range []struct{ name, content string }{
		{"42 characters", key[:42]},
		{"44 characters", key + "A"},
		{"padded", key + "="},
		{"standard alphabet", key[:42] + "+"},
		{"a slash", "/" + key[1:]},
		{"hex", strings.Repeat("ab", 32)},
		{"empty", ""},
	} {
		t.Run(tc.name, func(t *testing.T) {
			file := write(t, filepath.Join(dir, "key"), tc.content, 0o600)
			_, err := realityPassword(file)
			if err == nil || !strings.Contains(err.Error(), "does not hold a REALITY private key") {
				t.Errorf("err = %v", err)
			}
			if rc := printClientValue("reality-password", realityPassword, []string{file}); rc != exConfig {
				t.Errorf("rc = %d", rc)
			}
		})
	}
	if _, err := realityPassword(subdir); err == nil || !strings.Contains(err.Error(), "is a directory") {
		t.Errorf("directory: err = %v", err)
	}
	if rc := printClientValue("reality-password", realityPassword, []string{"a", "b"}); rc != 2 {
		t.Errorf("two arguments: rc = %d", rc)
	}
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

// The secret pasted where its path belongs, as `xray x25519 -i <key>` takes
// it, is refused without being repeated.
func TestClientCommandsDoNotEchoANonPath(t *testing.T) {
	for _, tc := range []struct{ command, secret string }{
		{"reality-password", "abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQ"},
		{"vless-encryption", strings.Repeat("ab", 64)},
		{"reality-password", "relative/path"},
	} {
		var rc int
		out := stderr(t, func() { rc = printClientValue(tc.command, clientValues[tc.command], []string{tc.secret}) })
		if rc != 2 || strings.Contains(out, tc.secret) || !strings.Contains(out, "not an absolute path") {
			t.Errorf("%s %s: rc = %d, stderr %q", tc.command, tc.secret, rc, out)
		}
	}
}

const (
	clientA = "3f2c1f0e-8a4b-4c1d-9e2f-0a1b2c3d4e5f"
	clientB = "6b1d2c3e-4f5a-4b6c-8d7e-9f0a1b2c3d4e"
)

// The format from #130: comments, blank lines, spaces or tabs between the
// fields, whitespace around them, CRLF, and an id lower-cased.
func TestVlessClients(t *testing.T) {
	dir := t.TempDir()
	list := write(t, filepath.Join(dir, "clients"), "# <uuid> [name]\r\n\n  "+clientA+"  \r\n\t"+strings.ToUpper(clientB)+"\tphone\n   # "+clientA+" old-laptop\n", 0o400)
	src := write(t, filepath.Join(dir, "c.json"), `{"inbounds": [{"settings": {"clients": {"$vlessClients": "`+list+`"}, "flow": "xtls-rprx-vision"}}]}`, 0o600)
	c, err := resolveFile(src)
	if err != nil {
		t.Fatal(err)
	}
	want := `{"inbounds":[{"settings":{"clients":[{"id":"` + clientA + `"},{"id":"` + clientB + `","email":"phone"}],"flow":"xtls-rprx-vision"}}]}` + "\n"
	if string(c.out) != want {
		t.Errorf("resolved\n got %s\nwant %s", c.out, want)
	}
	if len(c.refs) != 1 || c.refs[0] != (ref{"inbounds[0].settings.clients", "$vlessClients", list, "(2 clients)"}) {
		t.Errorf("refs = %v", c.refs)
	}
	if !slices.Equal(c.values, []string{clientA, clientB}) {
		t.Errorf("values to redact = %v", c.values)
	}

	// What morzer's uuid generator writes at init.
	bare := write(t, filepath.Join(dir, "bare"), clientA+"\n", 0o400)
	r, err := vlessClients(bare)
	if err != nil || r.note != "(1 client)" || !slices.Equal(r.value.([]vlessClient), []vlessClient{{ID: clientA}}) {
		t.Errorf("a bare UUID: %+v, %v", r, err)
	}
}

func TestVlessClientsRefusals(t *testing.T) {
	dir := t.TempDir()
	for _, tc := range []struct{ name, content, want string }{
		{"three fields", "# devices\n" + clientA + " phone spare\n", "line 2: 3 fields"},
		{"not hex", clientA[:35] + "g", "line 1: the id is not a UUID"},
		{"no dashes", strings.ReplaceAll(clientA, "-", ""), "line 1: the id is not a UUID"},
		{"braces", "{" + clientA + "}", "line 1: the id is not a UUID"},
		{"a URN", "urn:uuid:" + clientA, "line 1: the id is not a UUID"},
		{"a short string Xray would map to a UUIDv5", "phone", "line 1: the id is not a UUID"},
		{"a name with a slash", clientA + " ph/one", "line 1: the name is not 1 to 64"},
		{"a name of 65 characters", clientA + " " + strings.Repeat("n", 65), "line 1: the name is not 1 to 64"},
		{"a name that is not ASCII", clientA + " t\u00e9l\u00e9phone", "line 1: the name is not 1 to 64"},
		{"the same id in another case", clientA + "\n\n" + strings.ToUpper(clientA) + " phone", "line 3: the id is the one on line 1"},
		{"the same name in another case", clientA + " phone\n" + clientB + " Phone", "line 2: the name is the one on line 1"},
		{"only comments", "# " + clientA + "\n\n", "lists no client"},
		{"empty", "", "lists no client"},
	} {
		t.Run(tc.name, func(t *testing.T) {
			list := write(t, filepath.Join(dir, "clients"), tc.content, 0o600)
			src := write(t, filepath.Join(dir, "c.json"), `{"inbounds": [{"settings": {"clients": {"$vlessClients": "`+list+`"}}}]}`, 0o600)
			_, err := resolveFile(src)
			if err == nil || !strings.Contains(err.Error(), "inbounds[0].settings.clients: "+list+" "+tc.want) {
				t.Fatalf("err = %v\nwant %q", err, tc.want)
			}
			for _, id := range []string{clientA, clientB, clientA[:35], strings.ToUpper(clientA)} {
				if strings.Contains(err.Error(), id) {
					t.Errorf("error %q carries an id", err)
				}
			}
		})
	}
	// A name of exactly 64 characters, every allowed one included.
	name := strings.Repeat("x", 52) + "Az09._@+-Q.Z"
	if _, err := parseClients(clientA + " " + name); err != nil || len(name) != 64 {
		t.Errorf("a 64-character name: %v", err)
	}
}

// The format dotdash's gate reads its upstream from: the userinfo ends at the
// last @, the user at its first colon, and nothing is decoded.
func TestProxy(t *testing.T) {
	dir := t.TempDir()
	for _, tc := range []struct {
		content string
		want    proxyServer
		note    string
	}{
		{"alice:s3cret@proxy.example:1080\n", proxyServer{"proxy.example", 1080, "alice", "s3cret"}, "proxy.example:1080"},
		{"alice:pa:ss:wd@proxy.example:1080", proxyServer{"proxy.example", 1080, "alice", "pa:ss:wd"}, "proxy.example:1080"},
		{"alice:p@ss@w0rd@203.0.113.7:3128", proxyServer{"203.0.113.7", 3128, "alice", "p@ss@w0rd"}, "203.0.113.7:3128"},
		{"alice:@:@x@proxy.example:1", proxyServer{"proxy.example", 1, "alice", "@:@x"}, "proxy.example:1"},
		{"al@ice:pw@proxy.example:65535", proxyServer{"proxy.example", 65535, "al@ice", "pw"}, "proxy.example:65535"},
		{"alice:p%40ss@proxy.example:1080", proxyServer{"proxy.example", 1080, "alice", "p%40ss"}, "proxy.example:1080"},
		{"alice:s3cret@[2001:db8::1]:1080", proxyServer{"2001:db8::1", 1080, "alice", "s3cret"}, "[2001:db8::1]:1080"},
		{"[::1]:8080", proxyServer{"::1", 8080, "", ""}, "no credentials"},
		{"203.0.113.7:3128\n", proxyServer{"203.0.113.7", 3128, "", ""}, "no credentials"},
		{"Proxy-1.example_net:01080", proxyServer{"Proxy-1.example_net", 1080, "", ""}, "no credentials"},
		// "user:pass" that lost its "@host:port": the summary must not show it.
		{"alice:1234", proxyServer{"alice", 1234, "", ""}, "no credentials"},
		{"alice:pw@" + strings.Repeat("a", 63) + ".example:1080", proxyServer{strings.Repeat("a", 63) + ".example", 1080, "alice", "pw"}, strings.Repeat("a", 63) + ".example:1080"},
	} {
		file := write(t, filepath.Join(dir, "proxy"), tc.content, 0o600)
		r, err := proxy(file)
		if err != nil || r.value != tc.want || r.note != tc.note {
			t.Errorf("%q: %+v, %v\nwant %+v, note %q", tc.content, r, err, tc.want, tc.note)
		}
		var secrets []string
		if tc.want.User != "" {
			secrets = []string{tc.want.User, tc.want.Pass}
		}
		if !slices.Equal(r.secrets, secrets) {
			t.Errorf("%q: secrets to redact = %q", tc.content, r.secrets)
		}
	}

	// The whole settings of an outbound, the port a JSON number, and the
	// credentials left out when the file has none.
	withAuth := write(t, filepath.Join(dir, "with"), "alice:p:@ss@proxy.example:1080\n", 0o400)
	without := write(t, filepath.Join(dir, "without"), "[2001:db8::1]:3128\n", 0o400)
	src := write(t, filepath.Join(dir, "c.json"), `{"outbounds": [
		{"protocol": "socks", "settings": {"$proxy": "`+withAuth+`"}},
		{"protocol": "http", "settings": {"$proxy": "`+without+`"}}
	]}`, 0o600)
	c, err := resolveFile(src)
	if err != nil {
		t.Fatal(err)
	}
	want := `{"outbounds":[{"protocol":"socks","settings":{"address":"proxy.example","port":1080,"user":"alice","pass":"p:@ss"}},{"protocol":"http","settings":{"address":"2001:db8::1","port":3128}}]}` + "\n"
	if string(c.out) != want {
		t.Errorf("resolved\n got %s\nwant %s", c.out, want)
	}
	wantRefs := []ref{
		{"outbounds[0].settings", "$proxy", withAuth, "proxy.example:1080"},
		{"outbounds[1].settings", "$proxy", without, "no credentials"},
	}
	if !slices.Equal(c.refs, wantRefs) {
		t.Errorf("refs = %v, want %v", c.refs, wantRefs)
	}
	if !slices.Equal(c.values, []string{"alice", "p:@ss"}) {
		t.Errorf("values to redact = %q", c.values)
	}
	var b bytes.Buffer
	summary(&b, "Xray 26.10.31", []*config{c})
	if line := "outbounds[0].settings <- $proxy " + withAuth + " proxy.example:1080   (" + src + ")"; !strings.Contains(b.String(), line) {
		t.Errorf("summary lacks %q:\n%s", line, b.String())
	}
}

// Each refusal names the file and what is wrong, and the value carries a user
// and a password that must not appear in the error, nor any part of them.
func TestProxyRefusals(t *testing.T) {
	dir := t.TempDir()
	const user, pass = "alice-7f3a", "s3cret-9c2e"
	for _, tc := range []struct{ name, content, want string }{
		{"a socks5 scheme", "socks5://" + user + ":" + pass + "@proxy.example:1080", "holds a URL. Write user:pass@host:port, without the scheme"},
		{"an http scheme", "http://proxy.example:3128", "without the scheme"},
		{"a space", user + ":" + pass + " @proxy.example:1080", "contains whitespace"},
		{"a leading tab", "\t" + user + ":" + pass + "@proxy.example:1080", "contains whitespace"},
		{"CRLF", user + ":" + pass + "@proxy.example:1080\r\n", "contains whitespace"},
		{"a second line", user + ":" + pass + "@proxy.example:1080\n\n", "contains whitespace"},
		{"a no-break space", user + ":" + pass + "\u00a0@proxy.example:1080", "contains whitespace"},
		{"no password", user + "@proxy.example:1080", "before the @ is not a user and a password"},
		{"an empty password", user + ":@proxy.example:1080", "before the @ is not a user and a password"},
		{"an empty user", ":" + pass + "@proxy.example:1080", "before the @ is not a user and a password"},
		{"nothing before the @", "@proxy.example:1080", "before the @ is not a user and a password"},
		{"no @, so the password reads as the port", user + ":" + pass, "the port is not a number from 1 to 65535"},
		{"no host or port", user + ":" + pass + "@", "does not end in a host, a colon and a port"},
		{"no port", user + ":" + pass + "@proxy.example", "does not end in a host, a colon and a port"},
		{"an empty port", user + ":" + pass + "@proxy.example:", "the port is missing"},
		{"an empty host", user + ":" + pass + "@:1080", "the host is empty"},
		{"empty brackets", user + ":" + pass + "@[]:1080", "the host is empty"},
		{"port 0", user + ":" + pass + "@proxy.example:0", "the port is not a number from 1 to 65535"},
		{"port 65536", user + ":" + pass + "@proxy.example:65536", "the port is not a number from 1 to 65535"},
		{"a signed port", user + ":" + pass + "@proxy.example:+1080", "the port is not a number from 1 to 65535"},
		{"a named port", user + ":" + pass + "@proxy.example:socks", "the port is not a number from 1 to 65535"},
		{"IPv6 without brackets", user + ":" + pass + "@2001:db8::1:1080", "does not end in a host, a colon and a port"},
		{"an unclosed bracket", user + ":" + pass + "@[2001:db8::1:1080", "does not end in a host, a colon and a port"},
		{"a name in brackets", user + ":" + pass + "@[proxy.example]:1080", "the brackets hold something other than an IPv6 address"},
		{"IPv4 in brackets", user + ":" + pass + "@[203.0.113.7]:1080", "the brackets hold something other than an IPv6 address"},
		{"a path", user + ":" + pass + "@proxy.example/x:1080", "the host is not a DNS name"},
		{"a 64-byte label", user + ":" + pass + "@" + strings.Repeat("a", 64) + ".example:1080", "the host is not a DNS name"},
		{"an empty label", user + ":" + pass + "@proxy..example:1080", "the host is not a DNS name"},
		{"a trailing dot", user + ":" + pass + "@proxy.example.:1080", "the host is not a DNS name"},
		{"a 254-byte name", user + ":" + pass + "@" + strings.Repeat("a.", 126) + "ab:1080", "the host is not a DNS name"},
		{"empty", "", "does not end in a host, a colon and a port"},
	} {
		t.Run(tc.name, func(t *testing.T) {
			file := write(t, filepath.Join(dir, "proxy"), tc.content, 0o600)
			src := write(t, filepath.Join(dir, "c.json"), `{"outbounds": [{"protocol": "socks", "settings": {"$proxy": "`+file+`"}}]}`, 0o600)
			_, err := resolveFile(src)
			if err == nil || !strings.Contains(err.Error(), "outbounds[0].settings: "+file+" ") || !strings.Contains(err.Error(), tc.want) {
				t.Fatalf("err = %v\nwant %q", err, tc.want)
			}
			for _, s := range []string{user, pass, "alice", "s3cret"} {
				if strings.Contains(err.Error(), s) {
					t.Errorf("error %q carries %q", err, s)
				}
			}
		})
	}
	src := write(t, filepath.Join(dir, "c.json"), `{"settings": {"$proxy": "/run/secrets/upstream", "address": "x"}}`, 0o600)
	if _, err := resolveFile(src); err == nil || !strings.Contains(err.Error(), `an object holding "$proxy" holds nothing else, and this one also holds address`) {
		t.Errorf("beside another key: err = %v", err)
	}
}
