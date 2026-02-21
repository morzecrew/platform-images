# Morze :: Platform Images

Docker image definitions for the Morze platform. This repo holds Dockerfiles and config used to build and publish images to [ghcr.io/morzecrew](https://ghcr.io/morzecrew).

## Building

Requires [just](https://github.com/casey/just). Builds and pushes are run from the **repo root**.

```bash
# Build an image (target = directory under images/, version = subdir with Dockerfile)
just build -t postgres -v 18-cron-pgroonga

# Build and push
just build -t postgres -v 18-cron-pgroonga --push

# Push only (after building)
just push -t postgres -v 18-cron-pgroonga
```

Pushing uses `gh auth token` for registry login to `ghcr.io`.

## Images

| Target | Description |
|--------|-------------|
| [postgres](./images/postgres) | PostgreSQL with pg_cron and pgroonga, allowlist-based config overrides via env. |

See [images/postgres/README.md](./images/postgres/README.md) for details on the postgres image and configuration.
