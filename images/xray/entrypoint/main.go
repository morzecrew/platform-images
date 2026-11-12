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
// settings, split from the [user:pass@]host:port in that file, or exactly
// {"$wireguard": "/absolute/path"} with a wireguard outbound's settings, from
// the wg-quick client config in that file, or exactly
// {"$upstreams": "/absolute/path"} with an outbounds array, one outbound per
// line of that file, and changes nothing else. The contract is in images/xray/README.md.
package main

import (
	"crypto/ecdh"
	"crypto/mlkem"
	"encoding/base64"
	"encoding/hex"
	"errors"
	"fmt"
	"maps"
	"net"
	"net/netip"
	"net/url"
	"os"
	"os/exec"
	"path/filepath"
	"regexp"
	"slices"
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
		{Name: "XRAY_UPSTREAM_ALIASES", Default: ""},
		{Name: "XRAY_UPSTREAM_PIN", Default: ""},
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
	{Key: "$wireguard", Resolve: wireguard},
	{Key: "$upstreams", Resolve: upstreams},
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
func parseProxy(s string) (proxyServer, error) { return parseProxyFrom(s, false) }

// parseProxyFrom is parseProxy; with bare, a host with no dot is taken, as a
// deployment's own alias names a service on its network (vpn:1080). An alias
// is not a secret, so no password can hide in it.
func parseProxyFrom(s string, bare bool) (proxyServer, error) {
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
	case !bare && p.User == "" && !strings.Contains(host, ".") && !strings.HasPrefix(hostport, "["):
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

// A wireguard outbound's settings, from a wg-quick client config, for Xray's
// own WireGuard over its built-in TCP/IP stack (noKernelTun), which needs no
// capability. Keys that only wg-quick or the kernel act on are accepted and
// left out: DNS, routing tables, marks and scripts are the host's business,
// and this container has none of them.
type wgPeer struct {
	PublicKey    string   `json:"publicKey"`
	PreSharedKey string   `json:"preSharedKey,omitempty"`
	Endpoint     string   `json:"endpoint"`
	AllowedIPs   []string `json:"allowedIPs"`
	KeepAlive    int      `json:"keepAlive,omitempty"`
}

type wgSettings struct {
	SecretKey   string   `json:"secretKey"`
	Address     []string `json:"address"`
	Peers       []wgPeer `json:"peers"`
	MTU         int      `json:"mtu"`
	NoKernelTun bool     `json:"noKernelTun"`
}

// wg-quick's default MTU when the file names none, which leaves room for
// WireGuard's overhead on an Ethernet path.
const wgDefaultMTU = 1420

var wgIgnored = map[string]bool{
	"dns": true, "listenport": true, "table": true, "fwmark": true, "saveconfig": true,
	"preup": true, "postup": true, "predown": true, "postdown": true,
}

// wireguard resolves {"$wireguard": path}: the outbound's settings, with the
// private key and any preshared key to redact, and the endpoints as the note.
func wireguard(name string) (envconf.Resolution, error) {
	s, err := envconf.ReadSecret(name)
	if err != nil {
		return envconf.Resolution{}, err
	}
	w, err := parseWireGuard(s)
	if err != nil {
		return envconf.Resolution{}, err
	}
	r := envconf.Resolution{Value: w, Secrets: []string{w.SecretKey}}
	endpoints := make([]string, len(w.Peers))
	for i, p := range w.Peers {
		endpoints[i] = p.Endpoint
		if p.PreSharedKey != "" {
			r.Secrets = append(r.Secrets, p.PreSharedKey)
		}
	}
	r.Note = strings.Join(endpoints, ", ")
	return r, nil
}

// The errors name a line and a key, never a value: a key's base64 is the
// secret itself. Keys are matched ignoring case, as wg(8) matches them.
func parseWireGuard(s string) (wgSettings, error) {
	w := wgSettings{MTU: wgDefaultMTU, NoKernelTun: true}
	var section string
	ifaceLine, peerLines := 0, []int(nil)
	seen := map[string]int{}
	for i, line := range strings.Split(s, "\n") {
		n := i + 1
		if j := strings.IndexByte(line, '#'); j >= 0 {
			line = line[:j]
		}
		if line = strings.TrimSpace(line); line == "" {
			continue
		}
		if strings.HasPrefix(line, "[") {
			if !strings.HasSuffix(line, "]") {
				return w, fmt.Errorf("line %d: a section header that does not end in ]", n)
			}
			switch strings.ToLower(strings.TrimSpace(line[1 : len(line)-1])) {
			case "interface":
				if ifaceLine != 0 {
					return w, fmt.Errorf("line %d: a second [Interface], after the one on line %d", n, ifaceLine)
				}
				section, ifaceLine = "Interface", n
			case "peer":
				section, peerLines = "Peer", append(peerLines, n)
				w.Peers = append(w.Peers, wgPeer{})
			default:
				return w, fmt.Errorf("line %d: a section other than [Interface] and [Peer]", n)
			}
			clear(seen)
			continue
		}
		k, v, ok := strings.Cut(line, "=")
		if !ok {
			return w, fmt.Errorf("line %d: neither a [section] nor a key = value", n)
		}
		key, v := strings.TrimSpace(k), strings.TrimSpace(v)
		lower := strings.ToLower(key)
		if section == "" {
			return w, fmt.Errorf("line %d: %s before any [Interface] or [Peer]", n, safeKey(key))
		}
		if wgIgnored[lower] && section == "Interface" {
			continue
		}
		// Address and AllowedIPs may repeat, adding to the list; any other
		// key twice in one section would leave one of them unread.
		if lower != "address" && lower != "allowedips" {
			if first, dup := seen[lower]; dup {
				return w, fmt.Errorf("line %d: %s again in this [%s], first on line %d", n, safeKey(key), section, first)
			}
			seen[lower] = n
		}
		if v == "" {
			return w, fmt.Errorf("line %d: %s is empty", n, safeKey(key))
		}
		var err error
		if section == "Interface" {
			err = w.setInterface(lower, v)
		} else {
			err = w.Peers[len(w.Peers)-1].set(lower, v)
		}
		if err != nil {
			return w, fmt.Errorf("line %d: %s %v", n, safeKey(key), err)
		}
	}
	switch {
	case ifaceLine == 0:
		return w, errors.New("has no [Interface]")
	case w.SecretKey == "":
		return w, fmt.Errorf("the [Interface] on line %d has no PrivateKey", ifaceLine)
	case len(w.Address) == 0:
		return w, fmt.Errorf("the [Interface] on line %d has no Address", ifaceLine)
	case len(w.Peers) == 0:
		return w, errors.New("has no [Peer]")
	}
	for i, p := range w.Peers {
		// An outbound dials out, so each peer needs somewhere to dial.
		for _, missing := range []struct {
			key   string
			empty bool
		}{{"PublicKey", p.PublicKey == ""}, {"Endpoint", p.Endpoint == ""}, {"AllowedIPs", len(p.AllowedIPs) == 0}} {
			if missing.empty {
				return w, fmt.Errorf("the [Peer] on line %d has no %s", peerLines[i], missing.key)
			}
		}
	}
	return w, nil
}

// setInterface takes one [Interface] key, lowercased, and its value.
func (w *wgSettings) setInterface(key, v string) error {
	switch key {
	case "privatekey":
		if !wgKey(v) {
			return errors.New("is not a WireGuard key, 32 bytes in base64")
		}
		w.SecretKey = v
	case "address":
		addrs, err := wgPrefixes(v, false)
		if err != nil {
			return err
		}
		w.Address = append(w.Address, addrs...)
	case "mtu":
		// IPv6 needs 1280; nothing on a real path is larger than 65535.
		n, err := strconv.ParseUint(v, 10, 16)
		if err != nil || n < 1280 {
			return errors.New("is not a number from 1280 to 65535")
		}
		w.MTU = int(n)
	default:
		return errors.New("is not a key of [Interface] that wg-quick knows")
	}
	return nil
}

// set takes one [Peer] key, lowercased, and its value.
func (p *wgPeer) set(key, v string) error {
	switch key {
	case "publickey":
		if !wgKey(v) {
			return errors.New("is not a WireGuard key, 32 bytes in base64")
		}
		p.PublicKey = v
	case "presharedkey":
		if !wgKey(v) {
			return errors.New("is not a WireGuard key, 32 bytes in base64")
		}
		p.PreSharedKey = v
	case "endpoint":
		host, port, err := net.SplitHostPort(v)
		switch {
		case err != nil:
			return errors.New("is not a host, a colon and a port, with an IPv6 address in brackets")
		case strings.HasPrefix(v, "["):
			if net.ParseIP(host) == nil || !strings.Contains(host, ":") {
				return errors.New("has brackets holding something other than an IPv6 address")
			}
		// A name may end in the root's dot, as wg(8) and Xray take it; the
		// value is passed on as written.
		case !validHost(strings.TrimSuffix(host, ".")):
			return errors.New("does not name a DNS name, an IPv4 address or an IPv6 address in brackets")
		}
		if n, err := strconv.ParseUint(port, 10, 16); err != nil || n == 0 {
			return errors.New("has a port that is not a number from 1 to 65535")
		}
		p.Endpoint = v
	case "allowedips":
		ips, err := wgPrefixes(v, true)
		if err != nil {
			return err
		}
		p.AllowedIPs = append(p.AllowedIPs, ips...)
	case "persistentkeepalive":
		if strings.EqualFold(v, "off") {
			p.KeepAlive = 0
			return nil
		}
		n, err := strconv.ParseUint(v, 10, 16)
		if err != nil {
			return errors.New("is neither off nor a number of seconds from 0 to 65535")
		}
		p.KeepAlive = int(n)
	default:
		return errors.New("is not a key of [Peer] that wg-quick knows")
	}
	return nil
}

// wgKey reports whether v is a WireGuard key: 32 bytes in standard base64.
func wgKey(v string) bool {
	b, err := base64.StdEncoding.Strict().DecodeString(v)
	return err == nil && len(b) == 32
}

// A comma-separated list of addresses with or without a prefix length; a bare
// address is a single host, /32 or /128. AllowedIPs are networks, so their host
// bits are cleared as wg(8) clears them; an Address keeps its own.
func wgPrefixes(v string, network bool) ([]string, error) {
	var out []string
	for f := range strings.SplitSeq(v, ",") {
		f = strings.TrimSpace(f)
		var p netip.Prefix
		var err error
		if strings.Contains(f, "/") {
			p, err = netip.ParsePrefix(f)
		} else {
			var a netip.Addr
			if a, err = netip.ParseAddr(f); err == nil && a.Zone() == "" {
				p = netip.PrefixFrom(a, a.BitLen())
			}
		}
		if err != nil || !p.IsValid() || p.Addr().Zone() != "" {
			return nil, errors.New("holds an entry that is not an IPv4 or IPv6 address, with or without a /prefix")
		}
		if network {
			p = p.Masked()
		}
		out = append(out, p.String())
	}
	return out, nil
}

// An outbound $upstreams makes. Settings is a proxyServer or wgSettings.
type upstreamOutbound struct {
	Tag            string          `json:"tag"`
	Protocol       string          `json:"protocol"`
	Settings       any             `json:"settings"`
	StreamSettings *upstreamStream `json:"streamSettings,omitempty"`
}

type upstreamStream struct {
	Security string `json:"security"`
}

// One line of an upstreams file, parsed.
type upstreamLine struct {
	n       int // its line number
	out     upstreamOutbound
	name    string
	groups  []string
	where   string // host:port, which the summary may show
	secrets []string
}

var (
	upstreamNameRE  = regexp.MustCompile(`^[a-z0-9][a-z0-9-]{0,31}$`)
	upstreamGroupRE = regexp.MustCompile(`^[a-z][a-z0-9]{0,15}$`)
	upstreamWordRE  = regexp.MustCompile(`^[a-z][a-z0-9-]{0,31}$`)
)

// upstreams resolves {"$upstreams": path}: an outbounds array, one outbound per
// line of the file, "<url> [name=<name>] [group=<group>[,<group>]]", so any
// number of proxies and WireGuard exits is one secret, in order. In each group,
// default "upstream", the first line is tagged "<group>-0" and each later one
// "<group>-b<n>", so a balancer selects the first ("<group>-0"), the rest
// ("<group>-b") or all ("<group>-"). XRAY_UPSTREAM_PIN names lines to move to
// the front of their groups; XRAY_UPSTREAM_ALIASES gives the URL for a line
// that is one word, such as a tunnel's hop the deployment defines.
func upstreams(name string) (envconf.Resolution, error) {
	s, err := envconf.ReadSecret(name)
	if err != nil {
		return envconf.Resolution{}, err
	}
	aliases, err := upstreamAliases(os.Getenv("XRAY_UPSTREAM_ALIASES"))
	if err != nil {
		return envconf.Resolution{}, err
	}
	outs, secrets, note, err := parseUpstreams(s, aliases, os.Getenv("XRAY_UPSTREAM_PIN"))
	if err != nil {
		return envconf.Resolution{}, err
	}
	return envconf.Resolution{Value: outs, Secrets: secrets, Note: note}, nil
}

// "<word>=<url> ..." from the environment, for a hop the deployment itself
// defines, such as a tunnel's SOCKS port. It holds no login. An error names the
// word, never the URL.
func upstreamAliases(env string) (map[string]string, error) {
	aliases := map[string]string{}
	for _, f := range strings.Fields(env) {
		word, u, ok := strings.Cut(f, "=")
		if !ok || !upstreamWordRE.MatchString(word) || !strings.Contains(u, "://") {
			return nil, errors.New("XRAY_UPSTREAM_ALIASES holds an entry that is not <word>=<url>")
		}
		if _, dup := aliases[word]; dup {
			return nil, fmt.Errorf("XRAY_UPSTREAM_ALIASES names %s twice", word)
		}
		// A word is also a scheme (openvpn://...), so it may not take one of
		// the schemes a line already has.
		if slices.Contains([]string{"socks", "socks5", "http", "https", "wireguard"}, word) {
			return nil, fmt.Errorf("XRAY_UPSTREAM_ALIASES defines %s, which is a scheme of its own", word)
		}
		// The environment is printed at start and in docker inspect: a login
		// belongs in the upstreams file, which is a secret.
		if strings.Contains(u, "@") {
			return nil, fmt.Errorf("XRAY_UPSTREAM_ALIASES gives %s a URL with a login, which the environment would show: put that line in the upstreams file", word)
		}
		aliases[word] = u
	}
	return aliases, nil
}

func parseUpstreams(s string, aliases map[string]string, pin string) ([]upstreamOutbound, []string, string, error) {
	var lines []upstreamLine
	names := map[string]int{}
	counts := map[string]int{}
	for i, raw := range strings.Split(s, "\n") {
		n := i + 1
		line := strings.TrimSpace(raw)
		if line == "" || strings.HasPrefix(line, "#") {
			continue
		}
		l, err := parseUpstreamLine(line, aliases, counts)
		if err != nil {
			return nil, nil, "", fmt.Errorf("line %d: %v", n, err)
		}
		l.n = n
		if l.name != "" {
			if first, dup := names[l.name]; dup {
				return nil, nil, "", fmt.Errorf("line %d: name=%s again, first on line %d", n, l.name, first)
			}
			names[l.name] = n
		}
		lines = append(lines, l)
	}
	if len(lines) == 0 {
		return nil, nil, "", errors.New("lists no upstream")
	}

	// Each group's lines in order, a pinned one first.
	var order []string
	byGroup := map[string][]*upstreamLine{}
	for i := range lines {
		for _, g := range lines[i].groups {
			if _, ok := byGroup[g]; !ok {
				order = append(order, g)
			}
			byGroup[g] = append(byGroup[g], &lines[i])
		}
	}
	pinned := map[string]string{}
	for _, p := range strings.FieldsFunc(pin, func(r rune) bool { return r == ',' || unicode.IsSpace(r) }) {
		if !upstreamNameRE.MatchString(p) {
			// The value may be a URL pasted in by mistake, login and all.
			return nil, nil, "", errors.New("XRAY_UPSTREAM_PIN holds something that is not a line name")
		}
		at, ok := names[p]
		if !ok {
			return nil, nil, "", fmt.Errorf("XRAY_UPSTREAM_PIN names %q, which no line has as its name", p)
		}
		for _, l := range lines {
			if l.n != at {
				continue
			}
			for _, g := range l.groups {
				if other, dup := pinned[g]; dup {
					return nil, nil, "", fmt.Errorf("XRAY_UPSTREAM_PIN pins %s and %s, both in group %s", other, p, g)
				}
				pinned[g] = p
				list := byGroup[g]
				for j, m := range list {
					if m.n == at {
						byGroup[g] = append([]*upstreamLine{m}, append(append([]*upstreamLine{}, list[:j]...), list[j+1:]...)...)
						break
					}
				}
			}
		}
	}

	var outs []upstreamOutbound
	var secrets, notes []string
	for i := range lines {
		secrets = append(secrets, lines[i].secrets...)
	}
	for _, g := range order {
		for j, l := range byGroup[g] {
			o := l.out
			if j == 0 {
				o.Tag = g + "-0"
			} else {
				o.Tag = fmt.Sprintf("%s-b%d", g, j)
			}
			outs = append(outs, o)
			label := o.Tag
			if l.name != "" {
				label += " (" + l.name + ")"
			}
			notes = append(notes, label+" "+o.Protocol+" "+l.where)
		}
	}
	return outs, secrets, strings.Join(notes, ", "), nil
}

// One non-blank line: a URL or an alias word, then its options. An alias word
// is the line, or its scheme (openvpn://<config>), whose rest is for the hop
// the alias names, such as a tunnel's config, and is never read here: the k-th
// line naming a word, k counting from 0 in the file's order (counts), dials
// the alias's port plus k, so each of a sidecar's tunnels has a port of its
// own. Errors never quote the URL, which may hold credentials.
func parseUpstreamLine(line string, aliases map[string]string, counts map[string]int) (upstreamLine, error) {
	fields := strings.Fields(line)
	l := upstreamLine{groups: []string{"upstream"}}
	u := fields[0]
	word, _, isURL := strings.Cut(u, "://")
	if !isURL {
		if !upstreamWordRE.MatchString(u) {
			return l, errors.New("does not start with a URL (socks5://, socks5+tls://, http://, https://, wireguard://) or a word XRAY_UPSTREAM_ALIASES defines")
		}
		if _, ok := aliases[u]; !ok {
			return l, fmt.Errorf("%s is not a word XRAY_UPSTREAM_ALIASES defines", u)
		}
	}
	a, alias := aliases[word]
	if alias {
		u = a
	}
	seen := map[string]bool{}
	for _, opt := range fields[1:] {
		k, v, ok := strings.Cut(opt, "=")
		if !ok || seen[k] {
			return l, errors.New("after the URL comes name=<name> and group=<group>[,<group>], each at most once")
		}
		seen[k] = true
		switch k {
		case "name":
			if !upstreamNameRE.MatchString(v) {
				return l, errors.New("a name is 1 to 32 lowercase letters, digits and dashes, starting with a letter or a digit")
			}
			l.name = v
		case "group":
			l.groups = strings.Split(v, ",")
			for i, g := range l.groups {
				if !upstreamGroupRE.MatchString(g) {
					return l, errors.New("a group is 1 to 16 lowercase letters and digits, starting with a letter")
				}
				if slices.Contains(l.groups[:i], g) {
					return l, fmt.Errorf("group= lists %s twice", g)
				}
			}
		default:
			return l, errors.New("after the URL comes name=<name> and group=<group>[,<group>], each at most once")
		}
	}

	scheme, rest, _ := strings.Cut(u, "://")
	switch scheme {
	case "socks", "socks5", "socks5+tls", "http", "https":
		p, err := parseProxyFrom(rest, alias)
		if err != nil {
			return l, err
		}
		if alias {
			if p.Port += counts[word]; p.Port > 65535 {
				return l, fmt.Errorf("is line %d naming %s, past port 65535", counts[word]+1, word)
			}
			counts[word]++
		}
		l.out = upstreamOutbound{Protocol: "socks", Settings: p}
		if strings.HasPrefix(scheme, "http") {
			l.out.Protocol = "http"
		}
		if scheme == "socks5+tls" || scheme == "https" {
			l.out.StreamSettings = &upstreamStream{Security: "tls"}
		}
		l.where = net.JoinHostPort(p.Address, strconv.Itoa(p.Port))
		if p.User != "" {
			l.secrets = []string{p.User, p.Pass}
		}
	case "wireguard":
		w, err := parseWireGuardURL(rest)
		if err != nil {
			return l, err
		}
		l.out = upstreamOutbound{Protocol: "wireguard", Settings: w}
		l.secrets = []string{w.SecretKey}
		ends := make([]string, len(w.Peers))
		for i, p := range w.Peers {
			ends[i] = p.Endpoint
			if p.PreSharedKey != "" {
				l.secrets = append(l.secrets, p.PreSharedKey)
			}
		}
		l.where = strings.Join(ends, " ")
	default:
		return l, errors.New("its scheme is not socks5, socks5+tls, http, https or wireguard")
	}
	return l, nil
}

// wireguardURLKeys maps a wireguard:// URL's query keys to wg-quick's.
var wireguardURLKeys = map[string]struct{ section, key string }{
	"address":      {"Interface", "Address"},
	"mtu":          {"Interface", "MTU"},
	"publickey":    {"Peer", "PublicKey"},
	"presharedkey": {"Peer", "PresharedKey"},
	"allowedips":   {"Peer", "AllowedIPs"},
	"keepalive":    {"Peer", "PersistentKeepalive"},
}

// A wireguard:// URL, as apps share one: the private key before the @, the
// peer's endpoint after it, the rest in the query; a #fragment, an app's name
// for it, is dropped. It becomes the wg-quick file it stands for, so it is
// checked by the same rules as $wireguard. A value may not hold a line break,
// which would add a line of its own to that file.
func parseWireGuardURL(rest string) (wgSettings, error) {
	rest, _, _ = strings.Cut(rest, "#")
	authority, query, _ := strings.Cut(rest, "?")
	authority = strings.TrimSuffix(authority, "/")
	at := strings.LastIndexByte(authority, '@')
	if at < 0 {
		return wgSettings{}, errors.New("is a wireguard:// URL with no private key before an @")
	}
	key, err := url.PathUnescape(authority[:at])
	if err != nil {
		return wgSettings{}, errors.New("is a wireguard:// URL whose private key is not percent-encoded correctly")
	}
	vals := map[string]string{}
	for _, kv := range strings.Split(query, "&") {
		if kv == "" {
			continue
		}
		k, v, _ := strings.Cut(kv, "=")
		k = strings.ToLower(k)
		if _, known := wireguardURLKeys[k]; !known {
			return wgSettings{}, fmt.Errorf("is a wireguard:// URL with %s, which is none of address, mtu, publickey, presharedkey, allowedips and keepalive", safeKey(k))
		}
		if _, dup := vals[k]; dup {
			return wgSettings{}, fmt.Errorf("is a wireguard:// URL with %s twice", k)
		}
		if vals[k], err = url.PathUnescape(v); err != nil {
			return wgSettings{}, fmt.Errorf("is a wireguard:// URL whose %s is not percent-encoded correctly", k)
		}
	}
	if _, ok := vals["allowedips"]; !ok {
		vals["allowedips"] = "0.0.0.0/0, ::/0"
	}
	for _, v := range append([]string{key, authority[at+1:]}, slices.Collect(maps.Values(vals))...) {
		if strings.ContainsAny(v, "\r\n#") {
			return wgSettings{}, errors.New("is a wireguard:// URL with a line break or a # in a value")
		}
	}
	var b strings.Builder
	fmt.Fprintf(&b, "[Interface]\nPrivateKey = %s\n", key)
	for _, k := range []string{"address", "mtu"} {
		if v, ok := vals[k]; ok {
			fmt.Fprintf(&b, "%s = %s\n", wireguardURLKeys[k].key, v)
		}
	}
	fmt.Fprintf(&b, "[Peer]\nEndpoint = %s\n", authority[at+1:])
	for _, k := range []string{"publickey", "presharedkey", "allowedips", "keepalive"} {
		if v, ok := vals[k]; ok {
			fmt.Fprintf(&b, "%s = %s\n", wireguardURLKeys[k].key, v)
		}
	}
	w, err := parseWireGuard(b.String())
	if err != nil {
		// Its line numbers are the made-up file's; the key names stand alone.
		msg := err.Error()
		if _, after, ok := strings.Cut(msg, ": "); ok && strings.HasPrefix(msg, "line ") {
			msg = after
		}
		return wgSettings{}, errors.New("is a wireguard:// URL whose settings fail: " + msg)
	}
	return w, nil
}

// A key name goes into an error only if it reads as one: a line with no = is
// refused before this, but a value pasted where a key belongs must not be
// echoed.
func safeKey(k string) string {
	if wgKeyNameRE.MatchString(k) {
		return k
	}
	return "a key"
}

var wgKeyNameRE = regexp.MustCompile(`^[A-Za-z]{1,24}$`)

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
