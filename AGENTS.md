<!-- torve:managed root — rendered from the corpus; do not edit by hand -->

## Decisions governing the repository root

### S-0001/D-2 — `ASSUMED` (Standing decisions)

Admitting an image takes the nine touchpoints `images/README.md` lists. Every target needs a `DESCRIPTIONS` entry, because the bake indexes it directly, and `PACKAGES` and the `default` group are kept in step by hand.

- Paths: `docker-bake.hcl` `.github/workflows/cleanup-images.yaml` `README.md` `images/README.md`
- Consequence: a target with no description fails every bake, and a package missing from `PACKAGES` escapes cleanup

### S-0001/D-3 — `ASSUMED` (Standing decisions)

Versions live in `docker-bake.hcl`, where one variable feeds both an image's tag and its build argument. A Dockerfile's `ARG` default copies the bake value under the same `# renovate:` annotation, so one Renovate pull request moves both.

- Paths: `docker-bake.hcl` `images/*/Dockerfile`
- Consequence: a version moves in one place for the published image, and a local `docker build` lags until its default is moved too

### S-0001/D-4 — `ASSUMED` (Standing decisions)

Two tags are published per image: `:<version>`, which moves, and `:<version>-<yyyymmdd>-<run_id>.<run_attempt>`, which does not and exists only when CI sets `BUILD_STAMP`. There is no `latest`, and the docs call the digest the only true pin.

- Paths: `docker-bake.hcl` `.github/workflows/publish.yaml` `README.md`
- Consequence: a consumer can pin a build that never changes, and a local build carries only the moving tag

### S-0001/D-5 — `ASSUMED` (Standing decisions)

Every target inherits `_attested`, written in list form, `attest = ["type=provenance,mode=max", "type=sbom"]`, never in the shorthand. The attestations are described everywhere as unsigned evidence.

- Paths: `docker-bake.hcl` `README.md`
- Consequence: every image carries max-mode provenance and an SBOM, and nobody reads them as a signature

### S-0001/D-7 — `ASSUMED` (Standing decisions)

Publishing is CI's. `just publish` refuses unless `I_KNOW_THIS_IS_UNGATED=1`, and `just push` only moves a tag that already exists.

- Paths: `justfile` `README.md` `images/README.md`
- Consequence: a local publish cannot skip the smoke gate or the attestations by accident

### S-0001/D-9 — `ASSUMED` (Standing decisions)

Every target is built, smoked and published for linux/amd64 and linux/arm64, each on a native runner and never under QEMU; `just publish` forces both.

- Paths: `.github/workflows/publish.yaml` `.github/workflows/bake.yaml` `justfile`
- Consequence: an arm64 host pulls a tested image, and promotion refuses a single-platform index

### S-0001/D-17 — `ASSUMED` (Standing decisions)

`shared/` holds only files two or more images use. They reach an image through the bake's named context `contexts = { shared = "./shared" }`, never by copy. The helper is POSIX sh and runs under busybox, dash and bash.

- Paths: `shared/**` `docker-bake.hcl`
- Consequence: a fix to the shared helper reaches every image that uses it at its next build

### S-0001/D-19 — `ASSUMED` (Standing decisions)

`PG_EXTENSIONS` is checked against the five-column manifest, and an unknown name fails the build. The preload line and the `io.morze.postgres.extensions` label are generated from that one argument, the label in the Dockerfile. A variant is a tag suffix on one package, its set written literally in its target, and there are at most three variants with the default; the unsuffixed tag is cron and pgroonga.

- Paths: `images/postgres/Dockerfile` `images/postgres/rootfs/*extensions*` `images/postgres/test-extensions.sh` `docker-bake.hcl`
- Consequence: an image's extensions are what its label says, and adding one is a manifest line and a target

### S-0001/D-22 — `ASSUMED` (Standing decisions)

One exact-patch `DISTROLESS_PYTHON_VERSION` drives both uv-builder and python-distroless, and uv-builder's tag is the minor.

- Paths: `docker-bake.hcl` `images/uv-builder/Dockerfile` `images/python-distroless/Dockerfile`
- Consequence: an application built on uv-builder runs on the same Python patch in python-distroless

### S-0001/D-23 — `ASSUMED` (Standing decisions)

Versions are tracked only through `# renovate:` annotations directly above a `variable` or `ARG` line in `docker-bake.hcl`, and the same annotation directly above each Dockerfile `ARG` default that copies the value. The dockerfile manager is off except for `docker/dockerfile`, Renovate reads patch tags only, and automerge is on except for Node.

- Paths: `.github/renovate.json` `docker-bake.hcl` `images/*/Dockerfile`
- Consequence: a version without its annotation is invisible to Renovate, and an RC never ships as a release

### S-0002/D-2 — `ASSUMED` (Service images and the drift CI cannot see)

python-distroless is tagged with the minor of `DISTROLESS_PYTHON_VERSION` and with the exact patch, the minor first, as uv-builder is. Its labels keep naming the exact patch.

- Paths: `docker-bake.hcl` `images/python-distroless/README.md`
- Consequence: a consumer pinning `python-distroless:3.14` gets the weekly rebuild again without an edit, and a consumer pinning the patch keeps it

<!-- /torve:managed -->

<!-- torve:managed root index — rendered from the corpus; do not edit by hand -->

## Governed directories

Each of these carries a managed `AGENTS.md` section listing the decisions
and invariants that govern it. `torve spec show S-NNNN/D-n`, `torve spec paths`
`<file>` and `torve spec tests S-NNNN/D-n` read the same corpus from the worktree.

- `images/` — 13 decision(s)
- `images/caddy/` — 2 decision(s)
- `images/caddy/rootfs/` — 3 decision(s)
- `images/flyway/` — 0 decision(s)
- `images/flyway/rootfs/` — 1 decision(s)
- `images/npm-builder/` — 1 decision(s)
- `images/pgbouncer/` — 5 decision(s)
- `images/pgbouncer/rootfs/` — 2 decision(s)
- `images/postgres/` — 1 decision(s)
- `images/postgres/rootfs/` — 2 decision(s)
- `images/postgres/rootfs/conf.d/` — 1 decision(s)
- `images/python-distroless/` — 3 decision(s)
- `images/python-distroless/rootfs/` — 1 decision(s)
- `images/rustfs/` — 5 decision(s)
- `images/rustfs/rootfs/` — 4 decision(s)
- `images/uv-builder/` — 1 decision(s)
- `images/valkey/` — 1 decision(s)
- `images/valkey/rootfs/` — 2 decision(s)
- `rfcs/` — 1 decision(s)
- `shared/` — 1 decision(s)
- `shared/rootfs/lib/` — 6 decision(s)
- `shared/test/` — 1 decision(s)

<!-- /torve:managed -->
