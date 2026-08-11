# Morze :: Platform Images

Docker definitions for сommon platform images. This repo holds Dockerfiles and config used to build and publish images to [ghcr.io/morzecrew](https://ghcr.io/morzecrew).

## Layout

Every image lives under `images/<name>/` with the **same shape**: a `Dockerfile` at the root of that folder, optional **`rootfs/`** for files that are copied into the image, and a `README.md`. See [images/README.md](./images/README.md) for the full convention.

Tags and build arguments are declared once in **[`docker-bake.hcl`](./docker-bake.hcl)**.

## Building

From the **repo root**. Requires [just](https://github.com/casey/just) and [Docker Buildx](https://docs.docker.com/build/).

```bash
just bake                 # all images (default group)
just bake postgres        # single image
just publish              # build + push everything (uses gh auth)
just push postgres 18.4
just push uv-builder 3.14
```

Pushing uses `gh auth token` for registry login to `ghcr.io`.

Tags follow bake defaults. The image name carries what is inside; bake variables set both the tag and matching build-args.

## Images

| Directory | Description |
|-----------|-------------|
| [postgres](./images/postgres) | PostgreSQL with pg_cron and pgroonga, allowlist-based config overrides via env. |
| [caddy](./images/caddy) | Caddy with Coraza WAF and OWASP CRS; env-templated base, `CONFIG_DIR` / `SERVERS_DIR`, top-level snippet imports (`BUILTIN_SNIPPETS_DIR`, `SNIPPET_DEFS_DIR`). |
| [flyway](./images/flyway) | Flyway with essential JDBC drivers, pinned versions. |
| [uv-builder](./images/uv-builder) | uv-based Python build stage: sync, wheel, slim venv (`build-uv-app`). |
| [python-distroless](./images/python-distroless) | Distroless Python runtime with libmagic and CA bundle for small final images. |

## License

[MIT](./LICENSE) © Morze Technologies
