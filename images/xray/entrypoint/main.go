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
// or exactly {"$proxy": "/absolute/path"} with a socks or http outbound's
// settings, split from the [user:pass@]host:port in that file, and changes
// nothing else. The contract is in images/xray/README.md.
package main

import (
	"crypto/ecdh"
	"crypto/mlkem"
	"encoding/base64"
	"encoding/hex"
	"errors"
	"fmt"
	"net"
	"os"
	"os/exec"
	"path/filepath"
	"regexp"
	"strconv"
	"strings"
	"unicode"

	"github.com/morzecrew/platform-images/shared/go/envconf"
)

// The image's own settings are in summary order. Xray's own names, from
// common/platform, reach Xray untouched and are not warned about.
var img = &envconf.Image{
	Name: "xray", Title: "Xray", Bin: "/usr/local/bin/xray", Prefix: "XRAY_",
	Readme: "images/xray/README.md",
	Settings: []envconf.Setting{
		{Name: "XRAY_SOURCE_DIR", Default: "/etc/xray"},
		{Name: "XRAY_RUNTIME_DIR", Default: "/run/xray"},
		{Name: "XRAY_HEALTHCHECK_URL", Default: "https://www.gstatic.com/generate_204"},
		{Name: "XRAY_HEALTHCHECK_PROXY", Default: ""},
		{Name: "XRAY_HEALTHCHECK_TIMEOUT", Default: "10s"},
		{Name: "XRAY_HEALTHCHECK_EXPECT", Default: ""},
	},
	Upstream: map[string]bool{
		"XRAY_LOCATION_ASSET": true, "XRAY_LOCATION_CERT": true,
		"XRAY_LOCATION_CONFIG": true, "XRAY_LOCATION_CONFDIR": true,
		"XRAY_BUF_READV": true, "XRAY_BUF_SPLICE": true,
		"XRAY_RAY_BUFFER_SIZE": true, "XRAY_BROWSER_DIALER": true,
		"XRAY_CONE_DISABLED": true, "XRAY_JSON_STRICT": true,
		"XRAY_TUN_FD": true, "XRAY_VMESS_PADDING": true,
		"XRAY_XUDP_BASEKEY": true, "XRAY_XUDP_SHOW": true,
	},
}

func main() {
	args := os.Args[1:]
	if len(args) > 0 && args[0] == "healthcheck" {
		os.Exit(img.Healthcheck(img.Get("XRAY_RUNTIME_DIR"), "*.json"))
	}
	if len(args) > 0 {
		if derive, ok := clientValues[args[0]]; ok {
			os.Exit(printClientValue(args[0], derive, args[1:]))
		}
	}
	if len(args) > 0 && args[0] != "run" {
		img.Exec(args...) // uuid, x25519, vlessenc, version, ...
	}
	if len(args) > 0 {
		args = args[1:]
	}
	if err := start(args); err != nil {
		fmt.Fprintln(os.Stderr, "FATAL:", err)
		os.Exit(envconf.ExConfig)
	}
}

func start(extra []string) error {
	img.WarnUnknown()
	src := filepath.Clean(img.Get("XRAY_SOURCE_DIR"))
	run := filepath.Clean(img.Get("XRAY_RUNTIME_DIR"))
	// The runtime directory is emptied on every start: a symlink alias of a
	// writable source would have its config replaced with the resolved
	// secrets, and a parent of it would lose it entirely.
	if envconf.Overlap(src, run) {
		return fmt.Errorf("XRAY_RUNTIME_DIR (%s) and XRAY_SOURCE_DIR (%s) overlap, and the runtime directory is emptied on every start. Point them at separate directories", run, src)
	}
	if _, err := img.HealthSettings(); err != nil {
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
	img.Summary(os.Stderr, version, configs)
	img.Exec(append([]string{"run", "-confdir", run}, extra...)...)
	return nil
}

// The reference forms, in the order they are looked for: an object whose one
// key is one of these, naming an absolute path.
var references = []envconf.Reference{
	envconf.File,
	{Key: "$vlessDecryption", Resolve: envconf.Secret(vlessDecryption)},
	{Key: "$vlessClients", Resolve: vlessClients},
	{Key: "$proxy", Resolve: proxy},
}

func resolveDir(dir string) ([]*envconf.Config, error) {
	entries, err := os.ReadDir(dir)
	if err != nil {
		return nil, fmt.Errorf("XRAY_SOURCE_DIR is %s, which cannot be read (%v). Mount the Xray config there", dir, envconf.Cause(err))
	}
	var configs []*envconf.Config
	for _, e := range entries {
		p := filepath.Join(dir, e.Name())
		info, err := os.Stat(p)
		if err != nil {
			return nil, fmt.Errorf("%s: %v", p, envconf.Cause(err))
		}
		// Xray's -confdir also reads .jsonc, .yaml, .yml and .toml, which this
		// would not have resolved, so anything but JSON is refused, not skipped.
		if filepath.Ext(e.Name()) != ".json" || !info.Mode().IsRegular() {
			return nil, fmt.Errorf("%s is not a .json file. XRAY_SOURCE_DIR holds only the JSON files Xray is to read", p)
		}
		c, err := envconf.ResolveFile(p, references)
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

// A seed file holds the 64 bytes of an ML-KEM-768 seed as 128 hex characters,
// which a generator that can only write text can produce. Both halves of a
// VLESS Encryption key pair derive from it, so the server's and the client's
// configs can each be built from the one secret.
func readSeed(name string) ([]byte, error) {
	s, err := envconf.ReadSecret(name)
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
	s, err := envconf.ReadSecret(name)
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
func vlessClients(name string) (envconf.Resolution, error) {
	s, err := envconf.ReadSecret(name)
	if err != nil {
		return envconf.Resolution{}, err
	}
	clients, err := parseClients(s)
	if err != nil {
		return envconf.Resolution{}, err
	}
	r := envconf.Resolution{Value: clients, Note: fmt.Sprintf("(%d clients)", len(clients))}
	if len(clients) == 1 {
		r.Note = "(1 client)"
	}
	for _, c := range clients {
		r.Secrets = append(r.Secrets, c.ID)
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

// The whole "settings" of a socks or http outbound, in Xray's flat form, which
// takes these four keys for both protocols.
type proxyServer struct {
	Address string `json:"address"`
	Port    int    `json:"port"`
	User    string `json:"user,omitempty"`
	Pass    string `json:"pass,omitempty"`
}

// One label of a DNS name: no hyphen at either end, and at most 63 bytes, as
// DNS caps it, with the name at 253; a longer one resolves nowhere.
var (
	labelRE   = regexp.MustCompile(`^[A-Za-z0-9_]([A-Za-z0-9_-]*[A-Za-z0-9_])?$`)
	numericRE = regexp.MustCompile(`^[0-9.]+$`)
)

// A DNS name or an IPv4 address. An IPv6 address comes in brackets. A host of
// digits and dots alone is an IPv4 address or nothing, so 999.999.999.999 is
// refused here rather than looked up.
func validHost(host string) bool {
	if numericRE.MatchString(host) {
		ip := net.ParseIP(host)
		return ip != nil && ip.To4() != nil
	}
	if len(host) > 253 {
		return false
	}
	for label := range strings.SplitSeq(host, ".") {
		if len(label) > 63 || !labelRE.MatchString(label) {
			return false
		}
	}
	return true
}

// An upstream proxy is one secret, "[user:pass@]host:port", so changing
// provider is one edit and one restart. Kept as an address, a port and two
// credentials, it took several, each restarting the service, which ran on a
// mismatched set in between. The user and the password are redacted like any
// secret. host:port is not secret, and the summary shows it, so the operator
// sees where the traffic goes; but only after an @. A line that lost its
// "@host:port" parses as a host and a port, and that port is the password.
func proxy(name string) (envconf.Resolution, error) {
	s, err := envconf.ReadSecret(name)
	if err != nil {
		return envconf.Resolution{}, err
	}
	p, err := parseProxy(s)
	if err != nil {
		return envconf.Resolution{}, err
	}
	r := envconf.Resolution{Value: p, Note: "no credentials"}
	if p.User != "" {
		r.Secrets = []string{p.User, p.Pass}
		r.Note = net.JoinHostPort(p.Address, strconv.Itoa(p.Port))
	}
	return r, nil
}

// The userinfo ends at the last @ and the user at its first colon, so a
// password may hold both. Nothing is percent-decoded: this is not a URL, and a
// scheme is refused so that it is not written as one. The errors never quote
// the value: without its @, "user:pass" parses as a host and a port, and the
// port would be the password.
func parseProxy(s string) (proxyServer, error) {
	fail := func(what string) (proxyServer, error) {
		return proxyServer{}, errors.New("does not hold [user:pass@]host:port: " + what)
	}
	if strings.Contains(s, "://") {
		return proxyServer{}, errors.New("holds a URL. Write user:pass@host:port, without the scheme")
	}
	if strings.IndexFunc(s, unicode.IsSpace) >= 0 {
		return fail("it contains whitespace, where one trailing newline is all a line may have")
	}
	var p proxyServer
	hostport := s
	if i := strings.LastIndexByte(s, '@'); i >= 0 {
		hostport = s[i+1:]
		if p.User, p.Pass, _ = strings.Cut(s[:i], ":"); p.User == "" || p.Pass == "" {
			return fail("before the @ is not a user and a password, both non-empty, joined by a colon")
		}
	}
	// net's error quotes its input, so it is not passed on.
	host, port, err := net.SplitHostPort(hostport)
	switch {
	case err != nil:
		return fail("it does not end in a host, a colon and a port, with an IPv6 address in brackets")
	case host == "":
		return fail("the host is empty")
	case strings.HasPrefix(hostport, "["):
		if net.ParseIP(host) == nil || !strings.Contains(host, ":") {
			return fail("the brackets hold something other than an IPv6 address")
		}
	case !validHost(host):
		return fail("the host is not a DNS name, an IPv4 address or an IPv6 address in brackets")
	case p.User == "" && !strings.Contains(host, ".") && !strings.HasPrefix(hostport, "["):
		// Most likely "user:pass" that lost its "@host:port", whose password
		// would become a port that nothing redacts. A proxy that asks for no
		// login is reached at a dotted name or an address.
		return fail("there is no @, and a host with no dot reads as a user and a password that lost their @host:port")
	}
	if port == "" {
		return fail("the port is missing")
	}
	// No sign, base 10, and 16 bits, which caps it at 65535.
	n, err := strconv.ParseUint(port, 10, 16)
	if err != nil || n == 0 {
		return fail("the port is not a number from 1 to 65535")
	}
	p.Address, p.Port = host, int(n)
	return p, nil
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
		return envconf.ExConfig
	}
	fmt.Println(value)
	return 0
}

func writeRuntime(dir string, configs []*envconf.Config) error {
	hint := func(err error) error {
		return fmt.Errorf("XRAY_RUNTIME_DIR is %s, which is not writable by uid %d (%v). Mount a tmpfs there that it owns, such as Compose's `tmpfs: [\"%s:uid=%d,gid=%d,mode=0700\"]`", dir, os.Getuid(), envconf.Cause(err), dir, os.Getuid(), os.Getgid())
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
		if err := os.WriteFile(filepath.Join(dir, filepath.Base(c.Src)), c.Out, 0o600); err != nil {
			return hint(err)
		}
	}
	return nil
}

// Runs `xray run -test` on the resolved config and returns Xray's version
// line. Xray quotes the value it rejects ("invalid UUID: <the id>"), so its
// output is printed with every resolved value replaced.
func testConfig(dir string, extra []string, configs []*envconf.Config) (string, error) {
	out, err := exec.Command(img.Bin, append([]string{"run", "-test", "-confdir", dir}, extra...)...).CombinedOutput()
	var values []string
	for _, c := range configs {
		values = append(values, c.Values...)
	}
	text := envconf.Redact(string(out), values)
	if err != nil {
		fmt.Fprint(os.Stderr, text)
		return "", fmt.Errorf("xray run -test refused the configuration (%v)", err)
	}
	version, _, _ := strings.Cut(text, "\n")
	return version, nil
}
