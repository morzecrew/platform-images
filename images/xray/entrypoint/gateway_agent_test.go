package main

import (
	"bytes"
	"encoding/json"
	"errors"
	"fmt"
	"maps"
	"net"
	"net/http"
	"net/http/httptest"
	"os"
	"path/filepath"
	"slices"
	"strings"
	"testing"
	"time"
)

// fakeAPI stands in for `xray api` as the agent runs it: the users each
// inbound holds, the routing, and who is online, with every call kept.
type fakeAPI struct {
	users   map[string]map[string]string // inbound tag -> email -> id
	flows   map[string]string            // email -> the flow adu gave it
	rules   []string                     // the rules' tags, as lsrules lists them
	last    string                       // the outbound tag of the last rule
	online  map[string]bool
	calls   []string
	fail    string // a command that fails
	ignored bool   // adrules answers ok and changes nothing
	// Users whose rmu or adu fails on its own while the command exits 0, as
	// Xray's CLI does when one user's call fails.
	silent map[string]bool
}

func (f *fakeAPI) api(stdin []byte, args ...string) ([]byte, error) {
	f.calls = append(f.calls, args[0])
	if args[0] == f.fail {
		return nil, errors.New("xray api " + args[0] + " failed (exit status 1): failed to dial")
	}
	switch args[0] {
	case "inbounduser":
		tag := strings.TrimPrefix(args[1], "-tag=")
		var r struct {
			Users []map[string]any `json:"users"`
		}
		for _, e := range slices.Sorted(maps.Keys(f.users[tag])) {
			key := "id"
			if strings.HasSuffix(tag, "hy2") {
				key = "auth"
			}
			r.Users = append(r.Users, map[string]any{"email": e, "account": map[string]any{key: f.users[tag][e]}})
		}
		return json.Marshal(r)
	case "rmu":
		// Go's flag package, as Xray's: options until "--" or a word.
		tag, rest := strings.TrimPrefix(args[1], "-tag="), args[2:]
		if len(rest) > 0 && rest[0] == "--" {
			rest = rest[1:]
		} else if len(rest) > 0 && strings.HasPrefix(rest[0], "-") {
			return nil, errors.New("xray api rmu failed (exit status 2): flag provided but not defined: " + rest[0])
		}
		for _, e := range rest {
			if !f.silent[e] {
				delete(f.users[tag], e)
			}
		}
	case "adu":
		var in struct {
			Inbounds []struct {
				Tag      string `json:"tag"`
				Port     int    `json:"port"`
				Settings struct {
					Clients []struct{ ID, Email, Flow string } `json:"clients"`
					Users   []struct{ Auth, Email string }     `json:"users"`
				} `json:"settings"`
			} `json:"inbounds"`
		}
		if err := json.Unmarshal(stdin, &in); err != nil || args[1] != "stdin:" {
			return nil, fmt.Errorf("adu: %v", err)
		}
		for _, i := range in.Inbounds {
			if i.Port == 0 {
				return nil, errors.New("adu: an inbound without its port")
			}
			if f.users[i.Tag] == nil {
				f.users[i.Tag] = map[string]string{}
			}
			for _, c := range i.Settings.Clients {
				if !f.silent[c.Email] {
					f.users[i.Tag][c.Email], f.flows[c.Email] = c.ID, c.Flow
				}
			}
			for _, u := range i.Settings.Users {
				if !f.silent[u.Email] {
					f.users[i.Tag][u.Email] = u.Auth
				}
			}
		}
	case "adrules":
		if f.ignored {
			return []byte("{}\n"), nil
		}
		var in struct {
			Routing struct {
				Balancers []any `json:"balancers"`
				Rules     []struct {
					RuleTag     string `json:"ruleTag"`
					OutboundTag string `json:"outboundTag"`
				} `json:"rules"`
			} `json:"routing"`
		}
		if err := json.Unmarshal(stdin, &in); err != nil {
			return nil, err
		}
		f.rules = nil
		for _, r := range in.Routing.Rules {
			f.rules = append(f.rules, r.RuleTag)
			f.last = r.OutboundTag
		}
	case "lsrules":
		var r struct {
			Rules []map[string]string `json:"rules"`
		}
		for i, t := range f.rules {
			m := map[string]string{"ruleTag": t}
			if i == len(f.rules)-1 && f.last != "" {
				m["tag"] = f.last
			}
			r.Rules = append(r.Rules, m)
		}
		return json.Marshal(r)
	case "statsgetallonlineusers":
		if len(f.online) == 0 {
			return []byte("{}\n"), nil
		}
		var r struct {
			Users []string `json:"users"`
		}
		for _, e := range slices.Sorted(maps.Keys(f.online)) {
			r.Users = append(r.Users, "user>>>"+e+">>>online")
		}
		return json.Marshal(r)
	}
	return []byte("ok\n"), nil
}

// fakeLists answers each probe port as a leg's server would: a list, a
// status, or no answer.
type fakeLists map[int]struct {
	code int
	body string
}

func (l fakeLists) fetch(probe int, token string) (int, []byte, error) {
	a, ok := l[probe]
	if !ok {
		return 0, nil, errors.New("no answer (dial tcp: connection refused)")
	}
	return a.code, []byte(a.body), nil
}

func list(lines ...string) string { return gwListHeader + "\n" + strings.Join(lines, "\n") + "\n" }

const (
	devA = "11111111-1111-4111-8111-111111111111"
	devB = "22222222-2222-4222-8222-222222222222"
	devC = "33333333-3333-4333-8333-333333333333"
)

// gwAgent resolves a relay with two groups, a of two servers (probes 10900
// and 10901) and b of one (10902), and puts the fakes in place.
func gwAgent(t *testing.T) (*fakeAPI, fakeLists, string) {
	t.Helper()
	status := filepath.Join(t.TempDir(), "gateway", "status.json")
	t.Setenv("XRAY_GATEWAY_STATUS", status)
	t.Setenv("XRAY_GATEWAY_INTERVAL", "")
	gw.users, gw.prefixes, gwStates, gwDropped, gwLastErr, gwRound, gwRestartDue = nil, nil, map[string]*gwGroupState{}, nil, nil, time.Time{}, false
	src, configs, err := gwSource(t, server1("a", "a1.example.com,a2.example.com", clientA)+"\n"+server1("b", "b.example.com", clientB), "", "")
	if err != nil || len(configs) != 2 {
		t.Fatal(err)
	}
	gwTestSrc = src
	if err := gatewaySettings(); err != nil {
		t.Fatal(err)
	}
	f := &fakeAPI{users: map[string]map[string]string{}, flows: map[string]string{}, online: map[string]bool{}, silent: map[string]bool{}}
	gwPending = map[string]string{}
	lists := fakeLists{}
	oldAPI, oldFetch, oldReload := xrayAPI, gwFetch, gwReload
	xrayAPI, gwFetch = f.api, lists.fetch
	gwReload = func(string, string, []string) error { f.calls = append(f.calls, "reload"); return nil }
	t.Cleanup(func() {
		xrayAPI, gwFetch, gwReload = oldAPI, oldFetch, oldReload
		gw.users, gw.prefixes = nil, nil
	})
	return f, lists, status
}

// The source gwAgent resolved, for a test that resolves it again.
var gwTestSrc string

// stubXray stands in for the xray binary: `xray run -test` passes.
func stubXray(t *testing.T) {
	t.Helper()
	bin := filepath.Join(t.TempDir(), "xray")
	if err := os.WriteFile(bin, []byte("#!/bin/sh\necho 'Xray 0.0.0'\n"), 0o755); err != nil {
		t.Fatal(err)
	}
	old := img.Bin
	img.Bin = bin
	t.Cleanup(func() { img.Bin = old })
}

func readStatus(t *testing.T, p string) gwStatus {
	t.Helper()
	b, err := os.ReadFile(p)
	if err != nil {
		t.Fatal(err)
	}
	var st gwStatus
	if err := json.Unmarshal(b, &st); err != nil {
		t.Fatal(err)
	}
	return st
}

func TestParseList(t *testing.T) {
	got, skipped, err := parseList([]byte(list("# devices", strings.ToUpper(devA)+" phone 0123456789ab", "", devB+"\trelay-r2", devC,
		"not-a-uuid phone", devC+" ph/one", devC+" x 0123", devC+" x 0123456789ab extra")))
	want := []gwEntry{{devA, "phone", "0123456789ab"}, {devB, "relay-r2", ""}, {devC, "", ""}}
	if err != nil || !slices.Equal(got, want) || skipped != 4 {
		t.Errorf("parsed %v, %d skipped, %v", got, skipped, err)
	}
	for _, bad := range []string{"", devA + " phone\n", "# dotdash relay list v2\n" + devA, "<html>404</html>"} {
		if _, _, err := parseList([]byte(bad)); err == nil || err.Error() != "not a dotdash relay list v1" {
			t.Errorf("%q: %v", bad, err)
		}
	}
}

func TestGatewayUnion(t *testing.T) {
	gwStates = map[string]*gwGroupState{}
	groups := []gwGroup{{serverLine: serverLine{name: "a"}}, {serverLine: serverLine{name: "b"}}, {serverLine: serverLine{name: "c"}}}
	// devA on b, but for bytes 6 and 7.
	devA67 := devA[:14] + "4fff" + devA[18:]
	groupState("a").list = []gwEntry{{devA, "phone", "aaaaaaaaaaaa"}, {devB, "laptop", "cccccccccccc"}, {devC, "", ""}}
	groupState("b").list = []gwEntry{{devA67, "phone", "bbbbbbbbbbbb"}, {"44444444-4444-4444-8444-444444444444", "tablet", "cccccccccccc"}}
	groupState("c").list = []gwEntry{{"55555555-5555-4555-8555-555555555555", "x", ""}, {"66666666-6666-4666-8666-666666666666", "X", ""}}
	users, prefixes, dropped := gatewayUnion(groups)
	var emails []string
	for _, u := range users {
		emails = append(emails, u.email)
	}
	if want := []string{"#check@a", "laptop@a", "#f6222a11@a", "#check@b", "tablet@b", "#check@c"}; !slices.Equal(emails, want) {
		t.Errorf("users %v\nwant %v", emails, want)
	}
	if len(prefixes) != 0 {
		t.Errorf("prefixes %v: phone's went with phone, and laptop's and tablet's are one", prefixes)
	}
	want := []string{
		"phone@a, phone@b: one id, once bytes 6 and 7 are zeroed",
		"the subscription prefix of laptop@a, tablet@b: in two groups, so it has no route",
		"x@c, X@c: one name in one group",
	}
	if !slices.Equal(dropped, want) {
		t.Errorf("dropped\n got %q\nwant %q", dropped, want)
	}
	for _, d := range dropped {
		if strings.Contains(d, devA) || strings.Contains(d, "cccccccccccc") {
			t.Errorf("%q names an id or a prefix", d)
		}
	}
	groupState("b").list = nil
	if _, prefixes, _ := gatewayUnion(groups); !slices.Equal(prefixes["a"], []string{"aaaaaaaaaaaa", "cccccccccccc"}) {
		t.Errorf("prefixes %v", prefixes)
	}
	// b claims laptop@a's prefix on an entry its id has dropped (with
	// phone@a): still b's as well as a's, so no route; and phone@a's, whose
	// only entry went, none either.
	groupState("b").list = []gwEntry{{devA67, "phone", "cccccccccccc"}}
	_, prefixes, dropped = gatewayUnion(groups)
	if len(prefixes) != 0 {
		t.Errorf("a prefix two groups claim, one of them on a dropped entry: %v", prefixes)
	}
	if !slices.Contains(dropped, "the subscription prefix of laptop@a, phone@b: in two groups, so it has no route") {
		t.Errorf("dropped %q", dropped)
	}
	// A prefix only a dropped entry has gets no route either.
	groupState("b").list = []gwEntry{{devA67, "phone", "dddddddddddd"}}
	if _, prefixes, _ := gatewayUnion(groups); slices.Contains(prefixes["b"], "dddddddddddd") {
		t.Errorf("the prefix of a dropped entry routed: %v", prefixes)
	}
}

func TestGatewayRounds(t *testing.T) {
	f, lists, status := gwAgent(t)
	if st := readStatus(t, status); len(st.Groups) != 2 || st.Groups[0].State != "starting" || !st.Round.IsZero() || st.Groups[0].Legs[1].State != "starting" {
		t.Fatalf("the first status: %+v", st)
	}

	// Round 1: a served by its second server, b by its own.
	lists[10901] = struct {
		code int
		body string
	}{200, list(devA + " phone 0123456789ab")}
	lists[10902] = struct {
		code int
		body string
	}{200, list(devB + " tablet")}
	var logs string
	logs = stderr(t, func() {
		if gatewayRound("", "", nil) {
			t.Error("a restart with nothing removed")
		}
	})
	for _, want := range []string{"gateway: group a live", "gateway: group b live", "gateway: devices: 4 added, 0 removed"} {
		if !strings.Contains(logs, want) {
			t.Errorf("logs %q lack %q", logs, want)
		}
	}
	for _, tag := range []string{"devices", "devices-hy2"} {
		if got := f.users[tag]; len(got) != 4 || got["phone@a"] != devA || got["tablet@b"] != devB || got["#check@a"] == "" {
			t.Errorf("%s holds %v", tag, got)
		}
	}
	if f.flows["phone@a"] != "xtls-rprx-vision" {
		t.Errorf("a VLESS client added without the inbound's flow: %q", f.flows["phone@a"])
	}
	if want := []string{"internal", "probe-a-0", "probe-a-1", "probe-b-0", "tunnel", "sub-a", "users-a", "users-b", "block"}; !slices.Equal(f.rules, want) {
		t.Errorf("rules %v", f.rules)
	}
	st := readStatus(t, status)
	if st.Round.IsZero() || st.Error != "" || st.Groups[0].State != "live" || st.Groups[0].Devices != 1 || st.Groups[0].Digest == "" ||
		st.Groups[0].Legs[0].State != "down" || st.Groups[0].Legs[1].State != "ok" || st.Groups[0].Check != f.users["devices"]["#check@a"] {
		t.Errorf("status %+v", st)
	}

	// Round 2: nothing changes, and the routing isn't sent again.
	f.calls = nil
	gatewayRound("", "", nil)
	if slices.Contains(f.calls, "adu") || slices.Contains(f.calls, "rmu") || slices.Contains(f.calls, "adrules") || !slices.Contains(f.calls, "lsrules") {
		t.Errorf("a round with no change called %v", f.calls)
	}

	// Round 3: a's list drops phone, which is not connected; b goes down.
	lists[10901] = struct {
		code int
		body string
	}{200, list(devC + " laptop")}
	delete(lists, 10902)
	f.calls = nil
	logs = stderr(t, func() {
		if gatewayRound("", "", nil) {
			t.Error("a restart for a device that is not connected")
		}
	})
	if !strings.Contains(logs, "gateway: group b down: no leg answers (b.example.com: no answer") {
		t.Errorf("logs %q", logs)
	}
	if got := f.users["devices"]; got["phone@a"] != "" || got["laptop@a"] != devC || got["tablet@b"] != devB {
		t.Errorf("devices holds %v: b's devices are kept while it is down", got)
	}
	if !slices.Contains(f.calls, "adrules") {
		t.Error("a's prefix went and the routing was not replaced")
	}

	// Round 4: laptop goes while connected: Xray restarts on the new lists.
	lists[10901] = struct {
		code int
		body string
	}{200, list()}
	f.online["laptop@a"] = true
	f.calls = nil
	logs = stderr(t, func() {
		if !gatewayRound("", "", nil) {
			t.Error("no restart for a removed device still connected")
		}
	})
	if !strings.Contains(logs, "laptop@a removed while connected: restarting Xray") || !slices.Contains(f.calls, "reload") {
		t.Errorf("logs %q, calls %v", logs, f.calls)
	}
	if slices.ContainsFunc(gw.users, func(u gwUser) bool { return u.email == "laptop@a" }) {
		t.Error("the restart's config would still hold laptop@a")
	}

	// A restart that fails is tried again the next round, which sees no
	// removal of its own: laptop@a is gone from Xray's users by then.
	f.calls = nil
	reloads := 0
	gwReload = func(string, string, []string) error {
		if reloads++; reloads == 1 {
			return errors.New("xray run -test refused the configuration")
		}
		return nil
	}
	lists[10901] = struct {
		code int
		body string
	}{200, list(devC + " laptop")}
	gatewayRound("", "", nil)
	lists[10901] = struct {
		code int
		body string
	}{200, list()}
	logs = stderr(t, func() {
		if gatewayRound("", "", nil) {
			t.Error("a failed restart reported as one")
		}
	})
	if !strings.Contains(logs, "the restart is tried again next round") {
		t.Errorf("logs %q", logs)
	}
	if !gatewayRound("", "", nil) || reloads != 2 {
		t.Errorf("the failed restart was not tried again: %d reloads", reloads)
	}
	if gatewayRound("", "", nil) || reloads != 2 {
		t.Errorf("a restart once one succeeded: %d reloads", reloads)
	}

	// Round 5: b's server answers that it has no list for this relay: its
	// devices go.
	lists[10902] = struct {
		code int
		body string
	}{404, "Not Found"}
	logs = stderr(t, func() { gatewayRound("", "", nil) })
	if !strings.Contains(logs, "gateway: group b refused: b.example.com: no list for this relay (404)") || f.users["devices"]["tablet@b"] != "" || f.users["devices"]["#check@b"] == "" {
		t.Errorf("logs %q, devices holds %v", logs, f.users["devices"])
	}
	if st := readStatus(t, status); st.Groups[1].State != "refused" || st.Groups[1].Devices != 0 {
		t.Errorf("status %+v", st.Groups[1])
	}

	// Round 5b: b's server answers a 200 that is no list: b is down, not
	// refused, and keeps what it had (none, after the 404).
	lists[10902] = struct {
		code int
		body string
	}{200, "<html>a captive portal</html>"}
	gatewayRound("", "", nil)
	if st := readStatus(t, status); st.Groups[1].State != "down" || st.Groups[1].Legs[0].Error != "not a dotdash relay list v1" {
		t.Errorf("a 200 that is no list: %+v", st.Groups[1])
	}

	// Round 6: the API doesn't answer: said, the round's time kept, and the
	// next round sooner.
	before := readStatus(t, status).Round
	f.fail = "inbounduser"
	logs = stderr(t, func() { gatewayRound("", "", nil) })
	st = readStatus(t, status)
	if !strings.Contains(logs, "failed to dial; Xray keeps what it holds") || !st.Round.Equal(before) || !strings.Contains(st.Error, "inbounduser") || gwNext() != gwRetry {
		t.Errorf("logs %q, status %+v, next %v", logs, st, gwNext())
	}
	f.fail = ""
	gatewayRound("", "", nil)
	if gwNext() != time.Minute {
		t.Errorf("next %v", gwNext())
	}
}

// What Xray's CLI leaves undone with a 0 exit fails the round, which the
// next one mends; a name may start with a dash; and a removed device stays
// pending till an online check answers.
func TestGatewayMutationsAreReadBack(t *testing.T) {
	f, lists, status := gwAgent(t)
	lists[10902] = struct {
		code int
		body string
	}{200, list(devB+" -tablet", devC+" laptop")}
	gatewayRound("", "", nil)
	if f.users["devices"]["-tablet@b"] != devB || readStatus(t, status).Error != "" {
		t.Fatalf("devices holds %v", f.users["devices"])
	}

	// laptop's removal does nothing, and the CLI says ok: the round fails.
	before := readStatus(t, status).Round
	f.silent["laptop@b"] = true
	lists[10902] = struct {
		code int
		body string
	}{200, list(devB + " -tablet")}
	gatewayRound("", "", nil)
	if st := readStatus(t, status); !st.Round.Equal(before) || st.Error != "the devices inbound does not hold the users sent to it" || gwNext() != gwRetry {
		t.Errorf("a removal the CLI left undone: %+v", st)
	}
	delete(f.silent, "laptop@b")
	gatewayRound("", "", nil)
	if f.users["devices"]["laptop@b"] != "" || readStatus(t, status).Error != "" {
		t.Errorf("the next round did not mend it: %v", f.users["devices"])
	}

	// -tablet goes, a name that starts with a dash, while the online check
	// fails: pending, it is checked the round after, and is still connected.
	lists[10902] = struct {
		code int
		body string
	}{200, list()}
	f.fail = "statsgetallonlineusers"
	if gatewayRound("", "", nil) || f.users["devices"]["-tablet@b"] != "" {
		t.Errorf("devices holds %v", f.users["devices"])
	}
	f.fail, f.online["-tablet@b"] = "", true
	f.calls = nil
	if !gatewayRound("", "", nil) || !slices.Contains(f.calls, "reload") {
		t.Errorf("a removal whose online check failed was forgotten: %v", f.calls)
	}
	f.calls = nil
	if gatewayRound("", "", nil) || slices.Contains(f.calls, "statsgetallonlineusers") {
		t.Errorf("checked again once Xray was replaced: %v", f.calls)
	}
}

// A resolve whose config Xray never runs changes nothing the agent goes by:
// with a's prefix moved, an adrules that fails and a restart whose config
// fails its test, the next round still sends the new routing.
func TestGatewayCandidateIsNotInstalled(t *testing.T) {
	f, lists, _ := gwAgent(t)
	gwReload = func(src, run string, extra []string) error {
		_, _, err := reload(src, run, extra)
		return err
	}
	fakeXray(t, "never") // every config fails its test
	lists[10902] = struct {
		code int
		body string
	}{200, list(devB + " tablet 0123456789ab")}
	gatewayRound(gwTestSrc, t.TempDir(), nil)
	installed := gw.routing
	lists[10902] = struct {
		code int
		body string
	}{200, list(devB + " tablet ba9876543210")}
	f.fail, gwRestartDue = "adrules", true
	gatewayRound(gwTestSrc, t.TempDir(), nil)
	if gw.routing != installed || gw.next.routing == installed {
		t.Errorf("a failed reload's routing was taken for the one Xray holds")
	}
	f.fail, f.calls = "", nil
	stubXray(t)
	gwRestartDue = false
	gatewayRound(gwTestSrc, t.TempDir(), nil)
	if !slices.Contains(f.calls, "adrules") || gw.routing == installed {
		t.Errorf("the new routing was not sent: %v", f.calls)
	}
}

// A restart for geodata alone resolves the gateway's config again first: the
// runtime directory still holds a device the agent removed since.
func TestGeodataRestartTakesTheGatewaysDevices(t *testing.T) {
	_, lists, _ := gwAgent(t)
	stubXray(t)
	run := t.TempDir()
	lists[10902] = struct {
		code int
		body string
	}{200, list(devB+" tablet", devC+" laptop")}
	gatewayRound(gwTestSrc, run, nil)
	if ok, _, err := reload(gwTestSrc, run, nil); !ok || !strings.Contains(read(t, filepath.Join(run, "xray.json")), "laptop@b") {
		t.Fatalf("the runtime config: %v", err)
	}
	lists[10902] = struct {
		code int
		body string
	}{200, list(devB + " tablet")}
	if gatewayRound(gwTestSrc, run, nil) {
		t.Fatal("a restart for a device that is not connected")
	}

	srv := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) { w.Write([]byte("pinned data")) }))
	defer srv.Close()
	geoSetup(t, srv.URL, "pinned data")
	if err := geodataPrepare(); err != nil {
		t.Fatal(err)
	}
	fakeXray(t, "pinned data")
	if !refresh(gwTestSrc, run, nil, subSettings{interval: time.Hour}) {
		t.Fatal("no restart for a pinned file fetched")
	}
	if strings.Contains(read(t, filepath.Join(run, "xray.json")), "laptop@b") {
		t.Error("Xray would restart on a config that lets laptop@b back in")
	}
}

// A routing replace that doesn't hold is sent again, then Xray restarts on
// the config, whose routing is the gateway's.
func TestGatewayRoutingReadBack(t *testing.T) {
	f, lists, _ := gwAgent(t)
	lists[10902] = struct {
		code int
		body string
	}{200, list(devB + " tablet 0123456789ab")}
	f.ignored = true
	f.rules, f.last = []string{"block"}, "direct"
	var restart bool
	logs := stderr(t, func() { restart = gatewayRound("", "", nil) })
	if !restart || !strings.Contains(logs, "not the one sent, after a replace: restarting Xray") {
		t.Errorf("restart %v, logs %q", restart, logs)
	}
	// A rule changed behind the agent's back is put back.
	f.ignored = false
	gatewayRound("", "", nil)
	f.last = "direct"
	logs = stderr(t, func() { restart = gatewayRound("", "", nil) })
	if restart || !strings.Contains(logs, "is not the gateway's: replacing it") || f.last != "block" {
		t.Errorf("restart %v, logs %q, last %s", restart, logs, f.last)
	}
}

func TestGatewayStatusCommand(t *testing.T) {
	_, lists, status := gwAgent(t)
	var out bytes.Buffer
	if gatewayStatusCmd(&out) != 1 || !strings.Contains(out.String(), "gateway: no round has reached Xray's API yet") || !strings.Contains(out.String(), "a                starting a1.example.com starting") {
		t.Errorf("before a round:\n%s", out.String())
	}
	lists[10900] = struct {
		code int
		body string
	}{503, ""}
	lists[10901] = struct {
		code int
		body string
	}{200, list(devA + " phone")}
	lists[10902] = struct {
		code int
		body string
	}{404, ""}
	gatewayRound("", "", nil)
	// Ages counted from a clock of the test's, so a slow run reads the same.
	at := gwRound
	gwNow = func() time.Time { return at }
	t.Cleanup(func() { gwNow = time.Now })
	out.Reset()
	if gatewayStatusCmd(&out) != 0 {
		t.Errorf("after a round: %s", out.String())
	}
	for _, want := range []string{
		"a                live     a1.example.com down (503 Service Unavailable), a2.example.com ok ",
		"; 1 devices, digest ",
		"b                refused  b.example.com refused (no list for this relay (404))",
		"gateway: last round 0 s ago",
	} {
		if !strings.Contains(out.String(), want) {
			t.Errorf("status lacks %q:\n%s", want, out.String())
		}
	}
	gwRound = at.Add(-3 * time.Minute)
	writeGatewayStatus()
	out.Reset()
	if gatewayStatusCmd(&out) != 1 || !strings.Contains(out.String(), "the last round that reached Xray's API was 180 s ago") {
		t.Errorf("stale:\n%s", out.String())
	}
	os.Remove(status)
	out.Reset()
	if gatewayStatusCmd(&out) != 1 || !strings.Contains(out.String(), "gateway: no status at "+status) {
		t.Errorf("no file:\n%s", out.String())
	}
}

func TestGatewaySettings(t *testing.T) {
	t.Setenv("XRAY_GATEWAY_INTERVAL", "500ms")
	if err := gatewaySettings(); err == nil || !strings.Contains(err.Error(), "XRAY_GATEWAY_INTERVAL is not a Go duration of 1s or more") {
		t.Errorf("err = %v", err)
	}
	t.Setenv("XRAY_GATEWAY_INTERVAL", "")
	t.Setenv("XRAY_GATEWAY_STATUS", "status.json")
	if err := gatewaySettings(); err == nil || !strings.Contains(err.Error(), "not an absolute path") {
		t.Errorf("err = %v", err)
	}
	src, run := t.TempDir(), t.TempDir()
	t.Setenv("XRAY_SOURCE_DIR", src)
	t.Setenv("XRAY_RUNTIME_DIR", run)
	for _, p := range []string{filepath.Join(src, "gateway.json"), filepath.Join(run, "status.json"), filepath.Join(filepath.Dir(run), "status.json")} {
		t.Setenv("XRAY_GATEWAY_STATUS", p)
		if err := gatewaySettings(); err == nil || !strings.Contains(err.Error(), "is in or around XRAY_SOURCE_DIR or XRAY_RUNTIME_DIR") {
			t.Errorf("%s: err = %v", p, err)
		}
	}
	if os.Geteuid() != 0 {
		dir := filepath.Join(t.TempDir(), "ro")
		os.Mkdir(dir, 0o500)
		t.Setenv("XRAY_GATEWAY_STATUS", filepath.Join(dir, "status.json"))
		if err := gatewaySettings(); err == nil || !strings.Contains(err.Error(), "which uid") {
			t.Errorf("err = %v", err)
		}
	}
}

// The real fetch, through a stand-in for a probe inbound: an HTTP proxy.
func TestFetchListThroughTheProbe(t *testing.T) {
	ln, err := net.Listen("tcp", "127.0.0.1:0")
	if err != nil {
		t.Fatal(err)
	}
	token := listToken(clientA)
	srv := &http.Server{Handler: http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		switch {
		case r.URL.Host != "list.sub.dotdash.internal":
			w.WriteHeader(http.StatusBadGateway)
		case r.URL.Path == "/big404":
			w.WriteHeader(http.StatusNotFound)
			w.Write(bytes.Repeat([]byte("x"), gwListMax+10))
		case r.URL.Path == "/"+token:
			fmt.Fprint(w, list(devA+" phone"))
		case r.URL.Path == "/moved":
			http.Redirect(w, r, "/elsewhere", http.StatusFound)
		default:
			http.NotFound(w, r)
		}
	})}
	go srv.Serve(ln)
	defer srv.Close()
	port := ln.Addr().(*net.TCPAddr).Port
	if code, b, err := fetchList(port, token); err != nil || code != 200 || !strings.HasPrefix(string(b), gwListHeader) {
		t.Errorf("%d %q %v", code, b, err)
	}
	if code, _, err := fetchList(port, listToken(clientB)); err != nil || code != 404 {
		t.Errorf("another token: %d %v", code, err)
	}
	if code, _, err := fetchList(port, "big404"); err != nil || code != 404 {
		t.Errorf("a 404 with a page larger than a list: %d %v", code, err)
	}
	if code, _, err := fetchList(port, "moved"); err != nil || code != 302 {
		t.Errorf("a redirect is not followed: %d %v", code, err)
	}
	srv.Close()
	if _, _, err := fetchList(port, token); err == nil || strings.Contains(err.Error(), token) || !strings.HasPrefix(err.Error(), "no answer (") {
		t.Errorf("no proxy: %v", err)
	}
}
