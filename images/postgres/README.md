# PostgreSQL images

Custom PostgreSQL Docker images for the Morze platform. Based on official `postgres` with **pg_cron** and **pgroonga** (PostgreSQL + full-text search).

## Contents

- **PostgreSQL 18** (variant `18-cron-pgroonga`) with:
  - [pg_cron](https://github.com/citusdata/pg_cron) — cron-style job scheduling inside Postgres
  - [pgroonga](https://pgroonga.github.io/) — full-text search via Groonga
- Base config in the image (`postgres.conf`) plus **allowlist-based overrides** via environment variables.

## Building

Build from the **repo root** with [just](https://github.com/casey/just):

```bash
just build -t postgres -v 18-cron-pgroonga
```

Image: `ghcr.io/morzecrew/postgres:18-cron-pgroonga`.

Optional: `--push` to push after build, or run `just push -t postgres -v 18-cron-pgroonga` separately.

## Configuration overrides

The image uses a custom entrypoint (`entrypoint-merge.sh`) that:

1. Reads an **allowlist** of PostgreSQL parameter names from `/etc/postgresql/allowlist.conf` (built from `allowlists/base.conf` and version-specific `allowlists/18.conf`).
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

- `18-cron-pgroonga/` — PostgreSQL 18 + cron + pgroonga: `Dockerfile`, `postgres.conf`, `entrypoint-merge.sh`
- `allowlists/` — `base.conf` (shared allowed params) and `18.conf` (version-specific)
