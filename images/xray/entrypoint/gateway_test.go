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

// One server/1 line, as a server's relay-config prints it.
func server1(name, hosts, id string, more ...string) string {
	return strings.Join(append([]string{"server/1", name, hosts, "443", strings.Repeat("Q", 43), "a1b2",
		"mlkem768x25519plus.native.0rtt.Zz", id}, more...), " ")
}

// The device inbounds and the API a relay's template declares beside
// $gateway.
const gwDevices = `{"api": {"tag": "api", "listen": "127.0.0.1:10085", "services": ["HandlerService", "RoutingService", "StatsService"]},
 "stats": {}, "policy": {"levels": {"0": {"statsUserOnline": true, "statsUserUplink": true}}},
 "inbounds": [
  {"tag": "devices", "listen": "0.0.0.0", "port": 8443, "protocol": "vless", "settings": {"clients": {"$gatewayClients": "vless"}, "flow": "xtls-rprx-vision", "decryption": "none"}},
  {"tag": "devices-hy2", "listen": "0.0.0.0", "port": 8448, "protocol": "hysteria", "settings": {"version": 2, "users": {"$gatewayClients": "hysteria"}}}]}`

// gwSource writes a relay's source: gateway.json with $gateway, whose
// options are opts plus the servers and via files, and xray.json with the
// device inbounds; and resolves it.
func gwSource(t *testing.T, servers, via, opts string) (string, []*envconf.Config, error) {
	t.Helper()
	dir := t.TempDir()
	src := filepath.Join(dir, "src")
	if err := os.Mkdir(src, 0o700); err != nil {
		t.Fatal(err)
	}
	obj := `"servers": "` + write(t, filepath.Join(dir, "servers"), servers, 0o400) + `"`
	if via != "" {
		obj += `, "via": "` + write(t, filepath.Join(dir, "via"), via, 0o400) + `"`
	}
	if opts != "" {
		obj += ", " + opts
	}
	write(t, filepath.Join(src, "gateway.json"), `{"$gateway": {`+obj+`}}`, 0o600)
	write(t, filepath.Join(src, "xray.json"), gwDevices, 0o600)
	configs, err := resolveDir(src)
	if err == nil {
		gatewayInstall()
	}
	return src, configs, err
}

// asJSON is a config as Xray reads it.
func asJSON(t *testing.T, c *envconf.Config) map[string]any {
	t.Helper()
	var m map[string]any
	if err := json.Unmarshal(c.Out, &m); err != nil {
		t.Fatal(err)
	}
	return m
}

// failsClosed checks the three rules on a gateway's config: the default
// outbound a blackhole, each balancer falling back to its own group's first
// leg, and a last rule that blocks; and that each rule sends a group's
// traffic to that group alone, after the rule that keeps devices from the
// internal names.
func failsClosed(t *testing.T, doc map[string]any, groups []string) {
	t.Helper()
	outs, _ := doc["outbounds"].([]any)
	if first, _ := outs[0].(map[string]any); first["tag"] != "block" || first["protocol"] != "blackhole" {
		t.Errorf("the first outbound, Xray's default, is %v", outs[0])
	}
	tags := map[string]bool{}
	for _, o := range outs {
		tags[o.(map[string]any)["tag"].(string)] = true
	}
	routing := doc["routing"].(map[string]any)
	balancers, _ := routing["balancers"].([]any)
	if len(balancers) != len(groups) {
		t.Errorf("%d balancers for groups %v", len(balancers), groups)
	}
	for i, b := range balancers {
		b := b.(map[string]any)
		g := groups[i]
		fb, _ := b["fallbackTag"].(string)
		if b["tag"] != g || fmt.Sprint(b["selector"]) != "["+g+"-]" || !strings.HasPrefix(fb, g+"-") || !tags[fb] {
			t.Errorf("balancer %v does not fall back to a leg of its own group %s", b, g)
		}
		if strings.Contains(g, "-") {
			t.Errorf("group %s has a dash, which another's selector would take", g)
		}
	}
	rules := routing["rules"].([]any)
	last := rules[len(rules)-1].(map[string]any)
	if last["network"] != "tcp,udp" || last["outboundTag"] != "block" || last["ruleTag"] != "block" || len(last) != 3 {
		t.Errorf("the last rule is %v, not a block of everything", last)
	}
	internal := -1
	for i, r := range rules {
		r := r.(map[string]any)
		tag := r["ruleTag"].(string)
		switch {
		case tag == "internal":
			internal = i
			if fmt.Sprint(r["user"]) != "[regexp:@]" || fmt.Sprint(r["domain"]) != "[domain:dotdash.internal]" || r["outboundTag"] != "block" {
				t.Errorf("the internal rule is %v", r)
			}
		case strings.HasPrefix(tag, "users-"):
			g := strings.TrimPrefix(tag, "users-")
			if fmt.Sprint(r["user"]) != "[regexp:@"+g+"$]" || r["balancerTag"] != g {
				t.Errorf("rule %v sends a group's devices elsewhere", r)
			}
		case strings.HasPrefix(tag, "sub-"):
			g := strings.TrimPrefix(tag, "sub-")
			if fmt.Sprint(r["inboundTag"]) != "[subscriptions]" || r["balancerTag"] != g {
				t.Errorf("rule %v sends a group's subscriptions elsewhere", r)
			}
		case strings.HasPrefix(tag, "probe-"):
			leg := strings.TrimPrefix(tag, "probe-")
			if fmt.Sprint(r["inboundTag"]) != "[probe-"+leg+"]" || r["outboundTag"] != leg || !tags[leg] {
				t.Errorf("rule %v probes another leg", r)
			}
		case tag == "tunnel":
			if !slices.Contains(groups, fmt.Sprint(r["balancerTag"])) {
				t.Errorf("the tunnel goes to %v", r["balancerTag"])
			}
		case tag == "ipv6":
			if i != 0 || r["outboundTag"] != "block" {
				t.Errorf("the ipv6 rule is %v, at %d", r, i)
			}
		case tag != "block":
			t.Errorf("a rule the gateway doesn't make: %v", r)
		}
		if _, toGroup := r["balancerTag"]; toGroup && (internal < 0 || internal > i) {
			t.Errorf("rule %v reaches a group before devices are kept from the internal names", r)
		}
	}
	if internal < 0 {
		t.Error("no rule keeps devices from the internal names")
	}
	if len(groups) > 0 {
		obs := doc["burstObservatory"].(map[string]any)
		var want []string
		for _, g := range groups {
			want = append(want, g+"-")
		}
		if fmt.Sprint(obs["subjectSelector"]) != fmt.Sprint(want) {
			t.Errorf("the observatory watches %v", obs["subjectSelector"])
		}
	} else if _, ok := doc["burstObservatory"]; ok {
		t.Error("an observatory with nothing to watch")
	}
}

func TestParseServers(t *testing.T) {
	text := "# servers\n\n" + server1("a", "a1.example.com,203.0.113.9", clientA, "xr=8444,0a1b", "address=192.0.2.1,2001:db8::2") + "\n" +
		server1("b2", "b.example.com", strings.ToUpper(clientB)) + "\n"
	got, err := parseServers(text, "x")
	if err != nil {
		t.Fatal(err)
	}
	if len(got) != 2 || got[0].n != 3 || got[0].name != "a" || !slices.Equal(got[0].hosts, []string{"a1.example.com", "203.0.113.9"}) ||
		!slices.Equal(got[0].addrs, []string{"192.0.2.1", "2001:db8::2"}) || got[0].xrPort != 8444 || got[0].xrPath != "0a1b" ||
		got[1].id != clientB || !slices.Equal(got[1].addrs, got[1].hosts) || got[1].port != 443 {
		t.Errorf("parsed %+v", got)
	}
	warned := stderr(t, func() {
		if _, err := parseServers(server1("a", "a.example.com", clientA, "future=1"), "/run/secrets/servers"); err != nil {
			t.Error(err)
		}
	})
	if !strings.Contains(warned, "/run/secrets/servers line 1: no field is named future=; ignored") {
		t.Errorf("warned %q", warned)
	}
}

func TestParseServersRefusals(t *testing.T) {
	ok := server1("a", "a.example.com", clientA)
	field := func(i int, v string) string {
		f := strings.Fields(ok)
		f[i] = v
		return strings.Join(f, " ")
	}
	for _, tc := range []struct{ name, text, want string }{
		{"a relay/1 line", relay1("r1", "0123456789abcdef"), "line 1: a relay/1 line, where server/1 lines go"},
		{"no tag", "# x\n" + ok[9:], "line 2: not a server/1 line"},
		{"server/2", "server/2" + ok[8:], "line 1: not a server/1 line"},
		{"seven fields", strings.Join(strings.Fields(ok)[:7], " "), "line 1: 7 fields"},
		{"a name with a dash", field(1, "a-b"), "line 1: the name is not 1 to 16 lowercase"},
		{"a name in capitals", field(1, "A"), "line 1: the name is not"},
		{"a name of 17", field(1, strings.Repeat("a", 17)), "line 1: the name is not"},
		{"an empty host", field(2, "a.example.com,"), "line 1: the hosts are not"},
		{"an IPv6 host", field(2, "2001:db8::1"), "line 1: the hosts are not"},
		{"port 0", field(3, "0"), "line 1: the port is not"},
		{"port 65536", field(3, "65536"), "line 1: the port is not"},
		{"a public key of 44", field(4, strings.Repeat("Q", 44)), "line 1: the public key is not"},
		{"a short id of 17", field(5, strings.Repeat("a", 17)), "line 1: the short id is not"},
		{"an encryption with a quote", field(6, `mlkem768x25519plus."`), "line 1: the encryption is neither"},
		{"a relay id that is not a UUID", field(7, clientA[:35]), "line 1: the relay id is not a UUID"},
		{"xr= without a path", ok + " xr=8444", "line 1: xr= is not <port>,<path>"},
		{"xr= with port 0", ok + " xr=0,ab", "line 1: xr= is not <port>,<path>"},
		{"address= of two for one host", ok + " address=192.0.2.1,192.0.2.2", "line 1: address= is not one IP address per host"},
		{"address= a name", ok + " address=a.example.com", "line 1: address= is not one IP address per host"},
		{"the same name twice", ok + "\n" + server1("a", "b.example.com", clientB), "line 2: the name is the one on line 1"},
	} {
		t.Run(tc.name, func(t *testing.T) {
			_, err := parseServers(tc.text, "x")
			if err == nil || !strings.HasPrefix(err.Error(), tc.want) {
				t.Fatalf("err = %v\nwant %q", err, tc.want)
			}
			for _, secret := range []string{clientA, clientA[:35], strings.Repeat("Q", 43), "a.example.com"} {
				if strings.Contains(err.Error(), secret) {
					t.Errorf("error %q quotes the line", err)
				}
			}
		})
	}
}

// Every shape the relay takes keeps the three rules and isolates its groups.
func TestGatewayShapes(t *testing.T) {
	two := server1("a", "a1.example.com,a2.example.com", clientA, "xr=8444,0a1b", "address=192.0.2.1,192.0.2.2") + "\n" + server1("b", "b.example.com", clientB) + "\n"
	hops := relay1("y", "0123456789abcdef", "xhttp=ffee") + "\n" + strings.Replace(relay1("z", "fedcba9876543210", "xhttp=ddcc"), "r1.example.net", "z.example.net", 1)
	for _, tc := range []struct {
		name, servers, via, opts string
		groups                   []string
		legs                     map[string][]string // each group's legs: their tags and what they dial
		check                    func(t *testing.T, doc map[string]any)
	}{
		{name: "one group of one server", servers: server1("a", "a.example.com", clientA), groups: []string{"a"},
			legs: map[string][]string{"a": {"a-0 a.example.com:443 raw"}}},
		{name: "two groups, one of them cloned, by address", servers: two, groups: []string{"a", "b"},
			legs: map[string][]string{"a": {"a-0 192.0.2.1:443 raw", "a-1 192.0.2.2:443 raw"}, "b": {"b-0 b.example.com:443 raw"}}},
		{name: "XHTTP with REALITY where a line has xr=", servers: two, opts: `"serverLink": "xhttp-reality"`, groups: []string{"a", "b"},
			legs: map[string][]string{"a": {"a-0 192.0.2.1:8444 xhttp", "a-1 192.0.2.2:8444 xhttp"}, "b": {"b-0 b.example.com:443 raw"}}},
		{name: "via, by REALITY", servers: two, via: hops, groups: []string{"a", "b"},
			legs: map[string][]string{"a": {"a-v0 r1.example.net:443 raw", "a-v1 z.example.net:443 raw"}, "b": {"b-v0 r1.example.net:443 raw", "b-v1 z.example.net:443 raw"}}},
		{name: "via, by XHTTP", servers: two, via: hops, opts: `"viaLink": "xhttp", "viaFingerprint": "none"`, groups: []string{"a", "b"},
			legs: map[string][]string{"a": {"a-v0 r1.example.net:443 xhttp", "a-v1 z.example.net:443 xhttp"}, "b": {"b-v0 r1.example.net:443 xhttp", "b-v1 z.example.net:443 xhttp"}}},
		{name: "ipv6 block", servers: two, opts: `"ipv6": "block", "tunnelGroup": "b"`, groups: []string{"a", "b"},
			legs: map[string][]string{"a": {"a-0 192.0.2.1:443 raw", "a-1 192.0.2.2:443 raw"}, "b": {"b-0 b.example.com:443 raw"}},
			check: func(t *testing.T, doc map[string]any) {
				for _, r := range doc["routing"].(map[string]any)["rules"].([]any) {
					if r := r.(map[string]any); r["ruleTag"] == "tunnel" && r["balancerTag"] != "b" {
						t.Errorf("the tunnel goes to %v, not tunnelGroup b", r["balancerTag"])
					}
				}
			}},
		{name: "idle, with no server yet", servers: "# server/1 lines, as each server's relay-config prints them\n", groups: nil},
	} {
		t.Run(tc.name, func(t *testing.T) {
			_, configs, err := gwSource(t, tc.servers, tc.via, tc.opts)
			if err != nil {
				t.Fatal(err)
			}
			doc := asJSON(t, configs[0])
			failsClosed(t, doc, tc.groups)
			// Each group's legs, in order, and what they dial: the address=
			// in place of a host, the xr= port under xhttp-reality, a hop's
			// host on 443 through via; each with its probe inbound.
			got := map[string][]string{}
			probes := map[string]bool{}
			for _, in := range doc["inbounds"].([]any) {
				in := in.(map[string]any)
				if tag := in["tag"].(string); strings.HasPrefix(tag, "probe-") {
					probes[strings.TrimPrefix(tag, "probe-")] = in["listen"] == "127.0.0.1"
				}
			}
			for _, o := range doc["outbounds"].([]any)[1:] {
				o := o.(map[string]any)
				s := o["settings"].(map[string]any)
				st := o["streamSettings"].(map[string]any)
				tag := o["tag"].(string)
				g, _, _ := strings.Cut(tag, "-")
				got[g] = append(got[g], fmt.Sprintf("%s %s:%v %s", tag, s["address"], s["port"], st["network"]))
				if !probes[tag] {
					t.Errorf("leg %s has no probe inbound on loopback", tag)
				}
				if (st["network"] == "raw") != (s["flow"] == "xtls-rprx-vision") {
					t.Errorf("leg %s: flow %v over %v", tag, s["flow"], st["network"])
				}
				if want := map[string]string{"a": clientA, "b": clientB}[g]; s["id"] != want {
					t.Errorf("leg %s goes as %v, not as this relay's id on %s", tag, s["id"], g)
				}
			}
			if fmt.Sprint(got) != fmt.Sprint(tc.legs) && !(len(got) == 0 && len(tc.legs) == 0) {
				t.Errorf("legs\n got %v\nwant %v", got, tc.legs)
			}
			if tc.check != nil {
				tc.check(t, doc)
			}
		})
	}
}

// What a leg sends: the outbound under each link, as the template had it.
func TestGatewayLegs(t *testing.T) {
	_, configs, err := gwSource(t, server1("a", "a.example.com", clientA, "xr=8444,0a1b"), "", `"serverLink": "xhttp-reality"`)
	if err != nil {
		t.Fatal(err)
	}
	out, _ := json.Marshal(asJSON(t, configs[0])["outbounds"].([]any)[1])
	want := `{"protocol":"vless","settings":{"address":"a.example.com","encryption":"mlkem768x25519plus.native.0rtt.Zz","id":"` + clientA + `","port":8444},"streamSettings":{"network":"xhttp","realitySettings":{"fingerprint":"chrome","password":"` + strings.Repeat("Q", 43) + `","serverName":"a.example.com","shortId":"a1b2"},"security":"reality","sockopt":{"tcpUserTimeout":15000},"xhttpSettings":{"mode":"auto","path":"0a1b"}},"tag":"a-0"}`
	if string(out) != want {
		t.Errorf("xhttp-reality leg\n got %s\nwant %s", out, want)
	}
	_, configs, err = gwSource(t, server1("a", "a.example.com", clientA), relay1("y", "0123456789abcdef", "xhttp=ffee"), `"viaLink": "xhttp", "viaFingerprint": "safari"`)
	if err != nil {
		t.Fatal(err)
	}
	out, _ = json.Marshal(asJSON(t, configs[0])["outbounds"].([]any)[1])
	want = `{"protocol":"vless","settings":{"address":"r1.example.net","encryption":"mlkem768x25519plus.native.0rtt.AbC-_","id":"` + clientA + `","port":443},"streamSettings":{"network":"xhttp","security":"tls","sockopt":{"tcpUserTimeout":15000},"tlsSettings":{"alpn":["h2"],"fingerprint":"safari","serverName":"r1.example.net"},"xhttpSettings":{"host":"r1.example.net","mode":"auto","path":"/ffee"}},"tag":"a-v0"}`
	if string(out) != want {
		t.Errorf("via xhttp leg\n got %s\nwant %s", out, want)
	}
}

// The resolved config, its summary, its redactions and what it records for
// the agent; and the subscription routes the agent's prefixes add.
func TestGatewayResolves(t *testing.T) {
	defer func() { gw.users, gw.prefixes = nil, nil }()
	gw.users = []gwUser{{clientA, "phone@a"}, {clientB, "#check@b"}}
	gw.prefixes = map[string][]string{"a": {"0123456789ab", "ba9876543210"}}
	_, configs, err := gwSource(t, server1("a", "a.example.com", clientA)+"\n"+server1("b", "b.example.com", clientB), "", "")
	if err != nil {
		t.Fatal(err)
	}
	if len(configs[0].Refs) != 1 || configs[0].Refs[0].Note != "2 group(s), each with its legs: a (1), b (1); 0 via hop(s)" {
		t.Errorf("refs %+v", configs[0].Refs)
	}
	for _, v := range []string{clientA, clientB, "a1b2", strings.Repeat("Q", 43)} {
		if !slices.Contains(configs[0].Values, v) {
			t.Errorf("%s is not redacted", v)
		}
	}
	devices := asJSON(t, configs[1])["inbounds"].([]any)
	if got := fmt.Sprint(devices[0].(map[string]any)["settings"].(map[string]any)["clients"]); got != "[map[email:phone@a id:"+clientA+"] map[email:#check@b id:"+clientB+"]]" {
		t.Errorf("vless clients %s", got)
	}
	if got := fmt.Sprint(devices[1].(map[string]any)["settings"].(map[string]any)["users"]); got != "[map[auth:"+clientA+" email:phone@a] map[auth:"+clientB+" email:#check@b]]" {
		t.Errorf("hysteria users %s", got)
	}
	if !slices.Equal(gw.inbounds, []gwInbound{{"devices", "vless", "xtls-rprx-vision", 8443}, {"devices-hy2", "hysteria", "", 8448}}) || gw.api != "127.0.0.1:10085" {
		t.Errorf("recorded %+v, %s", gw.inbounds, gw.api)
	}
	if len(gw.groups) != 2 || gw.groups[1].legs[0].probe != gwProbeBase+1 {
		t.Errorf("groups %+v", gw.groups)
	}
	var sub map[string]any
	for _, r := range asJSON(t, configs[0])["routing"].(map[string]any)["rules"].([]any) {
		if r := r.(map[string]any); r["ruleTag"] == "sub-a" {
			sub = r
		}
	}
	if fmt.Sprint(sub["domain"]) != "[full:0123456789ab.sub.dotdash.internal full:ba9876543210.sub.dotdash.internal]" || sub["balancerTag"] != "a" {
		t.Errorf("a's subscriptions: %v", sub)
	}
	failsClosed(t, asJSON(t, configs[0]), []string{"a", "b"})

	// Caddy's inbounds on every address unless listen names one.
	for _, in := range asJSON(t, configs[0])["inbounds"].([]any)[:2] {
		if in.(map[string]any)["listen"] != "0.0.0.0" {
			t.Errorf("by default: %v", in)
		}
	}
	_, configs, err = gwSource(t, server1("a", "a.example.com", clientA), "", `"listen": "127.0.0.1"`)
	if err != nil {
		t.Fatal(err)
	}
	for _, in := range asJSON(t, configs[0])["inbounds"].([]any)[:2] {
		if in := in.(map[string]any); in["listen"] != "127.0.0.1" || (in["tag"] != "subscriptions" && in["tag"] != "tunnel") {
			t.Errorf("with listen 127.0.0.1: %v", in)
		}
	}

	// An unknown tunnelGroup: said, and the first group's.
	warned := stderr(t, func() {
		if _, _, err := gwSource(t, server1("a", "a.example.com", clientA), "", `"tunnelGroup": "zz"`); err != nil {
			t.Error(err)
		}
	})
	if !strings.Contains(warned, "tunnelGroup names zz") || gw.opts.tunnelGroup != "a" {
		t.Errorf("warned %q, tunnel to %s", warned, gw.opts.tunnelGroup)
	}
}

func TestGatewayRefusals(t *testing.T) {
	ok := server1("a", "a.example.com", clientA)
	for _, tc := range []struct{ name, servers, via, opts, want string }{
		{"an option it doesn't know", ok, "", `"link": "reality"`, `"$gateway" takes servers, via,`},
		{"a link it doesn't know", ok, "", `"serverLink": "quic"`, `"$gateway": "serverLink" is none of reality, xhttp-reality`},
		{"an option that is not a string", ok, "", `"ipv6": true`, `"$gateway": "ipv6" is not a string`},
		{"a probe URL that is not one", ok, "", `"probeURL": "ftp://x"`, `"$gateway": "probeURL" is not an http or https URL`},
		{"a listen address that is a name", ok, "", `"listen": "caddy"`, `"$gateway": "listen" is not an IP address`},
		{"a malformed server line", ok + "\n\n" + server1("b-c", "b.example.com", clientB), "", "", "servers line 3: the name is not 1 to 16"},
		{"a legacy via line", ok, "r1.example.net site.example " + strings.Repeat("P", 43) + " ab none", "", "via line 1: not a relay/1 line"},
		{"an xhttp via with no path", ok, relay1("y", "0123456789abcdef"), `"viaLink": "xhttp"`, "via line 1: viaLink xhttp goes through each relay's own site"},
	} {
		t.Run(tc.name, func(t *testing.T) {
			_, _, err := gwSource(t, tc.servers, tc.via, tc.opts)
			if err == nil || !strings.Contains(err.Error(), tc.want) {
				t.Fatalf("err = %v\nwant %q", err, tc.want)
			}
			if strings.Contains(err.Error(), clientB) || strings.Contains(err.Error(), "b.example.com") {
				t.Errorf("error %q quotes a line", err)
			}
		})
	}

	// What the rest of the source has to hold.
	dir := t.TempDir()
	servers := write(t, filepath.Join(dir, "servers"), ok, 0o400)
	gateway := `{"$gateway": {"servers": "` + servers + `"}}`
	for _, tc := range []struct {
		name  string
		files map[string]string
		want  string
	}{
		{"no servers", map[string]string{"gateway.json": `{"$gateway": {}}`}, `"$gateway" needs "servers"`},
		{"a path for $gateway", map[string]string{"gateway.json": `{"$gateway": "` + servers + `"}`}, `"$gateway" takes an object`},
		{"$gateway inside a config", map[string]string{"gateway.json": `{"x": {"$gateway": {"servers": "` + servers + `"}}}`, "xray.json": gwDevices}, "x: $gateway stands for a whole config"},
		{"two of them", map[string]string{"a.json": gateway, "b.json": gateway, "xray.json": gwDevices}, "b.json: a second $gateway"},
		{"routing in another file", map[string]string{"gateway.json": gateway, "xray.json": gwDevices, "zz.json": `{"routing": {"rules": []}}`}, "zz.json holds routing, which only $gateway may"},
		{"an outbound in another file", map[string]string{"gateway.json": gateway, "xray.json": strings.Replace(gwDevices, `"stats"`, `"outbounds": [{"protocol": "freedom"}], "stats"`, 1)}, "xray.json holds outbounds, which only $gateway may"},
		{"no API", map[string]string{"gateway.json": gateway, "xray.json": strings.Replace(gwDevices, `"api"`, `"x"`, 1)}, `the config needs "api": {"listen": "127.0.0.1:<port>"`},
		{"an API on every address", map[string]string{"gateway.json": gateway, "xray.json": strings.Replace(gwDevices, "127.0.0.1:10085", "0.0.0.0:10085", 1)}, `the config needs "api"`},
		{"an API on no port", map[string]string{"gateway.json": gateway, "xray.json": strings.Replace(gwDevices, "127.0.0.1:10085", "127.0.0.1:api", 1)}, `the config needs "api"`},
		{"an API on port 0", map[string]string{"gateway.json": gateway, "xray.json": strings.Replace(gwDevices, "127.0.0.1:10085", "127.0.0.1:0", 1)}, `the config needs "api"`},
		{"an API without the handler", map[string]string{"gateway.json": gateway, "xray.json": strings.Replace(gwDevices, `"HandlerService", `, "", 1)}, `the config needs "api"`},
		{"a later file's API, which Xray takes", map[string]string{"gateway.json": gateway, "xray.json": gwDevices, "zz.json": `{"api": {"tag": "api", "listen": "127.0.0.1:1", "services": ["StatsService"]}}`}, `the config needs "api"`},
		{"no online counts", map[string]string{"gateway.json": gateway, "xray.json": strings.Replace(gwDevices, `"statsUserOnline": true`, `"statsUserOnline": false`, 1)}, `"policy": {"levels": {"0": {"statsUserOnline": true}}}`},
		{"no stats", map[string]string{"gateway.json": gateway, "xray.json": strings.Replace(gwDevices, `"stats": {}, `, "", 1)}, `"stats": {}`},
		{"$gatewayClients with no $gateway", map[string]string{"xray.json": gwDevices}, "inbounds[0].settings.clients: $gatewayClients fills an inbound from a $gateway"},
		{"a word it doesn't know", map[string]string{"gateway.json": gateway, "xray.json": strings.Replace(gwDevices, `{"$gatewayClients": "vless"}`, `{"$gatewayClients": "trojan"}`, 1)}, `"$gatewayClients" is "vless", for a VLESS inbound's clients`},
		{"a path for $gatewayClients", map[string]string{"gateway.json": gateway, "xray.json": strings.Replace(gwDevices, `{"$gatewayClients": "vless"}`, `{"$gatewayClients": "/run/secrets/vless_clients"}`, 1)}, `"$gatewayClients" is "vless"`},
		{"hysteria users in a VLESS inbound", map[string]string{"gateway.json": gateway, "xray.json": strings.Replace(gwDevices, `{"$gatewayClients": "vless"}`, `{"$gatewayClients": "hysteria"}`, 1)}, `inbounds[0].settings.clients: $gatewayClients is "vless" in a VLESS inbound's settings.clients`},
		{"an inbound with no tag", map[string]string{"gateway.json": gateway, "xray.json": strings.Replace(gwDevices, `"tag": "devices", `, "", 1)}, "of an inbound with a tag and a port"},
		{"in a client's id", map[string]string{"gateway.json": gateway, "xray.json": strings.Replace(gwDevices, `{"$gatewayClients": "vless"}`, `[{"id": {"$gatewayClients": "vless"}}]`, 1)}, "inbounds[0].settings.clients[0].id: $gatewayClients is"},
	} {
		t.Run(tc.name, func(t *testing.T) {
			src := filepath.Join(t.TempDir(), "src")
			if err := os.Mkdir(src, 0o700); err != nil {
				t.Fatal(err)
			}
			for name, content := range tc.files {
				write(t, filepath.Join(src, name), content, 0o600)
			}
			_, err := resolveDir(src)
			if err == nil || !strings.Contains(err.Error(), tc.want) {
				t.Fatalf("err = %v\nwant %q", err, tc.want)
			}
		})
	}
}
