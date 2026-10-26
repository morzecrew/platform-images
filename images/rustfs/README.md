# rustfs

`ghcr.io/morzecrew/rustfs`

> **Two credentials are required, and the console is off.** Upstream warns about
> a missing or default `rustfsadmin` credential and starts anyway; this image
> refuses. Every deployment needs `RUSTFS_ACCESS_KEY` and `RUSTFS_SECRET_KEY`
> (or their `_FILE` forms) before it will boot.

[RustFS](https://github.com/rustfs/rustfs) is S3-compatible object storage
written in Rust. This image runs upstream's `rustfs/rustfs` unmodified —
same binary, same uid 10001, same `/data` volume, same
`/entrypoint.sh` — and adds the environment contract from
[images/README.md](../README.md#environment-configuration): three changed
defaults, one required credential source, and an allowlisted passthrough
channel. It starts as root only to read the credential files, and drops to
uid 10001 before upstream's script runs.

The upstream image it builds on is pinned by `RUSTFS_VERSION` in
[`docker-bake.hcl`](../../docker-bake.hcl), a Renovate-tracked variable. The
image's tag is that version.

## The three defaults

| | Default | Upstream | Why |
|---|---|---|---|
| `RUSTFS_ADDRESS` | `:9000` | `:9000` | Named so the bind is a setting an operator can see and move, not something inherited by accident |
| `RUSTFS_CONSOLE_ENABLE` | `false` | `true` | The console is a second HTTP surface on 9001 with its own authentication. Nothing here needs it, so nothing listens until a deployment asks |
| `RUSTFS_OBS_LOG_DIRECTORY` | empty | `/logs` | A non-empty directory is where the server writes its log *instead of* stdout. Emptied, `docker logs` carries the server's own lines |

The last one is the reason this image exists as more than a pin: with upstream's
default, `docker logs` shows the entrypoint's three lines and then goes quiet
while the server logs to a file nobody is reading.

`RUSTFS_CONSOLE_ENABLE=true` turns the console back on and `RUSTFS_CONSOLE_ADDRESS`
moves it; both are reachable through the passthrough channel below.

## Credentials

`RUSTFS_ACCESS_KEY` and `RUSTFS_SECRET_KEY` are upstream's names, and they are
**required**. Each may be given as a value or as `<NAME>_FILE`:

```yaml
environment:
  RUSTFS_ACCESS_KEY_FILE: /run/secrets/rustfs_access
  RUSTFS_SECRET_KEY_FILE: /run/secrets/rustfs_secret
```

Startup aborts when either is

- missing or empty, or
- upstream's built-in default, `rustfsadmin`, or
- given as a `_FILE` that is missing, unreadable, a directory, over 64 KiB, not
  UTF-8 or holding a NUL byte (exit 78, `EX_CONFIG`, naming the variable and
  path but never the content), or
- given as a value **and** a file at once — upstream's own refusal, kept as it
  is.

### Reading the files, and the drop to uid 10001

The container **starts as root**, and its entrypoint drops to uid 10001 with
`setpriv` before upstream's `/entrypoint.sh` runs, so the server itself never
runs as root. What the root start buys is that a credential file may be **owned
by any uid, at any mode root can read**: a Kubernetes secret, or a file an init
container wrote, is typically mode 0400 and belongs to somebody else, and uid
10001 could not open it at all.

Started as root, the entrypoint reads each file, exports its content to the
server as `RUSTFS_ACCESS_KEY` / `RUSTFS_SECRET_KEY`, and unsets the `_FILE`
pair, so upstream's script and the server see one credential, as a value. It is
the file's **first line**, with carriage returns removed and surrounding
whitespace trimmed — the same reading upstream's own script does — so a
CRLF-edited or newline-terminated secret file is accepted and the terminator is
not part of the credential.

A container started with `user:` (any uid other than 0) takes the other path: it
runs as that user throughout and execs upstream's entrypoint unchanged. Nothing
is read on its behalf, so **both `_FILE`s must be readable by that user** — pass
a 65532-owned 0400 file to `user: 10001` and it exits 78 naming the unreadable
`_FILE`, while a world-readable one works as before.

Choose between the paths by what the value may touch. The root start reaches a
file its own user cannot, and pays for it by putting the value in the
container's process environment. `user:` keeps the value out of the environment
— the `_FILE` stays a path, and `docker inspect` reports it rather than the
value — and needs the files readable by that user. Either way the startup
summary prints both key names and redacts both values.

**`RUSTFS_ROOT_USER`, `RUSTFS_ROOT_PASSWORD`, `MINIO_ROOT_USER` and
`MINIO_ROOT_PASSWORD` are refused.** Upstream accepts them as pre-rename
aliases and does not report which one won; with two credential channels there
is no longer one place a credential comes from.

## Environment

Two channels, per the [shared contract](../README.md#environment-configuration):
the curated upstream names above, and `RUSTFS_CONF__<key>` passthrough for
anything in [`rootfs/allowlist.conf`](rootfs/allowlist.conf).

| Variable | Default | Notes |
|---|---|---|
| `RUSTFS_ADDRESS` | `:9000` | |
| `RUSTFS_CONSOLE_ENABLE` | `false` | `true` puts the console back on 9001 |
| `RUSTFS_OBS_LOG_DIRECTORY` | empty (stdout) | A path sends the log to a file in the container |
| `RUSTFS_ACCESS_KEY` / `RUSTFS_SECRET_KEY` | **required** | Prefer the `_FILE` forms |
| `RUSTFS_CONF__<key>` | — | Must be in the allowlist; `RUSTFS_CONF__VOLUMES` and the credential names are refused outright |
| `RUSTFS_CONF_STRICT` | `fail` | `ignore` warns instead of aborting on an unknown key |
| `RUSTFS_CONF_ALLOWLIST` | `/etc/rustfs/allowlist.conf` | Widen the curated set without rebuilding |

The allowlist is a guard rail against typos and drift, not a security boundary:
`RUSTFS_CONF_ALLOWLIST` and `RUSTFS_CONF_STRICT` are themselves environment
variables. It stops short of upstream's internals — the internode, allocator,
object-lock, drive-health and per-backend audit/notification namespaces are not
listed — and a new upstream setting needs an allowlist edit before it can be
reached by name.

## Refusals

Beside the credential rules, three settings are refused through the passthrough
channel whatever the allowlist says:

- **`VOLUMES`** — the data directory is this image's contract with its `/data`
  volume mount. Moving it silently strands existing data at the old path.
- **`TLS_KEYLOG`** — writes every TLS session key to the named file, which
  decrypts traffic captured from the same process.
- **`UNSAFE_BYPASS_DISK_CHECK`** — skips the disk check that stops the server
  from claiming a filesystem it cannot store data on; the failure it suppresses
  is discovered later, as corrupt objects.
- **`KMS_ALLOW_INSECURE_DEV_DEFAULTS`** — accepts upstream's development key
  material, which is to say predictable keys, under a name that reads like a
  convenience.

## Data

`/data`, declared as a volume by the base image and left alone. The image
**creates no bucket**: a bucket is an application's decision, and an image that
invents one makes every deployment carry a name nobody chose. Create yours with
any S3 client after the server is up.

## Health checks

`/health/live`, `/health/ready` and `/minio/health/live` all answer 200 on the
API port once the server is up. Use **`/health/ready`**:

```yaml
healthcheck:
  test: ["CMD", "curl", "-fsS", "http://127.0.0.1:9000/health/ready"]
  interval: 10s
  timeout: 3s
  retries: 5
```

`/health/live` proves the process answers, not that storage is ready; `/health/ready`
is the one that withdraws when it is not. The console port, when enabled, serves
the same probes.

## Configuration and startup summary

There is no config file and no mounted layer: the defaults are the image's
`ENV` and everything else is the environment. The summary says so, rather than
naming layers this image does not have, and attributes every curated value
`env-or-default` — the process environment cannot tell a value set in the
Dockerfile from one set by an operator, and inventing attribution it cannot
compute would be printing a guess (RFC 0001 decision 13).

```text
[envconf] RUSTFS: effective configuration
[envconf]   source=env-or-default RUSTFS_ADDRESS = :9000                     (RUSTFS_ADDRESS)
[envconf]   source=env-or-default RUSTFS_CONSOLE_ENABLE = false              (RUSTFS_CONSOLE_ENABLE)
[envconf]   source=baked        RUSTFS_OBS_LOG_DIRECTORY =
[envconf]   source=env          RUSTFS_ACCESS_KEY = <redacted>               (RUSTFS_ACCESS_KEY_FILE=/run/secrets/rustfs_access)
[envconf]   source=env          RUSTFS_SECRET_KEY = <redacted>               (RUSTFS_SECRET_KEY_FILE=/run/secrets/rustfs_secret)
[envconf]   source=env          RUSTFS_REGION = eu-west-1                    (RUSTFS_CONF__REGION)
[envconf] precedence: image default < environment
```

## Usage

```yaml
services:
  objects:
    image: ghcr.io/morzecrew/rustfs:1.0.1
    environment:
      RUSTFS_ACCESS_KEY_FILE: /run/secrets/rustfs_access
      RUSTFS_SECRET_KEY_FILE: /run/secrets/rustfs_secret
      RUSTFS_CONF__region: eu-west-1        # one upstream setting, verbatim
    secrets: [rustfs_access, rustfs_secret]
    volumes: [objects-data:/data]
    healthcheck:
      test: ["CMD", "curl", "-fsS", "http://127.0.0.1:9000/health/ready"]
      interval: 10s
      timeout: 3s
      retries: 5

secrets:
  rustfs_access:
    file: ./rustfs_access.txt
  rustfs_secret:
    file: ./rustfs_secret.txt

volumes:
  objects-data:
```

Each credential needs both lines: `secrets:` mounts the file and
`RUSTFS_<NAME>_FILE` points the image at it. With only the first, the container
exits 1 for a missing credential; with only the second, it exits 78 for an
unreadable file. The named volume keeps objects across `docker compose down`.