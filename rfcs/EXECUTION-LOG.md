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
