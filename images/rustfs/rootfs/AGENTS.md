<!-- torve:managed images/rustfs/rootfs — rendered from the corpus; do not edit by hand -->

## Decisions governing `images/rustfs/rootfs/`

### S-0002/D-5 — `ASSUMED` (Service images and the drift CI cannot see)

`images/rustfs` builds `FROM rustfs/rustfs:${RUSTFS_VERSION}`, a Renovate-tracked bake variable starting at 1.0.1, and its tag is that version. Its entrypoint sources the shared helper, exports what it decides and then execs upstream's `/entrypoint.sh`, which keeps creating the data directories; the server runs as uid 10001, dropped to from root by S-0003/D-3 when the container starts as root. Upstream owns every `RUSTFS_*` name, so the curated keys are upstream names whose defaults the image changes: `RUSTFS_CONSOLE_ENABLE=false`, `RUSTFS_OBS_LOG_DIRECTORY` empty so the server logs to stdout, and `RUSTFS_ADDRESS=:9000`.

- Paths: `images/rustfs/Dockerfile` `images/rustfs/rootfs/**`
- Consequence: nothing listens on the console port unless a consumer asks, and the server's log is in `docker logs`

### S-0002/D-6 — `ASSUMED` (Service images and the drift CI cannot see)

`RUSTFS_ACCESS_KEY` and `RUSTFS_SECRET_KEY` are required, each through its value or upstream's own `_FILE`. Startup aborts when either is missing, empty or upstream's built-in `rustfsadmin`. Upstream's refusal of a value and its file set together stands. `RUSTFS_ROOT_*` and `MINIO_ROOT_*` credentials are refused, and the secret never reaches the startup summary.

- Paths: `images/rustfs/rootfs/**`
- Consequence: a deployment cannot start on a default credential, and there is one place a credential comes from

### S-0002/D-7 — `ASSUMED` (Service images and the drift CI cannot see)

`RUSTFS_CONF__<KEY>` exports `RUSTFS_<KEY>` once the key is on the image's allowlist. `VOLUMES`, the credential names and the unsafe switches (`TLS_KEYLOG`, `UNSAFE_BYPASS_DISK_CHECK`, `KMS_ALLOW_INSECURE_DEV_DEFAULTS`) are refused. The image creates no bucket, and its README gives `/health/ready` as the compose health check.

- Paths: `images/rustfs/rootfs/**` `images/rustfs/README.md`
- Consequence: a consumer can reach upstream's settings by name, and cannot reach the ones that move its data or weaken it

### S-0003/D-3 — `ASSUMED` (pgbouncer and rustfs read their secrets as root, then drop to their user) — implementation: none

`images/rustfs`'s final `USER` is root. Started as uid 0, its entrypoint resolves and checks both credentials as it does today, refuses a credential set both as a value and as `_FILE` before anything is exported, as upstream would, exports `RUSTFS_ACCESS_KEY` and `RUSTFS_SECRET_KEY` as each `_FILE`'s content reads to upstream's script (its first line, with carriage returns removed and surrounding whitespace trimmed), unsets `RUSTFS_ACCESS_KEY_FILE` and `RUSTFS_SECRET_KEY_FILE`, and execs `setpriv --reuid=10001 --regid=10001 --clear-groups /entrypoint.sh rustfs` with the container's arguments. Started as any other uid, it behaves exactly as before. The server never runs as root.

- Paths: `images/rustfs/Dockerfile` `images/rustfs/rootfs/**`
- Consequence: a credential file of any owner at mode 0400 reaches RustFS, and upstream's script and the server run as uid 10001 as before

<!-- /torve:managed -->
