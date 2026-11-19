package main

import (
	"bufio"
	"bytes"
	"encoding/base64"
	"encoding/binary"
	"io"
	"log"
	"net"
	"net/textproto"
	"os"
	"strconv"
	"strings"
	"sync"
	"sync/atomic"
	"testing"
	"time"
)

func TestMain(m *testing.M) {
	log.SetOutput(io.Discard)
	os.Exit(m.Run())
}

func TestParseLine(t *testing.T) {
	for _, tc := range []struct {
		line string
		want *upstream // nil: not served
		err  string
	}{
		{line: "socks5://u:p4ss@proxy.example:1080 name=isp warm=4",
			want: &upstream{name: "isp", socks: true, host: "proxy.example", port: "1080", user: "u", pass: "p4ss", spares: 4}},
		{line: "name=isp group=a,b warm=2 | http://u:p4ss:x@y@proxy.example:8080",
			want: &upstream{name: "isp", host: "proxy.example", port: "8080", user: "u", pass: "p4ss:x@y", spares: 2}},
		{line: "warm=1|https://[2001:db8::1]:443",
			want: &upstream{tls: true, host: "2001:db8::1", port: "443", spares: 1}},
		{line: "socks5+tls://proxy.example:1080 warm=16",
			want: &upstream{socks: true, tls: true, host: "proxy.example", port: "1080", spares: 16}},
		{line: "socks5://u:p4ss@proxy.example:1080 name=isp"},
		{line: "name=a | openvpn://H4sI"},
		{line: "openvpn://H4sI warm=1", err: "is for a SOCKS5 or an HTTP proxy"},
		{line: "wireguard://k3y@1.2.3.4:51820 warm=1", err: "is for a SOCKS5 or an HTTP proxy"},
		{line: "socks5://u:p4ss@proxy.example:1080 warm=0", err: "from 1 to 16"},
		{line: "socks5://u:p4ss@proxy.example:1080 warm=17", err: "from 1 to 16"},
		{line: "socks5://u:p4ss@proxy.example:1080 warm=", err: "from 1 to 16"},
		{line: "socks5://u:p4ss@proxy.example:1080 warm=1 warm=2", err: "twice"},
		{line: "socks5://:p4ss@proxy.example:1080 warm=1", err: "user and a password"},
		{line: "socks5://u:p4ss@proxy.example warm=1", err: "a host, a colon and a port"},
		{line: "socks5://u:p4ss@proxy.example:0 warm=1", err: "from 1 to 65535"},
		{line: "warm=1 | ", err: "is for a SOCKS5"},
		{line: "name=p4ss\x1b[2J warm=1 | socks5://u:p4ss@proxy.example:1080", err: "a name is 1 to 32"},
	} {
		got, err := parseLine(tc.line)
		switch {
		case tc.err != "":
			if err == nil || !strings.Contains(err.Error(), tc.err) {
				t.Errorf("%q: error %v, want one saying %q", tc.line, err, tc.err)
			} else if strings.Contains(err.Error(), "p4ss") {
				t.Errorf("%q: the error quotes the password: %v", tc.line, err)
			}
		case err != nil:
			t.Errorf("%q: %v", tc.line, err)
		case tc.want == nil && got != nil:
			t.Errorf("%q: served, and should be the gate's alone", tc.line)
		case tc.want != nil && (got == nil || *got != *tc.want):
			t.Errorf("%q: got %+v, want %+v", tc.line, got, tc.want)
		}
	}
	ups, err := parseUpstreams("# list\nsocks5://a.example:1 warm=1\n\nhttp://b.example:2\nname=c warm=3 | http://c.example:3\n")
	if err != nil || len(ups) != 2 || ups[0].line != 2 || ups[1].line != 5 || ups[1].String() != "line 5 (c)" {
		t.Fatalf("parseUpstreams: %v, %+v", err, ups)
	}
}

// A fake upstream proxy: SOCKS5 or HTTP, with a login, waiting delay before
// each reply, as a proxy one round trip away would answer.
type fake struct {
	socks      bool
	user, pass string
	delay      time.Duration
	refuse     bool
	drop       atomic.Int32 // requests to close unanswered, as a dead spare does
	logins     atomic.Int32
	requests   atomic.Int32
}

func (f *fake) start(t *testing.T) *upstream {
	ln, err := net.Listen("tcp", "127.0.0.1:0")
	if err != nil {
		t.Fatal(err)
	}
	t.Cleanup(func() { ln.Close() })
	go func() {
		for {
			c, err := ln.Accept()
			if err != nil {
				return
			}
			go f.handle(c)
		}
	}()
	host, port, _ := net.SplitHostPort(ln.Addr().String())
	return &upstream{socks: f.socks, host: host, port: port, user: f.user, pass: f.pass, line: 1}
}

func (f *fake) handle(c net.Conn) {
	defer c.Close()
	br := bufio.NewReader(c)
	if !f.socks {
		f.handleHTTP(c, br)
		return
	}
	var b [262]byte
	if _, err := io.ReadFull(br, b[:2]); err != nil {
		return
	}
	if _, err := io.ReadFull(br, b[2:2+b[1]]); err != nil {
		return
	}
	time.Sleep(f.delay)
	if f.user == "" {
		c.Write([]byte{5, 0})
	} else {
		c.Write([]byte{5, 2})
		if _, err := io.ReadFull(br, b[:2]); err != nil {
			return
		}
		user := make([]byte, b[1])
		io.ReadFull(br, user)
		io.ReadFull(br, b[:1])
		pass := make([]byte, b[0])
		io.ReadFull(br, pass)
		time.Sleep(f.delay)
		if string(user) != f.user || string(pass) != f.pass {
			c.Write([]byte{1, 1})
			return
		}
		c.Write([]byte{1, 0})
		f.logins.Add(1)
	}
	if _, err := io.ReadFull(br, b[:3]); err != nil {
		return
	}
	host, port, err := readAddr(br)
	if err != nil {
		return
	}
	f.requests.Add(1)
	if f.drop.Add(-1) >= 0 {
		return
	}
	time.Sleep(f.delay)
	ok := []byte{5, 0, 0, 1, 0, 0, 0, 0, 0, 0}
	switch b[1] {
	case 1:
		if f.refuse {
			c.Write([]byte{5, 5, 0, 1, 0, 0, 0, 0, 0, 0})
			return
		}
		tgt, err := net.Dial("tcp", net.JoinHostPort(host, strconv.Itoa(port)))
		if err != nil {
			c.Write([]byte{5, 4, 0, 1, 0, 0, 0, 0, 0, 0})
			return
		}
		c.Write(ok)
		relay(c, br, tgt)
	case 3:
		u, _ := net.ListenUDP("udp", &net.UDPAddr{IP: net.IPv4(127, 0, 0, 1)})
		defer u.Close()
		// 0.0.0.0: the relay is on the proxy's own address.
		c.Write(binary.BigEndian.AppendUint16(ok[:8], uint16(u.LocalAddr().(*net.UDPAddr).Port)))
		go f.relayUDP(u)
		io.Copy(io.Discard, br)
	}
}

// relayUDP sends what the client frames on to its destination, and what comes
// back framed with where it came from.
func (f *fake) relayUDP(u *net.UDPConn) {
	var client *net.UDPAddr
	b := make([]byte, 64<<10)
	for {
		n, from, err := u.ReadFromUDP(b)
		if err != nil {
			return
		}
		if client == nil || from.String() == client.String() {
			client = from
			r := bytes.NewReader(b[3:n])
			host, port, err := readAddr(r)
			if err != nil {
				continue
			}
			payload, _ := io.ReadAll(r)
			u.WriteToUDP(payload, &net.UDPAddr{IP: net.ParseIP(host), Port: port})
			continue
		}
		hdr := append([]byte{0, 0, 0, 1}, from.IP.To4()...)
		hdr = binary.BigEndian.AppendUint16(hdr, uint16(from.Port))
		u.WriteToUDP(append(hdr, b[:n]...), client)
	}
}

func (f *fake) handleHTTP(c net.Conn, br *bufio.Reader) {
	tp := textproto.NewReader(br)
	line, err := tp.ReadLine()
	if err != nil {
		return
	}
	h, err := tp.ReadMIMEHeader()
	if err != nil {
		return
	}
	f.requests.Add(1)
	if f.drop.Add(-1) >= 0 {
		return
	}
	time.Sleep(f.delay)
	if h.Get("Proxy-Authorization") != "Basic "+base64.StdEncoding.EncodeToString([]byte(f.user+":"+f.pass)) {
		io.WriteString(c, "HTTP/1.1 407 Proxy Authentication Required\r\n\r\n")
		return
	}
	f.logins.Add(1)
	if f.refuse {
		io.WriteString(c, "HTTP/1.1 403 Forbidden\r\n\r\n")
		return
	}
	tgt, err := net.Dial("tcp", strings.Fields(line)[1])
	if err != nil {
		io.WriteString(c, "HTTP/1.1 502 Bad Gateway\r\n\r\n")
		return
	}
	io.WriteString(c, "HTTP/1.1 200 Connection established\r\n\r\n")
	relay(c, br, tgt)
}

// relay copies both ways, br first, which may hold bytes sent before the reply.
func relay(c net.Conn, br *bufio.Reader, tgt net.Conn) {
	defer tgt.Close()
	go io.Copy(tgt, br)
	io.Copy(c, tgt)
}

func readAddr(r io.Reader) (string, int, error) {
	var a [1]byte
	if _, err := io.ReadFull(r, a[:]); err != nil {
		return "", 0, err
	}
	var addr []byte
	switch a[0] {
	case 1:
		addr = make([]byte, 4)
	case 4:
		addr = make([]byte, 16)
	default:
		var n [1]byte
		io.ReadFull(r, n[:])
		addr = make([]byte, n[0])
	}
	var p [2]byte
	if _, err := io.ReadFull(r, addr); err != nil {
		return "", 0, err
	}
	if _, err := io.ReadFull(r, p[:]); err != nil {
		return "", 0, err
	}
	host := string(addr)
	if a[0] != 3 {
		host = net.IP(addr).String()
	}
	return host, int(binary.BigEndian.Uint16(p[:])), nil
}

// echo is a target that sends back what it gets, on TCP and on UDP.
func echo(t *testing.T) (*net.TCPAddr, *net.UDPAddr) {
	ln, err := net.Listen("tcp", "127.0.0.1:0")
	if err != nil {
		t.Fatal(err)
	}
	t.Cleanup(func() { ln.Close() })
	go func() {
		for {
			c, err := ln.Accept()
			if err != nil {
				return
			}
			go func() { defer c.Close(); io.Copy(c, c) }()
		}
	}()
	u, err := net.ListenUDP("udp", &net.UDPAddr{IP: net.IPv4(127, 0, 0, 1)})
	if err != nil {
		t.Fatal(err)
	}
	t.Cleanup(func() { u.Close() })
	go func() {
		b := make([]byte, 64<<10)
		for {
			n, from, err := u.ReadFromUDP(b)
			if err != nil {
				return
			}
			u.WriteToUDP(b[:n], from)
		}
	}()
	return ln.Addr().(*net.TCPAddr), u.LocalAddr().(*net.UDPAddr)
}

func serveWarm(t *testing.T, u *upstream, spares int) (string, *pool) {
	u.spares = spares
	p := newPool(u, 90*time.Second)
	ln, err := net.Listen("tcp", "127.0.0.1:0")
	if err != nil {
		t.Fatal(err)
	}
	t.Cleanup(func() { ln.Close() })
	go p.keep()
	go p.serve(ln)
	return ln.Addr().String(), p
}

func waitFor(t *testing.T, what string, cond func() bool) {
	t.Helper()
	for deadline := time.Now().Add(5 * time.Second); !cond(); time.Sleep(10 * time.Millisecond) {
		if time.Now().After(deadline) {
			t.Fatalf("timed out waiting for %s", what)
		}
	}
}

// socks asks the server at addr, as Xray does, step by step: the greeting,
// then the request, each waiting for its reply.
func socks(t *testing.T, addr string, cmd byte, dst *net.TCPAddr) (net.Conn, []byte) {
	t.Helper()
	c, err := net.Dial("tcp", addr)
	if err != nil {
		t.Fatal(err)
	}
	t.Cleanup(func() { c.Close() })
	c.SetDeadline(time.Now().Add(5 * time.Second))
	var b [2]byte
	c.Write([]byte{5, 1, 0})
	if _, err := io.ReadFull(c, b[:]); err != nil || b != [2]byte{5, 0} {
		t.Fatalf("greeting: %v %v", b, err)
	}
	req := append([]byte{5, cmd, 0, 1}, dst.IP.To4()...)
	c.Write(binary.BigEndian.AppendUint16(req, uint16(dst.Port)))
	r := make([]byte, 10)
	if _, err := io.ReadFull(c, r); err != nil {
		t.Fatalf("reply: %v", err)
	}
	return c, r
}

// roundTrip sends ping through c and times the echo.
func roundTrip(t *testing.T, c net.Conn) (time.Duration, error) {
	t.Helper()
	start := time.Now()
	c.Write([]byte("ping"))
	b := make([]byte, 4)
	_, err := io.ReadFull(c, b)
	if err == nil && string(b) != "ping" {
		t.Fatalf("echo %q", b)
	}
	return time.Since(start), err
}

const rtt = 200 * time.Millisecond

func TestWarmSOCKS5(t *testing.T) {
	tcp, _ := echo(t)
	f := &fake{socks: true, user: "u", pass: "p4ss", delay: rtt}
	addr, _ := serveWarm(t, f.start(t), 2)
	waitFor(t, "two spares logged in", func() bool { return f.logins.Load() == 2 })
	c, r := socks(t, addr, 1, tcp)
	if r[1] != 0 {
		t.Fatalf("reply %v", r)
	}
	// The CONNECT's reply is the one round trip: the greeting and the login
	// were made beforehand, and the data went with the CONNECT.
	d, err := roundTrip(t, c)
	if err != nil || d > 2*rtt {
		t.Fatalf("the first echo took %v (%v), more than the one round trip of %v it needs", d, err, rtt)
	}
	t.Logf("first echo after %v, one round trip being %v", d, rtt)
}

func TestWarmHTTP(t *testing.T) {
	tcp, _ := echo(t)
	f := &fake{user: "u", pass: "p4ss", delay: rtt}
	addr, _ := serveWarm(t, f.start(t), 2)
	time.Sleep(100 * time.Millisecond) // the spares' TCP, which logs nothing in
	c, _ := socks(t, addr, 1, tcp)
	d, err := roundTrip(t, c)
	if err != nil || d > 2*rtt {
		t.Fatalf("the first echo took %v (%v), more than the one round trip of %v it needs", d, err, rtt)
	}
	if f.logins.Load() != 1 {
		t.Fatalf("%d CONNECTs logged in, want 1", f.logins.Load())
	}
}

// With no spare ready, each connection still gets through, its greeting,
// login and CONNECT sent together.
func TestNoSpareReady(t *testing.T) {
	tcp, _ := echo(t)
	f := &fake{socks: true, user: "u", pass: "p4ss"}
	addr, _ := serveWarm(t, f.start(t), 1)
	var wg sync.WaitGroup
	for range 8 {
		wg.Go(func() {
			c, _ := socks(t, addr, 1, tcp)
			if _, err := roundTrip(t, c); err != nil {
				t.Error(err)
			}
		})
	}
	wg.Wait()
}

// A spare the proxy dropped without a word still carries the connection: it
// goes again on a new one.
func TestDeadSpare(t *testing.T) {
	tcp, _ := echo(t)
	for _, socks5 := range []bool{true, false} {
		f := &fake{socks: socks5, user: "u", pass: "p4ss"}
		addr, p := serveWarm(t, f.start(t), 1)
		waitFor(t, "a spare", func() bool { return len(p.tcp) == 1 })
		f.drop.Store(1)
		c, _ := socks(t, addr, 1, tcp)
		if _, err := roundTrip(t, c); err != nil {
			t.Fatalf("socks5=%v: %v", socks5, err)
		}
		if n := f.requests.Load(); n != 2 {
			t.Fatalf("socks5=%v: %d requests reached the proxy, want 2", socks5, n)
		}
	}
}

// The client is told yes before the proxy answers; a refusal then closes the
// connection.
func TestRefused(t *testing.T) {
	tcp, _ := echo(t)
	for _, socks5 := range []bool{true, false} {
		f := &fake{socks: socks5, user: "u", pass: "p4ss", refuse: true}
		addr, _ := serveWarm(t, f.start(t), 1)
		c, r := socks(t, addr, 1, tcp)
		if r[1] != 0 {
			t.Fatalf("socks5=%v: reply %v", socks5, r)
		}
		if _, err := roundTrip(t, c); err == nil {
			t.Fatalf("socks5=%v: a refused CONNECT carried data", socks5)
		}
	}
}

func TestWrongLogin(t *testing.T) {
	tcp, _ := echo(t)
	f := &fake{socks: true, user: "u", pass: "right"}
	u := f.start(t)
	u.pass = "wrong"
	addr, _ := serveWarm(t, u, 1)
	c, _ := socks(t, addr, 1, tcp)
	if _, err := roundTrip(t, c); err == nil {
		t.Fatal("a refused login carried data")
	}
}

func TestUDP(t *testing.T) {
	_, udp := echo(t)
	f := &fake{socks: true, user: "u", pass: "p4ss"}
	addr, p := serveWarm(t, f.start(t), 2)
	ask := func() {
		t.Helper()
		ctrl, r := socks(t, addr, 3, &net.TCPAddr{IP: net.IPv4zero})
		if r[1] != 0 || r[3] != 1 {
			t.Fatalf("reply %v", r)
		}
		relay := &net.UDPAddr{IP: net.IP(r[4:8]), Port: int(binary.BigEndian.Uint16(r[8:10]))}
		u, err := net.ListenUDP("udp", &net.UDPAddr{IP: net.IPv4(127, 0, 0, 1)})
		if err != nil {
			t.Fatal(err)
		}
		defer u.Close()
		dgram := append([]byte{0, 0, 0, 1}, udp.IP.To4()...)
		dgram = binary.BigEndian.AppendUint16(dgram, uint16(udp.Port))
		dgram = append(dgram, "hello"...)
		u.SetDeadline(time.Now().Add(5 * time.Second))
		u.WriteToUDP(dgram, relay)
		b := make([]byte, 1500)
		n, _, err := u.ReadFromUDP(b)
		if err != nil {
			t.Fatal(err)
		}
		if !bytes.Equal(b[:n], dgram) {
			t.Fatalf("got %v, want %v back", b[:n], dgram)
		}
		ctrl.Close()
	}
	ask()
	// The first association made UDP wanted: associations are now kept ready.
	waitFor(t, "an association ready", func() bool { return len(p.udp) == cap(p.udp) })
	ask()
}

func TestHTTPCarriesNoUDP(t *testing.T) {
	f := &fake{user: "u", pass: "p4ss"}
	addr, _ := serveWarm(t, f.start(t), 1)
	if _, r := socks(t, addr, 3, &net.TCPAddr{IP: net.IPv4zero}); r[1] != 7 {
		t.Fatalf("reply %v, want command not supported (7)", r)
	}
}

func TestRequestRefusesInjection(t *testing.T) {
	a, b := net.Pipe()
	defer a.Close()
	go func() {
		a.Write([]byte{5, 1, 0})
		io.ReadFull(a, make([]byte, 2))
		name := "x.example\r\nX: y"
		req := append([]byte{5, 1, 0, 3, byte(len(name))}, name...)
		a.Write(append(req, 0, 80))
		io.Copy(io.Discard, a)
	}()
	if _, _, err := readRequest(b); err == nil {
		t.Fatal("a name with a CR LF passed")
	}
	b.Close()
}

func TestHostPort(t *testing.T) {
	for dst, want := range map[string]string{
		"\x01\x7f\x00\x00\x01\x01\xbb":                 "127.0.0.1:443",
		"\x03\x09x.example\x00\x50":                    "x.example:80",
		"\x04" + string(net.IPv6loopback) + "\x00\x35": "[::1]:53",
	} {
		if got := hostPort([]byte(dst)); got != want {
			t.Errorf("got %s, want %s", got, want)
		}
	}
}
