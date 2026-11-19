// proxy-warm keeps connections to upstream proxies open, and logged in, ahead
// of use, and serves each upstream as a SOCKS5 proxy of its own.
//
//	proxy-warm [run]        serve each warm= line of PROXY_WARM_UPSTREAMS
//	proxy-warm healthcheck  check that each line's port answers SOCKS5
//
// Through a SOCKS5 proxy that asks for a login, a new connection costs a
// client such as Xray four round trips to the proxy before its first byte of
// data leaves: TCP, the greeting, the login and the CONNECT, each waiting for
// the one before. Through an HTTP proxy, two. Here the client is answered at
// once, on its own network, and its CONNECT and first bytes go out together
// on a connection opened and logged in beforehand: one round trip, which the
// request takes anyway. With no connection ready, a new one sends its
// greeting, login, CONNECT and data in one go: two round trips.
//
// The upstreams file is the xray image's $upstreams list. The k-th line tagged
// warm=<n>, counting from 0 in the file's order, is served on
// PROXY_WARM_PORT+k, with n connections kept ready. The contract is in
// images/proxy-warm/README.md.
package main

import (
	"bufio"
	"bytes"
	"crypto/tls"
	"encoding/base64"
	"encoding/binary"
	"errors"
	"fmt"
	"io"
	"log"
	"net"
	"net/netip"
	"net/textproto"
	"os"
	"os/signal"
	"regexp"
	"strconv"
	"strings"
	"sync"
	"sync/atomic"
	"syscall"
	"time"

	"github.com/morzecrew/platform-images/shared/go/envconf"
)

// Set at build time to the image's version.
var version = "dev"

const (
	// A dial, a TLS handshake, a SOCKS exchange or a CONNECT's reply.
	timeout = 10 * time.Second
	// How long the client is given to send its first bytes, which go out with
	// its CONNECT. Xray holds them already when it dials, typically a TLS
	// ClientHello. A protocol whose server speaks first sends nothing and
	// waits this long once, hidden by the round trip under way when it is
	// shorter.
	firstWait = 20 * time.Millisecond
	maxSpares = 16
)

var settings = []struct{ name, def string }{
	{"PROXY_WARM_UPSTREAMS", ""},
	{"PROXY_WARM_PORT", "1080"},
	{"PROXY_WARM_MAX_IDLE", "90s"},
}

// get returns a setting, or its default when it is unset or empty.
func get(name string) string {
	if v := os.Getenv(name); v != "" {
		return v
	}
	for _, s := range settings {
		if s.name == name {
			return s.def
		}
	}
	panic("not a setting: " + name)
}

func main() {
	log.SetFlags(0)
	args := os.Args[1:]
	switch {
	case len(args) == 1 && args[0] == "healthcheck":
		os.Exit(healthcheck())
	case len(args) == 0, len(args) == 1 && args[0] == "run":
		if err := run(); err != nil {
			fmt.Fprintln(os.Stderr, "FATAL:", err)
			os.Exit(envconf.ExConfig)
		}
	default:
		fmt.Fprintln(os.Stderr, "usage: proxy-warm [run] | proxy-warm healthcheck")
		os.Exit(64)
	}
}

func run() error {
	warnUnknown()
	c, err := load()
	if err != nil {
		return err
	}
	lns := make([]net.Listener, len(c.ups))
	for k := range c.ups {
		if lns[k], err = net.Listen("tcp", ":"+strconv.Itoa(c.port+k)); err != nil {
			return err
		}
	}
	summary(os.Stderr, c)
	if len(c.ups) == 0 {
		// Not a refusal: a deployment turns this on before it tags a line,
		// and its only line may not lead here until this runs.
		log.Printf("%s has no line tagged warm=: nothing to keep ready until one is", c.path)
	}
	for k, u := range c.ups {
		p := newPool(u, c.maxIdle)
		go p.keep()
		go p.serve(lns[k])
	}
	// PID 1 gets no default action for a signal: without this, a stop
	// would wait for the kill.
	sigs := make(chan os.Signal, 1)
	signal.Notify(sigs, syscall.SIGTERM, syscall.SIGINT)
	<-sigs
	return nil
}

func warnUnknown() {
	for _, kv := range os.Environ() {
		name, _, _ := strings.Cut(kv, "=")
		known := false
		for _, s := range settings {
			known = known || s.name == name
		}
		if strings.HasPrefix(name, "PROXY_WARM_") && !known {
			fmt.Fprintf(os.Stderr, "WARN: %s is set but this image does not read it. Check the spelling against images/proxy-warm/README.md.\n", name)
		}
	}
}

type config struct {
	path    string
	port    int
	maxIdle time.Duration
	ups     []*upstream
}

func load() (*config, error) {
	c := &config{path: get("PROXY_WARM_UPSTREAMS")}
	if c.path == "" {
		return nil, errors.New("PROXY_WARM_UPSTREAMS is unset: point it at the upstreams file")
	}
	s, err := envconf.ReadSecret(c.path)
	if err != nil {
		return nil, fmt.Errorf("PROXY_WARM_UPSTREAMS: %s %v", c.path, err)
	}
	if c.ups, err = parseUpstreams(s); err != nil {
		return nil, fmt.Errorf("%s: %v", c.path, err)
	}
	p, err := strconv.ParseUint(get("PROXY_WARM_PORT"), 10, 16)
	if err != nil || p == 0 || int(p)+len(c.ups)-1 > 65535 {
		return nil, fmt.Errorf("PROXY_WARM_PORT is not a port from 1 to %d, which leaves one for each of the %d warm= lines", 65536-len(c.ups), len(c.ups))
	}
	c.port = int(p)
	if c.maxIdle, err = time.ParseDuration(get("PROXY_WARM_MAX_IDLE")); err != nil || c.maxIdle < 5*time.Second {
		return nil, errors.New("PROXY_WARM_MAX_IDLE is not a duration of 5s or more, such as 90s")
	}
	return c, nil
}

// summary prints the settings and where each port leads, never a login.
func summary(w io.Writer, c *config) {
	fmt.Fprintln(w, "[envconf] proxy-warm: effective configuration")
	for _, s := range settings {
		fmt.Fprintf(w, "[envconf]   source=%-14s %s = %s\n", "env-or-default", s.name, get(s.name))
	}
	fmt.Fprintf(w, "[envconf]   source=%-14s proxy-warm = %s\n", "image", version)
	for k, u := range c.ups {
		fmt.Fprintf(w, "[envconf]   source=%-14s :%d <- %s %s %s, %d kept ready\n", "file", c.port+k, u, u.scheme(), net.JoinHostPort(u.host, u.port), u.spares)
	}
	fmt.Fprintln(w, "[envconf] precedence: image default < environment")
}

// --- the upstreams file ------------------------------------------------------

type upstream struct {
	line       int
	name       string
	socks, tls bool
	host, port string
	user, pass string
	spares     int
}

// String names the line in a log, never with its login.
func (u *upstream) String() string {
	s := fmt.Sprintf("line %d", u.line)
	if u.name != "" {
		s += " (" + u.name + ")"
	}
	return s
}

func (u *upstream) scheme() string {
	switch {
	case u.socks && u.tls:
		return "socks5+tls"
	case u.socks:
		return "socks5"
	case u.tls:
		return "https"
	}
	return "http"
}

func parseUpstreams(s string) ([]*upstream, error) {
	var ups []*upstream
	for i, raw := range strings.Split(s, "\n") {
		line := strings.TrimSpace(raw)
		if line == "" || strings.HasPrefix(line, "#") {
			continue
		}
		u, err := parseLine(line)
		if err != nil {
			return nil, fmt.Errorf("line %d: %v", i+1, err)
		}
		if u != nil {
			u.line = i + 1
			ups = append(ups, u)
		}
	}
	return ups, nil
}

var nameRE = regexp.MustCompile(`^[a-z0-9][a-z0-9-]{0,31}$`)

// parseLine reads a line as the xray image does: its tags, a "|" and its URL;
// the URL alone; or the URL with its tags after it. A line with no warm= tag
// is the gate's alone, and nil: the xray image checks it. The login ends at
// the last @ and the user at its first colon, as the xray image splits it,
// and nothing is percent-decoded. Errors never quote the URL, which holds the
// login.
func parseLine(line string) (*upstream, error) {
	fields := strings.Fields(line)
	url, tags := fields[0], fields[1:]
	if k, _, ok := strings.Cut(url, "="); strings.HasPrefix(url, "|") || ok && (k == "name" || k == "group" || k == "warm") {
		before, after, _ := strings.Cut(line, "|")
		url, tags = "", strings.Fields(before)
		if rest := strings.Fields(after); len(rest) == 1 {
			url = rest[0]
		}
	}
	var u upstream
	warm, tagged := "", false
	for _, t := range tags {
		switch k, v, _ := strings.Cut(t, "="); k {
		case "name":
			// Checked as the xray image checks it, since it goes into the log.
			if !nameRE.MatchString(v) {
				return nil, errors.New("a name is 1 to 32 lowercase letters, digits and dashes, starting with a letter or a digit")
			}
			u.name = v
		case "warm":
			if tagged {
				return nil, errors.New("warm= twice")
			}
			warm, tagged = v, true
		}
	}
	if !tagged {
		return nil, nil
	}
	n, err := strconv.Atoi(warm)
	if err != nil || n < 1 || n > maxSpares {
		return nil, fmt.Errorf("warm= is the number of connections to keep ready, from 1 to %d", maxSpares)
	}
	u.spares = n
	scheme, rest, _ := strings.Cut(url, "://")
	switch scheme {
	case "socks", "socks5":
		u.socks = true
	case "socks5+tls":
		u.socks, u.tls = true, true
	case "http":
	case "https":
		u.tls = true
	default:
		return nil, errors.New("warm= is for a SOCKS5 or an HTTP proxy, whose URL is socks5://, socks5+tls://, http:// or https://")
	}
	hostport := rest
	if i := strings.LastIndexByte(rest, '@'); i >= 0 {
		hostport = rest[i+1:]
		if u.user, u.pass, _ = strings.Cut(rest[:i], ":"); u.user == "" || u.pass == "" {
			return nil, errors.New("before the @ is not a user and a password, both non-empty, joined by a colon")
		}
		if u.socks && (len(u.user) > 255 || len(u.pass) > 255) {
			return nil, errors.New("a SOCKS5 user and password are at most 255 bytes each")
		}
	}
	host, port, err := net.SplitHostPort(hostport)
	if err != nil || host == "" {
		return nil, errors.New("does not end in a host, a colon and a port, with an IPv6 address in brackets")
	}
	if p, err := strconv.ParseUint(port, 10, 16); err != nil || p == 0 {
		return nil, errors.New("the port is not a number from 1 to 65535")
	}
	u.host, u.port = host, port
	return &u, nil
}

// --- talking to the upstream -------------------------------------------------

func (u *upstream) dial() (net.Conn, error) {
	c, err := net.DialTimeout("tcp", net.JoinHostPort(u.host, u.port), timeout)
	if err != nil || !u.tls {
		return c, err
	}
	cfg := &tls.Config{ServerName: u.host, MinVersion: tls.VersionTLS12}
	if !u.socks {
		// HTTP/1.1, whose CONNECT takes the connection as the tunnel.
		cfg.NextProtos = []string{"http/1.1"}
	}
	t := tls.Client(c, cfg)
	_ = t.SetDeadline(time.Now().Add(timeout))
	if err := t.Handshake(); err != nil {
		c.Close()
		return nil, err
	}
	_ = t.SetDeadline(time.Time{})
	return t, nil
}

// hello is what a SOCKS5 proxy is sent before a request: the greeting and, in
// the same write, the login. Nothing for an HTTP proxy, which takes the login
// with each CONNECT.
func (u *upstream) hello() []byte {
	if !u.socks {
		return nil
	}
	if u.user == "" {
		return []byte{5, 1, 0}
	}
	b := append([]byte{5, 1, 2, 1, byte(len(u.user))}, u.user...)
	return append(append(b, byte(len(u.pass))), u.pass...)
}

func (u *upstream) readHello(r io.Reader) error {
	if !u.socks {
		return nil
	}
	var b [2]byte
	if _, err := io.ReadFull(r, b[:]); err != nil {
		return err
	}
	switch {
	case b[0] != 5:
		return errors.New("the proxy answered something other than SOCKS5")
	case u.user == "" && b[1] != 0:
		return errors.New("the proxy asks for a login, and the line has none")
	case u.user != "" && b[1] != 2:
		return errors.New("the proxy does not take a user and a password")
	case u.user == "":
		return nil
	}
	if _, err := io.ReadFull(r, b[:]); err != nil {
		return err
	}
	if b[1] != 0 {
		return errors.New("the proxy refused the login")
	}
	return nil
}

// open is a connection ready for a request: dialled and, for SOCKS5, logged in.
func (u *upstream) open() (net.Conn, error) {
	c, err := u.dial()
	if err != nil || !u.socks {
		return c, err
	}
	_ = c.SetDeadline(time.Now().Add(timeout))
	_, err = c.Write(u.hello())
	if err == nil {
		err = u.readHello(c)
	}
	if err != nil {
		c.Close()
		return nil, err
	}
	_ = c.SetDeadline(time.Time{})
	return c, nil
}

// request is the CONNECT for dst, a destination as SOCKS5 encodes it.
func (u *upstream) request(dst []byte) []byte {
	if u.socks {
		return append([]byte{5, 1, 0}, dst...)
	}
	hp := hostPort(dst)
	s := "CONNECT " + hp + " HTTP/1.1\r\nHost: " + hp + "\r\n"
	if u.user != "" {
		s += "Proxy-Authorization: Basic " + base64.StdEncoding.EncodeToString([]byte(u.user+":"+u.pass)) + "\r\n"
	}
	return []byte(s + "\r\n")
}

// answer reads the replies to what was sent: the greeting's and the login's
// with hello, then the CONNECT's. What an HTTP proxy sent after its header is
// the tunnel's already, and returned. heard is whether any byte came back.
func (u *upstream) answer(c net.Conn, hello bool) (left []byte, heard bool, err error) {
	r := &counter{r: c}
	if hello {
		if err := u.readHello(r); err != nil {
			return nil, r.n > 0, err
		}
	}
	if u.socks {
		_, _, err = readReply(r)
		return nil, r.n > 0, err
	}
	// Bounded: a header never needs more, and the rest is read from c itself.
	br := bufio.NewReader(io.LimitReader(r, 64<<10))
	tp := textproto.NewReader(br)
	status, err := tp.ReadLine()
	if err == nil {
		_, err = tp.ReadMIMEHeader()
	}
	if err != nil {
		return nil, r.n > 0, err
	}
	proto, code, _ := strings.Cut(status, " ")
	if !strings.HasPrefix(proto, "HTTP/1.") || len(code) < 3 || code[0] != '2' {
		return nil, true, fmt.Errorf("the proxy refused the CONNECT (%.3s)", code)
	}
	left, _ = br.Peek(br.Buffered())
	return left, true, nil
}

// readReply reads a SOCKS5 reply and returns the address in it.
func readReply(r io.Reader) (string, int, error) {
	var h [4]byte
	if _, err := io.ReadFull(r, h[:]); err != nil {
		return "", 0, err
	}
	if h[0] != 5 {
		return "", 0, errors.New("the proxy answered something other than SOCKS5")
	}
	if h[1] != 0 {
		return "", 0, fmt.Errorf("the proxy refused the request (%d)", h[1])
	}
	var a []byte
	switch h[3] {
	case 1:
		a = make([]byte, 4+2)
	case 4:
		a = make([]byte, 16+2)
	case 3:
		var n [1]byte
		if _, err := io.ReadFull(r, n[:]); err != nil {
			return "", 0, err
		}
		a = make([]byte, int(n[0])+2)
	default:
		return "", 0, errors.New("the proxy answered with an unknown address type")
	}
	if _, err := io.ReadFull(r, a); err != nil {
		return "", 0, err
	}
	port := int(binary.BigEndian.Uint16(a[len(a)-2:]))
	if h[3] == 3 {
		return string(a[:len(a)-2]), port, nil
	}
	return net.IP(a[:len(a)-2]).String(), port, nil
}

type counter struct {
	r io.Reader
	n int
}

func (c *counter) Read(p []byte) (int, error) {
	n, err := c.r.Read(p)
	c.n += n
	return n, err
}

// hostPort is a SOCKS5 destination as host:port.
func hostPort(dst []byte) string {
	port := strconv.Itoa(int(binary.BigEndian.Uint16(dst[len(dst)-2:])))
	switch dst[0] {
	case 1:
		return net.JoinHostPort(net.IP(dst[1:5]).String(), port)
	case 4:
		return net.JoinHostPort(net.IP(dst[1:17]).String(), port)
	}
	return net.JoinHostPort(string(dst[2:len(dst)-2]), port)
}

// alive reports whether an idle connection is still open: nothing to read,
// neither data nor an end, which a proxy that closed it would have sent.
func alive(c net.Conn) bool {
	var b [1]byte
	_ = c.SetReadDeadline(time.Now())
	n, err := c.Read(b[:])
	_ = c.SetReadDeadline(time.Time{})
	var ne net.Error
	return n == 0 && errors.As(err, &ne) && ne.Timeout()
}

// --- the pool ----------------------------------------------------------------

type spare struct {
	c    net.Conn
	born time.Time
}

// A UDP association: it lives as long as its control connection.
type assoc struct {
	ctrl  net.Conn
	relay *net.UDPConn
	born  time.Time
}

func (a *assoc) close() {
	a.ctrl.Close()
	a.relay.Close()
}

type pool struct {
	up      *upstream
	maxIdle time.Duration
	tcp     chan spare
	// Associations, kept ready once a client has asked for one: none while
	// the client sends no UDP.
	udp     chan *assoc
	wantUDP atomic.Bool
	wake    chan struct{}
}

func newPool(u *upstream, maxIdle time.Duration) *pool {
	p := &pool{up: u, maxIdle: maxIdle, tcp: make(chan spare, u.spares), wake: make(chan struct{}, 1)}
	if u.socks {
		p.udp = make(chan *assoc, (u.spares+1)/2)
	}
	return p
}

// An association's relay may forget a mapping that carried nothing sooner
// than the proxy closes an idle connection, and a lost datagram says nothing.
func (p *pool) udpIdle() time.Duration { return p.maxIdle / 3 }

func (p *pool) poke() {
	select {
	case p.wake <- struct{}{}:
	default:
	}
}

// keep keeps the spares topped up: at once when one is taken, and every
// maxIdle/6 to replace those gone stale. Never is one used past maxIdle.
func (p *pool) keep() {
	tick := time.NewTicker(p.maxIdle / 6)
	fails := 0
	for {
		p.expire()
		if err := p.fill(); err != nil {
			fails++
			wait := min(time.Second<<min(fails-1, 5), 30*time.Second)
			log.Printf("%s: %v; trying again in %s", p.up, err, wait)
			time.Sleep(wait)
			continue
		}
		if fails > 0 {
			log.Printf("%s: connections ready again", p.up)
			fails = 0
		}
		select {
		case <-p.wake:
		case <-tick.C:
		}
	}
}

// expire closes the spares gone stale or closed by the proxy. It runs while
// nothing else adds to the pool, so putting one back never blocks.
func (p *pool) expire() {
	for range len(p.tcp) {
		select {
		case s := <-p.tcp:
			if time.Since(s.born) < p.maxIdle && alive(s.c) {
				p.tcp <- s
			} else {
				s.c.Close()
			}
		default:
		}
	}
	for range len(p.udp) {
		select {
		case a := <-p.udp:
			if time.Since(a.born) < p.udpIdle() && alive(a.ctrl) {
				p.udp <- a
			} else {
				a.close()
			}
		default:
		}
	}
}

// fill opens what is missing, all at once, and returns the first error.
func (p *pool) fill() error {
	var wg sync.WaitGroup
	errs := make(chan error, cap(p.tcp)+cap(p.udp))
	for range cap(p.tcp) - len(p.tcp) {
		wg.Go(func() {
			c, err := p.up.open()
			if err != nil {
				errs <- err
				return
			}
			p.tcp <- spare{c, time.Now()}
		})
	}
	if p.wantUDP.Load() {
		for range cap(p.udp) - len(p.udp) {
			wg.Go(func() {
				a, err := p.freshAssoc()
				if err != nil {
					errs <- err
					return
				}
				p.udp <- a
			})
		}
	}
	wg.Wait()
	close(errs)
	return <-errs
}

// take is a spare, or nil with none ready.
func (p *pool) take() net.Conn {
	defer p.poke()
	for {
		select {
		case s := <-p.tcp:
			if time.Since(s.born) < p.maxIdle && alive(s.c) {
				return s.c
			}
			s.c.Close()
		default:
			return nil
		}
	}
}

// --- serving the client ------------------------------------------------------

func (p *pool) serve(ln net.Listener) {
	for {
		c, err := ln.Accept()
		if err != nil {
			log.Printf("%s: %v", p.up, err)
			time.Sleep(100 * time.Millisecond)
			continue
		}
		go p.handle(c)
	}
}

func (p *pool) handle(c net.Conn) {
	defer c.Close()
	_ = c.SetDeadline(time.Now().Add(timeout))
	cmd, dst, err := readRequest(c)
	if err != nil {
		return
	}
	_ = c.SetDeadline(time.Time{})
	switch cmd {
	case 1:
		p.connect(c, dst)
	case 3:
		p.associate(c)
	default:
		_, _ = c.Write(reply(7, netip.AddrPort{}))
	}
}

// readRequest answers a client's greeting, which must offer no login, and
// returns its request's command and destination, as SOCKS5 encodes it.
func readRequest(c net.Conn) (byte, []byte, error) {
	var b [262]byte
	if _, err := io.ReadFull(c, b[:2]); err != nil {
		return 0, nil, err
	}
	methods := b[2 : 2+int(b[1])]
	if _, err := io.ReadFull(c, methods); err != nil {
		return 0, nil, err
	}
	if b[0] != 5 || bytes.IndexByte(methods, 0) < 0 {
		_, _ = c.Write([]byte{5, 0xff})
		return 0, nil, errors.New("not SOCKS5 without a login")
	}
	if _, err := c.Write([]byte{5, 0}); err != nil {
		return 0, nil, err
	}
	if _, err := io.ReadFull(c, b[:5]); err != nil {
		return 0, nil, err
	}
	var n int
	switch b[3] {
	case 1:
		n = 3 + 2
	case 4:
		n = 15 + 2
	case 3:
		n = int(b[4]) + 2
	}
	if b[0] != 5 || n == 0 || b[3] == 3 && b[4] == 0 {
		_, _ = c.Write(reply(8, netip.AddrPort{}))
		return 0, nil, errors.New("not a SOCKS5 address")
	}
	if _, err := io.ReadFull(c, b[5:5+n]); err != nil {
		return 0, nil, err
	}
	dst := bytes.Clone(b[3 : 5+n])
	// A name goes into an HTTP CONNECT's request line as it is.
	if dst[0] == 3 && bytes.ContainsFunc(dst[2:len(dst)-2], func(r rune) bool { return r <= ' ' || r >= 0x7f }) {
		_, _ = c.Write(reply(8, netip.AddrPort{}))
		return 0, nil, errors.New("a name with a space or a control character")
	}
	return b[1], dst, nil
}

func reply(code byte, a netip.AddrPort) []byte {
	b := []byte{5, code, 0, 1, 0, 0, 0, 0}
	if ip := a.Addr().Unmap(); ip.Is4() {
		b = append(b[:4], ip.AsSlice()...)
	} else if ip.Is6() {
		b = append(append(b[:3], 4), ip.AsSlice()...)
	}
	return binary.BigEndian.AppendUint16(b, a.Port())
}

// connect carries a CONNECT. The client is told yes at once, so it sends what
// it has without waiting; a refusal upstream then closes the connection, as a
// refused site would.
func (p *pool) connect(c net.Conn, dst []byte) {
	if _, err := c.Write(reply(0, netip.AddrPort{})); err != nil {
		return
	}
	req := p.up.request(dst)
	up := p.take()
	spare := up != nil
	if !spare {
		var err error
		if up, err = p.up.dial(); err != nil {
			return
		}
		req = append(p.up.hello(), req...)
	}
	defer func() { up.Close() }()
	// The CONNECT leaves now, and the first bytes as soon as they come:
	// neither waits for a reply. A write to a dead spare fails, or vanishes;
	// either way no reply comes, which answer reports.
	_ = up.SetDeadline(time.Now().Add(timeout))
	_, _ = up.Write(req)
	first := readFirst(c)
	if len(first) > 0 {
		_, _ = up.Write(first)
	}
	left, heard, err := p.up.answer(up, !spare)
	if err != nil && spare && !heard {
		// The spare was dead: the proxy closed it, or a NAT on the way
		// forgot it. Everything goes again on a new connection.
		up.Close()
		if up, err = p.up.dial(); err != nil {
			return
		}
		_ = up.SetDeadline(time.Now().Add(timeout))
		_, _ = up.Write(append(append(p.up.hello(), p.up.request(dst)...), first...))
		left, _, err = p.up.answer(up, true)
	}
	if err != nil {
		return
	}
	_ = up.SetDeadline(time.Time{})
	if len(left) > 0 {
		if _, err := c.Write(left); err != nil {
			return
		}
	}
	pipe(c, up)
}

// readFirst returns what the client sent within firstWait.
func readFirst(c net.Conn) []byte {
	b := make([]byte, 32<<10)
	_ = c.SetReadDeadline(time.Now().Add(firstWait))
	n, _ := c.Read(b)
	_ = c.SetReadDeadline(time.Time{})
	return b[:n]
}

// pipe copies both ways until the client is gone. Xray, the client this
// serves, closes a connection whole and never half, so the end of what it
// sends is the end of the connection. The proxy's end is passed on as a half
// close, which Xray reads as the end of the reply, and then closes.
func pipe(c, up net.Conn) {
	done := make(chan struct{})
	go func() {
		_, _ = io.Copy(c, up)
		if cw, ok := c.(interface{ CloseWrite() error }); ok {
			_ = cw.CloseWrite()
		}
		close(done)
	}()
	_, _ = io.Copy(up, c)
	up.Close()
	c.Close()
	<-done
}

// --- UDP ---------------------------------------------------------------------

// associateOn asks for a UDP association on c, after the greeting and login
// when hello. heard is whether any byte came back.
func (u *upstream) associateOn(c net.Conn, hello bool) (a *assoc, heard bool, err error) {
	req := []byte{5, 3, 0, 1, 0, 0, 0, 0, 0, 0}
	if hello {
		req = append(u.hello(), req...)
	}
	_ = c.SetDeadline(time.Now().Add(timeout))
	defer func() { _ = c.SetDeadline(time.Time{}) }()
	_, _ = c.Write(req)
	r := &counter{r: c}
	if hello {
		if err := u.readHello(r); err != nil {
			return nil, r.n > 0, err
		}
	}
	host, port, err := readReply(r)
	if err != nil {
		return nil, r.n > 0, err
	}
	// The relay is on the proxy's own address when the reply names none.
	if ip := net.ParseIP(host); ip != nil && ip.IsUnspecified() {
		host, _, _ = net.SplitHostPort(c.RemoteAddr().String())
	}
	ra, err := net.ResolveUDPAddr("udp", net.JoinHostPort(host, strconv.Itoa(port)))
	if err != nil {
		return nil, true, err
	}
	relay, err := net.DialUDP("udp", nil, ra)
	if err != nil {
		return nil, true, err
	}
	return &assoc{ctrl: c, relay: relay, born: time.Now()}, true, nil
}

func (p *pool) freshAssoc() (*assoc, error) {
	c, err := p.up.dial()
	if err != nil {
		return nil, err
	}
	a, _, err := p.up.associateOn(c, true)
	if err != nil {
		c.Close()
	}
	return a, err
}

// takeAssoc is an association: a ready one, else one asked for on a spare
// (one round trip), else on a new connection (two).
func (p *pool) takeAssoc() (*assoc, error) {
	for len(p.udp) > 0 {
		select {
		case a := <-p.udp:
			p.poke()
			if time.Since(a.born) < p.udpIdle() && alive(a.ctrl) {
				return a, nil
			}
			a.close()
		default:
		}
	}
	if c := p.take(); c != nil {
		a, heard, err := p.up.associateOn(c, false)
		if err == nil {
			return a, nil
		}
		c.Close()
		if heard {
			return nil, err
		}
	}
	return p.freshAssoc()
}

// associate carries a UDP ASSOCIATE. The client is answered once the proxy's
// association is ready, with a port of this container's where the client's
// datagrams go; they and the replies pass through unchanged, since the client
// and the proxy frame them alike.
func (p *pool) associate(c net.Conn) {
	if !p.up.socks {
		// An HTTP proxy carries no UDP.
		_, _ = c.Write(reply(7, netip.AddrPort{}))
		return
	}
	if !p.wantUDP.Swap(true) {
		p.poke()
	}
	a, err := p.takeAssoc()
	if err != nil {
		_, _ = c.Write(reply(1, netip.AddrPort{}))
		return
	}
	defer a.close()
	local := c.LocalAddr().(*net.TCPAddr)
	l, err := net.ListenUDP("udp", &net.UDPAddr{IP: local.IP})
	if err != nil {
		_, _ = c.Write(reply(1, netip.AddrPort{}))
		return
	}
	defer l.Close()
	if _, err := c.Write(reply(0, l.LocalAddr().(*net.UDPAddr).AddrPort())); err != nil {
		return
	}
	peer := c.RemoteAddr().(*net.TCPAddr).IP
	var client atomic.Pointer[net.UDPAddr]
	go func() {
		b := make([]byte, 64<<10)
		for {
			n, from, err := l.ReadFromUDP(b)
			if err != nil {
				return
			}
			// Only from the client that asked.
			if from.IP.Equal(peer) {
				client.Store(from)
				_, _ = a.relay.Write(b[:n])
			}
		}
	}()
	go func() {
		b := make([]byte, 64<<10)
		for {
			n, err := a.relay.Read(b)
			if errors.Is(err, syscall.ECONNREFUSED) {
				continue // an ICMP unreachable for an earlier datagram
			}
			if err != nil {
				return
			}
			if to := client.Load(); to != nil {
				_, _ = l.WriteToUDP(b[:n], to)
			}
		}
	}()
	// The association lasts while both control connections do.
	go func() {
		_, _ = io.Copy(io.Discard, a.ctrl)
		c.Close()
	}()
	_, _ = io.Copy(io.Discard, c)
}

// --- healthcheck -------------------------------------------------------------

// healthcheck passes while each line's port answers a SOCKS5 greeting. Whether
// a line carries traffic is its client's to judge.
func healthcheck() int {
	c, err := load()
	if err != nil {
		fmt.Fprintln(os.Stderr, "unhealthy:", err)
		return 1
	}
	for k := range c.ups {
		addr := net.JoinHostPort("127.0.0.1", strconv.Itoa(c.port+k))
		conn, err := net.DialTimeout("tcp", addr, 2*time.Second)
		if err != nil {
			fmt.Fprintf(os.Stderr, "unhealthy: %s: %v\n", c.ups[k], err)
			return 1
		}
		_ = conn.SetDeadline(time.Now().Add(2 * time.Second))
		var b [2]byte
		_, err = conn.Write([]byte{5, 1, 0})
		if err == nil {
			_, err = io.ReadFull(conn, b[:])
		}
		conn.Close()
		if err != nil || b != [2]byte{5, 0} {
			fmt.Fprintf(os.Stderr, "unhealthy: %s: %s does not answer SOCKS5\n", c.ups[k], addr)
			return 1
		}
	}
	return 0
}
