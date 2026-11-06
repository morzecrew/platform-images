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
- An object holding `$file` or `$vlessDecryption` and any other key, or a path
  that is not an absolute path in a string. A near miss would otherwise reach
  Xray as a literal.
- A seed file that is not exactly 128 hex characters.
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

## VLESS Encryption from one seed

Both halves of an ML-KEM-768 VLESS Encryption key pair derive from one 64-byte
seed. A seed file holds it as 128 hex characters, which a generator that writes
only text can produce, such as morzer's `hex` with length 128.

- **Server.** `{"$vlessDecryption": "/run/secrets/vless_seed"}` resolves to
  `mlkem768x25519plus.native.600s.<seed, base64url>`. This is the server half
  `xray vlessenc` prints for its ML-KEM-768 pair. `native` and `600s` are fixed.
- **Client.** `xray-entrypoint vless-encryption <seed file>` prints the
  matching `mlkem768x25519plus.native.0rtt.<key>` line on stdout and nothing
  else. The key is the one `xray mlkem768 -i <seed>` prints as `Client:`. The
  seed is read from the file, so it never appears on a command line. The binary
  is static, so another image can run it from a read-only mount of this one.

```sh
docker run --rm -v ./secrets/vless_seed:/run/secrets/vless_seed:ro \
  ghcr.io/morzecrew/xray:26.10.31 vless-encryption /run/secrets/vless_seed
```

A bad seed file exits 78 here too.

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
| `XRAY_HEALTHCHECK_TIMEOUT` | `10s` | A Go duration. |

A value set to the empty string takes the default. A bad URL or timeout
refuses at start (78), so it is found at deployment rather than as an
unhealthy container later.

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
[envconf]   source=image          xray = Xray 26.10.31 (Xray, Penetrates Everything.) Custom (go1.27.3 linux/amd64)
[envconf]   source=config         /etc/xray/10-xray.json
[envconf]   source=file           inbounds[0].settings.clients[0].id <- /run/secrets/vless_uuid   (/etc/xray/10-xray.json)
[envconf]   source=file           inbounds[0].settings.decryption <- $vlessDecryption /run/secrets/vless_seed   (/etc/xray/10-xray.json)
[envconf] precedence: image default < environment
```

A password in a URL is shown as `xxxxx`.

## Other commands

Any first argument other than `run`, `healthcheck` or `vless-encryption` goes
straight to `xray`, so upstream's tools work:

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
  which cover every file and seed refusal above. `testdata/vlessenc.txt` is a
  key pair `xray vlessenc` printed on 26.10.31, which the derivation must
  reproduce.
- `smoke.sh`: rootless Podman. Covers the references, the seeded key pair end
  to end, the healthcheck, the refusals an operator is most likely to meet,
  and the absence of every secret from the output.
