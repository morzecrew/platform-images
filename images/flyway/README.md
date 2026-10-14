# Flyway images

[Flyway](https://documentation.red-gate.com/flyway/) base images with **PostgreSQL** and **ClickHouse** JDBC drivers pre-installed next to Flyway so migrations can reach those backends without mounting drivers yourself.

## Contents

**Tag `12.7`** — extends `flyway/flyway:12.7-alpine` with pinned drivers:

- PostgreSQL JDBC (42.7.11) under `/flyway/drivers/`
- ClickHouse JDBC (0.9.8, `*-all.jar`) under `/flyway/drivers/`

`FLYWAY_VERSION` and driver versions are **build args** in [`Dockerfile`](./Dockerfile) and [`docker-bake.hcl`](../../docker-bake.hcl).

## Secrets from files

Flyway reads `FLYWAY_URL`, `FLYWAY_USER` and `FLYWAY_PASSWORD` from the
environment and has no `_FILE` variant of its own. The image's entrypoint adds
one for those three, following the repo's [secrets rule](../README.md#secrets):
`FLYWAY_PASSWORD_FILE=/run/secrets/db_password` sets `FLYWAY_PASSWORD` to the
file's content (one trailing newline stripped), wins over a plain
`FLYWAY_PASSWORD`, and is removed before Flyway starts. A missing, unreadable or
non-regular file aborts with exit 1 and a message naming the variable; it never
falls back to the plain value.

Every argument goes to `flyway` unchanged, and `CMD` is upstream's `-?`, so
`migrate`, `info` and the rest work as they do on the official image. One line
per resolved name goes to stderr:

```text
[envfile] FLYWAY_PASSWORD <- FLYWAY_PASSWORD_FILE=/run/secrets/db_password
```

## Building

From the repo root (see [images/README.md](../README.md)):

```bash
just bake flyway
```

Image: `ghcr.io/morzecrew/flyway:12.7`.

## Layout

- `Dockerfile` — extends official Alpine Flyway and downloads drivers into `/flyway/drivers`
- `rootfs/entrypoint.sh` — resolves the `_FILE` secrets with the shared [`envconf.sh`](../../shared/rootfs/lib/envconf.sh), then `exec flyway "$@"`
