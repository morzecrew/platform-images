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

**Drift count: 0.**

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
- **Proposed row (RFC 0002):** `ASSUMED` — bake exports each target to a
  docker-format tar which Podman loads, in a single job.

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
- **Next:** spike it — build one image to an OCI layout, push to a throwaway
  GHCR tag, `imagetools inspect` for the provenance and SBOM manifests. The
  spike also discharges §6's outstanding first-publish verification, which has
  been unproven since wave 0.

**Deliberately not applied:** RFC 0002 §5.4 sketches
`--set *.output=type=oci,dest=…` as the build-once mechanism. Not built, pending
D-007's spike — the sketch is what needs verifying, not what needs implementing.

## Rules distilled

- A decision row that names both a property and an implementation is two claims,
  and they can disagree. When they do, the property is the decision — the
  implementation was an illustration (D-002).
- A format defined in one section and consumed in another is a place to check
  that the consumer's needs survived the trip; §5.1 dropped the column §5.2
  depended on (D-001).
- Prescribing how to test a class of image ("run its helper with `--help`") is a
  claim about every member of the class. `uv-builder` is the member that has no
  helper flags (D-004).
- Where an RFC names a comparison but not its reference point, the reference is
  usually only obtainable before the change lands. Capture the result in the log,
  not just the method (D-006).

## Carried into the next unit

- **RFC 0002 P4**, blocked on D-007's spike. It carries the outstanding §6
  verification with it.
- The equivalence gate in D-006 is spent once this merges; RFC 0004 P2's
  variants have no equivalent reference and will need a different argument.
- `images/README.md` touchpoint 9 (`smoke.sh`) is now real — a new image without
  one silently gets no smoke coverage, since the loop iterates over the files
  that exist.
