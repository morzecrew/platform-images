# RFC 0006 — Valkey image

- **Status:** 📝 Draft — **admitted 2026-08-12.** Demand measured (§3.1: 14
  projects, four distinct upstream references, three pinned and one floating),
  and RFC 0003 gained a second admission route
  (its decision 9) that this image meets on drift rather than duplication. The
  gate is open and the design is unbuilt; what remains is §10's questions and a
  decision on scheduling.
- **Gate:** ~~Answer RFC 0004's question first: if Postgres with pgmq covers the
  queue and Postgres or the application covers the cache, this image should not
  exist.~~ **Answered and opened 2026-08-12.** pgmq is in zero repositories, so
  the queue half of the question was moot; the cache half measured 14 projects
  across four pinned images (§3.1), and RFC 0003's second admission route admits
  it on that drift (§3.2). The gate as written is kept struck through rather than
  deleted, because the reasoning it encodes — that an explicit refusal beats a
  silently absent image — is why the question was worth asking.
- **Scope:** A single-node Valkey image whose value is its defaults: a finite
  `maxmemory` with an eviction policy, persistence off behind one explicit
  switch, secrets from files, and an allowlist-generated `valkey.conf` sharing
  RFC 0001's helper. Covers the defaults, the env surface, and the refusal rules
  that keep the cache and durable-store roles from being silently mixed. Does
  **not** cover clustering, Sentinel, replication, or modules.
- **Related:** RFC 0001 (this image is intended as the helper's first consumer),
  RFC 0004 (its gate), RFC 0003 (admission), RFC 0002 (smoke tests),
  [images/postgres/rootfs/entrypoint.sh](../images/postgres/rootfs/entrypoint.sh)
  (the allowlist pattern being generalized).
- **Origin:** `candidate-images.md` §3.

---

## 1. Summary

If the gate opens: package `valkey/valkey` with a generated `valkey.conf`, a
finite `maxmemory` derived from the container's cgroup limit, an eviction policy,
persistence off behind `VALKEY_PERSISTENCE=off|rdb|aof`, and `_FILE`-first
secrets. The image exists to impose four defaults that upstream does not, and to
refuse two configurations that silently lose data.

If the gate stays shut: none of that is built, and the refusal is written into
[images/README.md](../images/README.md) with the reasoning, so the next person to
ask gets an answer instead of a shrug.

## 2. Motivation

**The service gap.** `postgres` carrying pgroonga and pg_cron
([Dockerfile:14-33](../images/postgres/Dockerfile#L14-L33)) is evidence of a
deliberate "Postgres is the platform" posture — search and scheduling both live
in the database. Cache is where that posture usually breaks: a hot key-value read
path against Postgres has a real cost, and pgmq is a good queue but not a good
cache.

**The configuration gap.** Upstream Redis/Valkey images ignore the environment
entirely. Configuration is a `redis.conf` mount or a command line that grows to
two hundred characters in every Compose file anyone has ever written. This is the
most literal instance in the candidate set of the problem this repo exists to
solve.

But the configuration gap alone does not justify an image. If nothing needs a
cache, an elegantly configurable cache is an image maintained for nobody — and
RFC 0003 counts eight edits and a permanent CVE subscription for that privilege.
Hence the gate.

## 3. Current state

Nothing exists in this repo, and the repo's shape is the argument on both sides:

- **For:** `postgres` is the only stateful service image, and the allowlist
  mechanism it already ships ([entrypoint.sh](../images/postgres/rootfs/entrypoint.sh))
  is exactly what Valkey needs. Two images sharing one contract is RFC 0001's
  entire thesis, and RFC 0001 §12 explicitly wants a *new* image as the shared
  helper's first consumer rather than retrofitting `postgres` blind.
- **Against:** `postgres` today has neither pgmq nor pgvector, and RFC 0004 §10
  records that whether pgmq is even apt-installable for the pinned major is
  unmeasured. So the "Postgres covers it" claim is currently untested in both
  directions.

### 3.1 The demand, measured (2026-08-12)

Swept every Morze repository for a Redis or Valkey **service** in a compose file.

**Fourteen repositories run one**: `backend-template`, `demo-ai-consultant`,
`eis-backend`, `erp-backend`, `erp-standalone`, `fashion-ai-mvp`, `forze`,
`morze-ai-chat-backend`, `morze-crm-backend`, `morze-crm-backend-v2`,
`morze-erp-backend`, `morze-erp-infrastructure`, `samolet-ai-mvp`,
`test-livekit`.

Across them, **four distinct upstream image references** are in use:
`redis:7-alpine` (floating minor), `redis:7.2.3-alpine`, `redis:8.0.3-alpine`,
and `valkey/valkey:9.0` — somebody has already migrated to Valkey without a
shared image to land on. Three are pinned and one floats, which is itself part
of the divergence: the projects on `redis:7-alpine` are not on a version anyone
chose, and cannot say which one they are running.

That drift is what this repo exists to remove, and **the cache requirement is not
hypothetical**: it is in more projects than any image currently published here.

**pgmq appears in zero repositories.** The gate as originally written — "does
Postgres with pgmq cover the queue" — is therefore moot: no project runs a queue
on pgmq, and what was measured is demand for a *cache*, not a queue. RFC 0004's
packaging question no longer blocks this RFC.

### 3.2 Why the admission bar does not fit, and what to do about it

**No project hand-rolls a Dockerfile for Redis or Valkey.** All fourteen consume
an upstream image directly and configure it through compose — a `command:` line
or a mounted `redis.conf`.

Read literally, RFC 0003's bar therefore **refuses this image**: the bar counts
hand-rolled Dockerfiles, and there are none. Read for its purpose — two or more
projects having separately solved the same problem — it is met several times
over, because fourteen compose files each re-solve configuration.

That is a defect in the bar, not a verdict on this image. RFC 0003's rule is
Dockerfile-shaped, and the contribution of a *configuration-curation* image is
config-shaped; an image whose whole value is defaults will never appear as a
duplicated Dockerfile.

> **Settled 2026-08-12.** RFC 0003 decision 9 adds a second admission route: two
> or more projects running the same upstream image whose pinned versions or
> configuration have diverged. This image meets it — fourteen projects, four
> distinct upstream references (three pinned, one floating), and a Valkey
> migration already begun in one of them.
> **The gate is open.** Note what did not happen: decision 1 was not widened, so
> route 1 still means what it meant, and RFC 0005 is still refused because zero
> projects cannot diverge.

## 4. Goals / Non-goals

**Goals**

- A Valkey that cannot eat the host.
- One explicit decision — cache or durable store — that the operator must make in
  words, not by omission.
- A supported path by which secrets do not travel in `docker inspect` output.
  `VALKEY_PASSWORD_FILE` is that path; `VALKEY_PASSWORD` stays supported for
  compatibility and remains inspect-visible, so the guarantee is conditional on
  which one an operator uses and the README says exactly that (§7).
- Second consumer of RFC 0001's contract, proving it is a contract rather than a
  description of `postgres`.

**Non-goals**

- **Cluster mode, Sentinel, replication topology.** Single node. This repo ships
  images, not topologies, and a half-configured Sentinel is worse than none.
  *Reopens if* a project genuinely runs multi-node — at which point the honest
  answer may be a managed service.
- **Modules** (search, JSON, timeseries). Licensing is a minefield and pgroonga
  already declares where search lives in this stack.
- **A `redis` compatibility alias tag.** The binary is protocol-compatible; a
  second name is a second thing to keep true, and RFC 0002's tag policy would
  have to describe both.
- **Being a queue.** See §5.3 — the defaults that make this a good cache make it
  a dangerous queue, and the image takes a side.

## 5. Design

### 5.1 Generated config, shared helper

`FROM valkey/valkey:<pinned>` (Alpine variant, so RFC 0001's POSIX-`sh` helper
runs unmodified — see RFC 0001 decision 7). The entrypoint sources
`envconf.sh`, loads `rootfs/allowlist.conf`, collects `VALKEY_CONF__*`, renders
`valkey.conf`, prints the startup summary, and execs the server.

The allowlist mechanism is **shared with `postgres`, not copied**. If it cannot
be shared, RFC 0001 was not actually done, and that is the signal to stop and
fix RFC 0001 rather than to fork the helper.

### 5.2 The four defaults

These are the image. Everything else is plumbing.

**1. A finite `maxmemory`.** Upstream's default is unlimited, which is a
machine-killer in a container sharing a host. The value is derived at startup,
in this order:

1. `VALKEY_MAXMEMORY` if set — an explicit value always wins.
2. Otherwise a percentage (`VALKEY_MAXMEMORY_PERCENT`, default 75) of the
   container's memory limit, read from cgroup v2 `/sys/fs/cgroup/memory.max`.
3. If that file is absent or reads `max` — an unconstrained container, or cgroup
   v1 — a conservative fixed fallback, and a **warning naming the reason**.

Deriving from the cgroup rather than shipping a fixed number is what makes the
default correct on a 512 MB container and on a 32 GB one. The fallback path is
the one that will actually be hit in unusual environments, so it warns rather
than proceeding quietly. Rootless Podman (RFC 0002 §5.5) is cgroup v2, which
makes the primary path the tested one.

**2. An eviction policy**, `allkeys-lru`, because `maxmemory` without a policy
turns a memory limit into write errors.

**3. Persistence off**, behind `VALKEY_PERSISTENCE=off|rdb|aof` — one switch,
three values, never five interacting variables. `off` is an explicit word, never
an empty default, because the variable name is the mitigation for the naive user
who expected a durable store.

**4. Secrets from files first.** `VALKEY_PASSWORD_FILE` before `VALKEY_PASSWORD`,
per RFC 0001 decision 4, with an unreadable `_FILE` aborting rather than falling
back. Env vars leak into `docker inspect` output and crash dumps; morzer delivers
secrets as files or env by design, so the file path must be first-class.

Note what this does **not** claim. Keeping `VALKEY_PASSWORD` means a deployment
that uses it still exposes the password to anyone who can inspect the container;
precedence does not retract that. The plain variable stays because removing it
would break the ordinary Compose case for no gain the operator asked for, and the
startup summary names which of the two supplied the credential — so an operator
reading the log can see they took the visible path.

### 5.3 Two refusals

The defaults above are safe for a cache and actively wrong for anything durable.
Rather than documenting that and hoping, the entrypoint refuses two combinations
at startup:

- **`VALKEY_PERSISTENCE != off` together with an `allkeys-*` eviction policy.**
  This configuration says "keep my data" and "delete my data under pressure" at
  the same time, and the failure is silent and total. Refused, naming both
  settings and the two ways to resolve it.
- **`VALKEY_PERSISTENCE != off` with no `maxmemory-policy` set explicitly.** The
  image's own default would otherwise apply `allkeys-lru` to a durable store —
  the image causing the first refusal by itself. A durable configuration must
  name its policy, and `noeviction` is the one it almost certainly wants.

This is the same fail-closed instinct as RFC 0001 decision 2, applied to a
combination rather than a key.

**The queue consequence.** A job queue on Valkey needs `noeviction`; with
`allkeys-lru` it silently drops queued jobs under memory pressure. So this image
defaults to *cache*, and using it as a queue backend is an explicit
reconfiguration the refusals force into the open. That is also the honest answer
to the gate: if the requirement is a queue, the comparison is pgmq versus a
Valkey deliberately configured against its own defaults — which weakens the case
for this image rather than strengthening it.

### 5.4 Dangerous commands

`FLUSHALL`, `KEYS` and `CONFIG` renamed or disabled by default was the source
proposal. Partially adopted:

- **`FLUSHALL`, `FLUSHDB`, `KEYS`: renamed by default**, re-enableable by env.
  Low blast radius; nothing legitimate calls them in a hot path.
- **`CONFIG`: enabled by default**, opt-in to rename. Several widely-used queue
  and cache clients issue `CONFIG GET maxmemory-policy` at connect time
  specifically to warn about eviction risk, and disabling `CONFIG` breaks them or
  produces a confusing degraded mode. A default that breaks common clients is a
  default that gets removed wholesale, taking the `FLUSHALL` protection with it.

`protected-mode` on, and the bind behaviour stated explicitly in the README
rather than inherited silently.

### 5.5 Env surface, first cut

`VALKEY_PASSWORD` / `VALKEY_PASSWORD_FILE`, `VALKEY_MAXMEMORY`,
`VALKEY_MAXMEMORY_PERCENT`, `VALKEY_MAXMEMORY_POLICY`, `VALKEY_PERSISTENCE`,
`VALKEY_APPENDFSYNC`, `VALKEY_DATABASES`, `VALKEY_LOGLEVEL`,
`VALKEY_TCP_KEEPALIVE`, `VALKEY_RENAME_DANGEROUS`, plus `VALKEY_CONF__<key>` for
anything the allowlist permits (RFC 0001 §5.1).

Several curated names here have a passthrough spelling for the same setting —
`VALKEY_MAXMEMORY_POLICY` and `VALKEY_CONF__maxmemory_policy` are the same knob.
RFC 0001 decision 11 governs: setting both aborts startup naming both, rather
than one silently winning. This image is where that rule was found, so it is also
where it must be tested (§6).

### Alternatives considered

- **Redis instead of Valkey.** Licence trajectory, and Valkey is the distro and
  downstream default now. Not seriously contested.
- **No default `maxmemory`, document it instead.** That is upstream, and upstream
  is what produces the incident. The surprise of eviction is smaller than the
  surprise of an OOM-killed host.
- **A fixed `maxmemory` default** (say 512 MB). Simple, wrong at both ends of the
  range, and wrong quietly.
- **Two images, cache and store.** Doubles the maintenance to encode what one
  refusal encodes.

## 6. Tests

Per RFC 0002 §5.5:

- Starts with no configuration; `CONFIG GET maxmemory` is finite and
  `maxmemory-policy` is `allkeys-lru`.
- Under a 256 MB container limit, the derived `maxmemory` is ~75% of it — the
  cgroup path is the one most likely to be silently wrong.
- With no cgroup limit, the fallback applies **and warns**.
- `VALKEY_PASSWORD_FILE` beats `VALKEY_PASSWORD`; an unreadable `_FILE` exits
  non-zero.
- Both §5.3 refusals exit non-zero with both offending settings named.
- Setting `VALKEY_MAXMEMORY_POLICY` and `VALKEY_CONF__maxmemory_policy` together
  exits non-zero naming both (RFC 0001 decision 11).
- `VALKEY_PERSISTENCE=rdb` with `noeviction` starts and survives a restart with
  data intact — the durable path must be tested, not just permitted.
- Renamed commands are absent and `CONFIG GET` still works by default.
- The startup summary shows effective memory, eviction and persistence, and
  redacts the password.

## 7. Docs

`images/valkey/README.md` **leads with the non-upstream defaults**, before
anything else:

> This image sets a finite `maxmemory` and evicts. Upstream does not. If you are
> using this as a durable store, set `VALKEY_PERSISTENCE` and
> `VALKEY_MAXMEMORY_POLICY=noeviction` — the image refuses the unsafe
> combinations, but it defaults to being a cache.

Then the env table, the refusal rules with their exact messages, and the derived
`maxmemory` calculation including the fallback. A reader who skims must still
come away knowing the image evicts by default.

## 8. Out of scope

- **TLS termination.** Valkey supports it; certificate lifecycle is the
  platform's job and `caddy` already exists for edge TLS.
- **ACL users beyond the default password.** Reopens with a real multi-tenant
  consumer.
- **`VALKEY_CONF__` coverage of every tunable.** The allowlist starts small —
  memory, persistence, timeouts, logging — and grows on demand, per RFC 0001
  decision 2.
- **Benchmarks against pgmq/Postgres.** That comparison decides the gate (§10),
  and it belongs in the gate decision, not in this image's documentation.

## 9. Risks

- **Defaulting `maxmemory` will surprise someone** whose workload silently
  started evicting. Mitigated by the startup summary and by §7's lead paragraph;
  not eliminated. The alternative — unbounded growth — is worse.
- **Persistence off by default means a naive durable user loses data.** The
  explicit `off` value and §5.3's refusals are the mitigations; neither helps
  someone who never set the variable and never read the README, which is the
  residual risk this design accepts.
- **The cgroup path is environment-dependent.** cgroup v1 hosts, unusual runtimes
  and nested containers all land on the fallback. It warns; a warning in a log
  nobody reads is a partial mitigation at best.
- **Renaming commands breaks tooling in ways that are hard to diagnose** — an
  unrecognized-command error from a client library rarely names the server config
  as the cause. §5.4's `CONFIG` carve-out is the largest instance; the README
  must list every renamed command explicitly.
- **Building this image weakens the "Postgres is the platform" posture** the repo
  currently expresses. That is a real architectural cost and it is the reason the
  gate is not a formality.

## 10. Unresolved questions

1. **Does pgmq + Postgres cover the queue usage?** This decides whether the image
   is built at all. Blocked on RFC 0004 §10 (is pgmq even packaged for the pinned
   major) and on a real workload to compare against.
2. **Is there a cache requirement distinct from the queue one?** The two are
   usually conflated and §5.3 shows they want opposite settings. If only one
   exists, the answer is likely "not this image".
3. **Is RFC 0001's helper genuinely shareable**, or is it Postgres-specific in
   ways only a second consumer reveals? This image is how that gets answered,
   which is an argument for building it that has nothing to do with Valkey.
4. Whether Valkey's runtime `CONFIG SET` can drift from the generated conf, and
   whether that matters for restart semantics — a `CONFIG SET maxmemory` survives
   until restart and then silently reverts.

## 11. Decisions

| # | Grade | Decision |
| --- | --- | --- |
| 1 | `LOCKED` | A finite `maxmemory` and an eviction policy by default. The one non-upstream default this image exists to impose; without it there is no reason to build it. |
| 2 | `LOCKED` | Persistence is one switch with three values (`off\|rdb\|aof`), with `off` an explicit word rather than an empty default. |
| 3 | `LOCKED` | The allowlist helper is shared with `postgres` via RFC 0001, not copied. If it cannot be shared, stop and fix RFC 0001. |
| 4 | `LOCKED` | `_FILE` variants take precedence over plain env for every secret, with an unreadable `_FILE` aborting (RFC 0001 decision 4). |
| 5 | `LOCKED` | Valkey, not Redis. |
| 6 | `LOCKED` | The two §5.3 combinations are refused at startup, not documented and permitted. A durable store under `allkeys-lru` loses data silently, and silence is the failure this repo's images are supposed to remove. |
| 7 | `ASSUMED` | `maxmemory` derives from cgroup v2 `memory.max` at 75%, with a warned fallback. Depart on the percentage; do not depart on "warn when falling back". |
| 8 | `ASSUMED` | `CONFIG` stays enabled by default while `FLUSHALL`/`FLUSHDB`/`KEYS` are renamed (§5.4). Depart if no consumer's client library probes `CONFIG GET`. |
| 9 | `OPEN` | Alpine or Debian-slim base. Alpine keeps RFC 0001's POSIX-`sh` helper trivially satisfiable; if a consumer hits a musl-related issue, Debian-slim plus a shell is the fallback. |
| 10 | `OPEN` | The conservative fixed fallback value for `maxmemory` when no cgroup limit is readable. Pick it against a real host, and prefer embarrassingly small — an evicting cache is recoverable, an OOM-killed host is not. |

## 12. Phasing

- **P1 — the gate decision.** Written down either way, in
  [images/README.md](../images/README.md), with its reasoning. If refused, this
  RFC becomes ❌ Rejected, the file stays as the record, and **the phase was
  still worth running** — a written refusal is the deliverable.
- **P2 — the image**: shared helper, the four defaults, the two refusals,
  `_FILE` secrets. Gated on P1 and on RFC 0001 P2.
- **P3 — startup summary and README**, showing effective memory, eviction and
  persistence, because those three are what people get wrong and never check.
