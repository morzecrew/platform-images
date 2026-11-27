package main

// dotdash's relays on a server: the relay/1 lines a server keeps for them,
// each relay's id there, derived from a server secret, the relay seed, and
// the relay's name and nonce, so that nobody types a relay's id into
// vless_clients ($vlessClients's object form), and the relay-id command that
// prints one. The derivation's test vector is testdata/relay-id.json.

import (
	"crypto/sha256"
	"encoding/hex"
	"errors"
	"fmt"
	"net"
	"os"
	"path/filepath"
	"regexp"
	"strings"

	"github.com/morzecrew/platform-images/shared/go/envconf"
)

var (
	relayNameRE = regexp.MustCompile(`^[A-Za-z0-9._-]{1,24}$`)
	nonceRE     = regexp.MustCompile(`^[0-9a-f]{16}$`)
	relaySeedRE = regexp.MustCompile(`^[0-9a-f]{64}$`)
	pbkRE       = regexp.MustCompile(`^[A-Za-z0-9_-]{43}$`)
	shortIDRE   = regexp.MustCompile(`^[0-9a-f]{1,16}$`)
	encRE       = regexp.MustCompile(`^(none|mlkem768x25519plus\.[A-Za-z0-9._-]+)$`)
	urlPathRE   = regexp.MustCompile(`^[A-Za-z0-9._~-]{1,128}$`)
	// A key= of a line, safe to name in a message.
	lineKeyRE = regexp.MustCompile(`^[a-z0-9_-]{1,16}$`)
)

// relayID is a relay's id on a server: a version 4 UUID made of the first 16
// bytes of sha256("<relay seed>:relay:<name>:<nonce>"). Each server group has
// a seed of its own, so a relay's ids on two groups are unrelated; the nonce
// is the relay's own, made once when it is installed, so a new relay that
// takes a removed one's name gets another id.
func relayID(seed, name, nonce string) string {
	sum := sha256.Sum256([]byte(seed + ":relay:" + name + ":" + nonce))
	b := sum[:16]
	b[6] = b[6]&0x0f | 0x40
	b[8] = b[8]&0x3f | 0x80
	return fmt.Sprintf("%x-%x-%x-%x-%x", b[0:4], b[4:6], b[6:8], b[8:10], b[10:16])
}

// listToken is where a relay fetches its device list from a server: the first
// 32 hex characters of sha256("<relay id>:list"), so only the server and the
// relay holding the id know it.
func listToken(id string) string {
	sum := sha256.Sum256([]byte(id + ":list"))
	return hex.EncodeToString(sum[:16])
}

// readRelaySeed reads a server's relay seed: 64 lowercase hex characters, as
// morzer's hex generator writes them. The derivation hashes the text, so
// another case would make other ids.
func readRelaySeed(name string) (string, error) {
	s, err := envconf.ReadSecret(name)
	if err != nil {
		return "", err
	}
	if !relaySeedRE.MatchString(s) {
		return "", errors.New("does not hold a relay seed: 64 lowercase hex characters and nothing else")
	}
	return s, nil
}

// One relay/1 line: the head, and of the optional fields the one this image
// reads. The rest (kcp=, hy2=, cdn=, cdnpath=, origin=, cdn-only) are for the
// server's links through the relay.
type relayLine struct {
	n                                 int
	name, nonce, host, site, pbk, sid string
	enc, xhttp                        string
}

// The optional fields of a relay/1 line that this image leaves to the
// server's links, and the one bare word.
var relayKeys = map[string]bool{"xhttp": true, "kcp": true, "hy2": true, "cdn": true, "cdnpath": true, "origin": true}

const relayHead = "relay/1 <name> <nonce> <host> <site> <public key> <short id> <encryption>"

// parseRelays reads relay/1 lines, as a relay's relay-entry prints them:
//
//	relay/1 <name> <nonce> <host> <site> <pbk> <sid> <enc> [xhttp=<path>] [kcp=...] [hy2=...] [cdn=...] [cdnpath=...] [origin=...] [cdn-only]
//
// Blank lines and # comments are skipped. Any other line is refused by its
// number, never by what it holds: a line is as sensitive as a device's link.
// A key= it doesn't know is left out with a warning on stderr, from naming
// the file, so a new optional field needs no new version.
func parseRelays(s, from string) ([]relayLine, error) {
	var out []relayLine
	names := map[string]int{}
	for i, raw := range strings.Split(s, "\n") {
		n, line := i+1, strings.TrimSpace(raw)
		if line == "" || line[0] == '#' {
			continue
		}
		f := strings.Fields(line)
		if f[0] != "relay/1" {
			return nil, fmt.Errorf("line %d: %s", n, notTagged(f[0], "relay/1"))
		}
		if len(f) < 8 {
			return nil, fmt.Errorf("line %d: %d fields, where a relay/1 line starts with the 8 of %s", n, len(f), relayHead)
		}
		r := relayLine{n: n, name: f[1], nonce: f[2], host: f[3], site: f[4], pbk: f[5], sid: f[6], enc: f[7]}
		if why := r.malformed(); why != "" {
			return nil, fmt.Errorf("line %d: %s", n, why)
		}
		if first, dup := names[strings.ToLower(r.name)]; dup {
			return nil, fmt.Errorf("line %d: the name is the one on line %d, ignoring case", n, first)
		}
		names[strings.ToLower(r.name)] = n
		for _, opt := range f[8:] {
			k, v, ok := strings.Cut(opt, "=")
			switch {
			case ok && k == "xhttp":
				if !urlPathRE.MatchString(v) {
					return nil, fmt.Errorf("line %d: xhttp= is not a path of 1 to 128 of A-Z a-z 0-9 . _ ~ -", n)
				}
				r.xhttp = v
			case ok && relayKeys[k], opt == "cdn-only":
			default:
				warnField(from, n, opt)
			}
		}
		out = append(out, r)
	}
	return out, nil
}

// malformed names the first field of a relay/1 line's head that is not
// shaped as it should be, or returns "".
func (r relayLine) malformed() string {
	switch {
	case !relayNameRE.MatchString(r.name):
		return "the name is not 1 to 24 of A-Z a-z 0-9 . _ -"
	case !nonceRE.MatchString(r.nonce):
		return "the nonce is not 16 lowercase hex characters"
	case !validHost(r.host) && !isIPv6(r.host):
		return "the host is not a DNS name, an IPv4 address or an IPv6 address"
	case !validHost(r.site) || numericRE.MatchString(r.site):
		return "the site is not a DNS name"
	case !pbkRE.MatchString(r.pbk):
		return "the public key is not 43 base64url characters"
	case !shortIDRE.MatchString(r.sid):
		return "the short id is not 1 to 16 lowercase hex characters"
	case !encRE.MatchString(r.enc):
		return "the encryption is neither none nor mlkem768x25519plus.<...>"
	}
	return ""
}

func isIPv6(s string) bool {
	ip := net.ParseIP(s)
	return ip != nil && strings.Contains(s, ":")
}

// notTagged says why a line whose first field is not the tag wanted is
// refused, without repeating the field: on a line of today's format it is a
// relay's address.
func notTagged(first, want string) string {
	for _, other := range []string{"server/1", "relay/1"} {
		if first == other {
			return fmt.Sprintf("a %s line, where %s lines go", other, want)
		}
	}
	return fmt.Sprintf("not a %s line: one without a tag, or of a format or version this image does not read, is refused", want)
}

// warnField tells of an optional field a reader doesn't know, naming its key
// only when it reads as one.
func warnField(from string, n int, opt string) {
	k, _, ok := strings.Cut(opt, "=")
	switch {
	case ok && lineKeyRE.MatchString(k):
		fmt.Fprintf(os.Stderr, "WARN: %s line %d: no field is named %s=; ignored\n", from, n, k)
	case ok:
		fmt.Fprintf(os.Stderr, "WARN: %s line %d: a field with a key that is not one; ignored\n", from, n)
	default:
		fmt.Fprintf(os.Stderr, "WARN: %s line %d: a field with no =, which no optional field is but cdn-only; ignored\n", from, n)
	}
}

// vlessClientsWithRelays resolves $vlessClients's object form,
//
//	{"devices": "<path>", "relays": "<path>" or ["<relay/1 line>", ...], "seed": "<path>"}
//
// to the clients the devices file lists and one client per relay/1 line, its
// id derived from the seed, its email relay-<name>: so a server lets its
// relays in with no line of theirs in vless_clients. relays is a file of
// relay/1 lines, or the lines themselves, as a template writes them out of a
// parameter. Its errors start with the file they read.
func vlessClientsWithRelays(target any) (envconf.Resolution, error) {
	const form = `"$vlessClients" takes an absolute path, or an object of "devices", "relays" and "seed"`
	obj, ok := target.(map[string]any)
	if !ok {
		return envconf.Resolution{}, errors.New(form)
	}
	for k := range obj {
		if k != "devices" && k != "relays" && k != "seed" {
			return envconf.Resolution{}, fmt.Errorf("%s, and this one also holds %q", form, k)
		}
	}
	devices, _ := obj["devices"].(string)
	seedFile, _ := obj["seed"].(string)
	if !filepath.IsAbs(devices) || !filepath.IsAbs(seedFile) {
		return envconf.Resolution{}, errors.New(`"devices" and "seed" of "$vlessClients" are absolute paths, as strings`)
	}
	var text, from string
	switch r := obj["relays"].(type) {
	case string:
		if !filepath.IsAbs(r) {
			return envconf.Resolution{}, errors.New(`"relays" of "$vlessClients" is an absolute path, or an array of relay/1 lines`)
		}
		s, err := envconf.ReadSecret(r)
		if err != nil {
			return envconf.Resolution{}, fmt.Errorf("%s %v", r, err)
		}
		text, from = s, r
	case []any:
		lines := make([]string, len(r))
		for i, l := range r {
			if lines[i], ok = l.(string); !ok || strings.ContainsAny(lines[i], "\r\n") {
				return envconf.Resolution{}, fmt.Errorf(`"relays" of "$vlessClients": entry %d is not one line, as a string`, i+1)
			}
		}
		// Each entry a line, numbered as one.
		text, from = strings.Join(lines, "\n"), "the relays array, at"
	default:
		return envconf.Resolution{}, errors.New(`"relays" of "$vlessClients" is an absolute path, or an array of relay/1 lines`)
	}
	relays, err := parseRelays(text, from)
	if err != nil {
		return envconf.Resolution{}, fmt.Errorf("%s %v", from, err)
	}
	r, err := vlessClients(devices)
	if err != nil {
		return envconf.Resolution{}, fmt.Errorf("%s %v", devices, err)
	}
	if len(relays) > 0 {
		seed, err := readRelaySeed(seedFile)
		if err != nil {
			return envconf.Resolution{}, fmt.Errorf("%s %v", seedFile, err)
		}
		clients := r.Value.([]vlessClient)
		for _, l := range relays {
			c := vlessClient{ID: relayID(seed, l.name, l.nonce), Email: "relay-" + l.name}
			for _, d := range clients {
				switch {
				case strings.EqualFold(d.Email, c.Email):
					return envconf.Resolution{}, fmt.Errorf("%s line %d: the relay's client is named %s, which is the name of a client in %s, ignoring case: rename that one, or drop it once the relay has its relay/1 line", from, l.n, c.Email, devices)
				case zeroed(d.ID) == zeroed(c.ID):
					return envconf.Resolution{}, fmt.Errorf("%s line %d: the id derived for the relay differs from a client's in %s only in bytes 6 and 7, which Xray ignores: give the relay another nonce", from, l.n, devices)
				}
			}
			clients = append(clients, c)
			r.Secrets = append(r.Secrets, c.ID)
		}
		r.Value = clients
	}
	src := strings.TrimSuffix(from, ", at")
	if len(relays) > 0 {
		src += ", their ids from " + seedFile
	}
	r.Note = fmt.Sprintf("%s and %d relay(s) from %s (%d clients)", devices, len(relays), src, len(r.Value.([]vlessClient)))
	return r, nil
}

// zeroed is an id as Xray looks it up: bytes 6 and 7, the third group,
// zeroed (ProcessUUID, proxy/vless/validator.go).
func zeroed(id string) string { return strings.ToLower(id[:14] + "0000" + id[18:]) }

// relayIDCmd prints a relay's id on this server, for the server's tasks:
// relay-id <seed file> <name> <nonce>. The seed is read from the file, so it
// never reaches a command line.
func relayIDCmd(args []string) int {
	const usage = "usage: xray-entrypoint relay-id <absolute path of the relay seed> <relay name> <nonce>"
	switch {
	case len(args) != 3:
		fmt.Fprintln(os.Stderr, usage)
		return 2
	case !filepath.IsAbs(args[0]):
		fmt.Fprintln(os.Stderr, usage+"\nThe first argument is not an absolute path, and is not shown in case it is the seed itself.")
		return 2
	case !relayNameRE.MatchString(args[1]):
		fmt.Fprintln(os.Stderr, usage+"\nThe name is not 1 to 24 of A-Z a-z 0-9 . _ -")
		return 2
	case !nonceRE.MatchString(args[2]):
		fmt.Fprintln(os.Stderr, usage+"\nThe nonce is not 16 lowercase hex characters.")
		return 2
	}
	seed, err := readRelaySeed(args[0])
	if err != nil {
		fmt.Fprintf(os.Stderr, "FATAL: %s %v\n", args[0], err)
		return envconf.ExConfig
	}
	fmt.Println(relayID(seed, args[1], args[2]))
	return 0
}
