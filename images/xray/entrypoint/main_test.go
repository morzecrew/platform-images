package main

import (
	"bytes"
	"encoding/base64"
	"encoding/hex"
	"io"
	"os"
	"path/filepath"
	"slices"
	"strings"
	"testing"

	"github.com/morzecrew/platform-images/shared/go/envconf"
)

// The generic parts, $file among them, are tested in shared/go/envconf.
func resolveFile(p string) (*envconf.Config, error) {
	return envconf.ResolveFile(p, references)
}

func write(t *testing.T, path, content string, mode os.FileMode) string {
	t.Helper()
	if err := os.WriteFile(path, []byte(content), mode); err != nil {
		t.Fatal(err)
	}
	return path
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
	if len(configs) != 2 || filepath.Base(configs[0].Src) != "10-in.json" {
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
	err := writeRuntime(run, []*envconf.Config{{Src: "/etc/xray/10-in.json", Out: []byte("{}\n")}})
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
	if want := `{"decryption":"` + lines[0] + `"}` + "\n"; string(c.Out) != want {
		t.Errorf("resolved %s", c.Out)
	}
	if c.Refs[0] != (envconf.Ref{Path: "decryption", Kind: "$vlessDecryption", File: file, Note: ""}) || c.Values[0] != lines[0] {
		t.Errorf("refs %v", c.Refs)
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
	if rc := printClientValue("vless-encryption", vlessEncryptionFile, []string{subdir}); rc != envconf.ExConfig {
		t.Errorf("directory: rc = %d", rc)
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
			if rc := printClientValue("reality-password", realityPassword, []string{file}); rc != envconf.ExConfig {
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
	if string(c.Out) != want {
		t.Errorf("resolved\n got %s\nwant %s", c.Out, want)
	}
	if len(c.Refs) != 1 || c.Refs[0] != (envconf.Ref{Path: "inbounds[0].settings.clients", Kind: "$vlessClients", File: list, Note: "(2 clients)"}) {
		t.Errorf("refs = %v", c.Refs)
	}
	if !slices.Equal(c.Values, []string{clientA, clientB}) {
		t.Errorf("values to redact = %v", c.Values)
	}

	// What morzer's uuid generator writes at init.
	bare := write(t, filepath.Join(dir, "bare"), clientA+"\n", 0o400)
	r, err := vlessClients(bare)
	if err != nil || r.Note != "(1 client)" || !slices.Equal(r.Value.([]vlessClient), []vlessClient{{ID: clientA}}) {
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
		{"alice:pw@" + strings.Repeat("a", 63) + ".example:1080", proxyServer{strings.Repeat("a", 63) + ".example", 1080, "alice", "pw"}, strings.Repeat("a", 63) + ".example:1080"},
	} {
		file := write(t, filepath.Join(dir, "proxy"), tc.content, 0o600)
		r, err := proxy(file)
		if err != nil || r.Value != tc.want || r.Note != tc.note {
			t.Errorf("%q: %+v, %v\nwant %+v, note %q", tc.content, r, err, tc.want, tc.note)
		}
		var secrets []string
		if tc.want.User != "" {
			secrets = []string{tc.want.User, tc.want.Pass}
		}
		if !slices.Equal(r.Secrets, secrets) {
			t.Errorf("%q: secrets to redact = %q", tc.content, r.Secrets)
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
	if string(c.Out) != want {
		t.Errorf("resolved\n got %s\nwant %s", c.Out, want)
	}
	wantRefs := []envconf.Ref{
		{Path: "outbounds[0].settings", Kind: "$proxy", File: withAuth, Note: "proxy.example:1080"},
		{Path: "outbounds[1].settings", Kind: "$proxy", File: without, Note: "no credentials"},
	}
	if !slices.Equal(c.Refs, wantRefs) {
		t.Errorf("refs = %v, want %v", c.Refs, wantRefs)
	}
	if !slices.Equal(c.Values, []string{"alice", "p:@ss"}) {
		t.Errorf("values to redact = %q", c.Values)
	}
	var b bytes.Buffer
	img.Summary(&b, "Xray 26.10.31", []*envconf.Config{c})
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
		{"no @, so the user reads as a host", user + ":" + pass, "there is no @, and a host with no dot"},
		{"no @, and a password that is a port", "alice:1234", "there is no @, and a host with no dot"},
		{"a dotted user with no @", "alice.b:" + pass, "the port is not a number from 1 to 65535"},
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
		{"an IPv4 address out of range", user + ":" + pass + "@999.999.999.999:1080", "the host is not a DNS name"},
		{"five IPv4 octets", user + ":" + pass + "@1.2.3.4.5:1080", "the host is not a DNS name"},
		{"a label ending in a hyphen", user + ":" + pass + "@proxy-.example:1080", "the host is not a DNS name"},
		{"a label starting with a hyphen", user + ":" + pass + "@-proxy.example:1080", "the host is not a DNS name"},
		{"empty", "", "does not end in a host, a colon and a port"},
	} {
		t.Run(tc.name, func(t *testing.T) {
			file := write(t, filepath.Join(dir, "proxy"), tc.content, 0o600)
			src := write(t, filepath.Join(dir, "c.json"), `{"outbounds": [{"protocol": "socks", "settings": {"$proxy": "`+file+`"}}]}`, 0o600)
			_, err := resolveFile(src)
			if err == nil || !strings.Contains(err.Error(), "outbounds[0].settings: "+file+" ") || !strings.Contains(err.Error(), tc.want) {
				t.Fatalf("err = %v\nwant %q", err, tc.want)
			}
			// Fragments too: a message that quoted part of the value would
			// carry one of these.
			for _, s := range []string{user, pass, "alice", "s3cret", "7f3a", "9c2e", "1234"} {
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

// Throwaway keys, generated for these tests with `xray wg`.
const (
	wgPriv = "COVmSwOBxaVOO/HxsbcWScy7qC7TdkSHcIQ7att8CXY="
	wgPub  = "KCy9XEHEkTC/weEDMlRHzJ2o5Oa3jXe8o3GKdMVJ2GI="
	wgPSK  = "eBSs0NJMmt89WE32GaHruRx8XlkzYaENus8hH8nlYl4="
)

func TestWireGuard(t *testing.T) {
	dir := t.TempDir()
	// A provider's export: comments, DNS and scripts that only wg-quick runs,
	// keys in any case, Address and AllowedIPs over two lines, a bare address.
	conf := `# exported by a provider
[Interface]
PrivateKey = ` + wgPriv + `
Address = 10.34.0.3/32, fd30:2::3/128
DNS = 1.1.1.1
PostUp = iptables -A FORWARD -i %i -j ACCEPT
mtu=1280

[Peer]  # the exit
publickey = ` + wgPub + `
PresharedKey = ` + wgPSK + `
Endpoint = vpn.example:51820
AllowedIPs = 0.0.0.0/0
AllowedIPs = ::/0
PersistentKeepalive = 25

[Peer]
PublicKey = ` + wgPub + `
Endpoint = [2001:db8::7]:51821
AllowedIPs = 10.9.0.0/16, 192.0.2.77

[Peer]
PublicKey = ` + wgPub + `
Endpoint = vpn.example.:51822
AllowedIPs = 192.0.2.0/24
PersistentKeepalive = off
`
	file := write(t, filepath.Join(dir, "wg.conf"), conf, 0o600)
	r, err := wireguard(file)
	if err != nil {
		t.Fatal(err)
	}
	want := wgSettings{
		SecretKey: wgPriv,
		Address:   []string{"10.34.0.3/32", "fd30:2::3/128"},
		Peers: []wgPeer{
			{PublicKey: wgPub, PreSharedKey: wgPSK, Endpoint: "vpn.example:51820", AllowedIPs: []string{"0.0.0.0/0", "::/0"}, KeepAlive: 25},
			{PublicKey: wgPub, Endpoint: "[2001:db8::7]:51821", AllowedIPs: []string{"10.9.0.0/16", "192.0.2.77/32"}},
			{PublicKey: wgPub, Endpoint: "vpn.example.:51822", AllowedIPs: []string{"192.0.2.0/24"}},
		},
		MTU: 1280, NoKernelTun: true,
	}
	got, _ := r.Value.(wgSettings)
	if !wgEqual(got, want) {
		t.Errorf("settings\n got %+v\nwant %+v", got, want)
	}
	if !slices.Equal(r.Secrets, []string{wgPriv, wgPSK}) {
		t.Errorf("secrets to redact = %q", r.Secrets)
	}
	if r.Note != "vpn.example:51820, [2001:db8::7]:51821, vpn.example.:51822" {
		t.Errorf("note = %q", r.Note)
	}

	// The whole settings of an outbound: the MTU wg-quick defaults to, host
	// bits of an AllowedIPs network cleared, an Address's kept, no keepAlive
	// or preSharedKey when the file has none.
	minimal := write(t, filepath.Join(dir, "min.conf"), "[Interface]\nPrivateKey="+wgPriv+"\nAddress=10.0.0.2/24\n[Peer]\nPublicKey="+wgPub+"\nEndpoint=203.0.113.7:51820\nAllowedIPs=10.0.0.9/24\n", 0o400)
	src := write(t, filepath.Join(dir, "c.json"), `{"outbounds": [{"protocol": "wireguard", "settings": {"$wireguard": "`+minimal+`"}}]}`, 0o600)
	c, err := resolveFile(src)
	if err != nil {
		t.Fatal(err)
	}
	wantOut := `{"outbounds":[{"protocol":"wireguard","settings":{"secretKey":"` + wgPriv + `","address":["10.0.0.2/24"],"peers":[{"publicKey":"` + wgPub + `","endpoint":"203.0.113.7:51820","allowedIPs":["10.0.0.0/24"]}],"mtu":1420,"noKernelTun":true}}]}` + "\n"
	if string(c.Out) != wantOut {
		t.Errorf("resolved\n got %s\nwant %s", c.Out, wantOut)
	}
	wantRefs := []envconf.Ref{{Path: "outbounds[0].settings", Kind: "$wireguard", File: minimal, Note: "203.0.113.7:51820"}}
	if !slices.Equal(c.Refs, wantRefs) {
		t.Errorf("refs = %v, want %v", c.Refs, wantRefs)
	}
	if !slices.Equal(c.Values, []string{wgPriv}) {
		t.Errorf("values to redact = %q", c.Values)
	}
}

func wgEqual(a, b wgSettings) bool {
	if a.SecretKey != b.SecretKey || a.MTU != b.MTU || a.NoKernelTun != b.NoKernelTun ||
		!slices.Equal(a.Address, b.Address) || len(a.Peers) != len(b.Peers) {
		return false
	}
	for i := range a.Peers {
		p, q := a.Peers[i], b.Peers[i]
		if p.PublicKey != q.PublicKey || p.PreSharedKey != q.PreSharedKey || p.Endpoint != q.Endpoint ||
			p.KeepAlive != q.KeepAlive || !slices.Equal(p.AllowedIPs, q.AllowedIPs) {
			return false
		}
	}
	return true
}

// Each refusal names the file, a line or a section, and what is wrong, and
// never a key: the private key and the preshared key are the secrets.
func TestWireGuardRefusals(t *testing.T) {
	dir := t.TempDir()
	iface := "[Interface]\nPrivateKey = " + wgPriv + "\nAddress = 10.34.0.3/32\n"
	peer := "[Peer]\nPublicKey = " + wgPub + "\nPresharedKey = " + wgPSK + "\nEndpoint = vpn.example:51820\nAllowedIPs = 0.0.0.0/0\n"
	for _, tc := range []struct{ name, content, want string }{
		{"empty", "", "has no [Interface]"},
		{"no peer", iface, "has no [Peer]"},
		{"no interface", peer, "has no [Interface]"},
		{"no private key", "[Interface]\nAddress = 10.34.0.3/32\n" + peer, "the [Interface] on line 1 has no PrivateKey"},
		{"no address", "[Interface]\nPrivateKey = " + wgPriv + "\n" + peer, "the [Interface] on line 1 has no Address"},
		{"no endpoint", iface + "[Peer]\nPublicKey = " + wgPub + "\nAllowedIPs = 0.0.0.0/0\n", "the [Peer] on line 4 has no Endpoint"},
		{"no public key", iface + "[Peer]\nEndpoint = vpn.example:51820\nAllowedIPs = 0.0.0.0/0\n", "the [Peer] on line 4 has no PublicKey"},
		{"no allowed IPs", iface + "[Peer]\nPublicKey = " + wgPub + "\nEndpoint = vpn.example:51820\n", "the [Peer] on line 4 has no AllowedIPs"},
		{"a key before a section", "PrivateKey = " + wgPriv + "\n" + iface + peer, "line 1: PrivateKey before any [Interface] or [Peer]"},
		{"an unknown section", iface + "[Peers]\n" + peer, "line 4: a section other than [Interface] and [Peer]"},
		{"an unclosed section", iface + "[Peer\n", "line 4: a section header that does not end in ]"},
		{"two interfaces", iface + iface + peer, "line 4: a second [Interface], after the one on line 1"},
		{"a typo in a key", iface + "[Peer]\nPublicKey = " + wgPub + "\nEndpiont = vpn.example:51820\n", "line 6: Endpiont is not a key of [Peer] that wg-quick knows"},
		{"an interface key in a peer", iface + peer + "DNS = 1.1.1.1\n", "line 9: DNS is not a key of [Peer] that wg-quick knows"},
		{"a line with no =", iface + peer + "Endpoint vpn.example:51820\n", "line 9: neither a [section] nor a key = value"},
		{"a key alone on a line", iface + peer + wgPSK + "\n", "line 9: a key is empty"},
		{"a key pasted as a key name", iface + peer + wgPSK + " = x\n", "line 9: a key is not a key of [Peer]"},
		{"a private key twice", "[Interface]\nPrivateKey = " + wgPriv + "\nPrivateKey = " + wgPSK + "\nAddress = 10.34.0.3/32\n" + peer, "line 3: PrivateKey again in this [Interface], first on line 2"},
		{"a short private key", "[Interface]\nPrivateKey = " + wgPriv[:40] + "\nAddress = 10.34.0.3/32\n" + peer, "line 2: PrivateKey is not a WireGuard key, 32 bytes in base64"},
		{"a hex private key", "[Interface]\nPrivateKey = " + strings.Repeat("ab", 32) + "\nAddress = 10.34.0.3/32\n" + peer, "line 2: PrivateKey is not a WireGuard key"},
		{"a bad preshared key", iface + "[Peer]\nPublicKey = " + wgPub + "\nPresharedKey = " + wgPSK[1:] + "\n", "line 6: PresharedKey is not a WireGuard key"},
		{"an empty value", iface + "[Peer]\nPublicKey =\n", "line 5: PublicKey is empty"},
		{"a bad address", "[Interface]\nPrivateKey = " + wgPriv + "\nAddress = 10.34.0.300/32\n" + peer, "line 3: Address holds an entry that is not an IPv4 or IPv6 address"},
		{"an address with a zone", "[Interface]\nPrivateKey = " + wgPriv + "\nAddress = fe80::1%eth0\n" + peer, "line 3: Address holds an entry"},
		{"a bad allowed IP", iface + "[Peer]\nAllowedIPs = 0.0.0.0/33\n", "line 5: AllowedIPs holds an entry"},
		{"a trailing comma", iface + "[Peer]\nAllowedIPs = 0.0.0.0/0,\n", "line 5: AllowedIPs holds an entry"},
		{"an endpoint with no port", iface + "[Peer]\nEndpoint = vpn.example\n", "line 5: Endpoint is not a host, a colon and a port"},
		{"an endpoint's port 0", iface + "[Peer]\nEndpoint = vpn.example:0\n", "line 5: Endpoint has a port that is not a number from 1 to 65535"},
		{"IPv6 without brackets", iface + "[Peer]\nEndpoint = 2001:db8::7:51820\n", "line 5: Endpoint is not a host, a colon and a port"},
		{"a name in brackets", iface + "[Peer]\nEndpoint = [vpn.example]:51820\n", "line 5: Endpoint has brackets holding something other than an IPv6 address"},
		{"a name ending in two dots", iface + "[Peer]\nEndpoint = vpn.example..:51820\n", "line 5: Endpoint does not name a DNS name"},
		{"a URL endpoint", iface + "[Peer]\nEndpoint = udp://vpn.example:51820\n", "line 5: Endpoint"},
		{"an MTU too small", "[Interface]\nPrivateKey = " + wgPriv + "\nAddress = 10.34.0.3/32\nMTU = 576\n" + peer, "line 4: MTU is not a number from 1280 to 65535"},
		{"a keepalive word", iface + "[Peer]\nPersistentKeepalive = always\n", "line 5: PersistentKeepalive is neither off nor a number"},
	} {
		t.Run(tc.name, func(t *testing.T) {
			file := write(t, filepath.Join(dir, "wg.conf"), tc.content, 0o600)
			src := write(t, filepath.Join(dir, "c.json"), `{"outbounds": [{"protocol": "wireguard", "settings": {"$wireguard": "`+file+`"}}]}`, 0o600)
			_, err := resolveFile(src)
			if err == nil || !strings.Contains(err.Error(), "outbounds[0].settings: "+file+" ") || !strings.Contains(err.Error(), tc.want) {
				t.Fatalf("err = %v\nwant %q", err, tc.want)
			}
			for _, k := range []string{wgPriv, wgPSK, wgPriv[:12], wgPSK[:12], wgPriv[20:32], wgPSK[1:13]} {
				if strings.Contains(err.Error(), k) {
					t.Errorf("error %q carries key material %q", err, k)
				}
			}
		})
	}
}

func TestUpstreams(t *testing.T) {
	dir := t.TempDir()
	encoded := strings.NewReplacer("+", "%2B", "/", "%2F", "=", "%3D").Replace(wgPriv)
	list := `# the ways out, in order
socks5://alice:p@ss:word@proxy.example:1080 name=isp-a
https://bob:secret@203.0.113.9:8443         name=isp-b

wireguard://` + wgPriv + `@vpn.example:51820?publickey=` + wgPub + `&address=10.34.0.3/32,fd30:2::3/128&mtu=1280 name=home group=upstream,ipv6
openvpn
wireguard://` + encoded + `@[2001:db8::7]:51820/?PublicKey=` + wgPub + `&presharedkey=` + wgPSK + `&address=fd30:2::4/128&allowedips=::/0&keepalive=25#my%20exit group=ipv6
socks5+tls://carol:pw@[2001:db8::9]:1080 group=ipv6 name=isp-c6
http://198.51.100.4:3128
`
	file := write(t, filepath.Join(dir, "upstreams"), list, 0o600)
	aliases, err := upstreamAliases("openvpn=socks5://vpn:1080")
	if err != nil {
		t.Fatal(err)
	}
	outs, secrets, note, err := parseUpstreams(list, aliases, "isp-b, isp-c6")
	if err != nil {
		t.Fatal(err)
	}
	type got struct{ tag, protocol, tls, where string }
	var have []got
	for _, o := range outs {
		g := got{tag: o.Tag, protocol: o.Protocol}
		if o.StreamSettings != nil {
			g.tls = o.StreamSettings.Security
		}
		switch s := o.Settings.(type) {
		case proxyServer:
			g.where = s.Address
		case wgSettings:
			g.where = s.Peers[0].Endpoint
		}
		have = append(have, g)
	}
	want := []got{
		// isp-b pinned first, then the rest of the group in order.
		{"upstream-0", "http", "tls", "203.0.113.9"},
		{"upstream-b1", "socks", "", "proxy.example"},
		{"upstream-b2", "wireguard", "", "vpn.example:51820"},
		{"upstream-b3", "socks", "", "vpn"},
		{"upstream-b4", "http", "", "198.51.100.4"},
		// isp-c6 pinned first in ipv6; home is in both groups.
		{"ipv6-0", "socks", "tls", "2001:db8::9"},
		{"ipv6-b1", "wireguard", "", "vpn.example:51820"},
		{"ipv6-b2", "wireguard", "", "[2001:db8::7]:51820"},
	}
	if !slices.Equal(have, want) {
		t.Fatalf("outbounds\n got %+v\nwant %+v", have, want)
	}
	if p := outs[1].Settings.(proxyServer); p.User != "alice" || p.Pass != "p@ss:word" || p.Port != 1080 {
		t.Errorf("the userinfo did not split at the last @ and the first colon: %+v", p)
	}
	if w := outs[2].Settings.(wgSettings); w.SecretKey != wgPriv || w.MTU != 1280 || !slices.Equal(w.Address, []string{"10.34.0.3/32", "fd30:2::3/128"}) ||
		!slices.Equal(w.Peers[0].AllowedIPs, []string{"0.0.0.0/0", "::/0"}) || !w.NoKernelTun {
		t.Errorf("the first wireguard URL: %+v", w)
	}
	if w := outs[7].Settings.(wgSettings); w.SecretKey != wgPriv || w.Peers[0].PreSharedKey != wgPSK || w.Peers[0].KeepAlive != 25 ||
		!slices.Equal(w.Peers[0].AllowedIPs, []string{"::/0"}) {
		t.Errorf("the percent-encoded wireguard URL: %+v", w)
	}
	for _, s := range []string{"alice", "p@ss:word", "bob", "secret", "carol", "pw", wgPriv, wgPSK} {
		if !slices.Contains(secrets, s) {
			t.Errorf("%q is not among the values to redact", s)
		}
		if strings.Contains(note, s) {
			t.Errorf("the summary note %q shows %q", note, s)
		}
	}
	if !strings.Contains(note, "upstream-0 (isp-b) http 203.0.113.9:8443") || !strings.Contains(note, "ipv6-b2 wireguard [2001:db8::7]:51820") {
		t.Errorf("the summary note %q does not name the tags, names and endpoints", note)
	}

	// Through the reference, with the aliases from the environment.
	t.Setenv("XRAY_UPSTREAM_ALIASES", "openvpn=socks5://vpn:1080")
	t.Setenv("XRAY_UPSTREAM_PIN", "")
	src := write(t, filepath.Join(dir, "c.json"), `{"outbounds": {"$upstreams": "`+file+`"}}`, 0o600)
	c, err := resolveFile(src)
	if err != nil {
		t.Fatal(err)
	}
	if !bytes.Contains(c.Out, []byte(`"tag":"upstream-0","protocol":"socks","settings":{"address":"proxy.example"`)) {
		t.Errorf("without a pin the first line is not upstream-0: %s", c.Out)
	}
}

func TestUpstreamsRefusals(t *testing.T) {
	aliases := map[string]string{"openvpn": "socks5://vpn:1080"}
	wg := "wireguard://" + wgPriv + "@vpn.example:51820?publickey=" + wgPub + "&address=10.34.0.3/32"
	for _, tc := range []struct{ name, list, pin, want string }{
		{"empty", "", "", "lists no upstream"},
		{"comments only", "# nothing yet\n\n", "", "lists no upstream"},
		{"no scheme", "alice:secret@proxy.example:1080\n", "", "line 1: does not start with a URL"},
		{"an undefined word", "socks5://proxy.example:1080\nwarp\n", "", "line 2: warp is not a word XRAY_UPSTREAM_ALIASES defines"},
		{"an unknown scheme", "ss://alice:secret@proxy.example:8388\n", "", "line 1: its scheme is not socks5"},
		{"a bad proxy", "socks5://alice@proxy.example:1080\n", "", "line 1: does not hold [user:pass@]host:port"},
		{"an unknown option", "socks5://proxy.example:1080 weight=2\n", "", "line 1: after the URL comes name="},
		{"an option twice", "socks5://proxy.example:1080 name=a name=b\n", "", "line 1: after the URL comes name="},
		{"a bare word option", "socks5://proxy.example:1080 ipv6\n", "", "line 1: after the URL comes name="},
		{"a bad name", "socks5://proxy.example:1080 name=ISP_A\n", "", "line 1: a name is 1 to 32"},
		{"a bad group", "socks5://proxy.example:1080 group=v6-only\n", "", "line 1: a group is 1 to 16"},
		{"a group twice on a line", "socks5://proxy.example:1080 group=upstream,ipv6,upstream\n", "", "line 1: group= lists upstream twice"},
		{"a URL after a repeated group", "socks5://proxy.example:1080 group=upstream,upstream,socks5://alice:secret@proxy.example:1080\n", "", "line 1: group= lists upstream twice"},
		{"a name twice", "socks5://a.example:1080 name=isp\nsocks5://b.example:1080 name=isp\n", "", "line 2: name=isp again, first on line 1"},
		{"a pin no line has", "socks5://a.example:1080 name=isp\n", "home", `XRAY_UPSTREAM_PIN names "home"`},
		{"a URL as the pin", "socks5://a.example:1080 name=isp\n", "socks5://alice:secret@proxy.example:1080", "XRAY_UPSTREAM_PIN holds something that is not a line name"},
		{"two pins in a group", "socks5://a.example:1080 name=a\nsocks5://b.example:1080 name=b\n", "a,b", "XRAY_UPSTREAM_PIN pins a and b, both in group upstream"},
		{"a wireguard URL with no key", "wireguard://vpn.example:51820?publickey=" + wgPub + "\n", "", "line 1: is a wireguard:// URL with no private key"},
		{"an unknown wireguard key", wg + "&reserved=1,2,3\n", "", "line 1: is a wireguard:// URL with reserved, which is none of"},
		{"a wireguard key twice", wg + "&mtu=1280&mtu=1420\n", "", "line 1: is a wireguard:// URL with mtu twice"},
		{"a wireguard URL with no address", "wireguard://" + wgPriv + "@vpn.example:51820?publickey=" + wgPub + "\n", "", "settings fail: the [Interface] on line 1 has no Address"},
		{"a short wireguard key", "wireguard://" + wgPriv[:40] + "@vpn.example:51820?publickey=" + wgPub + "&address=10.34.0.3/32\n", "", "settings fail: PrivateKey is not a WireGuard key"},
		{"a line break smuggled in", wg + "&mtu=1280%0A[Peer]\n", "", "line 1: is a wireguard:// URL with a line break or a # in a value"},
	} {
		t.Run(tc.name, func(t *testing.T) {
			_, _, _, err := parseUpstreams(tc.list, aliases, tc.pin)
			if err == nil || !strings.Contains(err.Error(), tc.want) {
				t.Fatalf("err = %v\nwant %q", err, tc.want)
			}
			for _, s := range []string{"alice", "secret", wgPriv, wgPriv[:12], wgPub[:12]} {
				if strings.Contains(err.Error(), s) {
					t.Errorf("error %q carries %q", err, s)
				}
			}
		})
	}
	for _, env := range []string{"openvpn", "openvpn=vpn:1080", "Open=socks5://vpn:1080", "a=socks5://x.example:1 a=socks5://y.example:1", "vpn=socks5://alice:secret@vpn:1080"} {
		if _, err := upstreamAliases(env); err == nil {
			t.Errorf("XRAY_UPSTREAM_ALIASES=%q was taken", env)
		}
	}
}
