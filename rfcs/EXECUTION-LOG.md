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

---

# Wave 2 · Weekly rebuild

Branch `feat/wave-2-weekly-rebuild`. RFC 0002 P4 — the phase wave 1 descoped in
D-007 and the spike in D-008 unblocked.

**Drift count: 2** — R-9 and R-10, both found by PR #28's review, neither caught
during execution or by the self-audit. The count read 0 until review; the
history is kept because a zero that only survives until someone else looks was
never a measurement.

The departures below are one `spec-gap` the RFC left between two sections, one
`spec-gap` about a file the RFC never mentions, and one `discovery` about cron
ordering — none of which is drift. The drift arrived from the review.

**Scoped deliberately narrow.** The planned wave 2 was RFC 0006 P2+P3 carrying
RFC 0001 P2. That track was **stopped at the readiness gate** — see D-012 — and
P4 was pulled forward, because it was already specified, already spiked, and had
been deferred only until wave 1 merged.

## D-010 — Smoke runs against a pulled digest, not a local OCI layout

- **Touches:** RFC 0002 §5.4, decisions row 10 (`LOCKED`)
- **RFC said:** the run "builds to a local OCI layout
  (`--set *.output=type=oci,dest=…` or a loaded image), runs §5.5's smoke script
  against **that** artifact, and pushes it only if the script passes"
- **Built:** push by digest with tags cleared → `podman pull` that digest →
  smoke → `docker buildx imagetools create` to promote the tags
- **Because:** §5.4 and D-008 disagree about *where* the gate happens, and only
  one of them can be honoured. The local-layout shape cannot push what it
  tested: buildx has no way to push an OCI archive as-is, so publishing means
  re-running the build with `--push` — a second build, which under `--no-cache`
  is not the same bytes. That is precisely the test-one-ship-another shape row
  10 forbids. Pushing by digest first inverts it: the artifact exists in the
  registry but is unreachable by name until it passes, and promotion re-points
  tags at an index that already exists rather than producing a new one.
- **Class:** `spec-gap`. §5.4 was written before the spike and reached for the
  mechanism that looked local and safe; the spike then established that
  promotion preserves identity, which is what makes the digest-first order
  strictly better.
- **Consequence:** a failed run leaves an untagged version in GHCR. That is
  collected by `cleanup-images.yaml`, so it self-heals — see D-011 — but it does
  mean the registry briefly holds bytes nothing points at. Verified end to end
  against a throwaway local registry, including that a failing smoke leaves
  **every** tag untouched, not just the failing image's.
- **Proposed row (RFC 0002):** `LOCKED` — the gate is push-by-digest → pull that
  digest → smoke → `imagetools create`. Building to a local OCI layout is
  explicitly rejected: it cannot publish the artifact it tested without
  rebuilding.

## D-011 — The cron offset is doing work nobody wrote down

- **Touches:** RFC 0002 §5.4 — unlisted
- **RFC said:** `cron: "0 5 * * 1"`, annotated only "Mondays, an hour after
  cleanup-images"
- **Built:** the same cron, with the reason recorded
- **Because:** the offset reads like politeness — stagger the jobs — and is
  actually protecting the digest-first gate from `cleanup-images.yaml`. Between
  the digest push and the promotion, a **healthy** build sits in GHCR as an
  untagged version, which is precisely what cleanup deletes. The two workflows
  are in different concurrency groups, so nothing serialises them; the cron
  offset is the only separation. Running the rebuild *before* cleanup would mean
  that a rebuild overrunning its hour — five uncached images, easily — has its
  in-flight digest deleted an instant before promotion.
- **Class:** `discovery`. Only building the digest-first gate made the ordering
  load-bearing; before D-010 nothing untagged existed for cleanup to race.
- **Consequence:** the two crons are coupled and neither file said so. A
  *genuine* orphan, from a run that died mid-flight, now waits until the
  following Monday to be collected — a week of unreferenced bytes, which is
  storage rather than a fault, and the cheaper of the two mistakes.
- **Corrected twice, and the second one matters more than the first.**

  *First correction (self-audit).* The original entry, and the workflow comment
  with it, claimed the offset *minimised* orphan lifetime — "an hour instead of
  a week". Exactly inverted: an orphan created at 05:00 Monday waits for the
  next Monday's 04:00 cleanup.

  *Second correction (PR #28 review).* The offset does not protect the window at
  all, except in one of four cases. It separates the two **scheduled** runs.
  `publish.yaml` also fires on `push` and `workflow_dispatch`, and
  `cleanup-images.yaml` fires on `workflow_dispatch` — and the two workflows sat
  in **different concurrency groups**, so nothing serialised them. A merge
  landing at 03:59 on a Monday, or anyone dispatching cleanup by hand, walks
  straight into the untagged window and deletes a healthy build moments before
  promotion.

  Both workflows now share `concurrency: group: ghcr-mutations`. Concurrency
  groups are repository-scoped rather than per-workflow, so one shared name is
  what actually serialises them. The cron offset is retained for ordering, and
  is no longer load-bearing.
- **Consequence of the fix:** cleanup and publish now queue behind each other.
  Both are infrequent and neither is latency-sensitive, so the cost is a wait.
  Splitting the group reopens the race, which is why both files say so.
- **Proposed row (RFC 0002):** `ASSUMED` — every workflow that mutates GHCR
  shares one concurrency group, because a gated publish is untagged by
  construction between its digest push and its promotion, and untagged is what
  cleanup deletes. The cron offset orders the scheduled runs; it does not
  protect the window.

## D-012 — `just publish` refuses instead of publishing

- **Touches:** RFC 0002 decisions rows 2 and 10 (both `LOCKED`) — the `justfile`
  is unlisted in every phase
- **RFC said:** nothing. §5.4 specifies the workflow; no phase mentions the
  recipe the workflow used to call.
- **Built:** `just publish` refuses unless `I_KNOW_THIS_IS_UNGATED=1`, and the
  workflow no longer calls it
- **Because:** leaving it as it was would have left a one-word command that
  violates both rows silently. It skips the smoke gate row 10 requires of *every*
  publishing run, and on the default `docker` driver buildx emits no attestations
  at all while reporting success (D-008), so an ungated local push is
  indistinguishable from a correct one until someone inspects the registry.
- **Class:** `spec-gap`. The RFC specified the pipeline and never asked what
  happens to the other door into it.
- **Consequence:** a developer who genuinely wants an ungated push types one
  environment variable and gets it, with both reasons printed first. `just push`
  is untouched — it moves an existing tag and was never a build.
- **Proposed row (RFC 0002):** `ASSUMED` — publishing paths that bypass the
  smoke gate refuse by default and name both silent failure modes.

## D-013 — Wave 2's planned scope stopped at the readiness gate

- **Touches:** the execution plan, not an RFC
- **Planned:** RFC 0006 P2 + P3, carrying RFC 0001 P2
- **Built:** RFC 0002 P4 instead
- **Because:** `flag-dont-flip`'s readiness gate is three load-bearing decisions
  the design does not settle, and the valkey track has three:
  1. **The source-map shape.** RFC 0001 §5.2 requires `envconf_summary` to take
     a source map and says each image builds one, but never says what it is. It
     is the interface between every future image and the shared helper.
  2. **Whether `shared/` gets its own test harness.** §6 routes every test
     through per-image smoke tests. The helper's NUL-delimited wire format and
     newline refusal are testable without starting a server, and only through a
     running Valkey if the RFC's silence is taken literally.
  3. **`VALKEY_RENAME_DANGEROUS`'s surface.** §5.4 locks *that* the dangerous
     commands are renamed and re-enableable; §5.5 lists the variable without
     saying whether it is a boolean or a list of exemptions.
  Decisions 9 and 10 (Alpine base, fallback `maxmemory`) are `OPEN` and so are
  the executor's to decide and log — they are not part of this count.
- **Class:** `spec-gap`, against the plan.
- **Consequence:** P4 shipped a wave earlier than planned and the valkey track
  starts once those three are settled — each is a paragraph, against a
  re-implementation if guessed at.

## Review findings — PR #28, 2026-08-16

`R-` numbers continue from wave 1 rather than restarting, because they are
identifiers and a number that means two things breaks every citation to it.

| # | Where | Finding | Class | Status |
|---|---|---|---|---|
| R-9 | `publish.yaml`, `cleanup-images.yaml` | **The cron offset protected one interleaving out of four.** D-011 argued the offset keeps cleanup out of the window where a gated publish is untagged. It only separates the two *scheduled* runs — publish also fires on `push` and `workflow_dispatch`, cleanup on `workflow_dispatch`, and the two workflows were in different concurrency groups, so nothing serialised them. A merge landing at 03:59 Monday deletes a healthy digest moments before promotion. Both now share `concurrency: group: ghcr-mutations`. | `drift` | Fixed |
| R-10 | `README.md`, `images/README.md` | Both documented `just publish` as "build + push everything" after D-012 made it refuse, and neither mentioned `I_KNOW_THIS_IS_UNGATED`. Following the documentation produced a refusal. | `drift` | Fixed |

**Drift count corrected: 2, not 0.** Both are `drift` by the test that matters —
the design covered the case and the code did otherwise. R-9 is against a
`LOCKED` row (10): a publish whose digest is deleted before promotion cannot
push what it smoke-tested. R-10 is against D-012's own consequence line, which
claimed a developer "gets it, with both reasons printed first" while the docs
still advertised the old contract.

R-9 is the one worth dwelling on. It survived being written, being re-derived
during a self-audit that *corrected this very entry's rationale*, and being
described in a PR body — and it was still wrong, because every pass reasoned
about the schedules rather than about the triggers. Getting the rationale right
is not the same as getting the mechanism right.

## Self-audit findings — wave 2, 2026-08-16

| # | Where | Finding | Class | Status |
|---|---|---|---|---|
| A-4 | both workflows | `bake --print` ran with `2>/dev/null`. Buildx writes its **errors** to stderr, so a bad target or an HCL error produced a red job stating only that a process exited 1. Verified: `bake --print nosuchtarget` prints `ERROR: failed to find target nosuchtarget` on stderr and nothing on stdout. | — | Fixed |
| A-6 | `publish.yaml`, D-011 | The cron offset was justified backwards. The comment and the log entry both claimed running after cleanup *minimised* orphan lifetime; an orphan created at 05:00 Monday actually waits for the next Monday's 04:00 cleanup. The ordering is right — it keeps cleanup out of the window where a healthy build is pushed-by-digest and not yet promoted — but the reason given was the opposite of the real one. | — | Fixed |
| A-5 | both workflows | An `Install just` step that nothing used. Wave 1 replaced the `just bake` / `just publish` calls with direct `docker buildx` invocations and left the action behind; `justfile` also stayed in both `paths:` filters, so editing a file CI no longer reads would trigger a full rebuild and publish. | — | Fixed |

**Neither moves the drift count, and that is worth saying rather than assuming.**
`drift` means a decision row covered it and the code said otherwise. No row
governs stderr handling or which actions a job installs, so counting these as
drift would inflate the number that is supposed to mean something specific. They
are ordinary defects, found by the audit, fixed here.

A-4 is the more serious of the two despite looking like housekeeping: it is a
failure whose only symptom is the absence of a symptom, in the workflow whose
whole purpose this wave is to make failures loud.

## Rules distilled

- When two sections of one RFC describe the same gate differently, the one
  written *after* the measurement wins, and the disagreement is the entry —
  §5.4's local-OCI sketch predates the spike that made digest-first viable
  (D-010).
- A gate that publishes what it tested has to make the tested artifact and the
  published artifact **the same object**, not two objects a build is expected to
  produce identically. Digest-first does that; build-test-rebuild cannot (D-010).
- An offset between two schedules is a dependency. If moving one alone breaks
  something, that is a coupling and it belongs in a comment on both (D-011).
- Writing down *why* an ordering is right is what catches a right ordering
  held for a wrong reason. D-011 was correct and its stated justification was
  backwards — a defect invisible until someone acts on the justification
  rather than the ordering (D-011, corrected in self-audit).
- A schedule is not a mutual exclusion. Two jobs that must not overlap need a
  shared concurrency group, because every non-scheduled trigger — push, manual
  dispatch — bypasses the reasoning the schedules encode. D-011 survived a
  self-audit that corrected its rationale and still protected only one of four
  interleavings (D-011, second correction).
- Specifying a pipeline does not secure it. Ask what the *other* entrances are —
  the local recipe, the manual dispatch — because a rule enforced in one path
  and absent from another is a rule with a documented bypass (D-012).
- The readiness gate is worth honouring when the answer is inconvenient. Three
  paragraphs settled now is the cheap version of the same conversation (D-013).

## Carried into the next unit

- **RFC 0002 §6's first-publish verification is now discharge-able but not
  discharged.** The gate is proven against a throwaway local registry, not
  against GHCR. The first real scheduled run is what turns it into a fact, and
  it will be the first time `podman pull` authenticates against GHCR in this
  repo.
- The valkey track (RFC 0001 P2, RFC 0006 P2+P3) is blocked on D-013's three
  questions.
- RFC 0004 P2 still carries wave 1's R-7 — a `POSTGRES_EXTENSIONS` override
  publishes onto the default tags.
- The rebuild has never run on a schedule. Cron triggers only fire from the
  default branch, so this cannot be exercised until it merges.

## Reconciliation — 2026-08-16 (wave 2)

| RFC | Row | Outcome | Grade | Decision | From |
|---|---|---|---|---|---|
| 0002 | — | **Pending author** | — | Gate is push-by-digest → pull → smoke → `imagetools create`; local OCI layout rejected | D-010 |
| 0002 | — | **Pending author** | — | Rebuild cron must stay after the cleanup cron on the same day | D-011 |
| 0002 | — | **Pending author** | — | Publishing paths that bypass the smoke gate refuse by default | D-012 |

Wave 1's pending rows (D-003, D-004, D-005, D-006, D-008) are still pending and
are not restated here. **Row 17 (D-009) was written into RFC 0002 during wave 1's
review and flagged as needing ratification; it has not been explicitly ratified
and still stands.**

Nothing in this wave was written into an RFC. Every entry above touches a
`LOCKED` row or proposes a new one, and none of them is pre-authorised the way
RFC 0004 row 5 pre-authorised D-001 — so they wait.

---

# Wave 3 · Shared env-config helper and the valkey image

Branch `feat/wave-3-shared-envconf-valkey`. RFC 0001 P2, RFC 0006 P1, P2 and P3.

**Drift count: 5** — D-018, A-7, A-8, A-9, A-11. The count read 1 after execution and
was corrected by the self-audit; all three additions are places where a
**`LOCKED`** row or an explicit RFC instruction covered the case and the code
did something else. The rest of the entries are `spec-gap` or `discovery`; the
grading argument is under D-018, which is the one that could plausibly have
gone either way.

These four phases shipped as one unit because none of them is separately
verifiable. RFC 0001 P2 requires the helper be "exercised by exactly one
consumer" and that the consumer be a *new* image; RFC 0006 P2 requires the
allowlist mechanism be shared rather than copied, "and if it cannot be shared,
stop and fix RFC 0001". The helper alone is untested and the image alone is the
fork both documents forbid.

**This wave answers RFC 0006's open question 3** — *is RFC 0001's helper
genuinely shareable, or Postgres-specific in ways only a second consumer
reveals?* It is shareable, but not in the shape RFC 0001 described: three of
the entries below (D-014, D-015, D-018) are places where the contract as
written could not be implemented against a second config format, and all three
were invisible while `postgres` was the only consumer.

## D-014 — The source map is quads, not triples

- **Touches:** RFC 0001 §5.2 — the shape was settled with the author before
  execution (readiness gate, see D-021)
- **Settled as:** `key\0source\0origin\0` triples on stdin
- **Built:** `key\0value\0source\0origin\0` quads
- **Because:** the summary prints the effective *value* — that is most of its
  output and the reason anyone reads it — and the helper cannot obtain it. It
  has a prefix and `environ`; the effective value of a baked or mounted setting
  is in neither. A triple would have forced every image to pass its values
  through a second channel alongside the map, which is the same data in two
  places.
- **Class:** `spec-gap`. §5.2 named the argument and never its shape, and the
  triple was proposed from the same gap rather than from the code.
- **Consequence:** one more field per record for every future image.
- **Proposed row (RFC 0001):** `ASSUMED` — `envconf_summary` reads NUL
  delimited `key, value, source, origin` quads.

## D-015 — The allowlist is the authority on spelling

- **Touches:** RFC 0001 §5.1 — unlisted
- **RFC said:** "`<key>` is normalized (lowercase, `-`→`_`) and must be in that
  image's allowlist"
- **Built:** normalization decides whether a variable *matches* an entry; what
  is written to the config file is the entry's own spelling
- **Because:** §5.1 specifies matching and is silent on emitting, and for
  `postgres` the two coincide — postgresql.conf uses underscores, so the
  normalized form is also the correct output. valkey.conf uses dashes, so
  emitting the normalized key produces `maxmemory_policy`, which the server
  ignores silently. The obvious fix, mapping `_`→`-` on the way out, is **not a
  safe inverse**: valkey also has `server_cpulist`, `bio_cpulist`,
  `bgsave_cpulist` and `aof_rewrite_cpulist`. There is no rule that recovers
  the spelling, so the allowlist has to carry it.
- **Class:** `spec-gap`. Knowable at design time and pitched at the wrong
  altitude: the contract described a transformation without saying which
  direction it applied in.
- **Consequence:** allowlist files must use exact upstream spelling, which is
  now stated in `images/README.md` and in each allowlist's header. The postgres
  retrofit (P4) is unaffected — its spellings already coincide.
- **Proposed row (RFC 0001):** `LOCKED` — the allowlist carries the canonical
  upstream spelling and is the authority on it. Normalization is used only for
  matching, never for output, because it is lossy and its inverse is not
  computable.

## D-016 — Values are read through `awk ENVIRON`, never `eval`

- **Touches:** nothing in any RFC — an implementation hazard
- **Built:** `value=$(awk -v n="$name" 'BEGIN { printf "%s", ENVIRON[n] }'; printf X)`
- **Instead of:** `eval "value=\${${name}}"`
- **Because:** environment variable names may contain characters that shell
  parameter expansion claims for itself.
  `${VALKEY_CONF__notify-keyspace-events}` does not mean "the value of that
  variable" — it means "the value of `VALKEY_CONF__notify`, or the literal
  string `keyspace-events` if unset". So the lookup returns a **plausible wrong
  value** rather than failing. Dashed keys are not exotic here: §5.1 normalizes
  `-`→`_` precisely because operators write them.
- **Class:** `discovery`. Found by the image's smoke test, which asserted
  `notify-keyspace-events=KEA` reached the server and got
  `notify-keyspace-events keyspace-events` — a config the server then rejected.
  Nothing short of running it would have surfaced this.
- **Consequence:** one `awk` per passthrough variable at startup. Both suites
  now pin it: `shared/test/run.sh` covers the dashed name directly, and the
  smoke test covers it end to end.

## D-017 — Two additions to the contract's function list

- **Touches:** RFC 0001 §5.2, which lists five functions
- **Built:** six, and one gained a parameter
  - `envconf_load_denylist <path>` — §5.4 says the postgres denylist "moves
    into `rootfs/denylist.conf` alongside the allowlist", so a loader for it is
    required and was not listed
  - `envconf_collect <prefix> [curated_keys]` — decision 11's collision check
    needs the passthrough keys and the curated keys in one place, and the
    passthrough keys are already here
- **Because:** the alternative was a seventh function taking both sets, which
  is the same check with an extra hop.
- **Class:** `spec-gap`.
- **Consequence:** the collision check counts only curated variables the
  operator actually **set**, not every key the image writes. Counting defaults
  would make the passthrough spelling of any defaulted knob permanently
  unusable — `VALKEY_CONF__maxmemory_policy` would always collide with the
  image's own `allkeys-lru` default.

## D-018 — The `*KEY*` redaction pattern is narrowed to whole segments

- **Touches:** RFC 0001 §5.2
- **RFC said:** redact anything matching `*PASSWORD*`, `*TOKEN*`, `*SECRET*`,
  `*KEY*`, `*HEADERS*`
- **Built:** the first, second, third and fifth as substrings; `KEY`/`KEYS`
  only as a whole segment
- **Because:** `*KEY*` as a substring redacts `notify-keyspace-events`, which
  is an allowlisted valkey directive whose value an operator specifically needs
  to read. Over-redaction is not the safe direction it looks like: it hides
  settings the summary exists to reveal, and a summary that redacts obviously
  non-secret things teaches people to skim past the redactions that matter.
- **Class:** `drift`, and this is the one grading choice in this wave worth
  showing. The test is "could this have been known before code existed, and did
  the design cover it" — the design covered it, named the exact pattern, and
  the code does something else. That it is a *correction* of the RFC does not
  make it a `spec-gap`; every drift feels like a correction to whoever writes
  it, which is why the class is defined by what the document said rather than
  by how right the change looks.
- **Consequence:** a variable named `SIGNING_KEYS` still redacts; one named
  `keyspace` does not. Both suites pin both directions.
- **Proposed row (RFC 0001):** `ASSUMED` — the redaction heuristic matches
  `KEY`/`KEYS` as a delimited segment, not a substring.

## D-019 — Only `valkeyconf` is implemented; the other two refuse

- **Touches:** RFC 0001 §5.2, which declares `pgconf | keyvalue | valkeyconf`
- **Built:** `valkeyconf`; the other two abort naming themselves
- **Because:** this wave has exactly one consumer, and a renderer with no
  consumer is a renderer with no test. `pgconf` lands with P4's postgres
  retrofit, where a real `postgresql.conf` can verify it.
- **Class:** departure from the execution plan, agreed with the author before
  execution.
- **Consequence:** they fail loudly rather than emitting nothing, so a future
  image that reaches for one gets a message rather than an empty config file.

## D-020 — RFC 0006's two `OPEN` decisions, decided

- **Touches:** RFC 0006 decisions 9 and 10 (both `OPEN`)
- **Decision 9 — base image:** Alpine (`valkey/valkey:9.0-alpine`), as §5.1
  assumes. It is what makes RFC 0001 decision 7's POSIX-`sh` helper testable
  rather than aspirational; the whole helper is exercised on busybox `ash` on
  every PR.
- **Decision 10 — fallback `maxmemory`:** **268435456 (256 MiB)**, with a
  warning naming the reason. The row asked for "embarrassingly small": small
  enough that nobody mistakes it for a tuned value, large enough to start and
  serve. The fallback is reached on cgroup v1, in an unconstrained container,
  and where `memory.max` reads `max`.
- **Class:** `OPEN` rows decided by the executor, as that grade instructs.
- **Also decided, and not in any row:** values above 1 PiB are treated as
  unlimited and take the warned fallback, because some runtimes report a very
  large number in place of `max`, and the percentage arithmetic on it overflows
  64-bit to a negative `maxmemory` the server rejects at startup.

## D-021 — The readiness gate was answered before execution, not during

- **Touches:** the execution plan
- **Wave 2 reported** the valkey track as not ready: three load-bearing
  decisions the RFCs do not settle, which is `flag-dont-flip`'s threshold.
- **Settled with the author before any code:** the source-map shape (NUL
  delimited, later corrected by D-014), a dedicated `shared/` test harness, and
  `VALKEY_RENAME_DANGEROUS` as an explicit list of commands to rename.
- **Consequence, and the reason this entry exists:** two of the three answers
  were changed by execution — the source map gained a field (D-014) and the
  helper's spelling rule was rewritten (D-015). The gate was still worth
  running. Settling them made the *questions* explicit, so both changes are
  visible as amendments to a recorded answer rather than as choices nobody
  knew were being made.

## Self-audit findings — wave 3, 2026-08-16

Found by the adversarial pass over the finished branch. They span both halves
of the wave: A-7 and A-8 are in the `valkey` entrypoint, A-9 in its README,
A-10 in the helper's test suite and A-11 in the helper itself.

| # | Where | Finding | Class | Status |
|---|---|---|---|---|
| A-7 | `entrypoint.sh` | A mounted fragment was summarised as one `(fragment) = included verbatim` line. RFC 0001 decision 13 (`LOCKED`) requires **full per-setting `source=` attribution** from an image that assembles its config from enumerable layers, and this is one. "Which layer won" is unanswerable when a whole file collapses to a single row. Now parsed and attributed per directive. | `drift` | Fixed |
| A-8 | `entrypoint.sh` | The §5.3 refusals read the *environment*, so a fragment setting `appendonly yes` turned on persistence without passing through `VALKEY_PERSISTENCE` and walked straight past a refusal decision 6 marks `LOCKED`. The refusals now run a second time against the **assembled** config, which covers all three layers uniformly. | `drift` | Fixed |
| A-9 | `images/valkey/README.md` | The Networking section said reachability "is the business of your network" and that a password *should* be set. In fact `protected-mode` plus no password means the server **refuses every non-loopback connection** — the service is simply unreachable. RFC 0006 §5.4 requires the bind behaviour "stated explicitly in the README rather than inherited silently", and it was inherited silently. | `drift` | Fixed |
| A-11 | `envconf.sh`, `entrypoint.sh` | **RFC 0001 decision 9 (`LOCKED` 2026-08-12) was not implemented at all.** A `<PREFIX>_*` variable that is neither a curated name nor a passthrough key must warn — `VALKEY_MAXMEMROY=100mb` did nothing, silently, which the row calls "the failure this contract exists to prevent". Added `envconf_warn_unknown`, with the row's ignore list (`_CONF_STRICT`, `_CONF_ALLOWLIST`, any `_FILE`) and non-fatal by design. | `drift` | Fixed |
| A-10 | `shared/test/run.sh` | Two surviving mutants. Removing the `_FILE` trailing-newline strip survived, because `$(...)` strips trailing newlines and the assertion could not see the difference. Removing the `sort` in `envconf_collect` survived, because nothing asserted the deterministic ordering the helper claims. | — | Fixed |

**A-11 is why pass 10 is worth running even when the code looks finished.**
Every other finding here came from probing behaviour; this one came from
reading the decision table row by row against the implementation, and it is a
whole `LOCKED` row that was never built. Nothing about the code looked wrong,
because the missing feature left no trace — which is exactly the shape of
defect that only an oracle catches.

**A-8 is the one that mattered.** A-7 and A-9 degrade what a reader is told;
A-8 was a way to reach the exact silent data loss this image exists to prevent,
and it existed because the refusals were written against the *input* rather
than against the *result*. Checking the assembled configuration is strictly
better and would have covered the environment channel too.

A-10 is worth separating because neither gap was visible from reading the
tests, and one of them — the trailing-newline case — had an assertion that
looked precise and could not fail. Mutation is what found both.

## Rules distilled

- A contract that describes a transformation must say which **direction** it
  applies in. `-`→`_` for matching and `-`→`_` for output are different rules
  that happen to coincide for one config format, which is exactly how the
  ambiguity survived a whole RFC (D-015).
- Before normalizing a key, ask whether the original spelling is recoverable.
  If it is not, the lossy form cannot be the one you store (D-015).
- Never use `eval "v=\${$name}"` on a name you did not construct. Shell
  parameter syntax claims `-`, `:`, `#`, `%` and `?`, so the expansion silently
  returns something plausible instead of failing (D-016).
- A redaction heuristic is a claim about a namespace. `*KEY*` is sound for
  environment variables and wrong for config directives, where `keyspace` and
  `keepalive` are ordinary words (D-018).
- The second implementation of an interface is what tests the interface. Three
  entries here are contract defects that were invisible while `postgres` was
  the only consumer, and none of them needed a *third* (D-014, D-015, D-018).
- Walk the decision table against the code as a list, not as a memory. A row
  that was never implemented leaves nothing in the diff to notice (A-11).
- Refuse against the **result**, not the input. A guard written against one
  input channel is bypassed by every other channel that reaches the same state
  — and the config file, not the environment, is what the server reads (A-8).
- An assertion that cannot fail looks exactly like one that passes. `$(...)`
  strips trailing newlines, so a test comparing captured output can never see
  trailing-whitespace behaviour (A-10).
- Answering a readiness gate is worth doing even when the answers turn out
  wrong. A recorded wrong answer becomes a visible amendment; an unrecorded
  assumption becomes a silent design (D-021).

## Carried into the next unit

- **RFC 0001 P3** (`caddy` startup summary) and **P4** (`postgres` retrofit).
  P4 now has a helper proven against a second config format, and D-015 says its
  spellings coincide so the retrofit does not inherit that problem.
- **`pgconf` and `keyvalue` renderers** ship with their first consumers (D-019).
- **RFC 0004 P2** still carries wave 1's R-7 — a `POSTGRES_EXTENSIONS` override
  publishes onto the default tags.
- **RFC 0002 §6's first-publish verification** is still not discharged; it needs
  a real GHCR push, which wave 2's gate now performs on merge.
- `postgres` still has its own bash implementation of the two channels, so the
  contract is implemented twice in this repo until P4. `images/README.md` says
  so rather than leaving a reader to assume the helper is universal.

## Reconciliation — 2026-08-16 (wave 3)

| RFC | Row | Outcome | Grade | Decision | From |
|---|---|---|---|---|---|
| 0001 | — | **Pending author** | — | `envconf_summary` reads key/value/source/origin quads | D-014 |
| 0001 | — | **Pending author** | — | The allowlist carries canonical spelling and is the authority on it | D-015 |
| 0001 | — | **Pending author** | — | Redaction matches `KEY`/`KEYS` as a segment, not a substring | D-018 |
| 0006 | 9 | **Decided by executor** | `OPEN` | Alpine base | D-020 |
| 0006 | 10 | **Decided by executor** | `OPEN` | 256 MiB warned fallback | D-020 |

Decisions 9 and 10 are recorded as decided rather than pending: `OPEN` delegates
them to execution, so no author acceptance is outstanding. The three RFC 0001
rows are the author's, and **D-015 is the one to look at** — it proposes a
`LOCKED` row constraining every future image's allowlist file.

Still pending from earlier waves: D-003, D-004, D-005 (as corrected), D-006,
D-008, D-010, D-011, D-012, and row 17 from D-009 which remains unratified.
Nothing from those waves has been accepted into an RFC except row 14 (D-001).
**Nine proposed rows are now outstanding across three waves**, which is the
failure mode `flag-dont-flip` calls "the log with no proposals accepted" and is
worth a deliberate pass rather than another entry.

---

# Wave 4 · The caddy summary, and the reconciliation backlog

Branch `feat/wave-4-caddy-summary`. RFC 0001 P3, RFC 0002 §6's first-publish
verification, and a pass over every proposed row from waves 1–3.

**Drift count: 0** — no entry below is a case where a decision row covered it
and the code did something else. Two of the entries record a conflict *inside*
RFC 0001 (D-022) and one records an implementation the RFC could not have
anticipated (D-024); the rest are gaps. The count is written after the
self-audit and carries its findings, so it is the final figure for this wave
rather than the pre-audit one.

**RFC 0001 P4 is deliberately not here.** §12 and §9 both say the `postgres`
retrofit lands as its own PR — it is the only step in this RFC that can regress
a running deployment, and folding it in would have made this wave the one that
does. The reconciliation pass is here instead, because eleven unratified rows
across three waves is the failure mode the practice is named against.

## D-022 — `caddy`'s curated names become `CADDY_*`, with the old names kept

- **Touches:** RFC 0001 decision 1 (`LOCKED`), §4 non-goals, §5.4
- **RFC said:** two things that cannot both hold. Decision 1: curated names are
  `<PREFIX>_<NAME>`, and `<PREFIX>` for this image is `CADDY`. §4: renaming
  existing variables is a **non-goal**, naming `CONFIG_DIR` and `EDGE_ADDRESS`
  specifically, because "the contract is written to fit them".
- **Built:** `CADDY_<NAME>` as the canonical spelling, with all nine unprefixed
  names kept as aliases that warn, are honoured, and are attributed in the
  summary as `source=env`.
- **Because:** the conflict is in the document, so the executor does not get to
  pick — it went to the author at the plan gate, who chose decision 1's rule
  with the published surface preserved rather than either half alone.
- **Class:** `spec-gap`. Both statements were written before any code and
  neither cites the other; nothing about building it revealed the conflict,
  only reading the two sections next to each other did.
- **Consequence:** two spellings to maintain, and a deprecation window that
  nothing yet schedules. The alias table is nine rows in the entrypoint, and
  dropping it later is a separate decision with its own announcement.
- **Proposed row (RFC 0001):** `LOCKED` — written as decision 20.

## D-023 — The summary's header and footer belong to the image

- **Touches:** RFC 0001 §5.2, which fixes both strings in its example
- **RFC said:** `[envconf] postgres: effective non-default settings`, closing
  with `precedence: baked < mounted < env`
- **Built:** `envconf_summary <prefix> [infile] [header] [footer]`, and `caddy`
  passes `effective configuration` over `precedence: image default <
  environment`
- **Because:** `caddy` prints *every* variable it reads — decision 13 says it
  cannot tell a default from a supplied value, so "non-default" is a claim it
  is not entitled to make — and it has neither a baked config file nor a
  mounted layer, so the precedence line names layers that do not exist. Both
  defaults are claims about `postgres`, and the helper had been asserting them
  on behalf of every image.
- **Class:** `spec-gap`. §5.2's example and §5.4's description of `caddy` are
  four hundred words apart in the same document and contradict each other.
- **Consequence:** an image that overrides neither string still inherits
  `postgres`-shaped claims, which is the right default and a live trap for the
  next image that is not `postgres`-shaped.
- **Proposed row (RFC 0001):** `ASSUMED` — written as decision 18, with the
  function-list change folded into decision 17.

## D-024 — Three source labels, and the one that was left on the table

- **Touches:** RFC 0001 decision 13 (`LOCKED`)
- **Built:** `source=env` when a legacy alias supplied the value, `source=baked`
  when the variable was absent or empty and the image default applied, and
  `source=env-or-default` for everything else
- **Because:** decision 13's reasoning is that `environ` cannot distinguish a
  Dockerfile default from a supplied value. That is true of the canonical
  names, which the Dockerfile sets — and false of the legacy names, which it
  deliberately does not, so a value under one is provably the operator's.
- **Class:** `discovery`. The alias mechanism created a channel with no baked
  default, and that channel did not exist when decision 13 was written.
- **Deliberately not applied:** the same reasoning would license `source=env`
  for a *canonical* value that differs from the entrypoint's copy of the baked
  default — the image does know that. It is not implemented, because decision
  13 is `LOCKED` and says those lines print `env-or-default`. The gain is one
  more precise word on lines an operator can already read; the cost is an
  executor overruling a `LOCKED` row on their own judgement, which is the exact
  trade the grade exists to refuse.
- **Consequence:** the summary is more informative for operators still on the
  old spelling than for those who migrated, which is backwards as an incentive
  and correct as a statement of what is known.

## D-025 — Two spellings of one name collide, with one case that cannot

- **Touches:** RFC 0001 decision 11 (`LOCKED`), which covers curated-versus-passthrough
- **Built:** setting both `EDGE_ADDRESS` and `CADDY_EDGE_ADDRESS` to different
  values aborts naming both and their values
- **Because:** decision 11's principle is that an operator who set the same
  thing twice must not silently get one of them. Nothing about that principle
  is specific to the passthrough channel.
- **Class:** `spec-gap`.
- **Consequence:** one case is undetectable and is documented rather than
  hidden. A canonical value that happens to equal the image default is
  indistinguishable from unset (decision 13 again), so `CADDY_EDGE_ADDRESS=:8080`
  plus `EDGE_ADDRESS=:9000` starts on `:9000`. The warning names the value it
  started with, so the operator can see the choice that was made even though
  the code could not refuse it.
- **Proposed row (RFC 0001):** `ASSUMED` — written as decision 21.

## D-026 — The defaults are duplicated three times, on purpose, and pinned

- **Touches:** nothing in any RFC — an implementation shape
- **Built:** the nine defaults live in the Dockerfile's `ENV`, in the
  entrypoint's alias table, and in the README table. `smoke.sh` extracts all
  three from the built image and the repo and asserts they agree.
- **Because:** the entrypoint needs its own copy to answer "did you set this or
  did we", which is the whole source column; the `ENV` copy is what a bypassed
  entrypoint and a derived image see; the README is what an operator reads.
  Removing any one of the three costs something real.
- **Class:** `discovery`.
- **Consequence:** three copies with a test between them, rather than one copy
  and a documentation lie. Nothing at runtime can catch them drifting — an
  operator-supplied value and a baked one are the same string — so the check
  has to live in the smoke test or nowhere.

## D-027 — `caddy` gets no passthrough channel, and says so

- **Touches:** RFC 0001 §10's first unresolved question
- **RFC said:** open, "leaning: no channel", to be settled before RFC 0005
  copies the pattern
- **Built:** no channel, and a `CADDY_CONF__*` variable is **warned about**
  rather than ignored
- **Because:** the leaning is right — Caddy's config is not key-value, so the
  mapping would be a fiction — and the warning exists because the helper skips
  `<PREFIX>_CONF__*` for every other image, where that prefix *is* the channel.
  Without it, an operator copying the `postgres` pattern gets exactly the
  silence decision 9 exists to prevent.
- **Class:** `discovery` for the warning; the channel question itself was
  delegated and is now answered.
- **Proposed row (RFC 0001):** `ASSUMED` — written as decision 22, and §10's
  question struck through with a pointer to it.

## D-028 — RFC 0002 §6's first publish, verified against GHCR

- **Touches:** RFC 0002 §6 — carried unfinished since wave 1
- **Verified** against the two real publishes that ran on merge (runs
  31964963480 and 31969227420), not against the throwaway local registry wave 2
  used:
  - **What was smoked is what is published.** The digests the gate pulled and
    smoke-tested are the digests the mutable tags resolve to today, for all
    four images: `caddy@f5e63f05`, `flyway@f6113802`, `postgres@1524c8a9`,
    `valkey@a21e6e31`.
  - **Attestations survived the promotion.** `imagetools inspect` returns SLSA
    provenance with the build arguments and an SPDX SBOM listing both Alpine
    packages and Go modules.
  - **Eight labels populated**, with `.revision` = `c643ad2`, the merge commit
    that produced the image.
  - **The dated tag and the mutable tag resolve to one digest**:
    `18.6-20260816-31969227420.1` and `18.6` are the same version.
  - **A local `just bake postgres` produces one tag and no dated alias.**
- **Not verified:** divergence of the two tags after the *next* publish, which
  needs a second run and is now mechanical.
- **Class:** not a departure — the discharge of a test the RFC asked for.

## D-029 — The cleanup job's dry run is not zero, and one deletion matters

- **Touches:** RFC 0002 §6, RFC 0004 §6 and D-006's addendum
- **RFC said:** "a `dry_run: true` cleanup run reports **zero deletions**
  against them"
- **Measured** (run 31971410999, dry run, nothing deleted): **69 versions would
  be deleted**, none of them tagged, none of them belonging to any image
  published under the tag policy. Every current digest and every current
  attestation manifest is untouched, which is the property §6 was reaching for;
  the deletions are the pre-tag-policy publishes, whose digests went untagged
  the moment the mutable tag moved. `valkey`, published only once and only
  since the policy, reports "nothing to delete".
- **Because:** the tag policy landed on 2026-08-16. Everything published before
  it has exactly one tag, and that tag has since moved.
- **Class:** `spec-gap` — §6's expectation is written as "zero deletions" when
  the property that matters is "zero deletions *of what the gate published*".
- **The finding that matters:** one of those 69 is
  `postgres@sha256:9934cb32…`, the digest **RFC 0004 D-006's addendum names as
  the immutable pre-refactor reference** for the equivalence check. It is
  untagged, so the next real cleanup run deletes it — the cron is 04:00 Monday,
  which is roughly seven hours after this was measured. A digest survives a
  repointed tag; it does not survive this repo's own garbage collection, and
  the addendum treated the first property as if it implied the second.
  RFC 0004's proposed row 15 is written to say so rather than to repeat the
  claim. Keeping the reference means giving it a tag, which is a registry write
  and the author's to make.
- **Proposed row (RFC 0002):** none. §6 is a test list, not a decision table;
  the correction belongs in §6's wording, which is the author's to amend.

## Self-audit findings — wave 4, 2026-08-16

Found by the adversarial pass over the finished branch, after the entries above
were written.

| # | Where | Finding | Class | Status |
|---|---|---|---|---|
| A-12 | `images/caddy/smoke.sh`, `images/valkey/smoke.sh` | **A refusal that stops refusing hangs the job instead of failing it.** Both scripts assert a refusal with `run --rm … "${IMAGE}"` and check for a non-zero exit — but an image that no longer refuses *starts a server*, so the command never returns. Measured: `timeout` reports 124 against a non-refusing image, and unbounded it runs until CI kills the job, which reads as an infrastructure problem rather than as the data-loss regression it is. Both now bounded, with 124 reported as its own failure. The valkey helper also passed `--name` to `rm -f` for a container it had never named. | — | Fixed |
| A-13 | `entrypoint.sh` | The source map survived into the running container. `trap … EXIT` does not fire across `exec`, so `/tmp/tmp.XXXX` — a file describing the configuration — sat there for the life of the process. Removed after the summary consumes it. | — | Fixed |
| A-14 | `entrypoint.sh` | `env_present()` was written, never called. Dead code in the file that decides what an operator's variables mean. Removed. | — | Fixed |
| A-15 | `images/caddy/README.md` | "everything beginning with `CADDY_` is checked against the table above" — false. `CADDY_CONF__*`, `CADDY_CONF_STRICT`, `CADDY_CONF_ALLOWLIST`, any `*_FILE` and upstream's `CADDY_VERSION` are all exempt by decision 9's ignore list. The sentence was selling the migration on a guarantee one paragraph wider than the one that exists. | — | Fixed |

**None of the four is `drift`,** and saying so is worth more than the count:
no decision row governs test bounding, temp-file lifetime, dead code or that
sentence. The wave's drift count stays 0 — not because the audit found
nothing, but because what it found is not the thing that number measures.

**A-12 is the one that mattered**, and it was found by accident: an experiment
meant to sabotage the *image* revealed the *test* could not fail. It is also
the second time this wave that a check turned out to be shaped so a regression
would show up as something other than a failing assertion — the first was the
reason `smoke.sh` compares three copies of the defaults rather than trusting
them. A test that hangs is worse than a test that fails, because the hang gets
attributed to the runner.

Verification actually performed, rather than claimed:

- Helper suite: **102 passed / 0 failed** under `bash`, **99 / 0** under busybox
  `ash` in an Alpine container (the shell the images actually run). The gap is
  two capability skips plus one case that cannot run as root.
- `images/caddy/smoke.sh`: full pass against the built image, including the
  three-way defaults check and the summary ordering assertion.
- `images/valkey/smoke.sh`: full pass, re-run because A-12 changed its helper.
- Sabotage, each verified red and reverted: the header override removed from
  the helper (2 assertions fail); a README default changed (1); an entrypoint
  default changed (1); the deprecation warning removed (1); a non-refusing
  image fed to the collision case (reported as "started and kept running",
  which is the branch A-12 added).
- Runtime states: root and `--user caddy` both start and serve; an emptied
  variable; a `/docker-entrypoint.d` hook is still sourced before resolution.

## Rules distilled

- A refusal test must be **bounded**. The failure mode of a lost refusal is not
  a non-zero exit, it is a process that keeps running, and an unbounded
  assertion turns that into a hung job attributed to the runner (A-12).
- When two sections of one document disagree, the executor's job is to notice,
  not to choose. D-022's conflict was one `LOCKED` row against one non-goal,
  four hundred words apart, and either half read alone looked settled.
- A default duplicated across a Dockerfile, an entrypoint and a README is fine
  if a test compares all three, and a lie waiting to happen otherwise. Ask
  which copies exist before deciding whether duplication is the problem (D-026).
- `trap … EXIT` does not fire across `exec`. Any entrypoint that hands off to a
  server leaks whatever it meant to clean up (A-13).
- A digest is immutable, not durable. It survives a repointed tag and not a
  garbage collector, and this repo runs one weekly (D-029).
- Precision you are entitled to is not always precision you may print. A
  `LOCKED` row that mandates a weaker label outranks an executor's correct
  observation that a stronger one is available (D-024).

## Carried into the next unit

- **RFC 0001 P4** (`postgres` retrofit) is the last phase of RFC 0001 and the
  only one that can regress a running deployment. It needs the `pgconf`
  renderer (D-019), the denylist moved to a file (§5.4), and §6's tests green
  before it lands.
- **`postgres@sha256:9934cb32…` is deleted by the next cleanup run** unless it
  is tagged. That digest is RFC 0004 §6's pre-refactor reference (D-029). A
  registry write is the author's call; nothing in this wave made one.
- **RFC 0002 §6's wording** needs the correction D-029 describes: "zero
  deletions" is true only of images published under the tag policy.
- **The alias deprecation has no end date.** Decision 20 keeps nine unprefixed
  names working; nothing schedules their removal, and the next wave that
  touches `caddy` should either set that date or record that there is none.
- ~~RFC 0002 §6's first-publish verification~~ — discharged, D-028.
- ~~Nine proposed rows outstanding across three waves~~ — drafted as rows for
  ratification; see the reconciliation table below.
- **`keyvalue` renderer** still ships with RFC 0005, `pgconf` with P4 (D-019).

## Reconciliation — 2026-08-16 (wave 4)

Every outstanding proposal from waves 1–3 is written into its RFC's decision
table as a row citing the entry it came from. **They are proposals until this
branch merges** — the author ratifies by accepting the PR, or strikes any row
and the refusal is recorded here in the next pass.

| RFC | Row | Outcome | Grade | Decision | From |
|---|---|---|---|---|---|
| 0002 | 17 | **Awaiting explicit ratification** | `LOCKED` | `BUILD_STAMP` is `<yyyymmdd>-<run_id>.<run_attempt>` | D-009 |
| 0002 | 18 | **Proposed** | `ASSUMED` | Build-stage images are smoked for toolchain presence, not a `--help` | D-004 |
| 0002 | 19 | **Proposed** | `ASSUMED` | CI exports `type=oci` and loads into Podman; the docker exporter cannot | D-005 (as corrected) |
| 0002 | 20 | **Proposed** | `LOCKED` | The gate is push-by-digest → pull → smoke → `imagetools create` | D-008, D-010 |
| 0002 | 21 | **Proposed** | `ASSUMED` | One concurrency group for every workflow that mutates GHCR | D-011 |
| 0002 | 22 | **Proposed** | `ASSUMED` | Publishing paths that bypass the gate refuse by default | D-012 |
| 0004 | 15 | **Proposed** | `ASSUMED` | The equivalence reference is a digest — and a digest is not durable here | D-006, D-029 |
| 0001 | 14 | **Proposed** | `ASSUMED` | The summary reads NUL-delimited quads | D-014 |
| 0001 | 15 | **Proposed** | `LOCKED` | The allowlist is the authority on canonical spelling | D-015 |
| 0001 | 16 | **Proposed** | `ASSUMED` | Redaction matches `KEY`/`KEYS` as a segment | D-018 |
| 0001 | 17 | **Proposed** | `ASSUMED` | Six functions, and `envconf_summary` takes a header and footer | D-017, D-023 |
| 0001 | 18 | **Proposed** | `ASSUMED` | Header and footer are the image's claims, not the helper's | D-023 |
| 0001 | 19 | **Proposed** | `ASSUMED` | A renderer ships with its first consumer; the rest abort | D-019 |
| 0001 | 20 | **Decided by the author** | `LOCKED` | `caddy`'s curated names are `CADDY_*`, old names kept as warning aliases | D-022 |
| 0001 | 21 | **Proposed** | `ASSUMED` | Two spellings of one curated name collide and refuse | D-025 |
| 0001 | 22 | **Proposed** | `ASSUMED` | `caddy` has no passthrough channel; §10's question struck through | D-027 |

**Sixteen rows, of which fifteen were owed from earlier waves or this one and
one is a ratification.** D-003, D-016, D-024 and D-026 propose no row on
purpose: the first is a cosmetic mismatch between a phase and a snippet, and
the other three are implementation shapes with no decision to record. D-013,
D-021 and D-029 touch the plan or a test list rather than a decision table.

The row to read first is **RFC 0001 row 15** (`LOCKED`), which constrains every
future image's allowlist file, and **row 20**, which is the one decision in this
table the author made rather than the executor proposing.

## D-030 — Hooks are sourced, so their assignments are not in `environ`

- **Touches:** nothing in any RFC — this image's own hook contract
- **Built first:** every curated variable read through `awk ENVIRON`, per the
  habit D-016 established
- **Built now:** read through the shell scope, with a guard that refuses a name
  that is not a plain identifier before it reaches `eval`
- **Because:** `/docker-entrypoint.d/*.sh` are **sourced**, so a hook writing
  the natural `EDGE_ADDRESS=:8081` sets a shell variable, not an environment
  variable. `ENVIRON` cannot see one, so the alias resolution ignored it and
  started on the baked default — while the comment directly above the hook loop
  claimed hook-set legacy names reach the alias handling. Reproduced both ways:
  unexported is ignored, `export` works.
- **Class:** ordinary defect, found by review. No decision row governs hooks.
- **On D-016:** its rule is "never `eval` on a name you did not construct", and
  every name here comes from the literal table in the same file. The guard is
  what keeps that true — a future row containing a `-` now aborts with an
  internal error instead of silently expanding as `${VAR-default}`, which is
  the exact failure D-016 was written about.

## D-031 — A newline is refused for values Caddy substitutes, not just rendered

- **Touches:** RFC 0001 decision 12 (`LOCKED`)
- **RFC said:** the collect→render wire format is NUL-delimited and
  newline-bearing values are refused
- **Built first:** curated values exported unchecked — this image never calls
  `envconf_collect`, so nothing refused anything
- **Built now:** `envconf_refuse_newline` in the helper, applied to both
  spellings before either is exported or written to the source map
- **Because:** Caddy expands `{$VAR}` itself, so a newline is not a corrupt
  record — it is a second directive. Measured before the fix: a newline-bearing
  `CADDY_EDGE_ADDRESS` added a complete server block and a second listener on
  `:8099` to the running configuration, invisible in the Caddyfile on disk
  because substitution happens at adapt time.
- **Class:** `drift`, and the temptation to call it `spec-gap` is worth naming.
  Decision 12 attaches its refusal to `envconf_collect`, which this image does
  not use, so a literal reading exempts it. That reading is wrong for the same
  reason wave 3's A-8 was: the rule exists so no image lets a newline reach a
  config parser, and this image let one reach Caddy's. **The wave's drift count
  is 1.**
- **Proposed row (RFC 0001):** none needed — decision 12 already says it. What
  changed is that the helper now offers the check to images that do not collect.

## D-032 — The unknown-name warning's remediation is the image's to write

- **Touches:** RFC 0001 decision 9 (`LOCKED`), §5.2's function list
- **Built:** `envconf_warn_unknown <prefix> <known> [remediation]`
- **Because:** the helper's sentence ends "or use `<PREFIX>_CONF__<directive>`
  for a passthrough setting", and `caddy` warns against exactly that two lines
  later. A typo'd variable was answered with advice the next check rejects.
- **Class:** ordinary defect, found by review.
- **Proposed row (RFC 0001):** folded into decision 17's function list.

## Review findings — PR #31, 2026-08-16

| # | Where | Finding | Class | Status |
|---|---|---|---|---|
| R-11 | `entrypoint.sh` | A hook's plain `EDGE_ADDRESS=:8081` was silently ignored — sourced hooks set shell variables and `awk ENVIRON` sees only exported ones. The comment above the hook loop claimed the opposite. See D-030. | — | Fixed |
| R-12 | `entrypoint.sh` | A newline in a curated value reached Caddy's substitution and **added a server block** to the running config. Decision 12 (`LOCKED`) refuses newline-bearing values; this image never called the function that enforces it. See D-031. | `drift` | Fixed |
| R-13 | `README.md`, `smoke.sh` | "Setting both spellings to different values aborts startup" was unconditional, and one combination cannot abort — a canonical value equal to the baked default is indistinguishable from unset. Now documented with its exception and pinned by a smoke case that asserts the alias wins and says so. The reviewer's alternative — drop the baked `ENV` defaults so every state is detectable — was not taken: the `ENV` block is what a derived image overrides and what a bypassed entrypoint reads. | — | Fixed |
| R-14 | `envconf.sh`, `entrypoint.sh` | The unknown-name warning offered `CADDY_CONF__<directive>` as the remedy on an image whose next warning rejects that channel. See D-032. | — | Fixed |
| R-15 | both `smoke.sh` | `timeout` sends `SIGTERM` and then waits, so an engine that ignores it hangs the assertion the timeout was added to bound. Both now use `--kill-after`, and **both treat 137 as well as 124** as "started and kept running" — without that, the kill path would have exited 137 and been read as a successful refusal, which is the hole the fix would otherwise have opened. | — | Fixed |
| R-16 | `rfcs/0002` §5.4, §5.5 | Rows 18 and 20 superseded procedures whose prose still read as normative. Both sections now carry a superseded note pointing at the row, rather than being rewritten — the procedure is the record of what was decided then. | — | Fixed |
| R-17 | `.github/workflows/cleanup-images.yaml` | Preserve RFC 0004 §6's equivalence digest from cleanup. Real, and **not fixable in this PR**: `dataaxiom/ghcr-cleanup-action` exposes `exclude-tags` and `keep-n-untagged` — nothing that names an untagged digest — so the only durable fix is giving the digest a tag, which is a registry write. Recorded in D-029 and in RFC 0004 row 15. | — | **Open**, needs a registry write |

**Found while fixing R-15: the fix nearly repeated wave 3's G7.** The first
version of the shared `refuse` helper was called as `out=$(refuse …)`, which
puts its `exit 1` inside a subshell — where it ends the substitution and not
the script, exactly as the counter increments did in wave 3. It was rewritten
to write to a file and run in the main shell before it ever ran. The rule
distilled from G7 was in this same file and did not prevent the same shape
being written a second time; what caught it was reading the diff.

---

# Wave 5 · The postgres retrofit

Branch `feat/wave-5-postgres-retrofit`. RFC 0001 P4, and the `pgconf` renderer
it needed (D-019).

**Drift count: 1** — D-036, against the pre-RFC `postgres` entrypoint, found by
the §6 battery this wave wrote. Two further defects (D-037, D-038) are ordinary
ones with no row behind them.

RFC 0001 is complete with this unit: P1 the contract, P2 the helper and `valkey`,
P3 `caddy`, P4 `postgres`.

## D-033 — The `pgconf` renderer quotes every value, and does not escape backslashes

- **Touches:** RFC 0001 §5.2 (`envconf_render` formats), decision 19
- **RFC said:** `pgconf` is one of three formats; it does not say what the output
  looks like
- **Built:** `parameter = 'value'`, single quotes doubled, backslashes left alone
- **Because:** the retrofit must not change what this image already publishes,
  and the bash version quoted unconditionally. Postgres accepts a quoted literal
  for every parameter type, so `max_connections = '200'` is valid and is what
  operators' existing `99-overrides.conf` files already contain. Backslashes are
  literal in `postgresql.conf` — `standard_conforming_strings` governs SQL string
  literals, not configuration values — so escaping them would corrupt a
  `log_line_prefix`.
- **Class:** `discovery`. The format existed only as a name until it had a
  consumer, which is exactly what decision 19 delegates.
- **Verified:** the generated `99-overrides.conf` is byte-identical between the
  published pre-retrofit image and this build, header line excluded.

## D-034 — The summary reports all 35 baked directives, and the build says which fragments are its own

- **Touches:** RFC 0001 decision 13 (`LOCKED`), decision 3 (`LOCKED`)
- **RFC said:** full `source=` attribution is required of images that generate a
  config file from enumerable layers. It does not say what "enumerable" includes
  for an image whose baked layer is an 880-line file, nor how a baked fragment in
  an include directory is told from a mounted one.
- **Built:** every directive the baked `postgresql.conf` assigns gets a row
  (35 of them), and `build-extensions` records the fragments it installed in
  `conf.d/.baked-fragments`, so anything else in that directory reads as
  `mounted`.
- **Because:** the alternative readings both make the summary answer less than
  the row asks. Reporting only contested keys hides the image's tuning from an
  operator who set nothing; reporting nothing from the baked file makes
  `source=baked` almost unreachable on the one image that can compute it. And a
  filename convention for the fragment question is wrong the moment somebody
  mounts a file whose name looks baked — the build is the only place that knows
  the answer, so it writes it down.
- **Class:** `spec-gap` for both halves — decision 13 is pitched at "which images
  must attribute" and leaves "how" to each image, which is right for one image
  and underspecified at three.
- **Settled with the author before execution**, along with the third question in
  this wave's gate.
- **Proposed row (RFC 0001):** an image whose baked layer is a config file
  reports every directive that file assigns; an image that reads an include
  directory records at build time which files it shipped.

## D-035 — The published control names keep working, and the contract's are accepted too

- **Touches:** RFC 0001 decision 10 (`ASSUMED`)
- **RFC said:** `postgres` keeps `PG_CONF_STRICT_MODE` and
  `PG_CONF_ALLOWLIST_PATH` as published; new images use the `_CONF_STRICT` form
- **Built:** both spellings work, the published one wins nothing — setting the
  two to **different** values refuses naming both
- **Because:** the helper reads the contract's spelling, so the retrofit has to
  translate, and translation makes both names live whether or not that is
  admitted. Refusing a conflicting pair is the same rule decision 11 applies to
  a curated name colliding with a passthrough key, for the same reason: an
  operator who sets both cannot tell from any document which one the code reads.
- **Also:** the helper's allowlist-miss message names `PG_CONF_STRICT`, which is
  the contract's spelling and not this image's published one. It is not wrong —
  that variable does work — so the README documents both rather than the message
  being special-cased per image again (wave 4 R-14 did that once already).
- **Class:** `spec-gap`. Decision 10 says which names survive and not what
  happens when both are set.
- **Proposed row (RFC 0001):** where an image publishes an alias for a contract
  control, both spellings are accepted and a conflicting pair refuses.

## D-036 — A read-only mounted fragment has never been able to start this image

- **Touches:** RFC 0001 decision 3 (`LOCKED`), §6's precedence case
- **RFC said:** precedence is baked → mounted → environment "in every image", and
  §6 asks for a test where a baked value, a mounted `50-*.conf` value and an env
  value resolve to the env value
- **Found:** the mounted layer aborts the container whenever the fragment is
  mounted read-only, which is the natural way to mount one:

  ```
  chown: changing ownership of '/etc/postgresql/conf.d/50-tuning.conf':
         Read-only file system
  ```

  The cause is a `chown -R` over the include directory, under `set -e`.
- **Reproduced against the published pre-retrofit image**, so this is not a
  regression introduced here — it is a defect the retrofit's own §6 battery is
  what finally caught. Nothing tested the mounted layer before this wave.
- **Built:** the directory is still chowned, and the recursive pass is attempted
  and **warned about** rather than fatal. A read-write fragment with a
  restrictive mode still gets taken over, which is what the recursion was for;
  whether the server can read a file it does not own is the server's own error to
  report, and it does.
- **Class:** `drift`. A `LOCKED` row says the mounted layer works in every image,
  and this image refused it. The code predates the row, which explains it and
  does not change the class — the row describes what the image must do, and the
  count is what makes "we never checked" visible.

## D-037 — `$( )` would have dropped a trailing empty value from the summary

- **Touches:** nothing in an RFC; wave 3's A-10 in a different costume
- **Built:** the env channel's quads are read through a pipe, not a here-document
- **Because:** `PG_CONF__log_line_prefix=` renders `log_line_prefix = ''`, and a
  final pair whose value is empty ends the stream with two NULs. Converted
  inside `$(...)`, both trailing newlines are stripped, `read value` fails, and
  the row vanishes from the summary while still reaching the file — a setting
  applied and not reported, which is the one failure the summary exists to
  prevent.
- **Class:** `discovery`, and it was found by writing the loop rather than by a
  test. The rule from A-10 is what made it visible.

## D-038 — Three test defects, each of which looked like a code defect

- **Touches:** nothing; recorded because the pattern is the finding
- **Found while running the new §6 battery**, in order:
  1. `expect_in <label> <needle> <haystack>` where every sibling image uses
     `<label> <haystack> <needle>`. The first assertion failed and the code was
     correct.
  2. Asserting `source=mounted` for `work_mem` — a key all three layers set, so
     the summary correctly collapses it to the env row. The assertion demanded
     the summary contradict wave 3's F3 fix.
  3. Counting `work_mem = ` rows with a substring match, which
     `maintenance_work_mem` also satisfies. Reported "2 rows for one key".
- **Because:** all three are the same mistake — asserting against a
  remembered shape of the output rather than the measured one.
- **Class:** ordinary defects, in tests rather than code. Worth one entry because
  three consecutive red runs were all the test's fault, and the temptation each
  time was to change the code.

## Facts measured this wave

| What | Result |
|---|---|
| The weekly rebuild's **first scheduled run** | Fired 05:27 UTC 2026-08-17 (run 31997975960), success, after the 04:49 cleanup — the offset D-011 describes, working. Wave 2's last carried item, discharged. |
| `postgres@sha256:9934cb32…`, RFC 0004 §6's equivalence reference | **Deleted** by that morning's cleanup (`manifest unknown`), ~3 hours before wave 4 merged. D-029 predicted it; the window closed first. |
| Effective server state, pre-retrofit vs retrofit | All 414 `pg_settings` rows identical, with two `PG_CONF__` overrides applied. |
| `99-overrides.conf`, pre-retrofit vs retrofit | Identical, generated-at header excluded. |
| Refusal paths, pre-retrofit vs retrofit | Denylist, allowlist-miss, and denylist-under-`ignore` all still exit 1. Message wording differs. |

**The deletion has a better answer than the one D-029 proposed.** It asked for a
registry write to tag the digest. The tag policy already solved this: a **dated
tag is immutable and is never repointed**, so `postgres:18.6-20260817-31997975960.1`
cannot become untagged and cannot be collected. `9934cb32` had no dated tag
because it predates the policy. This wave's equivalence check used the dated
tag's digest and needed no registry write — which is the shape RFC 0004 §6
should ask for.

## Findings against earlier units — wave 5

| # | Where | Finding | Class | Status |
|---|---|---|---|---|
| W-1 | `rfcs/0001` status block | Said "**P3 and P4 not started**" and "until P4, the contract is implemented twice" after wave 4 had shipped P3. Wave 4 wrote decision rows 20–22 from `caddy`'s execution and left the status field describing the state before it. A reader checking whether the summary exists would have been told it does not. | `drift` | Fixed, and the lag is recorded in the block itself rather than quietly overwritten |
| W-2 | `images/README.md` §Startup summary | The normative example showed `source=env  <redacted>  (PG_CONF__log_line_prefix)` — the key replaced by `<redacted>` rather than the value, and on a key that matches none of the redaction patterns. Both halves are wrong about behaviour that has shipped since wave 3, in the document images are told to link to instead of restating. | `drift` | Fixed, with `valkey`'s measured line as the example |

W-1 and W-2 are the same shape as wave 1's R-4 and are why that entry is worth
re-reading: **prose that describes the state of the work goes stale one wave
later, and the wave that stales it is never the wave that notices.** Neither is
counted in this wave's drift count — they are findings against waves 1–4 — but
both would have been caught by a pass over "every claim about what is shipped"
at the end of any of them.

## Rules distilled

- A config-format parser has to be written against the *server's* grammar, not
  the shape the file happens to have. `=` optional, `#` inside quotes literal,
  `''` an escaped quote — three rules, all of which a naive `key = value` split
  gets wrong, and none of which the RFC mentioned (D-033).
- When a runtime cannot tell two layers apart, have the **build** write down what
  it knows. A filename convention is a guess evaluated at the wrong time
  (D-034).
- An alias is two live names whether or not the document admits it. Translating
  a published name onto a contract name makes both work, so both need
  documenting and a conflicting pair needs refusing (D-035).
- `$( )` strips trailing newlines, so any NUL-delimited stream read through
  command substitution loses a trailing empty field. The second time this
  pattern has produced a defect in this repo (D-037, after A-10).
- **Three consecutive red runs were the test's fault, not the code's.** When an
  assertion fails, check what the code actually printed before changing it:
  each of the three was written against a remembered output shape (D-038).
- A `chown -R` over a directory an operator can mount into is a startup failure
  waiting for its first read-only mount. Take ownership of what the image
  created, warn about the rest (D-036).
- The durable reference to an image is a **dated tag**, not a digest. Untagged
  digests are what garbage collection is for, so a bare digest is a reference
  with a deletion date nobody wrote down (this wave's facts table).

## Carried into the next unit

- **RFC 0004 P2** — the first real variant, and the question of which extension
  has a consumer (pgvector or pgmq) is the author's. It still carries wave 1's
  R-7: a `POSTGRES_EXTENSIONS` override publishes onto the default tags.
- **RFC 0004 §6's equivalence reference is gone** and the check is now only the
  log entry that recorded it. Row 15 says so, and says a dated tag is what a
  future reference should name.
- **`keyvalue` renderer** still ships with RFC 0005 (D-019). `pgconf` and
  `valkeyconf` both exist now, so the next renderer has two shapes to follow.
- **`caddy`'s aliases have no sunset date**, recorded deliberately at this
  wave's gate: nine table rows and one warning line is cheaper than breaking
  working compose files. Revisit only if the table stops being nine rows.
- ~~RFC 0001 P3, P4~~ — shipped; **RFC 0001 is complete**.
- ~~The weekly rebuild has never run on a schedule~~ — it has, successfully.
- ~~`postgres@sha256:9934cb32…` will be deleted unless tagged~~ — it was.

## Reconciliation — 2026-08-17 (wave 5)

| RFC | Row | Outcome | Grade | Decision | From |
|---|---|---|---|---|---|
| 0001 | 23 | **Proposed** | `ASSUMED` | How an image attributes a config-file layer and an include directory | D-034 |
| 0001 | 24 | **Proposed** | `ASSUMED` | A published control alias and the contract name both work; a conflict refuses | D-035 |
| 0004 | 15 | **Amended** | `ASSUMED` | The reference was deleted; a dated tag is the durable form | D-029, this wave |
| 0002 | §6 | **Amended** | — | "Zero deletions" narrowed to "of what the gate published" | D-029 |
| 0001 | — | **Status corrected** | — | P3 and P4 marked shipped; RFC 0001 closed as complete | W-1 |

Wave 4's sixteen rows were ratified by merging PR #31; none was struck, so no
refusal is recorded against them. D-033, D-036, D-037 and D-038 propose no row:
the first is a shape decision 19 delegates outright, and the other three are
defects rather than decisions.

**Two amendments here are corrections to rows this practice itself produced**
(0004 row 15, 0002 §6), which is the reconciliation half doing what it is for —
a row written from a prediction gets corrected by the measurement, in the same
table, instead of standing as a claim nobody rechecked.

## Self-audit findings — wave 5, 2026-08-17

Scope: the whole branch, 5 commits, 15 files, +879/−140 — source, tests, docs,
the RFCs it amends, and the bake config.

| # | Where | Finding | Class | Status |
|---|---|---|---|---|
| A-21 | RFC 0001 decisions 1 and 4 | **Two `LOCKED` rows contradict each other, and P4 shipped without recording it.** Decision 4 says `<NAME>_FILE` takes precedence over `<NAME>` "for every secret" and calls it "retroactive for `postgres`"; decision 1 says upstream-owned names are never intercepted, and `POSTGRES_PASSWORD` is upstream's. Measured: `postgres` with both set exits 1 (`both … are set (but are exclusive)`), while `valkey` — an image-curated secret — takes the file and answers `PONG` to it. So the rule holds where the image owns the name and cannot hold where upstream does. | `drift` | **Open — needs the author.** Narrowing decision 4 is a `LOCKED` edit, so the executor does not make it |
| A-22 | `images/postgres/smoke.sh` | Six §6 and decision-table properties were implemented and asserted by nothing: `!secret` redaction, a tab surviving into effective config, decision 9's warning on a guessed name, decision 9's silence on upstream's `PG_MAJOR`/`PG_VERSION`, decision 8's stderr-only summary, and the denylist outranking an operator-supplied allowlist. All six pass; **none was proven before this pass.** | — | Fixed |
| A-23 | `images/postgres/rootfs/entrypoint.sh` | The header claimed "the published surface is unchanged". Three things did change: the summary is new, refusal wording comes from the helper, and a read-only fragment no longer aborts. The claim a reader needs is "nothing that worked before stops working", which is true and is now what it says. | — | Fixed |
| A-24 | `images/postgres/rootfs/entrypoint.sh` | `tmp_overrides` was outside the cleanup trap, so an aborted render left a temp file in the container. | — | Fixed |
| A-25 | `images/postgres/rootfs/entrypoint.sh` | The unknown-name warning printed *after* the summary; `caddy` and `valkey` both print it before. Same information, worse placement — the comparison an operator makes is between "you set this" and "here is what I used". | — | Fixed |
| A-26 | §6's channel-collision case | Not applicable to `postgres`: it has no curated channel, so no curated name can collide with a passthrough key. Recorded because an unexplained gap in a test list reads as an omission. The nearest real case — two spellings of one *control* variable — is asserted instead (D-035). | — | Recorded |

**A-21 is the one that matters, and pass 10 is what found it.** Every other
finding here came from probing behaviour or reading prose; this one came from
walking the decision table row by row and asking what the code does about each.
Nothing in the diff looks wrong, because the departure is an absence — `postgres`
implements upstream's rule by not implementing the contract's, and that leaves no
trace to notice.

**A-22 is the pattern this practice keeps producing.** Six properties, all
working, none tested. They were "verified" by having been read. The measurement
that proved them took one container each.

- **Proposed row (RFC 0001, decision 4):** the `_FILE` rule binds only for
  secrets the **image** names. For an upstream-owned name, upstream's own
  handling stands, and the image's README states what that is — for `postgres`,
  setting both spellings is refused rather than resolved.

### Sabotages run

| Sabotage | Result |
|---|---|
| `pgconf` quoting: drop the `''` doubling | `FAIL   ...doubled, not escaped` |
| Parser: strip `#` inside quotes too | `FAIL   ...hash inside quotes kept` |
| Parser: require an `=` separator | `FAIL   ...no equals sign needed` |
| Parser: stop lowering keys | `FAIL   ...key lowered` |
| Entrypoint: ignore the fragment manifest | `FAIL: image fragment reads as baked` |
| Entrypoint: stop refusing a control collision | `FAIL: both spellings of the strict control started and kept running` |

The last one also re-exercised wave 4's `--kill-after` work: a refusal that stops
refusing is caught by the timeout path rather than hanging the run.

### Residue — what I would still distrust

- **A whole-directory mount over `conf.d`** replaces the image's own fragments,
  including `10-extensions.conf` with the generated preload line. The summary
  degrades honestly (the manifest becomes unreadable, so everything reads
  `mounted`) but the *server* loses its preload configuration. Pre-existing, out
  of this wave's scope, and untested either way.
- **Decision 8's stderr routing is now asserted for `postgres` only.** `caddy` and
  `valkey` print to stderr and nothing proves it; the assertion is three lines
  and belongs in both.
- **The equivalence check is one-shot.** It compared this build against a digest
  pulled today, and the result lives in this log rather than in CI. A future
  change to the renderer will not re-run it.
- **`refuse` is duplicated** between `caddy`'s and `postgres`'s smoke scripts,
  ~20 near-identical lines. Left alone deliberately: extracting it couples two
  per-image tests through a shared file, and the two copies already differ in
  timeout and container name. Recorded rather than done silently.

## W-3 — `ALTER SYSTEM` is a fourth configuration layer, and no RFC mentions it

- **Touches:** RFC 0001 decision 3 (`LOCKED`), decision 13 (`LOCKED`)
- **RFC said:** precedence is baked default → mounted config file → environment,
  "in every image, printed at startup"
- **Measured:** there is a fourth layer above all three.
  `ALTER SYSTEM SET work_mem = '7MB'` writes `${PGDATA}/postgresql.auto.conf`,
  which Postgres reads **after** `postgresql.conf` and everything its
  `include_dir` pulled in. With `PG_CONF__work_mem=64MB` also set, the effective
  value after a restart is 7MB — and the summary went on printing
  `source=env  work_mem = 64MB`, a value the server had stopped using.
- **Built:** the file is scanned last and attributed `source=sql` with an
  `(ALTER SYSTEM)` origin; `postgres`'s footer reads
  `precedence: baked < mounted < env < ALTER SYSTEM`.
- **Class:** `spec-gap`. The design names three layers because nobody looked for
  a fourth; the summary defect is the consequence rather than the finding.
- **Not built, and proposed instead:** `-c allow_alter_system=off` at startup
  would close the route, and cannot be overridden by any config file because
  command-line options outrank them. It also removes something this image has
  always permitted, which is a **policy change to a published image** rather than
  part of moving it onto the shared helper. Cited from
  `rootfs/denylist.conf` and the entrypoint so a reader meets the proposal where
  the switch is discussed.
- **Proposed row (RFC 0001):** decision 3 enumerates the layers an image must
  print, and an image whose server can write its own configuration reports that
  file as a layer of its own. Whether to disable `ALTER SYSTEM` in `postgres` is
  a separate question for RFC 0004's image policy.

## Review findings — PR #32, 2026-08-17

| # | Where | Finding | Class | Status |
|---|---|---|---|---|
| R-18 | `smoke.sh` | Claimed the new stderr assertion could not work because `engine logs` returns a combined stream. It does not: container stdout goes to the command's stdout and stderr to its stderr. Measured `0` summary lines on stdout and all 43 on stderr, and the assertion passes in CI. | — | **Refuted** |
| R-19 | `rootfs/denylist.conf` | The comment on `shared_preload_libraries` read as though *the denylist file* were generated from `PG_EXTENSIONS`. The **setting** is, into `conf.d/10-extensions.conf`; the file ships as written for every variant. | — | Fixed |
| R-20 | `README.md` | Said every non-control `PG_*` variable warns, while `PG_MAJOR` and `PG_VERSION` are deliberately silent. The exclusion and its reason are now stated. | — | Fixed |
| R-21 | `rootfs/entrypoint.sh` | **`mktemp` with no template writes to `/tmp`**, so `mv` into `conf.d` is a rename only while they share a filesystem — measured `--tmpfs /tmp` giving device ids 1048775 vs 1048655, where `mv` becomes copy-then-unlink and an interruption leaves the truncated `99-overrides.conf` the comment claimed the pattern prevented. Template moved into `CONF_D`, dot-prefixed so a leftover is invisible to both `include_dir` and the attribution loop. | — | Fixed |
| R-22 | `rfcs/0001`, `rfcs/INDEX.md` | Marked RFC 0001 complete while decision 4 is known to conflict with decision 1 (A-21). The status now reads "Complete (one decision under review)" and names the conflict; the index carries the same qualification. Narrowing decision 4 is still not done here — it is a `LOCKED` row. | — | Fixed |
| R-23 | `rootfs/entrypoint.sh`, `build-extensions.sh` | **A bind mount can replace an image fragment at its own path**, and matching on the basename reported the operator's own value back as `source=baked`. Decision 13 (`LOCKED`) exists to answer "which layer won"; this answered it wrongly. The build now records a sha256 per fragment and content that differs reads as `mounted`. | `drift` | Fixed |
| R-24 | `rootfs/entrypoint.sh` | The `ALTER SYSTEM` layer, reported and proposed — see W-3. | `spec-gap` | Fixed (report); policy proposed |

**Drift count for the wave is now 2** — D-036 and R-23. Both are the same shape:
a `LOCKED` row describing what the summary must tell an operator, and an
implementation telling them something else. Neither was reachable by reading the
code; both needed a container and a mount.

**R-23 and R-24 arrived with no inline thread.** They were "outside diff range"
comments in a review body, which is the surface a review loop drops silently —
they were answered in a reply naming the commit, and are filed here because a
finding whose only record is a PR comment is a finding nobody will count.

**Two process facts worth keeping**, both about trusting a green:

- **CodeRabbit's check reported `success` twice while it had not reviewed.** The
  first time it was rate-limited (`Review limit reached … we couldn't start this
  review`) and the check was green anyway; the review only happened after the
  window reset and an explicit request. A reviewer's check status is not evidence
  that a review occurred.
- **The `--since` timestamp for round 2 was computed with `sed 's/+.*/Z/'`**,
  which strips a `+03:00` offset instead of converting it — three hours into the
  future, so the sweep returned nothing and looked like convergence. The same
  expression was used on PR #31, which is already merged: its "round 2 empty"
  rests on zero unresolved threads and a possibly-false-green check, not on a
  correct sweep.

---

# Wave 6 · Postgres extension variants

Branch `feat/wave-6-postgres-variants`. RFC 0004 P2 and P3.

**Drift count: 1** — D-040, introduced and caught inside this wave.

Three tags where there was one: `postgres:18.6` unchanged, `:18.6-pgvector`, and
`:18.6-cron`. Decision 7's ceiling of three including the default is now reached
exactly.

## D-039 — pgvector's availability, measured twice because the first answer was an artefact

- **Touches:** RFC 0004 §10 questions 1 and 2, decision 5
- **Measured (wrong):** `apt-cache policy postgresql-18-pgvector` inside the
  built image reported `<not found>`, and only three `postgresql-18-*` packages
  existed at all.
- **Why it was wrong:** every apt index in that container had failed to fetch — a
  host proxy on `127.0.0.1:7890` is unreachable from a container — so `apt-cache`
  answered from the stale lists baked into the image. Suppressing `apt-get
  update`'s output with `-qq` is what hid it. Three packages from a repository
  that carries hundreds was the tell.
- **Measured (right), from the host against the PGDG index:**
  `postgresql-18-pgvector` **0.8.6-1.pgdg13+1** exists, for majors 12–19. **pgmq
  exists for no major.**
- **Class:** `discovery`, and the entry is here because the near-miss is the
  finding: it was one commit away from being written into an RFC as "pgvector
  needs a source build", which would have justified a new manifest column and a
  build stage nobody needed.
- **Rule:** a measurement whose failure mode looks like a result has to be
  checked for having run at all. `<not found>` and "could not look" are the same
  string.

## D-040 — The extensions label moves into the Dockerfile

- **Touches:** RFC 0004 decision 10 (`LOCKED`), decision 1 (`LOCKED`), §5.3
- **RFC said:** §5.3's sketch sets `io.morze.postgres.extensions` in
  `docker-bake.hcl`, beside the tags
- **Built first, in this wave:** the label and the install list as two separate
  literals per target, replacing the single `POSTGRES_EXTENSIONS` variable that
  had fed both
- **Found:** `--set postgres.args.PG_EXTENSIONS=pgroonga` produced an image
  containing pgroonga alone that went on claiming `cron pgroonga`. Decision 10 is
  `LOCKED` on the label **being** the canonicalized selection, and wave 1's
  canonical-order refusal cannot catch this because the build never sees the
  label.
- **Built now:** `LABEL io.morze.postgres.extensions="${PG_EXTENSIONS}"` in the
  Dockerfile; bake writes only the OCI label set. One string, read where the
  install reads it, and the canonical-order refusal makes it the canonical
  spelling.
- **Class:** `drift`, against a `LOCKED` row, introduced by this wave's own first
  attempt. Splitting one variable into two literals looked like a simplification
  and was a way for contents and label to disagree.
- **This is decision 1 generalised.** That row says the preload line is generated
  from the same input that drives the install and never hand-written. The label
  has the same property and the same failure mode, and §5.3 put it somewhere the
  input cannot reach.
- **Proposed row (RFC 0004):** row 16.

## D-041 — No `POSTGRES_EXTENSIONS` variable; sets are literal per target

- **Touches:** wave 1's R-7, RFC 0004 §5.3
- **RFC said:** §5.3's sketch hardcodes `PG_EXTENSIONS` per target and declares no
  variable. Wave 1 introduced one.
- **Built:** the sketch's shape — literal per target, no variable.
- **Because:** bake reads HCL variables from the environment, so anything that
  exported `POSTGRES_EXTENSIONS` changed what `postgres:18.6` contained while its
  tags stayed put. That is R-7's remaining bite after wave 2's D-012 closed the
  local-publish route.
- **Class:** `drift` against wave 1, fixed here. Not counted in this wave's drift
  number, which counts what this wave introduced.
- **Proposed row (RFC 0004):** row 17.

## D-042 — CI resolves a smoke script from the target's context, and §6's build tests get their own harness

- **Touches:** RFC 0002 §5.5, decision 20; RFC 0004 §6
- **Found:** the two workflows disagreed about what "smoke every image" means.
  `bake.yaml` iterated `images/*/smoke.sh` — one per directory — while
  `publish.yaml` iterated targets and required `images/<target>/smoke.sh`. A
  variant is a target sharing the base image's directory, so it would have been
  **built and never smoked** in CI, then refused at publish.
- **Built:** both workflows resolve `<context>/smoke.sh` from `bake --print`. A
  target's context already is its image directory and a variant inherits it, so
  there is no naming convention and nothing new to forget; a target whose context
  has no script is still refused, which is the property decision 20 wants.
- **Also built:** `images/postgres/test-extensions.sh`, because three of §6's
  tests cannot run against a built image. Two assert that a bad `PG_EXTENSIONS`
  **fails the build**; the third needs an image without `cron`, and no shipped
  variant is one. §6 calls that third test the one that must never be skipped,
  and until this wave it had never run.
- **Class:** `spec-gap`. §6 listed tests that P1 could not run and P2 makes
  runnable; §5.5 described a per-image smoke stage before targets could
  outnumber directories.
- **Departure from this wave's own plan gate:** the answer chosen was a declared
  label (`io.morze.smoke`). The context field carries the same information, is
  already correct for all eight targets, needs no new field per target and adds
  no ninth image label. Same source of truth, one less thing to forget — flagged
  here rather than silently substituted.
- **Proposed row (RFC 0004):** row 18.

## Facts measured this wave

| What | Result |
|---|---|
| `postgresql-18-pgvector` in PGDG `trixie-pgdg` | 0.8.6-1.pgdg13+1, majors 12–19 |
| pgmq in PGDG, any major | absent |
| pgvector end to end | `CREATE EXTENSION vector`, `vector(3)` column, `<->` nearest-neighbour query returns the right row, `extversion` 0.8.6 |
| `postgres:18.6-cron` | `absent as expected: pgroonga` **and** `absent as expected: vector` — wave 1's R-8 negative direction with something real to catch |
| An image built without `cron` | starts; preload line is `pg_stat_statements` alone; no `cron.*` setting anywhere under `/etc/postgresql/` |
| All three shipped labels | `cron pgroonga`, `cron pgroonga pgvector`, `cron` |

## Rules distilled

- A measurement that can fail silently must be checked for having run. An apt
  cache with no network answers from stale lists, and `<not found>` is what both
  "absent" and "could not look" print (D-039).
- Two literals that must agree will disagree. If one of them is derivable from
  the other, derive it — and derive it where the authority is, not where it is
  convenient to write (D-040).
- A bake variable is an environment variable. Anything settable from outside the
  file can change what a tag contains without changing the tag (D-041).
- When a test list names a test that cannot run against the artefact under test,
  that is not a gap in the tests — it is a missing harness (D-042).
- Iterating directories to test targets works until a target does not own a
  directory. Ask what the loop is actually enumerating (D-042).

## Carried into the next unit

- **`keyvalue` renderer** still ships with RFC 0005 (D-019). `pgconf` and
  `valkeyconf` both exist, so a third has two shapes to follow.
- **RFC 0004 has no P4**; with P2 and P3 shipped the RFC is complete except for
  the decision-7 ceiling being a standing constraint rather than a task.
- **Two author decisions are still open**, both carried from wave 5: narrowing
  RFC 0001 decision 4 to image-owned secrets (A-21), and whether `postgres`
  should ship `-c allow_alter_system=off` (W-3).
- ~~RFC 0004 P2, P3~~ — shipped.
- ~~R-7~~ — closed, by removing the variable (D-041).
- ~~§10 questions 1 and 2~~ — answered by measurement (D-039).

## Reconciliation — 2026-08-17 (wave 6)

| RFC | Row | Outcome | Grade | Decision | From |
|---|---|---|---|---|---|
| 0004 | 16 | **Proposed** | `ASSUMED` | The extensions label is written by the Dockerfile from the build arg | D-040 |
| 0004 | 17 | **Proposed** | `ASSUMED` | Extension sets are literal per target; no bake variable | D-041 |
| 0004 | 18 | **Proposed** | `ASSUMED` | CI resolves a smoke script from the target's context; §6's build tests get a harness | D-042 |
| 0004 | §10 | **Answered** | — | pgvector packaged for 18; pgmq packaged for nothing | D-039 |
| 0004 | status | **Corrected twice** | — | `Draft` → `In progress` (five days late) → **`Complete`**: §12 has three phases and all shipped. The intermediate step was itself wrong, caught by PR #33's review (R-26). Scope's "no specific extension" reconciled against decision 7 | this wave, R-26 |

Wave 5's rows 23 and 24 (RFC 0001) were ratified by merging PR #32. The two
`LOCKED`-row questions it raised are still open and are the author's.

## Self-audit findings — wave 6, 2026-08-17

Scope: the whole branch, 2 commits, 11 files, +458/−44 — the manifest row, the
bake targets, both workflows, the new build-mechanism harness, and the docs.

| # | Where | Finding | Class | Status |
|---|---|---|---|---|
| A-27 | `test-extensions.sh` | `cleanup()` reads `${TEST_TAG}`, and `trap cleanup EXIT` is installed **before** that variable is assigned. A failure in between would make cleanup itself die on an unbound variable under `set -u`, taking the `rm -rf "${WORK}"` after it. An advisory cleanup outranking the outcome it trails. | — | Fixed (`${TEST_TAG:-}`) |
| A-28 | `bake.yaml`, `publish.yaml` | The context→script resolution had only ever run on the happy path: all eight targets resolve, so nothing exercised the refusal. Tested against a doctored plan whose target names a nonexistent context — it refuses by name and the loop exits 1. | — | Verified |
| A-29 | RFC 0004 §8's empty set | `PG_EXTENSIONS=""` is where wave 1's A-1 defect lived, and nothing had exercised it since that fix. Measured: builds, starts, preload is `pg_stat_statements` alone, label is empty, and `conf.d` holds only the unconditional fragments. **Deliberately not automated** — it is a full build for a case with no shipped tag, and the harness already pays for one. Recorded so the omission is visible rather than assumed. | — | Verified, not automated |
| A-30 | decisions 3 and 6 | Both verified by measurement rather than read: every variant carries `POSTGRES_IMAGE_TAG=18.6`, so `inherits` merged args per key (D-006 warned this fails as a build against the wrong major, not as an error); `PACKAGES` still lists `postgres` once, so variants cost no new GHCR package. | — | Conformant |

**The wave's real finding is D-040 and it was found by the harness, not by this
pass.** Writing the tests §6 had asked for since wave 1 exposed a defect this
wave had just introduced, within minutes of the harness existing. The audit's own
findings here are smaller: a cleanup path that could outrank its outcome, and a
refusal branch that had never fired.

### Verified

| Check | Result |
|---|---|
| Helper suite | 139 passed / 0 failed (bash), 136 / 0 (busybox ash) |
| `postgres`, `:18.6-pgvector`, `:18.6-cron` smoke | all exit 0; labels `cron pgroonga`, `cron pgroonga pgvector`, `cron` |
| Extension mechanism harness | 6 assertions, PASS |
| Tag shapes with `BUILD_STAMP` set | `18.6-pgvector` and `18.6-pgvector-<stamp>`; the mutable tag is a strict prefix of the immutable one for every variant |
| Label set per image | 9 — the eight OCI labels plus the extensions label; the Dockerfile `LABEL` merges with bake's rather than displacing them |

### Residue — what I would still distrust

- **pgvector is unpinned, like every other extension package (decision 8), and it
  is the first extension where that matters differently.** A weekly `--no-cache`
  rebuild can move pgvector across a minor release, and vector index formats are
  not guaranteed stable across those; a stateful database may need a `REINDEX`
  that nothing here would announce. Decision 8 accepted unpinned packages when
  the set was cron and pgroonga, where the equivalent risk is much lower. **This
  is the author's call** and is carried, not fixed.
- **CI now runs three extra builds** for the harness — two are `type=cacheonly`
  and cheap, the third is a full build. If the job gets slow, the full one is what
  to gate on paths.
- **`test-extensions.sh` does not follow `smoke.sh`'s assertion helpers**
  (`expect_in`/`expect_not_in`); it uses `fail` plus `case`. Both are bash under
  `set -euo pipefail`, and the harness is testing builds rather than a running
  image, so the shapes differ for a reason — but a reader moving between the two
  files will notice.
- **No variant omits `cron`,** so the §6 trap test depends entirely on the
  harness's throwaway build. If that step is ever skipped, the test §6 calls
  unskippable is skipped with it.

## Review findings — PR #33, 2026-08-17

| # | Where | Finding | Class | Status |
|---|---|---|---|---|
| R-25 | `docker-bake.hcl` `DESCRIPTIONS` | **The OCI description contradicted two of the three images.** All three carried `PostgreSQL with pg_cron and pgroonga…`: `:18.6-pgvector` omitted the extension it exists for, and `:18.6-cron` advertised pgroonga it does not have. This is D-040 again one label along — the extensions label was fixed in this wave and the description beside it was left saying the same wrong thing. The self-audit missed it too. | `drift` | Fixed |
| R-26 | `rfcs/0004`, `rfcs/INDEX.md` | Status read **In progress** with all three of §12's phases shipped. Correcting a stale `Draft` earlier in this wave and stopping one notch short is the same failure the field keeps having (W-1, and this wave's own status entry). Now ✅ Complete in both places. | — | Fixed |
| R-27 | `rfcs/0004` §5.1, §5.3 | Two design passages overtaken by what shipped: §5.1 used pgvector as its example of a row that must **not** exist, "whose packaging §10 records as unverified" — §10 now records it verified — and §5.3's snippets still write the extensions label in `docker-bake.hcl`, which row 16 moved to the Dockerfile. Both carry amendment notes rather than being rewritten. | `spec-gap` | Fixed |

**R-25 makes the wave's drift count 2** — D-040 and R-25, the same defect class
twice: metadata written by hand beside metadata generated from the build input.

**The fix deliberately does not give each variant its own description.** Three
hand-written descriptions that must agree with three `PG_EXTENSIONS` values is
this wave's own distilled rule broken three times over. The description no longer
names extensions at all; it points at the label, which is generated. One place
names the set.

**Round 1 was collected through GraphQL, because REST was returning 500.**
`GET /repos/…/pulls/33/reviews` answered `HTTP 500` with `Content-Length: 0` for
every page size, while `pulls/33/comments`, `issues/33/comments` and
`pulls/33` were all `200` and GitHub's status page reported all systems normal.
An earlier `401 Bad credentials` on the same endpoint was the same instability,
not an auth failure — `gh auth status` and `/rate_limit` were healthy throughout.
The loop's own tooling reads that surface over REST, so without the GraphQL
detour this round would have looked empty, which is the failure mode wave 5's
`--since` bug already demonstrated once.

# Wave 7 · Closing the record

Branch `docs/wave-7-rfc-close-out`. RFC 0002 §6's verification against GHCR,
RFC 0006's close-out, and RFC 0009's evidence and open decisions. No image
changed; the only executable change is one `smoke.sh` section.

**Drift count: 4** — A-31, A-32, A-33 and A-35, all introduced by this wave and
all caught by its own audit or the PR that followed it. D-044 is `drift` against
wave 3, found here, and is not counted in this wave's number.

This number was written as **0** when the group was drafted, then **3** after the
audit, and is corrected in place each time rather than rewritten — a drift count
written before the audit is a prediction, and this one was wrong twice. The four
are one failure repeated: a claim that overshoots the measurement or the fix
behind it.

The wave exists because three RFCs were finished, or wrong, in ways nobody had
checked. Two of them turned out to be finished.

## D-043 — RFC 0002 §6 verified against GHCR, on every target

- **Touches:** RFC 0002 §6, decision 2 (`LOCKED`), status
- **RFC said:** attestations on published images "remain unverified"; every
  earlier measurement (D-008, D-010) ran against a throwaway local registry, and
  §6 says only a real publishing run can settle it
- **Measured, against real published digests:** `ghcr.io/morzecrew/postgres:18.6`
  carries an `attestation-manifest` child whose layers are
  `https://spdx.dev/Document` and `https://slsa.dev/provenance/v1`. The
  provenance contains `buildConfig` and `llbDefinition` — the fields `mode=min`
  omits — so it is `mode=max`, which is what decision 2 requires. Nine labels,
  `.revision` = `2c0f21e`, the commit whose publish produced it. `:18.6` and
  `:18.6-20260817-32061042936.1` resolve to one digest while the three earlier
  dated tags kept their own and lost `:18.6`. A local `bake --print` yields one
  tag and no dated alias.
- **Checked on all three postgres targets, not one**, because decision 2 says
  *every* target and the two RFC 0004 variants had never been published before
  this run. Both carry attestation manifests.
- **Class:** `discovery` — the RFC was right that only a real publish could
  answer it, and right to refuse to claim it until one had.
- **Consequence:** RFC 0002 has nothing left that this repository controls, so
  its status moves to ✅ Complete. Signing stays out of scope by decision 4.
- **Proposed row (RFC 0002):** none. §6 gains a verification table; the decision
  table is unchanged, because nothing was decided — a claim was checked.

## D-044 — RFC 0006 sat at 🚧 for five days with every phase shipped

- **Touches:** RFC 0006 §12, status; `rfcs/INDEX.md`
- **RFC said:** status 🚧 In progress
- **Found:** §12 lists exactly P1, P2 and P3, and the status block's own first
  sentence says all three shipped on 2026-08-16. The document contradicted itself
  in consecutive lines for five days.
- **Class:** `drift`, against wave 3, which shipped the phases and did not move
  the status. Not counted in wave 7's drift number.
- **This is the fourth instance of one failure.** W-1 (RFC 0001), R-26 (RFC 0004,
  caught in review, where I had already corrected `Draft` → `In progress` and
  stopped one notch short), wave 6's own status entry, and now this. The pattern
  is that the executor updates the status to describe *the work they just did*
  rather than re-reading the phase list to ask whether anything remains.
- **Built:** status ✅ Complete **with the completion criterion written into the
  status block** — every §12 phase shipped and §10 answered or struck — so the
  next reader checks a stated condition rather than re-deriving one. Same
  treatment R-26 forced on RFC 0004.
- **Proposed row (RFC 0006):** none; this is a status correction, recorded in the
  reconciliation table below.

## D-045 — Valkey's runtime mutation channel exists, and the restart erases it

- **Touches:** RFC 0006 §10 question 4; RFC 0001 decision 5 (the summary)
- **RFC asked:** whether a runtime `CONFIG SET` can drift from the generated conf
  and whether that matters for restart semantics, assuming the drift "survives
  until restart and then silently reverts"
- **Measured:** the assumption was right about `CONFIG SET` and missed a case.
  `CONFIG SET maxmemory 7mb` changes the running server and leaves the generated
  file alone. **`CONFIG REWRITE` writes the drift into `/etc/valkey/valkey.conf`**
  — a persistence channel the question did not anticipate. It still does not
  survive a restart, because §9 of the entrypoint regenerates that file from the
  environment unconditionally: 100mb → `CONFIG SET` + `CONFIG REWRITE` → 7mb on
  disk → restart → 100mb on disk and in the server.
- **Class:** `discovery`. Reading the entrypoint would have shown the
  regeneration; only running it showed that `CONFIG REWRITE` reaches the file at
  all, which is what makes the regeneration load-bearing rather than incidental.
- **The finding is the contrast with `postgres`.** `ALTER SYSTEM` writes
  `postgresql.auto.conf` into `PGDATA` — a mounted volume the entrypoint must not
  overwrite, read *after* every layer the image generates. Valkey's equivalent
  writes into a path the entrypoint owns. **Neither RFC decided this**; it falls
  out of where the file lives. So `valkey` already holds the property the open
  `allow_alter_system` question (W-3) is trying to buy for `postgres`, and holds
  it for free.
- **Built:** `smoke.sh` §18, which asserts the rewrite *reaches* the file before
  asserting the restart erases it — without the first assertion the section would
  pass against an image where `CONFIG REWRITE` quietly did nothing, which is the
  same test with none of the meaning. Verified red against an image whose
  regeneration was made conditional: it fails at the restart assertion and the
  preceding one still passes.
- **Proposed row (RFC 0006):** none. §10 question 4 is answered in place; no
  behaviour changed, so there is no decision to record.

## D-046 — Two of RFC 0009's measurements are wrong, both under decision 8

- **Touches:** RFC 0009 §2, §10 questions 1 and 2, decision 8 (`OPEN`)
- **RFC said:** `erp-frontend` runs `npm ci` "with a cache mount", and one of the
  three Caddy projects "already uses `ghcr.io/morzecrew/caddy:2.11`". Decision 8
  recommends it as the first migration *because* of both.
- **Measured, against the default branch of each of the five repositories:**
  neither holds. `erp-frontend` has no `--mount=type=cache` anywhere, and its
  runtime is `caddy:2.11.1-alpine` from Docker Hub. **None of the five consumes
  this repo's caddy image.** Cache mounts across all five: **zero**, not one.
- **Corrected during this wave's own audit (A-31):** the first version of this
  entry said *no Morze project* consumes this repo's caddy image, which is false
  and is a broader claim than the measurement supported. An org-wide code search
  finds `eis-backend` and `erp-backend` building `containers/gateway` from
  `ghcr.io/morzecrew/caddy:2.11.2`. The image is adopted as a reverse-proxy
  gateway and unadopted as a static-asset runtime.
- **Not drift in the projects:** `erp-frontend`'s `Dockerfile` is unchanged since
  2026-05-09, three months before the RFC measured it, so it was in this state
  when the claims were written.
- **Class:** `spec-gap`, filed against the design process rather than any
  execution — this is an RFC asserting measurements that were never taken, which
  is a different failure from an RFC being silent, and the one that is hardest to
  catch later because a stated measurement reads as settled.
- **Both errors point the same way, which is why nobody questioned them:** each
  made adoption look *further along* than it is. An RFC's own evidence drifting
  optimistic is the direction that does not provoke a re-check.
- **Consequence:** the conclusion survives and the reasoning does not.
  `erp-frontend` is still the right first migration — Vite emitting to `dist`,
  `npm ci`, Caddy already — and the migration is now worth more than the RFC
  credited it, since it introduces the first cache mount and the first consumer
  of this repo's caddy image at once.
- **§10 question 1 answered in passing:** both landings run a detect chain
  testing `yarn.lock`, then `package-lock.json`, then `pnpm-lock.yaml`. Neither
  has a `yarn.lock`, so `npm ci` wins every build and `pnpm-lock.yaml` is never
  read. The question "which do they intend" is unanswerable from outside; "which
  runs" is not, and it is what decision 4 needed.
- **Proposed rows (RFC 0009):** none from this entry; §2 and §10 carry amendment
  notes and the strike-throughs.

## D-047 — RFC 0009's open decisions closed, and three unlisted ones filled

- **Touches:** RFC 0009 decisions 7 and 8 (`OPEN`), §12 P1, §5.1
- **Author-ratified 2026-08-17.** The plan gate reported RFC 0009 **not ready**
  on three load-bearing gaps; these are the answers, and they are recorded here
  rather than embedded in code because none of them had been written down.
- **Decision 7 — `BUILD_OUTPUT_DIR` defaults to `dist`.** Measured split across
  the five: `dist` 2, `out` 2, `build` 1 — a plurality, so no default is right
  for most. Defaulted anyway, because a wrong default fails loudly at build time
  through §5.2's non-empty and `index.html` check, and requiring the variable
  buys explicitness against an error already caught. **Conditioned** on the
  failure message naming the variable, the path it looked at and what it found —
  a loud failure is only a signpost if it says which knob to turn.
- **Decision 8 — `erp-frontend`, and not in the same PR.** The repository, not
  the package name: the `erp-frontend` repo contains a package called
  `morze-crm-frontend` and a separate `morze-crm-frontend` repo also exists.
- **Decision 9 — one target, one bake variable, Node `22`.** `uv-builder`'s
  shape; `BUILDER_NODE_VERSION` feeds tag and arg together so contents cannot
  move without the tag (D-041's rule). `22` over `24` because starting two majors
  ahead of the fleet changes two things at once during adoption.
- **Decision 10 — the `packageManager` pin is not applicable to npm.** §5.1
  requires an "exact, integrity-checked `packageManager`", citing superseded
  RFC 0008. That is a Corepack mechanism; npm ships inside the Node image, so
  Corepack is never in the path, and honouring it literally would mean fetching
  npm over the network to overwrite the npm from a pinned base image — **lower**
  reproducibility, not higher. Retained in full for a future `pnpm-builder`,
  where it does bite. Base image Debian, mirroring `uv-builder`, keeping native
  modules on glibc.
- **Decision 11 (`LOCKED`) — §6's battery verifies P1; the migration is adoption
  evidence.** §12 required P1 to land "alongside one real migration", which lives
  in another repository and therefore cannot be in this repository's PR: the
  requirement was unsatisfiable as written, not merely inconvenient. It also
  conflated verification with adoption. §6 verifies the image and does it better
  than one migration would; a migration proves someone wants it, which is §9's
  risk and RFC 0003's retirement criterion.
- **Class:** `spec-gap` for decision 11 and for §5.1's mechanism; decisions 7 and
  8 are `OPEN` rows answered, which is the delegated path rather than a
  departure. Decisions 9 and 10 fill unlisted gaps, logged at the same weight per
  this skill's rule that an unlisted decision is not an open one.
- **Proposed rows (RFC 0009):** 7 and 8 resolved in place; 9, 10, 11 added.

## Facts measured this wave

| What | Result |
|---|---|
| `postgres:18.6` on GHCR | attestation manifest present; SPDX SBOM + SLSA provenance v1; provenance carries `buildConfig` and `llbDefinition`, so `mode=max` |
| `:18.6-pgvector`, `:18.6-cron` on GHCR | both attested — first publish of the wave 6 variants |
| Published label set | 9 labels; `.revision` = `2c0f21e`, matching the producing commit |
| Tag policy on GHCR | `:18.6` ≡ newest dated tag; three older dated tags retain their own digests |
| Local bake, no `BUILD_STAMP` | exactly one tag, no dated alias |
| Valkey `CONFIG SET` | changes the running server; generated conf untouched |
| Valkey `CONFIG REWRITE` | **does** rewrite the generated conf (100mb → 7mb) |
| Valkey restart | conf regenerated from the environment; 100mb restored on disk and in the server |
| `valkey/smoke.sh` | 29 assertions, PASS; §18 verified red against a sabotaged image |
| Cache mounts across the five JS projects | **zero** (RFC 0009 §2 said one) |
| Of the five JS projects, consumers of `ghcr.io/morzecrew/caddy` | **zero** (RFC 0009 §2 said one) |
| Org-wide consumers of `ghcr.io/morzecrew/caddy` | **two** — `eis-backend`, `erp-backend`, both `containers/gateway`, both `:2.11.2`. Found by the audit after the first draft of D-046 overstated the zero (A-31) |
| Package manager the two landings actually run | `npm ci`, by the detect chain's order |

## Rules distilled

- A status line is not a phase list. Before writing one, re-read the phases and
  ask what remains — not what was just finished. Four instances now: W-1, R-26,
  wave 6's own entry, D-044.
- Write the completion criterion into the status, not just the verdict. A stated
  condition can be checked by the next reader; a ✅ cannot (D-044).
- A test that asserts a thing was *undone* must first assert it was *done*, or it
  passes against an implementation where the mechanism never fired (D-045).
- Two images can differ on a safety property with neither RFC having decided it,
  because the property follows from where a file lives. Ask what the runtime can
  write and whether the entrypoint owns that path (D-045).
- A measurement stated in a design document is still a measurement, and it decays
  or was never taken. Re-measure the ones a decision rests on before executing
  against them (D-046).
- When a document's errors all point the same direction, that direction is the
  bias to look for — optimistic evidence about adoption does not provoke the
  re-check that pessimistic evidence does (D-046).
- A phase that requires a change in another repository cannot be gated on it.
  Separate what verifies the artefact from what proves anyone wants it (D-047).
- A requirement inherited from a superseded document may name a mechanism that no
  longer applies. Check the mechanism is in the path before honouring it (D-047).

## Carried into the next unit

- **RFC 0009 P1 is wave 8.** Decisions 7–11 are settled; §6's battery is the
  gate. The first migration (`erp-frontend`) is adoption evidence and needs a
  named date and an authorized cross-repo change — it is **not** this
  repository's PR (decision 11).
- **RFC 0009 §10 question 3 is still open** — whether `morze-landing` can leave
  Node 16. It gates P3 only. `react-scripts` 5.0.1 on webpack 5 suggests yes, but
  that is a read, not a measurement, and the repo is another project's.
- **`keyvalue` renderer** still ships with RFC 0005 (D-019), whose gate remains
  unmet and unscheduled.
- **Two author decisions still open**, carried since wave 5: narrowing RFC 0001
  decision 4 to image-owned secrets (A-21), and whether `postgres` ships
  `-c allow_alter_system=off` (W-3). **D-045 is new evidence for W-3**: `valkey`
  already has the property by construction, so the question is only ever about
  `postgres`, and only because `PGDATA` is a volume.
- **`morze-landing` bakes three EmailJS credentials into its Dockerfile** as
  literal `RUN` values, and RFC 0009 §5.3 warns that build args land in
  `mode=max` provenance. Not this repo's to fix and not in scope, but it is the
  exact shape §5.3 describes, and it is live today. Flagged for the author.
- ~~RFC 0002's unverified attestation claim~~ — verified (D-043).
- ~~RFC 0006 §10 questions 1 and 4~~ — answered (D-039, D-045).
- ~~RFC 0009 §10 questions 1 and 2~~ — answered (D-046).

## Reconciliation — 2026-08-17 (wave 7)

| RFC | Row | Outcome | Grade | Decision | From |
|---|---|---|---|---|---|
| 0002 | status | **Corrected** | — | 🚧 → ✅ Complete; §6 gains a verification table and the status states its completion criterion | D-043 |
| 0006 | status | **Corrected** | — | 🚧 → ✅ Complete, five days late; criterion stated in the status block | D-044 |
| 0006 | §10 q1 | **Answered** | — | pgmq is packaged for no major, so the comparison had no second term | D-039 via D-044 |
| 0006 | §10 q4 | **Answered** | — | `CONFIG REWRITE` persists to the conf; the restart regenerates it away | D-045 |
| 0009 | §2, §10 q1, q2 | **Corrected / answered** | — | zero of five have cache mounts; zero consume this repo's caddy; the landings run npm | D-046 |
| 0009 | 7 | **Resolved** | `ASSUMED` | `BUILD_OUTPUT_DIR` defaults to `dist`; the failure must name the variable and the path | D-047 |
| 0009 | 8 | **Resolved** | `ASSUMED` | `erp-frontend` (the repository) first, not in the same PR | D-047 |
| 0009 | 9 | **Added** | `ASSUMED` | One target, one bake variable, Node `22` | D-047 |
| 0009 | 10 | **Added** | `ASSUMED` | npm is pinned by the base image tag; the Corepack requirement is retained for a future `pnpm-builder` | D-047 |
| 0009 | 11 | **Added** | `LOCKED` | §6 verifies P1; the first migration is adoption evidence, tracked here | D-047 |
| 0009 | §12 P1 | **Amended** | — | The cross-repo migration no longer gates the phase | D-047 |

Wave 6's rows 16, 17 and 18 (RFC 0004) were ratified by merging PR #33.

## Self-audit findings — wave 7, 2026-08-17

Scope: the whole branch, 4 commits — one `smoke.sh` section and five documents.
The audit's centre of gravity is prose, because that is nearly all this wave
produced, and prose is the thing nothing else checks.

| # | Where | Finding | Class | Status |
|---|---|---|---|---|
| A-31 | D-046, RFC 0009 §2, facts table | **My own correction overstated its own measurement.** I wrote "**No Morze project** consumes this repo's caddy image" having measured five JS repositories. An org-wide code search finds two consumers — `eis-backend` and `erp-backend`, both `containers/gateway`, both `ghcr.io/morzecrew/caddy:2.11.2`. The image is adopted as a reverse-proxy gateway and unadopted as a static-asset runtime, which are different claims. Correcting a false claim with a broader false claim is the worst outcome available, and it happened inside the entry whose whole subject is unverified measurements. | `drift` | Fixed in three places |
| A-32 | RFC 0006 §10, status | I wrote a completion criterion — "every §12 phase shipped **and §10's questions answered or struck**" — and then flipped the status while questions 2 and 3 were neither. Question 3's answer existed only in the status block, which is the same "answered somewhere else" defect R-26 caught on RFC 0004. A criterion the document does not visibly satisfy is worse than no criterion, because it invites the reader to stop checking. | `drift` | Fixed — both struck with their evidence |
| A-33 | RFC 0009 §5.1, §4 | New decision 10 supersedes §5.1's `packageManager` requirement, and I left §5.1 stating it with no pointer — exactly the defect R-27 raised against RFC 0004 §5.3 one wave earlier. The same sweep found two more instances of D-046's corrected count still live in §5.1 and §4 ("the measurable win for four of five", "not one of five"). | `drift` | Fixed — amendment notes on all three |
| A-34 | `smoke.sh` §18 | A redundant `"${ENGINE}" rm -f "${CTR}"` immediately after §17's own, and immediately before a `start` that does it a third time. Harmless, and duplication I introduced. | — | Fixed |
| A-35 | This section's own residue | "**No CI covers any of this wave**" — contradicted by the rest of its own sentence, which correctly says `smoke.sh` §18 runs in CI. `bake.yaml`'s filter matches `images/**`. Found while opening the PR, after this table was written, and recorded rather than quietly fixed because it is A-31's shape a fourth time: an overstated headline over an accurate detail. | `drift` | Fixed |

**Three of the four findings are the same failure: a correction that stopped one
step short of the places it implicated.** A-31 corrected a claim and overshot,
A-32 stated a criterion without satisfying it, A-33 added a superseding row and
left the superseded prose unmarked. This wave's subject was other people's stale
documents, and it produced stale documents of its own at the same rate — which is
the argument for the audit being a separate pass rather than care taken while
writing.

### Verified

| Check | Result |
|---|---|
| `valkey/smoke.sh` | 29 assertions PASS against `ghcr.io/morzecrew/valkey:9.0`, re-run after the A-34 edit |
| `smoke.sh` §18 verified red | Against an image whose conf regeneration was made conditional: fails at the restart assertion, with the preceding "does reach the generated conf" assertion still passing. Red proof predates A-34's cleanup, which removed a `rm -f` that `start` performs anyway, leaving the assertion path unchanged |
| Cache-mount claim | Re-measured across all five repositories, not the four I had read: zero |
| Relative links in all five edited documents | All resolve |
| RFC 0002, RFC 0006 live `OPEN` rows | Zero in each — the oracle for the two ✅ flips |
| RFC 0009 decision table | 11 rows, all four-column; no `LOCKED` row contradicted by this wave |

### Residue — what I would still distrust

- **Decision 9 picks Node `22` without checking its LTS phase.** The row is
  deliberately argued on migration distance rather than support status, so it
  does not rest on a fact I did not verify — but §9 frames the release valve as
  "current LTS and previous", and if `24` is Active LTS while `22` is in
  maintenance, wave 8 is shipping a builder on a maintenance-phase major. Check
  against nodejs.org before the Dockerfile exists, not after.
- **"Two org-wide consumers" is a floor, not a count.** GitHub code search
  indexes default branches and can lag; it is evidence that "zero" was wrong,
  not proof that "two" is right.
- **RFC 0009 §10 question 3 is still a read rather than a measurement.**
  `react-scripts` 5.0.1 on webpack 5 suggests `morze-landing` can leave Node 16,
  but nothing was built to confirm it, and it is another project's repository.
- **No CI covers the documents**, which are most of this wave. `bake.yaml`'s path
  filter matches `images/**`, so `smoke.sh` §18 *is* built and run in CI; every
  RFC and the log itself are checked by review alone.

# Wave 8 · The npm builder

Branch `feat/wave-8-npm-builder`. RFC 0009 P1 — `npm-builder`, `build-js-app`,
and §6's battery. The first new image since wave 3.

**Drift count: 3** — A-36, A-38 and A-41, all introduced by this wave and all
caught by its own audit. A-42 is `drift` against the wave that added the
`python-distroless` annotation, found here, and is not counted in this wave's
number. D-048 is `drift` against wave 7, found here, and is not counted
in this wave's number.

Written as **0** when the group was drafted, before the audit ran. That is the
third consecutive wave whose pre-audit count was wrong, which is enough evidence
to stop writing it before the audit: it is a prediction dressed as a measurement.

## D-048 — Node 24, not 22: the ratified premise was false

- **Touches:** RFC 0009 decision 9 (`ASSUMED`), §9
- **Row said:** Node `22`, because "the newest consumer is already there and the
  three on `20` move one major", whereas `24` would make adopters jump two
  majors while adopting a new builder
- **Measured** against `nodejs/Release`'s `schedule.json`: **22 is in
  Maintenance, EOL 2027-04-30. 24 is Active LTS, EOL 2028-04-30.** The three
  projects on `20` are already past EOL (2026-04-30), so the "one gentle major"
  framing was describing a move between two unsupported positions.
- **Built:** `BUILDER_NODE_VERSION = "24"`.
- **Class:** `drift`, against wave 7. The public release schedule was knowable
  when the row was written; the row was written anyway.
- **This is my defect specifically, and the shape of it matters.** I wrote, in
  the same message that recommended `22`, that I would "confirm 22's current LTS
  phase against nodejs.org before it becomes a row" — then wrote the row without
  confirming, and the author ratified it on that recommendation. A caveat
  attached to a recommendation is worthless if the recommendation is acted on
  first: it reads as diligence while functioning as a disclaimer.
- **Why the original argument does not survive:** the builder exists so the major
  lives in one place. A consumer's edit is `npm-builder:22` → `npm-builder:24`
  either way, so "two majors at once" was never about edit size — it is about
  build-tool compatibility, and that risk sits almost entirely in
  `morze-landing`'s `react-scripts` 5.0.1, which is P3 and gated regardless.
  Shipping on 22 would have scheduled a second migration for every adopter
  within months of the first.
- **Proposed row (RFC 0009):** 9 amended in place with the measurement.

## D-049 — An image cannot carry a cache mount

- **Touches:** RFC 0009 §5.1, §6, decision 12 (new)
- **RFC said:** the builder has "a cache mount on the npm store", and §6 tests
  that "the cache mount hits on a second build"
- **Found:** `--mount=type=cache` is a flag on a `RUN` instruction in the
  *consuming* Dockerfile. No image can contain one. The RFC described a property
  the artefact is structurally incapable of having, and §6 specified a test for
  it.
- **Built:** the half the image *can* keep — `npm_config_cache=/cache`, fixed and
  documented, with the mount in the README's two-stage example so adopters get it
  by copying. `smoke.sh` asserts the path, because moving it would make every
  consumer's mount silently stop matching, with no error anywhere.
- **Class:** `spec-gap`. Knowable at design time from the BuildKit docs, and the
  kind of gap that survives review because the sentence reads fine.
- **The test had to change with it.** "The cache hits" is not directly
  observable; timing a build is flaky. §6's assertion is now that the documented
  pattern *genuinely reuses the store*, proven by running the second build
  **offline**: a cold or unshared cache fails with `ENOTCACHED`. Verified that
  the offline flag is really enforced by running the same build offline with the
  mount removed — it fails with
  `cache mode is 'only-if-cached' but no cached response is available`, so the
  passing case is not passing vacuously.
- **Proposed row (RFC 0009):** 12, `ASSUMED`.

## D-050 — ~~The §6 harness uses docker, not rootless podman~~ **Withdrawn**

- **Touches:** RFC 0002 §5.5, RFC 0009 §6
- **Convention says:** tests run under rootless Podman, because rootless is where
  UID mapping, volume ownership and port binds actually break
- **Built:** `test-build-js-app.sh` drives `docker buildx` throughout
- **Because:** `--mount=type=cache` is a BuildKit feature, and the cache
  assertion cannot be expressed without it. The convention's rationale does not
  apply here either — nothing in this battery depends on rootless behaviour; it
  builds fixtures and inspects their output. The rootless assertions belong to
  the runtime images and are made in their own smoke tests, including `caddy`'s,
  which is the image this battery hands off to.
- **Class:** `discovery` — the conflict only exists because of the cache
  assertion, which only exists because of D-049.
- **Consequence:** `npm-builder`'s rootless behaviour is asserted by `smoke.sh`
  (which does run under Podman) and not by the battery. For a build-stage image
  that is the right split: it is never run in production, only built from.
- **Deliberately not applied:** running the battery twice, once per engine.
  Doubles CI time for a build-stage image to assert something no consumer
  depends on.
- **WITHDRAWN 2026-08-18, same day — the premise was false and the departure was
  a defect (R-31).** Podman supports `--mount=type=cache` and persists it across
  builds; this was asserted from memory rather than measured, and one probe
  disproved it. Worse, the buildx route did not merely differ from convention,
  it **broke CI**: `setup-buildx-action` makes a `docker-container` driver
  current, which cannot resolve a locally built image in `FROM`, so the harness
  tried to pull `localhost/npm-builder:scratch` from a registry on port 80. It
  passed locally only because the default `docker` driver reads the local image
  store. The harness now runs entirely under rootless Podman, RFC 0002 §5.5
  needs no departure, and §6's "under rootless Podman" was true all along.

## D-051 — Two unlisted decisions, one of which is a real footgun

- **Touches:** RFC 0009 §5.2, decision 13 (new)
- **RFC is silent on:** which `package.json` script `build-js-app` runs, and what
  environment the builder presets
- **Built:** `BUILD_SCRIPT=build` (all five projects use it; a wrong name fails
  closed because `npm run` exits non-zero), and **`NODE_ENV` and `CI` left
  deliberately unset.**
- **The unset half is the one worth recording.** Both look like obvious
  build-stage hygiene and both break real builds:
  - `NODE_ENV=production` makes `npm ci` skip devDependencies — where all five
    projects keep their build tool. The install succeeds and the build then fails
    on a missing binary, which reads as a project bug rather than an image one.
  - `CI=true` makes `react-scripts` treat warnings as errors, so a project that
    builds locally fails here for reasons unrelated to this image.
- **`smoke.sh` asserts both stay unset**, rather than trusting the comment that
  says why. A comment does not survive the next person tidying the Dockerfile.
- **Class:** unlisted decisions filled, logged at departure weight per this
  skill's rule that an unlisted decision is not an open one.
- **Proposed row (RFC 0009):** 13, `ASSUMED`.

## D-052 — §5.4's copyable example was wrong in three ways

- **Touches:** RFC 0009 §5.4
- **RFC said:** `FROM ghcr.io/morzecrew/npm-builder:22`, `FROM
  ghcr.io/morzecrew/caddy:2.11`, and a bare `RUN build-js-app`
- **Found:** the major is `24` (D-048); **`2.11` is not a tag this repo
  publishes** — the mutable tag carries the patch, currently `2.11.4`; and the
  cache mount belongs on that `RUN` (D-049).
- **Why it matters more than a normal doc slip:** §5.4 is the block every adopter
  copies. A wrong tag fails immediately and loudly, which is survivable — but the
  missing mount fails *silently*, leaving the cache benefit opt-out in practice
  for everyone who copied the example. The RFC's central performance argument
  would have been undermined by its own sample code.
- **Class:** `spec-gap`.
- **Proposed row (RFC 0009):** none; §5.4 carries a correction note.

## Facts measured this wave

| What | Result |
|---|---|
| Node 22 | Maintenance, EOL 2027-04-30 |
| Node 24 | **Active LTS**, EOL 2028-04-30 |
| Node 26 | Current — becomes Active LTS 2026-10-28 |
| Node 27 | **Not released**; starts 2027-04-22. An earlier draft of this table called it Current, which was wrong — see A-43 |
| Node 24's own horizon | Active LTS **until 2026-10-20**, two months out, then Maintenance until EOL 2028-04-30. Still the right choice today (20 months of support against `22`'s 8), but `26` is the natural next bump once it reaches LTS, not `27` |
| `node:22-trixie`, `node:24-trixie` | both exist on Docker Hub |
| `ghcr.io/morzecrew/caddy` visibility | public, anonymously pullable — so §6's handoff test runs in CI rather than skipping |
| Latest published caddy tag | `2.11.4` (RFC §5.4 said `2.11`, which does not exist) |
| `test-build-js-app.sh` | 13 assertions, PASS |
| Offline enforcement | same build offline *without* the mount fails `ENOTCACHED / cache mode is 'only-if-cached'` — the cache assertion is not vacuous |
| `smoke.sh` against the baked, attested image | PASS, loaded into Podman from an OCI tar as CI does |
| `bake --print npm-builder` | one tag `ghcr.io/morzecrew/npm-builder:24`, attested, description populated, in `default` |

## Rules distilled

- A caveat attached to a recommendation does not protect anything if the
  recommendation is acted on first. Either verify before recommending, or make
  the recommendation conditional in a way that blocks (D-048).
- Check that the artefact can structurally hold the property before specifying a
  test for it. "The image has a cache mount" was never buildable (D-049).
- When a property cannot be observed directly, assert the failure instead:
  offline installs are binary where build timings are flaky (D-049).
- A test that asserts an absence must be run against the presence, or it cannot
  distinguish "not set" from "not checked" (D-049's offline check, D-051's
  `NODE_ENV`).
- Environment variables a build image does *not* set are part of its contract,
  and belong in the test rather than in a comment (D-051).
- The example everyone copies is load-bearing code. A silent omission there
  propagates further than a wrong line, because it never fails (D-052).

## Carried into the next unit

- **No project uses this image yet.** RFC 0009 stays In progress until one does;
  decision 11 makes adoption evidence rather than verification, and RFC 0003's
  retirement rule applies to an unadopted image. First migration:
  **`erp-frontend`** (the repository), decision 8 — another repo's PR, needing
  authorization this repo does not have.
- **RFC 0009 §10 question 3 is still open** — whether `morze-landing` can leave
  Node 16, now a jump to 24. It gates P3 only. Its `react-scripts` 5.0.1 is the
  single largest compatibility unknown in the whole RFC.
- ~~**Renovate will propose Node 26/27** against `BUILDER_NODE_VERSION`, both
  Current-phase rather than LTS. The bake file carries a comment saying so; that
  comment is the only thing standing between a green Renovate PR and a support
  downgrade. A `matchUpdateTypes` rule would be sturdier.~~ **Corrected and fixed
  during the audit — see A-41.** The comment guarded nothing: this repo sets
  `automerge: true` with `platformAutomerge: true`, and the custom manager is not
  excluded, so a Node major bump merges itself and no human ever sees the PR.
  `.github/renovate.json` now carries a rule holding `node` back from automerge.
- **Two author decisions still open**, carried since wave 5: narrowing RFC 0001
  decision 4 (A-21), and whether `postgres` ships `-c allow_alter_system=off`
  (W-3).
- **`morze-landing` bakes three EmailJS credentials** into its Dockerfile as
  literal `RUN` values — the exact shape RFC 0009 §5.3 warns lands in `mode=max`
  provenance. Another repo's, and now doubly relevant since that project is P3.
- ~~RFC 0009 decisions 7–11 need ratifying~~ — ratified, and 9 amended (D-048).

## Reconciliation — 2026-08-18 (wave 8)

| RFC | Row | Outcome | Grade | Decision | From |
|---|---|---|---|---|---|
| 0009 | status | **Updated** | — | 📝 Draft → 🚧 In progress; P1 shipped, RFC stays open until adoption | wave 8 |
| 0009 | 9 | **Amended** | `ASSUMED` | Node `22` → `24` on the measured release schedule | D-048 |
| 0009 | 12 | **Added** | `ASSUMED` | Builder fixes `npm_config_cache=/cache`; the mount is the consumer's | D-049 |
| 0009 | 13 | **Added** | `ASSUMED` | `BUILD_SCRIPT=build`; `NODE_ENV` and `CI` deliberately unset | D-051 |
| 0009 | §5.1, §6 | **Amended** | — | The cache claim and its test, per decision 12 | D-049 |
| 0009 | §5.4 | **Corrected** | — | Wrong builder major, non-existent caddy tag, missing cache mount | D-052 |
| 0002 | §5.5 | ~~**Departed**~~ **No departure** | — | Withdrawn the same day: Podman does support cache mounts, and the buildx route broke CI outright | D-050, R-31 |

## Self-audit findings — wave 8, 2026-08-18

Scope: the whole branch — one new image (Dockerfile, `build-js-app`, two test
scripts, README), the bake/CI/cleanup wiring, and RFC 0009's reconciliation.

| # | Where | Finding | Class | Status |
|---|---|---|---|---|
| A-36 | `build.sh`, `README.md` | `emitted()` built its list with `-printf '%f '`, leaving a trailing space, so the real message read `…these directories: out . Set…` while the README quoted it without the space. The one diagnostic this image exists to produce did not match its own documentation. `find` also emitted in filesystem order, so the list could reshuffle between builds — a diagnostic that changes shape is one nobody trusts. Now sorted and trimmed. | `drift` | Fixed |
| A-37 | `test-build-js-app.sh` | `BUILDER_TAG` was overridable and `cleanup()` runs `docker rmi -f` on it. `BUILDER_TAG=ghcr.io/morzecrew/npm-builder:24 ./test-build-js-app.sh` would have overwritten *and then deleted* the local copy of the published image. The override was never useful either — the harness builds the image it tests, so an override only renames the thing it is about to overwrite. Removed. | — | Fixed |
| A-38 | `images/README.md` | The image shipped with no row in **Admissions on record**, and the refused Node runtime had none either. That table is not one of the nine numbered touchpoints, so nothing prompts for it, and its own text says a refusal is recorded "rather than left implicit". Both rows added. | `drift` | Fixed |
| A-39 | RFC 0009 §11 | New rows 12 and 13 were appended next to row 9 rather than at the end, leaving the table numbered 1–9, 12, 13, 10, 11. Reordered. | — | Fixed |
| A-41 | this log, `.github/renovate.json` | My own residue claimed a bake-file comment was "the only thing standing between a green Renovate PR and a support downgrade". **There is no PR to review**: the repo sets `automerge: true` and `platformAutomerge: true`, and the `packageRules` exclusion covers only the `dockerfile` manager, not the custom regex manager that reads `docker-bake.hcl`. A Node major bump would have merged itself, moving the builder off Active LTS with nobody in the loop. Added a `packageRules` entry holding `node` back from automerge. | `drift` | Fixed |
| A-42 | `docker-bake.hcl` | Checking my own annotation against the custom manager's regex showed **11 annotations but only 10 tracked dependencies**. The unmatched one is `al3xos/python-distroless`: its `# renovate:` line sits above a ten-line explanatory comment, and the manager matches `# renovate: …\s+variable`, so a comment in the gap unhooks it. **That base image has never been bumped by Renovate.** The comment in the gap is itself about automerge risk between the builder and the runtime — so the guard it describes has been protecting against an event that could not occur, while the runtime base quietly went unupdated. Annotation moved directly above its `variable`, with a note saying why it must stay there. | `drift` (against the wave that added it, not counted here) | Fixed |
| A-40 | `smoke.sh` | **Nothing asserted that the image's Node major matches the major it advertises.** The tag is the only thing telling a consumer which major they pin; if `BUILDER_NODE_VERSION` and the base image disagree — a bake edit missing the Dockerfile default, a hand-built image — every consumer pins a major they are not getting, with no error anywhere. This is exactly the tag/content divergence wave 6 shipped in the postgres extensions label (D-040), in the wave that distilled the rule against it. Added, verified red against an image labelled `24` that ships `v22.23.2`. | — | Fixed |

**A-40 is the one worth reading twice.** Wave 6 found this class, wrote the rule
down, and wave 8 built a new image with the same hole — a tag asserting something
about contents that nothing checks. A distilled rule does not transfer by having
been written; it transfers when a test enforces it, which is why it is now an
assertion rather than a line in this file.

### Verified

| Check | Result |
|---|---|
| `test-build-js-app.sh` | 13 assertions PASS, re-run after every fix |
| `smoke.sh` against the baked, attested image | PASS — loaded into Podman from an OCI tar exactly as CI does |
| Offline enforcement (D-049) | the same build offline *without* the mount fails `ENOTCACHED`, so the cache assertion is not vacuous |
| `NODE_ENV` assertion | verified red against an image presetting `NODE_ENV=production` |
| npm cache path assertion | verified red against an image moving it to `/somewhere-else` |
| Node major assertion (A-40) | verified red against an image declaring `24` while shipping `v22.23.2` |
| Refusal tests | inherently red-verified: each asserts a build *fails*, so a removed check turns the test red rather than green |
| RFC 0009 §11 | 13 rows, contiguous, all four-column; links resolve |
| Indentation | tabs throughout, matching every other shell file in the repo |
| RFC 0009 §6 coverage | all six bullets have a corresponding assertion — the criterion decision 11 (`LOCKED`) sets for P1 |

### Residue — what I would still distrust

- **Nothing here has built a real project.** Every fixture is a `package.json`
  whose build script is `mkdir && echo`. That is the right shape for testing
  *this image's* contract, but it means no Vite, Next or react-scripts build has
  run through `build-js-app`. The first migration is where that gets tested, and
  it is in another repository.
- **`morze-landing`'s `react-scripts` 5.0.1 on Node 24 is untested and is the
  RFC's largest unknown.** Decision 9 now puts two majors between them.
- **The handoff test binds host port 18080.** Occupied, it fails as a confusing
  connection error rather than a clear one. Left alone: CI runners are clean, and
  a port-probe helper is more machinery than the failure justifies.
- ~~**Renovate will propose Current-phase majors** against
  `BUILDER_NODE_VERSION`. A bake-file comment is the only guard; a
  `matchUpdateTypes` rule would be real enforcement.~~ **Wrong, and fixed — see
  A-41.** With `automerge: true` there is no PR for a comment to inform.

## Review round 1 — PR #37, 2026-08-18

Six findings, **all six valid**, plus one CI failure the review did not raise.
Two were reproduced before being fixed; none were accepted on the reviewer's
word alone.

| # | Finding | Verdict |
|---|---|---|
| R-28 | **A stale output directory in the build context is accepted.** A project that commits `dist/`, or sweeps one in with `COPY . .`, hands `build-js-app` a complete-looking bundle the build never touched — so every check passes on last release's assets. Reproduced: a committed `dist/index.html` plus a `true` build script shipped `STALE-FROM-LAST-YEAR` and the build **succeeded**. This is the image's central promise failing in a subtler way than decision 2's empty case, and worse in effect: it ships and looks fine, where the empty case at least 404s. Fixed by requiring `index.html` to be newer than a marker taken before `npm run` — mtime rather than clearing the directory first, because deleting a caller-supplied path is a worse failure than the one it prevents. | fixed |
| R-29 | **`BUILD_OUTPUT_DIR` overlapping `APP_DIST`.** `BUILD_OUTPUT_DIR=/srv` made source and destination the same tree. Reproduced: `cp: '/srv/.' and '/srv/.' are the same file`. It already failed, so the severity is diagnosis, not corruption — but a `cp` error is not a message anyone can act on. Now refused before the install, naming both paths. | fixed |
| R-30 | **A failed Caddy pull skipped §6's handoff assertion while the battery still reported PASS.** My own "no silent caps" rule, broken in the wave that restated it. The package is public and anonymously pullable, so a pull failure is infrastructure, not an optional test. Now fatal. | fixed |
| R-31 | **§6 says rootless Podman; the harness required `docker buildx`.** True when reviewed, and the underlying choice was worse than inconsistent — see below. | fixed |
| R-32 | **§5.1 still said decision 9 fixes the major at `22`** after D-048 amended the row to `24`. This is A-33's exact shape — superseded prose left unmarked — one wave after I distilled the rule against it, and this time review caught it rather than the audit. | fixed |
| R-33 | **Node 27 recorded as Current.** It starts 2027-04-22 and is unreleased. My classifier inferred phase from the absence of a maintenance date without checking whether `start` had passed, so an unreleased major came out looking shipped. Corrected, and the table now also records that **Node 24 enters Maintenance on 2026-10-20** — two months out — which the original measurement never surfaced. | fixed |

### The CI failure the review did not raise

`Bake and smoke` went red on the first push, and the cause is the one that makes
R-31 more than a style point. `setup-buildx-action` makes a **`docker-container`
driver** builder current; that driver cannot resolve a locally built image in
`FROM`, so the harness tried to pull `localhost/npm-builder:scratch` over HTTP
from port 80 and every fixture build failed. It passed locally only because the
default `docker` driver reads the local image store — **the harness was green on
my machine for a reason that does not exist in CI.**

The premise underneath it was never measured: I recorded in D-050 that
`--mount=type=cache` was BuildKit-only and Podman could not express the cache
assertion. One probe disproved it — Podman supports cache mounts and persists
them across builds. So the departure bought nothing, cost a red CI run, and is
withdrawn; the harness now runs entirely under rootless Podman and RFC 0002 §5.5
needs no exception.

**A local environment note that cost real time.** The desync assertion failed
locally under Podman with `ECONNREFUSED 127.0.0.1:7890` — a dead proxy in my
shell, which Podman forwards into builds and buildx did not. That is D-039's
trap exactly: "could not look" and "looked and found nothing" print different
strings, but both just say the test failed. The test was correct; the
environment was not.

### Rules distilled

- A build stage must prove the artefact is *fresh*, not merely present. "Exists,
  non-empty, well-formed" is satisfied by last release's output (R-28).
- Prefer proving freshness over clearing state: a marker comparison cannot delete
  the wrong directory, and a path derived from a caller-supplied variable is
  exactly the wrong thing to `rm -rf` (R-28).
- A test that skips on infrastructure failure and still reports PASS is a test
  that will be absent precisely when something is broken (R-30).
- "Works locally" and "works in CI" diverge most where the *builder*, not the
  code, differs. A locally built image in `FROM` is a docker-driver privilege
  (R-31).
- Do not infer a release phase from the absence of a field. Check the date that
  says it shipped (R-33).

# Wave 9 · The review that opens itself

Branch `feat/wave-9-annual-image-review`. RFC 0003 decision 6 — the scheduled
workflow that opens the annual review issue. No image changed.

**Drift count: 3** — A-45, A-46 and A-47, all introduced by this wave and all
caught by its own audit. Written as 0 when the group was drafted, which is the
fifth consecutive wave the pre-audit number has been wrong; the practice of
writing it before the audit is what is wrong, not the arithmetic.

RFC 0003's rule shipped on 2026-08-12 and its `LOCKED` decision 6 specified a
mechanism that was never built: for six days the annual review has been a
calendar promise, which is the exact thing that row exists to prevent. It says
so itself — *"a self-opening issue is the difference between a review that
happens and a calendar promise that does not."*

## D-053 — The issue carries evidence, not just a checklist

- **Touches:** RFC 0003 decision 6 (`LOCKED`), decision 5 (`ASSUMED`), §4.2
- **RFC said:** open an issue with "both questions and the current image list
  pre-filled"
- **Built:** that, plus a per-image scan of which repositories reference each
  tag
- **Because:** the review's actual work is reading consuming repositories. An
  issue that opens with "go and grep forty repositories" is the kind that gets
  closed unread in February, and decision 6's whole argument is about the
  difference between a review that happens and one that does not.
- **Class:** `spec-gap` — the RFC specified the trigger and the shape, and was
  silent on whether the trigger should do any of the work.
- **Two mechanisms this needed that nobody would have predicted:**
  - **This repository is excluded from its own results.** Every image is
    referenced here — bake file, READMEs, RFCs — so the unfiltered scan returns
    `platform-images` for all nine, and §4.2's actual signal ("an image whose
    *only* consumer is this repo is retired") is buried under noise that reads
    like use. Measured before the exclusion: nine of nine rows self-referential.
  - **`GITHUB_TOKEN` cannot search other repositories.** The scan needs
    `ORG_READ_TOKEN`, and when it is absent the issue says the scan did not run
    and names the secret — rather than rendering an empty column that reads as
    "no consumers found". D-039's rule, applied to a column in a table.
- **Held deliberately:** decision 5 says the review reads consuming
  repositories, **not GHCR pull counts**. There is no call to the packages API
  anywhere in the workflow, and the issue body says so, because the packages API
  is right there and pull counts look like data.
- **Proposed row (RFC 0003):** 11, `ASSUMED`, with the "starting point, not the
  answer" caveat that keeps a scan from being read as a verdict.

## D-054 — Decision 6 presumes an assignee it never names

- **Touches:** RFC 0003 decision 6 (`LOCKED`)
- **RFC said:** "Owner is whoever the issue is assigned to at open time"
- **Found:** nothing names one, and a workflow cannot invent an owner. An
  unassigned issue leaves the rule's owner undefined at exactly the moment the
  row claims it is defined.
- **Built:** a `REVIEW_ASSIGNEE` repository variable defaulting to the repo
  owner, applied **after** creation rather than during it — `gh issue create
  --assignee` fails the whole command when the assignee is no longer a
  collaborator, which would lose the issue. A failed assignment now warns and
  leaves the issue standing.
- **Class:** `spec-gap`.
- **Proposed row (RFC 0003):** 12, `ASSUMED`.

## D-055 — An annual cron is the schedule most likely never to fire

- **Touches:** RFC 0003 decision 6 (`LOCKED`), §6 risks
- **Found:** GitHub disables scheduled workflows in repositories that have gone
  inactive. An annual cron is uniquely exposed to that — and **a repository
  quiet for a year is precisely when an unused-image review matters most.** The
  mechanism decision 6 chose is weakest in the case it was chosen for.
- **Built:** nothing. There is no in-repo fix, so the workflow states the
  limitation in its own header.
- **Class:** `discovery` — visible only once the mechanism was chosen and
  written.
- **Not verified by me.** This is GitHub's documented behaviour for scheduled
  workflows, not something this wave measured, and the exact inactivity window
  should be confirmed before anyone relies on the number.
- **Deliberately not applied:** a monthly cron that no-ops outside January.
  Keeps the workflow "recent" only if the disabling rule keys on workflow runs
  rather than repository activity — which is the thing above that I have not
  confirmed. Guessing here would trade a stated limitation for an unstated one.

## The rule, applied for the first time

Run by hand with the workflow's own query, this repository excluded:

| Image | Repositories referencing it |
|---|---|
| `flyway` | 6 |
| `python-distroless` | 5 |
| `uv-builder` | 5 |
| `postgres` | 3 |
| `caddy` | 2 |
| `npm-builder` | **none** |
| `postgres-cron` | **none** |
| `postgres-pgvector` | **none** |
| `valkey` | **none** |

**No image is a retirement candidate**, because all four zero-consumer images
shipped within the last three days — `valkey` on 2026-08-16, the two postgres
variants on 2026-08-17, `npm-builder` on 2026-08-18. The clock starts now rather
than having run out.

**`valkey` is the one to watch, and the reason is its own admission.** It was
admitted under route 2 — 14 projects running upstream Redis or Valkey with
divergent pins — and the whole premise was that those projects would land on a
shared image. Two days in, none has. That is not yet a failure; it is the
premise being unproven, and it is exactly what the annual review exists to
notice. `npm-builder` is in the same position by design (RFC 0009 decision 11).

The two postgres variants are a case the scan cannot read: they are variants of
an image with three consumers, so "nobody references `postgres-pgvector`" may
mean nobody wants it, or may mean everyone uses plain `postgres`. A reviewer has
to answer that; the scan cannot.

## Rules distilled

- A rule with a `LOCKED` mechanism and no implementation is a rule that has not
  shipped, however completely it is written down. Six days is short; a year is
  the usual gap, and nothing would have surfaced it (D-053).
- Exclude the observer from the observation. A repository that publishes an
  image also references it, so an unfiltered "who uses this" search answers a
  different question than the one asked (D-053).
- When automation cannot measure something, say so in the artefact it produces.
  An empty column and an unrun scan look identical to the reader (D-053).
- A row that says "whoever is assigned" needs something to do the assigning, or
  it is describing a state nobody creates (D-054).
- The mechanism chosen for a rare event should be checked against the rare event
  itself: an annual cron in a repository that has gone quiet is exactly the case
  it was chosen for, and the weakest place to rely on it (D-055).

## Carried into the next unit

- **`ORG_READ_TOKEN` does not exist yet.** Until it is created with org-wide
  read, the January issue will open with its scan column reading *not scanned*.
  The workflow says so rather than pretending, but the secret is the difference
  between a review with evidence and a review with a checklist.
- **The workflow has never run end to end.** Composition and the scan query are
  verified locally; the duplicate check, issue creation and assignment cannot be
  exercised until the file is on the default branch and can be dispatched.
- **`valkey`, `npm-builder`, `postgres-cron`, `postgres-pgvector` have no
  external consumer.** All shipped within three days, so none is due for
  retirement — but the first review will ask, and `valkey`'s route-2 admission
  premise is the one with something to prove.
- **Two author decisions still open**, carried since wave 5: narrowing RFC 0001
  decision 4 (A-21), and whether `postgres` ships `-c allow_alter_system=off`
  (W-3).
- **RFC 0009's first migration (`erp-frontend`) still needs a cross-repo PR**
  this repository cannot open.

## Reconciliation — 2026-08-18 (wave 9)

| RFC | Row | Outcome | Grade | Decision | From |
|---|---|---|---|---|---|
| 0003 | status | **Updated** | — | 🚧 → ✅ Complete; decision 6 now has a mechanism rather than an intention | wave 9 |
| 0003 | 11 | **Added** | `ASSUMED` | The issue pre-fills a consumer scan, with this repo excluded and three distinct evidence states | D-053 |
| 0003 | 12 | **Added** | `ASSUMED` | Assignee from `REVIEW_ASSIGNEE`, applied after creation | D-054 |
| 0003 | §6 | **Risk recorded** | — | An annual cron is disabled by repository inactivity, the case it exists for | D-055 |

## Self-audit findings — wave 9, 2026-08-18

Scope: one new workflow and four documents. Almost all of the risk is in a file
that **cannot be run here** — its scheduled path fires in January and its issue
creation needs the default branch — so the audit leaned on reading it against
the rows it implements, and on running every piece that could be run in
isolation.

| # | Where | Finding | Class | Status |
|---|---|---|---|---|
| A-45 | `annual-image-review.yaml` | The scan step interpolated `${{ steps.images.outputs.targets }}` straight into its `run:` block while the compose step two steps below passed the same value through `env:`. Inconsistent within one file, and the raw form is the shape that becomes a script-injection bug the moment the interpolated value stops being repo-controlled. Moved to `env:`. | `drift` | Fixed |
| A-46 | this log | The duplicate-issue check was **decided in the plan and never logged**. It is a real behaviour — a manual dispatch while last year's review is open opens nothing — and identifying prior reviews *by title prefix rather than by label* was a deliberate choice to avoid the workflow maintaining a label as a side effect. An unlisted decision is not an open one; it should have had an entry. Recorded here as D-056. | `drift` | Fixed |
| A-47 | `annual-image-review.yaml` | The header asserted GitHub's cron-disabling behaviour as flat fact while D-055 in this log marks the same claim unverified. The file a reader reaches first was the more confident of the two. Reworded to say it is quoted from documentation and not measured here. | `drift` | Fixed |

## D-056 — Duplicate reviews are suppressed by title, not by label

- **Touches:** RFC 0003 decision 6 (`LOCKED`)
- **RFC is silent on:** what a second trigger should do while a review is open
- **Built:** the workflow lists open issues and skips if any title starts with
  "Annual image review". `workflow_dispatch` makes a second trigger easy, and an
  annual review that opens twice is a review nobody trusts to be the current one.
- **By title rather than by label**, so the workflow does not have to create and
  maintain a label as a side effect of running — `gh issue create --label` fails
  outright when the label does not exist, which would make first-run success
  depend on repository state nobody set up.
- **Class:** unlisted decision filled; logged at departure weight.
- **Consequence, stated plainly:** a review issue that is closed without the work
  being done is invisible to this check, and the next dispatch opens a fresh one.
  That is the intended direction — the check prevents duplicates, not amnesia.

### Verified

| Check | Result |
|---|---|
| Workflow YAML | Parses; 6 steps, `contents: read` + `issues: write`, cron `0 9 8 1 *` |
| Issue composer | Extracted and run in both modes — scanned and unscanned — rendering all three evidence states distinctly |
| Consumer scan query | Run end to end against the live API for all nine images; results in the table above |
| Self-exclusion | Verified by contrast: unfiltered, all nine rows return `platform-images`; filtered, four return nothing |
| Duplicate-detection query | Run against this repository; returns empty, which is correct — no review issue is open |
| Decision 5 (no pull counts) | `grep` finds two mentions of the packages API, both prose asserting its absence. No call |
| RFC 0003 decision table | 12 rows, contiguous, four columns |

### Residue — what I would still distrust

- **The workflow has never run.** Issue creation, assignment and the
  `dry_run` branch are unexercised, and cannot be exercised until the file is on
  the default branch. The first real proof is a manual dispatch after merge, and
  I would do that before trusting January.
- **`ORG_READ_TOKEN` does not exist**, so the first run — whenever it happens —
  produces the unscanned form of the issue. That path is tested; the scanned path
  is the one the January issue should carry, and it needs a secret only you can
  create.
- **The cron-disabling limitation is quoted, not measured.** It is the single
  thing most likely to make this workflow silently never fire, and I have not
  confirmed the window.
- **The scan cannot read variants.** `postgres-pgvector` and `postgres-cron`
  return nothing, which may mean nobody wants them or may mean everyone uses
  plain `postgres`. A reviewer answers that; the table only asks.
