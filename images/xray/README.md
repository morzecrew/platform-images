# xray

[Xray-core](https://github.com/XTLS/Xray-core) for a Compose bundle: uid 65532
on distroless, a read-only root, secrets read from files that its JSON config
references, and a healthcheck that sends a request out through Xray itself.

The binary and the geodata are upstream's, copied unchanged out of
`ghcr.io/xtls/xray-core` pinned by digest. The image adds one static Go binary,
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
| `{"$proxy": "/abs/path"}` | a socks or http outbound's `settings`, split from the `[user:pass@]host:port` in the file (see below) |

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
result and execs `xray run -confdir $XRAY_RUNTIME_DIR` as PID 1.

### Refusals

Each of these exits **78** before Xray starts. The message names the JSON
file, the JSON path and the referenced path, never a value.

- A referenced file that is missing, unreadable by uid 65532, not a regular
  file (a directory counts: Compose leaves one where a secret's source file is
  missing), over 64 KiB, not UTF-8, or holding a NUL byte. These are the
  checks the shared `_FILE` contract makes.
- An object holding `$file`, `$vlessDecryption`, `$vlessClients` or `$proxy`
  and any other key, or a path that is not an absolute path in a string. A near
  miss would otherwise reach Xray as a literal.
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
# <uuid> [name]
3f2c1f0e-8a4b-4c1d-9e2f-0a1b2c3d4e5f
6b1d2c3e-4f5a-4b6c-8d7e-9f0a1b2c3d4e phone
```

```json
[{"id": "3f2c1f0e-8a4b-4c1d-9e2f-0a1b2c3d4e5f"}, {"id": "6b1d2c3e-4f5a-4b6c-8d7e-9f0a1b2c3d4e", "email": "phone"}]
```

- The id and the optional name are separated by spaces or tabs. Whitespace
  around them, blank lines and lines starting with `#` are ignored.
- The id is lower-cased. The name becomes `email`, which Xray shows as the
  user's label in its logs and stats.
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

Each of these exits 78. The message names the line, never what is on it:

- An id that is not a UUID written as 8-4-4-4-12 hex digits. Xray itself maps
  any other string of 1 to 30 bytes to a UUIDv5, so a typo would become a
  different id that looks valid and locks its device out.
- A name that is not 1 to 64 of `A-Z a-z 0-9 . _ @ + -`.
- A line with more than two fields.
- An id or a name that appears twice, ignoring case. Xray compares emails
  ignoring case and refuses the second.
- No client at all once comments and blank lines are skipped.

The summary shows the count, not the ids, and the ids are redacted from
`xray run -test` output like every other resolved value.

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
- With `XRAY_HEALTHCHECK_PROXY` unset, the check passes if PID 1 is Xray and
  the runtime config exists. It says on stderr that egress was not probed.
- The image bakes no `HEALTHCHECK`, because the probe needs an inbound only
  your config can declare. Add the `healthcheck:` block shown under
  [Usage](#usage).

## Environment

| Variable | Default | |
|---|---|---|
| `XRAY_SOURCE_DIR` | `/etc/xray` | Where the config is read from. Every file must be `.json`. |
| `XRAY_RUNTIME_DIR` | `/run/xray` | Where the resolved config is written. Emptied on every start, so it may not be the source, hold it or sit inside it, through a symlink or otherwise. |
| `XRAY_HEALTHCHECK_URL` | `https://www.gstatic.com/generate_204` | What the probe requests. `http` or `https`. |
| `XRAY_HEALTHCHECK_PROXY` | unset | The loopback inbound the probe goes through. Unset means liveness only. |
| `XRAY_HEALTHCHECK_TIMEOUT` | `10s` | A Go duration. Reading the body counts against it. |
| `XRAY_HEALTHCHECK_EXPECT` | unset | A regular expression in [Go's RE2 syntax](https://github.com/google/re2/wiki/Syntax) the response body must match. Unset means any 2xx passes and the body is not read. Ignored, with a warning at start, while `XRAY_HEALTHCHECK_PROXY` is unset. |

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

Any first argument other than `run`, `healthcheck`, `vless-encryption` or
`reality-password` goes straight to `xray`, so upstream's tools work:

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
depends on. Renovate moves the version and not the digest. Its pull request
fails `smoke.sh`, which compares the binary's version with the label, until the
digest is moved in both `docker-bake.hcl` and the `Dockerfile`:

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
  which cover every seed, client list and proxy refusal above. The resolver
  and its file checks, the summary and the healthcheck live in
  [`shared/go/envconf`](../../shared/go/envconf), with their tests, which
  mihomo uses too.
  `testdata/vlessenc.txt` is a key pair `xray vlessenc` printed on 26.10.31,
  which the derivation must reproduce.
- `smoke.sh`: rootless Podman. Covers the references, the seeded key pair end
  to end, both client-side commands against upstream's own derivation, a socks
  and an http upstream with a password holding `:` and `@`, the healthcheck,
  the refusals an operator is most likely to meet, and the absence of every
  secret from the output.
