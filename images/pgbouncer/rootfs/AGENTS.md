<!-- torve:managed images/pgbouncer/rootfs — rendered from the corpus; do not edit by hand -->

## Decisions governing `images/pgbouncer/rootfs/`

### S-0002/D-9 — `ASSUMED` (Service images and the drift CI cannot see) — implementation: none

`images/pgbouncer` takes PgBouncer from `edoburu/pgbouncer` at a Renovate-tracked bake tag, starting at v1.26.0-p0, and is tagged with PgBouncer's own version. Its own entrypoint writes `pgbouncer.ini` and a 0600 `userlist.txt` on every start, then execs `pgbouncer`. edoburu's script is not run. The prefix is `PGBOUNCER`, and the curated keys default to what every consumer sets today: `DB_HOST` and `DB_USER` required, `DB_PORT=5432`, `DB_NAME=*`, `DB_PASSWORD` required (with `_FILE`), `LISTEN_PORT=6432`, `AUTH_TYPE=scram-sha-256`, `POOL_MODE=transaction`, `MAX_CLIENT_CONN=1000`, `DEFAULT_POOL_SIZE=30`, `MAX_PREPARED_STATEMENTS=200`, and `ADMIN_USERS` and `STATS_USERS` defaulting to `DB_USER`. `AUTH_TYPE` refuses `trust` and `any`. `min_pool_size=5` and `reserve_pool_size=10` are baked. The image's version label is the version `pgbouncer --version` prints, and its smoke test compares the two.

- Paths: `images/pgbouncer/Dockerfile` `images/pgbouncer/rootfs/**`
- Consequence: a changed environment takes effect on a restart, the password arrives through a file, and a moved upstream tag is caught by the smoke test rather than shipped

<!-- /torve:managed -->
