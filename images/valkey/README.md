# valkey

`ghcr.io/morzecrew/valkey`

> **This image sets a finite `maxmemory` and evicts. Upstream does not.**
> If you are using this as a durable store, set `VALKEY_PERSISTENCE` and
> `VALKEY_MAXMEMORY_POLICY=noeviction` — the image refuses the unsafe
> combinations, but it defaults to being a **cache**.

Upstream's `maxmemory` default is unlimited, which on a shared host means the
process grows until the kernel kills something. This image derives a limit from
the container's own memory limit instead, and pairs it with an eviction policy,
because a `maxmemory` without a policy turns a memory limit into write errors.

Everything else here is plumbing around that one decision.

## The four defaults

| | Default | Why it is not upstream's |
|---|---|---|
| `maxmemory` | 75% of the cgroup v2 limit | A fixed number is wrong on a 512 MB container and on a 32 GB one |
| `maxmemory-policy` | `allkeys-lru` | `maxmemory` with no policy converts memory pressure into write errors |
| persistence | **off**, one switch | Five interacting variables is how people end up with neither durability nor a cache |
| secrets | `_FILE` first | Env vars are visible in `docker inspect` and crash dumps |

## Environment

Two channels, per the [shared contract](../README.md#environment-configuration):
curated `VALKEY_*` names below, and `VALKEY_CONF__<directive>` passthrough for
anything in [`rootfs/allowlist.conf`](rootfs/allowlist.conf).

| Variable | Default | Notes |
|---|---|---|
| `VALKEY_MAXMEMORY` | derived | An explicit value always wins over the derivation |
| `VALKEY_MAXMEMORY_PERCENT` | `75` | Percentage of the cgroup limit; 1–100 |
| `VALKEY_MAXMEMORY_POLICY` | `allkeys-lru` | Required to be explicit when persistence is on |
| `VALKEY_PERSISTENCE` | `off` | `off` \| `rdb` \| `aof` |
| `VALKEY_APPENDFSYNC` | `everysec` | Only meaningful with `VALKEY_PERSISTENCE=aof` |
| `VALKEY_PASSWORD` | unset | Visible in `docker inspect`; prefer the `_FILE` form |
| `VALKEY_PASSWORD_FILE` | unset | Wins over `VALKEY_PASSWORD`; unreadable ⇒ startup aborts |
| `VALKEY_DATABASES` | upstream | |
| `VALKEY_LOGLEVEL` | upstream | |
| `VALKEY_TCP_KEEPALIVE` | upstream | |
| `VALKEY_RENAME_DANGEROUS` | `FLUSHALL FLUSHDB KEYS` | The explicit list of commands to disable; empty disables none |
| `VALKEY_CONF__<directive>` | — | Must be in the allowlist |
| `VALKEY_CONF_STRICT` | `fail` | `ignore` warns instead of aborting on an unknown key |

`VALKEY_PASSWORD` is kept, and keeping it does not make it safe: a deployment
using it still exposes the password to anyone who can inspect the container.
The startup summary names which of the two supplied the credential, so a log
reader can see that the visible path was taken.

## How `maxmemory` is derived

1. `VALKEY_MAXMEMORY`, if set.
2. Otherwise `VALKEY_MAXMEMORY_PERCENT` (default 75) of `/sys/fs/cgroup/memory.max`.
3. Otherwise **268435456 (256 MiB)**, with a warning naming the reason.

Step 3 is reached on cgroup v1, in an unconstrained container, and where
`memory.max` reads `max`. It warns rather than proceeding quietly, because a
silent fallback to a small number looks exactly like a working cache until the
working set outgrows it. Set `VALKEY_MAXMEMORY` explicitly to make it a
decision rather than a default.

The percentage is applied by dividing before multiplying, so the derived value
can be up to 99 bytes under a strict 75%.

## The two refusals

Both are startup aborts, not warnings, because the failure they prevent is
silent and total.

**Persistence with an evicting policy.**

```
VALKEY_PERSISTENCE=rdb  VALKEY_MAXMEMORY_POLICY=allkeys-lru   ⇒ refused
```

Saying "keep my data" and "delete my data under pressure" at once. Resolve it
by setting `VALKEY_MAXMEMORY_POLICY=noeviction`, or `VALKEY_PERSISTENCE=off` if
this is a cache after all.

**Persistence without an explicit policy.**

```
VALKEY_PERSISTENCE=rdb                                        ⇒ refused
```

Otherwise the image's own `allkeys-lru` default would apply to a durable store
— the image causing the first refusal by itself. A durable configuration has to
name its policy, and `noeviction` is almost certainly the one it wants.

**Using this as a queue** means `noeviction`: under `allkeys-lru` a job queue
silently drops queued jobs under memory pressure. The refusals force that into
the open rather than leaving it to be discovered in production.

## Disabled commands

`FLUSHALL`, `FLUSHDB` and `KEYS` are disabled by default — nothing legitimate
calls them in a hot path, and the blast radius is total. Re-enable by narrowing
the list:

```bash
VALKEY_RENAME_DANGEROUS="FLUSHALL FLUSHDB"   # KEYS now usable
VALKEY_RENAME_DANGEROUS=""                   # all three usable
```

**`CONFIG` stays enabled**, deliberately. Widely-used cache and queue clients
call `CONFIG GET maxmemory-policy` at connect time specifically to warn about
eviction risk; disabling it breaks them or degrades them confusingly, and a
default that breaks common clients is one that gets removed wholesale — taking
the `FLUSHALL` protection with it. Add `CONFIG` to the list to opt in.

## Networking

`protected-mode` is on. The server binds all interfaces inside the container,
which is the normal container arrangement — reachability is the business of
your network, not of a bind address inside a namespace. Anything reachable
beyond a trusted network should set a password.

## Configuration precedence

Baked defaults, then any `*.conf` in `/etc/valkey/conf.d/`, then the
environment. Later wins, and the startup summary prints which layer each
setting came from:

```text
[envconf] VALKEY: effective non-default settings
[envconf]   source=derived   maxmemory = 201326550        (75% of cgroup memory.max)
[envconf]   source=baked     maxmemory-policy = allkeys-lru   (image default)
[envconf]   source=env       maxmemory-samples = 7        (VALKEY_CONF__maxmemory-samples)
[envconf] precedence: baked < mounted < env
```

The generated file lands at `/etc/valkey/valkey.conf` and is rewritten on every
start. Editing it is pointless; mount a fragment into `/etc/valkey/conf.d/`
instead.

## Data

`/data`, declared as a volume. `dir` is denylisted, so it cannot be pointed
elsewhere by environment — moving it would silently strand existing data.

## Usage

```yaml
services:
  cache:
    image: ghcr.io/morzecrew/valkey:9.0
    environment:
      VALKEY_MAXMEMORY_PERCENT: "60"
    secrets: [valkey_password]
    mem_limit: 512m

  queue:
    image: ghcr.io/morzecrew/valkey:9.0
    environment:
      VALKEY_PERSISTENCE: aof
      VALKEY_MAXMEMORY_POLICY: noeviction   # required; see the refusals
      VALKEY_PASSWORD_FILE: /run/secrets/valkey_password
```
