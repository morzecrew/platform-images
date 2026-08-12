# RFC 0009 — JavaScript static-asset builder

- **Status:** 📝 Draft — admitted under RFC 0003 route 1 (five hand-rolled Node
  build stages), design not started
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
| `erp-frontend` | `node:20-alpine` | `npm ci` **with a cache mount** | `/app/dist` |
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
- **One project out of five has a cache mount.** The other four re-download the
  dependency tree on every build, which is the entire performance argument for
  sharing a builder, unrealised four times.
- **`morze-ai-landing` and `morze-erp-landing` ship byte-identical Dockerfiles**
  whose build step is `npm run build || yarn build || pnpm build` — a fallback
  chain that runs whichever happens to work. Nobody wrote that on purpose twice;
  it was copied, and it will drift.

**The runtime half is already solved.** Three of the five serve from Caddy and
one of those three already uses `ghcr.io/morzecrew/caddy:2.11`. The two landings
hand-write a Caddyfile with an SPA `try_files` fallback that
[`snippets/spa.caddy`](../images/caddy/rootfs/snippets/spa.caddy) already
provides. So the missing piece is a builder, not a pair.

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
- A warm dependency cache in every build, not one of five.
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

- `FROM node:<major>-<suite>`, one bake variable for the major, per RFC 0008
  decision 10's pinning discipline (exact, integrity-checked `packageManager`;
  no reliance on Corepack's mutable Known Good Releases).
- A cache mount on the npm store, which is the measurable win for four of five
  projects.
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
FROM ghcr.io/morzecrew/npm-builder:22 AS build
COPY . .
RUN build-js-app

FROM ghcr.io/morzecrew/caddy:2.11
COPY --from=build /srv /srv
# CONFIG_DIR fragment: `import spa`
```

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
- The cache mount hits on a second build.
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

1. **Do the two landings actually build with pnpm or npm?** Both lockfiles are
   committed, which usually means one is stale. Determines whether the first
   builder is `npm-builder` alone.
2. **Which project migrates first?** `erp-frontend` is the closest — it already
   uses this repo's caddy image and already has `npm ci` with a cache mount, so
   its diff is nearly empty and it proves the contract.
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
| 7 | `OPEN` | `BUILD_OUTPUT_DIR` default `dist`, or required (§10 question 4). |
| 8 | `OPEN` | Which project migrates first, and whether it lands in the same PR as the image. Recommendation: `erp-frontend`, same PR — an unadopted builder is the §9 risk, and one migration is what proves the contract. |

## 12. Phasing

- **P1 — the builder and `build-js-app`**, with §6's tests, landed alongside one
  real migration (decision 8). The migration is not follow-up work; it is what
  makes P1 verifiable.
- **P2 — the remaining Caddy-based projects**, which is mostly deleting
  hand-written Caddyfiles in favour of `import spa`.
- **P3 — `morze-landing`**, gated on §10 question 3. It is the project that most
  needs this and the one most likely to resist it.
