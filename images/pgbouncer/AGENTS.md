<!-- torve:managed images/pgbouncer — rendered from the corpus; do not edit by hand -->

## Decisions governing `images/pgbouncer/`

### S-0002/D-9 — `ASSUMED` (Service images and the drift CI cannot see)

`images/pgbouncer` takes PgBouncer from `edoburu/pgbouncer` at a Renovate-tracked bake tag, starting at v1.26.0-p0, and is tagged with PgBouncer's own version. Its own entrypoint writes `pgbouncer.ini` and a 0600 `userlist.txt` on every start, then execs `pgbouncer`, as uid 70 (S-0003/D-1 drops to it from root when the container starts as root). edoburu's script is not run. The prefix is `PGBOUNCER`, and the curated keys default to what every consumer sets today: `DB_HOST` and `DB_USER` required, `DB_PORT=5432`, `DB_NAME=*`, `DB_PASSWORD` required (with `_FILE`), `LISTEN_PORT=6432`, `AUTH_TYPE=scram-sha-256`, `POOL_MODE=transaction`, `MAX_CLIENT_CONN=1000`, `DEFAULT_POOL_SIZE=30`, `MAX_PREPARED_STATEMENTS=200`, and `ADMIN_USERS` and `STATS_USERS` defaulting to `DB_USER`. `AUTH_TYPE` refuses `trust` and `any`. `min_pool_size=5` and `reserve_pool_size=10` are baked. The image's version label is the version `pgbouncer --version` prints, and its smoke test compares the two.

- Paths: `images/pgbouncer/Dockerfile` `images/pgbouncer/rootfs/**`
- Consequence: a changed environment takes effect on a restart, the password arrives through a file, and a moved upstream tag is caught by the smoke test rather than shipped

### S-0002/D-10 — `ASSUMED` (Service images and the drift CI cannot see)

`PGBOUNCER_CONF__<key>` writes `<key> = <value>` into the `[pgbouncer]` section once the key is on the image's allowlist, in PgBouncer's own spelling. `user`, `auth_file`, `auth_hba_file`, `logfile`, `pidfile` and `unix_socket_dir` are refused, as is a value that starts a new section or `%include`. The renderer is a new mode of `shared/rootfs/lib/envconf.sh` beside `valkeyconf` and `pgconf`, covered by the helper's own suite. The README gives `pg_isready -h 127.0.0.1 -p 6432` as the health check and says it proves PgBouncer answers, not that Postgres does.

- Paths: `shared/rootfs/lib/envconf.sh` `shared/test/**` `images/pgbouncer/README.md`
- Consequence: a consumer reaches PgBouncer's settings by name, and nothing in the environment can rewrite the files PgBouncer reads its users from

### S-0003/D-1 — `ASSUMED` (pgbouncer and rustfs read their secrets as root, then drop to their user) — implementation: none

`images/pgbouncer`'s final `USER` is root. Started as uid 0, its entrypoint reads `PGBOUNCER_DB_PASSWORD_FILE` and writes `/etc/pgbouncer/pgbouncer.ini` and the 0600 `userlist.txt` as it does today, gives both files to 70:70, and execs `setpriv --reuid=70 --regid=70 --clear-groups pgbouncer /etc/pgbouncer/pgbouncer.ini`. Started as any other uid, it behaves exactly as before and execs `pgbouncer` as that uid. PgBouncer never runs as root.

- Paths: `images/pgbouncer/Dockerfile` `images/pgbouncer/rootfs/**`
- Consequence: a password file of any owner at mode 0400 reaches PgBouncer, so one secret can serve the pooler and its clients

### S-0003/D-2 — `ASSUMED` (pgbouncer and rustfs read their secrets as root, then drop to their user) — implementation: none

`images/pgbouncer/smoke.sh` creates its password file inside a throwaway container of the image under test (`--user 0 --entrypoint sh`) on a volume, owned by 65532 at mode 0400. With that file it asserts that a login through 6432 works, that PID 1 runs as uid 70, that `userlist.txt` is 70's at mode 0600, and that the password is absent from the log. It also asserts that a container started with `--user 70` and a world-readable file still works, and that one started with `--user 70` and the 65532-owned file aborts naming the unreadable file.

- Paths: `images/pgbouncer/smoke.sh`
- Consequence: both the root path and the `user:` path are proven on every build, under rootless Podman and under Docker

### S-0003/D-5 — `ASSUMED` (pgbouncer and rustfs read their secrets as root, then drop to their user) — implementation: none

`images/pgbouncer/README.md` says that the container starts as root and drops to uid 70 before PgBouncer starts, that `PGBOUNCER_DB_PASSWORD_FILE` may be owned by any uid, and that a container started with `user:` runs as that user throughout and needs the file readable by it.

- Paths: `images/pgbouncer/README.md`
- Consequence: a consumer learns it can give the password file to its application's user

<!-- /torve:managed -->
