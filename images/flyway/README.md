# Flyway images

[Flyway](https://documentation.red-gate.com/flyway/) base images with **PostgreSQL** and **ClickHouse** JDBC drivers pre-installed next to Flyway so migrations can reach those backends without mounting drivers yourself.

## Variants

- **`12.5-essentials`** — `flyway/flyway:12.5-alpine` plus pinned drivers:
  - PostgreSQL JDBC (42.7.11) under `/flyway/drivers/`
  - ClickHouse JDBC (0.9.8, `*-all.jar`) under `/flyway/drivers/`

## Building

From the repo root with [just](https://github.com/casey/just):

```bash
just build -t flyway -v 12.5-essentials
```

Image: `ghcr.io/morzecrew/flyway:12.5-essentials`.

Use `--push` to push after build, or run `just push -t flyway -v 12.5-essentials` separately.

## Layout

- `12.5-essentials/Dockerfile` — extends official Alpine Flyway image and downloads drivers into `/flyway/drivers`
