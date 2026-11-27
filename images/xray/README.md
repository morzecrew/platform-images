# xray

[Xray-core](https://github.com/XTLS/Xray-core) for a Compose bundle: uid 65532
on distroless, a read-only root, secrets read from files that its JSON config
references, and a healthcheck that sends a request out through Xray itself.

The binary and the geodata are upstream's, copied unchanged out of
`ghcr.io/xtls/xray-core` pinned by digest; [`XRAY_GEOIP` and
`XRAY_GEOSITE`](#geodata-from-a-url) fetch other geodata at run time. The image adds one static Go binary,
`/usr/local/bin/xray-entrypoint`, which is the entrypoint. There is no shell.

| | |
|---|---|
| Image | `ghcr.io/morzecrew/xray:26.10.31` |
| Tag | Upstream's version, stable releases only |
| User | `65532:65532` (`nonroot`), never root |
| Base | `gcr.io/distroless/static-debian13:nonroot` |
| Config | every `*.json` in `XRAY_SOURCE_DIR` (`/etc/xray`), mounted read-only |
| Writes | only to `XRAY_RUNTIME_DIR` (`/run/xray`) |
| Logs | Xray's console log, which `docker logs` shows. No log file. |

Admitted on neither route of the [admission rule](../README.md#which-images-belong-here):
one project uses it. See "Admissions on record" there and
[#125](https://github.com/morzecrew/platform-images/issues/125).

## Usage

```yaml
services:
  xray:
    image: ghcr.io/morzecrew/xray:26.10.31
    read_only: true
    tmpfs:
      - /run/xray:uid=65532,gid=65532,mode=0700
    cap_drop: [ALL]
    security_opt: ["no-new-privileges:true"]
    ports:
      - "443:8443"            # inbounds listen on 1024 or above
    volumes:
      - ./xray:/etc/xray:ro   # the config, as *.json
    secrets: [vless_uuid, vless_seed, xhttp_path]
    environment:
      XRAY_HEALTHCHECK_PROXY: http://127.0.0.1:10809
    healthcheck:
      test: ["CMD", "/usr/local/bin/xray-entrypoint", "healthcheck"]
      interval: 60s
      timeout: 15s

secrets:
  vless_uuid: { file: ./secrets/vless_uuid }
  vless_seed: { file: ./secrets/vless_seed }
  xhttp_path: { file: ./secrets/xhttp_path }
```

- **Ports.** Xray runs as uid 65532 with no capabilities, so an inbound
  cannot listen below 1024. Listen on 8443 or 5353 and publish 443 or 53.
- **The tmpfs** must be writable by 65532. Docker mounts a bare `--tmpfs`
  owned by root, which the entrypoint refuses. Without `read_only` the image's
  own `/run/xray` is used and the tmpfs can be left out. Podman's
  `--read-only` already mounts a writable tmpfs on `/run`.
- **Secret files** must be readable by uid 65532: owned by it, or group- or
  world-readable. Unlike `pgbouncer` and `rustfs`, this image never starts as
  root, so it cannot read a file only root may read.

## The config, and file references

Xray reads no value from a file and expands no variable, so a secret can reach
it only inside its JSON config. Before Xray starts, the entrypoint reads every
file in `XRAY_SOURCE_DIR` and replaces each JSON object that is **exactly** one
of these. Everything else in the config stays as written.

| Object | Replaced with |
|---|---|
| `{"$file": "/abs/path"}` | the file's content as a JSON string, minus one trailing newline |
| `{"$vlessDecryption": "/abs/path"}` | the VLESS Encryption server key derived from the seed in the file (see below) |
| `{"$vlessClients": "/abs/path"}` | a VLESS inbound's `clients` array, one client per line of the file (see below) |
| `{"$vlessClients": {"devices": …, "relays": …, "seed": …}}` | the same, and one client per dotdash relay, its id derived from the seed (see below) |
| `{"$hysteriaUsers": "/abs/path"}` | a Hysteria2 inbound's `users` array, from the same file (see below) |
| `{"$proxy": "/abs/path"}` | a socks or http outbound's `settings`, split from the `[user:pass@]host:port` in the file (see below) |
| `{"$wireguard": "/abs/path"}` | a wireguard outbound's `settings`, from the wg-quick client config in the file (see below) |
| `{"$upstreams": "/abs/path"}` | an `outbounds` array, one socks, http or wireguard outbound per line of the file (see below) |
| `{"$subscription": "/abs/path"}` | the `outbounds` array of the Xray config the URL in the file serves, kept current (see below) |
| `{"$gateway": {"servers": "/abs/path", …}}` | a whole config: a dotdash relay's inbounds, outbounds, routing and observatory to its server groups (see below) |
| `{"$gatewayClients": "vless"}`, `"hysteria"` | a device inbound's `clients` or `users`: the gateway's devices (see below) |

```json
"settings": {
  "clients": [{"id": {"$file": "/run/secrets/vless_uuid"}}],
  "decryption": {"$vlessDecryption": "/run/secrets/vless_seed"}
},
"streamSettings": {
  "network": "xhttp",
  "xhttpSettings": {"path": {"$file": "/run/secrets/xhttp_path"}}
}
```

The input is valid JSON before and after, and a reference replaces one whole
value. There is no environment expansion, no expression and no substitution
inside a string, which is why this is not the templating the
[environment contract](../README.md#no-templating) rules out.

The resolved files are written to `XRAY_RUNTIME_DIR` under the same names, at
mode 0600 in a 0700 directory. The directory is emptied on every start, so a
source file removed since the last start is not merged in again. The source
directory is never written. The entrypoint then runs `xray run -test` on the
result and execs `xray run -confdir $XRAY_RUNTIME_DIR` as PID 1, or, when a
config holds a [`$subscription`](#a-subscriptions-outbounds), runs it as its
child and keeps the subscription current.

### Refusals

Each of these exits **78** before Xray starts. The message names the JSON
file, the JSON path and the referenced path, never a value.

- A referenced file that is missing, unreadable by uid 65532, not a regular
  file (a directory counts: Compose leaves one where a secret's source file is
  missing), over 64 KiB, not UTF-8, or holding a NUL byte. These are the
  checks the shared `_FILE` contract makes.
- An object holding `$file`, `$vlessDecryption`, `$vlessClients`,
  `$hysteriaUsers`, `$proxy`, `$wireguard` or `$upstreams` and any other key, or a path that is not an absolute path in a string
  (`$vlessClients` also takes [an object](#a-servers-relays), and `$gateway`
  and `$gatewayClients` take [no path](#a-dotdash-relays-gateway), with their
  own checks). A near miss would otherwise reach Xray as a literal.
- A seed file that is not exactly 128 hex characters.
- A client list with a line it refuses (see below).
- A proxy file that is not one `[user:pass@]host:port` (see below).
- Any file in `XRAY_SOURCE_DIR` that is not a `.json` file, such as `.yaml`,
  `.toml` or `.jsonc`. Xray's `-confdir` would read those too, and nothing
  would have resolved them.
- A source file that is not valid JSON. **Comments are refused.** Xray's own
  loader accepts them, but this resolver does not.
- No `.json` file at all, or a source directory that cannot be read.
- A runtime directory uid 65532 cannot write, or one that overlaps the source
  directory once symlinks are resolved. Emptying it would delete the config or
  overwrite it with the resolved secrets.
- A config that `xray run -test` rejects. Xray's message is printed with every
  resolved value replaced by `<redacted>`, because Xray quotes the value it
  rejects (`invalid UUID: <the id>`).

## One VLESS client per device

`{"$vlessClients": "/run/secrets/vless_clients"}` resolves to a `clients`
array, so each device has its own id and one is revoked by deleting its line.
The file is UTF-8 text, one client per line:

```text
# <uuid> [name [desktop|mobile]]
3f2c1f0e-8a4b-4c1d-9e2f-0a1b2c3d4e5f
6b1d2c3e-4f5a-4b6c-8d7e-9f0a1b2c3d4e phone
9a8b7c6d-5e4f-4a3b-8c2d-1e0f9a8b7c6d laptop desktop
```

```json
[{"id": "3f2c1f0e-8a4b-4c1d-9e2f-0a1b2c3d4e5f"}, {"id": "6b1d2c3e-4f5a-4b6c-8d7e-9f0a1b2c3d4e", "email": "phone"},
 {"id": "9a8b7c6d-5e4f-4a3b-8c2d-1e0f9a8b7c6d", "email": "laptop"}]
```

- The id and the optional name are separated by spaces or tabs. Whitespace
  around them, blank lines and lines starting with `#` are ignored.
- The id is lower-cased. The name becomes `email`, which Xray shows as the
  user's label in its logs and stats.
- A named line may end in the device's kind, `desktop` or `mobile`. Xray
  never sees it; the tools that make devices' links from the same file read
  it. Any other word there is refused, so a name with a space in it still is.
- A single bare UUID, as morzer's `uuid` generator writes one, is a list of one.
- The clients carry no `flow`. Set the inbound's `settings.flow`, which Xray
  gives every client without its own, so one file serves a REALITY + Vision
  inbound and an XHTTP one:

```json
"settings": {
  "clients": {"$vlessClients": "/run/secrets/vless_clients"},
  "flow": "xtls-rprx-vision",
  "decryption": "none"
}
```

`{"$hysteriaUsers": "/run/secrets/vless_clients"}` reads the same file, with
the same checks, as a Hysteria2 inbound's `users`: each device's UUID is its
`auth`, its name its `email`. One file then adds and revokes a device on
every inbound, VLESS and Hysteria2 alike, and a device's Hysteria2 link
carries the UUID its VLESS links do:

```json
"settings": {"version": 2, "users": {"$hysteriaUsers": "/run/secrets/vless_clients"}}
```

```json
[{"auth": "3f2c1f0e-8a4b-4c1d-9e2f-0a1b2c3d4e5f"}, {"auth": "6b1d2c3e-4f5a-4b6c-8d7e-9f0a1b2c3d4e", "email": "phone"}]
```

Each of these exits 78. The message names the line, never an id:

- An id that is not a UUID written as 8-4-4-4-12 hex digits. Xray itself maps
  any other string of 1 to 30 bytes to a UUIDv5, so a typo would become a
  different id that looks valid and locks its device out.
- A name that is not 1 to 64 of `A-Z a-z 0-9 . _ @ + -`.
- A line with more than two fields.
- An id or a name that appears twice, ignoring case. Xray compares emails
  ignoring case and refuses the second.
- Two ids that differ only in bytes 6 and 7, their third group. Xray zeroes
  those bytes before it looks an id up (and hands them to routing as
  `vlessRoute`), keeping the client listed last, so both devices would be
  logged and routed as that one. The message names both lines, with their
  names, any UUID in a name shown as `<uuid>`.
- No client at all once comments and blank lines are skipped.

The summary shows the count, not the ids, and the ids are redacted from
`xray run -test` output like every other resolved value.

### A server's relays

A dotdash server lets its relays in by ids it works out itself, so nobody
types a relay's id into `vless_clients`. `$vlessClients` takes an object for
that, in place of the path:

```json
"clients": {"$vlessClients": {"devices": "/run/secrets/vless_clients", "relays": "/run/secrets/relays", "seed": "/run/secrets/relay_seed"}}
```

It resolves to the clients `devices` lists, as the path form does, then one
client per `relay/1` line in `relays`: its id is the relay's id on this
server, its email `relay-<name>`. `relays` may also be the lines themselves,
an array of strings, as a template writes them out of a parameter (only the
`relay/1` ones, as a template can pick them by their first word):

```json
"relays": ["relay/1 r1 0123456789abcdef r1.example.net r1.example.net <pbk> <sid> <enc> xhttp=<path>"]
```

- **A relay/1 line** is what a relay's `relay-entry` prints:
  `relay/1 <name> <nonce> <host> <site> <pbk> <sid> <enc>`, then optional
  `key=value` fields in any order. Blank lines and `#` comments are skipped.
  The name is 1 to 24 of `A-Z a-z 0-9 . _ -`, unique ignoring case; the nonce
  16 lowercase hex characters; the host a DNS name, an IPv4 or an IPv6
  address; the site a DNS name, not an address; the public key 43 base64url characters; the
  short id 1 to 16 lowercase hex characters; the encryption `none` or
  `mlkem768x25519plus.<…>`; `xhttp=` 1 to 128 of `A-Z a-z 0-9 . _ ~ -`.
  `kcp=`, `hy2=`, `cdn=`, `cdnpath=`, `origin=` and `cdn-only` are the
  server's links' business and pass unread. A `key=` it doesn't know is left
  out with a warning naming the line, so a new optional field needs no new
  version.
- **The id** is the version 4 UUID made of the first 16 bytes of
  `sha256("<seed>:relay:<name>:<nonce>")`: byte 6 is `(b & 0x0f) | 0x40`,
  byte 8 `(b & 0x3f) | 0x80`. The seed is the server group's own, so a
  relay's ids on two groups are unrelated; the nonce is the relay's own, made
  once at its install, so a new relay that takes a removed one's name gets
  another id. Deleting a line revokes that relay; a new seed revokes them all.
  [`relay-id`](#a-relays-id) prints one, and
  [`testdata/relay-id.json`](entrypoint/testdata/relay-id.json) holds the
  vectors every implementation is tested against.
- With no `relay/1` line, the seed is not read.
- The summary names the files and counts the clients, relays included.

Each of these exits 78. The message names the file and the line, never what
is on the line, which is as sensitive as a device's link:

- A line whose first field is not `relay/1`: today's relay lines, which have
  no tag, a `server/1` line, or a version this image doesn't read.
- A head of fewer than 8 fields, or a field outside its shape above.
- Two lines with one name, ignoring case.
- A seed file that is not 64 lowercase hex characters, the form morzer's
  `hex` generator writes: the hash takes the text, so another case would make
  other ids.
- A relay's client name, `relay-<name>`, that a client in `devices` has,
  ignoring case, such as the line a relay had there before: rename that one,
  or drop it once the relay has its `relay/1` line.
- A derived id that differs from a client's only in bytes 6 and 7: give the
  relay another nonce.
- An object with a key other than `devices`, `relays` and `seed`, a
  `devices` or `seed` that is not an absolute path, or a `relays` that is
  neither an absolute path nor an array of one-line strings.

## An upstream proxy from one secret

`{"$proxy": "/run/secrets/upstream"}` resolves to the whole `settings` of a
`socks` or `http` outbound, so an upstream proxy is one secret file and
changing provider is one edit and one restart. The file holds one line:

```text
alice:s3cret@proxy.example:1080
```

```json
{"tag": "upstream", "protocol": "socks", "settings": {"$proxy": "/run/secrets/upstream"}}
```

```json
{"tag": "upstream", "protocol": "socks", "settings": {"address": "proxy.example", "port": 1080, "user": "alice", "pass": "s3cret"}}
```

Xray's flat form takes the same four keys for `socks` and `http`, so one file
serves either protocol.

- The line is `[user:pass@]host:port`. Without `user:pass@`, the object has
  only `address` and `port`.
- The user and password end at the **last** `@`, and the user at the first `:`
  before it, so a password may hold `:` and `@` as written:
  `alice:p@ss:w0rd@proxy.example:1080` is user `alice`, password `p@ss:w0rd`.
  A user cannot hold `:`.
- Nothing is percent-decoded. `%40` stays `%40`.
- The host is a DNS name, an IPv4 address, or an IPv6 address in brackets,
  `[2001:db8::1]:1080`. The brackets are not part of `address`. A name's
  labels are 1 to 63 bytes, and the name at most 253, as DNS takes them.
- The port is decimal, 1 to 65535, and becomes a JSON number.
- The summary shows `host:port`, which is not secret, so the log says where
  the outbound dials; for a line without credentials it shows `no
  credentials` instead, since `user:pass` that lost its `@host:port` reads as
  a host and a port, and the port would be the password. The user and
  password are redacted from `xray run -test` output like every other
  resolved value.

Each of these exits 78. The message names the file and what is wrong, never
the value or any part of it:

- A scheme, such as `socks5://` or `http://`. Write `user:pass@host:port`
  without it.
- Whitespace anywhere, a second line or a CRLF included.
- An `@` without both a user and a password before it.
- An empty host, an IPv6 address without brackets, brackets around anything
  else, or a host that is not a DNS name or an IPv4 address.
- No `@` and a host with no dot, such as `alice:1234`: most likely a user and
  a password that lost their `@host:port`, whose password would otherwise
  become a port that nothing redacts. A proxy that asks for no login is
  written with a dotted name or an address.
- A missing port, or one that is not a number from 1 to 65535.

## A WireGuard upstream from one secret

`{"$wireguard": "/run/secrets/upstream"}` resolves to the whole `settings` of a
`wireguard` outbound, from the wg-quick client config a VPN provider or a
router exports, so a WireGuard upstream is one secret file as a proxy is:

```ini
[Interface]
PrivateKey = <base64>
Address = 10.34.0.3/32, fd30:2::3/128
DNS = 1.1.1.1

[Peer]
PublicKey = <base64>
Endpoint = vpn.example:51820
AllowedIPs = 0.0.0.0/0, ::/0
PersistentKeepalive = 25
```

```json
{"tag": "upstream", "protocol": "wireguard", "settings": {"$wireguard": "/run/secrets/upstream"}}
```

```json
{"tag": "upstream", "protocol": "wireguard", "settings": {"secretKey": "<base64>", "address": ["10.34.0.3/32", "fd30:2::3/128"], "peers": [{"publicKey": "<base64>", "endpoint": "vpn.example:51820", "allowedIPs": ["0.0.0.0/0", "::/0"], "keepAlive": 25}], "mtu": 1420, "noKernelTun": true}}
```

- `noKernelTun` is always set: Xray runs WireGuard on its own TCP/IP stack,
  which needs no capability, so the container keeps `cap_drop: ALL` and a
  read-only root.
- `[Interface]` takes `PrivateKey` and `Address` (both required) and `MTU`
  (1280 to 65535; 1420, wg-quick's default, when absent). `[Peer]`, one or
  more, takes `PublicKey`, `Endpoint` and `AllowedIPs` (all required: an
  outbound dials out), `PresharedKey` and `PersistentKeepalive` (seconds, or
  `off`).
- `DNS`, `ListenPort`, `Table`, `FwMark`, `SaveConfig` and the `PreUp`,
  `PostUp`, `PreDown` and `PostDown` scripts are accepted and left out: only
  wg-quick acts on them, and this container has no resolver, routes or
  scripts of the host's to change.
- Keys are matched ignoring case, as wg(8) matches them. `Address` and
  `AllowedIPs` may repeat, adding to the list, and take a bare address as a
  single host (`/32`, `/128`). `AllowedIPs` networks lose their host bits as
  wg(8) clears them; an `Address` keeps its own.
- The endpoint is a DNS name, an IPv4 address, or an IPv6 address in brackets,
  with a port from 1 to 65535. A name may end in the root's dot,
  `vpn.example.:51820`, and is passed on as written. Xray resolves a name
  itself, outside the tunnel.
- Xray's userspace stack does not carry a loopback destination through the
  tunnel. A peer's `AllowedIPs` decides what the outbound sends at all.
- The summary shows the peers' endpoints, which are not secret. The private
  key and any preshared key are redacted from `xray run -test` output like
  every other resolved value.

Each of these exits 78. The message names the file, the line and the key, and
never a value: a key's base64 is the secret itself.

- No `[Interface]`, a second one, or no `[Peer]`.
- A section other than `[Interface]` and `[Peer]`, or a key before any.
- A key wg-quick does not know in its section, such as a typo; an
  `[Interface]` key in a `[Peer]`.
- A key other than `Address` and `AllowedIPs` twice in one section.
- A missing required key, or an empty value.
- A key that is not 32 bytes of standard base64; an address or network that
  does not parse, or carries a zone; an endpoint that is not `host:port`; an
  MTU outside 1280 to 65535; a keepalive that is neither `off` nor a number.

## Any number of upstreams from one list

`{"$upstreams": "/run/secrets/upstreams"}` resolves to an `outbounds` array,
one outbound per line of the file, so every way out, whatever its kind and
however many, is one secret in order of preference:

```text
# [name=<name>] [group=<group>[,<group>]] [warm=<n>] | <url>
name=isp-a                     | socks5://alice:secret@proxy.example:1080
name=isp-b                     | https://bob:secret@203.0.113.9:8443
name=home group=upstream,ipv6  | wireguard://<private key>@vpn.example:51820?publickey=<base64>&address=10.34.0.3/32,fd30:2::3/128
name=vpn                       | openvpn://H4sIAAAAAAAAA…
name=isp-c6 group=ipv6         | socks5://carol:secret@[2001:db8::9]:1080
socks5://dave:secret@proxy2.example:1080
```

A line with no tags is its URL alone. Tags first keep each line's name in
view however long its URL runs; the older form, the URL first and its tags
after it, is still read.

It stands for an array, so it goes where an array goes. Put it in a file of its
own: Xray's `-confdir` puts a later file's outbounds before the earlier ones'
(unless its name holds `tail`) and keeps the earlier file's routing, so a
static config routes to tags it never spells out:

```json
{"outbounds": {"$upstreams": "/run/secrets/upstreams"}}
```

```json
{"outbounds": [
  {"tag": "upstream-0", "protocol": "http", "settings": {"address": "203.0.113.9", "port": 8443, "user": "bob", "pass": "secret"}, "streamSettings": {"security": "tls"}},
  {"tag": "upstream-b1", "protocol": "socks", "settings": {"address": "proxy.example", "port": 1080, "user": "alice", "pass": "secret"}},
  {"tag": "upstream-b2", "protocol": "wireguard", "settings": {"secretKey": "<base64>", "address": ["10.34.0.3/32", "fd30:2::3/128"], "peers": [{"publicKey": "<base64>", "endpoint": "vpn.example:51820", "allowedIPs": ["0.0.0.0/0", "::/0"]}], "mtu": 1420, "noKernelTun": true}},
  ...
]}
```

(That is with `XRAY_UPSTREAM_PIN=isp-b`, which put `isp-b` first.)

| A line's URL | Outbound |
|---|---|
| `socks5://[user:pass@]host:port`, or `socks://` | `socks` |
| `socks5+tls://[user:pass@]host:port` | `socks` over TLS |
| `http://[user:pass@]host:port` | `http` |
| `https://[user:pass@]host:port` | `http` over TLS |
| `wireguard://<private key>@host:port?<query>` | `wireguard`, as from a wg-quick file |
| `direct`, alone | `freedom`: this machine's own address, for a machine already on the network the traffic is to leave from, such as a home line. It takes `name=` and `group=`, not `warm=` |
| a word, such as `openvpn`, alone or as the scheme of `openvpn://<anything>` | the URL `XRAY_UPSTREAM_ALIASES` gives it, its port moved up one for each earlier line naming the word |

- **Tags.** A line's group is `upstream` unless `group=` names others, and a line
  in two groups becomes two outbounds. In each group the first line is tagged
  `<group>-0` and each later one `<group>-b<n>`, so a balancer's selector takes
  the first (`upstream-0`), the rest (`upstream-b`) or all (`upstream-`), with
  no prefix catching another line.
- **Order and pins.** Lines keep the file's order. `XRAY_UPSTREAM_PIN`, names
  separated by commas, moves each named line to the front of its groups,
  one per group, so the first can change with no edit to the secret.
- **Proxies.** After the scheme, a proxy is the same `[user:pass@]host:port`
  as [`$proxy`](#an-upstream-proxy-from-one-secret) takes, with the same
  checks: the userinfo ends at the last `@`, nothing is percent-decoded, and
  TLS takes the server name from the address.
- **WireGuard.** The share link's form: the private key before the `@`,
  percent-encoded or not, the peer's endpoint after it, and in the query
  `publickey` and `address` (both required), `mtu`, `presharedkey`,
  `keepalive` and `allowedips` (`0.0.0.0/0, ::/0` unless given). A `#name`
  an app adds is dropped. The line becomes the wg-quick file it stands for and
  passes [`$wireguard`](#a-wireguard-upstream-from-one-secret)'s checks.
- **Aliases.** `XRAY_UPSTREAM_ALIASES`, `<word>=<url>` pairs separated by spaces,
  names hops the deployment defines, such as the SOCKS port of a tunnel
  beside the container (`openvpn=socks5://vpn:1080`). A host there may lack a
  dot, as a service name does. An alias holds no login, because the
  environment is shown at start and by `docker inspect`. A line names the
  word alone, or as its scheme, with what follows for the hop to read, such
  as a tunnel's config, which this image never reads or shows. The k-th line
  naming a word, counting from 0 in the file's order, dials the alias's port
  plus k, so each tunnel of a sidecar such as the
  [openvpn image](../openvpn/README.md#several-tunnels-from-an-upstreams-list)
  has a port of its own. Pins change the outbounds' order, not the ports. A
  word may not be a scheme a line already has (`socks`, `socks5`, `http`,
  `https`, `wireguard`).
- **Warm.** A proxy line tagged `warm=<n>`, 1 to 16, is dialled at the SOCKS5
  hop `XRAY_UPSTREAM_ALIASES` names `warm` (`warm=socks5://warm:1080`), the
  k-th such line, counting from 0 in the file's order, at its port plus k,
  with no login and no TLS of its own. The hop is the
  [proxy-warm image](../proxy-warm/README.md), which reads the same list and
  keeps `n` connections to the line's proxy open, logged in for SOCKS5. A
  new connection's first data goes out with its CONNECT, before the proxy
  replies, with no greeting or login to wait for. Restart both after any
  change to the list, so the k-th port leads to the same line in each. The summary
  shows the proxy and the hop.
- `name=` is 1 to 32 lowercase letters, digits and dashes, starting with a
  letter or a digit; a group is 1 to 16 lowercase letters and digits, starting
  with a letter, and appears once on a line.
- The summary lists each outbound's tag, name, kind and endpoint, none of which
  is secret. Users, passwords and WireGuard keys are redacted from `xray run
  -test` output like every other resolved value.

Each of these exits 78. The message names the file and the line, and never
the URL:

- No line, after blank lines and `#` comments.
- A line that starts with neither a URL nor a word `XRAY_UPSTREAM_ALIASES`
  defines; a scheme other than those above.
- Tags before the URL that do not end in `|` and the URL; a tag other than
  `name=`, `group=` and `warm=`, one twice, or a name or group outside its
  pattern; a name on two lines.
- `warm=` outside 1 to 16, on a WireGuard line or a word's, or with no
  SOCKS5 hop named `warm` in `XRAY_UPSTREAM_ALIASES`; `warm` alone as a line,
  or as a scheme.
- A SOCKS5 user or password over 255 bytes, which the protocol cannot send.
- A proxy `$proxy` would refuse; a `wireguard://` URL with no key before its
  `@`, a query key not listed above or one twice, a line break or `#` in a
  value, or settings `$wireguard` would refuse.
- A pin no line is named, or two pins in one group; an alias that is not
  `<word>=<url>`, a word twice, a word that is a scheme, or a login in its
  URL; a line naming a word whose port would pass 65535.

## A subscription's outbounds

`{"$subscription": "/run/secrets/subscription_url"}` resolves to the
`outbounds` array of the Xray config the `http` or `https` URL in the file
serves, as an app's "custom config" subscription does. The rest of what that
config holds (its inbounds, routing, DNS) is not used: the local config keeps
those, and routes to the subscription's outbounds by tag, through a balancer
whose selector is their prefix. Put it in a file of its own, as
[`$upstreams`](#any-number-of-upstreams-from-one-list):

```json
{"outbounds": {"$subscription": "/run/secrets/subscription_url"}}
```

The URL is fetched at start, and again every `XRAY_SUBSCRIPTION_INTERVAL`,
through `XRAY_SUBSCRIPTION_PROXY` when it is set (an inbound of this Xray, so
the subscription comes through the tunnel where only the tunnel gets through)
and directly when that fails. When the outbounds changed, the whole source is
resolved again and tested with `xray run -test` in a directory beside the
running config. Xray restarts on it only if it passes; otherwise it keeps the
config it runs, and says so. With a subscription, the entrypoint stays as
Xray's parent: it passes `SIGTERM` and `SIGINT` on, and Xray's own exit ends
the container with Xray's status.

- **At start, unreachable.** The copy in `XRAY_SUBSCRIPTION_CACHE`, the last
  outbounds `xray run -test` passed, kept as `<file name>.json` there (two
  subscriptions whose files share a name are refused). With no
  cache, the array is empty, so Xray starts on the rest of the config alone.
  Either way the URL is tried every 30 seconds until it answers, and every
  interval from then on. A local config whose first outbound blocks fails
  closed until then.
- **What is accepted.** A `200` with at most 4 MiB of JSON, an object whose
  `outbounds` array holds at least one object with a `protocol`. A redirect is
  not followed. Anything else keeps what Xray has.
- **Nothing shown.** The URL's path is the credential: errors and the summary
  name the file, never the URL. Every string in the outbounds, but their
  `protocol`, `network`, `security`, `flow`, `fingerprint`, `mode`, `tag` and
  `type`, is redacted from Xray's output.

## A dotdash relay's gateway

A dotdash relay carries devices of several server groups, each with its own
servers and exit, and keeps each group's devices on that group's servers.
`$gateway` builds that from two secrets: `servers`, one `server/1` line per
group, as each server's `relay-config` prints it, and `via`, the relays this
one goes through, as `relay/1` lines. It stands for a whole config, so it is
alone in a file of its own; the device inbounds stay in the template's, their
clients and users from `$gatewayClients`:

```json
{"$gateway": {"servers": "/run/secrets/servers", "via": "/run/secrets/via", "serverLink": "reality", "ipv6": "allow",
              "probeURL": "https://www.gstatic.com/generate_204", "tunnelGroup": ""}}
```

```json
"inbounds": [{"tag": "devices", "port": 8443, "protocol": "vless",
              "settings": {"clients": {"$gatewayClients": "vless"}, "flow": "xtls-rprx-vision", "decryption": {"$vlessDecryption": "/run/secrets/vless_seed"}}, …},
             {"tag": "devices-hy2", "port": 8448, "protocol": "hysteria",
              "settings": {"version": 2, "users": {"$gatewayClients": "hysteria"}}, …}]
```

| Option | Default | |
|---|---|---|
| `servers` | required | The `server/1` lines. With none, the relay lets nobody in. |
| `via` | none | The `relay/1` lines of the relays this one goes through, in place of the servers. |
| `serverLink` | `reality` | `reality`: REALITY with Vision to each server. `xhttp-reality`: XHTTP with REALITY, on the port and path of a line's `xr=`; a line without `xr=` keeps REALITY. |
| `viaLink` | `reality` | `reality`: REALITY with Vision to each relay in `via`. `xhttp`: XHTTP through each one's own site, which needs its `xhttp=`. |
| `viaFingerprint` | `chrome` | The TLS hello of `viaLink` `xhttp`: `chrome`, `firefox`, `safari`, `edge`, `ios`, `android`, `random`, or `none` for Go's own. |
| `ipv6` | `allow` | `block`: an IPv6 destination goes nowhere. |
| `probeURL` | `https://www.gstatic.com/generate_204` | What the observatory fetches through each leg. |
| `tunnelGroup` | the first group | The group the `tunnel` inbound goes to. One no line names is warned of, and the first group's. |
| `listen` | `0.0.0.0` | The address the `subscriptions` and `tunnel` inbounds listen on, such as the container's address on the network it shares with Caddy alone. |

**A server/1 line** is
`server/1 <name> <host>[,<host>…] <port> <pbk> <sid> <enc> <relay id>`, then
optional `xr=<port>,<path>` and `address=<ip>[,<ip>…]`, read as `relay/1`
lines are: blank lines and `#` comments skipped, any other line refused by
its number, an unknown `key=` left out with a warning. The name is the
group's, 1 to 16 lowercase letters and digits starting with a letter, unique;
it has no dash, because a balancer's selector is a prefix of its legs' tags.
The hosts are the group's servers, which share their keys: DNS names or IPv4
addresses. The relay id is this relay's id on them, as a server derives it
([`$vlessClients`](#a-servers-relays)). `address=` gives one IP per host, in
order, which the relay dials in place of the name.

**What it makes.**

- **Outbounds.** First `block`, a blackhole: Xray's default outbound. Then a
  leg per server, tagged `<group>-<n>`, as this relay's id on the group; or,
  with `via`, a leg per relay there instead, `<group>-v<n>`, on port 443, still
  as this relay's id on the group, which that relay's server lists for it.
- **Inbounds.** `subscriptions` (http, port 10810) and `tunnel` (http,
  port 10811), on `listen`, for the relay's Caddy on the project's network; and a
  `probe-<leg>` per leg (http, `127.0.0.1`, from port 10900 in the legs'
  order), for the agent.
- **A balancer per group**, tagged with its name, `leastPing` over its legs
  (selector `<group>-`), its `fallbackTag` its own first leg, and a
  `burstObservatory` over every group, probing each leg every 30 seconds.
- **The rules**, in order, each tagged:

| `ruleTag` | Matches | Goes to |
|---|---|---|
| `ipv6` | `ip: ::/0` (`ipv6` `block` only) | `block` |
| `internal` | a device (`user: regexp:@`) asking for a `dotdash.internal` name | `block` |
| `probe-<leg>` | that leg's probe inbound | that leg |
| `tunnel` | the `tunnel` inbound | the tunnel group |
| `sub-<group>-<digest>` | the `subscriptions` inbound, for `<prefix>.sub.dotdash.internal`, a prefix of the group's; the digest, of the prefixes, is how a replace is read back, as Xray lists a rule by its tag and outbound alone | the group |
| `users-<group>` | a device named `<device>@<group>` | the group |
| `block` | anything else (`network: tcp,udp`) | `block` |

Three of these fail closed, and no template can drop them: the default
outbound is a blackhole; a group whose legs are all down, or not probed yet,
falls back to its own first leg, never to that default and so never to
another group's server; and the last rule blocks what no other took. A device
reaches its server as the relay, which may ask a server for its internal
names: `internal` keeps devices from asking.

**`$gatewayClients`** is `"vless"` in a VLESS inbound's `settings.clients`
or `"hysteria"` in a Hysteria2 inbound's `settings.users`: the gateway's
devices, each named `<device>@<group>`, none at the first start. The inbound's
`settings.flow` gives a VLESS client its flow, as for `$vlessClients`.

### The agent

With a `$gateway`, the entrypoint stays Xray's parent and runs an agent, a
second after Xray starts and every `XRAY_GATEWAY_INTERVAL` from then on:

1. **Each group's list**, through each of its legs' probe inbounds:
   `GET http://list.sub.dotdash.internal/<list token>`, the token the first 32
   hex characters of `sha256("<relay id>:list")`. The server hands the name to
   its own Caddy, for relays alone. A list is
   ```text
   # dotdash relay list v1
   <id> [<name> [<first 12 hex of the device's subscription token>]]
   ```
   and a line that is not an entry is left out and counted. A list without
   that first line counts as none.
2. **The group's state.** `live` while one leg serves its list; `refused`
   while none does and one answers that there is none (404), which drops the
   group's devices: a server that no longer lists this relay must not keep
   letting them in through it; `down` otherwise, keeping the list it had,
   since its devices can't get through anyway; `starting` before the first
   round.
3. **The union**: every group's entries, each named `<name>@<group>` (an
   unnamed one `#<8 hex of the sha256 of its id>@<group>`), and each group's
   checker, `#check@<group>`, with a random id made at start, for a probe of
   the relay's own entries that needs no device's id. An id two entries
   share once bytes 6 and 7 are zeroed goes from every group, as does a name a
   group lists twice: one copied id must not take every group down, nor let
   a device in as another group's. A subscription prefix two groups share
   gets no route. Each is named in the status and the log.
4. **Xray's API.** Each device inbound's users are read back
   (`inbounduser`), and those that differ are removed (`rmu`) and added
   (`adu`, a VLESS client with the inbound's flow). When the prefixes
   changed, the routing is replaced (`adrules`), balancers and all; every
   round it is read back (`lsrules`): the rules' tags are the ones sent, the
   last to `block`. Rules that differ are replaced again; still different,
   Xray restarts.
5. **A restart, for a removed device still connected.** The API cannot cut a
   user's open connections, and Hysteria2 takes new requests on one that
   logged in, so when a removed device is still online
   (`statsgetallonlineusers`), Xray restarts on the config resolved again from
   the lists in memory, tested first as a subscription's is. Every device's
   connections drop. A restart whose config fails is tried again every round
   till it passes. Xray counts nobody online from `127.0.0.1`.

The agent keeps the lists in memory, gone when the container stops: after a
start, each group's devices get in once its first round has its list. The
resolved config in `XRAY_RUNTIME_DIR` holds the devices of the last start or
restart, every id among them, till the next start empties it: on the
container's own layer or a volume, that is after a stop as well. Mount a
tmpfs there, as [Usage](#usage) does, for them to go with the container.

**The status.** After each round the agent writes `XRAY_GATEWAY_STATUS`, a
JSON file, whole, mode 0644, for the relay's tasks:

```json
{"round": "2026-11-27T12:00:00Z",
 "groups": [{"name": "a", "state": "live", "check": "<the checker's id>", "devices": 14, "digest": "3f9a1c2b",
             "listed": "2026-11-27T11:59:58Z",
             "legs": [{"tag": "a-0", "host": "a1.example.com", "probe": 10900, "state": "ok", "ms": 41},
                      {"tag": "a-1", "host": "a2.example.com", "probe": 10901, "state": "down", "error": "503 Service Unavailable"}]}],
 "dropped": ["phone@a, phone@b: one id, once bytes 6 and 7 are zeroed"]}
```

`round` is the last round that reached Xray's API, and `error` what stopped
a later one, which is tried again 5 seconds on. `digest` is the first 8 hex
characters of the sha256 of the list as served, `listed` when it was
fetched, `skipped` its lines left out. The checkers' ids let in only through
the relay's own entries. Its directory must be writable by 65532: a tmpfs
the tasks share, with a read-only root.

**`xray-entrypoint gateway-status`** prints it, a line per group, and exits
0 while the last round that reached Xray's API is at most two minutes old
(or two intervals): the relay's machinery works, whatever its groups' states.
A health check takes that; a group's state is for the tasks and the metrics.

```text
a                live     a1.example.com ok 41 ms, a2.example.com down (503 Service Unavailable); 14 devices, digest 3f9a1c2b, list 42 s old
b                refused  b.example.com refused (no list for this relay (404))
c                down     c.example.com down (no answer (…)); 6 devices kept from the last list, digest 0d1e2f3a, list 240 s old
gateway: last round 12 s ago
```

**The log** says when a group changes state, how many devices a round added
and removed, what it dropped, and why Xray restarts, naming devices, never an
id or a token: `gateway: group b down: no leg answers (b.example.com: 503
Service Unavailable)`, `gateway: phone@a removed while connected: restarting
Xray`.

**What the rest of the config holds.** Xray merges `-confdir` files, a later
file's outbounds before the earlier ones' and its routing in place of theirs,
so no other file may hold `outbounds`, `routing`, `observatory` or
`burstObservatory`. The devices are added and removed through Xray's API, and
a removed device still connected is told by its online count, so the config
needs:

```json
"api": {"tag": "api", "listen": "127.0.0.1:10085", "services": ["HandlerService", "RoutingService", "StatsService"]},
"stats": {},
"policy": {"levels": {"0": {"statsUserOnline": true}}}
```

Each of these exits 78. The message names the file and the line, never what
is on the line:

- A `servers` line whose first field is not `server/1`, such as a `relay/1`
  line; a head of fewer than 8 fields, or a field outside its shape; two lines
  with one name; an `xr=` that is not `<port>,<path>`; an `address=` that is
  not one IP per host.
- A `via` line `$vlessClients` would refuse; with `viaLink` `xhttp`, a line
  without `xhttp=`.
- An option not listed above, one that is not a string, or a value outside
  its list; no `servers`.
- `$gateway` anywhere but a file's top level, or in two files; `outbounds`,
  `routing`, `observatory` or `burstObservatory` in another file.
- No API on a loopback address with the three services, no `stats`, or no
  `statsUserOnline` at level 0, taking the file Xray takes each from: the last
  in name order.
- `$gatewayClients` with no `$gateway`; a word other than `vless` and
  `hysteria`; anywhere but a VLESS inbound's `settings.clients` or a Hysteria2
  inbound's `settings.users`, of an inbound with a tag and a port.
- `XRAY_GATEWAY_INTERVAL` under a second; an `XRAY_GATEWAY_STATUS` that is
  not an absolute path, in a directory in or around `XRAY_SOURCE_DIR` or
  `XRAY_RUNTIME_DIR` (Xray would read it there as config), or whose
  directory 65532 cannot write.

## Geodata from a URL

`XRAY_GEOIP` and `XRAY_GEOSITE` replace the image's `geoip.dat` and
`geosite.dat` with a file from a URL, pinned by its sha256, such as a
version of a list whose names (`geosite:<name>`) the image's lacks:

```sh
XRAY_GEOSITE="https://cdn.example/lists@2026.11.01/geosite.dat 3a7bd3e2360a3d29eea436fcfb7e44c735d117c42d1c1835420b6b9942dd4f1b"
XRAY_GEODATA_DIR=/var/lib/xray/geodata
```

A file is kept in `XRAY_GEODATA_DIR`, and Xray reads it from there: the
entrypoint sets `XRAY_LOCATION_ASSET`, which may not be set as well. A file
neither variable pins stays the image's own.

- **When it is fetched.** When the kept file is not the pinned one, every
  30 seconds once Xray runs, through `XRAY_SUBSCRIPTION_PROXY` first and
  directly when that fails, as a [subscription](#a-subscriptions-outbounds)
  is: so never around the tunnel before Xray runs, but directly once it runs
  and a fetch through the tunnel fails. Xray restarts on it once `xray run
  -test` passes the running config on it: the files fetched together are
  tested together, beside the files in use, and each alone when they fail. At start only when the config fails without it, as on a new
  machine or a lost volume, where Xray can't run to fetch it: then once,
  directly, tested the same way before it is kept.
- **When it is not fetched again.** A URL that serves a file of another
  sha256, or a larger one than below, and a file the test refuses: till a
  restart, as for a new pin, Xray keeps the one it has. Directly, after the
  tunnel failed, a wrong file is not final, as a block page may answer
  there; nor is a test that was killed rather than refused.
- **Until then.** Xray starts on the file kept for an earlier pin, or with
  none, on the image's own. A rule naming a list only the pinned file has
  fails that start unless the direct fetch above gets it, and the error then
  says so: behind a kill switch, pin the file first, and add such rules once
  its log says it was fetched. After that, the kept copy serves every start,
  with the URL unreachable or not.
- **What is accepted.** A `200`, redirects followed, of at most 256 MiB
  whose sha256 is the pinned one: connected to within 10 seconds, answering
  within 30, never a minute without data, and read within 10 minutes.
  Anything else is not kept, and a kept file is on disk before it is in use.
  A URL with a login or a query is refused at start, as the startup summary
  would show it.

## VLESS Encryption from one seed

Both halves of an ML-KEM-768 VLESS Encryption key pair derive from one 64-byte
seed. A seed file holds it as 128 hex characters, which a generator that writes
only text can produce, such as morzer's `hex` with length 128.

- **Server.** `{"$vlessDecryption": "/run/secrets/vless_seed"}` resolves to
  `mlkem768x25519plus.native.600s.<seed, base64url>`. This is the server half
  `xray vlessenc` prints for its ML-KEM-768 pair. `native` and `600s` are fixed.
- **Client.** `xray-entrypoint vless-encryption <absolute path>` prints the
  matching `mlkem768x25519plus.native.0rtt.<key>` line on stdout and nothing
  else. The key is the one `xray mlkem768 -i <seed>` prints as `Client:`. The
  seed is read from the file, so it never appears on a command line. The binary
  is static, so another image can run it from a read-only mount of this one.

```sh
docker run --rm -v ./secrets/vless_seed:/run/secrets/vless_seed:ro \
  ghcr.io/morzecrew/xray:26.10.31 vless-encryption /run/secrets/vless_seed
```

A bad seed file exits 78 here too.

## A relay's id

`xray-entrypoint relay-id <seed file> <name> <nonce>` prints a dotdash relay's
id on this server, [derived](#a-servers-relays) from the relay seed in the
file and the relay's name and nonce, plus a newline and nothing else, for the
server's tasks that print a relay its line. The seed is read from the file,
so it never shows on a command line.

```sh
docker run --rm -v ./secrets/relay_seed:/run/secrets/relay_seed:ro \
  ghcr.io/morzecrew/xray:26.11.9 relay-id /run/secrets/relay_seed r1 0123456789abcdef
```

A seed file that is not 64 lowercase hex characters exits 78; a name or a
nonce outside its shape, a missing argument, or a first argument that is
not an absolute path (and so may be the seed itself, which is not repeated)
exits 2. Where the relay fetches its device list is the first 32 hex
characters of `sha256("<relay id>:list")`, which the vectors carry too.

## REALITY public key

A REALITY server needs nothing from the image: its private key reaches Xray as
`"privateKey": {"$file": "/run/secrets/reality_key"}`. The file holds the
key as Xray's config takes it, 43 base64url characters.

Its clients need the public key, which Xray's client config calls `password`
(`publicKey` is the older alias) and share links carry as `pbk`.
`xray-entrypoint reality-password <absolute path>` prints it on stdout,
plus a newline and nothing else. It is the value `xray x25519 -i <key>` prints
as `Password (PublicKey)`. Unlike that command, it reads the key from a file,
so the key never shows in `/proc/<pid>/cmdline` or in the host's `ps`.

```sh
docker run --rm -v ./secrets/reality_key:/run/secrets/reality_key:ro \
  ghcr.io/morzecrew/xray:26.10.31 reality-password /run/secrets/reality_key
```

The file is decoded with the call Xray makes for `privateKey`, so any file the
server accepts gives the password its clients need. That decoding accepts 43
random characters whose last one has spare bits set, as a password generator
writes them, and skips line breaks. Anything else exits 78, naming the path:
a file that fails the `$file` checks, padding, the standard alphabet's `+` or
`/`, or a length other than 32 bytes, hex included.

Both commands take only an absolute path. Neither a seed nor a key can start
with `/`, so the secret pasted in place of its path, as `xray x25519 -i` takes
it, exits 2 with a usage line, and the argument is not repeated.

## Healthcheck

`xray-entrypoint healthcheck` sends one `GET XRAY_HEALTHCHECK_URL` through
`XRAY_HEALTHCHECK_PROXY`. It exits 0 on a 2xx within `XRAY_HEALTHCHECK_TIMEOUT`
and 1 otherwise, and prints the status or the error on stderr.

The proxy is an inbound your config declares on `127.0.0.1`, such as an `http`
inbound on `127.0.0.1:10809`. The probe then takes the same routing and
outbounds as client traffic, and nothing outside the container can use the
inbound. `http`, `https`, `socks5` and `socks5h` proxy URLs work.

- A redirect counts as a failure and is not followed. A captive portal or a
  block page answers with one more often than not.
- `XRAY_HEALTHCHECK_EXPECT` also checks where traffic leaves from. Point
  `XRAY_HEALTHCHECK_URL` at an IP-echo endpoint and set the expression to the
  exit IP you chose. A 2xx then passes only if the first 64 KiB of the body
  match it, and a mismatch prints the first 128 bytes of the body, which is the
  exit IP now in use:

  ```yaml
  XRAY_HEALTHCHECK_URL: https://api.ipify.org
  XRAY_HEALTHCHECK_EXPECT: '^203\.0\.113\.7\s*$'
  ```

  Anchor it: unanchored, `203\.0\.113\.7` also matches `203.0.113.71`. This
  fits a static exit IP. A rotating pool needs an ASN or country check, which
  the image does not make.
- With `XRAY_HEALTHCHECK_PROXY` unset, the check passes if Xray runs (as PID 1,
  or under the entrypoint with a subscription or a gateway) and the runtime config exists.
  A gateway's [`gateway-status`](#the-agent) also says its agent's rounds run.
  It says on stderr that egress was not probed.
- The image bakes no `HEALTHCHECK`, because the probe needs an inbound only
  your config can declare. Add the `healthcheck:` block shown under
  [Usage](#usage).

## Fetch

`xray-entrypoint fetch` makes one request through a proxy and reports how
much of the body came and how long it took. It is for a probe that measures
the tunnel itself, such as a freeze check or a speed test. The binary is
static, so a probe in another image with a shell can run it from a read-only
mount of this one.

```sh
xray-entrypoint fetch -proxy http://127.0.0.1:10809 [-read-timeout 10s] [-timeout 1m] [-upload <bytes>] <url>
```

- **`-proxy`** is required: an `http`, `https`, `socks5` or `socks5h` URL.
  Without a proxy, the request would leave through the machine's own network,
  which is what such a probe must never measure.
- **The URL** is `http` or `https`. An `https` URL goes through the proxy by
  CONNECT, and its certificate is checked against the image's CA bundle. An
  `http` URL is sent to the proxy as is.
- **`-read-timeout`**: when nothing moves in either direction for this long,
  the request ends.
- **`-timeout`** caps the whole request.
- **`-upload N`** sends N zero bytes as a POST body instead of a GET. 0, the
  default, sends a GET.

Redirects are not followed, and no compression is asked for, so the bytes
counted are the bytes sent. Whatever the outcome, `<bytes> <milliseconds>` is
printed on stdout: the bytes of the body received, and the time since the
request began. What ended the request goes to stderr. The exit code says how
it ended:

| Exit | |
|---|---|
| 0 | complete: a 2xx whose body arrived whole |
| 1 | nothing: no byte of a body, from no connection, a certificate that fails, a status other than 2xx, or no answer within `-read-timeout` |
| 2 | usage |
| 3 | cut short: some bytes, then the connection closed early, nothing came for `-read-timeout`, or `-timeout` was reached |

```sh
if out=$(/opt/xray/xray-entrypoint fetch -proxy http://reality:10809 "$url"); then
	bytes=${out% *} ms=${out#* }
fi
```

## Environment

| Variable | Default | |
|---|---|---|
| `XRAY_SOURCE_DIR` | `/etc/xray` | Where the config is read from. Every file must be `.json`. |
| `XRAY_RUNTIME_DIR` | `/run/xray` | Where the resolved config is written. Emptied on every start, so it may not be the source, hold it or sit inside it, through a symlink or otherwise. |
| `XRAY_HEALTHCHECK_URL` | `https://www.gstatic.com/generate_204` | What the probe requests. `http` or `https`. |
| `XRAY_HEALTHCHECK_PROXY` | unset | The loopback inbound the probe goes through. Unset means liveness only. |
| `XRAY_HEALTHCHECK_TIMEOUT` | `10s` | A Go duration. Reading the body counts against it. |
| `XRAY_HEALTHCHECK_EXPECT` | unset | A regular expression in [Go's RE2 syntax](https://github.com/google/re2/wiki/Syntax) the response body must match. Unset means any 2xx passes and the body is not read. Ignored, with a warning at start, while `XRAY_HEALTHCHECK_PROXY` is unset. |
| `XRAY_UPSTREAM_ALIASES` | unset | `<word>=<url>` pairs, separated by spaces, that an [upstreams](#any-number-of-upstreams-from-one-list) line may name by its word. No login. |
| `XRAY_UPSTREAM_PIN` | unset | Names of upstreams lines, separated by commas, each moved to the front of its groups. |
| `XRAY_SUBSCRIPTION_INTERVAL` | `1h` | How often a [subscription](#a-subscriptions-outbounds) is fetched again. A Go duration, 1s or more. |
| `XRAY_SUBSCRIPTION_PROXY` | unset | A `socks5://`, `socks5h://` or `http://` inbound of this Xray a subscription, and pinned geodata, is fetched through, directly when that fails. No login. Unset means directly. |
| `XRAY_SUBSCRIPTION_CACHE` | unset | A writable directory, outside `XRAY_SOURCE_DIR` and `XRAY_RUNTIME_DIR`, where each subscription's last accepted outbounds are kept, for a start while its URL is unreachable, such as `/var/lib/xray` with a volume on it: the image's is empty and 65532's, so a new volume there is writable. Unset means none. |
| `XRAY_GEOIP` | unset | `<url> <sha256>`: a [`geoip.dat`](#geodata-from-a-url) fetched in place of the image's. |
| `XRAY_GEOSITE` | unset | `<url> <sha256>`: a [`geosite.dat`](#geodata-from-a-url) fetched in place of the image's. |
| `XRAY_GATEWAY_INTERVAL` | `1m` | How often a [gateway's agent](#the-agent) fetches its groups' lists. A Go duration, 1s or more. |
| `XRAY_GATEWAY_STATUS` | `/run/gateway/status.json` | Where the agent writes its status, in a directory 65532 can write: the image's, or a tmpfs on it. |
| `XRAY_GEODATA_DIR` | unset | A writable directory, outside `XRAY_SOURCE_DIR` and `XRAY_RUNTIME_DIR`, where fetched geodata is kept, such as `/var/lib/xray/geodata` with a volume on `/var/lib/xray`. Needed by `XRAY_GEOIP` and `XRAY_GEOSITE`. |

A value set to the empty string takes the default. A bad URL, timeout or
expression refuses at start (78), so it is found at deployment rather than as
an unhealthy container later.

The prefix is `XRAY`. Xray's own names (`XRAY_LOCATION_ASSET`,
`XRAY_BUF_READV`, `XRAY_JSON_STRICT` and the rest from `common/platform`) reach
Xray untouched. The image has **no passthrough channel**: Xray's settings live
in its config. A `XRAY_CONF__*` variable is reported at start, not applied. Any
other `XRAY_*` name neither the image nor Xray reads draws a warning.

### Startup summary

Printed on stderr before Xray starts. It shows the paths a value came from,
never the value:

```text
[envconf] xray: effective configuration
[envconf]   source=env-or-default XRAY_SOURCE_DIR = /etc/xray
[envconf]   source=env-or-default XRAY_RUNTIME_DIR = /run/xray
[envconf]   source=env-or-default XRAY_HEALTHCHECK_URL = https://www.gstatic.com/generate_204
[envconf]   source=env-or-default XRAY_HEALTHCHECK_PROXY = http://127.0.0.1:10809
[envconf]   source=env-or-default XRAY_HEALTHCHECK_TIMEOUT = 10s
[envconf]   source=env-or-default XRAY_HEALTHCHECK_EXPECT = (unset: any 2xx passes)
[envconf]   source=image          xray = Xray 26.10.31 (Xray, Penetrates Everything.) Custom (go1.27.3 linux/amd64)
[envconf]   source=config         /etc/xray/10-xray.json
[envconf]   source=file           inbounds[0].settings.clients[0].id <- /run/secrets/vless_uuid   (/etc/xray/10-xray.json)
[envconf]   source=file           inbounds[0].settings.decryption <- $vlessDecryption /run/secrets/vless_seed   (/etc/xray/10-xray.json)
[envconf]   source=file           inbounds[1].settings.clients <- $vlessClients /run/secrets/vless_clients (2 clients)   (/etc/xray/10-xray.json)
[envconf]   source=file           outbounds[1].settings <- $proxy /run/secrets/upstream proxy.example:1080   (/etc/xray/10-xray.json)
[envconf] precedence: image default < environment
```

A password in a URL, and every value in its query, is shown as `xxxxx`, here
and in the healthcheck's output.

## Other commands

Any first argument other than `run`, `healthcheck`, `fetch`,
`vless-encryption`, `reality-password`, `relay-id` or `gateway-status` goes straight to `xray`, so
upstream's tools work:

```sh
docker run --rm ghcr.io/morzecrew/xray:26.10.31 uuid
docker run --rm ghcr.io/morzecrew/xray:26.10.31 vlessenc
docker run --rm ghcr.io/morzecrew/xray:26.10.31 x25519
```

`run` with more arguments passes them to both `xray run -test` and `xray run`,
after `-confdir`.

## Versions

`XRAY_VERSION` in [`docker-bake.hcl`](../../docker-bake.hcl) is read from
GitHub releases rather than image tags, because upstream publishes its
prereleases as image tags of the same form.

The upstream image is pinned by digest, `XRAY_IMAGE_DIGEST`, because upstream
rebuilds a tag when a prerelease is promoted and on a manual dispatch, and each
build fetches its geodata from `latest`. The pin is what makes a rebuild here
ship the same `geoip.dat` and `geosite.dat`, which `geoip:private` routing
depends on. Renovate moves the version and not the digest, and
[`follow-digest.yaml`](../../.github/workflows/follow-digest.yaml) then pushes
the new version's digest onto its branch, in both `docker-bake.hcl` and the
`Dockerfile`. A digest is moved only with its version, and only while the
branch still has the old one, so a tag upstream rebuilds never moves the pin on
`main`, nor one already on the branch: the digest CI tested, or one pinned
there by hand, is the one that merges. Until the digest follows, `smoke.sh`
fails on the version the label names. If upstream has not published the image yet, the
workflow fails; rerun it once it has, or move the digest by hand:

```sh
docker buildx imagetools inspect ghcr.io/xtls/xray-core:<version> \
  --format '{{json .Manifest.Digest}}'
```

The distroless base is not pinned, so the weekly rebuild brings its CA bundle
and tzdata current.

## Layout

- `Dockerfile`: the upstream stage pinned by digest, the entrypoint build
  (its tests run there), and the distroless runtime.
- `entrypoint/`: `xray-entrypoint`, standard library only, and its tests,
  which cover every seed, client list and proxy refusal above, and each way
  a `fetch` can end, against a test server and proxy, and check that every
  shape of a gateway's config keeps its three rules that fail closed. The resolver
  and its file checks, the summary and the healthcheck live in
  [`shared/go/envconf`](../../shared/go/envconf), with their tests, which
  mihomo uses too.
  `testdata/vlessenc.txt` is a key pair `xray vlessenc` printed on 26.10.31,
  which the derivation must reproduce. `testdata/relay-id.json` holds relay
  ids and list tokens a separate Python implementation computed: `relay-id`
  must reproduce them, and so must dotdash's server and manager, which test
  their own against a copy.
- `smoke.sh`: rootless Podman. Covers the references, the seeded key pair end
  to end, both client-side commands against upstream's own derivation, a socks
  and an http upstream with a password holding `:` and `@`, the healthcheck,
  `fetch` through the probe inbound and through a dead proxy, the refusals an
  operator is most likely to meet, and the absence of every secret from the
  output, and that Xray takes each shape of a gateway's config; then
  `smoke-gateway.sh`.
- `smoke-gateway.sh`: a gateway end to end, on loopback, with no image but
  this one: a relay in front of two stand-in server groups, each an Xray of
  this image letting the relay in by its derived id, with its own exit and,
  on the host, a Python stand-in for its internal endpoint. Devices of each group get in
  through the API by REALITY and Hysteria2 with no restart, reach their own
  group's exit and subscriptions, and are kept from the internal names; a
  device added gets in; an id two groups share is dropped from both; one
  removed while connected restarts Xray and loses its open download; a group
  whose server is down, also before the first round, or answers it has no
  list, gets nothing while the other is unaffected. Each refusal is checked
  to have reached the client, beside a request known to work. It needs the
  gateway's fixed ports, 10810, 10811 and 10900 up, free on loopback.
