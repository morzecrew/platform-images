# RFC 0002 — Publishing pipeline: attestations, tag policy, rebuild cadence

- **Status:** 🚧 In progress — **all four phases shipped; one claim still
  unverified against GHCR.** P1's labels and attestation declaration landed
  2026-08-12 ([docker-bake.hcl](../docker-bake.hcl), verified with
  `bake --print`); P2's tag policy and P3's rootless smoke stage landed
  2026-08-16 in wave 1; P4's weekly rebuild and smoke gate landed 2026-08-16 in
  wave 2. Execution found §5.2's specified syntax is silently ignored by buildx
  (§5.2a, decision 13) and that §5.3's stamp was not unique per build (decision
  17, EXECUTION-LOG D-009).
  **Attestations on published images remain unverified.** The full
  build → push-by-digest → smoke → promote gate is measured end to end, but
  against a throwaway local registry (EXECUTION-LOG D-008, D-010). §6's
  `imagetools inspect` against a real GHCR digest is what turns the declaration
  into a fact, and only a real publishing run can produce one.
- **Scope:** What a published `ghcr.io/morzecrew/*` tag guarantees about itself.
  Covers the OCI label set in [docker-bake.hcl](../docker-bake.hcl), buildx
  provenance and SBOM attestations, a stated tag-mutability policy with an
  immutable companion tag, a scheduled rebuild of the default group, and a
  rootless-Podman smoke-test stage in CI. Does **not** cover image content,
  runtime configuration (RFC 0001), which images exist (RFC 0003), or signing
  with cosign/Sigstore — the last is named in §8 as the deliberate next step,
  not built here. Nothing here blocks another RFC; the one place this RFC leans
  on RFC 0001 (the smoke stage's startup-summary assertion) is written as a
  conditional so the ordering stays free, §5.5.
- **Related:** [docker-bake.hcl](../docker-bake.hcl),
  [.github/workflows/publish.yaml](../.github/workflows/publish.yaml),
  [.github/workflows/bake.yaml](../.github/workflows/bake.yaml),
  [.github/workflows/cleanup-images.yaml](../.github/workflows/cleanup-images.yaml),
  [.github/renovate.json](../.github/renovate.json), [justfile](../justfile),
  [LICENSE](../LICENSE). Consumed by every image RFC; blocks none of them.
- **Origin:** `candidate-images.md` §1.2 and §7, written without repo access —
  two of its five items are already shipped and are corrected in §3.

---

## 1. Summary

Finish the metadata half of publishing: add `.revision`, `.created` and
`.description` to the existing label function, turn on `provenance` and `sbom`
in the bake file, and publish an immutable `:<version>-<yyyymmdd>` alongside the
existing mutable `:<version>`. Add a weekly scheduled rebuild so base-image CVE
fixes reach consumers without a version bump, and a rootless-Podman smoke stage
so the assumptions Docker hides fail in CI rather than in an air-gapped install.

## 2. Motivation

The repo publishes to a public registry and consumers cannot currently answer
three questions from the artifact alone: *what commit built this*, *what is
inside it*, and *will this tag still mean the same thing tomorrow*. The first two
are one bake-file line each. The third is a policy decision that costs nothing
now and cannot be made retroactively — a consumer who pinned `:18.4` in June has
already been given whatever answer we never wrote down.

The rebuild cadence is the load-bearing one. Renovate is configured and
automerging ([renovate.json:10-13](../.github/renovate.json#L10-L13)), so a new
`postgres:18.5` upstream tag flows to a merged PR and a publish run without human
action — genuinely good, and it covers exactly one case: *upstream published a
new version tag*. It does not cover a Debian security update landing inside an
unchanged `postgres:18.4` tag, which is the ordinary shape of a base-image CVE.
Today that fix reaches `ghcr.io/morzecrew/postgres:18.4` only when something
unrelated triggers a publish.

`cleanup-images.yaml` already runs on `cron: "0 4 * * 1"`, so the scheduling
machinery and its permission model are proven in this repo — the rebuild is the
same shape.

## 3. Current state

**Labels: mostly done.** `docker-bake.hcl`'s `label()` function emits
`org.opencontainers.image.title`, `.version`, `.licenses` (`MIT`), `.vendor` and
`.source` (the GitHub repo URL) for all five targets.

> **Correction.** `candidate-images.md` §1.2 claims there is no LICENSE and that
> images may be unlabelled. [LICENSE](../LICENSE) exists (MIT, commit `b5944b1`)
> and `.source` has been set for every target. Missing are `.revision`,
> `.created` and `.description`. An empty GHCR Packages panel, if still empty, is
> not a labelling problem.

**Attestations: not set.** The bake file has no `provenance` or `sbom`
attributes. Buildx emits provenance at `mode=min` by default for
`--push` builds with the container driver and emits no SBOM at all, so today's
pushes carry a minimal provenance attestation and nothing describing contents.
[cleanup-images.yaml:54-56](../.github/workflows/cleanup-images.yaml#L54-L56)
already accounts for this — its comment notes that buildx pushes an OCI index
whose platform manifest and provenance attestation both appear as untagged
versions, and the cleanup action is configured to keep them.

**Tags: mutable, undocumented.** `tag()` produces exactly one tag per target,
`ghcr.io/morzecrew/<name>:<version>` from a bake variable
(`POSTGRES_VERSION = "18.4"`, `CADDY_VERSION = "2.11.4"`, …). Every publish
repoints it. Neither README states this. There is no `latest`, no digest
guidance, and no immutable alias.

**Triggers.** `publish.yaml` runs on push to `main` filtered to
`docker-bake.hcl`, `images/**`, `justfile`. `bake.yaml` builds without pushing on
PRs with the same filter. There is no schedule on either. Both filters list
`.github/workflows/*.yml` while the files are named `.yaml`
([publish.yaml:11](../.github/workflows/publish.yaml#L11),
[bake.yaml:10](../.github/workflows/bake.yaml#L10)) — that entry matches nothing,
so a workflow-only edit does not trigger its own workflow. Harmless today,
confusing exactly once.

**CI tests nothing.** `bake.yaml` runs `just bake` and passes if the images
build. No container is started. Every behavioural claim in every image README is
currently unverified by CI.

**`PACKAGES` is hand-maintained.** `cleanup-images.yaml:31` hardcodes
`flyway,caddy,postgres,uv-builder,python-distroless` with a comment to keep it in
sync when adding an image — a per-new-image cost that RFC 0003 counts.

## 4. Goals / Non-goals

**Goals**

- A published tag that answers "what commit, what contents, what license" from
  its own metadata.
- A stated, documented answer to "can I pin this tag".
- Base-image CVE fixes reaching consumers without waiting on a version bump.
- CI that starts each image at least once, rootless.

**Non-goals**

- **Signing.** Cosign/Sigstore keyless signing is the natural next step and is
  deliberately not in this RFC — see §8.
- **Multi-architecture builds.** Nothing here adds `linux/arm64`; the images are
  `amd64` today and `python-distroless` copies `x86_64`-specific library paths
  ([Dockerfile:47-50](../images/python-distroless/Dockerfile#L47-L50)).
- **A `latest` tag.** Ambiguous by construction for a set of independently
  versioned images.
- **Changing how versions are chosen.** Renovate's custom manager for
  `docker-bake.hcl` works; this RFC adds a rebuild trigger beside it.

## 5. Design

### 5.1 Complete the label set

`label()` gains three entries, two of which need a value threaded in:

```hcl
variable "GIT_REVISION" { default = "" }   # set by CI: ${{ github.sha }}
variable "BUILD_DATE"   { default = "" }   # set by CI: RFC 3339, UTC
variable "BUILD_STAMP"  { default = "" }   # set by CI: see §5.3; empty = no dated tag

function "label" {
  params = [name, version]
  result = {
    # … existing five …
    "org.opencontainers.image.revision"    = GIT_REVISION
    "org.opencontainers.image.created"     = BUILD_DATE
    "org.opencontainers.image.description" = DESCRIPTIONS[name]
  }
}
```

`GIT_REVISION` and `BUILD_DATE` default to empty so a local `just bake` stays
reproducible and does not bust the cache on every invocation; CI passes both.
`.description` comes from a map in the bake file keyed by image name, so the
string that GHCR shows and the string in the root README come from one place.

### 5.2 Attestations

```hcl
target "_common" {
  provenance = "mode=max"
  sbom       = true
}
```

with every target inheriting it — **but not in that syntax; see §5.2a.**
`mode=max` over the default `min` because `min`
records only the materials, and the question a consumer actually asks — which
build steps ran — needs `max`. Both are free at build time and both are exactly
the material a deployment-attestation chain consumes upstream; turning them on
later does not retroactively attest anything already published, which is why this
is worth doing before the four candidate images rather than after.

The cleanup workflow already keeps attestation manifests
([cleanup-images.yaml:54-56](../.github/workflows/cleanup-images.yaml#L54-L56)),
so no change is needed there — but the SBOM manifests are new untagged children
and that behaviour must be re-verified with `dry_run: true` after the first
attested publish. A cleanup job that eats SBOMs is worse than no SBOM, because
the metadata claims coverage that no longer resolves.

### 5.2a Amendment (2026-08-12): the shorthand is silently ignored

§5.2 above specifies `provenance = "mode=max"` and `sbom = true`. **On buildx
0.35 those attributes are accepted without error and produce no attestation at
all** — verified with `bake --print`, which emits no `attest` entry for a target
carrying them, whether inherited or set directly.

The working form is the list:

```hcl
target "_attested" {
  attest = [
    "type=provenance,mode=max",
    "type=sbom",
  ]
}
```

which does inherit correctly and does appear in `--print`.

This is the failure mode this RFC is otherwise about: a green build claiming
coverage it does not have. Had P1 shipped as written, every published image would
have carried the *documentation* of attestations and none of the attestations,
and the gap would have surfaced only when a consumer went looking for an SBOM
that was never there. §6's first check — inspect a published image for the
attestation manifests — is what turns that from a documentation claim into a
tested one, and it should run against the first attested publish rather than
being deferred.

The §5.2 text above is left as written rather than corrected in place, so the
record shows the design was cut before the syntax was verified.

### 5.3 Tag policy: mutable and immutable, both

`tag()` returns a list, so a second tag is one line:

```hcl
function "tag" {
  params = [name, version]
  result = [
    "ghcr.io/morzecrew/${name}:${version}",
    "ghcr.io/morzecrew/${name}:${version}-${BUILD_STAMP}",
  ]
}
```

- **`:<version>`** — mutable, repointed on every rebuild. Consumers who want CVE
  fixes without action track this. This is what happens today; the change is
  saying so.
- **`:<version>-<stamp>`** — written once, never repointed. Consumers who need a
  fixed artifact pin this, or pin the digest.

**The stamp must be unique per build, not per day.** A bare `<yyyymmdd>` is
repointed by the second build on the same date, which contradicts "written once"
outright — an immutable tag that silently moves is worse than no immutable tag,
because consumers pinned it precisely to avoid that. So the stamp is
`<yyyymmdd>-<run>`, where ~~`<run>` is the CI run number: monotonic, unique, and
already available~~ — **corrected by execution 2026-08-16, see
[EXECUTION-LOG.md](EXECUTION-LOG.md) D-009.** `<run>` is
`<run_id>.<run_attempt>`. `github.run_number` is not unique per build and
neither is `github.run_id`: **neither changes when a run is re-run**, and a
re-run rebuilds against moved upstream state, so either alone would repoint the
tag this section calls immutable. Only `run_attempt` increments. Not a git short
SHA — two rebuilds of an unchanged tree
produce different images (that is the whole point of §5.4), so the SHA would
collide exactly when the date-based stamp must not.

`BUILD_STAMP` is declared with an empty default and set only by publish CI. When
it is empty, `tag()` emits the mutable tag alone — a developer's
`just bake postgres` should not mint dated tags.

**Neither tag is a substitute for the digest**, and the README says so: the
digest is the only true immutable reference, the dated tag is the ergonomic
approximation.

### 5.4 Weekly rebuild

A `schedule` trigger on `publish.yaml`, mirroring the cleanup workflow's existing
cron:

```yaml
on:
  schedule:
    - cron: "0 5 * * 1"   # Mondays, an hour after cleanup-images
  workflow_dispatch:
```

The scheduled run builds the `default` group with `--no-cache`, because a cached
build is precisely the thing that will not pick up a rebuilt base layer. That
makes the weekly run slow and correct; the push-triggered run stays cached and
fast.

**Build once, smoke-test that artifact, then push it.** The obvious arrangement —
smoke tests in `bake.yaml`, an independent `--no-cache` rebuild in
`publish.yaml` — tests one artifact and publishes a different one. Two builds of
the same tree are not the same image (that is §5.4's entire premise), so a green
smoke stage would say nothing about the bytes that reached the registry. Instead
every publishing run is one job that builds to a local OCI layout
(`--set *.output=type=oci,dest=…` or a loaded image), runs §5.5's smoke script
against **that** artifact, and pushes it only if the script passes. The digest
tested is the digest published, and the gate is a gate rather than a coincidence.

**The mechanism above is superseded by decision 20 (2026-08-16); the property
it exists for is not.** The local OCI layout cannot publish the artifact it
tested without a second push step that re-derives it, so the built gate is
**push-by-digest → pull that digest → smoke → `imagetools create`**. "The digest
tested is the digest published" is unchanged and is now literally true: the
smoke stage pulls the object the registry already holds.

Consequence to state plainly in the README: **on the mutable tag, the bytes
behind `:18.4` change weekly even when nothing in this repo changed.** That is
the intended behaviour and it is exactly why §5.3's dated tag exists.

### 5.5 Rootless smoke stage

`bake.yaml` gains a job after `bake` that loads each image and starts it under
**rootless Podman** — available on `ubuntu-latest` runners without setup — with a
per-image `images/<name>/smoke.sh`:

- The container starts and stays up for a fixed interval.
- Its health signal responds where it has one (`caddy`'s `HEALTH_PATH`, default
  `/__platform_healthz`; `pg_isready` for Postgres).
- **Conditionally**, once RFC 0001 has shipped for that image: its startup
  summary appears before the server's first log line. This assertion is skipped
  on images that do not yet emit one, so the smoke stage can land before RFC 0001
  rather than after it (§scope, and decision 10).
- Build-stage images (`uv-builder`, `flyway`) run their entrypoint helper with
  `--help`-equivalent instead; `python-distroless` runs `python -c` importing
  `magic`, which is the one claim its README makes that a build cannot verify.

  **Superseded by decision 18 (2026-08-16)** for `uv-builder`: `build-uv-app`
  has no `--help` and no argument parsing, so the `--help`-equivalent
  invocation would be a build. The smoke test asserts toolchain presence and
  helper validity instead. `flyway` and `python-distroless` are unaffected.

Rootless rather than Docker because rootless is where UID mapping, volume
ownership and sub-1024 port binds actually fail. `caddy` already listens on
`:8080` ([Dockerfile:96](../images/caddy/Dockerfile#L96)) and
`python-distroless` already runs as `65532:65532`
([Dockerfile:56](../images/python-distroless/Dockerfile#L56)), so both are
plausibly rootless-clean today — the point is to keep them that way as four more
images arrive.

### Alternatives considered

- **Immutable-only tags** (`:18.4-20260812` and nothing else). Honest, and it
  makes every consumer edit a file to get a CVE fix, which in practice means they
  do not. Rejected: the mutable tag is what makes the weekly rebuild useful.
- **`latest`.** Rejected in §4 — meaningless across five independently versioned
  images.
- **Rebuild by opening a Renovate-style PR instead of pushing.** More reviewable,
  but a rebuild has no diff to review; the review would be of a green checkmark.
- **Docker instead of Podman for smoke tests.** Simpler, and it hides exactly the
  class of bug the stage exists to catch.

## 6. Tests

The smoke stage of §5.5 is itself most of this RFC's verification. Beyond it:

- After the first attested publish, `docker buildx imagetools inspect` shows the
  provenance and SBOM manifests, and a `dry_run: true` cleanup run reports zero
  deletions against them.

  **Amendment (2026-08-16, EXECUTION-LOG D-029):** "zero deletions" is the wrong
  universal. The first real dry run reported **69**, every one of them an
  untagged pre-tag-policy publish, which is the mechanism working rather than
  failing. The property to test is **zero deletions of anything the gate
  published** — current digests and their attestation manifests — and that is
  what was verified. A weekly rebuild orphans the previous week's digest by
  design, so the count is expected to be non-zero forever.
- `docker inspect` on a published image shows all eight labels populated, with
  `.revision` matching the commit that produced it.
- The dated tag and the mutable tag resolve to the same digest immediately after
  a publish, and diverge after the next one.
- A local `just bake postgres` produces exactly one tag and no dated alias.

## 7. Docs

- Root [README.md](../README.md) gains a **Consuming these images** section: the
  two tag forms, which to pin for what, the weekly-rebuild consequence stated
  without euphemism, and how to read the attestations.
- [images/README.md](../images/README.md) records that a new image must be added
  to the `default` group **and** to `cleanup-images.yaml`'s `PACKAGES` — the
  second is easy to forget and its failure is silent.
- The provenance/SBOM section must not overclaim: attestations describe what the
  build did, they are **unsigned** here, and an unsigned attestation is evidence,
  not proof. §8's cosign item is what would change that sentence.

## 8. Out of scope

- **Cosign / Sigstore keyless signing.** The natural successor and deliberately
  separate: it needs an identity policy (which workflow identity is trusted, by
  whom, verified where) that is a decision about consumers, not about this repo.
  Named as the next RFC, not built here. §5.2's attestations are its
  prerequisite.
- **Vulnerability scanning in CI** (Trivy/Grype gate on publish). Wanted, and it
  needs a severity policy and an allowlist mechanism or it becomes a permanently
  red check that everyone ignores. Reopens once the SBOM exists to scan.
- **`linux/arm64`.** Reopens when a consumer runs one; `python-distroless` needs
  real work first (§4).
- **Retention policy for dated tags.** They accumulate at one per image per week.
  `cleanup-images.yaml` deletes untagged versions only, so dated tags survive
  forever. Named here as a known future cost, with `older_than` on the existing
  cleanup action as the likely lever.

## 9. Risks

- **`--no-cache` weekly builds are slow and can fail on upstream flakiness** —
  the caddy build compiles Caddy with xcaddy and fetches CRS from GitHub
  ([Dockerfile:18-20,34](../images/caddy/Dockerfile#L18-L34)), and the flyway
  build pulls two JARs from two hosts. A scheduled failure that nobody watches is
  a rebuild cadence that exists only on paper. Mitigation: the schedule needs a
  failure notification, or it is theatre.
- **Weekly rebuilds change the bytes behind a mutable tag** for consumers who
  believed otherwise. Mitigated by §5.3 and by leading the README with it;
  unavoidable in kind, since the alternative is stale CVEs.
- **`mode=max` provenance records build arguments.** No current target passes a
  secret as a build arg — checked against all five — but this closes a door: any
  future `ARG` carrying a credential becomes publicly readable in the
  attestation. The README's build-arg guidance must say so.
- **Attestations read as security guarantees.** They are unsigned metadata that
  anyone with push access can produce. §7's wording is the mitigation.
- **The smoke stage becomes the thing people skip.** A flaky container start on a
  shared runner will be re-run rather than diagnosed. Keeping each smoke script
  to one assertion per README claim is what keeps it diagnosable.

## 10. Unresolved questions

- ~~Whether the weekly rebuild should push directly or build, smoke-test, then
  push.~~ **Settled** by decision 10: build once, test that artifact, push it.
  What remains is sequencing — P4 needs the §5.5 harness to exist first, which
  the phasing already orders.
- ~~Whether `BUILD_STAMP` should be a date or an ISO week.~~ **Settled** by
  decision 11: neither, since both are reused by a second build in the same
  period. It is `<yyyymmdd>-<run>`.
- ~~Whether the GHCR Packages panel is empty because nothing has been pushed or
  because of package visibility settings.~~ **Answered 2026-08-12: neither.** All
  five packages are published and **public** (`postgres`, `caddy`, `flyway`,
  `uv-builder`, `python-distroless`), each updated 2026-08-11. Ten sibling
  repositories pull them by name. The source note's "the Packages panel is empty"
  premise was simply wrong, and §2's audience is real: this RFC's tag policy and
  attestations affect consumers that already exist.

## 11. Decisions

| # | Grade | Decision |
| --- | --- | --- |
| 1 | `LOCKED` | Both tag forms ship: mutable `:<version>` and immutable ~~`:<version>-<yyyymmdd>`~~ — **stamp format superseded by row 11**, now `:<version>-<yyyymmdd>-<run>` — with the digest documented as the only true immutable reference. Consequence: dated tags accumulate with no retention policy (§8). |
| 2 | `LOCKED` | Max-mode provenance and an SBOM on every target — ~~declared as `provenance = "mode=max"` / `sbom = true`~~, **syntax superseded by row 13** (§5.2a), since that form is silently ignored. Cannot be applied retroactively to already-published tags, which is why it lands before the candidate images. |
| 3 | `LOCKED` | The weekly scheduled rebuild uses `--no-cache`. A cached rebuild does not pick up a rebuilt base layer, which makes the cadence pointless. |
| 4 | `LOCKED` | Attestations are described as unsigned evidence in all documentation. Signing is a separate RFC with its own identity policy (§8). |
| 5 | `ASSUMED` | Rootless Podman for smoke tests, on stock `ubuntu-latest`. Depart if runner support proves fragile enough to make the stage flaky — but degrade to rootless Docker, not to root. |
| 6 | ~~`ASSUMED`~~ | ~~`BUILD_STAMP` is a UTC date; same-day rebuilds reuse the dated tag.~~ **Superseded by row 11**: a reused stamp repoints a tag decision 1 calls immutable, so the two could not both hold. |
| 7 | `ASSUMED` | `GIT_REVISION` / `BUILD_DATE` default to empty so local builds stay cache-stable. Depart if an empty `.created` label turns out to break a downstream tool. |
| 8 | ~~`OPEN`~~ **Locked 2026-08-12** | The scheduled rebuild opens or updates **a GitHub issue** on failure (`if: failure()`, reusing one open issue rather than filing a new one each week). Not email: GitHub notifies whoever last edited the cron, which is invisible to everyone else and fragile across staff changes. Not a chat webhook as the only channel: it needs a secret and an external service to stay up. An issue needs neither and lives where the fix happens. A chat notification may be added on top; it may not replace this. |
| 9 | ~~`OPEN`~~ **Locked 2026-08-12** | Fixed in wave 1. P3 and P4 both edit those workflows, so the filter is corrected while they are open rather than diagnosed a second time later. |
| 10 | `LOCKED` | Every publishing run builds once, smoke-tests that exact artifact, and pushes only on success (§5.4). A separate test build and publish build produce different digests, so the gate would attest to bytes nobody shipped. |
| 11 | `LOCKED` | `BUILD_STAMP` is unique per build (`<yyyymmdd>-<run>`), declared with an empty default, and omitted from `tag()` when empty. Supersedes row 6, and supersedes the stamp format in row 1. Consequence: dated tags accumulate faster than weekly under repeated dispatches, which §8's absent retention policy now has to account for. |
| 12 | `LOCKED` | The scheduled-rebuild failure notification is a **precondition for enabling P4**, not a follow-up. Row 8 still owns which channel; what is settled here is that P4 does not ship without one, because a silent weekly failure leaves the mutable tag on stale bytes while claiming freshness. |
| 13 | `LOCKED` | **Found by execution 2026-08-12.** Supersedes the syntax in row 2. Attestations are declared with the `attest = ["type=provenance,mode=max", "type=sbom"]` list, never the `provenance`/`sbom` shorthand, which buildx 0.35 accepts and silently drops (§5.2a). Consequence: any future attestation change must be verified with `bake --print`, because this class of error is invisible in a passing build. |
| 14 | ~~`ASSUMED`~~ | ~~**Set by execution.** `.description` comes from a `DESCRIPTIONS` map, and a target with no entry gets an **empty** description, not an error.~~ **Superseded by row 16** — an empty label was a silent failure the rest of this RFC exists to remove. |
| 15 | `ASSUMED` | **Set by execution.** The shared attestation target is named `_attested`, not §5.2's `_common` — it carries only attestations, and a name that says so survives the next thing someone wants to share across targets. |
| 16 | `LOCKED` | **Set by review.** `DESCRIPTIONS` is indexed directly (`DESCRIPTIONS[name]`), not via `lookup()` with a default, so a target with no entry **fails the build**. Bake evaluates every target on every invocation, so the failure is immediate and local rather than surfacing as a blank GHCR page after a push. Consequence: adding an image is a nine-item checklist and removing one has to drop the row too, both in [images/README.md](../images/README.md). Keys stay quoted — bare hyphenated keys parse as subtraction in HCL. |
| 17 | `LOCKED` | **Found by review 2026-08-16 — see [EXECUTION-LOG.md](EXECUTION-LOG.md) D-009.** Fixes the stamp format row 11 left as `<run>`: `BUILD_STAMP` is `<yyyymmdd>-<run_id>.<run_attempt>`. This **refines** row 11 rather than superseding it — row 11's property (unique per build) is unchanged, and the shipped `run_id` did not satisfy it. Both `github.run_number` and bare `github.run_id` are rejected: neither changes when a run is re-run, and a re-run rebuilds against moved upstream state, so either would repoint the tag decision 1 calls immutable. Consequence: every stamp carries a `.N` even though the first attempt is always `.1`, because a conditional suffix would make the format depend on history. |
| 18 | `ASSUMED` | **Added by execution 2026-08-16 — see [EXECUTION-LOG.md](EXECUTION-LOG.md) D-004.** A build-stage image is smoke-tested for **toolchain presence and helper validity**, not by §5.5's "entrypoint helper with a trivial argument": `build-uv-app` takes a project directory and has no `--help` and no argument parsing, so the trivial invocation would be a build. Depart when a build-stage image ships a helper that does parse flags. |
| 19 | `ASSUMED` | **Added by execution 2026-08-16 — see [EXECUTION-LOG.md](EXECUTION-LOG.md) D-005 as corrected by PR #27 R-1.** The build-only CI job exports each target as **`type=oci`** to a tarball and loads it into Podman. `type=docker` is rejected outright: every target inherits `_attested`, attestations make the result a manifest list, and the docker exporter refuses those. The tarball lands outside the bake context, so the job carries a scoped `--allow=fs.write=/tmp` rather than disabling the entitlement check wholesale. |
| 20 | `LOCKED` | **Added by execution 2026-08-16 — see [EXECUTION-LOG.md](EXECUTION-LOG.md) D-008 and D-010.** The publish gate is **push-by-digest → pull that digest → smoke → `imagetools create`**, and attestations survive all three steps (measured). §5.4's local-OCI-layout sketch is rejected: it cannot publish the artifact it tested without rebuilding, which is the property row 10 requires. Consequence: publishing is CI-only — a local build on the default `docker` driver produces no attestations at all. |
| 21 | `ASSUMED` | **Added by execution 2026-08-16 — see [EXECUTION-LOG.md](EXECUTION-LOG.md) D-011.** Every workflow that mutates GHCR shares **one concurrency group**. A gated publish is untagged by construction between its digest push and its promotion, and untagged is exactly what the cleanup job deletes. The cron offset orders the two scheduled runs; it does not protect that window, because every non-scheduled trigger bypasses the schedules entirely. |
| 22 | `ASSUMED` | **Added by execution 2026-08-16 — see [EXECUTION-LOG.md](EXECUTION-LOG.md) D-012.** Publishing paths that bypass the smoke gate **refuse by default** and name both silent failure modes. Specifying the pipeline does not secure it: a rule enforced in the workflow and absent from the local recipe is a rule with a documented bypass. |

## 12. Phasing

- **P1 — labels and attestations.** §5.1 + §5.2, one PR, no behavioural change to
  any image. Verify the cleanup workflow still keeps SBOM manifests with
  `dry_run: true` before the next scheduled cleanup runs for real.
- **P2 — tag policy.** §5.3 plus the README section. Independent of P1 but
  pointless before it, since the dated tag's value is that its metadata is
  complete.
- **P3 — smoke stage.** §5.5. Blocked on nothing; most valuable before RFC
  0005/0006 land, since those images will otherwise arrive untested.
- **P4 — weekly rebuild.** §5.4 last, because it pushes only what the smoke stage
  passed on the same artifact (decision 10), and because it is the step whose
  failure mode is silence. **Does not ship without the failure notification**
  (decision 12).
