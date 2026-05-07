# Flyway images

[Flyway](https://documentation.red-gate.com/flyway/) base images with **PostgreSQL** and **ClickHouse** JDBC drivers pre-installed next to Flyway so migrations can reach those backends without mounting drivers yourself.

## Contents

**Tag `12.5`** — extends `flyway/flyway:12.5-alpine` with pinned drivers:

- PostgreSQL JDBC (42.7.11) under `/flyway/drivers/`
- ClickHouse JDBC (0.9.8, `*-all.jar`) under `/flyway/drivers/`

`FLYWAY_VERSION` and driver versions are **build args** in [`Dockerfile`](./Dockerfile), defaults aligned with bake.

## Building

This image has no `rootfs/` overlay; the `Dockerfile` only adds driver JARs on top of the official image.

From the repo root (see [images/README.md](../README.md)):

```bash
just bake flyway
```

Image: `ghcr.io/morzecrew/flyway:12.5`.

## Layout

- `Dockerfile` — extends official Alpine Flyway and downloads drivers into `/flyway/drivers`
