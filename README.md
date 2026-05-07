# Morze :: Platform Images

Docker image definitions for the Morze platform. This repo holds Dockerfiles and config used to build and publish images to [ghcr.io/morzecrew](https://ghcr.io/morzecrew).

## Layout

Every image lives under `images/<name>/` with the **same shape**: a `Dockerfile` at the root of that folder, optional **`rootfs/`** for files that are copied into the image, and a `README.md`. See [images/README.md](./images/README.md) for the full convention.

Tags and build arguments are declared once in **[`docker-bake.hcl`](./docker-bake.hcl)**.

## Building

From the **repo root**. Requires [just](https://github.com/casey/just) and [Docker Buildx](https://docs.docker.com/build/).

```bash
just bake                 # all images (default group)
just bake postgres        # single image
just publish              # build + push everything (uses gh auth)
just push postgres 18
just push uv-builder 3.14
```

Equivalent without `just`:

```bash
docker buildx bake -f docker-bake.hcl
docker buildx bake -f docker-bake.hcl postgres
docker buildx bake -f docker-bake.hcl --push
```

Pushing uses `gh auth token` for registry login to `ghcr.io`.

**Tags** are short version identifiers where it fits (`postgres:18`, `caddy:2.11`, `flyway:12.5`, `uv-builder:3.14`, `python-distroless:3.14`). The image name carries *what* is inside; bake variables set both the tag and matching build-args (Bake cannot read Dockerfile `ARG` defaults for tags—you wire both from the same `variable` blocks in [`docker-bake.hcl`](./docker-bake.hcl)). For `python-distroless`, **`PYTHON_VERSION` in bake must match an existing `al3xos/python-distroless` tag** (`${PYTHON_VERSION}-debian${DISTROLESS_DEBIAN_VERSION}`), and the same value becomes your GHCR tag. Docker Hub often uses full `x.y.z` for `PYTHON_VERSION`; bump it in bake whenever the upstream tag you need changes.

## Images

| Directory | Description |
|-----------|-------------|
| [postgres](./images/postgres) | PostgreSQL with pg_cron and pgroonga, allowlist-based config overrides via env. |
| [caddy](./images/caddy) | Caddy with Coraza WAF and OWASP CRS; base config via env, optional `import /etc/caddy/config/*.caddy`. |
| [flyway](./images/flyway) | Flyway with essential JDBC drivers, pinned versions. |
| [uv-builder](./images/uv-builder) | uv-based Python build stage: sync, wheel, slim venv (`build-uv-app`). |
| [python-distroless](./images/python-distroless) | Distroless Python runtime with libmagic and CA bundle for small final images. |

Each image README documents usage; platform services focus on runtime env, builder/runtime pair on multi-stage workflows.
