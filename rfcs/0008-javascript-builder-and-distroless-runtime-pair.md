# RFC 0008 — JavaScript builder and distroless runtime pair

- **Status:** 📝 Draft — **demand-gated**, not scheduled. §5.1 is blocked on a
  decision no amount of design work can substitute for.
- **Gate:** Morze ships JS/TS services. If the stack is Python-only — which
  `uv-builder` and `python-distroless` suggest — this is an image maintained for
  nobody, which RFC 0003 §2 prices as the most expensive kind.
- **Scope:** A builder image that resolves dependencies and compiles, plus a
  distroless runtime that carries only what runs — the exact structural mirror of
  the existing Python pair. Covers the package-manager choice, the builder's
  helper script and cache mount, the runtime base, and the version coupling
  between the two. Also covers **fixing the same version-coupling defect that
  already exists in the Python pair** (§3), which is in scope because this design
  would otherwise copy it. Does **not** cover framework-specific builders, a dev
  image, or more than two live Node majors.
- **Related:** [images/uv-builder/Dockerfile](../images/uv-builder/Dockerfile),
  [images/uv-builder/rootfs/build.sh](../images/uv-builder/rootfs/build.sh),
  [images/python-distroless/Dockerfile](../images/python-distroless/Dockerfile),
  [docker-bake.hcl](../docker-bake.hcl),
  [.github/renovate.json](../.github/renovate.json), RFC 0002 (smoke tests),
  RFC 0003 (a pair is one admission).
- **Origin:** `candidate-images.md` §5.

---

## 1. Summary

If the gate opens: one builder image per package manager, named for it
(`pnpm-builder`, `bun-builder`), carrying a `build-js-app` helper that mirrors
`build-uv-app` — frozen-lockfile install, build, prune, emit a self-contained
tree at a known path — plus `node-distroless` on `gcr.io/distroless/nodejs<major>`,
non-root, with the Node major driven by **one** bake variable shared with the
builder.

Whether or not the gate opens, §5.4's coupling check is worth landing: the Python
pair has the same latent drift defect today, and it is a few lines to close.

## 2. Motivation

The Python pair proves the shape. `uv-builder` does dependency resolution,
wheel-building and aggressive pruning
([build.sh](../images/uv-builder/rootfs/build.sh), 109 lines of it);
`python-distroless` carries a Python runtime, a CA bundle, four shared libraries
and nothing else. The result is a small, non-root final image and a build stage
nobody rewrites per project.

JS has the same problem in a worse form: `node_modules` is famously large, the
distinction between build and runtime dependencies is real and rarely enforced,
and every project's Dockerfile reinvents the prune step. A shared builder is also
where a correct package-manager cache mount lives, which is the entire
performance argument.

## 3. Current state

No JS anywhere in the repo. What exists is the pattern to mirror — and one defect
in it.

**The pattern.** `uv-builder` sets `UV_PROJECT_ENVIRONMENT=/opt/venv`
([Dockerfile:14](../images/uv-builder/Dockerfile#L14)) and `build-uv-app` emits
exactly that tree; `python-distroless` is the runtime the tree is copied into.
The contract between them is "one self-contained directory at a known path", and
that is the contract §5.3 reuses.

**The defect, already present.** The two images' versions are **two independent
bake variables** with **two independent Renovate annotations**:
`BUILDER_PYTHON_VERSION = "3.14"` (extracted from `ghcr.io/astral-sh/uv` tags)
and `DISTROLESS_PYTHON_VERSION = "3.14.6"` (extracted from
`al3xos/python-distroless` tags). They agree today by convention only. Renovate
automerges ([renovate.json:10-13](../.github/renovate.json#L10-L13)), so when
Astral publishes a `python3.15-trixie` tag before the distroless publisher
catches up, the builder moves to 3.15 and the runtime stays on 3.14 — **with no
human in the loop**. A venv built for one minor, executed by another, produces
native-module ABI failures at runtime, not at build.

That is the worst failure timing available, and it is the same failure RFC
0008's Node pair would inherit. The Python pair is currently safe by luck, not
by construction.

**One asymmetry worth noting.** The Python side had to reach for a third-party
base — `al3xos/python-distroless` on Docker Hub — because Google's distroless
does not ship Python. Node is better supplied: `gcr.io/distroless/nodejs<major>`
is first-party. So the JS runtime half is on firmer ground than the Python one
it copies.

## 4. Goals / Non-goals

**Goals**

- A builder whose cache mount is right, so it is worth sharing.
- A runtime that carries no package manager and no compiler.
- Builder and runtime that cannot drift apart.

**Non-goals**

- **Framework-specific builders** (Next.js standalone, Nest, Remix). Each has its
  own output convention; baking one in makes this a framework image.
- **A dev/watch image.** Local dev is a bind mount and a plain Node image.
- **More than two live Node majors** (current LTS and previous).
- **A `node_modules` copy between stages.** §5.3 — the builder emits a tree, the
  runtime copies the tree.

## 5. Design

### 5.1 The hard question, first: which package manager

The Python side was easy — `uv` won, so `uv-builder` is a name with a meaning.
The JS side has npm, pnpm, yarn and bun in live use, and they differ in ways that
reach into the Dockerfile: pnpm's content-addressed store and symlinked
`node_modules` do not survive a naive `COPY` between stages, bun's lockfile is
binary, yarn PnP has no `node_modules` at all.

| Option | Trade-off |
|---|---|
| **One manager, named in the image** (`pnpm-builder`, `bun-builder`) | Honest, matches `uv-builder`, and a second manager later is a second image — which RFC 0003's bar would have to justify on its own. **Recommended.** |
| One image, manager by build arg | Looks economical. Produces one Dockerfile containing three incompatible cache-mount strategies, and a cache bug in one silently degrades the others. |
| One image, npm only | Safe, and misses most of the reason anyone wants this. |

**The choice must be made from evidence** — what existing Morze JS projects
already use — not from preference. If there are no existing JS projects, that is
the gate answering itself.

Nothing else in this RFC can be built first. A builder is its package manager.

### 5.2 Builder

`<pm>-builder`, mirroring `uv-builder`'s shape:

- Full Node image, pinned to an LTS major.
- The manager pinned by version via Corepack, never floating. A builder whose
  manager version drifts produces different lockfile resolutions on different
  days, which is the opposite of what a build stage is for.
- **A cache mount for the manager's store** (`RUN --mount=type=cache`). This is
  the entire performance argument for a shared builder image and it must be
  right — it is also the part most likely to be subtly wrong, since a cache mount
  that misses silently just makes builds slow.
- `build-js-app`, mirroring `build-uv-app`: install with a frozen lockfile, run
  the project's build, prune to production dependencies, emit a self-contained
  tree at a known path.

`build-uv-app`'s pruning switches ([build.sh:8-17](../images/uv-builder/rootfs/build.sh#L8-L17))
are the precedent for how aggressive the JS equivalent may be and how each step is
opt-out-able. The JS equivalents are not the same list — no `.pyi` files, no
`compileall` — and the list should be derived from measurement, not translated.

### 5.3 Runtime

`node-distroless` on `gcr.io/distroless/nodejs<major>`, non-root by default,
plus the CA bundle and whatever native libraries prove necessary — the Python
runtime's set (libmagic, libbz2, liblzma, libz;
[Dockerfile:47-51](../images/python-distroless/Dockerfile#L47-L51)) is a starting
hypothesis, not an answer.

The builder emits a self-contained tree; the runtime copies that tree and nothing
else. No `node_modules` copied between stages — that is precisely the operation
pnpm's symlink layout and yarn PnP break, and forbidding it is what lets the
builder choice stay open.

### 5.4 Version coupling — one variable, both images, both pairs

The builder's Node major and the runtime's distroless major **must** come from
one bake variable:

```hcl
variable "NODE_MAJOR" { default = "22" }

target "pnpm-builder"  { args = { NODE_MAJOR = NODE_MAJOR }, tags = tag("pnpm-builder", NODE_MAJOR) }
target "node-distroless" { args = { NODE_MAJOR = NODE_MAJOR }, tags = tag("node-distroless", NODE_MAJOR) }
```

A mismatched pair silently produces native-module ABI failures at runtime, not at
build. One variable makes the mismatch unrepresentable.

**The same treatment is owed to the Python pair** (§3). Its two variables cannot
simply be merged — one is a minor (`3.14`) and one a patch (`3.14.6`) drawn from
different registries — so the fix is a **CI assertion that the two agree on
major.minor**, failing the build when they do not. That check costs a few lines,
catches an automerged Renovate PR before it publishes, and is worth landing
whether or not this RFC's gate ever opens.

### 5.5 Bun is a third target, not a variant

`bun build --compile` produces a single binary, so the runtime is
`distroless/base` and there is no Node at all — a cleaner result and a much
smaller image. But it shares neither the builder's cache strategy nor the
runtime's base with the Node pair. It is a *third* target, and the RFC treats it
as such: choosing bun in §5.1 means not building the Node pair, not building a
variant of it.

### Alternatives considered

- **A single `js-builder` with a manager build arg.** §5.1, rejected.
- **Alpine or slim runtime instead of distroless.** Easier native-module story
  and a debuggable shell; abandons the property that makes the Python pair worth
  copying.
- **Skipping the builder image, documenting a multi-stage Dockerfile instead.**
  Genuinely viable for JS, since there is no `uv`-scale tool to encapsulate. The
  cache mount and the prune step are what tip it — those are what get copied
  wrong.

## 6. Tests

Per RFC 0002 §5.5, plus one that is specific and non-negotiable:

- **A native-module smoke test.** A package with a compiled binding, installed
  and built by the builder, then **actually `require`d in the runtime image**.
  Without this, §5.4's coupling is a hope rather than a guarantee — and the
  failure it guards against does not appear at build time.
- The builder's cache mount demonstrably hits on a second build.
- `build-js-app` fails on a lockfile that does not match `package.json`, rather
  than resolving fresh.
- The runtime runs as non-root and contains no package manager binary.
- **For the Python pair:** the §5.4 assertion fails when `BUILDER_PYTHON_VERSION`
  and `DISTROLESS_PYTHON_VERSION` disagree on major.minor. Testable today,
  against the images that already exist.

## 7. Docs

`images/<pm>-builder/README.md` and `images/node-distroless/README.md`, in the
shape the Python pair already uses — each stating that it is half of a pair, and
both stating that the majors are coupled and why.

The root README's images table gains two rows; RFC 0003 §2's other six touchpoints
apply once, since a pair is one admission.

## 8. Out of scope

- **A second package manager**, unless and until a second project needs one.
  Explicitly a new admission under RFC 0003, not an extension of this one.
- **`node_modules`-based runtimes** (a runtime that installs at start).
- **ARM builds** — RFC 0002 §4 excludes them repo-wide.
- **Publishing the built app** — this pair produces images, not artifacts.

## 9. Risks

- **Maintained for nobody.** Restated because it is the actual risk. Node LTS
  turns over yearly and package managers more often, so this is the pair most
  likely to be stale, and staleness in a build stage is invisible until someone
  tries to use it.
- **Distroless Node lags Node releases**, so the major that is current may not
  exist as a distroless base yet. Check before pinning; the coupling in §5.4
  means the *builder* cannot move ahead of the runtime either, which converts a
  silent breakage into a blocked bump. That is the intended trade.
- **The cache mount is the value and the failure mode.** A cache that silently
  misses looks like a working image, just slower, and nobody investigates a slow
  build to the point of finding it. Hence the §6 test.
- **`uv-builder`'s pruning aggressiveness is not transferable.** Deleting `*.py`
  sources and stripping `.so` files works because Python has a bytecode story;
  the JS equivalents are different and mostly less safe. Translating the switch
  list rather than deriving it would produce a builder that breaks source maps
  and stack traces.
- **The Python coupling fix touches a shipped, working pair.** It only adds a
  check, and the check's failure mode is a red build rather than a bad image.

## 10. Unresolved questions

1. **Is JS a real target for Morze at all?** The gate. Nothing else matters
   first.
2. **Which manager**, measured by what existing projects already use (§5.1).
3. **Which Node majors exist as distroless bases** at the time of pinning (§9).
4. **Does `python-distroless`'s libmagic/CA-bundle approach transfer**, or does
   distroless Node need a different native-library set (§5.3)?
5. Whether the Python coupling check belongs in `bake.yaml` as a step or in the
   bake file as an HCL-level assertion. The second fails earlier and locally;
   whether HCL can express it in the pinned buildx is unverified.

## 11. Decisions

| # | Grade | Decision |
| --- | --- | --- |
| 1 | `LOCKED` | One package manager per builder image, named in the image. A second manager is a second image and a separate RFC 0003 admission. |
| 2 | `LOCKED` | The Node major is one bake variable driving both images, making a mismatched pair unrepresentable. Consequence: the builder cannot move to a major that has no distroless base yet — a deliberate block over a silent runtime failure. |
| 3 | `LOCKED` | Non-root in the runtime by default, matching `python-distroless`'s `65532:65532`. |
| 4 | `LOCKED` | The builder emits a self-contained tree at a known path; the runtime copies that and nothing else. No `node_modules` copy between stages — that is what pnpm's symlink store and yarn PnP break. |
| 5 | `LOCKED` | The native-module smoke test (§6) ships with the pair. Without it decision 2 is unverified, and its failure mode is invisible at build time. |
| 6 | `ASSUMED` | The version-coupling check applies to the Python pair too, and lands independently of this RFC's gate. Depart only if it proves impossible to express — not because the pair "already agrees". |
| 7 | `ASSUMED` | Bun, if chosen, replaces the Node pair rather than extending it (§5.5). |
| 8 | `OPEN` | The `build-js-app` prune list. Derive it by measuring what a real project's tree contains; do not translate `build-uv-app`'s switches, which are Python-specific and more aggressive than JS tolerates. |
| 9 | `OPEN` | Where the Python coupling assertion lives — CI step or HCL assertion (§10 question 5). |

## 12. Phasing

- **P0 — the Python coupling check.** Not gated on anything in this RFC. It
  closes an existing latent defect (§3) and proves §5.4's mechanism before any JS
  image exists. If this RFC's gate never opens, this is what it delivered.
- **P1 — the manager decision** (§5.1). Nothing else until it is made.
- **P2 — builder** with cache mount and the frozen-lockfile helper.
- **P3 — distroless runtime**, single-variable major coupling, and the
  native-module smoke test.
