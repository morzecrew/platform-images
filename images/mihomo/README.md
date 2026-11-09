# mihomo

[mihomo](https://github.com/MetaCubeX/mihomo), a client-side proxy, for a
Compose bundle. It runs as uid 65532 on distroless with a read-only root. Its
secrets, such as the subscription URL, are files that its JSON config
references. A healthcheck sends a request out through mihomo itself.

The binary and the geodata are upstream's, copied unchanged out of
`docker.io/metacubex/mihomo`, pinned by digest. The image adds one static Go
binary, `/usr/local/bin/mihomo-entrypoint`, which is the entrypoint. It has no
shell and no `iptables`.

| | |
|---|---|
| Image | `ghcr.io/morzecrew/mihomo:1.19.33` |
| Tag | Upstream's version without the `v`, stable releases only |
| User | `65532:65532` (`nonroot`), never root |
| Base | `gcr.io/distroless/static-debian13:nonroot` |
| Config | `config.json` in `MIHOMO_SOURCE_DIR` (`/etc/mihomo`), mounted read-only |
| Writes | only to `MIHOMO_HOME` (`/var/lib/mihomo`), a volume |
| Logs | mihomo's console log, which `docker logs` shows |

This image meets neither route of the
[admission rule](../README.md#which-images-belong-here), because only one
project uses it. It was admitted on the owner's call. See "Admissions on record"
there and [#140](https://github.com/morzecrew/platform-images/issues/140).

## Usage

```yaml
services:
  mihomo:
    image: ghcr.io/morzecrew/mihomo:1.19.33
    read_only: true
    cap_drop: [ALL]
    security_opt: ["no-new-privileges:true"]
    ports:
      - "1080:7890"             # inbounds listen on 1024 or above
    volumes:
      - ./mihomo:/etc/mihomo:ro # config.json
      - mihomo:/var/lib/mihomo  # provider caches, cache.db, geodata
    secrets: [subscription_url, direct_rules]
    environment:
      MIHOMO_HEALTHCHECK_PROXY: http://127.0.0.1:7890
    healthcheck:
      test: ["CMD", "/usr/local/bin/mihomo-entrypoint", "healthcheck"]
      interval: 60s
      timeout: 15s

volumes:
  mihomo:

secrets:
  subscription_url: { file: ./secrets/subscription_url }
  direct_rules: { file: ./secrets/direct_rules }
```

- **The volume** keeps the provider caches, so a client whose subscription
  URL cannot be reached starts on the subscription it fetched last time. A
  named volume starts as a copy of the image's `/var/lib/mihomo`, which uid
  65532 owns. A bind mount must be writable by 65532. With a read-only root
  and nothing mounted there, the entrypoint refuses to start, because nothing
  can be written. One home serves one container: two would share `cache.db` and the
  provider caches.
- **Ports.** mihomo runs as uid 65532 with no capabilities, so an inbound
  cannot listen below 1024.
- **Secret files** must be readable by uid 65532: owned by it, or group- or
  world-readable.

## The config, and file references

mihomo reads no value from a file and expands no variable inside its config.
`CLASH_CONFIG_STRING` and age encryption replace the whole config, which does
not help a single field. So a secret reaches mihomo only inside its config.

The source is **one JSON file**, `$MIHOMO_SOURCE_DIR/config.json`. mihomo reads
JSON as YAML, so any mihomo config can be written this way. JSON rather than
YAML lets the entrypoint parse it with Go's standard library alone, using the
resolver xray uses (`shared/go/envconf`). Before mihomo starts, the entrypoint
replaces each JSON object that is **exactly** `{"$file": "/abs/path"}` with the
file's content as a JSON string, minus one trailing newline. Everything else
stays as written.

```json
"proxy-providers": {
  "sub": {
    "type": "http",
    "url": {"$file": "/run/secrets/subscription_url"},
    "interval": 3600,
    "path": "./proxies/sub.yaml"
  }
}
```

A reference replaces one whole value, with no expansion inside a string, so
this is not the templating the
[environment contract](../README.md#no-templating) rules out.

The resolved config is written to `$MIHOMO_HOME/config.json` at mode 0600. The
source directory is never written. The entrypoint then copies in any of the
pinned geodata files the home directory lacks, runs `mihomo -t` on the result,
and execs `mihomo -d $MIHOMO_HOME -f $MIHOMO_HOME/config.json` as PID 1.

### Multiline secrets: rules from files

`SAFE_PATHS` is `/run/secrets` in this image. mihomo opens a provider or rule
file only under its home directory or `SAFE_PATHS`, so a secret can be a file
rule provider:

```json
"rule-providers": {
  "direct": {"type": "file", "behavior": "classical", "format": "text",
             "path": "/run/secrets/direct_rules"}
},
"rules": ["RULE-SET,direct,DIRECT", "MATCH,proxy"]
```

`SAFE_PATHS` is upstream's own variable. An operator who sets it replaces the
image's default, so add `/run/secrets` to the list (colon-separated) to keep
it. `SKIP_SAFE_PATH_CHECK=true` turns the check off, and the entrypoint warns
about it.

### The REST API

`external-controller` is off unless the config declares it. If it, or
`external-controller-tls`, listens on anything but loopback while `secret` is
empty, the entrypoint refuses. That API reads and changes the whole
configuration, the subscription included. `secret` can itself be a `$file`
reference. Upstream's `CLASH_OVERRIDE_EXTERNAL_CONTROLLER*` and
`CLASH_OVERRIDE_SECRET` are applied before this check, as mihomo applies them.
No web UI is shipped.

### Refusals

Each of these exits **78** before mihomo starts. The message names the JSON
path and the referenced path, never a value.

- A referenced file that is missing, unreadable by uid 65532, not a regular
  file (a directory counts: Compose leaves one where a secret's source file is
  missing), over 64 KiB, not UTF-8, or holding a NUL byte. These are the
  checks the shared `_FILE` contract makes.
- An object holding `$file` and any other key, or a path that is not an
  absolute path in a string. A near miss would otherwise reach mihomo as a
  literal.
- Anything in `MIHOMO_SOURCE_DIR` besides `config.json`, such as a
  `config.yaml`: it would look like config and never be read.
- A `config.json` that is not valid JSON (comments are refused), or no
  `config.json` at all.
- The REST API beyond loopback with no `secret` (above).
- `CLASH_CONFIG_STRING`, `CLASH_CONFIG_FILE` or `CLASH_HOME_DIR` set. The first
  would replace the image's config, and the image's `-d` and `-f` would
  silently override the other two.
- A `MIHOMO_HOME` uid 65532 cannot write, or one that overlaps the source
  directory once symlinks are resolved. Writing the resolved config there
  would overwrite the source.
- A config that `mihomo -t` rejects. mihomo's message is printed with every
  resolved value replaced by `<redacted>`, because mihomo quotes what it
  rejects.

`run` takes no further arguments. Flags such as `-d`, `-f`, `-config`,
`-ext-ctl` and `-secret` would undo these checks, so `run` with flags exits 2.

### What mihomo logs itself

The summary and the refusals never print a value. mihomo's own log is
different. **When it fails to fetch a subscription, it logs the full URL**:

```text
level=error msg="initial proxy provider sub error: Get \"https://sub.example/<token>\": EOF"
```

On a successful fetch it logs only the host and port. The entrypoint hands the
process over to mihomo, so it cannot redact what mihomo prints after that.
Treat the container log of a client whose subscription failed to load as if it
held the credential.

## Pinned geodata

`geoip.metadb`, `geosite.dat` and `geoip.dat` come from the pinned upstream
image and live in `/usr/local/share/mihomo`. At every start, the entrypoint
copies each one into `MIHOMO_HOME` if no file of that name is there. A first
start then needs no download, and two builds of the same tag ship the same
files. A file already in the home directory is kept. That includes one that
`geo-auto-update` replaced, which stays the operator's choice.

## Healthcheck

```sh
mihomo-entrypoint healthcheck
```

It sends one `GET` to `MIHOMO_HEALTHCHECK_URL` through
`MIHOMO_HEALTHCHECK_PROXY` within `MIHOMO_HEALTHCHECK_TIMEOUT`. It exits 0 on
a 2xx and 1 on anything else, and prints the status or the error on stderr.

The proxy is the `mixed-port` (or `port`, or `socks-port`) your config binds on
`127.0.0.1`. The probe then takes the same rules and proxies as client
traffic, and nothing outside the container can use the port. `http`, `https`,
`socks5` and `socks5h` proxy URLs work.

- A redirect counts as a failure and is not followed. A captive portal or a
  block page answers with one more often than not.
- `MIHOMO_HEALTHCHECK_EXPECT` also checks where traffic leaves from. Point the
  URL at an IP-echo endpoint and set the expression to the exit IP you expect.
  A 2xx then passes only if the first 64 KiB of the body match it. A mismatch
  prints the first 128 bytes of the body, which is the exit IP now in use. As
  for [xray](../xray/README.md#healthcheck), anchor it.
- With `MIHOMO_HEALTHCHECK_PROXY` unset, the check passes if PID 1 is mihomo
  and the resolved config exists. It says on stderr that egress was not
  probed.
- The image bakes no `HEALTHCHECK`, because the probe needs a port only your
  config can declare. mihomo's REST API can report delays, but it proves only
  that the process answers, and opening it is a risk of its own.

## Environment

| Variable | Default | |
|---|---|---|
| `MIHOMO_SOURCE_DIR` | `/etc/mihomo` | Where `config.json` is read from. It holds nothing else. |
| `MIHOMO_HOME` | `/var/lib/mihomo` | mihomo's home: the resolved config, provider caches, `cache.db` and geodata. It may not be the source, hold it or sit inside it. |
| `MIHOMO_HEALTHCHECK_URL` | `https://www.gstatic.com/generate_204` | What the probe requests. `http` or `https`. |
| `MIHOMO_HEALTHCHECK_PROXY` | unset | The loopback port the probe goes through. Unset means liveness only. |
| `MIHOMO_HEALTHCHECK_TIMEOUT` | `10s` | A Go duration. Reading the body counts against it. |
| `MIHOMO_HEALTHCHECK_EXPECT` | unset | A regular expression in [Go's RE2 syntax](https://github.com/google/re2/wiki/Syntax) the response body must match. Unset means any 2xx passes and the body is not read. Ignored, with a warning at start, while `MIHOMO_HEALTHCHECK_PROXY` is unset. |
| `SAFE_PATHS` | `/run/secrets` | Upstream's. Where provider and rule files may be, besides `MIHOMO_HOME`. |

A value set to the empty string takes the default. A bad URL, timeout or
expression refuses at start (78), so it shows up at deployment rather than
later as an unhealthy container.

The prefix is `MIHOMO`. mihomo's own names, `CLASH_*`, `SAFE_PATHS`,
`SKIP_SAFE_PATH_CHECK` and `XDG_CONFIG_HOME`, reach it untouched, apart from
the three refused above. The image has **no passthrough channel**: mihomo's
settings live in its config. A `MIHOMO_CONF__*` variable is reported at start,
not applied. Any other `MIHOMO_*` name the image does not read draws a warning.

### Startup summary

Printed on stderr before mihomo starts. It shows the paths a value came from,
never the value:

```text
[envconf] mihomo: effective configuration
[envconf]   source=env-or-default MIHOMO_SOURCE_DIR = /etc/mihomo
[envconf]   source=env-or-default MIHOMO_HOME = /var/lib/mihomo
[envconf]   source=env-or-default MIHOMO_HEALTHCHECK_URL = https://www.gstatic.com/generate_204
[envconf]   source=env-or-default MIHOMO_HEALTHCHECK_PROXY = http://127.0.0.1:7890
[envconf]   source=env-or-default MIHOMO_HEALTHCHECK_TIMEOUT = 10s
[envconf]   source=env-or-default MIHOMO_HEALTHCHECK_EXPECT = (unset: any 2xx passes)
[envconf]   source=image          mihomo = Mihomo Meta v1.19.33 linux amd64 with go1.26.10 Wed Oct 21 16:39:55 UTC 2026
[envconf]   source=config         /etc/mihomo/config.json
[envconf]   source=file           proxy-providers.sub.url <- /run/secrets/subscription_url   (/etc/mihomo/config.json)
[envconf] precedence: image default < environment
```

A password in a URL, and every value in its query, is shown as `xxxxx`, here
and in the healthcheck's output.

## Other commands

Any first argument other than `run` or `healthcheck` goes straight to
`mihomo`, so upstream's tools work:

```sh
docker run --rm ghcr.io/morzecrew/mihomo:1.19.33 -v
docker run --rm ghcr.io/morzecrew/mihomo:1.19.33 generate vless-x25519
docker run --rm ghcr.io/morzecrew/mihomo:1.19.33 generate vless-mlkem768
```

`-t` and `convert-ruleset` work the same way.

## TUN and a transparent proxy: not yet

This version is a SOCKS and HTTP proxy only. TUN needs `CAP_NET_ADMIN` and
`/dev/net/tun`. A router's transparent proxy also needs `CAP_NET_RAW` and host
networking. A process running as uid 65532 gets those capabilities only from
file capabilities, which `no-new-privileges` disables. So the image stays at
65532, and the follow-up is expected to document TUN as `user: "0:0"` with
`cap_drop: [ALL]` and `cap_add: [NET_ADMIN]`. Nothing here blocks that, but it
is untested, including whether mihomo needs nothing beyond netlink on a base
without `iptables`.

## Versions

`MIHOMO_VERSION` in [`docker-bake.hcl`](../../docker-bake.hcl) is read from
GitHub releases, stable ones only. Upstream's one prerelease,
`Prerelease-Alpha`, is marked as one there, and its tag is not a version.

The upstream image is pinned by digest, `MIHOMO_IMAGE_DIGEST`, because each
upstream build fetches its geodata from `latest`. Two builds of one tag are not
the same image. Renovate moves the version and not the digest. Its pull request
fails `smoke.sh`, which compares the binary's version with the label, until the
digest is moved in both `docker-bake.hcl` and the `Dockerfile`:

```sh
docker buildx imagetools inspect docker.io/metacubex/mihomo:v<version> \
  --format '{{json .Manifest.Digest}}'
```

The build checks upstream's binary from its own build information. It must be
a `CGO_ENABLED=0` build, because the base has no libc. On amd64 it must also be
the `GOAMD64=v1` baseline build, which runs on any x86-64 CPU. Either check
fails the build if upstream changes the binary it ships.

The distroless base is not pinned, so the weekly rebuild brings its CA bundle
and tzdata current.

## Layout

- `Dockerfile`: the upstream stage pinned by digest, the entrypoint build (its
  tests and the shared module's run there), the check on upstream's binary,
  and the distroless runtime.
- `entrypoint/`: `mihomo-entrypoint`, standard library only, and its tests.
  The resolver, the summary and the healthcheck live in
  [`shared/go/envconf`](../../shared/go/envconf), which xray uses too.
- `smoke.sh`: rootless Podman. It covers a subscription URL from a secret
  fetched from a local server, a rule provider from `/run/secrets`, the pinned
  geodata in a fresh home, the healthcheck, the refusals, and checks that the
  subscription URL appears in no output.
