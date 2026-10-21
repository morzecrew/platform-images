<!-- torve:managed shared/rootfs/lib — rendered from the corpus; do not edit by hand -->

## Decisions governing `shared/rootfs/lib/`

### S-0001/D-12 — `ASSUMED` (Standing decisions)

Configuration comes through two channels: curated `<PREFIX>_<NAME>` and passthrough `<PREFIX>_CONF__<key>`. An upstream name is never intercepted. caddy has no passthrough, so `CADDY_CONF__*` is reported, and its nine unprefixed names work as aliases with a warning.

- Paths: `shared/rootfs/lib/envconf.sh` `images/*/rootfs/entrypoint.sh` `images/*/README.md`
- Consequence: an operator configures every image the same way, and an upstream variable keeps its upstream meaning

### S-0001/D-13 — `ASSUMED` (Standing decisions)

Passthrough is allowlisted, never denylisted. An unknown key aborts under `_CONF_STRICT=fail`, and a missing allowlist always aborts. The allowlist holds upstream's canonical spelling. An unknown `<PREFIX>_*` name warns, except control names and `_FILE`. postgres keeps `PG_CONF_STRICT_MODE` and `PG_CONF_ALLOWLIST_PATH` beside the contract's names.

- Paths: `images/*/rootfs/allowlist.conf` `images/*/rootfs/denylist.conf` `shared/rootfs/lib/envconf.sh`
- Consequence: a setting no allowlist names never reaches the server's configuration

### S-0001/D-14 — `ASSUMED` (Standing decisions)

A curated and a passthrough setting for one key, or two spellings of one name, abort startup naming both. The wire format is NUL-delimited and a value with a newline is refused. Values are read through `awk ENVIRON`, never `eval`.

- Paths: `shared/rootfs/lib/envconf.sh` `images/caddy/rootfs/entrypoint.sh` `images/postgres/rootfs/entrypoint.sh` `images/valkey/rootfs/entrypoint.sh`
- Consequence: no value can add configuration it does not name, and no ambiguity is resolved silently

### S-0001/D-15 — `ASSUMED` (Standing decisions)

Precedence is baked, then mounted, then environment. A startup summary goes to stderr before `exec`: keys printed, values of secret-like keys redacted (`!secret`, and PASSWORD, TOKEN, SECRET, KEY as a segment, HEADERS). `source=` is required only where the layers can be enumerated. postgres prints a fourth layer, `ALTER SYSTEM` (`source=sql`), and caddy prints `image default < environment`.

- Paths: `shared/rootfs/lib/envconf.sh` `images/*/rootfs/entrypoint.sh` `images/postgres/rootfs/conf.d/*`
- Consequence: an operator reads where each setting came from in the container's log, and no secret appears there

### S-0001/D-16 — `ASSUMED` (Standing decisions)

`<NAME>_FILE` wins over `<NAME>` for an image-owned or declared name. A file that is missing, unreadable, not regular, over 64 KiB, not UTF-8 or holds a NUL exits 78, naming the variable and the path and never the content, and the file is read once. postgres keeps upstream's handling, and python-distroless resolves only `ENVFILE_NAMES` through the opt-in `envfile-exec`.

- Paths: `shared/rootfs/lib/envconf.sh` `images/flyway/rootfs/entrypoint.sh` `images/valkey/rootfs/entrypoint.sh` `images/python-distroless/rootfs/envfile-exec`
- Consequence: a secret mounted as a file is read safely or the container refuses to start

### S-0002/D-10 — `ASSUMED` (Service images and the drift CI cannot see) — implementation: none

`PGBOUNCER_CONF__<key>` writes `<key> = <value>` into the `[pgbouncer]` section once the key is on the image's allowlist, in PgBouncer's own spelling. `user`, `auth_file`, `auth_hba_file`, `logfile`, `pidfile` and `unix_socket_dir` are refused, as is a value that starts a new section or `%include`. The renderer is a new mode of `shared/rootfs/lib/envconf.sh` beside `valkeyconf` and `pgconf`, covered by the helper's own suite. The README gives `pg_isready -h 127.0.0.1 -p 6432` as the health check and says it proves PgBouncer answers, not that Postgres does.

- Paths: `shared/rootfs/lib/envconf.sh` `shared/test/**` `images/pgbouncer/README.md`
- Consequence: a consumer reaches PgBouncer's settings by name, and nothing in the environment can rewrite the files PgBouncer reads its users from

<!-- /torve:managed -->
