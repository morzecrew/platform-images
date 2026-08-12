# Image layout

Every image under `images/<name>/` follows the same rules:

| Path | Purpose |
|------|---------|
| `Dockerfile` | Build definition; build context is always this directory (`images/<name>/`). |
| `README.md` | What the image is for and how to configure it at runtime. |
| `rootfs/` | Optional. Static files that are `COPY`’d into the image (configs, scripts, bundled assets). Omit when the Dockerfile has nothing to copy besides layers (e.g. Flyway). |

**Registry names** match the directory name under `images/` (e.g. `postgres`, `caddy`, `flyway`, `uv-builder`, `python-distroless`). **Tags** are version strings from bake variables (e.g. `18.4`, `2.11.3`, `12.7`, `3.14`, `3.14.5`); the same variables usually feed both `tags` and `args` in [`docker-bake.hcl`](../docker-bake.hcl). Distroless Python tags must remain valid for upstream `al3xos` bases (see [python-distroless](./python-distroless/README.md)).

Build from the **repository root**:

```bash
just bake               # all images
just bake flyway        # one target
just publish            # build + push (requires gh auth)
just push postgres 18   # push an already-built local tag
```

`just` is a thin wrapper around `docker buildx bake -f docker-bake.hcl` (`just push` uses `docker push` separately).

## Which images belong here

> **Admission.** An image lands here when the same Dockerfile has been
> hand-rolled in **two or more** projects. One project keeps its own Dockerfile.
>
> **Retirement.** An image that no project has used for a year is deleted, not
> maintained.

The reason is cost, not taste. Every image is a permanent subscription to
somebody else's CVE feed, and adding one is nine edits, not one:

| # | Touchpoint |
|---|---|
| 1 | `images/<name>/` — `Dockerfile`, `README.md`, optional `rootfs/` |
| 2 | Version variable with its Renovate annotation in [`docker-bake.hcl`](../docker-bake.hcl) |
| 3 | Bake target with `tag()` / `label()` / args, inheriting `_attested` |
| 4 | `default` group membership |
| 5 | `PACKAGES` in [`cleanup-images.yaml`](../.github/workflows/cleanup-images.yaml) |
| 6 | Images table row in the [root README](../README.md) |
| 7 | A `DESCRIPTIONS` entry in [`docker-bake.hcl`](../docker-bake.hcl) |
| 8 | Env-config allowlist and README section — *once RFC 0001 ships* |
| 9 | `smoke.sh` — *once RFC 0002 P3 ships* |

**Items 4, 5 and 7 fail silently.** A missing `default` entry means the image is
never built by `just bake`; a missing `PACKAGES` entry means its untagged
versions accumulate in GHCR forever; a missing `DESCRIPTIONS` entry publishes an
empty `org.opencontainers.image.description` rather than raising. None of the
three produces a red check.

Items 8 and 9 have no mechanism yet — they are listed so the cost is visible, not
because there is something to fill in today.

Two clarifications that keep admission from being argued away:

- **"Hand-rolled in two projects" means the Dockerfiles exist**, not that two
  projects would benefit. Anticipated reuse is the failure this bar catches — it
  is how a repo acquires images maintained for nobody.
- **A pair counts as one admission.** `uv-builder` + `python-distroless` are one
  decision about Python, not two about images.

### The annual review

Once a year, each image is checked against one question: **does a live project
reference this tag?** The answer comes from consuming repositories, not from GHCR
pull counts — a scheduled CI job pulling an image is a pull count, not a user.

Outcomes are keep or retire. There is no "keep for now"; that is the state that
produces images nobody has used since 2024. An image whose only consumer is this
repo is retired even if it builds cleanly.

### Retiring an image

Deletion has to be mechanical or it will not happen:

1. Announce in the image's README that the tag is frozen, with a date.
2. Remove the bake target, its variable, its `default` group entry, and its
   `DESCRIPTIONS` row — the last is not optional bookkeeping: `DESCRIPTIONS` is
   indexed directly, so a stale row is harmless but a missing one fails every
   bake invocation, and leaving retirement half-done here is how the map drifts
   out of step with the targets.
3. Remove the row from the root README images table.
4. Delete `images/<name>/`.
5. **Leave `<name>` in `PACKAGES`** — the published package still exists and its
   untagged children still need collecting. Remove it only if the package itself
   is deleted.
6. Decide the published package's fate explicitly, below.

Steps 2–4 are one PR. Git history keeps the Dockerfile, so retirement costs
nothing irreversible — which is the argument that makes it easy to agree to.

**The published GHCR package** does not disappear with the directory. Choose per
image and record it in the PR:

- **Freeze** (default) — the package stays, tags stop moving, the last published
  image keeps working. It receives no further CVE fixes, and the frozen README
  says so in those words.
- **Delete** — for an image with no external consumers, where a broken pull is a
  better signal than a silently stale one.

Freeze is the default because this is a public registry and a deleted tag breaks
builds we cannot see.

See [RFC 0003](../rfcs/0003-image-admission-and-retirement-rule.md) for the
reasoning, the alternatives, and a known limitation of the bar.
