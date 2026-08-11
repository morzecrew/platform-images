# RFC 0007 — ClickHouse image

- **Status:** 📝 Draft — **demand-gated**, not scheduled. Highest maintenance load
  of the four candidates by a wide margin.
- **Gate:** Analytics is in the stack **and has a named owner**. Not "we might do
  analytics" — a person who will read ClickHouse release notes. ClickHouse's
  release cadence is fast, its config surface is enormous, and its defaults
  assume a machine that is entirely its own rather than a container sharing a
  host. Without an owner this image goes stale in a way that is worse than absent,
  because it makes claims about defaults that stop being true.
- **Scope:** A single-node `clickhouse-server` image whose contribution is
  container-sane defaults: memory and cache sizes for a shared host, stdout
  logging, and a default user profile with memory and time limits. Covers YAML
  overlays in `config.d/` and `users.d/` with `from_env` references, the env
  surface, and a documented diff from upstream defaults. Does **not** cover
  clustering, Keeper, replication, schema, migrations, or a UI.
- **Related:** [docker-bake.hcl](../docker-bake.hcl) —
  `CLICKHOUSE_JDBC_VERSION` is already a flyway build arg (§3);
  [images/flyway/Dockerfile](../images/flyway/Dockerfile); RFC 0001 (env
  contract), RFC 0002 (attestations, smoke tests), RFC 0003 (the admission bar
  this gate applies).
- **Origin:** `candidate-images.md` §4.

---

## 1. Summary

If the gate opens: pin `clickhouse/clickhouse-server` to a specific minor, ship
YAML overlays in `config.d/` and `users.d/` whose varying values are `from_env`
references, size the memory ratio and caches for a container sharing a host, log
to stdout, and give the default user profile a memory limit and a query timeout.
Pass upstream's own `CLICKHOUSE_*` variables through untouched. The deliverable
that matters most is a table of what was changed from upstream and why.

## 2. Motivation

Two problems, both real, and only the second is worth an image.

**Config is XML**, which is miserable to template, mount, or diff. That alone
would not justify anything — nobody edits ClickHouse XML twice, they copy a file.

**Upstream defaults assume a dedicated machine.** Memory limits, thread pools,
mark and uncompressed cache sizes are all sized for a node that is entirely
ClickHouse's. In a Compose deployment sharing a host with Postgres and an
application, those defaults fight everything else, and the symptom is the other
services degrading rather than ClickHouse complaining. Sizing them for a shared
host is the curation worth sharing, and it is the same argument that makes RFC
0006's `maxmemory` the one thing that image is for.

The trap in both cases is the same: an image whose value is defaults is an image
whose value expires. See §9.

## 3. Current state

Nothing exists in this repo — with one exception that cuts both ways.

**The flyway image already bundles a ClickHouse JDBC driver.**
[docker-bake.hcl](../docker-bake.hcl) pins
`CLICKHOUSE_JDBC_VERSION = "0.9.8"` with a Renovate annotation, and
[images/flyway/Dockerfile:13-14](../images/flyway/Dockerfile#L13-L14) fetches
`clickhouse-jdbc-<v>-all.jar` into `/flyway/drivers`. So somebody expected
ClickHouse migrations. That is the strongest evidence in the repo that the gate
may already be met — and it is equally consistent with a driver added
speculatively alongside the Postgres one. **Ask; do not infer.** If the driver
has a live consumer, the gate is met and this RFC has an owner. If it does not,
the driver is itself a candidate for RFC 0003's retirement rule.

Two upstream facts shrink the work considerably, and both need verification
against the pinned version (§10):

- **`from_env` on config elements** — `<max_connections from_env="CH_MAX_CONNECTIONS"/>`
  — so the env plumbing is native, like the Collector's, and no templating engine
  is required.
- **Recent versions accept YAML config** in `config.d/`, which removes most of the
  XML misery for anything baked in.

Between them, this image is again mostly curation.

## 4. Goals / Non-goals

**Goals**

- ClickHouse that shares a host without starving its neighbours.
- One bad query that cannot take the server down.
- Logs where every other container puts them.
- A written, maintained diff from upstream defaults.

**Non-goals**

- **Cluster, ZooKeeper/Keeper, replication.** Single node. Distributed ClickHouse
  is an operations discipline, not an image.
- **Schema, migrations, or a bundled UI.** Migrations are flyway's job and the
  driver is already there (§3).
- **Table engines requiring external credentials** (S3, Kafka). The engines exist
  upstream; wiring them is a project's business, and baking credentials anywhere
  near an image built by RFC 0002's `mode=max` provenance is a bad idea twice
  over.
- **Stateful upgrade support.** Named explicitly because the image would
  otherwise imply one — see §9.

## 5. Design

### 5.1 Base and overlays

`FROM clickhouse/clickhouse-server:<pinned minor>`, pinned hard: this is not an
image to float a major on, and the LTS series is preferred over latest. The
overlays ship in `rootfs/`:

- `config.d/10-container.yaml` — memory ratio, cache sizes, pool sizes, log
  destination.
- `users.d/10-profile.yaml` — the default profile's per-query memory limit and
  execution timeout.

Both YAML, both with `from_env` references for the values that vary. Nothing is
templated and nothing is generated: the file that ships is the file that runs,
which is what makes §7's diff table verifiable.

### 5.2 Container-sane defaults

The whole point, and every value here is a claim that needs measuring (§10):

- `max_server_memory_usage_to_ram_ratio` — sized for a host ClickHouse shares.
- `mark_cache_size`, `uncompressed_cache_size` — upstream's are generous for a
  dedicated node and are pure overhead on a shared one.
- `background_pool_size`, `max_concurrent_queries` — bounded so merges and
  concurrency cannot consume the host's CPU budget.
- **Logging to stdout**, not to upstream's file paths, with the level from env.
  Every other image in this repo logs to stdout; a container writing logs into
  its own filesystem is a container whose logs are lost on restart.

### 5.3 The default user profile

`users.d/10-profile.yaml` sets a per-query memory limit and `max_execution_time`
on the default profile, on by default. One analyst query should not be able to
take the server down, and the profile is where that is expressible without
touching any query.

This is the second-most valuable thing in the image after §5.2, and it is the one
most likely to be removed by someone debugging a legitimately slow query. The
README says so, with the variable to raise rather than the file to delete.

### 5.4 Env surface

Curated: `CH_MEMORY_RATIO`, `CH_MAX_CONCURRENT_QUERIES`, `CH_MARK_CACHE_MB`,
`CH_LOG_LEVEL`, `CH_MAX_QUERY_MEMORY`, `CH_MAX_EXECUTION_TIME`.

Upstream: `CLICKHOUSE_DB`, `CLICKHOUSE_USER`, `CLICKHOUSE_PASSWORD`,
`CLICKHOUSE_DEFAULT_ACCESS_MANAGEMENT` and anything else upstream's entrypoint
owns — **passed through unchanged and never shadowed**. A variable that upstream
owns and this image redefines is the worst possible failure in this repo: it
breaks the reader's ability to trust any upstream documentation.

**Passthrough, with a split RFC 0005 does not have.** Server config is nested and
does not flatten honestly. But *settings* — the profile-level knobs like
`max_execution_time`, `max_bytes_before_external_group_by` — are genuinely flat
key-value, so a passthrough channel over them is coherent.

That channel is **`CH_CONF__<name>`**, the spelling RFC 0001 decision 1 locks,
not a bespoke `CH_SETTING__`. A second prefix form would mean the shared helper
does not recognize this image's passthrough — the contract is `<PREFIX>_CONF__`
or it is not a contract, and inventing a synonym for one image is how a shared
mechanism becomes two mechanisms. What is specific to ClickHouse is only the
*target*: `CH_CONF__<name>` writes into the default user profile in
`users.d/`, never into server config. The README states that mapping explicitly,
because a reader who expects `CH_CONF__max_connections` to reach a server setting
will otherwise be surprised by silence.

### Alternatives considered

- **XML overlays instead of YAML.** Guaranteed to work, universally documented,
  and unreadable in a diff. Chosen against on the assumption that YAML is fully
  equivalent in the pinned version — §10 question 2, and the fallback is XML.
- **A generated config from a template.** Rejected: `from_env` is native and RFC
  0001 decision 5 forbids the templating engine anyway.
- **Shipping no defaults, just the env surface.** That is upstream plus
  ceremony. The defaults are the deliverable.
- **Floating on the LTS major.** Rejected — ClickHouse's on-disk format is
  version-sensitive (§9) and an automatic major bump is a data risk.

## 6. Tests

Per RFC 0002 §5.5:

- Starts with no configuration and answers a trivial query over HTTP.
- The effective values of every §5.2 setting are read back from
  `system.settings` / `system.server_settings` and compared to the intended
  ones — this is what proves the YAML overlay and `from_env` actually took
  effect, rather than being silently ignored in favour of upstream's XML.
- A `CH_*` variable changes the corresponding effective setting.
- A query exceeding `CH_MAX_QUERY_MEMORY` is refused rather than killing the
  server.
- A query exceeding `CH_MAX_EXECUTION_TIME` is cancelled.
- Logs appear on stdout and no log file is written under the data directory.
- Upstream's `CLICKHOUSE_DB`/`CLICKHOUSE_USER`/`CLICKHOUSE_PASSWORD` behave
  exactly as they do on the upstream image — the non-shadowing decision needs a
  test, not just an intention.

The "read the effective value back" family is the important one. A YAML overlay
that ClickHouse silently ignores looks identical to one that works, right up
until production.

## 7. Docs

`images/clickhouse/README.md`, and for this image the **"what we changed from
upstream defaults, and why" table is the deliverable** — not an appendix to it.
It is what a future reader needs when a query behaves differently here than on a
vanilla install, and answering that question without the table means diffing two
config trees under time pressure.

Each row: setting, upstream default, our value, reason, and the env variable that
overrides it.

Also required:

- The upgrade caveat (§9), stated as a limitation rather than implied by silence.
- Which of the two config surfaces has a passthrough channel and which does not
  (§5.4).
- The profile limits, with the variable to raise rather than the file to delete.

## 8. Out of scope

- **Tuning for any specific workload.** The defaults target "shares a host with
  other services"; a project with a dedicated node should raise them, and the
  README says which.
- **Backup and restore.** `BACKUP`/`RESTORE` exist upstream; the destination is a
  platform decision.
- **Query result caching, projections, materialized views.** Schema-level
  concerns.
- **A second variant sized for a dedicated node.** Plausible, and it would double
  the §7 table's maintenance. Named as the escape hatch, not built.

## 9. Risks

- **Defaults drift with upstream releases**, so §7's table goes stale silently
  and the image starts claiming differences that no longer exist. This is the
  characteristic failure of a curation image and it has no clean mitigation
  beyond the named owner in the gate. The table should carry the ClickHouse
  version it was verified against, so staleness is at least visible.
- **Upgrade path.** ClickHouse's on-disk format is version-sensitive and
  downgrades are generally not supported. This repo has no story for stateful
  upgrade — for any image — and here the consequence is a data directory that a
  rolled-back tag cannot read. RFC 0002's mutable tags plus a weekly rebuild make
  it possible to move minor versions without noticing, which is fine within a
  pinned minor and is exactly why decision 4 pins hard.
- **The maintenance load is the real risk.** Four images at this cadence is a
  part-time job; this one alone might be half of it. That is the gate's entire
  justification.
- **Guessed cache sizes are worse than upstream's guessed cache sizes.** Upstream
  at least guessed with a benchmark. Numbers that have not been measured under a
  real workload should ship as upstream's until they have (§10 question 3).
- **Silently ignored overlays** (§6). Mitigated only by reading effective values
  back in tests.

## 10. Unresolved questions

1. **Does the flyway ClickHouse driver have a live consumer?** This answers the
   gate (§3) and costs one conversation.
2. **Is YAML config fully equivalent to XML in the pinned version**, or do some
   settings remain XML-only? Determines whether §5.1 ships YAML or falls back to
   XML.
3. **Which config keys actually accept `from_env` in the pinned version?**
   Coverage is not complete, and the gaps determine the env surface — a curated
   variable whose setting cannot read `from_env` has to be dropped or implemented
   another way.
4. **Do `from_env` and YAML compose?** Both are documented individually; the
   attribute syntax that expresses `from_env` in YAML is the intersection nobody
   checks. If they do not compose, the design is XML overlays with `from_env`,
   and §5.1's YAML rationale disappears.
5. **Real memory behaviour under the intended workload** with the ratio defaults.

Questions 2 and 4 together decide the file format. They are cheap to answer with
one container and thirty minutes, and they should be answered before P1 is
scoped, not during it.

## 11. Decisions

| # | Grade | Decision |
| --- | --- | --- |
| 1 | `LOCKED` | Upstream's `CLICKHOUSE_*` variables are passed through unchanged and never shadowed. Consequence: our curated names all take the `CH_` prefix, and any future collision is resolved by renaming ours. |
| 2 | `LOCKED` | A default user profile with memory and execution-time limits, on by default. Removing it is the documented-but-discouraged action; loosening it is the supported one. |
| 3 | `LOCKED` | No template rendering. Native `from_env` only (RFC 0001 decision 5). |
| 4 | `LOCKED` | Pinned to a specific minor, LTS series preferred over latest. Consequence: a ClickHouse security fix in a newer minor requires a deliberate bump — accepted, because the on-disk format makes automatic movement a data risk (§9). |
| 5 | `LOCKED` | Logs to stdout. |
| 6 | `ASSUMED` | YAML overlays in `config.d/` and `users.d/`. Depart to XML if §10 questions 2 or 4 come back negative — the overlay content is unaffected, only its syntax. |
| 7 | `ASSUMED` | `CH_CONF__<name>` — RFC 0001's locked spelling — passes through to **profile settings only**; server config has no passthrough (§5.4). Depart on the scope if profile settings turn out not to be as flat as they look; do not depart on the spelling, which is not this RFC's to change. |
| 8 | `OPEN` | The actual numbers for every §5.2 default. Each must be measured (§10 question 3); an unmeasured number ships as upstream's value, not as a guess. Log each chosen number with the measurement that justified it — those become §7's table. |
| 9 | `OPEN` | Whether the §7 table is maintained by hand or generated by diffing effective settings against a vanilla container. Generated would not go stale, which is §9's main risk; it is also a small tool nobody asked for. |

## 12. Phasing

- **P1 — pin, overlay, container-sane memory defaults, stdout logging.** Blocked
  on §10 questions 2–4.
- **P2 — user profile limits and the env surface.**
- **P3 — the "what we changed and why" table.** For this image the table is the
  deliverable, and P3 is not optional polish; an image shipped without it is an
  image whose value cannot be verified by its user.

Gated throughout on a named owner. Absent one, this RFC stays Draft — which,
given the maintenance estimate in §9, is the expected outcome.
