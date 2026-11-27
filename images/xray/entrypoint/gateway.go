package main

// dotdash's relay as a gateway to several server groups, each with its own
// servers and exit. {"$gateway": {...}} builds, from the relay's servers
// secret (a server/1 line per group) and its via secret (relay/1 lines, the
// relays it goes through), the inbounds, outbounds, balancers, observatory
// and routing that carry each group's devices to that group's servers alone.
// Three rules that fail closed are built in, so no template can drop them:
// the first outbound, Xray's default, is a blackhole; each group's balancer
// falls back to its own first leg, never to that default; and the last rule
// blocks whatever no other rule took. {"$gatewayClients": "vless"} and
// {"$gatewayClients": "hysteria"} put the devices in a device inbound, each
// named <device>@<group>, which the rules route by.

import (
	"errors"
	"fmt"
	"net"
	"net/url"
	"os"
	"path/filepath"
	"regexp"
	"slices"
	"strconv"
	"strings"

	"github.com/morzecrew/platform-images/shared/go/envconf"
)

// The inbounds $gateway makes listen on these. subscriptions and tunnel are
// Caddy's, on the project's network; each leg's probe is the agent's, on
// loopback, in the order of the legs.
const (
	gwSubscriptionsPort = 10810
	gwTunnelPort        = 10811
	gwProbeBase         = 10900
	// Names a relay asks its servers for through a group's tunnel, which the
	// server hands to its own Caddy, for relays alone: a device never may.
	internalZone = "dotdash.internal"
	subZone      = "sub." + internalZone
)

// One server/1 line: a group, its servers, which share their keys, and this
// relay's id on them.
type serverLine struct {
	n                 int
	name              string
	hosts, addrs      []string // addrs: address=, one per host, or the hosts
	port              int
	pbk, sid, enc, id string
	xrPort            int // xr=: XHTTP with REALITY, 0 for none
	xrPath            string
}

const serverHead = "server/1 <name> <host>[,<host>...] <port> <public key> <short id> <encryption> <relay id>"

// parseServers reads server/1 lines, as a server's relay-config prints them:
//
//	server/1 <name> <host>[,<host>...] <port> <pbk> <sid> <enc> <relay id> [xr=<port>,<path>] [address=<ip>[,<ip>...]]
//
// as parseRelays reads relay/1 lines: blank lines and # comments skipped,
// anything else refused by its number, never by what it holds, and a key=
// it doesn't know left out with a warning.
func parseServers(s, from string) ([]serverLine, error) {
	var out []serverLine
	names := map[string]int{}
	for i, raw := range strings.Split(s, "\n") {
		n, line := i+1, strings.TrimSpace(raw)
		if line == "" || line[0] == '#' {
			continue
		}
		f := strings.Fields(line)
		if f[0] != "server/1" {
			return nil, fmt.Errorf("line %d: %s", n, notTagged(f[0], "server/1"))
		}
		if len(f) < 8 {
			return nil, fmt.Errorf("line %d: %d fields, where a server/1 line starts with the 8 of %s", n, len(f), serverHead)
		}
		g := serverLine{n: n, name: f[1], hosts: strings.Split(f[2], ","), pbk: f[4], sid: f[5], enc: f[6], id: strings.ToLower(f[7])}
		port, err := strconv.ParseUint(f[3], 10, 16)
		g.port = int(port)
		switch {
		// A balancer's selector is a prefix of its legs' tags, <name>-<n>: a
		// dash in a name would let one group's selector take another's.
		case !upstreamGroupRE.MatchString(g.name):
			return nil, fmt.Errorf("line %d: the name is not 1 to 16 lowercase letters and digits, starting with a letter", n)
		case slices.ContainsFunc(g.hosts, func(h string) bool { return !validHost(h) }):
			return nil, fmt.Errorf("line %d: the hosts are not DNS names or IPv4 addresses, comma-separated", n)
		case err != nil || port == 0:
			return nil, fmt.Errorf("line %d: the port is not a number from 1 to 65535", n)
		case !pbkRE.MatchString(g.pbk):
			return nil, fmt.Errorf("line %d: the public key is not 43 base64url characters", n)
		case !shortIDRE.MatchString(g.sid):
			return nil, fmt.Errorf("line %d: the short id is not 1 to 16 lowercase hex characters", n)
		case !encRE.MatchString(g.enc):
			return nil, fmt.Errorf("line %d: the encryption is neither none nor mlkem768x25519plus.<...>", n)
		case !uuidRE.MatchString(g.id):
			return nil, fmt.Errorf("line %d: the relay id is not a UUID, 8-4-4-4-12 hex digits", n)
		}
		if first, dup := names[g.name]; dup {
			return nil, fmt.Errorf("line %d: the name is the one on line %d", n, first)
		}
		names[g.name] = n
		g.addrs = g.hosts
		for _, opt := range f[8:] {
			k, v, ok := strings.Cut(opt, "=")
			switch {
			case ok && k == "xr":
				p, path, _ := strings.Cut(v, ",")
				port, err := strconv.ParseUint(p, 10, 16)
				if err != nil || port == 0 || !urlPathRE.MatchString(path) {
					return nil, fmt.Errorf("line %d: xr= is not <port>,<path>, the port 1 to 65535, the path 1 to 128 of A-Z a-z 0-9 . _ ~ -", n)
				}
				g.xrPort, g.xrPath = int(port), path
			case ok && k == "address":
				g.addrs = strings.Split(v, ",")
				if len(g.addrs) != len(g.hosts) || slices.ContainsFunc(g.addrs, func(a string) bool { return net.ParseIP(a) == nil }) {
					return nil, fmt.Errorf("line %d: address= is not one IP address per host, in their order, comma-separated", n)
				}
			default:
				warnField(from, n, opt)
			}
		}
		out = append(out, g)
	}
	return out, nil
}

// The template's choices, from the relay's parameters, beside the two files.
type gwOptions struct {
	servers, via   string
	serverLink     string // reality, or xhttp-reality where a line has xr=
	viaLink        string // reality, or xhttp through each hop's own site
	viaFingerprint string
	ipv6           string // allow, or block
	probeURL       string
	tunnelGroup    string // "": the first group
}

var gwEnums = map[string][]string{
	"serverLink":     {"reality", "xhttp-reality"},
	"viaLink":        {"reality", "xhttp"},
	"viaFingerprint": {"chrome", "firefox", "safari", "edge", "ios", "android", "random", "none"},
	"ipv6":           {"allow", "block"},
}

func gatewayOptions(target any) (gwOptions, error) {
	o := gwOptions{serverLink: "reality", viaLink: "reality", viaFingerprint: "chrome", ipv6: "allow",
		probeURL: "https://www.gstatic.com/generate_204"}
	obj, ok := target.(map[string]any)
	if !ok {
		return o, errors.New(`"$gateway" takes an object: {"servers": "<absolute path>", ...}`)
	}
	for k, v := range obj {
		s, ok := v.(string)
		if !ok {
			return o, fmt.Errorf(`"$gateway": %q is not a string`, k)
		}
		if values, enum := gwEnums[k]; enum && !slices.Contains(values, s) {
			return o, fmt.Errorf(`"$gateway": %q is none of %s`, k, strings.Join(values, ", "))
		}
		switch k {
		case "servers", "via":
			if !filepath.IsAbs(s) {
				return o, fmt.Errorf(`"$gateway": %q is not an absolute path`, k)
			}
			if k == "servers" {
				o.servers = s
			} else {
				o.via = s
			}
		case "serverLink":
			o.serverLink = s
		case "viaLink":
			o.viaLink = s
		case "viaFingerprint":
			o.viaFingerprint = s
		case "ipv6":
			o.ipv6 = s
		case "probeURL":
			if u, err := url.Parse(s); err != nil || (u.Scheme != "http" && u.Scheme != "https") || u.Host == "" {
				return o, errors.New(`"$gateway": "probeURL" is not an http or https URL`)
			}
			o.probeURL = s
		case "tunnelGroup":
			if s != "" && !upstreamGroupRE.MatchString(s) {
				return o, errors.New(`"$gateway": "tunnelGroup" is not a group's name`)
			}
			o.tunnelGroup = s
		default:
			return o, fmt.Errorf(`"$gateway" takes servers, via, serverLink, viaLink, viaFingerprint, ipv6, probeURL and tunnelGroup, and this one also holds %q`, k)
		}
	}
	if o.servers == "" {
		return o, errors.New(`"$gateway" needs "servers", the absolute path of the server/1 lines`)
	}
	return o, nil
}

// A group as the relay carries it: its line, and its legs, the ways to it:
// one per server, or with via one per hop.
type gwGroup struct {
	serverLine
	legs []gwLeg
}

type gwLeg struct {
	tag   string // the outbound's: <group>-<n>, or <group>-v<n> through via
	host  string // the server's or the hop's, for the status
	addr  string // what the outbound dials
	port  int
	probe int // its probe inbound's port
	out   map[string]any
}

// What the agent and $gatewayClients need of the gateway the source holds:
// its groups, its options, the device inbounds and the API, set each time it
// is resolved; and what the agent has made of the groups' lists, which a
// restart's config starts on.
var gw struct {
	groups   []gwGroup
	opts     gwOptions
	inbounds []gwInbound
	api      string
	users    []gwUser            // the devices of every group, as Xray holds them
	prefixes map[string][]string // each group's subscription token prefixes
}

// A device as the gateway holds it: its id, and its name tagged @<group>.
type gwUser struct{ id, email string }

// A device inbound, whose clients or users $gatewayClients fills.
type gwInbound struct {
	tag, protocol, flow string
	port                int
}

// gateway resolves {"$gateway": {...}} to a whole config: inbounds,
// outbounds, routing and burstObservatory.
func gateway(target any) (envconf.Resolution, error) {
	o, err := gatewayOptions(target)
	if err != nil {
		return envconf.Resolution{}, err
	}
	s, err := envconf.ReadSecret(o.servers)
	if err != nil {
		return envconf.Resolution{}, fmt.Errorf("%s %v", o.servers, err)
	}
	lines, err := parseServers(s, o.servers)
	if err != nil {
		return envconf.Resolution{}, fmt.Errorf("%s %v", o.servers, err)
	}
	var hops []relayLine
	if o.via != "" {
		v, err := envconf.ReadSecret(o.via)
		if err != nil {
			return envconf.Resolution{}, fmt.Errorf("%s %v", o.via, err)
		}
		if hops, err = parseRelays(v, o.via); err != nil {
			return envconf.Resolution{}, fmt.Errorf("%s %v", o.via, err)
		}
		for _, h := range hops {
			if o.viaLink == "xhttp" && h.xhttp == "" {
				return envconf.Resolution{}, fmt.Errorf("%s line %d: viaLink xhttp goes through each relay's own site, and this line has no xhttp=<path>", o.via, h.n)
			}
		}
	}
	groups := gatewayGroups(lines, hops, o)
	if len(groups) > 0 && !slices.ContainsFunc(groups, func(g gwGroup) bool { return g.name == o.tunnelGroup }) {
		if o.tunnelGroup != "" {
			fmt.Fprintf(os.Stderr, "WARN: $gateway: tunnelGroup names %s, which %s has no line for: the tunnel goes to the first group\n", o.tunnelGroup, o.servers)
		}
		o.tunnelGroup = groups[0].name
	}
	gw.groups, gw.opts = groups, o
	r := envconf.Resolution{Value: gatewayDoc(groups, o, gw.prefixes)}
	var notes []string
	for _, g := range groups {
		r.Secrets = append(r.Secrets, g.id, g.sid, g.enc, g.pbk, g.xrPath)
		notes = append(notes, fmt.Sprintf("%s (%d)", g.name, len(g.legs)))
	}
	for _, h := range hops {
		r.Secrets = append(r.Secrets, h.sid, h.enc, h.pbk, h.xhttp)
	}
	r.Note = fmt.Sprintf("%d group(s), each with its legs: %s; %d via hop(s)", len(groups), strings.Join(notes, ", "), len(hops))
	if len(groups) == 0 {
		r.Note = fmt.Sprintf("no group yet: every device is refused; %d via hop(s)", len(hops))
	}
	return r, nil
}

// gatewayGroups gives each group its legs: one outbound per server, REALITY
// with Vision, or XHTTP with REALITY under serverLink xhttp-reality where the
// line has xr=; with via, one per hop instead, as this relay's id on the
// group, which the hop's server lists for the hop. Each leg's probe inbound
// takes the next port from gwProbeBase.
func gatewayGroups(lines []serverLine, hops []relayLine, o gwOptions) []gwGroup {
	var groups []gwGroup
	probe := gwProbeBase
	sockopt := map[string]any{"tcpUserTimeout": 15000}
	for _, l := range lines {
		g := gwGroup{serverLine: l}
		if len(hops) == 0 {
			for j, host := range l.hosts {
				leg := gwLeg{tag: fmt.Sprintf("%s-%d", l.name, j), host: host, addr: l.addrs[j], port: l.port}
				reality := map[string]any{"serverName": host, "fingerprint": "chrome", "password": l.pbk, "shortId": l.sid}
				settings := map[string]any{"address": leg.addr, "port": leg.port, "id": l.id, "encryption": l.enc}
				stream := map[string]any{"network": "raw", "security": "reality", "realitySettings": reality, "sockopt": sockopt}
				if o.serverLink == "xhttp-reality" && l.xrPort != 0 {
					leg.port = l.xrPort
					settings["port"] = l.xrPort
					stream["network"] = "xhttp"
					stream["xhttpSettings"] = map[string]any{"path": l.xrPath, "mode": "auto"}
				} else {
					settings["flow"] = "xtls-rprx-vision"
				}
				leg.out = map[string]any{"tag": leg.tag, "protocol": "vless", "settings": settings, "streamSettings": stream}
				g.legs = append(g.legs, leg)
			}
		}
		for n, h := range hops {
			leg := gwLeg{tag: fmt.Sprintf("%s-v%d", l.name, n), host: h.host, addr: h.host, port: 443}
			settings := map[string]any{"address": h.host, "port": 443, "id": l.id, "encryption": h.enc}
			var stream map[string]any
			if o.viaLink == "xhttp" {
				fp := o.viaFingerprint
				if fp == "none" {
					fp = ""
				}
				stream = map[string]any{"network": "xhttp", "security": "tls",
					"tlsSettings":   map[string]any{"serverName": h.site, "alpn": []string{"h2"}, "fingerprint": fp},
					"xhttpSettings": map[string]any{"path": "/" + h.xhttp, "host": h.site, "mode": "auto"},
					"sockopt":       sockopt}
			} else {
				settings["flow"] = "xtls-rprx-vision"
				stream = map[string]any{"network": "raw", "security": "reality", "realitySettings": map[string]any{
					"serverName": h.site, "fingerprint": "chrome", "password": h.pbk, "shortId": h.sid}, "sockopt": sockopt}
			}
			leg.out = map[string]any{"tag": leg.tag, "protocol": "vless", "settings": settings, "streamSettings": stream}
			g.legs = append(g.legs, leg)
		}
		for i := range g.legs {
			g.legs[i].probe = probe
			probe++
		}
		groups = append(groups, g)
	}
	return groups
}

// gatewayDoc is the config $gateway stands for, with each group's
// subscription prefixes routed to it.
func gatewayDoc(groups []gwGroup, o gwOptions, prefixes map[string][]string) map[string]any {
	inbounds := []any{
		map[string]any{"tag": "subscriptions", "listen": "0.0.0.0", "port": gwSubscriptionsPort, "protocol": "http"},
		map[string]any{"tag": "tunnel", "listen": "0.0.0.0", "port": gwTunnelPort, "protocol": "http"},
	}
	outbounds := []any{map[string]any{"tag": "block", "protocol": "blackhole"}}
	var selectors []string
	for _, g := range groups {
		for _, l := range g.legs {
			inbounds = append(inbounds, map[string]any{"tag": "probe-" + l.tag, "listen": "127.0.0.1", "port": l.probe, "protocol": "http"})
			outbounds = append(outbounds, l.out)
		}
		selectors = append(selectors, g.name+"-")
	}
	doc := map[string]any{"inbounds": inbounds, "outbounds": outbounds, "routing": gatewayRouting(groups, o, prefixes)}
	if len(groups) > 0 {
		// Each leg probed at a moment of its own, every 30 seconds, not all
		// together, which would tie them to each other for whoever watches.
		// A balancer needs it: Xray refuses one without an observatory.
		doc["burstObservatory"] = map[string]any{"subjectSelector": selectors,
			"pingConfig": map[string]any{"destination": o.probeURL, "interval": "30s", "sampling": 1}}
	}
	return doc
}

// gatewayRouting is the routing: a balancer per group, falling back to its
// own first leg, and the rules, each tagged so a replace can be read back:
//
//	ipv6       an IPv6 destination: block (ipv6 block only)
//	internal   a device asking for a dotdash.internal name: block
//	probe-<leg> the agent's probe of one leg: that leg
//	tunnel     a cover app's tunnel host: the tunnel group
//	sub-<g>    a subscription whose token's prefix is <g>'s: <g>
//	users-<g>  a device of <g>, named <device>@<g>: <g>
//	block      anything else: block
func gatewayRouting(groups []gwGroup, o gwOptions, prefixes map[string][]string) map[string]any {
	var rules, balancers []any
	rule := func(tag string, r map[string]any) {
		r["ruleTag"] = tag
		rules = append(rules, r)
	}
	if o.ipv6 == "block" {
		rule("ipv6", map[string]any{"ip": []string{"::/0"}, "outboundTag": "block"})
	}
	// A device behind this relay reaches its server as the relay, which may
	// ask for the server's internal names: so a device never gets to ask.
	rule("internal", map[string]any{"user": []string{"regexp:@"}, "domain": []string{"domain:" + internalZone}, "outboundTag": "block"})
	for _, g := range groups {
		for _, l := range g.legs {
			rule("probe-"+l.tag, map[string]any{"inboundTag": []string{"probe-" + l.tag}, "outboundTag": l.tag})
		}
	}
	if len(groups) > 0 {
		rule("tunnel", map[string]any{"inboundTag": []string{"tunnel"}, "balancerTag": o.tunnelGroup})
	}
	for _, g := range groups {
		if p := prefixes[g.name]; len(p) > 0 {
			names := make([]string, len(p))
			for i := range p {
				names[i] = "full:" + p[i] + "." + subZone
			}
			rule("sub-"+g.name, map[string]any{"inboundTag": []string{"subscriptions"}, "domain": names, "balancerTag": g.name})
		}
	}
	for _, g := range groups {
		rule("users-"+g.name, map[string]any{"user": []string{"regexp:@" + g.name + "$"}, "balancerTag": g.name})
		balancers = append(balancers, map[string]any{"tag": g.name, "selector": []string{g.name + "-"},
			"strategy": map[string]any{"type": "leastPing"}, "fallbackTag": g.legs[0].tag})
	}
	rule("block", map[string]any{"network": "tcp,udp", "outboundTag": "block"})
	r := map[string]any{"rules": rules}
	if len(balancers) > 0 {
		r["balancers"] = balancers
	}
	return r
}

// gatewayClients resolves {"$gatewayClients": "vless"} to a VLESS inbound's
// clients, or "hysteria" to a Hysteria2 inbound's users: every group's
// devices the gateway holds now, none at its first start. The inbound's own
// settings.flow gives a VLESS client its flow, as for $vlessClients.
func gatewayClients(target any) (envconf.Resolution, error) {
	var r envconf.Resolution
	switch target {
	case "vless":
		clients := make([]vlessClient, len(gw.users))
		for i, u := range gw.users {
			clients[i] = vlessClient{ID: u.id, Email: u.email}
		}
		r.Value = clients
	case "hysteria":
		users := make([]hysteriaUser, len(gw.users))
		for i, u := range gw.users {
			users[i] = hysteriaUser{Auth: u.id, Email: u.email}
		}
		r.Value = users
	default:
		return r, errors.New(`"$gatewayClients" is "vless", for a VLESS inbound's clients, or "hysteria", for a Hysteria2 inbound's users`)
	}
	for _, u := range gw.users {
		r.Secrets = append(r.Secrets, u.id)
	}
	r.Note = fmt.Sprintf("(%d clients now; the agent keeps them current)", len(gw.users))
	return r, nil
}

var gwClientsPathRE = regexp.MustCompile(`^inbounds\[(\d+)\]\.settings\.(clients|users)$`)

// gatewayCheck holds what $gateway needs of the whole source, which Xray
// merges file by file: one $gateway, a file's whole top level; no outbounds,
// routing or observatory in another file, where Xray would put its outbounds
// first, the default, or its routing in place of the gateway's; an API on
// loopback with the services the agent calls; online counts per user, by
// which it tells a revoked device still connected; and each $gatewayClients
// in a device inbound's clients or users. It records the inbounds and the API
// for the agent.
func gatewayCheck(configs []*envconf.Config) error {
	gw.inbounds, gw.api = nil, ""
	var src string
	type at struct {
		c *envconf.Config
		r envconf.Ref
	}
	var fill []at
	for _, c := range configs {
		for _, r := range c.Refs {
			switch r.Kind {
			case "$gateway":
				if src != "" {
					return fmt.Errorf("%s: a second $gateway, where %s has one", c.Src, src)
				}
				if r.Path != "" {
					return fmt.Errorf("%s: %s: $gateway stands for a whole config: put it alone in a file of its own, as {\"$gateway\": {...}}", c.Src, r.Path)
				}
				src = c.Src
			case "$gatewayClients":
				fill = append(fill, at{c, r})
			}
		}
	}
	if src == "" {
		if len(fill) > 0 {
			return fmt.Errorf("%s: %s: $gatewayClients fills an inbound from a $gateway, and no file holds one", fill[0].c.Src, fill[0].r.Path)
		}
		gw.groups = nil
		return nil
	}
	// Xray takes a later file's api, stats and policy in place of an earlier
	// one's, as it does its routing.
	last := map[string]any{}
	for _, c := range configs {
		doc, _ := c.Doc.(map[string]any)
		for _, k := range []string{"outbounds", "routing", "observatory", "burstObservatory"} {
			if _, ok := doc[k]; ok && c.Src != src {
				return fmt.Errorf("%s holds %s, which only $gateway may: its three rules that fail closed hold only while no other file adds an outbound or a routing", c.Src, k)
			}
		}
		for _, k := range []string{"api", "stats", "policy"} {
			if v, ok := doc[k]; ok {
				last[k] = v
			}
		}
	}
	api, _ := last["api"].(map[string]any)
	listen, _ := api["listen"].(string)
	host, _, err := net.SplitHostPort(listen)
	services, _ := api["services"].([]any)
	if ip := net.ParseIP(host); err != nil || ip == nil || !ip.IsLoopback() ||
		!slices.Contains(services, any("HandlerService")) || !slices.Contains(services, any("RoutingService")) || !slices.Contains(services, any("StatsService")) {
		return errors.New(`$gateway's agent adds and removes devices through Xray's API: the config needs "api": {"listen": "127.0.0.1:<port>", "services": ["HandlerService", "RoutingService", "StatsService"]}`)
	}
	policy, _ := last["policy"].(map[string]any)
	levels, _ := policy["levels"].(map[string]any)
	level0, _ := levels["0"].(map[string]any)
	if _, ok := last["stats"].(map[string]any); !ok || level0["statsUserOnline"] != true {
		return errors.New(`$gateway's agent tells a removed device still connected by its online count: the config needs "stats": {} and "policy": {"levels": {"0": {"statsUserOnline": true}}}`)
	}
	gw.api = listen
	for _, f := range fill {
		m := gwClientsPathRE.FindStringSubmatch(f.r.Path)
		fail := fmt.Errorf("%s: %s: $gatewayClients is \"vless\" in a VLESS inbound's settings.clients, or \"hysteria\" in a Hysteria2 inbound's settings.users, of an inbound with a tag and a port", f.c.Src, f.r.Path)
		if m == nil {
			return fail
		}
		doc, _ := f.c.Doc.(map[string]any)
		list, _ := doc["inbounds"].([]any)
		i, _ := strconv.Atoi(m[1])
		inb, _ := list[i].(map[string]any)
		settings, _ := inb["settings"].(map[string]any)
		in := gwInbound{}
		in.tag, _ = inb["tag"].(string)
		in.protocol, _ = inb["protocol"].(string)
		in.flow, _ = settings["flow"].(string)
		port, err := strconv.Atoi(fmt.Sprint(inb["port"]))
		in.port = port
		_, isVLESS := settings["clients"].([]vlessClient)
		_, isHysteria := settings["users"].([]hysteriaUser)
		if in.tag == "" || err != nil || !(m[2] == "clients" && in.protocol == "vless" && isVLESS || m[2] == "users" && in.protocol == "hysteria" && isHysteria) {
			return fail
		}
		gw.inbounds = append(gw.inbounds, in)
	}
	return nil
}
