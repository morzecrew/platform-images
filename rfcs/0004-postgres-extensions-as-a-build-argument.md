# RFC 0004 — Postgres extensions as a build argument

- **Status:** 🚧 In progress — **P1 shipped 2026-08-16** (manifest, build-time generation, the default image produced by the new mechanism, equivalence proven in EXECUTION-LOG D-006). **P2 and P3 shipped 2026-08-17**: the `pgvector` and `cron` variants, the build-mechanism tests §6 asked for, and the variant documentation. This field read **Draft** until 2026-08-17, five days after P1 merged — recorded rather than quietly corrected, because a status that lags the work is the failure a status field has.
  The 2026-08-12 demand measurement (§3.1) stands: pgvector had two live
  consumers on a *different base image* and pgmq none, which is why P2 shipped
  `pgvector` and the cron-only subset rather than a queue.
- **Scope:** Turn the `postgres` image's hardcoded extension set into a
  `PG_EXTENSIONS` build argument backed by a manifest, so a second extension
  combination is a bake target rather than a second directory. Covers the
  extension manifest, generated `shared_preload_libraries`, per-extension config
  snippets, variant tag naming, and an image label recording the installed set.
  Does not change the `PG_CONF__*` runtime surface.

  This scope originally said the RFC adds **no specific extension**, pgvector and
  pgmq included. P2 added pgvector, under decision 7 — which pre-authorised
  exactly the two variants §3.1 measured demand for, and is the later text.
  Recorded rather than rewritten: the original scope is what the mechanism was
  designed against.
- **Related:** [images/postgres/Dockerfile](../images/postgres/Dockerfile),
  [images/postgres/rootfs/postgresql.conf](../images/postgres/rootfs/postgresql.conf),
  [images/postgres/rootfs/entrypoint.sh](../images/postgres/rootfs/entrypoint.sh),
  [docker-bake.hcl](../docker-bake.hcl),
  [images/postgres/README.md](../images/postgres/README.md). Depends on nothing.
  ~~Blocks RFC 0006 §gate~~ — that dependency closed when the 2026-08-12 sweep
  found pgmq in zero repositories (§3.1), so RFC 0006's gate no longer routes
  through this RFC.
- **Origin:** `candidate-images.md` §1.4.

---

## 1. Summary

`images/postgres/Dockerfile` installs pg_cron and pgroonga by name and
`rootfs/postgresql.conf` preloads them by name. Replace both with a
`PG_EXTENSIONS` build arg and a manifest that maps each logical extension name to
its apt package, its preload requirement and its config snippet. The default
value reproduces today's image exactly. Additional combinations become bake
targets with a tag suffix and an `io.morze.postgres.extensions` label, so
`docker inspect` answers "what is in this one".

## 2. Motivation

The immediate trigger is RFC 0006. Its gate is "does Postgres with pgmq cover the
queue", and that question cannot be answered honestly while adding pgmq means
adding `images/postgres-pgmq/` — a second directory with a duplicated 900-line
`postgresql.conf`, a duplicated entrypoint, a duplicated allowlist, and a second
copy of the pgroonga apt-source dance. The cost of *evaluating* the alternative
currently exceeds the cost of just building Valkey, which is how a gate gets
waved through.

The general form: `postgres` today is base + pg_cron + pgroonga, and the naive
response to any new extension is a new directory. Two extensions plus one
optional gives three directories; the set of subsets grows faster than anyone
maintains it, and each directory is a separate opportunity for the config files
to drift apart.

There is also a correctness trap in the current shape, described in §3, that
makes "just copy the directory and edit it" actively dangerous.

## 3. Current state

**Extensions are installed by name in one `RUN`.**
[Dockerfile:14-33](../images/postgres/Dockerfile#L14-L33) derives `PG_MAJOR` from
`POSTGRES_IMAGE_TAG`, installs `postgresql-${PG_MAJOR}-cron` from PGDG, fetches
`groonga-apt-source-latest-${CODENAME}.deb` keyed on the base image's Debian
codename, then installs `postgresql-${PG_MAJOR}-pgdg-pgroonga`. Neither extension
is version-pinned — apt resolves whatever the repository currently offers, so two
builds of `postgres:18.4` a month apart can carry different pgroonga versions
with no signal anywhere.

**Preloading is baked into the main config, and it is denylisted at runtime.**
[postgresql.conf:809](../images/postgres/rootfs/postgresql.conf#L809) sets
`shared_preload_libraries = 'pg_cron,pg_stat_statements'`, and the entrypoint
refuses `PG_CONF__shared_preload_libraries` unconditionally
([entrypoint.sh:27](../images/postgres/rootfs/entrypoint.sh#L27), the denylist,
which is checked before the allowlist and ignores `PG_CONF_STRICT_MODE`). So the
build is the only channel that can change the preload list — correct, and it
means the extension set and the preload line must be decided together at build
time or not at all.

> **The trap.** `shared_preload_libraries` naming a library that is not installed
> is a **fatal startup error**, not a warning. A copied directory that drops
> pg_cron from the `apt-get install` line but leaves line 809 alone produces an
> image that builds green and refuses to start. This is the single strongest
> argument for generating the line from the same input that drives the install.

**pg_cron also brings its own settings.**
[postgresql.conf:885-887](../images/postgres/rootfs/postgresql.conf#L885-L887)
set `cron.database_name`, `cron.log_run` and `cron.log_statement` in the main
config file — extension-specific configuration living in the shared base.

**The override path already works and is ordered correctly.**
`include_dir = '/etc/postgresql/conf.d'` is at
[postgresql.conf:874](../images/postgres/rootfs/postgresql.conf#L874), after
every baked setting, and Postgres takes the last occurrence of a parameter. So a
file dropped into `conf.d` at build time overrides the base config, and the
entrypoint's env-generated `99-overrides.conf` still sorts last (RFC 0001 §3).
This is the mechanism §5.2 uses; it needs no changes.

**Bake.** One `postgres` target, `tags = tag("postgres", POSTGRES_VERSION)`,
`args = { POSTGRES_IMAGE_TAG = POSTGRES_VERSION }`, and a Renovate annotation on
the variable. `label()` returns a fixed five-entry map for every target.

### 3.1 The demand, measured (2026-08-12)

Swept every Morze repository for pgvector, pgmq and hand-rolled Postgres images.

**pgvector has two deployed consumers, and they had to leave this image to get
it.** `demo-ai-consultant` and `fashion-ai-mvp` both run
`image: pgvector/pgvector:pg18-trixie` — a different upstream base entirely. A
third repository, `forze`, pins the same image in an integration-test fixture
(`tests/integration/test_forze_postgres/conftest.py`); that is counted separately
here for the same reason RFC 0005 §3.1 discounts forze's collector assets — a
test fixture is not a deployment.
Today the choice is `ghcr.io/morzecrew/postgres` (pg_cron + pgroonga, no vector)
**or** `pgvector/pgvector` (vector, no cron, no pgroonga). Nobody can have both,
and two projects have already picked the other side. That is this RFC's
motivation observed rather than argued, and it names the first variant: **vector,
not queue.**

**pgmq appears in zero repositories.** §2's framing — that this RFC exists to
unblock RFC 0006's pgmq question — is therefore not what the evidence supports.
The mechanism is still worth building; the reason is pgvector.

**Two projects hand-roll a Postgres image that already exists here.**

| Project | Dockerfile | Contents |
|---|---|---|
| `morze-crm-backend-v2` | `containers/postgres/Dockerfile` | `postgres:18.1` + pg_cron + pgroonga, including the groonga apt-source block **and its comments**, near-verbatim from [images/postgres/Dockerfile](../images/postgres/Dockerfile) |
| `morze-erp-backend-v2` | `ops/docker/postgres/Dockerfile` | `postgres:18.1` + pg_cron |

This is duplication of a published image, not of a missing one — the inverse of
RFC 0003's admission problem, and it now has a home there (RFC 0003 decision 10
makes it an annual-review question). It also means the `18.1` pin in both is
behind this repo's `18.4`.

**`morze-erp-backend-v2` is demand for this RFC, from the opposite direction to
pgvector.** It installs pg_cron and *not* pgroonga. Today that combination cannot
be had from this repo at all: `ghcr.io/morzecrew/postgres` bundles both, so a
project wanting one pays for the other — the groonga apt source, the package, the
image size — or rebuilds from `postgres:18.1` itself, which is what happened.
Where pgvector shows the mechanism is needed to *add* an extension, this shows it
is needed to *omit* one. Both are §12 P2 candidates and the subset case is the
cheaper of the two, since it needs no new manifest row.

## 4. Goals / Non-goals

**Goals**

- A second extension combination costs a bake target, not a directory.
- The preload line cannot disagree with the installed set.
- `docker inspect` answers what is installed, without pulling and running.
- The default build reproduces today's image's **effective server state** — same
  extensions, same effective settings, same preload order (§6 defines the test).

**Non-goals**

- **Admitting pgvector or pgmq.** They are the motivating cases and each needs
  its own consumer; this RFC makes admitting one a two-line change.
- **Runtime extension selection.** Extensions are installed at build time.
  `CREATE EXTENSION` remains the operator's business.
- **Enumerating subsets.** Targets name the combinations actually run — two or
  three — not the powerset.
- **Version-pinning existing extensions.** Worth doing (§10) and separable; doing
  it inside this refactor would make the "same image as before" claim
  untestable.

## 5. Design

### 5.1 The manifest

One file, `images/postgres/rootfs/extensions.manifest`, read by a build script.
Colon-separated: logical name, apt package template, ~~preload library (empty if
none), snippet file (empty if none)~~ — **column set superseded by row 14**
(added by execution 2026-08-16, see [EXECUTION-LOG.md](EXECUTION-LOG.md) D-001).
The SQL name is carried explicitly, because §5.2's control-file check and §5.4's
label mapping both need it and neither can derive it from the preload library:

```text
# name : apt package (%M = PG major) : sql name : preload lib : conf snippet
cron     : postgresql-%M-cron            : pg_cron  : pg_cron : cron.conf
pgroonga : postgresql-%M-pgdg-pgroonga   : pgroonga :         :
```

`cron` is the row that makes the fourth column look redundant — its preload and
its SQL name are both `pg_cron`. `pgroonga` is the row that shows it is not:
its control file is `pgroonga.control` and it has no preload at all.

**The manifest ships with exactly the two extensions the image installs today.**
Every example below uses only those two. An unadmitted extension must not appear
as a manifest row, because decision 4 makes manifest membership the definition of
a valid `PG_EXTENSIONS` value — a `vector` row would advertise a build input
whose packaging §10 records as unverified. pgvector and pgmq are added by the
one-line change this RFC exists to make possible, each when it has a consumer and
a verified package, not before.

`pg_stat_statements` is not listed either, on different grounds: it ships with
the server, needs no package, and is preloaded unconditionally. It stays a
constant in the generated preload line rather than an optional entry nobody would
deselect. §5.4 records what that means for the label.

pgroonga's apt source (`groonga-apt-source-latest-${CODENAME}.deb`) is a
prerequisite step, not a package, so it stays a conditional block in the
Dockerfile guarded on `pgroonga ∈ PG_EXTENSIONS` rather than becoming a manifest
column. One extension needing a repository is a special case; a column for it
would be a schema built for one row.

### 5.2 Build-time generation

```dockerfile
ARG PG_EXTENSIONS="cron pgroonga"
```

The build script, run in the existing `RUN` layer:

1. Fails on any name not in the manifest, listing the valid names. A typo'd
   extension must not produce a quietly smaller image.
2. Installs the resolved apt packages, adding the groonga source first when
   pgroonga is requested.
3. Writes `/etc/postgresql/conf.d/10-extensions.conf`:
   `shared_preload_libraries = 'pg_cron,pg_stat_statements'` — the preload column
   of the selected rows in manifest order, then the unconditional
   `pg_stat_statements`. That ordering is not cosmetic: it reproduces today's
   line exactly (§6).
4. Copies each selected row's snippet into `/etc/postgresql/conf.d/`, so
   `cron.database_name` and friends arrive if and only if pg_cron does.
5. Verifies each selected row's extension **control file** exists —
   `/usr/share/postgresql/<major>/extension/<sql name>.control` — and that each
   preload library is present under the server's `pkglibdir`, before the layer is
   accepted.

**Step 5 is a filesystem check, not a SQL one.** Querying
`pg_available_extensions` needs a running server, and the build has none: the
image never runs `initdb`, so a SQL gate would mean standing up a temporary
cluster, waiting for readiness, authenticating and tearing it down inside the
`RUN` layer — machinery worth more than the check it performs. The control file
is what the server itself reads to decide an extension is available, so testing
for it answers the same question deterministically and in one `test -f`.

It does need the logical→SQL name mapping (`cron` → `pg_cron`), which the
manifest already implies and §5.4 makes explicit as a column.

Step 5 is what makes the trap in §3 unreachable: an image whose preload line
names an uninstalled library fails the build, not the deployment.

**Removals from `rootfs/postgresql.conf`.** Four settings move out, not three:
`shared_preload_libraries` (line 809), the three `cron.*` settings (885–887), and
**`pg_stat_statements.max` / `.track` (890–891)**. The last pair matters more
than it looks: `include_dir` is at line 874, and both sit *after* it, so today
they override anything in `conf.d` — including the generated
`10-extensions.conf` and the entrypoint's `99-overrides.conf`. Leaving them would
make this RFC's precedence claim false for exactly the settings it generates.
They move into the `pg_stat_statements` snippet alongside the preload constant.

With those gone the base config stops mentioning any extension, and precedence
holds as stated: baked → extensions (`10-*.conf`) → mounted (`NN-*.conf`) → env
(`99-overrides.conf`).

### 5.3 Bake targets and tags

```hcl
target "postgres" {
  context = "./images/postgres"
  tags    = tag("postgres", POSTGRES_VERSION)
  labels  = merge(label("postgres", POSTGRES_VERSION), {
    "io.morze.postgres.extensions" = "cron pgroonga"
  })
  args = {
    POSTGRES_IMAGE_TAG = POSTGRES_VERSION
    PG_EXTENSIONS      = "cron pgroonga"
  }
}

# Shape of a future variant. Not shipped by P1, and not addable until its
# extension has both a verified package (§10) and a consumer (RFC 0003).
target "postgres-search" {
  inherits = ["postgres"]
  tags     = tag("postgres", "${POSTGRES_VERSION}-search")
  labels   = merge(label("postgres", POSTGRES_VERSION), {
    "io.morze.postgres.extensions" = "cron pgroonga"
  })
  args = { PG_EXTENSIONS = "cron pgroonga" }
}
```

The second target is **illustrative**: it shows the shape, using only manifest
rows that exist. A snippet naming `pgmq` would not build — decision 4 fails on
any name the manifest does not carry — so writing one here would put a
copy-pasteable defect in the document that motivates the mechanism.

**The unsuffixed tag keeps today's meaning.** `ghcr.io/morzecrew/postgres:18.4`
remains pg_cron + pgroonga; anyone pinning it sees no change. Variants take a
suffix: `:18.4-<name>`.

**Variants are tags, not registry names.** One GHCR package, so no new entry in
`cleanup-images.yaml`'s hand-maintained `PACKAGES` list
([cleanup-images.yaml:31](../.github/workflows/cleanup-images.yaml#L31)) and no
new row in the root README table. This is most of why the build-arg shape is
cheaper than a directory — it dodges RFC 0003's §2 checklist for everything
except the bake target itself.

Variants join the `default` group, so `just bake` and RFC 0002's weekly rebuild
cover them. Each variant is a full build of the base image plus its extensions;
the layer cache makes that cheap on push builds and not cheap under RFC 0002's
`--no-cache` weekly rebuild. Two or three variants is the point at which that
stays acceptable.

`inherits` **merges** the args map per key, with the child's value winning, so a
variant overriding `PG_EXTENSIONS` declares only that and keeps the parent's
`POSTGRES_IMAGE_TAG` (decision 6, measured on buildx 0.35). The repository pins
`docker/setup-buildx-action` by digest but not the buildx binary it installs, so
this is a measured behaviour of the version in use rather than a guarantee; a
variant that silently lost its base-image pin would show up as a build against
the wrong Postgres major, not as a merge error.

### 5.4 What the label says

`io.morze.postgres.extensions` is **the canonicalized `PG_EXTENSIONS` selection**
— the manifest names, normalized and sorted — and nothing else. It is not read
back from the database, because neither catalog answers the question:
`pg_available_extensions` lists everything installable in the image, base
Postgres included, and `pg_extension` lists what some database happens to have
run `CREATE EXTENSION` for. The build-selected set exists only at build time, so
the build is what records it.

Two consequences worth stating rather than discovering:

- **Logical names are not SQL names.** The manifest's `cron` is `pg_cron` to the
  server. The manifest carries both — the logical name is the build input and the
  label's vocabulary, the SQL name drives §5.2's control-file check.
- **`pg_stat_statements` is outside the label**, because the label describes the
  optional selection and that extension is unconditional. The image README says
  so; otherwise a reader diffs the label against `\dx` and concludes the label
  lies.

### Alternatives considered

- **A directory per combination.** Rejected: duplicates a 900-line config, an
  entrypoint, an allowlist, and pgroonga's apt-source block, and each duplicate
  can drift. It is also what makes RFC 0006's gate expensive to answer, which is
  the proximate reason this RFC exists.
- **Runtime extension install** (apt at container start). Rejected: needs network
  and root at runtime, makes startup time variable, and breaks the "the image is
  the artifact" property that RFC 0002's attestations depend on.
- **A boolean arg per extension** (`WITH_PGVECTOR=1`). Simpler for two, and it
  becomes an unreadable matrix at five, with no single string to put in the
  label.
- **Encoding the full list in the tag** (`:18.4-cron-pgroonga-vector`). Precise,
  unusable. The label carries the full list; the tag carries a name.

## 6. Tests

- **Equivalence, defined precisely.** The refactor moves settings between files
  and would otherwise reorder the preload list, so file-level comparison is the
  wrong instrument. Equivalence is asserted on the **effective server state**: for
  a container started from each image, every row of `pg_settings` that differs
  from the server's built-in default must match, and the installed package set
  must match. Both images are started and diffed; nothing is compared as text.
  This is the test that makes the refactor safe to merge.
- **Preload order is preserved.** `shared_preload_libraries` stays
  `pg_cron,pg_stat_statements` rather than becoming
  `pg_stat_statements,pg_cron`. Load order is observable — extensions initialize
  in list order and some are order-sensitive — so the generator emits manifest
  rows first and the unconditional constant last, and the test pins the exact
  string. Reordering it would be a behavioural change smuggled inside a refactor
  whose entire claim is that nothing changed.
- **Fail-fast:** `PG_EXTENSIONS="cron pgvektor"` fails the build with the valid
  names listed.
- **The §3 trap, directly:** a variant that omits `cron` produces an image whose
  preload line omits `pg_cron`, and it starts. This is the regression this whole
  RFC exists to prevent, and it is the one test that must never be skipped.
- **Snippet coupling:** a build without `cron` contains no `cron.*` settings in
  any file under `/etc/postgresql/`.
- **Runtime overrides still win:** `PG_CONF__work_mem` set on a variant image
  reaches the effective config, and `PG_CONF__shared_preload_libraries` is still
  refused (denylist, both strict modes) — RFC 0001 §6 covers this generally; it
  is re-asserted here because §5.2 moves the preload line.
- **Label:** `io.morze.postgres.extensions` on each variant equals the
  canonicalized `PG_EXTENSIONS` it was built with (§5.4), and every name in it
  has a matching control file in the image.

## 7. Docs

- [images/postgres/README.md](../images/postgres/README.md) gains an
  **Extensions** section: the manifest format, `PG_EXTENSIONS`, the published
  variants and what each is for, and the label to inspect. The existing
  configuration-override section is unchanged.
- A sentence stating that extension packages are **not version-pinned** (§3), so
  nobody infers reproducibility the build does not provide. §10 is where that
  gets fixed, not here.
- [images/README.md](../images/README.md) notes that variants are tag suffixes on
  one registry name, so the pattern is available to a future image.

## 8. Out of scope

- **pgmq's and pgvector's actual packaging.** Both are named in the manifest
  example; whether each is available as a PGDG apt package for the pinned major,
  or needs a source build or a vendor `.deb`, is a measurement (§10). A source
  build would need a manifest column the current schema does not have — the
  escape hatch, named and not built.
- **A variant with no extensions at all** (`PG_EXTENSIONS=""`). The machinery
  supports it; no target ships it, because plain `postgres:18.4` upstream is
  better than ours for that case.
- **Extension upgrade across image versions.** `ALTER EXTENSION … UPDATE` after a
  base bump is an operator procedure this repo has no story for, in common with
  every other stateful concern here.
- **Applying the manifest pattern to other images.** Only `postgres` has an
  optional-component problem today.

## 9. Risks

- **The refactor touches a shipped, stateful image.** The blast radius is every
  Postgres deployment on the mutable `:18.4` tag, and the failure mode of a
  wrong preload line is a container that will not start — visible immediately,
  which is the good version of bad. §6's equivalence test is the mitigation and
  it must run against the pre-refactor image, not against expectations.
- **Removing lines 809 and 885–887 from `postgresql.conf`** makes the base config
  diverge from the upstream sample it was derived from, so a future
  re-derivation from a new Postgres major must re-apply the deletion. A comment
  at the deletion site is the cheapest mitigation.
- **Variant proliferation.** The mechanism makes variants cheap, and cheap things
  multiply. RFC 0003's admission rule does not obviously cover tag variants of an
  admitted image; the ceiling of two or three targets is a convention here, not
  an enforced rule.
- **Weekly `--no-cache` rebuild cost** scales with variant count (§5.3).
- **The manifest is a small config language.** Colon-separated fields with a `%M`
  placeholder is a format someone will want to extend the first time an extension
  does not fit it (§8). Keeping it to four columns and refusing the fifth is the
  discipline; the alternative is a build system inside a Dockerfile.

## 10. Unresolved questions

- ~~**Is pgmq available as an apt package for the pinned major**, or does it need
  a source build?~~ **Answered by measurement 2026-08-17:** PGDG carries **no
  pgmq package for any major**. It would need a source build, which decision 5
  pre-authorises as a new manifest column — but §3.1 already found zero
  consumers, and RFC 0006 shipped in wave 3 without it, so the question this was
  gating no longer exists.
- ~~Same question for pgvector, which is the more likely first real consumer.~~
  **Answered by measurement 2026-08-17:** `postgresql-18-pgvector`
  **0.8.6-1.pgdg13+1** is in `trixie-pgdg`, for majors 12 through 19. No source
  build, no new column: one ordinary manifest row, shipped as P2.

  The first measurement said otherwise and was wrong. Run inside a container
  whose apt indexes had all failed to fetch, `apt-cache` answered from stale
  baked lists and reported the package missing — a broken measurement whose
  failure mode looks exactly like a result. See EXECUTION-LOG D-039.
- Whether dotted extension GUCs left in the base config (`cron.database_name`
  with pg_cron absent) are accepted as placeholders or refused at startup. §5.2
  moves them regardless, so the answer changes nothing here — but it determines
  how loud the failure is if someone reintroduces one.
- ~~Whether `inherits` merges or replaces the `args` map in the pinned buildx
  version (§5.3, decision 6).~~ **Answered by measurement 2026-08-12:** it
  merges per key. Left open in a narrower form — the buildx *binary* is not
  pinned, only the action that installs it, so the answer is measured rather
  than guaranteed.

## 11. Decisions

| # | Grade | Decision |
| --- | --- | --- |
| 1 | `LOCKED` | `shared_preload_libraries` is generated from the same input that drives the install, and never hand-written. This is the defect class (§3 trap) the RFC exists to close; a variant that hand-maintains the line reintroduces it. |
| 2 | `LOCKED` | The unsuffixed tag `postgres:<version>` keeps its current extension set (cron + pgroonga). Consumers pinning it see no change from this refactor. |
| 3 | `LOCKED` | Variants are tag suffixes on the single `postgres` registry name, not new registry names. Consequence: no new `PACKAGES` entry, no new README row — and variants share one package's version history in GHCR. |
| 4 | `LOCKED` | An unknown name in `PG_EXTENSIONS` fails the build. Silently building a smaller image is the failure this cannot have. |
| 5 | `ASSUMED` | A four-column colon-separated manifest is sufficient. Depart — with a new column, not a second mechanism — if an extension needs a source build (§8). |
| 6 | ~~`OPEN`~~ **Answered by measurement 2026-08-12** | `inherits` **merges** `args` per key, with the child's value winning. Verified on buildx 0.35: a child declaring only `OVERRIDE_ME` kept the parent's `KEEP_ME` and added its own. So a variant does **not** restate `POSTGRES_IMAGE_TAG`; it declares only what it changes. |
| 7 | ~~`OPEN`~~ **Locked 2026-08-12** | **Three variants including the default**, enforced by review rather than mechanism. Measured demand is exactly two beyond the default — pgvector (§3.1) and cron-without-pgroonga (§3.1). Each variant costs a full `--no-cache` slot in RFC 0002's weekly rebuild, so a fourth request is the prompt to ask whether the answer is no, not to extend the matrix. |
| 8 | `ASSUMED` | Extension packages stay unpinned in this RFC, as they are today. Pinning is a separate change so that §6's equivalence test means something. |
| 9 | `LOCKED` | The build-time availability gate is a control-file and library check on the filesystem, not a SQL query. `pg_available_extensions` needs a running server; the image never runs `initdb`, so a SQL gate would mean standing up a throwaway cluster inside the `RUN` layer. |
| 10 | `LOCKED` | `io.morze.postgres.extensions` is the canonicalized `PG_EXTENSIONS` selection, not a catalog read-back. Neither `pg_available_extensions` (everything installable) nor `pg_extension` (what one database created) describes the build selection. Consequence: `pg_stat_statements` sits outside the label and the README must say so. |
| 11 | `LOCKED` | `pg_stat_statements.max` and `.track` move out of the base config along with the preload line and the `cron.*` block. They sit after `include_dir` ([postgresql.conf:890-891](../images/postgres/rootfs/postgresql.conf#L890-L891)), so leaving them would let the base file override the generated extension config — making this RFC's precedence claim false exactly where it generates settings. |
| 12 | `LOCKED` | Preload order is preserved (`pg_cron,pg_stat_statements`), and equivalence is asserted on effective server state rather than on file contents. Load order is observable, and a refactor claiming "nothing changed" must not reorder it silently. |
| 13 | `LOCKED` | The manifest ships only extensions the image actually installs; unadmitted ones are not rows and do not appear in executable examples. Decision 4 makes manifest membership the definition of a valid input, so a speculative row advertises a build that fails. |
| 14 | `ASSUMED` | **Added by execution 2026-08-16 — see [EXECUTION-LOG.md](EXECUTION-LOG.md) D-001.** Supersedes the column set in row 5, under the departure row 5 pre-authorised ("a new column, not a second mechanism"). The manifest is **five** columns: `name : package : sql_name : preload : snippet`. The SQL name is explicit because it is not derivable from the preload library — `pgroonga` has a control file and no preload, `cron` has both and they differ from its logical name — and §5.2's control-file gate and §5.4's label mapping each require it. Consequence: adding an extension means filling five fields, and a row with an empty SQL name fails the build rather than skipping the availability check. |
| 15 | `ASSUMED` | **Added by execution 2026-08-16 — see [EXECUTION-LOG.md](EXECUTION-LOG.md) D-006.** §6's equivalence check is a **one-shot merge gate**, and its result is recorded in the execution log rather than kept runnable. The reference it compares against is the last `:18.6` published before the refactor, **by digest**. Two consequences, the second found while verifying the first: that reference fixes the base image and package versions as they were, so a later difference may be an upstream change rather than a regression; and **an untagged digest is not durable in this registry** — `cleanup-images.yaml` deletes untagged versions weekly, and a dry run on 2026-08-16 listed `sha256:9934cb32…` among them. A digest reference survives a repointed tag; it does not survive this repo's own garbage collection. Keeping one means giving it a tag. **Superseded in part by execution 2026-08-17 — see [EXECUTION-LOG.md](EXECUTION-LOG.md) D-036's group.** `sha256:9934cb32…` was deleted by the 04:49 UTC cleanup that morning, before it could be tagged, so this reference is gone and §6's result stands only as the log entry that recorded it. The durable form was already available and this row asked for the wrong thing: **a dated tag** from decision 12's tag policy is immutable and never repointed, so it cannot become untagged and cannot be collected. `9934cb32` had none because it predates the policy. An equivalence reference is therefore named as `postgres:<version>-<stamp>`, and RFC 0001 P4's own check used one — needing no registry write at all. |

| 16 | `ASSUMED` | **Added by execution 2026-08-17 — see [EXECUTION-LOG.md](EXECUTION-LOG.md) D-040.** The extensions label is written by the **Dockerfile** from the `PG_EXTENSIONS` build arg, not by `docker-bake.hcl` beside the tags as §5.3's sketch has it. Two literals — one for `args`, one for `labels` — can disagree, and measurably did: `--set postgres.args.PG_EXTENSIONS=pgroonga` produced an image containing pgroonga alone that still claimed `cron pgroonga`, which decision 10 forbids. One string, read where the install reads it, and build-extensions' canonical-order refusal makes that string the canonical one. This is decision 1's rule — generated from the same input that drives the install, never hand-written — applied to the label as well as the preload line. |
| 17 | `ASSUMED` | **Added by execution 2026-08-17 — see [EXECUTION-LOG.md](EXECUTION-LOG.md) D-041.** Extension sets are written **literally per target** and there is no `POSTGRES_EXTENSIONS` bake variable. A bake variable is settable from the environment, so anything exporting that name changed what `postgres:<version>` contained while its tags stayed put — wave 1's R-7. Consequence: a local experiment is `--set postgres.args.PG_EXTENSIONS=...`, which is explicit about being a one-off, and row 16 keeps its label honest. |
| 18 | `ASSUMED` | **Added by execution 2026-08-17 — see [EXECUTION-LOG.md](EXECUTION-LOG.md) D-042.** CI resolves a target's smoke script from its **bake context** (`<context>/smoke.sh`), in both workflows. Iterating `images/*/smoke.sh` tests one image per directory, which silently skipped every variant — built by CI, never smoked, then refused at publish for having no script of its own. §6's build-mechanism tests live in `images/postgres/test-extensions.sh` for the same reason: they assert what a bad `PG_EXTENSIONS` does to a *build*, which no per-image smoke script can see. |

## 12. Phasing

- **P1 — manifest + generation + default build only.** No new variant. The whole
  deliverable is that today's image is produced by the new mechanism and §6's
  equivalence test proves it. Merge this alone.
- **P2 — the first real variant**, driven by whichever extension has a consumer.
  If that is pgmq, it is what unblocks RFC 0006's gate; if it is pgvector, RFC
  0006 waits.
- **P3 — the `io.morze.*` label and README documentation.** Separable from P1 and
  worth landing with P2, when there is more than one thing for the label to
  distinguish.
