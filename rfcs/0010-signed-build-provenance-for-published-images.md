# RFC 0010 — Signed build provenance for published images

- **Status:** 🚧 In progress. The `attest` job lands with this RFC. §6's check
  runs against the first publish after the merge, and passing it moves this RFC
  to Complete.
- **Scope:** Each promoted image index gets a signed SLSA provenance statement:
  a GitHub artifact attestation, keyless through Sigstore and bound to this
  repository's `publish.yaml` on `main`. This RFC also records the identity a
  consumer verifies a pinned digest against, and where the bundle is stored.
  It does **not** change the BuildKit provenance and SBOM. They stay unsigned
  and are still described that way (RFC 0002 decision 4). It also leaves out
  attestations for the per-platform manifests, a signed SBOM, cosign
  signatures, attesting digests published before this change, and enforcement
  anywhere downstream. The only contract change is a new job in
  [publish.yaml](../.github/workflows/publish.yaml).
- **Related:** [RFC 0002](0002-publishing-pipeline-attestations-tag-policy-rebuild-cadence.md)
  §8, which names this RFC; [publish.yaml](../.github/workflows/publish.yaml);
  [cleanup-images.yaml](../.github/workflows/cleanup-images.yaml);
  [actions/attest](https://github.com/actions/attest);
  [`gh attestation verify`](https://cli.github.com/manual/gh_attestation_verify).
- **Discussion:** [#134](https://github.com/morzecrew/platform-images/issues/134),
  which carries the consumer's side.

---

## 1. Summary

A matrix job, `attest`, runs after promotion. It signs one SLSA provenance
statement for each target's index digest, which is the digest a bundle pins.
The bundle is stored in this repository's attestations and in GHCR as a
referrer of that index. A consumer accepts a digest only if
`gh attestation verify` finds a statement signed for `publish.yaml` on
`refs/heads/main`.

## 2. Motivation

dotdash pins `ghcr.io/morzecrew/xray:<tag>@sha256:<index digest>`, and
Renovate opens a pull request each time that digest moves, weekly rebuilds
included. Nothing in that pull request shows that the new digest came from
this repository's publish run, and not from anyone else who can push to the
package. The smoke gate proves the image works, not where it came from. RFC
0002 §9 says the same about its own attestations: "unsigned metadata that
anyone with push access can produce". RFC 0002 §8 deferred signing until a
consumer with an identity policy existed. dotdash is that consumer, and §5.3
states its policy.

## 3. Current state

- `promote` checks every leg's mode=max provenance and SPDX SBOM, then runs
  `imagetools create` for each target. That pushes one index per target, with
  every tag naming it. The BuildKit attestations are attestation manifests
  inside that index. Nothing signs them.
- No job in the workflow holds `id-token: write`.
- `cleanup-images.yaml` runs `dataaxiom/ghcr-cleanup-action` v1.2.2. That
  action treats referrers, including those `attest-build-provenance` writes,
  as children of their subject and keeps them. `delete-orphaned-images`
  deletes a `sha256-…` referrer only when its subject digest no longer exists.
- The repository is public, so `actions/attest` signs with the public-good
  Sigstore instance and records the signature in its public transparency log.

## 4. Non-goals

- **Signing the BuildKit statements.** They describe each platform's build,
  and a consumer pins the index. A second, signed statement on the index
  answers the consumer's question without changing what RFC 0002 verified.
- **Verifying in this repository.** The consumer is the one with a policy,
  so the check belongs in the consumer's CI (#134's dotdash side).

## 5. Design

### 5.1 The job

```yaml
attest:
  needs: promote
  strategy:
    fail-fast: false
    matrix:
      include: ${{ fromJSON(needs.promote.outputs.subjects) }} # target, name, digest
  permissions: { contents: read, packages: write, id-token: write, attestations: write }
  steps:
    - run: docker login ghcr.io …
    - uses: actions/attest@<sha> # v4.2.2
      with:
        subject-name: ${{ matrix.name }}     # ghcr.io/morzecrew/<package>
        subject-digest: ${{ matrix.digest }} # the index
        push-to-registry: true
        create-storage-record: false
```

With no predicate input, `actions/attest` generates SLSA build provenance.
`promote` collects the subjects. Right after each `imagetools create`, it reads
the index digest with `imagetools inspect <first tag> --format
'{{.Manifest.Digest}}'` and refuses anything that is not
`sha256:<64 hex digits>`. Nothing else moves the tag in that window, because
the run holds the `ghcr-mutations` concurrency group.

### 5.2 Failure semantics

Attestation runs after the tags move, because the index has no digest until
`imagetools create` pushes it. If an `attest` leg fails, the run fails, and on
a schedule `report-failure` files its issue. Until then the tag names an
unattested index, and a consumer that verifies refuses it: the failure is
closed. Re-running the failed jobs attests the same digest from `promote`'s
recorded outputs. A digest attested twice carries two valid statements, which
is harmless.

### 5.3 The identity policy, as a consumer states it

A digest is trusted if it carries a provenance attestation signed for the
workflow `morzecrew/platform-images/.github/workflows/publish.yaml`, on
`refs/heads/main`:

```sh
gh attestation verify oci://ghcr.io/morzecrew/xray@sha256:… \
  --owner morzecrew \
  --signer-workflow morzecrew/platform-images/.github/workflows/publish.yaml \
  --source-ref refs/heads/main
```

`publish.yaml` is triggered only by `push`, `schedule` and `workflow_dispatch`,
so the workflow identity already restricts the trigger. A `workflow_dispatch`
from another branch publishes, but it is signed with that branch's ref, and
`--source-ref` refuses it.

### 5.4 Alternatives considered

- **Attesting inside `promote`, as #134 sketched.** The action signs one
  subject per call, and a step cannot loop over targets. It would also put
  `id-token: write` on the job that runs `bake` and pushes every index. A
  separate job keeps the signing identity on a job that does nothing else.
- **`actions/attest-build-provenance`, as #134 named it.** From v4 it is a
  wrapper around `actions/attest`, and upstream directs new workflows to
  `actions/attest`. The statement and its verification are the same.
- **Attesting each platform manifest as well.** No consumer resolves those by
  digest. Each one would add a leg and a statement nobody reads.
- **Attesting before the tags move.** That needs the index pushed untagged
  first, which would be a second promotion path to keep correct. The order
  chosen costs a window in which a tag names an unattested index, and a
  verifying consumer refuses that index rather than trusting it.

## 6. Tests

- Before the merge: `zizmor` reports nothing new on `publish.yaml`. The
  subjects fragment was run against a real GHCR index, and its digest matched
  the `sha256sum` of `imagetools inspect --raw`.
- After the merge: the merge itself publishes, because `publish.yaml` is in
  the push path filter. `gh attestation verify` with §5.3's flags must pass on
  a target's new index digest. It must refuse a digest published before this
  change, and refuse the new digest under `--source-ref refs/heads/other`.

## 7. Docs

The root README's Attestations section separates the unsigned BuildKit
statements from the signed index statement and gives §5.3's command. RFC
0002's status block points here.

## 8. Out of scope

- **Attesting older digests.** A statement signed today for a digest built
  last month would claim a build this workflow run did not perform. The check
  starts with the first publish after this change.
- **A signed SBOM.** `actions/attest` can sign one with `sbom-path`, but no
  consumer asks for it. It reopens when one does.
- **Admission control.** Enforcing this at deploy time is the consumer's
  choice of tool.

## 9. Risks

- **The identity is a path.** Renaming `publish.yaml`, moving promotion to a
  reusable workflow, or publishing from another branch changes the signer and
  breaks every consumer's check at once. This closes a door, and decision 1
  says so.
- **The statement proves origin, not soundness.** It shows that this workflow
  built the digest from `main`. Anyone who can merge to `main` can still
  change what that workflow builds.
- **The attestation service is a new dependency of a publish run.** An outage
  fails the run after the tags have moved. §5.2 is the recovery.

## 10. Decisions

| # | Grade | Decision |
|---|---|---|
| 1 | `ASSUMED` | The trusted identity is the workflow `morzecrew/platform-images/.github/workflows/publish.yaml` on `refs/heads/main`. Closes a door: renaming the workflow or moving promotion breaks every consumer's verification. |
| 2 | `ASSUMED` | The subject is the index digest, the reference a consumer pins. Per-platform manifests are not attested. |
| 3 | `ASSUMED` | The BuildKit provenance and SBOM are unchanged and still described as unsigned. RFC 0002 decision 4 still describes them. |
| 4 | `ASSUMED` | Attestation is a job of its own after promotion, one leg per target, and the only job holding `id-token: write`. A failed leg fails the run (§5.2). |
| 5 | `ASSUMED` | The bundle is stored in this repository's attestations and pushed to GHCR as a referrer of the index. No artifact storage record is created. |
| 6 | `ASSUMED` | Signing uses the public-good Sigstore instance, as a public repository does. A private repository would sign with GitHub's own instance and change what a consumer verifies. |
| 7 | `ASSUMED` | Digests published before this change stay unattested. |
