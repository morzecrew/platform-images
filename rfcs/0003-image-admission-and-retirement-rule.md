# RFC 0003 — Image admission and retirement rule

- **Status:** 🚧 In progress — the rule shipped to
  [images/README.md](../images/README.md) on 2026-08-12. **Execution surfaced a
  conflict with decision 1, which is `LOCKED` and therefore not for the executor
  to resolve** — see decision 7. The rule as written is what shipped.
- **Scope:** The rule that decides whether an image belongs in this repo, and the
  rule that removes one. Covers the two-project admission bar, the annual
  unused-image review, the mechanical retirement checklist (including what
  happens to already-published GHCR packages), and where both are written down.
  Does **not** decide any specific image — RFCs 0005–0008 each carry their own
  gate and are judged against this rule, not by it.
- **Related:** [images/README.md](../images/README.md),
  [docker-bake.hcl](../docker-bake.hcl),
  [.github/workflows/cleanup-images.yaml](../.github/workflows/cleanup-images.yaml),
  [README.md](../README.md). RFC 0002 supplies the per-image CI cost this rule
  prices in.
- **Origin:** `candidate-images.md` §1.3 and §6.

---

## 1. Summary

An image lands here when the same Dockerfile has been hand-rolled in two or more
projects; one project keeps its own Dockerfile. An image no project has used for
a year is deleted, not maintained. Both sentences go in
[images/README.md](../images/README.md), together with a retirement checklist,
because deletion has to be routine or the set only grows.

## 2. Motivation

Adding an image is eight edits, not one. For a new `<name>`, today and after
RFC 0001/0002 land:

| # | Touchpoint | Where |
|---|---|---|
| 1 | `Dockerfile`, `README.md`, optional `rootfs/` | `images/<name>/` |
| 2 | Version variable with its Renovate annotation | [docker-bake.hcl](../docker-bake.hcl) |
| 3 | Bake target with `tag()` / `label()` / args | [docker-bake.hcl](../docker-bake.hcl) |
| 4 | `default` group membership | [docker-bake.hcl](../docker-bake.hcl) |
| 5 | `PACKAGES` list | [cleanup-images.yaml:31](../.github/workflows/cleanup-images.yaml#L31) |
| 6 | Images table row | [README.md](../README.md) |
| 7 | Allowlist + env-contract section | RFC 0001 |
| 8 | `smoke.sh` | RFC 0002 §5.5 |

Items 4 and 5 are hand-maintained lists whose omission fails silently: a missing
`default` entry means the image is never built by `just bake` or the weekly
rebuild, and a missing `PACKAGES` entry means its untagged versions accumulate in
GHCR forever. Neither produces a red check.

Beyond the edits, each image is a permanent subscription to an upstream's CVE
feed and, after RFC 0002, a `--no-cache` slot in the weekly rebuild. The four
candidates in RFCs 0005–0008 would take the set from five images to nine —
close to doubling it. The default answer has to be no, and something has to make
that the default rather than a mood.

## 3. Current state

Five images, all with at least one plausible in-house consumer: `postgres`,
`caddy`, `flyway`, `uv-builder`, `python-distroless`. The last two are an
explicit pair — `uv-builder` produces `/opt/venv`, `python-distroless` consumes
it — which is the shape RFC 0008 proposes to mirror for JavaScript.

There is no admission rule and no retirement mechanism. `images/README.md`
documents layout only. `cleanup-images.yaml` deletes *untagged versions* of
listed packages; it has no notion of a retired image and would simply stop being
told about one.

Nothing in the repo records why any of the five exists, so the rule below has no
retroactive evidence to work from — it applies from here forward.

### 3.1 What applying the bar actually found (2026-08-12)

The first real application of this rule, across ~40 sibling repositories, turned
up two things the rule does not handle.

> **Resolved 2026-08-12.** Both findings below were referred to the author and
> settled: the first by a second admission route (row 9), the second by an
> annual-review question (row 10). The text is kept as written, since it is the
> evidence those rows were decided on.

**The bar misses configuration-curation images.** RFC 0006 (Valkey) is the case:
fourteen projects run a Redis or Valkey service across four different pinned
upstream images, and **not one hand-rolls a Dockerfile** — they all configure
through compose. Read literally the bar refuses the image; read for its purpose —
two or more projects separately solving the same problem — it is met several
times over. The bar counts duplicated *Dockerfiles*, but an image whose entire
contribution is defaults never shows up as a duplicated Dockerfile. Decision 7
records this; decision 1 is `LOCKED`, so the fix is the author's, not
execution's.

**The touchpoint count moved from eight to nine.** RFC 0002 P1 shipped a
`DESCRIPTIONS` map in the bake file on the same day, and a target with no entry
in it publishes an empty description label rather than failing — a third
silent-omission touchpoint alongside `default` and `PACKAGES`. §2's table says
eight because that was true when this RFC was written; the shipped README says
nine. Expect this count to grow once RFC 0001 and RFC 0002 P3 land, which is
itself the argument the admission bar is making.

**The inverse problem exists and the rule says nothing about it.** Two projects —
`morze-crm-backend-v2` and `morze-erp-backend-v2` — hand-roll a Postgres
Dockerfile that **this repo already publishes**, one of them near-verbatim from
[images/postgres/Dockerfile](../images/postgres/Dockerfile) including its
comments. That is duplication of an existing image rather than evidence for a new
one, and no rule here catches it. Decision 8.

## 4. Design

### 4.1 The rule, as written into `images/README.md`

> **Admission.** An image lands here when the same Dockerfile has been
> hand-rolled in **two or more** projects. One project keeps its own Dockerfile.
>
> **Retirement.** An image that no project has used for a year is deleted, not
> maintained.

Two clarifications that keep the first sentence from being argued away:

- **"Hand-rolled in two projects" means the Dockerfiles exist**, not that two
  projects would benefit. Anticipated reuse is the failure mode this bar exists
  to catch; it is how a repo acquires images maintained for nobody.
- **A pair counts as one admission.** `uv-builder` + `python-distroless` are one
  decision about Python, not two about images. RFC 0008's builder + runtime is
  likewise one.

The bar is deliberately evidence-based rather than judgement-based, because a
judgement bar is met by whoever is currently enthusiastic.

### 4.2 The annual review

Once a year, each image is checked against one question: **does a live project
reference this tag?** The answer comes from consuming repositories, not from
GHCR pull counts — a scheduled CI job pulling an image is a pull count, not a
user.

Outcomes: keep, or retire. There is no "keep for now" — that is the state that
produces images nobody has used since 2024.

An image whose *only* consumer is this repo (a builder used by no downstream
project) is retired even if it builds cleanly.

### 4.3 Retirement checklist

Deletion has to be mechanical or it will not happen. Reverse of §2:

1. Announce in the image's README that the tag is frozen, with a date.
2. Remove the bake target, its variable, and its `default` group entry.
3. Remove the row from the root README images table.
4. Delete `images/<name>/`.
5. **Leave `<name>` in `cleanup-images.yaml`'s `PACKAGES`** — the published
   package still exists and its untagged children still need collecting. It is
   removed only if the package itself is deleted.
6. Decide the published package's fate explicitly (§4.4).

Steps 2–4 are one PR. The git history keeps the Dockerfile, so retirement costs
nothing irreversible; that is the argument that makes retirement easy to agree
to.

### 4.4 What happens to the published GHCR package

Deleting the directory does not delete the package, and this is the part a
retirement usually forgets. Two options, chosen per image and recorded in the PR:

- **Freeze** (default) — the package stays, tags stop moving, and the last
  published image keeps working for anyone still pulling it. It receives no
  further CVE fixes, which the frozen README states in those words.
- **Delete** — for an image with no external consumers, where a broken pull is a
  better signal than a silently stale one.

Freeze is the default because this is a public registry and a deleted tag breaks
builds we cannot see. The honest cost of freezing is a permanently stale image
carrying our vendor label, which is why the README wording is not optional.

### Alternatives considered

- **A one-project bar.** Simpler, and it makes this repo the place any Dockerfile
  goes. The two-project bar exists precisely to make the first project keep its
  own file until reuse is a fact.
- **A three-project bar.** Would have blocked `uv-builder`/`python-distroless`,
  which are the pair the repo is most obviously right about. Two is where
  evidence starts.
- **Deprecation without deletion** (keep building, mark deprecated). It is the
  comfortable choice and it is how sets grow without bound: a deprecated image
  still consumes a rebuild slot, a CVE feed, and a line in every list in §2.

## 5. Non-goals

- **Judging RFCs 0005–0008.** Each carries its own gate. This rule is what those
  gates are measured against; it does not pre-decide them.
- **A governance process.** No proposal template, no review quorum. The bar is a
  factual question with a factual answer.
- **Retroactively justifying the current five.** Applied from here forward.
- **Counting external users.** This repo's images are public, but the bar is
  about Morze projects. External adoption is welcome and is not evidence for
  admission.

## 6. Risks

- **The rule gets applied to the letter and dodged in spirit** — two projects
  acquire a copied Dockerfile specifically to clear the bar. Nothing prevents
  this; it is at least visible in two repositories' histories.
- **The annual review does not happen.** This is the likely failure, and it has
  no technical mitigation. The mitigation is that the review is cheap: five to
  nine yes/no questions once a year, and its output is usually "keep everything".
- **Freeze-by-default leaves stale public images under the Morze vendor label**
  indefinitely (§4.4). Accepted, with the README wording as the whole mitigation.
- **The rule reads as discouraging contribution.** It is aimed at the repo's
  scope, not at anyone's work. The README should carry the reason — a permanent
  maintenance subscription — rather than only the rule.

## 7. Decisions

| # | Grade | Decision |
| --- | --- | --- |
| 1 | `LOCKED` | Two or more projects with the Dockerfile already hand-rolled is the admission bar; anticipated reuse does not count. Consequence: some genuinely good images will be blocked until a second project needs them. |
| 2 | `LOCKED` | An image unused for a year is deleted from the repo, not deprecated in place. Deprecation-without-deletion is explicitly rejected (§4). |
| 3 | `LOCKED` | A builder/runtime pair counts as one admission decision, matching how `uv-builder` and `python-distroless` are already treated. |
| 4 | `ASSUMED` | Freeze rather than delete the published GHCR package on retirement, since a deleted public tag breaks consumers we cannot see. Depart per image where a broken pull is the better signal. |
| 5 | `ASSUMED` | The annual review reads consuming repositories, not GHCR pull counts. Depart if a better usage signal appears — but not toward pull counts, which CI inflates. |
| 6 | `OPEN` | When in the year the review happens and who runs it. An unscheduled annual review is one that does not occur; pick a month and put it in the README with the rule. |
| 7 | ~~`OPEN`~~ **Resolved by the author 2026-08-12** | Decision 1's bar counts hand-rolled Dockerfiles, which structurally excludes configuration-curation images (§3.1). **Resolved by adding a second admission route rather than widening decision 1** — see row 9. Decision 1 stays `LOCKED` and unchanged; it was never wrong, it was answering a different question. |
| 8 | ~~`OPEN`~~ **Resolved by the author 2026-08-12** | Reimplementation of a published image belongs in the annual review, as a question rather than an enforcement — see row 10. |
| 9 | `LOCKED` | **Route 2, drift.** An image is also admitted when two or more projects run the same upstream image without a Dockerfile *and* their pinned versions or configuration have diverged. Route 1 measures duplicated work; route 2 measures the absence of a shared default. Consequence: RFC 0006's gate opens — 14 projects, four pinned images — while RFC 0005's stays shut, since zero projects cannot diverge. That asymmetry is the test working, not a loophole. |
| 10 | `LOCKED` | The annual review asks a second question: **does a live project reimplement an image we already publish?** A hit is treated as feedback about the image, not a violation by the project — the useful output is *why* they did not adopt it. §3.1's `morze-erp-backend-v2` is the worked example: it wants pg_cron without pgroonga, which is a `PG_EXTENSIONS` variant (RFC 0004), not an adoption failure. |

## 8. Phasing

One PR: the two rules and the retirement checklist into
[images/README.md](../images/README.md), and the reason alongside them. Nothing
is blocked on it, and RFCs 0005–0008 are cheaper to argue once it exists.

The predicted outcome of applying this rule to the four candidates — **one image
built, one explicitly refused in the README, two deferred with their gates
written down** — is recorded here as the expectation this RFC was written under.
Four new images would mean the rule was not applied.
