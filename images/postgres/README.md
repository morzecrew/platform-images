# PostgreSQL images

Custom PostgreSQL Docker images for the Morze platform. Based on official `postgres` with **pg_cron** and **pgroonga** (PostgreSQL + full-text search).

## Contents

- **PostgreSQL 18** (tag `18`) with:
  - [pg_cron](https://github.com/citusdata/pg_cron) — cron-style job scheduling inside Postgres
  - [pgroonga](https://pgroonga.github.io/) — full-text search via Groonga
- Base config in the image (`rootfs/postgresql.conf`) plus **allowlist-based overrides** via environment variables.

`PG_MAJOR` drives the registry tag; `POSTGRES_IMAGE_TAG` pins the upstream `postgres` image (e.g. `18.1`). Both are **build args** in [`docker-bake.hcl`](../../docker-bake.hcl) and [`Dockerfile`](./Dockerfile).

## Building

From the repo root (see [images/README.md](../README.md)):

```bash
just bake postgres
```

Image: `ghcr.io/morzecrew/postgres:18`.

## Configuration overrides

The image uses a custom entrypoint (`rootfs/entrypoint.sh` → `/usr/local/bin/entrypoint-merge.sh`) that:

1. Reads an **allowlist** of PostgreSQL parameter names from `/etc/postgresql/allowlist.conf` (copied from `rootfs/allowlist.conf` in the image).
2. Scans the environment for variables named `PG_CONF__<param>` (e.g. `PG_CONF__shared_buffers`, `PG_CONF__work_mem`). Names are normalized (case-insensitive, dashes → underscores).
3. Writes allowed overrides to `/etc/postgresql/conf.d/99-overrides.conf` and starts Postgres with the official entrypoint, so the main config plus overrides are applied.

### Environment variables

| Variable | Default | Description |
|----------|---------|-------------|
| `PG_CONF__<param>` | — | Override a Postgres setting. Param must be in the allowlist. Example: `PG_CONF__shared_buffers=256MB`. |
| `PG_CONF_ALLOWLIST_PATH` | `/etc/postgresql/allowlist.conf` | Path to the allowlist file (e.g. if you mount your own). |
| `PG_CONF_STRICT_MODE` | `fail` | `fail` = container fails to start if an override is not in the allowlist; `ignore` = skip with a warning. |

Some parameters are **denylisted** (e.g. `shared_preload_libraries`, `data_directory`, `config_file`, `allow_alter_system`) and cannot be overridden via env for safety and consistency.

## Layout

- `Dockerfile` — image build
- `rootfs/postgresql.conf` — bundled server config
- `rootfs/entrypoint.sh` — allowlist merge entrypoint
- `rootfs/allowlist.conf` — parameter names allowed for `PG_CONF__*` env overrides (also copied to `/etc/postgresql/allowlist.conf`)
