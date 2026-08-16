# Image layout

Every image under `images/<name>/` follows the same rules:

| Path | Purpose |
|------|---------|
| `Dockerfile` | Build definition; build context is always this directory (`images/<name>/`). |
| `README.md` | What the image is for and how to configure it at runtime. |
| `rootfs/` | Optional. Static files that are `COPY`’d into the image (configs, scripts, bundled assets). Omit when the Dockerfile has nothing to copy besides layers (e.g. Flyway). |

**Registry names** match the directory name under `images/` (e.g. `postgres`, `caddy`, `flyway`, `uv-builder`, `python-distroless`). **Tags** are version strings from bake variables (e.g. `18.4`, `2.11.3`, `12.7`, `3.14`, `3.14.5`); the same variables usually feed both `tags` and `args` in [`docker-bake.hcl`](../docker-bake.hcl). Distroless Python tags must remain valid for upstream `al3xos` bases (see [python-distroless](./python-distroless/README.md)).

Build from the **repository root**:

```bash
just bake               # all images
just bake flyway        # one target
just publish            # build + push (requires gh auth)
just push postgres 18   # push an already-built local tag
```

`just` is a thin wrapper around `docker buildx bake -f docker-bake.hcl` (`just push` uses `docker push` separately).

## Environment configuration

Every image that takes runtime configuration from the environment follows this
contract. It is normative: image READMEs link here rather than restating it.

> **Status.** This is the contract, not a description of what ships today.
> `postgres` implements the two channels and the allowlist; **no image emits the
> startup summary yet**, and the shared helper that would enforce the collision,
> value-safety and redaction rules is not written. Where an image's behaviour and
> this section disagree today, this section is the target and the image is the
> gap. Each image's own README states what it actually does.

### Two channels

| Channel | Form | Meaning |
|---|---|---|
| **Curated** | `<PREFIX>_<NAME>` | A setting the image owns and documents in its own README. May be composed — one variable driving several upstream settings. |
| **Passthrough** | `<PREFIX>_CONF__<key>` | One upstream setting, verbatim. `<key>` is normalised (lowercase, `-` → `_`) and must appear in that image's allowlist. |
| **Upstream** | whatever upstream defined | Never intercepted, never redefined. |

`<PREFIX>` is one token per image, declared in its README — `PG`, `CADDY`,
`VALKEY`, `CH`. The double underscore is what keeps the passthrough channel
unambiguous, and it already ships in `postgres` as `PG_CONF__*`.

**A curated name and a passthrough key may not target the same setting.** Each
image declares which upstream key(s) each curated name writes; if a passthrough
key targets a setting a curated variable also wrote, **startup aborts naming
both**. Picking a winner would mean an operator who set both silently gets the
other one.

### Allowlist, never denylist

The passthrough channel is policed by an allowlist file in the image — one key
per line, `#` comments ignored. A key that is not on it **aborts startup** by
default (`<PREFIX>_CONF_STRICT=fail`); `ignore` downgrades that to a warning and
a skip. A missing allowlist file always aborts: that is a build defect, not a
runtime condition.

An allowlist rather than a denylist because every upstream release adds settings,
and a denylist permits them all by silence. The cost is real and accepted: a new
upstream setting needs an allowlist edit before operators can use it.

**The allowlist is a guard rail against typos and drift, not a security
boundary.** `<PREFIX>_CONF_ALLOWLIST` and `<PREFIX>_CONF_STRICT` are themselves
environment variables, so anyone who can set the container's environment can
widen it.

An unrecognised `<PREFIX>_*` name that is neither curated nor `_CONF__` **warns
but does not abort** — a real container's environment is full of unrelated
variables. The image's own control variables (`<PREFIX>_CONF_STRICT`,
`<PREFIX>_CONF_ALLOWLIST`, and any `<NAME>_FILE`) are excluded from that warning,
because a warning that fires on the mechanism's own knobs trains operators to
ignore all of them.

### Precedence

**Baked default → mounted config file → environment.** One order, in every
image, printed at startup.

### Secrets

`<NAME>_FILE` takes precedence over `<NAME>` for every secret. An unreadable
`<NAME>_FILE` **aborts** rather than falling back to the plain variable —
silently starting with the wrong credential is worse than not starting.

Note the limit of what this buys: a secret supplied through the plain variable is
still visible in `docker inspect` output and crash dumps. The `_FILE` form is
what avoids that, and an image README says so where it matters.

### Startup summary

Every image prints its effective non-default settings to **stderr** before
exec'ing the server — diagnostic output about configuration, not application
logging, and `docker logs` / `podman logs` capture both streams anyway:

```text
[envconf] postgres: effective non-default settings
[envconf]   source=baked      shared_preload_libraries = pg_cron,pg_stat_statements
[envconf]   source=mounted    work_mem = 32MB          (/etc/postgresql/conf.d/50-tuning.conf)
[envconf]   source=env        max_connections = 200    (PG_CONF__max_connections)
[envconf]   source=env        <redacted>               (PG_CONF__log_line_prefix)
[envconf] precedence: baked < mounted < env
```

Values are redacted for keys the allowlist marks `!secret` and for anything
matching `*PASSWORD*`, `*TOKEN*`, `*SECRET*`, `*KEY*`, `*HEADERS*`.

**`source=` attribution is required only of images that generate a config file**
from layers they can enumerate. An image whose defaults are Dockerfile `ENV`
prints `source=env-or-default`, because the process environment cannot
distinguish a baked default from an operator-supplied value. The effective value
and the redaction are required of every image; inventing attribution an image
cannot compute would be printing a guess.

### No templating

No image in this repo renders its configuration through a templating engine.
Each uses its own native expansion — Caddy's `{$VAR}`, a generated conf file, or
the upstream server's own env support. A candidate image that cannot be
configured without `envsubst` is re-examined before it is accepted.

See [RFC 0001](../rfcs/0001-shared-env-config-contract.md) for the reasoning and
the rejected alternatives.

## Which images belong here

> **Admission, route 1 — duplication.** An image lands here when the same
> Dockerfile has been hand-rolled in **two or more** projects. One project keeps
> its own Dockerfile.
>
> **Admission, route 2 — drift.** An image also lands here when **two or more**
> projects run the same upstream image *without* a Dockerfile, and their pinned
> versions or their configuration have diverged. The image's contribution is
> then the defaults, not the packaging.
>
> **Retirement.** An image that no project has used for a year is deleted, not
> maintained.

The reason is cost, not taste. Every image is a permanent subscription to
somebody else's CVE feed, and adding one is nine edits, not one:

| # | Touchpoint |
|---|---|
| 1 | `images/<name>/` — `Dockerfile`, `README.md`, optional `rootfs/` |
| 2 | Version variable with its Renovate annotation in [`docker-bake.hcl`](../docker-bake.hcl) |
| 3 | Bake target with `tag()` / `label()` / args, inheriting `_attested` |
| 4 | `default` group membership |
| 5 | `PACKAGES` in [`cleanup-images.yaml`](../.github/workflows/cleanup-images.yaml) |
| 6 | Images table row in the [root README](../README.md) |
| 7 | A `DESCRIPTIONS` entry in [`docker-bake.hcl`](../docker-bake.hcl) |
| 8 | Env-config allowlist and README section — see [Environment configuration](#environment-configuration) |
| 9 | `images/<name>/smoke.sh` — run against the built image by [`bake.yaml`](../.github/workflows/bake.yaml) |

**Items 4 and 5 fail silently.** A missing `default` entry means the image is
never built by `just bake`; a missing `PACKAGES` entry means its untagged
versions accumulate in GHCR forever. Neither produces a red check.

Item 7 used to be the third of those. A missing `DESCRIPTIONS` entry now
**fails the build** rather than publishing an empty
`org.opencontainers.image.description` — see RFC 0002 decision 16.

Item 9 is a script taking one argument, the image reference, exiting non-zero on
failure. It runs under rootless Podman, so it asserts what rootless is what
breaks: UID mapping, volume ownership, port binds. `bake.yaml` discovers it by
path, so an image without one is silently unsmoked — that much is still on the
author to remember.

**Why two routes.** Route 1 counts duplicated Dockerfiles, which is the right
evidence for a *packaging* image — somebody had to write a build, twice. It is
the wrong evidence for a *curation* image, whose whole contribution is defaults:
nobody writes a Dockerfile to run Valkey, they write a `command:` line, so a
curation image that is badly needed generates no duplicated Dockerfiles at all.
Route 2 measures what that need actually looks like from outside — the same
upstream image pinned differently in different places, or configured differently
for the same job.

Clarifications that keep both routes from being argued away:

- **"Hand-rolled in two projects" means the Dockerfiles exist**, not that two
  projects would benefit. Anticipated reuse is the failure this bar catches — it
  is how a repo acquires images maintained for nobody.
- **Route 2 needs the divergence, not just the count.** Ten projects running the
  same pinned image, configured the same way, are not drifting — they are fine,
  and an image would add a hop for nothing. What route 2 admits is the case
  where they have already fallen out of step.
- **Neither route admits an image nobody runs yet.** Both count deployed
  projects. An image for infrastructure the stack does not have is speculative
  under either route, and the right way in is to have a first consumer, not a
  looser rule.
- **A pair counts as one admission.** `uv-builder` + `python-distroless` are one
  decision about Python, not two about images.

### The annual review

Once a year, each image is checked against two questions, both answered from
consuming repositories rather than GHCR pull counts — a scheduled CI job pulling
an image is a pull count, not a user.

**1. Does a live project reference this tag?** No, for a year, means retire.

**2. Does a live project *reimplement* this image?** A project that hand-rolls a
Dockerfile for something already published here is not breaking a rule — it is
telling you the published image did not fit. The useful output is *why*, and the
fix is usually ours. Worked example, found 2026-08-12:
`morze-erp-backend-v2` builds its own `postgres:18.1` with pg_cron and no
pgroonga, because this repo's `postgres` bundles both and it wanted one. That is
demand for a build-arg variant, not an adoption problem — and a second project,
`morze-crm-backend-v2`, copied our Dockerfile near-verbatim while pinning a
version behind ours.

Outcomes are keep or retire. There is no "keep for now"; that is the state that
produces images nobody has used since 2024. An image whose only consumer is this
repo is retired even if it builds cleanly.

### Retiring an image

Deletion has to be mechanical or it will not happen:

1. Announce in the image's README that the tag is frozen, with a date.
2. Remove the bake target, its variable, its `default` group entry, and its
   `DESCRIPTIONS` row — the last is not optional bookkeeping: `DESCRIPTIONS` is
   indexed directly, so a stale row is harmless but a missing one fails every
   bake invocation, and leaving retirement half-done here is how the map drifts
   out of step with the targets.
3. Remove the row from the root README images table.
4. Delete `images/<name>/`.
5. **Leave `<name>` in `PACKAGES`** — the published package still exists and its
   untagged children still need collecting. Remove it only if the package itself
   is deleted.
6. Decide the published package's fate explicitly, below.

Steps 2–4 are one PR. Git history keeps the Dockerfile, so retirement costs
nothing irreversible — which is the argument that makes it easy to agree to.

**The published GHCR package** does not disappear with the directory. Choose per
image and record it in the PR:

- **Freeze** (default) — the package stays, tags stop moving, the last published
  image keeps working. It receives no further CVE fixes, and the frozen README
  says so in those words.
- **Delete** — for an image with no external consumers, where a broken pull is a
  better signal than a silently stale one.

Freeze is the default because this is a public registry and a deleted tag breaks
builds we cannot see.

See [RFC 0003](../rfcs/0003-image-admission-and-retirement-rule.md) for the
reasoning, the alternatives, and a known limitation of the bar.
