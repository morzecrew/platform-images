package main

// The gateway's agent, run by the entrypoint as Xray's parent. Every
// XRAY_GATEWAY_INTERVAL it fetches each group's device list through each of
// the group's legs, joins the lists (an id two entries share is dropped from
// both, and so is a subscription prefix two groups share), and brings Xray's
// device inbounds and routing to that through Xray's API, with no restart:
// users added and removed, the routing replaced when a prefix changed, then
// read back. A removed device still connected restarts Xray on a config
// resolved from the new lists: the API cannot cut a user's open connections,
// and Hysteria2 takes new requests on one that logged in. Each round's state
// goes to XRAY_GATEWAY_STATUS, which gateway-status reads.

import (
	"bytes"
	"crypto/rand"
	"crypto/sha256"
	"encoding/hex"
	"encoding/json"
	"errors"
	"fmt"
	"io"
	"maps"
	"net/http"
	"net/url"
	"os"
	"os/exec"
	"path/filepath"
	"regexp"
	"slices"
	"strings"
	"time"

	"github.com/morzecrew/platform-images/shared/go/envconf"
)

const (
	gwListHeader   = "# dotdash relay list v1"
	gwListMax      = 4 << 20
	gwFetchTimeout = 10 * time.Second
	gwFirstRound   = time.Second     // after Xray starts
	gwRetry        = 5 * time.Second // after a round that could not reach the API
	gwStaleMin     = 2 * time.Minute // gateway-status: no round for longer is unhealthy
)

var prefixRE = regexp.MustCompile(`^[0-9a-f]{12}$`)

// One entry of a group's list: a device, or another relay going through
// this one, and the first 12 hex characters of the device's subscription
// token, when the server serves subscriptions.
type gwEntry struct{ id, name, prefix string }

// What the agent keeps of a group across rounds.
type gwGroupState struct {
	state   string // starting, live, down, refused
	check   string // the id of the group's checker, #check@<group>
	list    []gwEntry
	digest  string // of the list as served: the first 8 hex of its sha256
	listed  time.Time
	skipped int // the list's lines that were not an entry, left out
	legs    []gwLegStatus
}

type gwLegStatus struct {
	Tag   string `json:"tag"`
	Host  string `json:"host"`
	Probe int    `json:"probe"`
	State string `json:"state"` // ok, down, refused
	MS    int64  `json:"ms,omitempty"`
	Error string `json:"error,omitempty"`
}

var (
	gwStates  = map[string]*gwGroupState{}
	gwDropped []string // what the last union dropped, as the status names it
	gwLastErr error    // the last round's, which could not reach the API
	gwRound   time.Time
	// A restart that failed, tried again each round till it succeeds: the
	// devices it was to cut are gone from Xray's users by then, so no later
	// round would see them removed.
	gwRestartDue bool
)

// The status file, for gateway-status, the relay's tasks and its facts.
type gwStatus struct {
	Round   time.Time       `json:"round,omitzero"` // the last round that reached Xray's API
	Error   string          `json:"error,omitempty"`
	Groups  []gwGroupStatus `json:"groups"`
	Dropped []string        `json:"dropped,omitempty"`
}

type gwGroupStatus struct {
	Name    string        `json:"name"`
	State   string        `json:"state"`
	Check   string        `json:"check"`
	Devices int           `json:"devices"`
	Digest  string        `json:"digest,omitempty"`
	Listed  time.Time     `json:"listed,omitzero"`
	Skipped int           `json:"skipped,omitempty"`
	Legs    []gwLegStatus `json:"legs"`
}

// The agent's seams, which its tests replace: the list fetch through a
// probe inbound, Xray's API, and the reload a restart starts on.
var (
	gwFetch  = fetchList
	xrayAPI  = runXrayAPI
	gwReload = func(src, run string, extra []string) error {
		ok, _, err := reload(src, run, extra)
		if !ok {
			return err
		}
		return nil
	}
)

func gwInterval() time.Duration {
	d, err := time.ParseDuration(img.Get("XRAY_GATEWAY_INTERVAL"))
	if err != nil || d < time.Second {
		return time.Minute
	}
	return d
}

// gatewaySettings checks the agent's settings and writes its first status,
// every group starting, so a status file that cannot be written is found at
// start.
func gatewaySettings() error {
	if d, err := time.ParseDuration(img.Get("XRAY_GATEWAY_INTERVAL")); err != nil || d < time.Second {
		return errors.New("XRAY_GATEWAY_INTERVAL is not a Go duration of 1s or more, such as 1m")
	}
	p := img.Get("XRAY_GATEWAY_STATUS")
	if !filepath.IsAbs(p) {
		return errors.New("XRAY_GATEWAY_STATUS is not an absolute path")
	}
	// The source would lose a file to it, and Xray would read it from the
	// runtime directory as config.
	if dir := filepath.Dir(p); envconf.Overlap(dir, img.Get("XRAY_SOURCE_DIR")) || envconf.Overlap(dir, img.Get("XRAY_RUNTIME_DIR")) {
		return fmt.Errorf("XRAY_GATEWAY_STATUS (%s) is in or around XRAY_SOURCE_DIR or XRAY_RUNTIME_DIR, whose files it would replace or join: point it at a directory of its own", p)
	}
	if err := writeGatewayStatus(); err != nil {
		return fmt.Errorf("XRAY_GATEWAY_STATUS is %s, which uid %d cannot write (%v). Mount a tmpfs on its directory that it owns", p, os.Getuid(), envconf.Cause(err))
	}
	return nil
}

// gatewayRound runs one round and reports whether Xray is to restart on the
// runtime directory, which then holds the config resolved on the new lists.
func gatewayRound(src, run string, extra []string) bool {
	for _, g := range gw.groups {
		groupState(g.name).fetch(g)
	}
	old := gw.users
	var dropped []string
	gw.users, gw.prefixes, dropped = gatewayUnion(gw.groups)
	if !slices.Equal(dropped, gwDropped) {
		for _, d := range dropped {
			if !slices.Contains(gwDropped, d) {
				fmt.Fprintf(os.Stderr, "gateway: dropped: %s\n", d)
			}
		}
		gwDropped = dropped
	}
	if a, r := usersDiff(old, gw.users); a+r > 0 {
		fmt.Fprintf(os.Stderr, "gateway: devices: %d added, %d removed\n", a, r)
	}
	restart, err := gatewayApply()
	gwLastErr = err
	if err != nil {
		fmt.Fprintf(os.Stderr, "gateway: %v; Xray keeps what it holds, and the round is tried again\n", err)
	} else {
		gwRound = time.Now()
	}
	if restart || gwRestartDue {
		restart, gwRestartDue = true, false
		if err := gwReload(src, run, extra); err != nil {
			fmt.Fprintf(os.Stderr, "gateway: Xray could not be restarted on the new lists (%v): it keeps the config it runs, and the restart is tried again next round\n", err)
			restart, gwRestartDue = false, true
		}
	}
	if err := writeGatewayStatus(); err != nil {
		fmt.Fprintf(os.Stderr, "gateway: XRAY_GATEWAY_STATUS could not be written (%v)\n", envconf.Cause(err))
	}
	return restart
}

func gwNext() time.Duration {
	if gwLastErr != nil {
		return min(gwRetry, gwInterval())
	}
	return gwInterval()
}

func groupState(name string) *gwGroupState {
	st := gwStates[name]
	if st == nil {
		st = &gwGroupState{state: "starting", check: newUUID()}
		gwStates[name] = st
	}
	return st
}

// newUUID is a random version 4 UUID, for a group's checker.
func newUUID() string {
	var b [16]byte
	_, _ = rand.Read(b[:])
	b[6] = b[6]&0x0f | 0x40
	b[8] = b[8]&0x3f | 0x80
	return fmt.Sprintf("%x-%x-%x-%x-%x", b[0:4], b[4:6], b[6:8], b[8:10], b[10:16])
}

// fetch asks each of the group's legs for its list and sets the group's
// state: live while one leg serves it, refused while none does and one
// answers that there is none (404), which drops the group's devices, as a
// server no longer listing this relay must not keep letting them in; down
// otherwise, a list that isn't one included, keeping the list it had, since
// its devices can't get through anyway. A change is logged, never with an id
// or a token.
func (st *gwGroupState) fetch(g gwGroup) {
	token := listToken(g.id)
	st.legs = st.legs[:0]
	var got []byte
	var entries []gwEntry
	skipped, refused := 0, false
	for _, l := range g.legs {
		ls := gwLegStatus{Tag: l.tag, Host: l.host, Probe: l.probe, State: "down"}
		start := time.Now()
		code, body, err := gwFetch(l.probe, token)
		switch {
		case err != nil:
			ls.Error = err.Error()
		case code == http.StatusOK:
			e, n, perr := parseList(body)
			if perr != nil {
				// Not an answer that this relay is unlisted: only a 404 is.
				ls.Error = perr.Error()
				break
			}
			ls.State, ls.MS = "ok", time.Since(start).Milliseconds()
			if got == nil {
				got, entries, skipped = body, e, n
			}
		case code == http.StatusNotFound:
			ls.State, ls.Error, refused = "refused", "no list for this relay (404)", true
		default:
			ls.Error = fmt.Sprintf("%d %s", code, http.StatusText(code))
		}
		st.legs = append(st.legs, ls)
	}
	was := st.state
	switch {
	case got != nil:
		st.state, st.list, st.skipped, st.listed = "live", entries, skipped, time.Now()
		sum := sha256.Sum256(got)
		st.digest = hex.EncodeToString(sum[:4])
	case refused:
		st.state, st.list, st.digest = "refused", nil, ""
	default:
		st.state = "down"
	}
	if st.state == was {
		return
	}
	var why []string
	for _, l := range st.legs {
		if l.State != "ok" {
			why = append(why, l.Host+": "+l.Error)
		}
	}
	switch st.state {
	case "live":
		fmt.Fprintf(os.Stderr, "gateway: group %s live\n", g.name)
	case "refused":
		fmt.Fprintf(os.Stderr, "gateway: group %s refused: %s\n", g.name, strings.Join(why, ", "))
	default:
		fmt.Fprintf(os.Stderr, "gateway: group %s down: no leg answers (%s)\n", g.name, strings.Join(why, ", "))
	}
}

// fetchList asks for a list through a leg's probe inbound: Xray's http
// inbound, which sends it down that leg to the group's server, which hands
// the internal name to its own Caddy. No redirect is followed, and an error
// never quotes the URL, whose path is the list token.
func fetchList(probe int, token string) (int, []byte, error) {
	tr := &http.Transport{Proxy: http.ProxyURL(&url.URL{Scheme: "http", Host: fmt.Sprintf("127.0.0.1:%d", probe)})}
	defer tr.CloseIdleConnections()
	c := &http.Client{Transport: tr, Timeout: gwFetchTimeout,
		CheckRedirect: func(*http.Request, []*http.Request) error { return http.ErrUseLastResponse }}
	resp, err := c.Get("http://list." + subZone + "/" + token)
	if err != nil {
		var ue *url.Error
		if errors.As(err, &ue) {
			err = ue.Err
		}
		return 0, nil, fmt.Errorf("no answer (%s)", strings.ReplaceAll(err.Error(), token, "…"))
	}
	defer resp.Body.Close()
	// A status says it all but for a list, whose body alone is read: a 404's
	// page, however large, must still say the relay is unlisted.
	if resp.StatusCode != http.StatusOK {
		return resp.StatusCode, nil, nil
	}
	b, err := io.ReadAll(io.LimitReader(resp.Body, gwListMax+1))
	switch {
	case err != nil:
		return 0, nil, errors.New("the list could not be read")
	case len(b) > gwListMax:
		return 0, nil, fmt.Errorf("a list of more than %d bytes", gwListMax)
	}
	return resp.StatusCode, b, nil
}

// parseList reads a list a server serves its relay:
//
//	# dotdash relay list v1
//	<id> [<name> [<first 12 hex of the device's subscription token>]]
//
// A list without that first line is refused whole; a line that is not an
// entry is left out and counted.
func parseList(b []byte) ([]gwEntry, int, error) {
	lines := strings.Split(string(b), "\n")
	if strings.TrimSpace(lines[0]) != gwListHeader {
		return nil, 0, errors.New("not a dotdash relay list v1")
	}
	var out []gwEntry
	skipped := 0
	for _, line := range lines[1:] {
		f := strings.Fields(line)
		if len(f) == 0 || strings.HasPrefix(f[0], "#") {
			continue
		}
		e := gwEntry{id: strings.ToLower(f[0])}
		if len(f) > 1 {
			e.name = f[1]
		}
		if len(f) > 2 {
			e.prefix = f[2]
		}
		if len(f) > 3 || !uuidRE.MatchString(f[0]) || len(f) > 1 && !nameRE.MatchString(e.name) || len(f) > 2 && !prefixRE.MatchString(e.prefix) {
			skipped++
			continue
		}
		out = append(out, e)
	}
	return out, skipped, nil
}

// gatewayUnion joins the groups' lists and their checkers, each name tagged
// @<group>, an unnamed entry named by a hash of its id: what Xray holds. Xray
// looks an id up with bytes 6 and 7 zeroed, so an id two entries share so
// goes from every group, as does a name a group lists twice; one copied id
// must not take every group down, nor let a device in as another group's.
// A subscription prefix two groups share gets no route. Each is named.
func gatewayUnion(groups []gwGroup) ([]gwUser, map[string][]string, []string) {
	type item struct {
		u             gwUser
		group, prefix string
		checker       bool
	}
	var items []item
	for _, g := range groups {
		st := groupState(g.name)
		items = append(items, item{u: gwUser{st.check, "#check@" + g.name}, group: g.name, checker: true})
		for _, e := range st.list {
			name := e.name
			if name == "" {
				sum := sha256.Sum256([]byte(e.id))
				name = "#" + hex.EncodeToString(sum[:4])
			}
			items = append(items, item{u: gwUser{e.id, name + "@" + g.name}, group: g.name, prefix: e.prefix})
		}
	}
	byID, byName := map[string][]int{}, map[string][]int{}
	for i, it := range items {
		byID[zeroed(it.u.id)] = append(byID[zeroed(it.u.id)], i)
		byName[strings.ToLower(it.u.email)] = append(byName[strings.ToLower(it.u.email)], i)
	}
	drop := map[int]bool{}
	var dropped []string
	for _, set := range []struct {
		by   map[string][]int
		what string
	}{{byID, "one id, once bytes 6 and 7 are zeroed"}, {byName, "one name in one group"}} {
		for _, k := range slices.Sorted(maps.Keys(set.by)) {
			if idx := set.by[k]; len(idx) > 1 {
				var names []string
				for _, i := range idx {
					drop[i] = true
					names = append(names, items[i].u.email)
				}
				dropped = append(dropped, strings.Join(names, ", ")+": "+set.what)
			}
		}
	}
	// Each group's claim on a prefix counts from every entry, dropped or not:
	// a prefix two groups list is theirs both, so no route, whichever entry
	// went. One group's goes to it while an entry it keeps has it.
	var users []gwUser
	groupsOf, namesOf, kept := map[string][]string{}, map[string][]string{}, map[string]bool{}
	for i, it := range items {
		if !drop[i] {
			users = append(users, it.u)
		}
		if it.prefix != "" {
			if !slices.Contains(groupsOf[it.prefix], it.group) {
				groupsOf[it.prefix] = append(groupsOf[it.prefix], it.group)
			}
			namesOf[it.prefix] = append(namesOf[it.prefix], it.u.email)
			kept[it.prefix] = kept[it.prefix] || !drop[i]
		}
	}
	prefixes := map[string][]string{}
	for _, p := range slices.Sorted(maps.Keys(groupsOf)) {
		switch {
		case len(groupsOf[p]) > 1:
			dropped = append(dropped, "the subscription prefix of "+strings.Join(namesOf[p], ", ")+": in two groups, so it has no route")
		case kept[p]:
			prefixes[groupsOf[p][0]] = append(prefixes[groupsOf[p][0]], p)
		}
	}
	slices.Sort(dropped)
	return users, prefixes, dropped
}

// usersDiff counts the users added and removed, an id changed counting as
// both.
func usersDiff(old, now []gwUser) (added, removed int) {
	was := map[gwUser]bool{}
	for _, u := range old {
		was[u] = true
	}
	for _, u := range now {
		if !was[u] {
			added++
		}
		delete(was, u)
	}
	return added, len(was)
}

// gatewayApply brings each device inbound to gw.users, which it reads back
// from Xray first, so a round also mends what an earlier one left undone;
// replaces the routing when the prefixes changed, then reads it back; and
// reports whether Xray is to restart: a removed device is still connected,
// or the routing read back is not the one sent, twice.
func gatewayApply() (bool, error) {
	want := map[string]string{}
	for _, u := range gw.users {
		want[u.email] = u.id
	}
	var removed []string
	var adds []any
	for _, in := range gw.inbounds {
		held, err := inboundUsers(in.tag)
		if err != nil {
			return false, err
		}
		var rm []string
		for _, e := range slices.Sorted(maps.Keys(held)) {
			if want[e] != held[e] {
				rm = append(rm, e)
			}
		}
		var add []gwUser
		for _, u := range gw.users {
			if held[u.email] != u.id {
				add = append(add, u)
			}
		}
		// ponytail: one rmu per inbound with every email on its command line;
		// split it once removals run into the thousands.
		if len(rm) > 0 {
			if _, err := xrayAPI(nil, append([]string{"rmu", "-tag=" + in.tag}, rm...)...); err != nil {
				return false, err
			}
			for _, e := range rm {
				if !slices.Contains(removed, e) {
					removed = append(removed, e)
				}
			}
		}
		if len(add) > 0 {
			adds = append(adds, in.adding(add))
		}
	}
	if len(adds) > 0 {
		body, _ := json.Marshal(map[string]any{"inbounds": adds})
		if _, err := xrayAPI(body, "adu", "stdin:"); err != nil {
			return false, err
		}
	}
	restart := false
	routing := gatewayRouting(gw.groups, gw.opts, gw.prefixes)
	sent, _ := json.Marshal(routing)
	for try := 0; ; try++ {
		if string(sent) != gw.routing || try > 0 {
			body, _ := json.Marshal(map[string]any{"routing": routing})
			if _, err := xrayAPI(body, "adrules", "stdin:"); err != nil {
				return false, err
			}
			gw.routing = string(sent)
		}
		same, err := rulesHeld(routing)
		if err != nil {
			return false, err
		}
		if same {
			break
		}
		if try > 0 {
			fmt.Fprintln(os.Stderr, "gateway: the routing Xray holds is not the one sent, after a replace: restarting Xray on it")
			restart = true
			break
		}
		fmt.Fprintln(os.Stderr, "gateway: the routing Xray holds is not the gateway's: replacing it")
	}
	if len(removed) > 0 {
		online, err := onlineUsers()
		if err != nil {
			return false, err
		}
		var cut []string
		for _, e := range removed {
			if online[e] {
				cut = append(cut, e)
			}
		}
		if len(cut) > 0 {
			fmt.Fprintf(os.Stderr, "gateway: %s removed while connected: restarting Xray, which alone cuts a user's open connections\n", strings.Join(cut, ", "))
			restart = true
		}
	}
	return restart, nil
}

// adding is the inbound as adu takes it, with the users to add: adu needs
// the port, which it otherwise ignores, and a VLESS client gets the
// inbound's flow, which a user added at run time doesn't otherwise.
func (in gwInbound) adding(users []gwUser) map[string]any {
	settings := map[string]any{}
	if in.protocol == "vless" {
		clients := make([]map[string]any, len(users))
		for i, u := range users {
			clients[i] = map[string]any{"id": u.id, "email": u.email}
			if in.flow != "" {
				clients[i]["flow"] = in.flow
			}
		}
		settings["clients"], settings["decryption"] = clients, "none"
	} else {
		list := make([]map[string]any, len(users))
		for i, u := range users {
			list[i] = map[string]any{"auth": u.id, "email": u.email}
		}
		settings["version"], settings["users"] = 2, list
	}
	return map[string]any{"tag": in.tag, "port": in.port, "protocol": in.protocol, "settings": settings}
}

// inboundUsers is what an inbound holds now: each user's id, or its
// Hysteria2 auth, by email.
func inboundUsers(tag string) (map[string]string, error) {
	out, err := xrayAPI(nil, "inbounduser", "-tag="+tag)
	if err != nil {
		return nil, err
	}
	var r struct {
		Users []struct {
			Email   string         `json:"email"`
			Account map[string]any `json:"account"`
		} `json:"users"`
	}
	if err := json.Unmarshal(out, &r); err != nil {
		return nil, fmt.Errorf("xray api inbounduser -tag=%s answered something that is not its users", tag)
	}
	held := map[string]string{}
	for _, u := range r.Users {
		id, _ := u.Account["id"].(string)
		if id == "" {
			id, _ = u.Account["auth"].(string)
		}
		held[u.Email] = strings.ToLower(id)
	}
	return held, nil
}

// rulesHeld reads the routing back: the rules' tags, in order, are the ones
// sent, and the last sends to block.
func rulesHeld(routing map[string]any) (bool, error) {
	out, err := xrayAPI(nil, "lsrules")
	if err != nil {
		return false, err
	}
	var r struct {
		Rules []struct {
			RuleTag string `json:"ruleTag"`
			Tag     string `json:"tag"`
		} `json:"rules"`
	}
	if err := json.Unmarshal(out, &r); err != nil {
		return false, errors.New("xray api lsrules answered something that is not its rules")
	}
	rules := routing["rules"].([]any)
	if len(r.Rules) != len(rules) || r.Rules[len(r.Rules)-1].Tag != "block" {
		return false, nil
	}
	for i, rule := range rules {
		if r.Rules[i].RuleTag != rule.(map[string]any)["ruleTag"] {
			return false, nil
		}
	}
	return true, nil
}

// onlineUsers is every user Xray counts online, by email.
func onlineUsers() (map[string]bool, error) {
	out, err := xrayAPI(nil, "statsgetallonlineusers")
	if err != nil {
		return nil, err
	}
	var r struct {
		Users []string `json:"users"`
	}
	if err := json.Unmarshal(out, &r); err != nil {
		return nil, errors.New("xray api statsgetallonlineusers answered something that is not its users")
	}
	online := map[string]bool{}
	for _, u := range r.Users {
		online[strings.TrimSuffix(strings.TrimPrefix(u, "user>>>"), ">>>online")] = true
	}
	return online, nil
}

// runXrayAPI runs `xray api <command> --server=<the config's API> args...`,
// with stdin when given, and returns what it printed. Its error carries the
// first line Xray printed on stderr, with every id redacted.
func runXrayAPI(stdin []byte, args ...string) ([]byte, error) {
	cmd := exec.Command(img.Bin, append([]string{"api", args[0], "--server=" + gw.api}, args[1:]...)...)
	if stdin != nil {
		cmd.Stdin = bytes.NewReader(stdin)
	}
	var stderr bytes.Buffer
	cmd.Stderr = &stderr
	out, err := cmd.Output()
	if err != nil {
		var ids []string
		for _, u := range gw.users {
			ids = append(ids, u.id)
		}
		line, _, _ := strings.Cut(strings.TrimSpace(stderr.String()+"\n"+string(out)), "\n")
		return out, fmt.Errorf("xray api %s failed (%v): %s", args[0], err, envconf.Redact(line, ids))
	}
	return out, nil
}

// writeGatewayStatus writes the status file whole, through a file beside
// it, so a reader never sees half of one.
func writeGatewayStatus() error {
	st := gwStatus{Round: gwRound, Groups: []gwGroupStatus{}, Dropped: gwDropped}
	if gwLastErr != nil {
		st.Error = gwLastErr.Error()
	}
	devices := map[string]int{}
	for _, u := range gw.users {
		if !strings.HasPrefix(u.email, "#check@") {
			devices[u.email[strings.LastIndexByte(u.email, '@')+1:]]++
		}
	}
	for _, g := range gw.groups {
		s := groupState(g.name)
		legs := s.legs
		if len(legs) == 0 {
			for _, l := range g.legs {
				legs = append(legs, gwLegStatus{Tag: l.tag, Host: l.host, Probe: l.probe, State: "starting"})
			}
		}
		st.Groups = append(st.Groups, gwGroupStatus{Name: g.name, State: s.state, Check: s.check, Devices: devices[g.name],
			Digest: s.digest, Listed: s.listed, Skipped: s.skipped, Legs: legs})
	}
	b, _ := json.MarshalIndent(st, "", "  ")
	p := img.Get("XRAY_GATEWAY_STATUS")
	if err := os.MkdirAll(filepath.Dir(p), 0o755); err != nil {
		return err
	}
	f, err := os.CreateTemp(filepath.Dir(p), ".status-*")
	if err != nil {
		return err
	}
	defer os.Remove(f.Name())
	if _, err := f.Write(append(b, '\n')); err != nil {
		f.Close()
		return err
	}
	// The relay's tasks read it, as whichever user they run as. It holds the
	// checkers' ids, which let in only through this relay's own entries.
	if err := f.Chmod(0o644); err != nil {
		f.Close()
		return err
	}
	if err := f.Close(); err != nil {
		return err
	}
	return os.Rename(f.Name(), p)
}

// gatewayStatusCmd prints the status file, a line per group, and exits 0
// while the agent's last round that reached Xray's API is recent: the
// relay's machinery works, whatever its groups' states.
func gatewayStatusCmd(w io.Writer) int {
	p := img.Get("XRAY_GATEWAY_STATUS")
	b, err := os.ReadFile(p)
	if err != nil {
		fmt.Fprintf(w, "gateway: no status at %s (%v): is $gateway in the config, and Xray running?\n", p, envconf.Cause(err))
		return 1
	}
	var st gwStatus
	if err := json.Unmarshal(b, &st); err != nil {
		fmt.Fprintf(w, "gateway: %s is not the agent's status\n", p)
		return 1
	}
	now := time.Now()
	for _, g := range st.Groups {
		var legs []string
		for _, l := range g.Legs {
			s := l.Host + " " + l.State
			switch {
			case l.State == "ok":
				s += fmt.Sprintf(" %d ms", l.MS)
			case l.Error != "":
				s += " (" + l.Error + ")"
			}
			legs = append(legs, s)
		}
		line := fmt.Sprintf("%-16s %-8s %s", g.Name, g.State, strings.Join(legs, ", "))
		if !g.Listed.IsZero() {
			kept := ""
			if g.State != "live" {
				kept = " kept from the last list"
			}
			line += fmt.Sprintf("; %d devices%s, digest %s, list %d s old", g.Devices, kept, g.Digest, int(now.Sub(g.Listed).Seconds()))
		}
		if g.Skipped > 0 {
			line += fmt.Sprintf(", %d list lines left out", g.Skipped)
		}
		fmt.Fprintln(w, line)
	}
	for _, d := range st.Dropped {
		fmt.Fprintf(w, "dropped: %s\n", d)
	}
	if len(st.Groups) == 0 {
		fmt.Fprintln(w, "no group yet: every device is refused")
	}
	stale := max(gwStaleMin, 2*gwInterval())
	switch {
	case st.Round.IsZero():
		fmt.Fprintf(w, "gateway: no round has reached Xray's API yet%s\n", errSuffix(st.Error))
		return 1
	case now.Sub(st.Round) > stale:
		fmt.Fprintf(w, "gateway: the last round that reached Xray's API was %d s ago%s\n", int(now.Sub(st.Round).Seconds()), errSuffix(st.Error))
		return 1
	}
	fmt.Fprintf(w, "gateway: last round %d s ago\n", int(now.Sub(st.Round).Seconds()))
	return 0
}

func errSuffix(e string) string {
	if e == "" {
		return ""
	}
	return ": " + e
}
