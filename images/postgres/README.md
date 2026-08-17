# PostgreSQL images

Custom PostgreSQL Docker images for the Morze platform. Based on official `postgres` with **pg_cron** and **pgroonga** (PostgreSQL + full-text search).

## Contents

Every tag is the same PostgreSQL, the same base config
(`rootfs/postgresql.conf`) and the same **allowlist-based overrides** via
environment variables. They differ only in which extensions are installed, and
each image records its own set in the `io.morze.postgres.extensions` label:

| Tag | Extensions | For |
|---|---|---|
| `18.6` | pg_cron, pgroonga | The default. Unchanged meaning since before variants existed — pinning it gets you both, as it always did. |
| `18.6-pgvector` | pg_cron, pgroonga, **pgvector** | Vector search *as well as* cron and full-text, which no single image offered before: the choice used to be this image or `pgvector/pgvector`. |
| `18.6-cron` | pg_cron | Cron without pgroonga, for a service that was paying for the groonga apt source, package and image size to get scheduling. |

- [pg_cron](https://github.com/citusdata/pg_cron) — cron-style job scheduling inside Postgres
- [pgroonga](https://pgroonga.github.io/) — full-text search via Groonga
- [pgvector](https://github.com/pgvector/pgvector) — vector similarity search; `CREATE EXTENSION vector`

`pg_stat_statements` is in every tag and is not listed in the label: it ships
with the server rather than being selected (RFC 0004 decision 10).

Which extensions are selectable is [`rootfs/extensions.manifest`](./rootfs/extensions.manifest),
and a name absent from it fails the build rather than quietly producing a smaller
image. Three variants including the default is the ceiling (RFC 0004 decision 7)
— each is a full uncached rebuild every week, so a fourth request is a
conversation, not a line.

`POSTGRES_VERSION` in [`docker-bake.hcl`](../../docker-bake.hcl) sets the registry tag and `POSTGRES_IMAGE_TAG` in [`Dockerfile`](./Dockerfile).

## Building

From the repo root (see [images/README.md](../README.md)):

```bash
just bake postgres            # the default set
just bake postgres-pgvector   # one variant
just bake                     # every image, variants included
```

Images: `ghcr.io/morzecrew/postgres:18.6`, `:18.6-pgvector`, `:18.6-cron`.

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

`PG_CONF_STRICT` and `PG_CONF_ALLOWLIST` are accepted as aliases for the two
control variables above, because they are the names the shared contract uses and
the ones the helper's own messages name (RFC 0001 decision 10 keeps the longer
spellings as this image's published surface). Setting both spellings of one
control to **different** values refuses at startup rather than picking a winner.

Some parameters are **denylisted** and cannot be set through `PG_CONF__*` in
either strict mode. The list is `/etc/postgresql/denylist.conf` in the image
(`rootfs/denylist.conf` in this directory), which is also where the reasoning
per group lives; it covers the generated preload line, the include and file-path
settings this image's precedence rule depends on, the SQL-compatibility
switches, and `allow_alter_system`.

### The startup summary

Before the server starts, the entrypoint prints every setting any layer assigns,
with the layer that supplied it, to **stderr**:

```text
[envconf] postgres: effective non-default settings
[envconf]   source=baked        shared_buffers = 1GB                 (/etc/postgresql.conf)
[envconf]   source=baked        pg_stat_statements.max = 10000       (/etc/postgresql/conf.d/11-pg_stat_statements.conf)
[envconf]   source=mounted      temp_buffers = 12MB                  (/etc/postgresql/conf.d/50-tuning.conf)
[envconf]   source=env          work_mem = 64MB                      (PG_CONF__work_mem)
[envconf] precedence: baked < mounted < env
```

One row per setting: where a key is set by more than one layer, the row is the
value the server will use and the layer it came from. `source=baked` covers both
the bundled `postgresql.conf` and the fragments this image ships in `conf.d`;
`source=mounted` is anything else found there, which is how a fragment you
mounted is distinguished from one the build installed.

A `PG_*` variable that is neither a `PG_CONF__*` override nor one of the controls
above produces a warning naming it — a misspelled override that silently does
nothing is the failure this is here to prevent.

Two names are excluded because the base image sets them on every start:
`PG_MAJOR` and `PG_VERSION`. They belong to upstream, this image never reads
them as configuration, and a warning that fires on every container is how an
operator learns to ignore all of them. `PGDATA` is also upstream's and never
matches in the first place — the prefix checked is `PG_`, with the underscore.

## Layout

- `Dockerfile` — image build
- `rootfs/postgresql.conf` — bundled server config
- `rootfs/entrypoint.sh` — allowlist merge entrypoint
- `rootfs/allowlist.conf` — parameter names allowed for `PG_CONF__*` env overrides (also copied to `/etc/postgresql/allowlist.conf`)
