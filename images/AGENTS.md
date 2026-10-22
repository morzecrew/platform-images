<!-- torve:managed images — rendered from the corpus; do not edit by hand -->

## Decisions governing `images/`

### S-0001/D-1 — `ASSUMED` (Standing decisions)

An image is `images/<name>/` holding a `Dockerfile`, a `README.md`, a `smoke.sh` and an optional `rootfs/`, and that directory is its build context. A variant is a bake target over the same directory and shares its `smoke.sh`.

- Paths: `images/*/Dockerfile` `images/*/README.md` `images/*/smoke.sh`
- Consequence: an image is read in one directory, and CI refuses an image with no smoke test

### S-0001/D-2 — `ASSUMED` (Standing decisions)

Admitting an image takes the nine touchpoints `images/README.md` lists. Every target needs a `DESCRIPTIONS` entry, because the bake indexes it directly, and `PACKAGES` and the `default` group are kept in step by hand.

- Paths: `docker-bake.hcl` `.github/workflows/cleanup-images.yaml` `README.md` `images/README.md`
- Consequence: a target with no description fails every bake, and a package missing from `PACKAGES` escapes cleanup

### S-0001/D-3 — `ASSUMED` (Standing decisions)

Versions live in `docker-bake.hcl`, where one variable feeds both an image's tag and its build argument. A Dockerfile's `ARG` default copies the bake value by hand.

- Paths: `docker-bake.hcl` `images/*/Dockerfile`
- Consequence: a version moves in one place for the published image, and a local `docker build` lags until its default is moved too

### S-0001/D-7 — `ASSUMED` (Standing decisions)

Publishing is CI's. `just publish` refuses unless `I_KNOW_THIS_IS_UNGATED=1`, and `just push` only moves a tag that already exists.

- Paths: `justfile` `README.md` `images/README.md`
- Consequence: a local publish cannot skip the smoke gate or the attestations by accident

### S-0001/D-11 — `ASSUMED` (Standing decisions)

A smoke script takes one image reference, exits non-zero on failure and runs under rootless Podman. It reads its expectations from the artifact's labels and manifest, and asserts what must be absent as well as what must be present. A build-stage image is smoked for its toolchain and helpers, not for `--help`. A multi-build battery lives in `test-*.sh`.

- Paths: `images/*/smoke.sh` `images/*/test-*.sh`
- Consequence: a smoke test fails on an image that lies about itself, not only on one that will not start

### S-0001/D-12 — `ASSUMED` (Standing decisions)

Configuration comes through two channels: curated `<PREFIX>_<NAME>` and passthrough `<PREFIX>_CONF__<key>`. An upstream name is never intercepted. caddy has no passthrough, so `CADDY_CONF__*` is reported, and its nine unprefixed names work as aliases with a warning.

- Paths: `shared/rootfs/lib/envconf.sh` `images/*/rootfs/entrypoint.sh` `images/*/README.md`
- Consequence: an operator configures every image the same way, and an upstream variable keeps its upstream meaning

### S-0001/D-13 — `ASSUMED` (Standing decisions)

Passthrough is allowlisted, never denylisted. An unknown key aborts under `_CONF_STRICT=fail`, and a missing allowlist always aborts. The allowlist holds upstream's canonical spelling. An unknown `<PREFIX>_*` name warns, except control names and `_FILE`. postgres keeps `PG_CONF_STRICT_MODE` and `PG_CONF_ALLOWLIST_PATH` beside the contract's names.

- Paths: `images/*/rootfs/allowlist.conf` `images/*/rootfs/denylist.conf` `shared/rootfs/lib/envconf.sh`
- Consequence: a setting no allowlist names never reaches the server's configuration

### S-0001/D-15 — `ASSUMED` (Standing decisions)

Precedence is baked, then mounted, then environment. A startup summary goes to stderr before `exec`: keys printed, values of secret-like keys redacted (`!secret`, and PASSWORD, TOKEN, SECRET, KEY as a segment, HEADERS). `source=` is required only where the layers can be enumerated. postgres prints a fourth layer, `ALTER SYSTEM` (`source=sql`), and caddy prints `image default < environment`.

- Paths: `shared/rootfs/lib/envconf.sh` `images/*/rootfs/entrypoint.sh` `images/postgres/rootfs/conf.d/*`
- Consequence: an operator reads where each setting came from in the container's log, and no secret appears there

### S-0001/D-18 — `ASSUMED` (Standing decisions)

No entrypoint renders configuration through a templating engine; each image uses its server's native expansion.

- Paths: `images/*/rootfs/entrypoint.sh` `images/caddy/rootfs/Caddyfile` `images/caddy/Dockerfile`
- Consequence: configuration is read by the server that owns it, with no second syntax in between

### S-0001/D-25 — `ASSUMED` (Standing decisions)

An image is admitted by route 1, hand-rolled in two or more projects, or route 2, the same upstream run and diverged in two or more; a pair counts once. Refusals are recorded under "Admissions on record". An image unused for a year is deleted, its package frozen by default and kept in `PACKAGES`. The annual workflow opens the review issue on 8 January with a consumer scan.

- Paths: `images/README.md` `.github/workflows/annual-image-review.yaml` `.github/workflows/cleanup-images.yaml`
- Consequence: an image enters and leaves by a rule, not by whoever needs it first

### S-0002/D-4 — `ASSUMED` (Service images and the drift CI cannot see) — implementation: none

`rustfs` is admitted by route 2 and recorded under "Admissions on record" in `images/README.md`. eis-backend and erp-backend both run `rustfs/rustfs:1.0.1`, and they have diverged on its health path and on where its logs go. MinIO, which the erp-standalone bundle and morze-crm-backend still name, no longer publishes an image.

- Paths: `images/README.md`
- Consequence: the projects that store objects have one image to land on, and MinIO's consumers have a destination when they move

### S-0002/D-8 — `ASSUMED` (Service images and the drift CI cannot see) — implementation: none

`pgbouncer` is admitted by route 2 and recorded under "Admissions on record" in `images/README.md`. eis-backend runs `edoburu/pgbouncer:v1.25.1-p0` and erp-backend `v1.26.0-p0`, with byte-identical environment blocks copied between them and into the erp-standalone bundle.

- Paths: `images/README.md`
- Consequence: the three blocks become one image's defaults, and the pool settings change in one place

<!-- /torve:managed -->
