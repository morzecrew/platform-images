#!/usr/bin/env python3
"""SOCKS5 for smoke.sh, standard library only, no auth.

  smoke-socks.py server <port> udp|noudp
      A proxy on 127.0.0.1:<port> that serves CONNECT, and UDP ASSOCIATE
      unless noudp, printing "tcp <host> <port>" or "udp <host> <port>" for
      each destination asked for. noudp refuses UDP ASSOCIATE (reply 7), as a
      TCP-only proxy does.
  smoke-socks.py udp <socks port> <host> <port>
      Sends "ping" to <host>:<port> through the SOCKS5 proxy on
      127.0.0.1:<socks port> and prints the reply, or exits 1 with no reply.
"""
import socket
import struct
import sys
import threading


def recvn(s, n):
    b = b""
    while len(b) < n:
        c = s.recv(n - len(b))
        if not c:
            raise EOFError
        b += c
    return b


def parse_addr(b, i):
    """The ATYP, address and port at b[i:]: (host, port, index after them)."""
    t = b[i]
    if t == 1:
        h, j = socket.inet_ntop(socket.AF_INET, b[i + 1:i + 5]), i + 5
    elif t == 4:
        h, j = socket.inet_ntop(socket.AF_INET6, b[i + 1:i + 17]), i + 17
    elif t == 3:
        n = b[i + 1]
        h, j = b[i + 2:i + 2 + n].decode(), i + 2 + n
    else:
        raise ValueError("ATYP %d" % t)
    return h, struct.unpack(">H", b[j:j + 2])[0], j + 2


def ipv4(host, port):
    return b"\x01" + socket.inet_aton(host) + struct.pack(">H", port)


def pipe(a, b):
    def copy(src, dst):
        try:
            while True:
                d = src.recv(65536)
                if not d:
                    break
                dst.sendall(d)
        except OSError:
            pass
        for s in (src, dst):
            try:
                s.shutdown(socket.SHUT_RDWR)
            except OSError:
                pass

    t = threading.Thread(target=copy, args=(b, a), daemon=True)
    t.start()
    copy(a, b)
    t.join()


def relay(ctrl, r):
    # The association lives as long as its TCP connection.
    threading.Thread(target=lambda: (ctrl.recv(1), r.close()), daemon=True).start()
    client = None
    while True:
        try:
            d, src = r.recvfrom(65535)
        except OSError:
            return
        if client is None or src == client:
            client = src
            host, port, j = parse_addr(d, 3)
            print("udp", host, port, flush=True)
            r.sendto(d[j:], (host, port))
        else:
            r.sendto(b"\x00\x00\x00" + ipv4(*src) + d, client)


def handle(c, udp):
    try:
        n = recvn(c, 2)[1]
        recvn(c, n)
        c.sendall(b"\x05\x00")
        _, cmd, _, t = recvn(c, 4)
        if t == 1:
            a = recvn(c, 4)
        elif t == 4:
            a = recvn(c, 16)
        else:
            a = recvn(c, 1)
            a += recvn(c, a[0])
        host, port, _ = parse_addr(bytes([t]) + a + recvn(c, 2), 0)
        if cmd == 1:
            print("tcp", host, port, flush=True)
            u = socket.create_connection((host, port), 5)
            c.sendall(b"\x05\x00\x00" + ipv4("0.0.0.0", 0))
            pipe(c, u)
        elif cmd == 3 and udp:
            r = socket.socket(socket.AF_INET, socket.SOCK_DGRAM)
            r.bind(("127.0.0.1", 0))
            c.sendall(b"\x05\x00\x00" + ipv4("127.0.0.1", r.getsockname()[1]))
            relay(c, r)
        else:
            c.sendall(b"\x05\x07\x00" + ipv4("0.0.0.0", 0))
    except (OSError, EOFError, ValueError):
        pass
    finally:
        c.close()


def server(port, udp):
    ls = socket.socket()
    ls.setsockopt(socket.SOL_SOCKET, socket.SO_REUSEADDR, 1)
    ls.bind(("127.0.0.1", port))
    ls.listen(16)
    print("listening", port, flush=True)
    while True:
        c, _ = ls.accept()
        threading.Thread(target=handle, args=(c, udp), daemon=True).start()


def udp_ping(socks_port, host, port):
    c = socket.create_connection(("127.0.0.1", socks_port), 5)
    c.settimeout(5)
    c.sendall(b"\x05\x01\x00")
    recvn(c, 2)
    c.sendall(b"\x05\x03\x00" + ipv4("0.0.0.0", 0))
    rep = recvn(c, 4)
    if rep[1] != 0:
        print("UDP ASSOCIATE refused: %d" % rep[1])
        return 1
    rhost, rport, _ = parse_addr(rep[3:4] + recvn(c, 6), 0)
    if rhost == "0.0.0.0":
        rhost = "127.0.0.1"
    u = socket.socket(socket.AF_INET, socket.SOCK_DGRAM)
    u.settimeout(5)
    u.sendto(b"\x00\x00\x00" + ipv4(host, port) + b"ping", (rhost, rport))
    try:
        d, _ = u.recvfrom(65535)
    except socket.timeout:
        print("no reply")
        return 1
    print("reply", d[parse_addr(d, 3)[2]:].decode())
    return 0


if __name__ == "__main__":
    if sys.argv[1] == "server":
        server(int(sys.argv[2]), sys.argv[3] == "udp")
    else:
        sys.exit(udp_ping(int(sys.argv[2]), sys.argv[3], int(sys.argv[4])))
