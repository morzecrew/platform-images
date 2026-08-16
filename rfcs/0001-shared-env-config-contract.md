# RFC 0001 — Shared env-config contract

- **Status:** 🚧 In progress — **P1 shipped 2026-08-16** (the contract in
  [images/README.md](../images/README.md)); **P2 shipped 2026-08-16** — the
  helper is [shared/rootfs/lib/envconf.sh](../shared/rootfs/lib/envconf.sh),
  distributed by a bake named context and exercised by the new `valkey` image,
  with its own suite at `shared/test/run.sh`. Execution found three defects in
  the contract as written, all invisible while `postgres` was the only
  consumer: the source map needs the effective value (EXECUTION-LOG D-014),
  §5.1's normalization is lossy and must not be used for output (D-015), and
  §5.2's `*KEY*` redaction pattern hides legitimate directives (D-018).
  **P3 (`caddy` summary) and P4 (`postgres` retrofit) not started** — until P4,
  the contract is implemented twice in this repo.
- **Scope:** One written contract for how every image in this repo takes runtime
  configuration from the environment: variable naming, allowlist semantics,
  precedence, failure mode, and a startup summary. Covers a shared entrypoint
  helper and the mechanism that distributes it into per-image build contexts
  (`docker-bake.hcl` named contexts), a retrofit of `postgres` onto that helper,
  and the contract's statement in [images/README.md](../images/README.md). It
  does **not** add a templating engine, change any image's existing variable
  names, or change what `caddy` does today beyond adding the startup summary —
  Caddy's config is expanded by Caddy itself and stays that way.
- **Related:** [images/postgres/rootfs/entrypoint.sh](../images/postgres/rootfs/entrypoint.sh),
  [images/postgres/rootfs/allowlist.conf](../images/postgres/rootfs/allowlist.conf),
  [images/postgres/rootfs/postgresql.conf](../images/postgres/rootfs/postgresql.conf),
  [images/caddy/rootfs/Caddyfile](../images/caddy/rootfs/Caddyfile),
  [images/caddy/rootfs/entrypoint.sh](../images/caddy/rootfs/entrypoint.sh),
  [docker-bake.hcl](../docker-bake.hcl), [images/README.md](../images/README.md).
  Consumed by RFC 0004, 0005, 0006, 0007.
- **Origin:** `candidate-images.md` §1.1 and §7, a working note written from the
  repo landing page without reading the Dockerfiles. Three of its assumptions
  are corrected in §3 below.

---

## 1. Summary

Write down one env-config contract and give it a shared implementation. Variable
names split into two channels — curated single-underscore names an image owns,
and a `<PREFIX>_CONF__<key>` passthrough policed by an allowlist. Unknown keys in
the passthrough channel abort startup. Precedence is baked default → mounted
config → environment, in that order, in every image. Every image prints its
effective non-default settings at boot, redacting anything the allowlist marks
sensitive. The helper lives in a repo-root `shared/` directory reached through a
bake named context, so per-image build contexts do not have to change.

## 2. Motivation

Two images configure themselves from the environment today and they do it two
different ways. `postgres` generates a config file from `PG_CONF__*` variables
against an allowlist; `caddy` relies on Caddy's own `{$VAR}` expansion with
defaults baked as `ENV` in the Dockerfile. Both are reasonable. Neither is
written down, so a third image picks whichever its author saw last.

The cost is not aesthetic. Concretely, today:

- **`PG_CONF_STRICT_MODE` defaults to `fail`** ([entrypoint.sh:17](../images/postgres/rootfs/entrypoint.sh#L17)) —
  a typo'd variable aborts the container. Caddy has no equivalent notion: a
  misspelled `EDGE_ADRESS` silently leaves `EDGE_ADDRESS` at its `ENV` default
  of `:8080` ([Dockerfile:96](../images/caddy/Dockerfile#L96)) and the container
  comes up listening on the wrong thing. Same repo, opposite failure mode, and
  nothing tells an operator which they are getting.
- **Neither image prints what it decided.** Postgres writes
  `/etc/postgresql/conf.d/99-overrides.conf` and never logs its contents; Caddy
  runs `caddy fmt` and `caddy adapt` ([entrypoint.sh:13-14](../images/caddy/rootfs/entrypoint.sh#L13-L14))
  and discards the adapted output to `/dev/null`. An operator debugging "why is
  this setting not taking effect" has no artifact to read short of `exec`ing in.
- **Precedence is real but undocumented.** It works today by an accident of line
  ordering that no README states — see §3.

Four candidate images (RFCs 0005–0008) each need this. Deciding it once, at five
images, is cheaper than deciding it four more times at nine.

## 3. Current state

Verified against the files, not the READMEs. The three items marked **correction**
contradict `candidate-images.md`, which was written without repo access.

**`postgres` — allowlist generation.** [entrypoint.sh](../images/postgres/rootfs/entrypoint.sh)
runs before the upstream `docker-entrypoint.sh`. It loads one parameter name per
line from `/etc/postgresql/allowlist.conf` (51 lines, grouped memory / CPU / WAL /
autovacuum / timeouts / logging), scans `env` for `PG_CONF__*`, normalizes each
key (lowercase, `-`→`_`, [entrypoint.sh:52-58](../images/postgres/rootfs/entrypoint.sh#L52-L58)),
refuses denylisted keys unconditionally, refuses non-allowlisted keys when
`PG_CONF_STRICT_MODE=fail`, escapes single quotes, and writes
`param = 'value'` lines to `/etc/postgresql/conf.d/99-overrides.conf`.

> **Correction 1.** The mechanism is generic; **the script is not**. It hardcodes
> the `PG_CONF__` prefix, the postgresql.conf output syntax, the output path, a
> `chown postgres:postgres`, and a 19-entry Postgres-specific `DENY` map
> ([entrypoint.sh:26-50](../images/postgres/rootfs/entrypoint.sh#L26-L50)). There
> is nothing to "lift"; §5.2 is a rewrite with the same semantics.

**Precedence already works, by line ordering.** `shared_preload_libraries` is set
at [postgresql.conf:809](../images/postgres/rootfs/postgresql.conf#L809) and
`include_dir = '/etc/postgresql/conf.d'` at
[postgresql.conf:874](../images/postgres/rootfs/postgresql.conf#L874). Postgres
takes the last occurrence of a setting, so everything in `conf.d` overrides the
baked file, and within `conf.d` the env-generated `99-overrides.conf` sorts after
any mounted `NN-*.conf`. That is exactly baked → mounted → env. It is correct and
undocumented, so it is one refactor away from being silently inverted.

**`caddy` — native expansion, no templating.**

> **Correction 2.** Caddy does not template. The Caddyfile uses Caddy's own
> `{$VAR}` / `{$VAR:default}` syntax ([Caddyfile:2,5,8-9,11,14,19,31](../images/caddy/rootfs/Caddyfile))
> and defaults are `ENV` in the Dockerfile. `gettext` is installed
> ([Dockerfile:67](../images/caddy/Dockerfile#L67)) but the stock entrypoint
> never calls `envsubst` — [images/caddy/README.md](../images/caddy/README.md)
> says so explicitly. So the repo is **already** at `candidate-images.md` §7's
> "no templating engine" end-state; the RFC's job is to keep it there, not to get
> it there.

**Distribution.**

> **Correction 3.** `rootfs/` is not copied wholesale. Each Dockerfile copies
> named paths to named destinations — `postgres` copies three files to three
> locations ([Dockerfile:38-48](../images/postgres/Dockerfile#L38-L48)), `caddy`
> copies four ([Dockerfile:72-75](../images/caddy/Dockerfile#L72-L75)). More
> importantly **each bake target's context is its own directory**
> (`context = "./images/<name>"` for all five targets, stated as a rule in
> [images/README.md:7](../images/README.md)). A file at the repo root is
> therefore **not reachable by `COPY`** from any image. This is the constraint
> that shapes §5.3.

**Shells differ.** The postgres entrypoint is `bash` and uses associative arrays
and `${k,,}`; the caddy entrypoint is `/bin/sh` on `caddy:*-alpine`, which has no
`bash`. A shared helper cannot be written in bash without adding a package to
Alpine-based images.

**Already done, contrary to the source note:** [LICENSE](../LICENSE) exists (MIT,
commit `b5944b1`), and `docker-bake.hcl`'s `label()` function already emits
`org.opencontainers.image.title`, `.version`, `.licenses`, `.vendor` and
`.source` for every target. Those belong to RFC 0002; they are noted here only so
this RFC is not read as claiming otherwise.

## 4. Goals / Non-goals

**Goals**

- One naming rule, one allowlist semantic, one precedence order, one failure
  mode, stated in [images/README.md](../images/README.md) and enforced by shared
  code rather than by review.
- A startup summary in every image that takes runtime config.
- A distribution mechanism for shared entrypoint code that does not require
  every image's build context to become the repo root.

**Non-goals**

- **A templating engine.** Every image in scope expands env natively — Caddy
  `{$VAR}`, the Collector `${env:}`, ClickHouse `from_env`, or a generated conf
  file. A fifth candidate that needs `envsubst` is a signal to look harder first,
  not a reason to add one.
- **Renaming existing variables.** `PG_CONF__*`, `CONFIG_DIR`, `EDGE_ADDRESS` and
  friends are published surface; the contract is written to fit them.
- **Shadowing upstream variables.** Where an upstream image owns a name
  (`POSTGRES_PASSWORD`, `CLICKHOUSE_USER`, `OTEL_EXPORTER_OTLP_ENDPOINT`), it is
  passed through untouched — that is RFC 0007's decision 2, generalized here.
- **A config schema or type system.** Values are strings; the upstream server
  validates them and its error message is better than ours would be.

## 5. Design

### 5.1 Two naming channels

One flat rule produces collisions the moment an image has both curated settings
and raw passthrough — `CH_MAX_CONCURRENT_QUERIES` as a curated knob and
`max_concurrent_queries` as a raw key are the same variable spelled two ways.
Split them, using the separator `postgres` already established:

| Channel | Form | Meaning |
|---|---|---|
| Curated | `<PREFIX>_<NAME>` | A setting the image owns and documents in its README, possibly composed (`VALKEY_PERSISTENCE=off\|rdb\|aof` drives several upstream settings). |
| Passthrough | `<PREFIX>_CONF__<key>` | One upstream setting, verbatim. `<key>` is normalized (lowercase, `-`→`_`) and must be in that image's allowlist. |
| Upstream | whatever upstream defined | Never intercepted, never redefined. |

`<PREFIX>` is one token per image, declared in its README: `PG`, `CADDY`, `OTEL`,
`VALKEY`, `CH`. The double underscore is what makes the passthrough channel
unambiguous and it is already shipping in `postgres`.

Curated names are a closed set an image README enumerates. There is no allowlist
for them because the image implements each one by hand; an unrecognized
`<PREFIX>_*` name that is not a curated name and not `_CONF__` is not fatal —
the environment of a real container is full of unrelated variables and a
fail-closed rule there would refuse to start on a sibling service's config.
Whether it warns or passes silently is **provisional and open** — decision 9 owns
it, and this paragraph follows whatever that row settles on.

**Collision between the two channels is refused.** A curated name and a
passthrough key can target the same upstream setting —
`VALKEY_MAXMEMORY_POLICY` and `VALKEY_CONF__maxmemory_policy` are the concrete
case, from RFC 0006 §5.5. Picking a winner means an operator who set both gets
the other one silently. So each image declares, alongside each curated name, the
upstream key(s) it writes; if a passthrough key targets a setting a curated
variable also wrote, startup aborts naming both variables. The rule is the same
fail-closed instinct as decision 2, applied to a pair rather than a key, and it
is what keeps the two-channel split from reintroducing the ambiguity it exists to
remove.

### 5.2 The shared helper

`shared/rootfs/lib/envconf.sh`, POSIX `sh`, sourced by an image's entrypoint. No
bash: it must run on `caddy:*-alpine` unmodified, which rules out associative
arrays and `${var,,}` (the postgres script's two bash dependencies — replaced by
`tr` and a whitespace-delimited string membership test).

```sh
# Contract exported by the helper.
envconf_load_allowlist  <path>            # one key per line, '#' comments, blank lines skipped
envconf_collect         <prefix>          # scan env for <prefix>_CONF__*, normalize, check
                                          #   allowlist + denylist, emit NUL-delimited key/value
                                          #   pairs on stdout (see "Value safety")
envconf_render          <fmt> <infile>    # fmt: pgconf | keyvalue | valkeyconf
envconf_summary         <prefix> <srcmap> # print effective settings, redacting sensitive keys;
                                          #   <srcmap> supplies per-key source attribution
envconf_secret          <name>            # value of <name>_FILE if set and readable, else $<name>
```

**Value safety.** A line-oriented `key<TAB>value` stream is unsafe: environment
values may contain tabs and newlines, and one such value splits into several
records and renders malformed config. Two rules close it. The wire format
between `envconf_collect` and `envconf_render` is **NUL-delimited**, since NUL is
the one byte an environment value cannot contain. And a value containing a
newline or a carriage return is **refused** by `envconf_collect`, naming the
variable: none of the config formats in scope (`postgresql.conf`, `valkey.conf`,
key-value) can represent an embedded newline, so accepting one only defers the
corruption to the server's parser. §6 tests both.

**Failure semantics, fail-closed by default.** A key in the denylist aborts
unconditionally. A key absent from the allowlist aborts when
`<PREFIX>_CONF_STRICT=fail` — the default — and warns-and-skips under `ignore`.
A missing allowlist file aborts; it is a build defect, not a runtime condition.
`envconf_secret` aborts if `<NAME>_FILE` is set but unreadable, rather than
falling back to the plain variable: silently starting with the wrong credential
is worse than not starting.

**Sensitivity.** The allowlist file gains an optional trailing `!secret` marker
per line. `envconf_summary` prints `<redacted>` for marked keys and for anything
matching `*PASSWORD*`, `*TOKEN*`, `*SECRET*`, `*KEY*`, `*HEADERS*` — the last
because OTLP credentials travel in headers (RFC 0005 §decision 4).

**The startup summary** is one block on stderr before `exec`, and it is the
cheapest high-value behaviour in this RFC:

```text
[envconf] postgres: effective non-default settings
[envconf]   source=baked      shared_preload_libraries = pg_cron,pg_stat_statements
[envconf]   source=mounted    work_mem = 32MB          (/etc/postgresql/conf.d/50-tuning.conf)
[envconf]   source=env        max_connections = 200    (PG_CONF__max_connections)
[envconf]   source=env        <redacted>               (PG_CONF__log_line_prefix)
[envconf] precedence: baked < mounted < env
```

The `source=` column is the point. "Which layer won" is the question the summary
exists to answer.

**It is also the one part of this contract the helper cannot compute alone**, and
saying so is what keeps the contract implementable:

- A prefix and the process environment are not enough. `envconf_summary` must be
  handed a **source map** — the baked config path, the mounted `conf.d` files it
  found, and the keys `envconf_collect` took from the environment. Each image
  builds that map, because only the image knows where its layers live. Hence the
  second argument in the signature above.
- **`ENV`-defaulted values are not attributable at all.** A Dockerfile
  `ENV EDGE_ADDRESS=":8080"` is indistinguishable in `environ` from an
  operator-supplied one, so an image configured that way — `caddy`, and the
  curated channel generally — cannot report `baked` versus `env` for those keys.
  Those lines print `source=env-or-default`, which is the true statement.

So the summary is normative in two parts: **the effective value and the
redaction are required of every image; full `source=` attribution is required
only of images that generate a config file** from layers they can enumerate
(`postgres`, `valkey`). RFC 0005 §5.5 is a further exception, on different
grounds. An image that promises attribution it cannot compute would be printing a
guess, which is worse than printing less.

### 5.3 Distributing the helper into per-image contexts

Each target's context is its own image directory (§3), so `COPY ../../shared` is
not available. Three options were weighed:

| Option | Cost |
|---|---|
| **Bake named context** — `contexts = { shared = "./shared" }` on each target, `COPY --from=shared rootfs/lib/envconf.sh /usr/local/lib/` | One line per target in `docker-bake.hcl`; requires BuildKit (already required: every Dockerfile pins `# syntax=docker/dockerfile:1.26`). Contexts stay per-image. |
| Move every context to `.` and use `dockerfile = "images/<name>/Dockerfile"` | Rewrites the layout rule in `images/README.md`, and sends the whole repo to the daemon as build context for every image. |
| Copy the file into each `rootfs/` with a CI drift check | No build changes; guarantees N copies and a check that will be silenced the first time it is inconvenient. |

**Named contexts win.** They are the mechanism buildx provides for exactly this,
they preserve the per-directory context rule the repo documents, and a target
that does not declare the context simply cannot reference it — the failure is a
build error, not a stale copy.

`shared/` sits at the repo root, next to `images/`, and gets its own README
stating that anything in it is consumed by two or more images by definition.

### 5.4 Retrofit of `postgres`

`postgres` moves onto the helper with **no change to its published surface**:
`PG_CONF__*`, `PG_CONF_ALLOWLIST_PATH` and `PG_CONF_STRICT_MODE` keep working,
the last two as image-local aliases for the contract's
`PG_CONF_STRICT` (`PG_CONF_STRICT_MODE` is kept as the name and the contract
adopts `_CONF_STRICT` for images that do not have a name yet — a new image gets
`<PREFIX>_CONF_STRICT`, `postgres` keeps what it published). The Postgres denylist
moves from the script into `rootfs/denylist.conf` alongside the allowlist, since
it is data, not logic. The startup summary is new behaviour and the only
observable change.

`caddy` gains the summary only: it prints its `ENV`-defaulted variables and their
effective values, marked `source=env-or-default` per §5.2 — it cannot say more
without a source map it has no way to build. Its config path is Caddy's own and
is not touched.

### Alternatives considered

- **Flat `<PREFIX>_<UPSTREAM_KEY>` naming**, as the source note proposed. Reads
  better in a Compose file, but it collides with curated names (§5.1) and it
  breaks the existing `PG_CONF__*` surface for no functional gain. Rejected: the
  double underscore is ugly and unambiguous, and unambiguous wins in a mechanism
  whose whole job is refusing typos.
- **Denylist instead of allowlist.** Cheaper to maintain and wrong by default:
  every upstream release adds settings that are then permitted by silence.
  Allowlist keeps the failure at "your key is not permitted" rather than "your
  key broke the server".
- **Ignore unknown keys silently.** Rejected for the passthrough channel: a
  `VALKEY_CONF__maxmemroy` that does nothing is discovered under load. Accepted
  for unrecognized curated-channel names, because that namespace is shared with
  the operator's own environment.

## 6. Tests

Per-image smoke tests in the existing bake CI job
([.github/workflows/bake.yaml](../.github/workflows/bake.yaml)), run against the
built image:

- A permitted `<PREFIX>_CONF__*` key reaches the server's effective config
  (`SHOW max_connections` for Postgres; the equivalent introspection per image).
- A key absent from the allowlist exits non-zero under `strict=fail` and starts
  with a warning under `ignore`.
- A denylisted key exits non-zero **in both modes** — this is the property most
  likely to regress in a rewrite.
- `<NAME>_FILE` beats `<NAME>`; an unreadable `<NAME>_FILE` exits non-zero.
- The summary prints `<redacted>` for a `!secret` key, and the plain value for a
  non-secret one, and the whole summary appears before the server's first log
  line.
- **Value safety (§5.2):** a passthrough value containing a tab survives intact
  into the rendered config, and one containing a newline is refused by name. Both
  are one-line tests and both guard a corruption that is otherwise found by the
  server's parser at a much worse moment.
- **Channel collision (§5.1):** setting a curated variable and a passthrough key
  that target the same upstream setting exits non-zero naming both.
- Precedence: a baked value, a mounted `50-*.conf` value and an env value for the
  same key resolve to the env value, and the summary attributes each correctly.

RFC 0002 §on rootless CI covers running these under rootless Podman.

## 7. Docs

- [images/README.md](../images/README.md) gains an **"Environment configuration"**
  section: the two channels, the allowlist rule, the precedence order, the
  failure mode, and the summary format. This is the normative statement; image
  READMEs link to it rather than restating it.
- Each image README keeps its variable table and marks each row curated,
  passthrough or upstream.
- `shared/README.md` states the two-consumer rule and the named-context wiring.
- The `postgres` README gains the summary example and a note that
  `PG_CONF_ALLOWLIST_PATH` pointing at a mounted file replaces the image's
  allowlist wholesale — see §9.

## 8. Out of scope

- **Reloading config without a restart.** Every mechanism here runs once at
  startup. Runtime drift (`ALTER SYSTEM`, Valkey `CONFIG SET`) is RFC 0006's
  problem to name, not this RFC's to solve.
- **Validating values.** The helper checks that a key is permitted, never that
  `work_mem = banana` is meaningful. The server's own error is better.
- **A shared entrypoint.** Only a sourced library is shared; each image keeps its
  own entrypoint, because what happens after config generation differs per image
  (`postgres` execs upstream's entrypoint, `caddy` validates then execs).
- **Retrofitting `flyway`, `uv-builder`, `python-distroless`.** They take no
  runtime env config — the first is a CLI, the other two are build/runtime
  stages. Named as excluded so a later reader does not read "every image" too
  literally.

## 9. Risks

- **`PG_CONF_ALLOWLIST_PATH` is itself an env variable**
  ([entrypoint.sh:12](../images/postgres/rootfs/entrypoint.sh#L12)), so an
  operator can point the allowlist at a file they control and permit anything.
  Same for `PG_CONF_STRICT_MODE=ignore`. The allowlist is a **guard rail against
  typos and drift, not a security boundary**, and the README must say so in those
  words — otherwise it reads as a sandbox and someone will rely on it as one.
- **The summary leaks by omission.** Redaction is pattern-based plus an explicit
  marker; a sensitive value under an unmarked, non-matching key prints in full.
  Mitigation: the allowlist marker is authoritative and reviewed per image;
  accepted residual risk for keys nobody marked.
- **POSIX-sh rewrite of working bash.** The postgres entrypoint works today. A
  rewrite in a weaker shell is a real chance to introduce a quoting bug in the
  exact code path that handles operator-supplied values. §6's tests exist mainly
  for this, and the retrofit should land as its own PR, after the helper and its
  tests are green on a new image.
- **A shared helper couples release cadence.** A bug fixed in `envconf.sh`
  requires rebuilding every image that embeds it. That is the same property as a
  base-image CVE and is handled by RFC 0002's rebuild cadence — noted so it is
  not discovered as a surprise.

## 10. Unresolved questions

- Whether `caddy` should also gain a `CADDY_CONF__*` passthrough channel, or
  whether snippet directories already cover everything an operator would reach
  for. Leaning: no channel — Caddy config is not key-value and the mapping would
  be a fiction. Settle before RFC 0005 copies the pattern.
- Whether the summary goes to stderr or stdout. Stderr keeps it out of a
  log-shipping pipeline's structured stream; stdout means it survives in
  `docker logs` alongside everything else. Implementation may settle it
  (decision 8).
- Whether `shared/` should carry a version marker so an image can state which
  helper revision it embeds. Only matters once two images embed different
  revisions, which the bake context makes impossible within one build — but not
  across published tags.

## 11. Decisions

| # | Grade | Decision |
| --- | --- | --- |
| 1 | `LOCKED` | Two naming channels: curated `<PREFIX>_<NAME>` and passthrough `<PREFIX>_CONF__<key>`, with upstream-owned names never intercepted. Every image RFC (0004–0008) is written against this split; changing it invalidates their env surfaces. |
| 2 | `LOCKED` | Allowlist, never denylist, for the passthrough channel; unknown key aborts startup by default (`<PREFIX>_CONF_STRICT=fail`). Consequence: an upstream release that adds a setting requires an allowlist edit before operators can use it — accepted, that is the mechanism working. |
| 3 | `LOCKED` | Precedence is baked default → mounted config file → environment, in every image, printed at startup. Already true for `postgres` by line ordering ([postgresql.conf:874](../images/postgres/rootfs/postgresql.conf#L874)); this makes it a rule rather than an accident. |
| 4 | `LOCKED` | `<NAME>_FILE` takes precedence over `<NAME>` for every secret, and an unreadable `_FILE` aborts rather than falling back. Consequence: retroactive for `postgres`, and RFC 0006 depends on it. |
| 5 | `LOCKED` | No templating engine anywhere in the repo. Each image uses its own native env expansion. A candidate that cannot be configured without `envsubst` is re-examined before it is accepted. |
| 6 | `ASSUMED` | The shared helper is distributed by a `docker-bake.hcl` named context (`contexts = { shared = "./shared" }`), not by moving build contexts to the repo root and not by copying. Depart if a target turns out to need the file at a stage buildx named contexts cannot reach. |
| 7 | `ASSUMED` | The helper is POSIX `sh`, so it runs on Alpine-based images without adding `bash`. Depart if the sh rewrite of the postgres logic proves unreadable enough to be a hazard in its own right — the alternative is `bash` in the caddy image, ~2 MB. |
| 8 | ~~`OPEN`~~ **Locked 2026-08-12** | **stderr.** The summary is diagnostic output about configuration, not application logging; `docker logs` and `podman logs` capture both streams, so nothing is lost operationally while stdout stays clean for anyone shipping structured logs. Precedent in the repo: [entrypoint.sh:60-67](../images/postgres/rootfs/entrypoint.sh#L60-L67) already writes `die` and `warn` to `>&2`. |
| 9 | ~~`OPEN`~~ **Locked 2026-08-12** | **Warn, with a known-ignore list.** A typo'd curated knob that silently does nothing is the failure this contract exists to prevent, and one log line is cheaper than that. The noise objection is answered by the list rather than by silence: the image's own control variables (`<PREFIX>_CONF_STRICT`, `<PREFIX>_CONF_ALLOWLIST`, and any `<NAME>_FILE`) are excluded, because a warning that fires on `PG_CONF_STRICT_MODE` itself trains operators to ignore all of them. |
| 10 | `ASSUMED` | `postgres` keeps `PG_CONF_STRICT_MODE` and `PG_CONF_ALLOWLIST_PATH` as published; new images use `<PREFIX>_CONF_STRICT` and `<PREFIX>_CONF_ALLOWLIST`. Accepting one inconsistent pair beats breaking a shipped surface. |
| 11 | `LOCKED` | A curated variable and a passthrough key targeting the same upstream setting abort startup naming both, rather than one silently winning (§5.1). Consequence: each image must declare the upstream key(s) behind every curated name — work its README was going to do anyway. |
| 12 | `LOCKED` | The collect→render wire format is NUL-delimited, and values containing a newline are refused (§5.2). A `key<TAB>value` stream splits a tab-bearing value into two malformed records, and no config format in scope can represent an embedded newline. |
| 13 | `LOCKED` | Full `source=` attribution is required only of images that generate a config file from enumerable layers; `ENV`-defaulted values print `source=env-or-default`, because `environ` cannot distinguish a Dockerfile default from a supplied value (§5.2). Effective value and redaction stay required of every image. Consequence: `caddy`'s summary is weaker than `postgres`'s, by construction rather than by omission. |

## 12. Phasing

- **P1 — the contract, written.** The "Environment configuration" section in
  [images/README.md](../images/README.md), plus decisions 1–5. No code, a day's
  work at most.

  **Correction 2026-08-12:** this phase previously claimed RFCs 0004–0008 were
  blocked on it. Two are not. RFC 0004 changes build-time extension selection and
  its own scope says it does not touch the `PG_CONF__*` runtime surface; RFC 0009
  is a builder with no runtime configuration at all. What P1 actually blocks is
  the *env surface* of RFCs 0005, 0006 and 0007. Read literally, the old wording
  serialized two independent tracks behind a docs task.
- **P2 — `shared/rootfs/lib/envconf.sh` + named-context wiring**, exercised by
  exactly one consumer, plus the §6 tests. The first consumer should be a new
  image (RFC 0005 or 0006) rather than `postgres`, so the helper is proven before
  it replaces something that works.
- **P3 — startup summary in `caddy`.** Small, isolated, and delivers the
  highest-value shared behaviour to a shipped image without touching its config
  path.
- **P4 — `postgres` retrofit**, own PR, own review, §6 tests green first.
  Deliberately last: it is the only step that can regress a running deployment.
