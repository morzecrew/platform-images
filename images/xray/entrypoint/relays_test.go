package main

import (
	"encoding/json"
	"fmt"
	"os"
	"path/filepath"
	"slices"
	"strings"
	"testing"

	"github.com/morzecrew/platform-images/shared/go/envconf"
)

// testdata/relay-id.json was written by a Python implementation of the
// derivation, independently of this one; dotdash's server and manager test
// theirs against the same file.
func TestRelayIDMatchesTheVector(t *testing.T) {
	raw, err := os.ReadFile("testdata/relay-id.json")
	if err != nil {
		t.Fatal(err)
	}
	var doc struct {
		Vectors []struct {
			Seed, Name, Nonce, ID string
			ListToken             string `json:"list_token"`
		} `json:"vectors"`
	}
	if err := json.Unmarshal(raw, &doc); err != nil {
		t.Fatal(err)
	}
	if len(doc.Vectors) < 3 {
		t.Fatalf("%d vectors", len(doc.Vectors))
	}
	dir := t.TempDir()
	for i, v := range doc.Vectors {
		if got := relayID(v.Seed, v.Name, v.Nonce); got != v.ID {
			t.Errorf("vector %d: id %s, want %s", i, got, v.ID)
		}
		if got := listToken(v.ID); got != v.ListToken || len(got) != 32 {
			t.Errorf("vector %d: list token %s, want %s", i, got, v.ListToken)
		}
		if !uuidRE.MatchString(v.ID) || v.ID[14] != '4' || !strings.ContainsRune("89ab", rune(v.ID[19])) {
			t.Errorf("vector %d: %s is not a version 4 UUID", i, v.ID)
		}
		seed := write(t, filepath.Join(dir, fmt.Sprintf("seed%d", i)), v.Seed+"\n", 0o400)
		if got, err := readRelaySeed(seed); err != nil || got != v.Seed {
			t.Errorf("vector %d: seed read as %q, %v", i, got, err)
		}
	}
}

func TestRelayIDCommand(t *testing.T) {
	dir := t.TempDir()
	seedHex := strings.Repeat("0", 64)
	seed := write(t, filepath.Join(dir, "seed"), seedHex+"\n", 0o400)
	upper := write(t, filepath.Join(dir, "upper"), strings.Repeat("A", 64), 0o400)
	short := write(t, filepath.Join(dir, "short"), strings.Repeat("0", 63), 0o400)
	for _, tc := range []struct {
		args []string
		code int
		out  string
	}{
		{[]string{seed, "r1", "0000000000000000"}, 0, relayID(seedHex, "r1", "0000000000000000") + "\n"},
		{[]string{seed, "r1"}, 2, ""},
		{[]string{seedHex, "r1", "0000000000000000"}, 2, ""},
		{[]string{seed, "r 1", "0000000000000000"}, 2, ""},
		{[]string{seed, strings.Repeat("r", 25), "0000000000000000"}, 2, ""},
		{[]string{seed, "r1", "000000000000000"}, 2, ""},
		{[]string{seed, "r1", "000000000000000A"}, 2, ""},
		{[]string{upper, "r1", "0000000000000000"}, 78, ""},
		{[]string{short, "r1", "0000000000000000"}, 78, ""},
		{[]string{filepath.Join(dir, "absent"), "r1", "0000000000000000"}, 78, ""},
	} {
		var code int
		out := filepath.Join(dir, "out")
		errOut := stderr(t, func() {
			f, err := os.Create(out)
			if err != nil {
				t.Fatal(err)
			}
			old := os.Stdout
			os.Stdout = f
			code = relayIDCmd(tc.args)
			os.Stdout = old
			f.Close()
		})
		if b, _ := os.ReadFile(out); string(b) != tc.out {
			t.Errorf("%v: printed %q, want %q", tc.args, b, tc.out)
		}
		if code != tc.code {
			t.Errorf("%v: exit %d, want %d (%s)", tc.args, code, tc.code, errOut)
		}
		if strings.Contains(errOut, seedHex) {
			t.Errorf("%v: stderr carries the seed: %s", tc.args, errOut)
		}
	}
}

// One relay/1 line, as relay-entry prints it, with every optional field.
func relay1(name, nonce string, more ...string) string {
	return strings.Join(append([]string{"relay/1", name, nonce, "r1.example.net", "r1.example.net",
		strings.Repeat("P", 43), "0123abcd", "mlkem768x25519plus.native.0rtt.AbC-_"}, more...), " ")
}

func TestParseRelays(t *testing.T) {
	text := "# relays\n\n" + relay1("r1", "0123456789abcdef", "xhttp=0a1b2c", "kcp=8447,none,ab12", "hy2=443",
		"cdn=c.example.com", "cdnpath=ff00", "origin=o.example.com/x", "cdn-only") +
		"\n  " + relay1("R2.b_x-y", "fedcba9876543210") + "  \n"
	var got []relayLine
	warned := stderr(t, func() {
		var err error
		if got, err = parseRelays(text, "/run/secrets/relays"); err != nil {
			t.Fatal(err)
		}
	})
	if warned != "" {
		t.Errorf("warned of a known field: %s", warned)
	}
	if len(got) != 2 || got[0].n != 3 || got[0].name != "r1" || got[0].xhttp != "0a1b2c" || got[1].n != 4 || got[1].name != "R2.b_x-y" || got[1].xhttp != "" {
		t.Errorf("parsed %+v", got)
	}
	// An IPv6 host, as relay-entry takes the relay's address without a domain.
	v6 := strings.Replace(relay1("r1", "0123456789abcdef"), "r1.example.net", "2001:db8::7", 1)
	if got, err := parseRelays(v6, "x"); err != nil || got[0].host != "2001:db8::7" {
		t.Errorf("an IPv6 host: %+v, %v", got, err)
	}
	// A key= it doesn't know: left out, and said, with the key.
	warned = stderr(t, func() {
		if _, err := parseRelays(relay1("r1", "0123456789abcdef", "future=1", "standby", "Sécret=x"), "/run/secrets/relays"); err != nil {
			t.Error(err)
		}
	})
	for _, want := range []string{"/run/secrets/relays line 1: no field is named future=; ignored", "line 1: a field with no =", "line 1: a field with a key that is not one"} {
		if !strings.Contains(warned, want) {
			t.Errorf("warnings %q lack %q", warned, want)
		}
	}
	if strings.Contains(warned, "Sécret") {
		t.Errorf("a key that is not one is quoted: %s", warned)
	}
}

func TestParseRelaysRefusals(t *testing.T) {
	ok := relay1("r1", "0123456789abcdef")
	field := func(i int, v string) string {
		f := strings.Fields(ok)
		f[i] = v
		return strings.Join(f, " ")
	}
	const legacyHost = "legacy.relay.example"
	for _, tc := range []struct{ name, text, want string }{
		{"a line of today's format", "# old\n" + legacyHost + " site.example " + strings.Repeat("P", 43) + " ab none own-site 0a", "line 2: not a relay/1 line"},
		{"a server/1 line", "server/1 a a.example.com 443", "line 1: a server/1 line, where relay/1 lines go"},
		{"relay/2", "relay/2 " + ok[8:], "line 1: not a relay/1 line"},
		{"seven fields", strings.Join(strings.Fields(ok)[:7], " "), "line 1: 7 fields"},
		{"a name with a slash", field(1, "r/1"), "line 1: the name is not 1 to 24"},
		{"a name of 25", field(1, strings.Repeat("r", 25)), "line 1: the name is not 1 to 24"},
		{"a nonce in capitals", field(2, "0123456789ABCDEF"), "line 1: the nonce is not 16 lowercase hex"},
		{"a short nonce", field(2, "0123"), "line 1: the nonce is not"},
		{"a host with a quote", field(3, `r1".example`), "line 1: the host is not"},
		{"a site that is an IPv6 address", field(4, "2001:db8::1"), "line 1: the site is not a DNS name"},
		{"a public key of 42", field(5, strings.Repeat("P", 42)), "line 1: the public key is not 43"},
		{"a short id in capitals", field(6, "ABCD"), "line 1: the short id is not"},
		{"an encryption with a brace", field(7, "mlkem768x25519plus.{x}"), "line 1: the encryption is neither"},
		{"an xhttp path with a slash", ok + " xhttp=/a/b", "line 1: xhttp= is not a path"},
		{"the same name in another case", ok + "\n" + field(1, "R1"), "line 2: the name is the one on line 1, ignoring case"},
	} {
		t.Run(tc.name, func(t *testing.T) {
			_, err := parseRelays(tc.text, "x")
			if err == nil || !strings.HasPrefix(err.Error(), tc.want) {
				t.Fatalf("err = %v\nwant %q", err, tc.want)
			}
			for _, secret := range []string{legacyHost, strings.Repeat("P", 42), "0123456789abcdef", "{x}"} {
				if strings.Contains(err.Error(), secret) {
					t.Errorf("error %q quotes the line", err)
				}
			}
		})
	}
}

// The object form: the devices, and a client per relay, from a file or from
// the lines as a template writes them.
func TestVlessClientsWithRelays(t *testing.T) {
	dir := t.TempDir()
	seedHex := strings.Repeat("ab", 32)
	seed := write(t, filepath.Join(dir, "relay_seed"), seedHex+"\n", 0o400)
	devices := write(t, filepath.Join(dir, "vless_clients"), clientA+"\n"+clientB+" phone\n", 0o400)
	lines := "# One relay per line\n" + relay1("r1", "0123456789abcdef") + "\n" + relay1("r2", "fedcba9876543210", "xhttp=ab") + "\n"
	relays := write(t, filepath.Join(dir, "relays"), lines, 0o400)
	id1, id2 := relayID(seedHex, "r1", "0123456789abcdef"), relayID(seedHex, "r2", "fedcba9876543210")
	want := `{"inbounds":[{"settings":{"clients":[{"id":"` + clientA + `"},{"id":"` + clientB + `","email":"phone"},{"id":"` + id1 + `","email":"relay-r1"},{"id":"` + id2 + `","email":"relay-r2"}],"flow":"xtls-rprx-vision"}}]}` + "\n"

	for _, tc := range []struct{ name, relays, note string }{
		{"a file", `"` + relays + `"`, devices + " and 2 relay(s) from " + relays + " (4 clients)"},
		{"the lines", `["# One relay per line", "` + relay1("r1", "0123456789abcdef") + `", "` + relay1("r2", "fedcba9876543210", "xhttp=ab") + `"]`, devices + " and 2 relay(s) from the relays array (4 clients)"},
	} {
		t.Run(tc.name, func(t *testing.T) {
			src := write(t, filepath.Join(dir, "c.json"), `{"inbounds": [{"settings": {"clients": {"$vlessClients": {"devices": "`+devices+`", "relays": `+tc.relays+`, "seed": "`+seed+`"}}, "flow": "xtls-rprx-vision"}}]}`, 0o600)
			c, err := resolveFile(src)
			if err != nil {
				t.Fatal(err)
			}
			if string(c.Out) != want {
				t.Errorf("resolved\n got %s\nwant %s", c.Out, want)
			}
			if len(c.Refs) != 1 || c.Refs[0] != (envconf.Ref{Path: "inbounds[0].settings.clients", Kind: "$vlessClients", Note: tc.note}) {
				t.Errorf("refs = %+v", c.Refs)
			}
			if !slices.Equal(c.Values, []string{clientA, clientB, id1, id2}) {
				t.Errorf("values to redact = %v", c.Values)
			}
		})
	}

	// No relay/1 line yet, as a new server's parameter: the devices alone,
	// and the seed isn't needed.
	none := write(t, filepath.Join(dir, "none"), "# One relay per line, as its relay-entry task prints it\n", 0o400)
	r, err := vlessClientsWithRelays(map[string]any{"devices": devices, "relays": none, "seed": filepath.Join(dir, "absent")})
	if err != nil || len(r.Value.([]vlessClient)) != 2 {
		t.Errorf("no relay: %+v, %v", r, err)
	}
}

func TestVlessClientsWithRelaysRefusals(t *testing.T) {
	dir := t.TempDir()
	seedHex := strings.Repeat("cd", 32)
	seed := write(t, filepath.Join(dir, "relay_seed"), seedHex, 0o400)
	badSeed := write(t, filepath.Join(dir, "bad_seed"), strings.Repeat("cd", 31), 0o400)
	devices := write(t, filepath.Join(dir, "vless_clients"), clientA+" relay-R1\n", 0o400)
	plain := write(t, filepath.Join(dir, "plain"), clientA+"\n", 0o400)
	relays := write(t, filepath.Join(dir, "relays"), relay1("r1", "0123456789abcdef"), 0o400)
	legacy := write(t, filepath.Join(dir, "legacy"), "r1.example.net site.example "+strings.Repeat("P", 43)+" ab none", 0o400)
	id := relayID(seedHex, "r1", "0123456789abcdef")
	clash := write(t, filepath.Join(dir, "clash"), id[:14]+"ffff"+id[18:]+" phone\n", 0o400)
	obj := func(d, r, s string) string {
		return `{"devices": "` + d + `", "relays": ` + r + `, "seed": "` + s + `"}`
	}
	for _, tc := range []struct{ name, target, want string }{
		{"a relative path", `"rel"`, `"$vlessClients" takes an absolute path, or an object`},
		{"a number", `7`, `"$vlessClients" takes an absolute path, or an object`},
		{"a key it doesn't know", `{"devices": "/a", "relays": "/b", "seed": "/c", "flow": "x"}`, `"$vlessClients" takes an absolute path, or an object of "devices", "relays" and "seed", and this one also holds "flow"`},
		{"no seed", `{"devices": "/a", "relays": "/b"}`, `"devices" and "seed" of "$vlessClients" are absolute paths`},
		{"a relative relays", obj(plain, `"relays"`, seed), `"relays" of "$vlessClients" is an absolute path, or an array`},
		{"relays an object", obj(plain, `{}`, seed), `"relays" of "$vlessClients" is an absolute path, or an array`},
		{"an entry of two lines", obj(plain, `["a\nb"]`, seed), `"relays" of "$vlessClients": entry 1 is not one line`},
		{"a legacy line", obj(plain, `"`+legacy+`"`, seed), legacy + " line 1: not a relay/1 line"},
		{"a legacy line among the lines", obj(plain, `["# x", "r1.example.net x"]`, seed), "the relays array, at line 2: not a relay/1 line"},
		{"a seed of 62", obj(plain, `"`+relays+`"`, badSeed), badSeed + " does not hold a relay seed"},
		{"a missing devices file", obj(filepath.Join(dir, "absent"), `"`+relays+`"`, seed), filepath.Join(dir, "absent") + " does not exist"},
		{"a relay whose client name a device has", obj(devices, `"`+relays+`"`, seed), relays + " line 1: the relay's client is named relay-r1, which is the name of a client in " + devices},
		{"a derived id a device's differs from in bytes 6 and 7", obj(clash, `"`+relays+`"`, seed), relays + " line 1: the id derived for the relay differs from a client's in " + clash + " only in bytes 6 and 7"},
	} {
		t.Run(tc.name, func(t *testing.T) {
			src := write(t, filepath.Join(dir, "c.json"), `{"inbounds": [{"settings": {"clients": {"$vlessClients": `+tc.target+`}}}]}`, 0o600)
			_, err := resolveFile(src)
			if err == nil || !strings.Contains(err.Error(), "inbounds[0].settings.clients: "+tc.want) {
				t.Fatalf("err = %v\nwant %q", err, tc.want)
			}
			for _, secret := range []string{seedHex, id, clientA, strings.Repeat("P", 43)} {
				if strings.Contains(err.Error(), secret) {
					t.Errorf("error %q carries a secret", err)
				}
			}
		})
	}
}
