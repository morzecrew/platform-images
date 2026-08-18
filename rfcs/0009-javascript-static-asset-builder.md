# RFC 0009 — JavaScript static-asset builder

- **Status:** 🚧 In progress — **P1 shipped 2026-08-18** in wave 8
  ([images/npm-builder](../images/npm-builder)), verified by §6's battery per
  decision 11. P2 and P3 are migrations in other repositories and are not this
  repo's to ship. The completion criterion is that §12's phases have shipped and
  §10 is answered or struck; **P1's half is met and the RFC stays In progress
  until at least one project adopts the image** — an unadopted builder is §9's
  risk and RFC 0003's retirement criterion, not a finished RFC.
  Wave 7 re-measured §2's evidence and found two claims wrong (§2's amendment,
  EXECUTION-LOG D-046), answered §10 questions 1 and 2, and closed decisions 7
  and 8 while adding 9, 10 and 11 (D-047). Wave 8 amended decision 9 to Node 24
  on the release schedule (D-048) and added decisions 12 and 13 (D-049, D-051).
  Question 3 — whether `morze-landing` can leave Node 16 — remains open and gates
  P3 only, not P1.
- **Scope:** One builder image that installs from a frozen lockfile, runs a
  project's build, and emits static assets at a known path — for the five Morze
  projects that build JavaScript and serve the result from a web server. Covers
  the builder, the output contract, build-time environment variables, and the
  handoff to this repo's existing `caddy` image as the runtime. Does **not** ship
  a runtime image, a Node runtime, or a distroless base: measurement found no
  project that executes Node in production, which is why RFC 0008 was superseded
  rather than executed.
- **Related:** [RFC 0008](0008-javascript-builder-and-distroless-runtime-pair.md)
  (superseded by this; its §3.1 carries the measurement),
  [images/caddy](../images/caddy) — the runtime half, already published and
  already used by `erp-frontend`;
  [images/uv-builder](../images/uv-builder) — the shape being mirrored;
  [images/README.md](../images/README.md) (admission), RFC 0002 (smoke tests).
- **Origin:** RFC 0008, re-cut after its gate measurement contradicted its
  design.

---

## 1. Summary

`<pm>-builder` for JavaScript: a pinned Node image, an integrity-pinned package
manager, a warm dependency cache, and a `build-js-app` helper that installs with
a frozen lockfile, runs the project's build, and leaves static assets at one
known path. The runtime is `ghcr.io/morzecrew/caddy`, which already exists and
already ships the SPA snippet two projects currently hand-write. There is no
second image in this RFC.

## 2. Motivation

Five projects build JavaScript and every one of them wrote the build stage
themselves. The results diverge in ways that are individually small and
collectively the argument for this image:

| Project | Node | Install | Output |
|---|---|---|---|
| `erp-frontend` | `node:20-alpine` | `npm ci`, ~~**with a cache mount**~~ **no cache mount** — corrected 2026-08-17, D-046 | `/app/dist` |
| `morze-ai-landing` | `node:20-bookworm-slim` | lockfile-detect chain | `/app/out` |
| `morze-erp-landing` | `node:20-bookworm-slim` | lockfile-detect chain | `/app/out` |
| `eis-dag` (frontend) | `node:22-alpine` | `npm install` | `/app/dist` |
| `morze-landing` | **`node:16`** | `npm install` + global webpack | `/app/build` |

Four things in that table are defects rather than preferences:

- **`node:16` is long past end of life.** A shared builder is how that stops
  being invisible — one variable, one bump, five projects.
- **Two projects use `npm install`, not `npm ci`**, so their builds do not
  respect the lockfile and can resolve differently on different days. That is the
  opposite of what a build stage is for.
- ~~**One project out of five has a cache mount.** The other four re-download the
  dependency tree on every build, which is the entire performance argument for
  sharing a builder, unrealised four times.~~
  **Corrected 2026-08-17 — see [EXECUTION-LOG.md](EXECUTION-LOG.md) D-046: it is
  zero of five.** No `--mount=type=cache` appears in any of the five
  Dockerfiles. The argument is unrealised five times, not four, so this bullet
  understated its own case.
- **`morze-ai-landing` and `morze-erp-landing` ship byte-identical Dockerfiles**
  whose build step is `npm run build || yarn build || pnpm build` — a fallback
  chain that runs whichever happens to work. Nobody wrote that on purpose twice;
  it was copied, and it will drift.

**The runtime half is already solved.** Three of the five serve from Caddy and
~~one of those three already uses `ghcr.io/morzecrew/caddy:2.11`~~ **all three use
upstream Caddy from Docker Hub — corrected 2026-08-17, D-046.** The two landings
hand-write a Caddyfile with an SPA `try_files` fallback that
[`snippets/spa.caddy`](../images/caddy/rootfs/snippets/spa.caddy) already
provides. So the missing piece is a builder, not a pair.

**Amendment (2026-08-17, EXECUTION-LOG D-046).** Two claims above were measured
wrong, both about `erp-frontend`, and both load-bearing for decision 8, which
names it as the first migration *because* of them. Measured against the
repository's default branch, unchanged since 2026-05-09 and therefore in this
state when the RFC was written: it runs `npm ci` with **no** cache mount, and its
runtime is `caddy:2.11.1-alpine` from Docker Hub, not `ghcr.io/morzecrew/caddy`.
**None of the five consumes this repo's caddy image.**

It is consumed elsewhere, in a different role: an org-wide code search finds
`eis-backend` and `erp-backend` both building `containers/gateway` from
`ghcr.io/morzecrew/caddy:2.11.2`, using the `config.d` overlay and, in one case,
the Coraza overrides. So the image is proven in production as a reverse-proxy
gateway and unadopted as a static-asset runtime, which are different claims about
different halves of it.

Neither error weakens the RFC — both strengthen it. The performance argument is
unrealised across all five rather than four, and §5.4's runtime handoff is an
untried path rather than an established one, which makes the first migration
worth more than the RFC credited it: it introduces the cache mount and becomes
the first static-asset consumer of this repo's caddy image at the same time. What
it does invalidate is the reasoning behind decision 8, which §11 now records.

## 3. Current state

`uv-builder` is the shape: a full-fat build image with a helper script
(`build-uv-app`) that produces one tree at a known path, consumed by a separate
runtime image. This RFC mirrors the builder half and stops there.

**Why the runtime half is not mirrored.** RFC 0008 proposed
`node-distroless` alongside the builder, mirroring `python-distroless`. The
2026-08-12 sweep ([RFC 0008 §3.1](0008-javascript-builder-and-distroless-runtime-pair.md))
found that **no Morze project runs Node at runtime** — all five build static
assets and serve them from nginx or Caddy. A distroless Node runtime would have
been an image maintained for nobody, which RFC 0003 §2 prices as the most
expensive kind.

**That deletion removes most of RFC 0008's complexity, not just one image.** The
version-coupling apparatus — its decisions 2 and 5, all of §5.4, the
native-module smoke test — exists because a dependency tree built by one runtime
is *executed* by another, so their majors must not drift. Static assets execute
in a browser. There is no runtime Node to couple to, so the whole class of
failure that RFC 0008 was mostly about does not exist here.

**Package managers, measured.** `package-lock.json` in all five;
`pnpm-lock.yaml` additionally in the two landings; **no yarn lockfile and no bun
lockfile anywhere.** RFC 0008 §5.1 framed the manager choice as open between
four; the evidence says npm, with pnpm as the only real second.

## 4. Goals / Non-goals

**Goals**

- One Node major to bump, not five.
- Frozen-lockfile installs everywhere, including the two projects that do not do
  it today.
- A warm dependency cache in every build, ~~not one of five~~ **where today none
  of the five has one** (corrected 2026-08-17, D-046).
- A stated handoff to `caddy` so the runtime stops being re-invented.

**Non-goals**

- **A runtime image.** `caddy` is it. Projects on nginx either migrate or keep
  their own runtime stage; this RFC does not force that.
- **A Node runtime image.** No consumer — §3. *Reopens if* a project ships an SSR
  or API service in Node, which is a different admission under RFC 0003.
- **Framework-specific builders.** Vite, Next static export and CRA all appear in
  the table above with three different output directories; §5.2 handles that with
  a variable, not with framework knowledge.
- **Managing the projects' `nginx.conf`.** `eis-dag` proxies to an API from
  nginx; that is its business.

## 5. Design

### 5.1 The builder

`npm-builder`, mirroring `uv-builder`:

- `FROM node:<major>-<suite>`, one bake variable for the major, ~~per RFC 0008
  decision 10's pinning discipline (exact, integrity-checked `packageManager`;
  no reliance on Corepack's mutable Known Good Releases)~~ — **the pinning half
  is superseded by decision 10 (2026-08-17, EXECUTION-LOG D-047): Corepack is
  never in the path for npm, so the pin is the base image tag. The requirement is
  retained verbatim for a future `pnpm-builder`.** Major and suite are fixed by
  decision 9: `22`, Debian.
- ~~A cache mount on the npm store~~ **the npm store at a fixed `/cache`, over
  which the consumer mounts a cache** — which is the measurable win for ~~four~~
  **five** of five projects (corrected 2026-08-17, D-046 — none of them has one).
  **Amended by execution 2026-08-18 (decision 12, D-049): an image cannot carry
  a `--mount=type=cache`; that is a flag on the consumer's `RUN`.** The builder
  keeps the path, the README keeps the pattern.
- `build-js-app`, mirroring `build-uv-app`.

Named for the manager, per RFC 0008 decision 1, which survives supersession: npm
is what the evidence supports, and a pnpm builder later is a second image, not a
build arg.

### 5.2 The output contract

`uv-builder` can promise `/opt/venv` because a venv is one shape. JavaScript
build output is not: the five projects emit to `dist`, `out` and `build`,
determined by the framework, and no builder should pretend to know which.

So the contract is a variable, not a constant:

```text
BUILD_OUTPUT_DIR   # project's own output, relative to /app. Default: dist
APP_DIST=/srv      # where build-js-app copies it, always
```

`build-js-app` installs, builds, then copies `${BUILD_OUTPUT_DIR}` to `/srv` and
verifies it is non-empty and contains an `index.html`. The runtime stage then
copies `/srv` and nothing else — one path, whatever the framework called it.

**The non-empty check is the point.** A build that silently produces nothing —
wrong output dir, a build script that exited zero without emitting — currently
yields a container serving a 404 for every path, diagnosed in a browser. Failing
the build instead is the same fail-closed instinct as RFC 0001 decision 2.

`/srv` because that is where this repo's `caddy` image already puts static
content and what its `spa` snippet defaults to via `{$WEB_ROOT:/srv}`.

### 5.3 Build-time environment

Static builds bake configuration at build time and both patterns are already in
use: `eis-dag` passes `VITE_API_URL` as `ARG`→`ENV`, `morze-landing` passes four
`REACT_APP_*` args. The builder cannot enumerate these — they are the project's.

`build-js-app` therefore passes the environment through untouched and the project
declares its own `ARG`s. **This is the one place where RFC 0002's `mode=max`
provenance matters to a consumer:** build args are recorded in the attestation,
so anything secret must not travel this way. The image README says so, because a
`REACT_APP_*` variable is exactly the shape someone puts an API key in — and in a
static build it would end up in the shipped bundle regardless, which is the
larger of the two problems.

### 5.4 The runtime handoff

Documented, not enforced. A consuming Dockerfile becomes:

```dockerfile
FROM ghcr.io/morzecrew/npm-builder:24 AS build
COPY . .
RUN --mount=type=cache,target=/cache,sharing=locked build-js-app

FROM ghcr.io/morzecrew/caddy:2.11.4
COPY --from=build /srv /srv
# CONFIG_DIR fragment: `import spa`
```

**Corrected by execution 2026-08-18 (D-052).** The sketch above originally read
`npm-builder:22`, `caddy:2.11`, and a bare `RUN build-js-app`. The major is `24`
(decision 9); `2.11` is not a tag this repo publishes — the mutable tag carries
the patch, currently `2.11.4`; and the cache mount belongs on the consumer's
`RUN` (decision 12), so leaving it out of the one example everybody copies would
have made the cache benefit opt-out in practice.

The two landings replace a hand-written Caddyfile with `import spa`. That is the
whole runtime half, and it needs no new image.

### Alternatives considered

- **RFC 0008's builder + `node-distroless` pair.** Superseded: no consumer for
  the runtime (§3).
- **A `caddy` variant with assets baked in.** Collapses build and serve into one
  image and re-couples them; the point of a builder is that the runtime is
  already published and stable.
- **Normalising output to `dist` and requiring projects to configure their
  framework.** Fewer moving parts in the image, and it makes adoption a change to
  every project's build config. The variable is cheaper.
- **A pnpm builder now.** Two projects have a `pnpm-lock.yaml` *and* a
  `package-lock.json`, so it is not clear either actually uses pnpm. Measure
  before building a second image.

## 6. Tests

Per RFC 0002 §5.5, under rootless Podman:

- A fixture project builds and `/srv/index.html` exists.
- **A build emitting nothing fails**, rather than producing an empty `/srv`
  (§5.2). This is the check the image exists to add, so it is the one that must
  never be skipped.
- `BUILD_OUTPUT_DIR=out` and `=build` both work — the three real conventions.
- ~~The cache mount hits on a second build.~~ **Amended by execution 2026-08-18 (decision 12, D-049): the documented mount pattern genuinely reuses the store, asserted by making the second build offline — a cold or unshared cache fails with `ENOTCACHED` instead of silently refetching. Timing a build would be flaky; this is binary.**
- A lockfile that disagrees with `package.json` fails rather than resolving
  fresh — the defect two projects ship today.
- The built assets are served by `ghcr.io/morzecrew/caddy` with `import spa`, and
  a deep path returns `index.html` rather than 404.

## 7. Docs

- `images/npm-builder/README.md`: `build-js-app`, `BUILD_OUTPUT_DIR`, the `/srv`
  contract, and the §5.4 two-stage example in full.
- The build-arg warning from §5.3, worded so it covers both the attestation leak
  and the fact that a static bundle ships whatever it was built with.
- A migration note per current runtime: Caddy projects drop their Caddyfile for
  `import spa`; nginx projects keep theirs and lose nothing.

## 8. Out of scope

- **Migrating the five projects.** This RFC ships the image; adoption is each
  project's PR, and `morze-landing`'s Node 16 jump is the one that needs care.
- **SSR / Node runtime images.** Named as the reopening condition in §4.
- **A pnpm or bun builder.** Separate admissions.
- **Serving from nginx.** Two projects do; this repo publishes no nginx image and
  this RFC does not propose one.

## 9. Risks

- **Five projects, five build conventions, one helper.** `BUILD_OUTPUT_DIR`
  covers the difference that was measured; a sixth project with a stranger layout
  is the case that turns the helper into a configuration language. The mitigation
  is that projects can always ignore the helper and run their own build in the
  builder image.
- **Adoption is where this dies.** Every project has a working Dockerfile today,
  so nothing forces migration, and an unadopted builder is an image maintained
  for nobody within a year — RFC 0003's retirement rule applies to it as much as
  to anything. Landing it alongside one real migration is what makes it real.
- **The Node major becomes a shared bump.** A project pinned to an old major for
  a real reason is then blocked on everyone else, or forks. Two live majors
  (current LTS and previous) is the release valve, but `node:16` cannot be one of
  them.
- **`npm-builder` in the name commits to npm.** If the landings turn out to use
  pnpm in earnest, the name is wrong or there are two images. Deliberate — RFC
  0008 decision 1, kept.

## 10. Unresolved questions

1. ~~**Do the two landings actually build with pnpm or npm?** Both lockfiles are
   committed, which usually means one is stale. Determines whether the first
   builder is `npm-builder` alone.~~
   **Answered 2026-08-17 — see [EXECUTION-LOG.md](EXECUTION-LOG.md) D-046: npm.**
   Not by asking which lockfile is stale, which is unanswerable from outside the
   projects, but by reading what their build actually executes. Both landings run
   the same detect chain, and it tests `yarn.lock`, then `package-lock.json`,
   then `pnpm-lock.yaml`; neither has a `yarn.lock`, so `npm ci` wins on every
   build and `pnpm-lock.yaml` is never consulted. Whatever the authors intended,
   the shipped behaviour is npm, which is what decision 4 needs to know.
2. ~~**Which project migrates first?** `erp-frontend` is the closest — it already
   uses this repo's caddy image and already has `npm ci` with a cache mount, so
   its diff is nearly empty and it proves the contract.~~
   **Answered 2026-08-17 — still `erp-frontend`, but both stated reasons were
   false (D-046).** It does not use this repo's caddy image and has no cache
   mount. It remains the right first migration on the reasons that survive: Vite
   emitting to `dist` (the decision 7 default, so no variable to set), `npm ci`
   already, and Caddy already, so only the image references change. Note the
   repository named `erp-frontend` contains a package named `morze-crm-frontend`
   and a separate `morze-crm-frontend` repository also exists; decision 8 is
   pinned to the repository, not the package name.
3. **Can `morze-landing` move off Node 16 at all**, or does its webpack setup pin
   it? If it cannot, it is not a consumer, and the count drops to four.
4. Whether `BUILD_OUTPUT_DIR` should default to `dist` (two projects) or be
   required with no default (explicit, one more line per project).

## 11. Decisions

| # | Grade | Decision |
| --- | --- | --- |
| 1 | `LOCKED` | No runtime image. The runtime is the published `caddy` image, and a Node runtime is a separate admission with its own consumer. Consequence: RFC 0008's entire version-coupling apparatus is not inherited, because static assets have no runtime to couple to. |
| 2 | `LOCKED` | The builder emits to `/srv`, and an empty or `index.html`-less output **fails the build**. Serving a 404 for every path is the failure this image exists to remove, and it is currently diagnosed in a browser. |
| 3 | `LOCKED` | Installs use a frozen lockfile; a lockfile that disagrees with `package.json` fails. Two projects ship `npm install` today and are not reproducible. |
| 4 | `LOCKED` | One package manager per builder image, named in the image (inherited from RFC 0008 decision 1). npm first, on the evidence. |
| 5 | `ASSUMED` | `BUILD_OUTPUT_DIR` accommodates framework differences rather than requiring projects to reconfigure their build. Depart if a project's layout needs more than one path. |
| 6 | `ASSUMED` | Build-time environment passes through untouched, with the provenance and bundle-leak warning in the README rather than a mechanism. Depart if a secret-shaped variable needs actively refusing. |
| 7 | ~~`OPEN`~~ **Decided 2026-08-17 — see [EXECUTION-LOG.md](EXECUTION-LOG.md) D-047.** `ASSUMED` | **`BUILD_OUTPUT_DIR` defaults to `dist`**, and the failure message when the directory is missing or empty must name the variable, the path it looked at, and what it found. Measured across the five projects the split is `dist` 2, `out` 2, `build` 1 — a plurality, not a majority, so no default is right for most. It is defaulted anyway because a wrong default fails **loudly** at build time via §5.2's non-empty and `index.html` check, and requiring the variable buys explicitness against an error that is already caught, at the cost of one line in every consumer forever. The naming condition is what makes the loud failure a signpost instead of the same undiagnosable 404 one layer earlier. Original text: `BUILD_OUTPUT_DIR` default `dist`, or required (§10 question 4). |
| 8 | ~~`OPEN`~~ **Decided 2026-08-17 — see [EXECUTION-LOG.md](EXECUTION-LOG.md) D-047.** `ASSUMED` | **`erp-frontend` (the repository, not the package name) migrates first, and it does not land in the same PR** — see row 11 for why the same-PR half could not hold. Both reasons the original recommendation gave were false (D-046); it survives on the ones that are true. Original text: Which project migrates first, and whether it lands in the same PR as the image. Recommendation: `erp-frontend`, same PR — an unadopted builder is the §9 risk, and one migration is what proves the contract. |
| 9 | `ASSUMED` | **One builder target, one bake variable, Node ~~`22`~~ `24`.** Mirrors `uv-builder`'s shape exactly: `BUILDER_NODE_VERSION` feeds both the tag and the build arg, so image contents cannot move without the tag moving (EXECUTION-LOG D-041). ~~`22` rather than `24` because the newest consumer is already there and the three on `20` move one major, whereas starting at `24` makes every adopter jump two majors *while* adopting a new builder — two changes at once, which is how a broken build gets blamed on the wrong one.~~ **Amended by execution 2026-08-18 — see [EXECUTION-LOG.md](EXECUTION-LOG.md) D-048.** The premise was unverified when this row was written and is false: **Node 22 is in Maintenance (EOL 2027-04-30); 24 is Active LTS (EOL 2028-04-30)**. Shipping a new builder on 22 would schedule a second migration for every adopter within months of the first, and §9 frames the valve as "current LTS and previous". The migration-distance argument also does not survive the mechanism: the builder exists so the major lives in one place, and a consumer's edit is `npm-builder:22` → `npm-builder:24` either way. Build-tool compatibility risk concentrates in `morze-landing`'s `react-scripts` 5.0.1, which is P3 and gated regardless. Depart by adding a second target when a consumer actually needs another major (§9's release valve); `node:16` may never be one. **Added by execution 2026-08-17 — see [EXECUTION-LOG.md](EXECUTION-LOG.md) D-047.** |
| 10 | `ASSUMED` | **npm's version is pinned by the base image tag, and nothing fetches a package manager at build time.** §5.1's "exact, integrity-checked `packageManager`" is a Corepack mechanism, and npm ships *inside* the Node image, so Corepack is never in the path; honouring it literally would mean downloading npm over the network to overwrite the npm that came with a pinned base image, which lowers reproducibility rather than raising it. The requirement is not wrong, it is misfiled — it is retained in full for a future `pnpm-builder`, where Corepack *is* the mechanism and the pin does bite. Base image is `node:${NODE_VERSION}-${DEBIAN_SUITE}`, Debian rather than Alpine, mirroring `uv-builder` and keeping native modules on glibc. **Added by execution 2026-08-17 — see [EXECUTION-LOG.md](EXECUTION-LOG.md) D-047.** |
| 11 | `LOCKED` | **P1 is verified by §6's test battery; the first migration is adoption evidence and is tracked separately.** §12 said the migration "is what makes P1 verifiable", but that migration lives in another repository and cannot be in this repo's PR, so the requirement was unsatisfiable as written. It also conflated two things: §6's battery verifies the image (all three output conventions, the empty-output refusal, the lockfile disagreement, the caddy handoff), while a migration proves someone wants it — which is §9's risk and RFC 0003's retirement criterion, not a test. Graded `LOCKED` because it redefines what "shipped" means for this RFC and because the adoption half reaches outside this repository. Consequence: an unadopted `npm-builder` is subject to RFC 0003's retirement rule like any other image, and the log carries the named repository and date. **Added by execution 2026-08-17 — see [EXECUTION-LOG.md](EXECUTION-LOG.md) D-047.** |
| 12 | `ASSUMED` | **The builder fixes the npm store at `/cache`; the cache mount is the consumer's.** §5.1 listed "a cache mount on the npm store" as a property of the image and §6 tested that it "hits on a second build", but `--mount=type=cache` is a flag on a `RUN` instruction in the *consuming* Dockerfile — an image cannot carry one. What this image can keep is the path: `npm_config_cache=/cache`, documented, with `RUN --mount=type=cache,target=/cache,sharing=locked build-js-app` in the README's two-stage example so adopters get it by copying. §6's cache assertion becomes "the documented pattern genuinely reuses the store", proven by making the second build **offline** — a cold or unshared cache then fails with `ENOTCACHED` rather than silently refetching. `smoke.sh` asserts the path, because a moved path makes every consumer's mount stop matching with no error at all. **Added by execution 2026-08-18 — see [EXECUTION-LOG.md](EXECUTION-LOG.md) D-049.** |
| 13 | `ASSUMED` | **`BUILD_SCRIPT` defaults to `build`, and `NODE_ENV` / `CI` are deliberately left unset.** All five projects run `npm run build`; a script name that does not exist fails closed because `npm run` exits non-zero. The two unset variables are the load-bearing half: `NODE_ENV=production` makes `npm ci` skip devDependencies — where every one of these projects keeps its build tool, so the install succeeds and the build then fails on a missing binary — and `CI=true` makes `react-scripts` treat warnings as errors, failing builds that pass locally. Both look like build-stage hygiene. `smoke.sh` asserts both stay unset rather than trusting the comment. **Added by execution 2026-08-18 — see [EXECUTION-LOG.md](EXECUTION-LOG.md) D-051.** |

## 12. Phasing

- **P1 — the builder and `build-js-app`**, with §6's tests. ~~landed alongside one
  real migration (decision 8). The migration is not follow-up work; it is what
  makes P1 verifiable.~~ **Amended 2026-08-17 by decision 11 (`LOCKED`) — see
  [EXECUTION-LOG.md](EXECUTION-LOG.md) D-047.** The migration cannot be in this
  repository's PR, so it cannot gate this repository's phase. §6's battery
  verifies P1; the first migration is adoption evidence, carried in the execution
  log against a named repository. P1 ships when §6 passes, including the
  empty-output test §6 calls the one that must never be skipped.
- **P2 — the remaining Caddy-based projects**, which is mostly deleting
  hand-written Caddyfiles in favour of `import spa`.
- **P3 — `morze-landing`**, gated on §10 question 3. It is the project that most
  needs this and the one most likely to resist it.
