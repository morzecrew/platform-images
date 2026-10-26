# pgbouncer

`ghcr.io/morzecrew/pgbouncer`

> **This image writes the pooler's configuration, including its credential,
> from the environment on every start.** Upstream's entrypoint writes
> `pgbouncer.ini` only when the file is missing and puts the password in the
> `[databases]` connection string. Here the file is regenerated at every start
> and the password lives in `userlist.txt` alone.

PgBouncer in front of a Postgres, as one container: it takes one user's
credential, pools transactions, and exposes an admin console. The point of the
image is what it refuses — an unrepresentable value, an unsafe auth method, a
setting that would make one of its own promises untrue.

## Tags

| | |
|---|---|
| Image tag and `org.opencontainers.image.version` | PgBouncer's own version, e.g. `1.26.0` |
| Base image | `edoburu/pgbouncer`, e.g. `v1.26.0-p0` |
| Baked by | `PGBOUNCER_VERSION` in [`docker-bake.hcl`](../../docker-bake.hcl), Renovate-tracked |

Edoburu's tag carries both PgBouncer's version and their own `-p<x>` packaging
revision of it. Only the first is the image's version: it is what
`pgbouncer --version` prints, and [`smoke.sh`](smoke.sh) fails the build when
the two disagree.

`EXPOSE` is additive and cannot be removed from a base image, so the metadata
names 5432 (the port edoburu's generated config listens on) alongside 6432.
Nothing listens on 5432.

## Environment

Two channels, per the [shared contract](../../shared/README.md): curated
`PGBOUNCER_*` names below, and `PGBOUNCER_CONF__<setting>` passthrough for
anything in [`rootfs/allowlist.conf`](rootfs/allowlist.conf).

| Variable | Default | Notes |
|---|---|---|
| `PGBOUNCER_DB_HOST` | **required** | The Postgres to pool |
| `PGBOUNCER_DB_USER` | **required** | The user clients authenticate as, and the user the pooler connects as |
| `PGBOUNCER_DB_PASSWORD` | **required** | Visible in `docker inspect`; prefer the `_FILE` form |
| `PGBOUNCER_DB_PASSWORD_FILE` | unset | Wins over `PGBOUNCER_DB_PASSWORD`; unreadable ⇒ startup aborts |
| `PGBOUNCER_DB_PORT` | `5432` | |
| `PGBOUNCER_DB_NAME` | `*` | The `[databases]` key; `*` routes every database name the client asks for |
| `PGBOUNCER_LISTEN_ADDR` | `0.0.0.0` | |
| `PGBOUNCER_LISTEN_PORT` | `6432` | |
| `PGBOUNCER_AUTH_TYPE` | `scram-sha-256` | `trust` and `any` are refused |
| `PGBOUNCER_POOL_MODE` | `transaction` | |
| `PGBOUNCER_MAX_CLIENT_CONN` | `1000` | |
| `PGBOUNCER_DEFAULT_POOL_SIZE` | `30` | Server connections per pool |
| `PGBOUNCER_MAX_PREPARED_STATEMENTS` | `200` | See prepared statements below |
| `PGBOUNCER_ADMIN_USERS` | `PGBOUNCER_DB_USER` | Who may use the admin console |
| `PGBOUNCER_STATS_USERS` | `PGBOUNCER_DB_USER` | |
| `PGBOUNCER_CONF__<setting>` | — | Must be in the allowlist |
| `PGBOUNCER_CONF_STRICT` | `fail` | `ignore` warns instead of aborting on an unknown key |

`min_pool_size` (5) and `reserve_pool_size` (10) are baked with no curated
variable — they are the shape of the pool rather than a knob every consumer
sets — and are reachable through `PGBOUNCER_CONF__min_pool_size` and
`PGBOUNCER_CONF__reserve_pool_size`.

`PGBOUNCER_DB_PASSWORD` is required and there is no default: a pooler with no
password authenticates nobody, and one that guessed the user would log into
Postgres as somebody the operator did not choose.

### The credential

`PGBOUNCER_DB_PASSWORD_FILE` is the safe form and `PGBOUNCER_DB_PASSWORD` is
kept anyway; the startup summary names which of the two was used, including
saying so on the visible path. The value is written to
`/etc/pgbouncer/userlist.txt`, mode 0600, and nowhere else:

- not in `pgbouncer.ini`, because the `[databases]` line names `user=` and lets
  the pooler take that user's password from the auth file;
- not in the log, which redacts it by name;
- not in `docker inspect`, if it came from a file;
- not anywhere else on the container's disk: the entrypoint's working directory
  holds it in the clear in its source map, and that directory is removed before
  the entrypoint hands off to the pooler.

A credential holding a newline or a `"` is refused at startup. Neither can
survive the file's format: a `"` ends a quoted field early, so the stored
password would not be the one given.

## Privileges

The container **starts as root**. Before PgBouncer starts, the entrypoint hands
`pgbouncer.ini` and the 0600 `userlist.txt` to the `postgres` user the base
image provides (uid 70) and drops to it with
`setpriv --reuid=70 --regid=70 --clear-groups`. PgBouncer itself never runs as
root: by the time it listens, PID 1 is uid 70.

Root for those few lines is what lets `PGBOUNCER_DB_PASSWORD_FILE` be **owned by
any uid, at any mode**. Root reads it, the pooler is handed the value in its own
file, and nothing else has to be able to read the secret — so the same file can
be mounted `0400` for the application's own user and shared with the pooler. A
secret owned by a user this image has never heard of is the normal case, not an
exception.

A container started with `user:` takes the other path: it is **that user
throughout**, so it skips the chown and the drop, and it needs the password file
readable by that user. Started `user: 70`, a world-readable file works exactly
as before; a file owned by another uid at 0400 aborts startup, naming
`PGBOUNCER_DB_PASSWORD_FILE`.

## Refusals

Every one of these aborts startup with the reason on stderr, which is where the
runtime collects it.

| Set | Why it is refused |
|---|---|
| `PGBOUNCER_AUTH_TYPE=trust` | Every user in the auth file is admitted without a password |
| `PGBOUNCER_AUTH_TYPE=any` | Every user at all is admitted, including as console administrator |
| `PGBOUNCER_CONF__auth_type=trust` | The allowlisted spelling of the same thing; checked against the assembled file, since PgBouncer takes the last occurrence of a repeated key |
| a value containing `[` | A database name is a key, and a `[` there opens a section |
| a value starting with `%include` | The directive that reads another file into this one |
| a value containing a newline | No ini file can carry one |
| a passthrough key not in the allowlist | Naming the key, so a typo is one line of log rather than a setting that silently does nothing |
| a denylisted key | See below, regardless of the allowlist |
| a curated variable and a passthrough key setting the same thing | Naming both |

The denylist is [`rootfs/denylist.conf`](rootfs/denylist.conf), and each entry
is there for a reason rather than for general caution: `user` (the uid PgBouncer
itself runs as — 70 — which the file modes are sized for),
`auth_file`/`auth_hba_file`/`auth_ident_file` (the credential file the
entrypoint writes), `logfile`/`syslog` (the pod's own log stream), `pidfile`,
`unix_socket_dir` (this container is reached over TCP), and
`peer_id`/`service_name`/`job_name` (peering, which would make one pooler a
member of a cluster).

## Prepared statements, and why `transaction` pooling works

Transaction pooling is what makes a pooler worth running, and it is also what
breaks named prepared statements: a client's statement is prepared on one server
connection and the next transaction may be served by another. PgBouncer tracks
them and re-prepares transparently on whichever connection serves the next
execution, which is exactly what `max_prepared_statements` enables. It is on,
at 200, by default here.

That tracking covers protocol-level named statements, which is what psql 18's
`\parse` and `\bind_named` and every common driver use. SQL-level `PREPARE`,
`EXECUTE` and `DEALLOCATE` are forwarded to Postgres untouched.

## The admin console

Connect to the `pgbouncer` database as a user in `PGBOUNCER_ADMIN_USERS`
(`PGBOUNCER_DB_USER` by default):

```console
$ psql -h 127.0.0.1 -p 6432 -U app -d pgbouncer -c 'SHOW CONFIG' -c 'SHOW POOLS'
```

`SHOW CONFIG` reports what the *running* process is using, so it is the way to
check that a setting arrived rather than assuming it did.

## Health check

```yaml
healthcheck:
  test: ["CMD", "pg_isready", "-h", "127.0.0.1", "-p", "6432"]
  interval: 10s
  timeout: 3s
  retries: 3
```

This proves **PgBouncer answers**. It does not prove Postgres does: the pooler
accepts client connections whether or not its backend is reachable, and a
`pg_isready` against a pooler whose Postgres is down still reports "accepting
connections". For the backend, watch `SHOW POOLS` (`sv_active`, `sv_idle`,
`sv_login`) or query through the pooler.

## Configuration precedence

The environment over the image's defaults, and the startup summary prints which
layer every setting came from:

```text
[envconf] PGBOUNCER: effective configuration
[envconf]   source=baked        db_name = *                                (image default)
[envconf]   source=env          db_host = postgres                         (PGBOUNCER_DB_HOST)
[envconf]   source=baked        db_port = 5432                             (image default)
[envconf]   source=env          db_user = app                              (PGBOUNCER_DB_USER)
[envconf]   source=env          db_password = <redacted>                   (PGBOUNCER_DB_PASSWORD_FILE=/run/secrets/pw)
...
[envconf]   source=baked        pool_mode = transaction                    (image default)
[envconf]   source=baked        admin_users = app                          (PGBOUNCER_DB_USER)
[envconf] precedence: image default < environment
```

`/etc/pgbouncer/pgbouncer.ini` and `/etc/pgbouncer/userlist.txt` are rewritten
on **every** start, so editing them is pointless and a restart always reflects
the current environment. Do not mount anything over `/etc/pgbouncer`: the
allowlist and denylist live there, and a mount that hides them is a container
that cannot start.

## Usage

```yaml
services:
  pgbouncer:
    image: ghcr.io/morzecrew/pgbouncer:1.26.0
    environment:
      PGBOUNCER_DB_HOST: postgres
      PGBOUNCER_DB_USER: app
      PGBOUNCER_DB_PASSWORD_FILE: /run/secrets/db_password
    secrets: [db_password]
    depends_on: [postgres]

  postgres:
    image: postgres:18
    environment:
      POSTGRES_PASSWORD_FILE: /run/secrets/db_password
    secrets: [db_password]

secrets:
  db_password:
    file: ./db_password.txt
```

Both services need the same secret: `secrets:` mounts the file and each
`*_FILE` points its image at it. Without the pooler's line the container exits
78 saying the mount is not there; without Postgres's line, initdb never gets the
password the pooler will present, and the backend container refuses to start at
all — the more legible of the two failures, which is why the example gives both
services the same file rather than only the pooler.