// xray-entrypoint starts Xray on a config whose secrets are files.
//
//	xray-entrypoint [run [xray run flags...]]  resolve, test, then exec xray
//	xray-entrypoint healthcheck                probe egress through Xray
//	xray-entrypoint vless-encryption <seed>    print the client's VLESS encryption
//	xray-entrypoint reality-password <key>     print the client's REALITY password
//	xray-entrypoint <anything else...>         exec xray with those arguments
//
// Xray reads no value from a file and expands no variable, so a secret can
// only reach it inside its JSON config. This replaces each JSON object that is
// exactly {"$file": "/absolute/path"} with that file's content as a string, or
// exactly {"$vlessDecryption": "/absolute/path"} with the VLESS Encryption
// server key derived from the seed in that file, or exactly
// {"$vlessClients": "/absolute/path"} with the VLESS clients that file lists,
// and changes nothing else. The contract is in images/xray/README.md.
package main

import (
	"bytes"
	"crypto/ecdh"
	"crypto/mlkem"
	"encoding/base64"
	"encoding/hex"
	"encoding/json"
	"errors"
	"fmt"
	"io"
	"io/fs"
	"net/http"
	"net/url"
	"os"
	"os/exec"
	"path/filepath"
	"regexp"
	"slices"
	"sort"
	"strings"
	"syscall"
	"time"
	"unicode/utf8"
)

const (
	xrayBin = "/usr/local/bin/xray"
	// EX_CONFIG, the code every image in this repository refuses a
	// configuration with.
	exConfig  = 78
	maxSecret = 64 << 10
)

// The image's own settings, in summary order. The Dockerfile sets the same
// defaults as ENV so `docker inspect` shows them; these apply when one is set
// to the empty string.
var curated = []struct{ name, def string }{
	{"XRAY_SOURCE_DIR", "/etc/xray"},
	{"XRAY_RUNTIME_DIR", "/run/xray"},
	{"XRAY_HEALTHCHECK_URL", "https://www.gstatic.com/generate_204"},
	{"XRAY_HEALTHCHECK_PROXY", ""},
	{"XRAY_HEALTHCHECK_TIMEOUT", "10s"},
}

// Xray's own names, from common/platform. They reach Xray untouched and are
// not warned about.
var upstream = map[string]bool{
	"XRAY_LOCATION_ASSET": true, "XRAY_LOCATION_CERT": true,
	"XRAY_LOCATION_CONFIG": true, "XRAY_LOCATION_CONFDIR": true,
	"XRAY_BUF_READV": true, "XRAY_BUF_SPLICE": true,
	"XRAY_RAY_BUFFER_SIZE": true, "XRAY_BROWSER_DIALER": true,
	"XRAY_CONE_DISABLED": true, "XRAY_JSON_STRICT": true,
	"XRAY_TUN_FD": true, "XRAY_VMESS_PADDING": true,
	"XRAY_XUDP_BASEKEY": true, "XRAY_XUDP_SHOW": true,
}

func main() {
	args := os.Args[1:]
	if len(args) > 0 && args[0] == "healthcheck" {
		os.Exit(healthcheck())
	}
	if len(args) > 0 {
		if derive, ok := clientValues[args[0]]; ok {
			os.Exit(printClientValue(args[0], derive, args[1:]))
		}
	}
	if len(args) > 0 && args[0] != "run" {
		execXray(args...) // uuid, x25519, vlessenc, version, ...
	}
	if len(args) > 0 {
		args = args[1:]
	}
	if err := start(args); err != nil {
		fmt.Fprintln(os.Stderr, "FATAL:", err)
		os.Exit(exConfig)
	}
}

func setting(name string) string {
	for _, c := range curated {
		if c.name == name {
			if v := os.Getenv(name); v != "" {
				return v
			}
			return c.def
		}
	}
	panic("not a curated name: " + name)
}

func isCurated(name string) bool {
	for _, c := range curated {
		if c.name == name {
			return true
		}
	}
	return false
}

func start(extra []string) error {
	warnUnknown()
	src := filepath.Clean(setting("XRAY_SOURCE_DIR"))
	run := filepath.Clean(setting("XRAY_RUNTIME_DIR"))
	if err := overlap(src, run); err != nil {
		return err
	}
	// Checked here as well as by the probe, so a bad value stops the
	// deployment rather than turning into an unhealthy container later.
	if _, _, _, err := healthSettings(); err != nil {
		return err
	}
	configs, err := resolveDir(src)
	if err != nil {
		return err
	}
	if err := writeRuntime(run, configs); err != nil {
		return err
	}
	version, err := testConfig(run, extra, configs)
	if err != nil {
		return err
	}
	summary(os.Stderr, version, configs)
	execXray(append([]string{"run", "-confdir", run}, extra...)...)
	return nil
}

// The runtime directory is emptied on every start, so it must not be, hold or
// sit inside the source. Compared as real paths: a symlink alias of a writable
// source would otherwise have its config replaced with the resolved secrets,
// and a parent of it would lose it entirely.
func overlap(src, run string) error {
	s, r := canonical(src), canonical(run)
	if within(s, r) || within(r, s) {
		return fmt.Errorf("XRAY_RUNTIME_DIR (%s) and XRAY_SOURCE_DIR (%s) overlap, and the runtime directory is emptied on every start. Point them at separate directories", run, src)
	}
	return nil
}

// The absolute path with every symlink resolved. A part that does not exist
// yet keeps its name under its parent's resolved path, so a runtime directory
// still to be created is judged by where it would be created.
func canonical(p string) string {
	if abs, err := filepath.Abs(p); err == nil {
		p = abs
	}
	if r, err := filepath.EvalSymlinks(p); err == nil {
		return r
	}
	parent := filepath.Dir(p)
	if parent == p {
		return p
	}
	return filepath.Join(canonical(parent), filepath.Base(p))
}

// Whether path is parent or lies under it.
func within(parent, path string) bool {
	rel, err := filepath.Rel(parent, path)
	return err == nil && rel != ".." && !strings.HasPrefix(rel, ".."+string(filepath.Separator))
}

func execXray(args ...string) {
	err := syscall.Exec(xrayBin, append([]string{xrayBin}, args...), os.Environ())
	fmt.Fprintf(os.Stderr, "FATAL: exec %s: %v\n", xrayBin, err)
	os.Exit(1)
}

func warnUnknown() {
	for _, kv := range os.Environ() {
		name, _, _ := strings.Cut(kv, "=")
		switch {
		case !strings.HasPrefix(name, "XRAY_"), upstream[name], isCurated(name):
		case strings.HasPrefix(name, "XRAY_CONF__"):
			fmt.Fprintf(os.Stderr, "WARN: %s is set, but this image has no XRAY_CONF__ passthrough channel. Xray is configured by the JSON files in XRAY_SOURCE_DIR -- see images/xray/README.md.\n", name)
		default:
			fmt.Fprintf(os.Stderr, "WARN: %s is set but neither this image nor Xray reads it. Check the spelling against images/xray/README.md.\n", name)
		}
	}
}

// One source file and what became of it.
type config struct {
	src    string   // the file in XRAY_SOURCE_DIR
	out    []byte   // resolved JSON, written under the same name in XRAY_RUNTIME_DIR
	refs   []ref    // in document order
	values []string // the resolved contents, so Xray's messages can be redacted
}

// note follows the path in the summary, as a count where the value is a list.
type ref struct{ path, kind, file, note string }

// What a reference resolves to.
type resolution struct {
	value   any      // replaces the reference
	secrets []string // redacted from Xray's output
	note    string
}

// The reference forms, in the order they are looked for: an object whose one
// key is one of these, naming an absolute path.
var references = []struct {
	key     string
	resolve func(file string) (resolution, error)
}{
	{"$file", secret(readSecret)},
	{"$vlessDecryption", secret(vlessDecryption)},
	{"$vlessClients", vlessClients},
}

// A reference that resolves to one string, which is itself the secret.
func secret(read func(string) (string, error)) func(string) (resolution, error) {
	return func(file string) (resolution, error) {
		s, err := read(file)
		return resolution{value: s, secrets: []string{s}}, err
	}
}

func resolveDir(dir string) ([]*config, error) {
	entries, err := os.ReadDir(dir)
	if err != nil {
		return nil, fmt.Errorf("XRAY_SOURCE_DIR is %s, which cannot be read (%v). Mount the Xray config there", dir, cause(err))
	}
	var configs []*config
	for _, e := range entries {
		p := filepath.Join(dir, e.Name())
		info, err := os.Stat(p)
		if err != nil {
			return nil, fmt.Errorf("%s: %v", p, cause(err))
		}
		// Xray's -confdir also reads .jsonc, .yaml, .yml and .toml, which this
		// would not have resolved, so anything but JSON is refused, not skipped.
		if filepath.Ext(e.Name()) != ".json" || !info.Mode().IsRegular() {
			return nil, fmt.Errorf("%s is not a .json file. XRAY_SOURCE_DIR holds only the JSON files Xray is to read", p)
		}
		c, err := resolveFile(p)
		if err != nil {
			return nil, err
		}
		configs = append(configs, c)
	}
	if len(configs) == 0 {
		return nil, fmt.Errorf("XRAY_SOURCE_DIR is %s, which holds no .json file. Mount the Xray config there", dir)
	}
	return configs, nil
}

func resolveFile(p string) (*config, error) {
	raw, err := os.ReadFile(p)
	if err != nil {
		return nil, fmt.Errorf("%s: %v", p, cause(err))
	}
	// UseNumber keeps every number as written; float64 would round a large one.
	dec := json.NewDecoder(bytes.NewReader(raw))
	dec.UseNumber()
	var doc any
	if err := dec.Decode(&doc); err != nil {
		return nil, fmt.Errorf("%s is not valid JSON: %v", p, err)
	}
	if _, err := dec.Token(); err != io.EOF {
		return nil, fmt.Errorf("%s is not valid JSON: something follows its value", p)
	}
	c := &config{src: p}
	if doc, err = c.resolve(doc, ""); err != nil {
		return nil, err
	}
	var out bytes.Buffer
	enc := json.NewEncoder(&out)
	enc.SetEscapeHTML(false)
	if err := enc.Encode(doc); err != nil {
		return nil, fmt.Errorf("%s: %v", p, err)
	}
	c.out = out.Bytes()
	return c, nil
}

func (c *config) resolve(v any, path string) (any, error) {
	switch t := v.(type) {
	case map[string]any:
		for _, r := range references {
			if target, ok := t[r.key]; ok {
				return c.reference(t, r.key, target, r.resolve, path)
			}
		}
		keys := make([]string, 0, len(t))
		for k := range t {
			keys = append(keys, k)
		}
		sort.Strings(keys)
		for _, k := range keys {
			child := k
			if path != "" {
				child = path + "." + k
			}
			r, err := c.resolve(t[k], child)
			if err != nil {
				return nil, err
			}
			t[k] = r
		}
	case []any:
		for i := range t {
			r, err := c.resolve(t[i], fmt.Sprintf("%s[%d]", path, i))
			if err != nil {
				return nil, err
			}
			t[i] = r
		}
	}
	return v, nil
}

// A near miss is an error rather than a literal, or a typo would reach Xray
// as an object it rejects with a message about some other field, or accepts.
func (c *config) reference(obj map[string]any, key string, target any, resolve func(string) (resolution, error), path string) (any, error) {
	if len(obj) != 1 {
		var others []string
		for k := range obj {
			if k != key {
				others = append(others, k)
			}
		}
		sort.Strings(others)
		return nil, c.errorf(path, `an object holding %q holds nothing else, and this one also holds %s`, key, strings.Join(others, ", "))
	}
	file, ok := target.(string)
	if !ok || !filepath.IsAbs(file) {
		return nil, c.errorf(path, `%q must be an absolute path, as a string`, key)
	}
	r, err := resolve(file)
	if err != nil {
		return nil, c.errorf(path, "%s %v", file, err)
	}
	c.refs = append(c.refs, ref{path, key, file, r.note})
	c.values = append(c.values, r.secrets...)
	return r.value, nil
}

// Names the file, the JSON path and the referenced path; never a value.
func (c *config) errorf(path, format string, args ...any) error {
	if path == "" {
		path = "the top level"
	}
	return fmt.Errorf("%s: %s: %s", c.src, path, fmt.Sprintf(format, args...))
}

// The checks the shared helper and envfile-exec make on a <NAME>_FILE, with
// the same limits. The error completes a sentence that starts with the path.
func readSecret(name string) (string, error) {
	// O_NONBLOCK so a FIFO opens at once, and the type is checked on what was
	// opened rather than on the path, which could change in between.
	f, err := os.OpenFile(name, os.O_RDONLY|syscall.O_NONBLOCK, 0)
	switch {
	case errors.Is(err, fs.ErrNotExist):
		return "", errors.New("does not exist")
	case errors.Is(err, fs.ErrPermission):
		return "", fmt.Errorf("is not readable by uid %d", os.Getuid())
	case err != nil:
		return "", fmt.Errorf("could not be opened: %v", cause(err))
	}
	defer f.Close()
	info, err := f.Stat()
	if err != nil {
		return "", fmt.Errorf("could not be read: %v", cause(err))
	}
	if info.IsDir() {
		return "", errors.New("is a directory, which is what Compose leaves when a secret's source file is missing")
	}
	if !info.Mode().IsRegular() {
		return "", errors.New("is not a regular file")
	}
	b, err := io.ReadAll(io.LimitReader(f, maxSecret+1))
	switch {
	case err != nil:
		return "", fmt.Errorf("could not be read: %v", cause(err))
	case len(b) > maxSecret:
		return "", fmt.Errorf("is larger than %d bytes", maxSecret)
	case bytes.IndexByte(b, 0) >= 0:
		return "", errors.New("contains a NUL byte")
	case !utf8.Valid(b):
		return "", errors.New("is not valid UTF-8")
	}
	// One trailing newline: every editor adds one and no secret wants it.
	return strings.TrimSuffix(string(b), "\n"), nil
}

// A seed file holds the 64 bytes of an ML-KEM-768 seed as 128 hex characters,
// which a generator that can only write text can produce. Both halves of a
// VLESS Encryption key pair derive from it, so the server's and the client's
// configs can each be built from the one secret.
func readSeed(name string) ([]byte, error) {
	s, err := readSecret(name)
	if err != nil {
		return nil, err
	}
	// hex's error quotes the offending character, so it is not passed on.
	seed, err := hex.DecodeString(s)
	if err != nil || len(seed) != mlkem.SeedSize {
		return nil, fmt.Errorf("does not hold a seed: %d hex characters and nothing else, the %d bytes of an ML-KEM-768 seed", 2*mlkem.SeedSize, mlkem.SeedSize)
	}
	return seed, nil
}

// The server half of the ML-KEM-768 pair `xray vlessenc` prints.
func vlessDecryption(name string) (string, error) {
	seed, err := readSeed(name)
	if err != nil {
		return "", err
	}
	return "mlkem768x25519plus.native.600s." + base64.RawURLEncoding.EncodeToString(seed), nil
}

// The client half: the encapsulation key, as `xray mlkem768 -i` prints it.
func vlessEncryption(seed []byte) (string, error) {
	dk, err := mlkem.NewDecapsulationKey768(seed)
	if err != nil {
		return "", err
	}
	return "mlkem768x25519plus.native.0rtt." + base64.RawURLEncoding.EncodeToString(dk.EncapsulationKey().Bytes()), nil
}

func vlessEncryptionFile(name string) (string, error) {
	seed, err := readSeed(name)
	if err != nil {
		return "", err
	}
	return vlessEncryption(seed)
}

// The REALITY password a client sets: the X25519 public key of the server's
// private key, as `xray x25519 -i` prints it under "Password (PublicKey)".
// The file holds the private key as Xray's config takes it, 43 base64url
// characters, and is decoded with the call Xray's loader makes, so any file
// the server accepts gives the password its clients need. That call is
// lenient: 43 random characters leave 2 spare bits, which strict decoding
// refuses three times in four, and it skips line breaks.
func realityPassword(name string) (string, error) {
	s, err := readSecret(name)
	if err != nil {
		return "", err
	}
	// base64's error quotes the offending byte, so it is not passed on.
	key, err := base64.RawURLEncoding.DecodeString(s)
	if err != nil || len(key) != 32 {
		return "", errors.New("does not hold a REALITY private key: 43 base64url characters and nothing else, unpadded, the 32 bytes of an X25519 key")
	}
	priv, err := ecdh.X25519().NewPrivateKey(key)
	if err != nil {
		return "", err
	}
	return base64.RawURLEncoding.EncodeToString(priv.PublicKey().Bytes()), nil
}

// One VLESS client as Xray's inbound takes it. Xray shows the email as the
// user's label in its logs and stats.
type vlessClient struct {
	ID    string `json:"id"`
	Email string `json:"email,omitempty"`
}

var (
	uuidRE = regexp.MustCompile(`^[0-9a-fA-F]{8}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{12}$`)
	nameRE = regexp.MustCompile(`^[A-Za-z0-9._@+-]{1,64}$`)
)

// A client list holds one client per line, "<uuid> [name]", so one device is
// revoked by deleting its line and the others keep their ids. The flow is the
// inbound's "settings.flow", which Xray gives every client without its own.
func vlessClients(name string) (resolution, error) {
	s, err := readSecret(name)
	if err != nil {
		return resolution{}, err
	}
	clients, err := parseClients(s)
	if err != nil {
		return resolution{}, err
	}
	r := resolution{value: clients, note: fmt.Sprintf("(%d clients)", len(clients))}
	if len(clients) == 1 {
		r.note = "(1 client)"
	}
	for _, c := range clients {
		r.secrets = append(r.secrets, c.ID)
	}
	return r, nil
}

// The errors name a line, never what is on it. An id must be a UUID as
// written: Xray maps any other string of 1 to 30 bytes to a UUIDv5, so a typo
// would become a valid id that locks its device out. Names are compared
// ignoring case, as Xray compares emails, which refuses the second.
func parseClients(s string) ([]vlessClient, error) {
	var clients []vlessClient
	idLine, nameLine := map[string]int{}, map[string]int{}
	for i, line := range strings.Split(s, "\n") {
		n, line := i+1, strings.TrimSpace(line)
		if line == "" || strings.HasPrefix(line, "#") {
			continue
		}
		f := strings.Fields(line)
		if len(f) > 2 {
			return nil, fmt.Errorf(`line %d: %d fields, where a client is "<uuid> [name]"`, n, len(f))
		}
		if !uuidRE.MatchString(f[0]) {
			return nil, fmt.Errorf("line %d: the id is not a UUID, 8-4-4-4-12 hex digits", n)
		}
		c := vlessClient{ID: strings.ToLower(f[0])}
		if first, ok := idLine[c.ID]; ok {
			return nil, fmt.Errorf("line %d: the id is the one on line %d", n, first)
		}
		idLine[c.ID] = n
		if len(f) == 2 {
			if !nameRE.MatchString(f[1]) {
				return nil, fmt.Errorf("line %d: the name is not 1 to 64 of the characters A-Z a-z 0-9 . _ @ + -", n)
			}
			if first, ok := nameLine[strings.ToLower(f[1])]; ok {
				return nil, fmt.Errorf("line %d: the name is the one on line %d, ignoring case", n, first)
			}
			nameLine[strings.ToLower(f[1])] = n
			c.Email = f[1]
		}
		clients = append(clients, c)
	}
	if len(clients) == 0 {
		return nil, errors.New("lists no client: every line is blank or a comment")
	}
	return clients, nil
}

// The commands that print what a client config needs from a server secret.
var clientValues = map[string]func(file string) (string, error){
	"vless-encryption": vlessEncryptionFile,
	"reality-password": realityPassword,
}

// Prints the value and a newline and nothing else, reading the secret from a
// file so that it never reaches a command line, where it would show in
// /proc/<pid>/cmdline and in the host's ps.
func printClientValue(command string, derive func(string) (string, error), args []string) int {
	if len(args) != 1 {
		fmt.Fprintf(os.Stderr, "usage: xray-entrypoint %s <absolute path>\n", command)
		return 2
	}
	// Neither a hex seed nor a base64url key can start with "/", so this
	// catches the secret itself pasted in place of its path, as `xray x25519
	// -i <key>` takes it. The argument is not repeated: it may be that secret.
	if !filepath.IsAbs(args[0]) {
		fmt.Fprintf(os.Stderr, "usage: xray-entrypoint %s <absolute path>\nThe argument given is not an absolute path, and is not shown in case it is the secret itself.\n", command)
		return 2
	}
	value, err := derive(args[0])
	if err != nil {
		fmt.Fprintf(os.Stderr, "FATAL: %s %v\n", args[0], err)
		return exConfig
	}
	fmt.Println(value)
	return 0
}

func cause(err error) error {
	if u := errors.Unwrap(err); u != nil {
		return u
	}
	return err
}

func writeRuntime(dir string, configs []*config) error {
	hint := func(err error) error {
		return fmt.Errorf("XRAY_RUNTIME_DIR is %s, which is not writable by uid %d (%v). Mount a tmpfs there that it owns, such as Compose's `tmpfs: [\"%s:uid=%d,gid=%d,mode=0700\"]`", dir, os.Getuid(), cause(err), dir, os.Getuid(), os.Getgid())
	}
	if err := os.MkdirAll(dir, 0o700); err != nil {
		return hint(err)
	}
	// Best effort: a tmpfs mounted with another owner keeps its mode, and the
	// files below are 0600 either way.
	_ = os.Chmod(dir, 0o700)
	// Emptied first: without a tmpfs the directory outlives a restart, and Xray
	// would merge a file whose source has since been removed.
	old, err := os.ReadDir(dir)
	if err != nil {
		return hint(err)
	}
	for _, e := range old {
		if err := os.RemoveAll(filepath.Join(dir, e.Name())); err != nil {
			return hint(err)
		}
	}
	for _, c := range configs {
		if err := os.WriteFile(filepath.Join(dir, filepath.Base(c.src)), c.out, 0o600); err != nil {
			return hint(err)
		}
	}
	return nil
}

// Runs `xray run -test` on the resolved config and returns Xray's version
// line. Xray quotes the value it rejects ("invalid UUID: <the id>"), so its
// output is printed with every resolved value replaced.
func testConfig(dir string, extra []string, configs []*config) (string, error) {
	out, err := exec.Command(xrayBin, append([]string{"run", "-test", "-confdir", dir}, extra...)...).CombinedOutput()
	var values []string
	for _, c := range configs {
		values = append(values, c.values...)
	}
	text := redact(string(out), values)
	if err != nil {
		fmt.Fprint(os.Stderr, text)
		return "", fmt.Errorf("xray run -test refused the configuration (%v)", err)
	}
	version, _, _ := strings.Cut(text, "\n")
	return version, nil
}

func redact(s string, values []string) string {
	// Longest first, so a value that contains another is replaced whole.
	sorted := slices.Clone(values)
	sort.Slice(sorted, func(i, j int) bool { return len(sorted[i]) > len(sorted[j]) })
	for _, v := range sorted {
		if v != "" {
			s = strings.ReplaceAll(s, v, "<redacted>")
		}
	}
	return s
}

func summary(w io.Writer, version string, configs []*config) {
	fmt.Fprintln(w, "[envconf] xray: effective configuration")
	for _, c := range curated {
		v := setting(c.name)
		switch {
		case c.name == "XRAY_HEALTHCHECK_PROXY" && v == "":
			v = "(unset: the healthcheck checks only that Xray is running)"
		case strings.HasSuffix(c.name, "_URL"), strings.HasSuffix(c.name, "_PROXY"):
			if u, err := url.Parse(v); err == nil {
				v = u.Redacted()
			}
		}
		fmt.Fprintf(w, "[envconf]   source=%-14s %s = %s\n", "env-or-default", c.name, v)
	}
	fmt.Fprintf(w, "[envconf]   source=%-14s xray = %s\n", "image", version)
	for _, c := range configs {
		fmt.Fprintf(w, "[envconf]   source=%-14s %s\n", "config", c.src)
		for _, r := range c.refs {
			from := r.file
			if r.kind != "$file" {
				from = r.kind + " " + r.file
			}
			if r.note != "" {
				from += " " + r.note
			}
			fmt.Fprintf(w, "[envconf]   source=%-14s %s <- %s   (%s)\n", "file", r.path, from, c.src)
		}
	}
	fmt.Fprintln(w, "[envconf] precedence: image default < environment")
}

func healthSettings() (target, proxy *url.URL, timeout time.Duration, err error) {
	target, err = url.Parse(setting("XRAY_HEALTHCHECK_URL"))
	if err != nil || (target.Scheme != "http" && target.Scheme != "https") || target.Host == "" {
		return nil, nil, 0, errors.New("XRAY_HEALTHCHECK_URL must be an http or https URL")
	}
	t := setting("XRAY_HEALTHCHECK_TIMEOUT")
	if timeout, err = time.ParseDuration(t); err != nil || timeout <= 0 {
		return nil, nil, 0, fmt.Errorf("XRAY_HEALTHCHECK_TIMEOUT is %q, which is not a duration such as 10s", t)
	}
	if p := setting("XRAY_HEALTHCHECK_PROXY"); p != "" {
		proxy, err = url.Parse(p)
		if err != nil || proxy.Host == "" || !slices.Contains([]string{"http", "https", "socks5", "socks5h"}, proxy.Scheme) {
			return nil, nil, 0, errors.New("XRAY_HEALTHCHECK_PROXY must be a proxy URL such as http://127.0.0.1:10809 or socks5://127.0.0.1:10808")
		}
	}
	return target, proxy, timeout, nil
}

func healthcheck() int {
	target, proxy, timeout, err := healthSettings()
	if err != nil {
		fmt.Fprintln(os.Stderr, "healthcheck:", err)
		return 1
	}
	if proxy == nil {
		return liveness()
	}
	client := &http.Client{
		Timeout:   timeout,
		Transport: &http.Transport{Proxy: http.ProxyURL(proxy)},
		// A redirect is a captive portal or a block page as often as not, so
		// it is the answer rather than a step towards one.
		CheckRedirect: func(*http.Request, []*http.Request) error { return http.ErrUseLastResponse },
	}
	resp, err := client.Get(target.String())
	if err != nil {
		fmt.Fprintf(os.Stderr, "healthcheck: GET %s through %s: %v\n", target.Redacted(), proxy.Redacted(), err)
		return 1
	}
	resp.Body.Close()
	fmt.Fprintf(os.Stderr, "healthcheck: GET %s through %s: %s\n", target.Redacted(), proxy.Redacted(), resp.Status)
	if resp.StatusCode < 200 || resp.StatusCode > 299 {
		return 1
	}
	return 0
}

// Without a proxy there is no egress to probe, and saying so is the point:
// a green check that tested nothing would read as one that did.
func liveness() int {
	cmdline, err := os.ReadFile("/proc/1/cmdline")
	if err != nil || !bytes.HasPrefix(cmdline, []byte(xrayBin+"\x00")) {
		fmt.Fprintln(os.Stderr, "healthcheck: PID 1 is not Xray")
		return 1
	}
	if found, _ := filepath.Glob(filepath.Join(setting("XRAY_RUNTIME_DIR"), "*.json")); len(found) == 0 {
		fmt.Fprintln(os.Stderr, "healthcheck: XRAY_RUNTIME_DIR holds no config")
		return 1
	}
	fmt.Fprintln(os.Stderr, "healthcheck: Xray is running. XRAY_HEALTHCHECK_PROXY is unset, so egress was not probed")
	return 0
}
