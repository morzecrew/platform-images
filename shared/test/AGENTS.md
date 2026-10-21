<!-- torve:managed shared/test — rendered from the corpus; do not edit by hand -->

## Decisions governing `shared/test/`

### S-0002/D-10 — `ASSUMED` (Service images and the drift CI cannot see) — implementation: none

`PGBOUNCER_CONF__<key>` writes `<key> = <value>` into the `[pgbouncer]` section once the key is on the image's allowlist, in PgBouncer's own spelling. `user`, `auth_file`, `auth_hba_file`, `logfile`, `pidfile` and `unix_socket_dir` are refused, as is a value that starts a new section or `%include`. The renderer is a new mode of `shared/rootfs/lib/envconf.sh` beside `valkeyconf` and `pgconf`, covered by the helper's own suite. The README gives `pg_isready -h 127.0.0.1 -p 6432` as the health check and says it proves PgBouncer answers, not that Postgres does.

- Paths: `shared/rootfs/lib/envconf.sh` `shared/test/**` `images/pgbouncer/README.md`
- Consequence: a consumer reaches PgBouncer's settings by name, and nothing in the environment can rewrite the files PgBouncer reads its users from

<!-- /torve:managed -->
