# proxy-warm

A SOCKS5 front for upstream proxies. It keeps connections to each one open,
and logged in, ahead of use, so a new connection's data leaves at once, not
four round trips to the proxy later. uid 65532 on distroless, one static Go binary,
`/usr/local/bin/proxy-warm`, which is the entrypoint. There is no shell.

| | |
|---|---|
| Image | `ghcr.io/morzecrew/proxy-warm:0.1.0` |
| Tag | This repository's version of the program, moved by hand |
| User | `65532:65532` (`nonroot`), never root |
| Base | `gcr.io/distroless/static-debian13:nonroot` |
| Config | the upstreams file `PROXY_WARM_UPSTREAMS` names, mounted read-only |
| Writes | nothing |
| Logs | stderr: the startup summary, and each line's failures to keep its connections ready. Never a login, never a destination. |

Admitted on neither route of the [admission rule](../README.md#which-images-belong-here):
one project uses it. See "Admissions on record" there and
[#180](https://github.com/morzecrew/platform-images/issues/180).

## Why

Through a SOCKS5 proxy that asks for a login, a new connection costs a client
such as Xray four round trips to the proxy before its first byte of data
leaves: TCP, the greeting, the login and the CONNECT, each waiting for the one
before. Through an HTTP proxy, two: TCP and the CONNECT. With the proxy 34 ms
away, that is 136 ms or 68 ms before a site's first byte, on every connection.

proxy-warm answers its client at once, on the container network, and sends
the CONNECT and the client's first bytes together on a connection it opened
and logged in beforehand:

| A new connection | Round trips to the proxy before data |
|---|---|
| Xray straight to a SOCKS5 proxy with a login | 4, then the data's own |
| Xray straight to an HTTP proxy | 2, then the data's own |
| through proxy-warm, a spare ready | 0, the CONNECT going with the data |
| through proxy-warm, no spare left | 1: TCP, then greeting, login, CONNECT and data in one go |

Measured from a server 34 ms from its proxy, fetching a 204 through it: 203 ms
to the first byte step by step, 87 ms with no spare, 51 ms on a spare.

## Usage

```yaml
services:
  warm:
    image: ghcr.io/morzecrew/proxy-warm:0.1.0
    read_only: true
    cap_drop: [ALL]
    security_opt: ["no-new-privileges:true"]
    environment:
      PROXY_WARM_UPSTREAMS: /run/secrets/upstreams
    secrets: [upstreams]
    healthcheck:
      test: ["CMD", "/usr/local/bin/proxy-warm", "healthcheck"]
      interval: 30s
      timeout: 5s

  gate:
    image: ghcr.io/morzecrew/xray:26.11.9
    environment:
      XRAY_UPSTREAM_ALIASES: warm=socks5://warm:1080
    secrets: [upstreams]
    # ... {"outbounds": {"$upstreams": "/run/secrets/upstreams"}}

secrets:
  upstreams: { file: ./secrets/upstreams }
```

The file is the [xray image's upstreams list](../xray/README.md#any-number-of-upstreams-from-one-list).
A proxy line tagged `warm=<n>` is served here, with `n` connections, 1 to 16,
kept ready:

```text
name=isp warm=4 | socks5://alice:secret@proxy.example:1080
name=isp2       | http://bob:secret@proxy2.example:8080
```

The k-th `warm=` line, counting from 0 in the file's order, is served on
`PROXY_WARM_PORT` plus k. The xray image dials the same line at the alias
`warm` names, its port plus k, with no login: proxy-warm holds it. Lines
without the tag are the xray image's alone and are not read here, beyond
finding the tag.

## Settings

| Variable | Default | Meaning |
|---|---|---|
| `PROXY_WARM_UPSTREAMS` | unset, required | The upstreams file: a secret, readable by uid 65532. |
| `PROXY_WARM_PORT` | `1080` | The first line's port; each later `warm=` line takes the next. |
| `PROXY_WARM_MAX_IDLE` | `90s` | How long a connection waits ready before it is replaced. 5s or more. |

An unknown `PROXY_WARM_*` name warns. There is no passthrough channel: the
program has nothing else to set.

## How it behaves

- **Spares.** Each line keeps `warm=` connections open: dialled, through TLS
  for `socks5+tls://` and `https://`, and for SOCKS5 greeted and logged in, the
  greeting and the login sent in one write. One taken is replaced at once.
  They are checked every `PROXY_WARM_MAX_IDLE`/6 and when taken: one older
  than `PROXY_WARM_MAX_IDLE`, or closed by the proxy, is never used. While
  they cannot be opened, the log says why, once per try, backing off from 1 s
  to 30 s.
- **The answer comes first.** A client's CONNECT is answered yes at once, so
  Xray sends what it holds without waiting. If the proxy then refuses, the
  connection closes, as a refused site's would.
- **Data before the reply.** The CONNECT leaves at once, and what the client
  sends within 20 ms goes right after it, before the proxy has replied. A
  proxy that drops bytes sent before its reply breaks every connection
  through this image: send it a CONNECT and a request in one write, and see
  whether the answer comes back, before tagging its line.
- **A dead spare.** One the proxy or a NAT on the way dropped without a word
  answers nothing. Everything sent on it goes again on a new connection, once.
- **Closing.** Xray closes a connection whole, never half, so the end of
  what the client sends ends the connection. The proxy's end is passed on as
  a half close.
- **UDP.** A UDP ASSOCIATE through a SOCKS5 line is answered once the proxy's
  association is ready, with a port of this container's, on the address the
  client reached it at. Datagrams pass through unchanged, and only from the
  client's own address. The first association makes the line keep about half
  as many associations ready as connections, each replaced after a third of
  `PROXY_WARM_MAX_IDLE`, since a relay may forget a mapping that has carried
  nothing. An HTTP line refuses UDP (reply 7).
- **The client side** takes SOCKS5 without a login, CONNECT and UDP
  ASSOCIATE. Anything that reaches the port can use the line, so publish it
  nowhere: put it on a network only its client shares.

The healthcheck passes while each line's port answers a SOCKS5 greeting.
Whether a line carries traffic is its client's to judge.

## Refusals

Each exits 78, naming the file and the line, never the URL:

- `PROXY_WARM_UPSTREAMS` unset, or a file the
  [shared checks](../README.md#environment-configuration) refuse: missing,
  unreadable, a directory, larger than 64 KiB, not UTF-8.
- No line tagged `warm=`.
- `warm=` outside 1 to 16, or twice on a line; on a line that is not
  `socks5://`, `socks://`, `socks5+tls://`, `http://` or `https://`.
- A login that is not a user and a password, both non-empty; a SOCKS5 user or
  password over 255 bytes; no host and port.
- `PROXY_WARM_PORT` that is not a port, or leaves no port for a later line;
  `PROXY_WARM_MAX_IDLE` that is not a duration of 5s or more.

The xray image refuses its own way what it reads of the same lines: see its
README.
