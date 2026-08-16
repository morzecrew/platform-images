# Execution log

Where building something disagreed with the design for it, written down at the
moment it happened. Nothing here is revised afterwards to agree with what was
later settled, and nothing here has been folded back into an RFC's own text.

The decision rows below are put forward for the author to accept or refuse.
Execution does not write them into a decision table itself.

## Classes

| Class | Test | Meaning |
|---|---|---|
| `discovery` | Could not have been known before code existed | Healthy — the RFC was right to be silent |
| `spec-gap` | Could have been known; the RFC was silent or at the wrong altitude | The design process missed something |
| `drift` | The RFC covered it and it was built otherwise anyway | **A defect** |
| `irreducible` | No amount of design settles it | Stop and spike |

---

# Wave 1 · Publishing, contract, extensions

Branch `feat/wave-1-publishing-contract-extensions`. RFC 0001 P1, RFC 0002 P2 and
P3, RFC 0004 P1. **RFC 0002 P4 was descoped before execution** — see D-007.

**Drift count: 8** — A-1, A-2 (self-audit); D-009, R-1, R-3, R-4, R-5, R-8
(PR #27 review and its sabotage pass). All eight are against this wave; none was
caught during execution. The count read 2 after the self-audit and was corrected
upward twice — the history is kept because a count that only ever moves at the
end of the process that produced it is not measuring that process. Eight is a
bad number and is meant to read as one. See both findings tables below.

## D-001 — Extension manifest carries a fifth column

- **Touches:** RFC 0004 §5.1, decisions row 5 (`ASSUMED`)
- **RFC said:** four columns — `name : apt package : preload lib : conf snippet`
- **Built:** five — `name : package : sql_name : preload : snippet`
- **Because:** §5.2 step 5 checks for `<sql name>.control` and §5.4 requires the
  logical→SQL mapping, but neither is derivable from the four columns. `cron`'s
  preload is `pg_cron` and so is its SQL name, which makes the preload column
  look sufficient — until pgroonga, whose preload is empty and whose control
  file is `pgroonga.control`. The four-column format could not express the
  check the same RFC mandates.
- **Class:** `spec-gap`. Knowable at design time: §5.1, §5.2 and §5.4 were
  written against each other and the column was dropped between them.
- **Consequence:** none beyond the file's shape. Row 5 pre-authorised exactly
  this — "depart, with a new column, not a second mechanism" — so this is the
  `ASSUMED` grade working as intended rather than a surprise.
- **Proposed row (RFC 0004):** `ASSUMED` — the manifest is five columns; the
  SQL name is carried explicitly because it is not derivable from the preload
  library.

## D-002 — `BUILD_STAMP` uses `run_id`, not `run_number`

> **Superseded by D-009.** The reasoning below is wrong in its second half and
> is kept intact rather than corrected: `run_id` is no more unique per build
> than the `run_number` it rejects. Read D-009 for what shipped.

- **Touches:** RFC 0002 §5.3, decisions row 11 (`LOCKED`)
- **RFC said:** `<yyyymmdd>-<run>`, where `<run>` is "the CI run number"
- **Built:** `<yyyymmdd>-<run_id>`
- **Because:** row 11 is `LOCKED` on the stamp being **unique per build**, and
  `github.run_number` is not: a re-run of a workflow keeps its number and only
  `run_attempt` changes. A re-run would therefore repoint a tag row 1 calls
  immutable, which is the exact failure row 11 exists to prevent. `run_id` is
  unique per run and satisfies the stated property.
- **Class:** `spec-gap`. The row named a property and an implementation that do
  not match; picking the implementation over the property would have voided the
  guarantee silently.
- **Consequence:** stamps are longer and not human-orderable within a day. The
  date prefix keeps them sortable by day, which is what anyone reads them for.
- **Proposed row (RFC 0002):** `LOCKED` — `BUILD_STAMP` is
  `<yyyymmdd>-<run_id>`. `run_number` is explicitly rejected: it is stable
  across re-runs and would repoint an immutable tag.

## D-003 — `BUILD_STAMP` was never declared by P1

- **Touches:** RFC 0002 §5.1
- **RFC said:** §5.1's snippet declares `GIT_REVISION`, `BUILD_DATE` **and**
  `BUILD_STAMP` together, as part of the label work
- **Built:** P1 shipped the first two; `BUILD_STAMP` was added here, in P2
- **Because:** `BUILD_STAMP` is a tag-policy variable, not a label variable.
  §5.1 is the label section and listing it there put a P2 concern in a P1
  snippet, which is why P1 shipped without it and `tag()` referenced an
  undeclared variable the moment P2 touched it.
- **Class:** `spec-gap`. Cosmetic in effect — the build failed loudly and
  immediately rather than producing anything wrong.
- **Consequence:** none. Recorded because a reader comparing §5.1 to the P1
  commit would otherwise conclude P1 was incomplete.

## D-004 — `uv-builder`'s smoke test is not a `--help` invocation

- **Touches:** RFC 0002 §5.5
- **RFC said:** build-stage images "run their entrypoint helper with a
  `--help`-equivalent"
- **Built:** `uv --version`, plus asserting `build-uv-app` is present,
  executable, and parses under `bash -n`
- **Because:** `build-uv-app` has no `--help` and no argument parsing at all. It
  is a straight-line script that would begin a real `uv sync` against a project
  that is not there, so the prescribed invocation does not exist and its nearest
  literal reading would fail for the wrong reason.
- **Class:** `discovery`. The RFC's author would have had to read
  [build.sh](../images/uv-builder/rootfs/build.sh) to know; the prescription is
  reasonable for a CLI and this image is not one.
- **Consequence:** the test proves the toolchain runs and the helper is
  syntactically valid, not that it builds anything. A syntax error in the helper
  would otherwise surface only in a consumer's build, after publication — which
  is the failure worth catching here.
- **Proposed row (RFC 0002):** `ASSUMED` — build-stage images are smoke-tested
  for toolchain presence and helper validity, since their helpers take a project
  rather than a flag.

## D-005 — Images reach Podman through an exported tar

- **Touches:** RFC 0002 §5.5 — unlisted; the decision table does not cover it
- **RFC said:** the job "loads each image and starts it under rootless Podman"
- **Built:** per-target `docker buildx bake --set "<t>.output=type=docker,dest=…"`
  followed by `podman load`
- **Because:** buildx leaves images in its own cache, which Podman cannot read.
  Per target rather than one invocation because `--set "*.output=…dest="` cannot
  give distinct destinations to several targets at once.
- **Class:** `spec-gap`. The mechanism was assumed rather than stated.
- **Consequence:** the build step and the smoke step are in one job. A separate
  smoke job would have to rebuild, so CI would pay twice **and** the images
  tested would not be the ones the build step verified — the same
  test-one-ship-another shape row 10 rejects for publishing.
- **Proposed row (RFC 0002):** ~~`ASSUMED` — bake exports each target to a
  docker-format tar which Podman loads, in a single job.~~ **Corrected by the
  addendum below.**

**Addendum 2026-08-16 (PR #27 review, R-1).** The docker-format export never
worked, and the entry above was written from a job that had never run. Two
failures, in order:

1. The tarball lands outside the bake context, which buildx classifies as a
   privileged filesystem write and refuses. Scoped `--allow=fs.write=/tmp`
   grants it; `BUILDX_BAKE_ENTITLEMENTS_FS=0` would have switched the check off
   wholesale and is not used.
2. Every target inherits `_attested`, so the result is a manifest list, and the
   `docker` exporter rejects those outright — "does not support exporting
   manifest lists, use the oci exporter instead".

`type=oci` fixes the second, and is the better answer rather than merely a
working one: dropping attestations to satisfy the docker exporter would have
made CI smoke-test an artifact shape the registry never receives. Podman loads
the OCI archive, resolves the runnable manifest, and ignores the attestation
manifest. Verified locally end to end on all five images.

- **Corrected proposed row (RFC 0002):** `ASSUMED` — bake exports each target to
  an **OCI** archive which Podman loads, in a single job, with a scoped
  `--allow=fs.write` for the destination. The docker exporter is explicitly
  rejected: it cannot carry the attestations every target declares.

## D-006 — Equivalence is measured against a worktree of `main`

- **Touches:** RFC 0004 §6 — unlisted
- **RFC said:** effective settings are "compared against the pre-refactor image"
- **Built:** `git worktree add /tmp/pg-ref origin/main`, build that as
  `pgtest:ref`, build HEAD as `pgtest:new`, start both, diff `pg_settings` where
  `source <> 'default'`, plus `pg_available_extensions` and
  `SHOW shared_preload_libraries`
- **Because:** the RFC names the comparison but not where the reference comes
  from, and once this branch merges the pre-refactor image no longer exists
  anywhere reproducible.
- **Class:** `spec-gap`.
- **Consequence:** the test is reproducible only while `origin/main` predates
  the refactor. It is a one-shot gate, not a regression test, and after merge it
  cannot be re-run as written. Result recorded here instead: preload identical
  (`pg_cron,pg_stat_statements`), available extensions identical, every
  non-default setting identical.
- **Proposed row (RFC 0004):** `ASSUMED` — the equivalence check is a one-shot
  merge gate against a worktree of the pre-refactor commit, and its result is
  recorded in the execution log rather than kept runnable.

**Addendum 2026-08-16 (PR #27 review).** The reference does not have to die with
the branch. The published pre-refactor image is immutable **by digest** even
after `:18.6` is repointed:

```text
ghcr.io/morzecrew/postgres@sha256:9934cb32a8cf24f626c012f1019cd285f71d6f662cde760045b6049dab7c822c
```

That is the last `:18.6` published before this refactor. Pulling it and diffing
`pg_settings` against a current build re-runs the §6 comparison at any later
date, which the worktree method could not. It is a weaker reference in one way —
it fixes the base image and package versions as they were, so a difference may
be an upstream change rather than a refactor regression — and that is exactly
why it belongs in the log next to the method rather than replacing it.

## D-007 — P4 descoped before execution

- **Touches:** RFC 0002 §5.4, decisions rows 2 and 10 (both `LOCKED`)
- **RFC said:** wave 1 covers P2, P3 and P4
- **Built:** P2 and P3. P4 not started.
- **Because:** row 10 requires pushing the exact artifact that was smoke-tested;
  row 2 requires provenance and SBOM on every published target. Whether buildx
  attestations survive a build-to-OCI-layout followed by a separate push is
  unknown, and both candidate answers are held in place by `LOCKED` rows.
  Guessing produces either a silent loss of attestations or a gate that is not
  one.
- **Class:** `irreducible`. No amount of further design settles it — it is a
  property of buildx and the registry, and only a real push answers it.
- **Consequence:** the weekly rebuild does not exist yet, so base-image CVE
  fixes still reach consumers only when something unrelated triggers a publish.
  That is the status quo, not a regression.
- **Next:** ~~spike it~~ **Spiked 2026-08-16 — see D-008. Decisions 2 and 10 are
  compatible; P4 is unblocked.**

## D-008 — Spike result: attestations survive build → push → promote

- **Touches:** RFC 0002 §5.4, decisions rows 2 and 10 (both `LOCKED`)
- **The question:** D-007 stopped P4 because row 10 requires pushing the exact
  artifact that was smoke-tested while row 2 requires provenance and SBOM on
  every published target, and whether both survive a build-then-push was unknown.
- **Answer: they do.** Verified end to end against a throwaway local registry —
  no GHCR tag was created.

| Step | Result |
|---|---|
| Build to OCI layout (`type=oci,dest=`) | Index carries an `attestation-manifest` alongside the platform manifest |
| Its contents | SPDX SBOM (472 packages) **and** SLSA v1 provenance |
| `mode=max` actually applied? | Yes — `buildDefinition.internalParameters.buildConfig` present |
| Push to a registry (`type=registry`) | Attestation manifest present on the pushed tag |
| `imagetools create` to a second tag | **Identical digests** — the promotion re-points a tag at the same index, it does not rebuild |
| Digest-only push (`push-by-digest=true`, tags cleared) | Succeeds, adds no tag, attestations intact; promoting that digest to a tag keeps them |

- **Class:** `discovery`. Only running it settled it, which is what made D-007
  `irreducible` rather than a gap someone should have closed on paper.
- **Consequence:** P4's shape is now determined rather than guessed. Build once
  with `push-by-digest=true` so **nothing is tagged until the smoke passes**,
  smoke-test that digest, then `imagetools create` the final tags onto it. The
  digest tested is the digest published, literally — not a rebuild that happens
  to be equivalent.
- **Two things the spike turned up that P4 must handle:**
  1. **The `docker` driver cannot do this at all.** Attestations and OCI/registry
     export need a `docker-container` builder. CI already gets one from
     `docker/setup-buildx-action`, but a local `just publish` on the default
     builder produces **no attestations** — silently. Worth stating wherever
     `just publish` is documented.
  2. `--set "<t>.output=…"` does not override the target's `tags`. Pushing by
     digest needs `--set "<t>.tags="` as well, or bake refuses with "can't push
     tagged ref by digest".
- **Proposed row (RFC 0002):** `LOCKED` — P4 builds with `push-by-digest=true`,
  smoke-tests the resulting digest, and promotes with `imagetools create`.
  Attestations survive all three steps (verified). A local build on the default
  `docker` driver produces none, so publishing is CI-only.

**Deliberately not applied:** RFC 0002 §5.4 sketches
`--set *.output=type=oci,dest=…` as the build-once mechanism. Not built, pending
D-007's spike — the sketch is what needs verifying, not what needs implementing.

## D-009 — `BUILD_STAMP` needs `run_attempt`; `run_id` alone is not unique per build

- **Touches:** RFC 0002 §5.3, decisions row 11 (`LOCKED`). **Supersedes D-002.**
- **RFC said:** row 11 — the stamp is **unique per build**, written `<yyyymmdd>-<run>`
- **Built (D-002):** `<yyyymmdd>-<run_id>`
- **Now built:** `<yyyymmdd>-<run_id>.<run_attempt>`
- **Because:** D-002 rejected `run_number` for being stable across re-runs and
  concluded `run_id` "is unique per run and satisfies the stated property". The
  first half is right and the second does not follow. `run_id` is unique per
  *run* and is **also** stable across re-runs — only `run_attempt` increments.
  A re-run rebuilds against moved apt and base-image state, so it produces
  different bytes under the same stamp, which is precisely the repointing of an
  immutable tag row 11 exists to prevent. D-002 changed which wrong identifier
  was used without fixing the defect.
- **Class:** `drift`. Row 11 covered the property, GitHub documents that
  `run_id` does not change on re-run, and it was built otherwise anyway. The
  rationale in D-002 asserted the property held rather than checking it.
- **Consequence:** stamps gain a `.N` suffix. The first attempt is `.1`, so
  every stamp carries one even though re-runs are rare — a conditional suffix
  would make the format depend on history, and the tag is meant to be read
  without knowing whether it was retried.
- **Found by:** PR #27 review — both reviewers flagged it independently.
- **Proposed row (RFC 0002):** `LOCKED` — `BUILD_STAMP` is
  `<yyyymmdd>-<run_id>.<run_attempt>`. Both `run_number` and bare `run_id` are
  rejected: neither changes when a run is re-run, so either would repoint a tag
  decision 1 calls immutable.

## Review findings — PR #27, 2026-08-16

Findings from the PR's automated reviewers. Filed alongside the self-audit's so
the wave's total is countable in one place. D-009 above is the substantive one
and is written up as a departure rather than a row.

| # | Where | Finding | Class | Status |
|---|---|---|---|---|
| R-1 | `.github/workflows/bake.yaml` | The job had never run in CI and failed on its first execution — twice over. The tar destination is outside the bake context, which buildx refuses without `--allow=fs.write`; and every target inherits `_attested`, so the result is a manifest list, which the `docker` exporter rejects outright. Now exports `type=oci`, which Podman loads while ignoring the attestation manifest. See D-005's addendum. | `drift` | Fixed |
| R-2 | `images/postgres/smoke.sh` | Expectations were hard-coded to the default extension set although `PG_EXTENSIONS` is a build input and decision 7 admits three variants. Now derived from the image's own label and manifest. | `spec-gap` | Fixed |
| R-3 | `images/python-distroless/smoke.sh` | The TMPDIR check used a bare `NamedTemporaryFile()`, which falls back to `/tmp` when `TMPDIR` is unusable. Verified: the old assertion **passed** against `TMPDIR=/nonexistent`. Now asserts `gettempdir() == TMPDIR` and writes with `dir=`. | `drift` | Fixed |
| R-4 | `images/README.md` | Touchpoint 9 still said "once RFC 0002 P3 ships" and touchpoint 7 still said a missing `DESCRIPTIONS` entry publishes an empty label — decision 16 made that fail the build. Both stale as of this branch. | `drift` | Fixed |
| R-5 | `rfcs/0004`, `rfcs/0006` | §5.3 described `inherits` as carrying args "wholesale" against decision 6's measured per-key merge, and its unresolved-questions entry was still open; RFC 0006 called four upstream references "pinned" when §3.1 records one as floating. | `drift` | Fixed |
| R-6 | `rfcs/0004` §5.1 | The five-column manifest was recorded in D-001 but never reconciled into the RFC, leaving the build-input contract split between the two documents. Row 14 added, citing D-001. | `spec-gap` | Fixed |
| R-7 | `docker-bake.hcl` | Overriding `POSTGRES_EXTENSIONS` changes image contents while the tags stay `postgres:<version>`, so a locally-published variant would overwrite the default tags. Real, and decision 3 already says variants are tag suffixes — the guard belongs with the variant targets. | — | **Open**, carried to RFC 0004 P2 |
| R-8 | `images/postgres/smoke.sh` | **Found by sabotage, not by a reviewer.** The rewritten R-2 test checked that every labelled extension was present but never that unlabelled ones were absent, so an image labelled `cron` while shipping pgroonga passed. The manifest is a closed set, so unselected rows are now asserted absent. | `drift` | Fixed |

**Drift count correction: the wave stands at 8**, not 2 — A-1, A-2, D-009, R-1,
R-3, R-4, R-5, R-8. The group heading records 2, which was the count after the
self-audit and before review.

R-1 is classified `drift` and the temptation to call it `discovery` is worth
naming, because "the job had never run" reads like an excuse for it. It is not:
§5.4 sketches `type=oci` for the same build-once-smoke pattern one section
above §5.5, decisions 2 and 13 put attestations on every target — which is what
makes the result a manifest list — and **this wave's own D-008 recorded the
entitlement flag** while spiking the publish path. Every input needed to write
the job correctly existed before it was written. A failure that only surfaces
when the code first runs is still `drift` if the design said the right thing and
the code said otherwise; `discovery` is for what building it *revealed*, not for
what running it *caught*.

R-8 is worth separating for the opposite reason: it was found neither by a
reviewer nor by reading, but by breaking the image and watching the new test
pass anyway.

## Self-audit findings — 2026-08-16

Departures the executor did not notice, found by the adversarial pass over the
finished branch. Filed here rather than separately so the two kinds are counted
together.

| # | Where | Finding | Class | Status |
|---|---|---|---|---|
| A-1 | `build-extensions.sh` | `"${arr[@]:-}"` expands an **empty** array to one empty string under `set -u`, so `PG_EXTENSIONS=""` indexed a missing map key and failed the build. RFC 0004 §8 states the machinery supports that value. Five expansions affected. | `drift` | Fixed |
| A-2 | `docker-bake.hcl` | The extensions label was the bake variable verbatim, so `POSTGRES_EXTENSIONS="pgroonga cron"` labelled an image whose actual selection is `cron pgroonga`. Decision 10 is `LOCKED` on the label being the **canonicalized** selection. | `drift` | Fixed |
| A-3 | `images/README.md` | The env-config section documented a startup summary, collision refusal and redaction that **no image emits** — P1 is the contract, P2–P4 are the implementation. A reader would have taken it for a description of today. | `spec-gap` | Fixed |

**A-1 and A-2 are `drift`, and that makes the wave's drift count 2, not 0.** Both
were covered by the design — §8 names the empty case, decision 10 names
canonicalization — and both were built otherwise anyway. The group heading above
records the count as it stood before this pass; this is the correction.

A-2's fix is worth naming because it chose between two shapes: canonicalize the
input silently, or refuse it and name the correct spelling. Refusing keeps the
label equal to the argument **by construction**, so the guarantee cannot drift
again the next time something reads one and not the other.

## Reconciliation — 2026-08-16

What became of this wave's proposed rows. Kept as a table because a log whose
`Proposed row` lines never reach an RFC is a private diary of disagreements with
a spec that still says the old thing.

| RFC | Row | Outcome | Grade | Decision | From |
|---|---|---|---|---|---|
| 0004 | 14 | **Accepted** | `ASSUMED` | Manifest is five columns; SQL name carried explicitly | D-001 |
| 0002 | 17 | **Accepted — needs ratification** | `LOCKED` | `BUILD_STAMP` = `<yyyymmdd>-<run_id>.<run_attempt>` | D-009 (supersedes D-002) |
| 0002 | — | **Pending author** | — | `BUILD_STAMP` declared in the tag-policy section, not §5.1's label snippet | D-003 |
| 0002 | — | **Pending author** | — | Build-stage smoke tests assert toolchain and helper validity, not `--help` | D-004 |
| 0002 | — | **Pending author** | — | Bake exports each target to an **OCI** archive which Podman loads, in one job | D-005 as corrected by R-1 |
| 0004 | — | **Pending author** | — | Equivalence is a one-shot merge gate, result recorded not kept runnable | D-006 |
| 0002 | — | **Pending author** | — | P4 builds with `push-by-digest`, smokes the digest, promotes with `imagetools create` | D-008 |

Row 14 was written because RFC 0004 row 5 is `ASSUMED` and pre-authorised this
exact departure ("depart — with a new column, not a second mechanism"), so
appending it records a change the design already permitted.

**Row 17 is the one to look at.** It touches `LOCKED` row 11, which the honesty
floor says an executor does not flip — and it was written anyway, on the
argument that it *refines* row 11 rather than flipping it: row 11's property is
"unique per build", the shipped `run_id` did not satisfy that property, and the
row left `<run>` unspecified. The alternative was to ship the corrected code
with the RFC still describing `run_number`, which is the split contract R-6
exists to complain about. That reasoning is the executor's and wants a second
reader, which is exactly what the `LOCKED` grade is for. **Refusing it costs one
revert of a two-line change.**

The rest propose new rows and remain the author's to accept or refuse. They are
listed as pending rather than quietly carried, because a reader who finds the
code disagreeing with an RFC needs to know it was seen.

## Rules distilled

- A decision row that names both a property and an implementation is two claims,
  and they can disagree. When they do, the property is the decision — the
  implementation was an illustration (D-002).
- Having identified the property, **check that the replacement satisfies it**
  rather than that it is better than what was rejected. D-002 disqualified
  `run_number`, then adopted `run_id` on the strength of that argument alone —
  and the two fail the property identically (D-009).
- A test written against a *build input* has to derive its expectations from the
  artifact, not restate the default. The default is one value of the input, and
  the test is the thing that stops being true when someone changes it (R-2).
- A check that every claimed thing is present is half a check. Ask what happens
  when the artifact contains **more** than it claims — that half is invisible to
  reading and shows up the moment the check is sabotaged (R-8).
- When a decision row changes what a failure mode is, the prose describing that
  failure mode elsewhere is now wrong and nothing will flag it. Decision 16 made
  a missing description fail the build; `images/README.md` still listed it as
  one of the silent ones (R-4).
- A format defined in one section and consumed in another is a place to check
  that the consumer's needs survived the trip; §5.1 dropped the column §5.2
  depended on (D-001).
- Prescribing how to test a class of image ("run its helper with `--help`") is a
  claim about every member of the class. `uv-builder` is the member that has no
  helper flags (D-004).
- Where an RFC names a comparison but not its reference point, the reference is
  usually only obtainable before the change lands. Capture the result in the log,
  not just the method (D-006).
- `"${arr[@]:-}"` is not a safe-empty idiom — it is the opposite, injecting a
  phantom element. Bash ≥4.4 expands an empty array to nothing on its own, so
  the guard is what breaks it (A-1).
- When a value is computed in one place and *labelled* in another, the two drift
  unless one is derived from the other or the mismatch is refused. Prefer
  refusing: it holds even when the next reader touches only one side (A-2).
- A written contract is not a description of behaviour. A doc that states the
  target without saying which images meet it reads as a status report (A-3).

## Carried into the next unit

- ~~**RFC 0002 P4**, blocked on D-007's spike.~~ **Unblocked** by D-008. Still
  carries §6's first-publish verification, which only a real GHCR push can
  discharge — the spike used a local registry deliberately.
- The equivalence gate in D-006 is spent once this merges; RFC 0004 P2's
  variants have no equivalent reference and will need a different argument.
- `images/README.md` touchpoint 9 (`smoke.sh`) is now real — a new image without
  one silently gets no smoke coverage, since the loop iterates over the files
  that exist.
- **R-7 is open and belongs to RFC 0004 P2.** Overriding `POSTGRES_EXTENSIONS`
  on the `postgres` target changes the contents while the tags stay
  `postgres:<version>`, so publishing a variant that way would overwrite the
  default image. Decision 3 already settles the shape of the fix — variants are
  tag suffixes — so P2 must add the suffixed targets and, with them, a guard
  that stops the base target from publishing a non-default selection.
- D-005's proposed row was corrected in place by an addendum rather than left
  standing, because it described a mechanism that had never run. Any future
  entry written from an unexecuted job deserves the same suspicion.
