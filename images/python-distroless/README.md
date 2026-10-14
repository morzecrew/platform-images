# python-distroless images

Minimal **runtime** image for Python workloads: [`al3xos/python-distroless`](https://hub.docker.com/r/al3xos/python-distroless) on Docker Hub as the main stage, plus a thin set of libraries copied from **`debian:bookworm-slim`** so common stacks (e.g. **python-magic** / **libmagic**) keep working without a full glibc dev tree.

## Contents

**Tag `3.14.8`** — distroless Python on `al3xos/python-distroless`, with libmagic, CA certs, and common runtime libs from bookworm.

- Intended as the **final stage** after a builder such as [`uv-builder`](../uv-builder): copy `/opt/venv` from the build stage and set `PATH` to the venv’s `bin` if you run your app as the main process.
- **User** `65532:65532` by default (overridable via **`APP_UID`** / **`APP_GID`** build args).
- **Environment** `LANG` / `LC_ALL` `C.UTF-8`, `TZ=UTC`, `PYTHONUNBUFFERED=1`, `PYTHONFAULTHANDLER=1`, plus **`APP_RUNTIME_DIR`**, **`APP_TMP_DIR`** (defaults `/srv/runtime` and `/srv/runtime/tmp`).
- **Writable temp**: `TMPDIR` is **`APP_TMP_DIR`** (default `/srv/runtime/tmp`); `XDG_CACHE_HOME` is `${TMPDIR}/.cache`. Mount a volume over those paths if you need a writable layer at runtime.
- Bundled from bookworm: updated CA certs, **`libmagic.so.1`** and **`magic.mgc`**, plus **`libbz2`**, **`liblzma`**, **`libz`**. **`LD_LIBRARY_PATH=/usr/lib`** is set so these libs resolve.

Published for `linux/amd64` and `linux/arm64`. `DISTROLESS_PYTHON_VERSION` in [`docker-bake.hcl`](../../docker-bake.hcl) sets the registry tag and `PYTHON_VERSION` in [`Dockerfile`](./Dockerfile), and is also the Python [`uv-builder`](../uv-builder) builds on, so the pair is one CPython build per platform. `DEBIAN_VERSION` comes from bake’s `DISTROLESS_DEBIAN_VERSION`. They must resolve to a real tag on **`al3xos/python-distroless`**: `FROM al3xos/python-distroless:${PYTHON_VERSION}-debian${DEBIAN_VERSION}` (e.g. `3.14.8-debian13`), and `python:${PYTHON_VERSION}-trixie` must exist for uv-builder. The value must be an exact patch; bake refuses a bare minor.

## Secrets from files: `envfile-exec`

Deployments hand secrets over as files (morzer, Compose `secrets:`, Kubernetes
secret volumes); applications read environment variables. There is no shell
here to bridge the two, so the image ships a launcher that does it,
`/usr/local/bin/envfile-exec`. It is **opt-in**: the entrypoint stays
upstream's `python`, and an application image puts the launcher in front of its
own command:

```dockerfile
ENV ENVFILE_NAMES="POSTGRES__PASSWORD AUTH__ACCESS_SECRET_KEY_B64"
ENTRYPOINT ["/usr/local/bin/envfile-exec", "/opt/venv/bin/app"]
```

For each name in `ENVFILE_NAMES` (whitespace- or comma-separated) whose
`<NAME>_FILE` is set and non-empty, it reads the file, sets `<NAME>` to the
content with exactly one trailing newline stripped, removes `<NAME>_FILE`, and
then `exec`s the command, so the application is PID 1, gets the signals and owns
the exit code.

- **Only declared names.** `SSL_CERT_FILE`, `AWS_CONFIG_FILE`,
  `AWS_WEB_IDENTITY_TOKEN_FILE` and the like are paths and stay paths. That is
  why the names are declared rather than every `*_FILE` being expanded. An
  operator can extend `ENVFILE_NAMES` at run time; like the
  [allowlist](../README.md#allowlist-never-denylist), it is a guard rail, not a
  security boundary.
- **The file wins** over a plain `<NAME>`, and a plain `<NAME>` with no
  `_FILE` passes through untouched, which is how local development keeps
  working.
- **Symlinks are followed**, so Kubernetes' `..data` layout works. An empty file
  gives an empty value; refusing one is the application's call.
- **Isolated:** `python3 -IS`, stdlib only, not the application's venv, so
  nothing the application sets can change it. It costs one interpreter start:
  11 to 15 ms on CI's amd64 and arm64 runners.

One line per resolved name goes to stderr, never a value. Nothing is printed
when nothing was resolved:

```text
[envfile] AUTH__ACCESS_SECRET_KEY_B64 <- AUTH__ACCESS_SECRET_KEY_B64_FILE=/run/secrets/access_secret_key
[envfile] POSTGRES__PASSWORD <- POSTGRES__PASSWORD_FILE=/run/secrets/postgres_password (plain POSTGRES__PASSWORD ignored)
```

| Exit | When |
| --- | --- |
| 78 (`EX_CONFIG`) | A `<NAME>_FILE` is missing, unreadable, not a regular file, over 64 KiB, not UTF-8 or holds a NUL; or a declared name is not `[A-Za-z_][A-Za-z0-9_]*`. The message names the variable and the path, never the content. |
| 64 (`EX_USAGE`) | No command was given. |
| 127 / 126 | The command was not found / could not be executed. |
| anything else | The application's own: the launcher is gone by then. |

## Building

From the repo root (see [images/README.md](../README.md)):

```bash
just bake python-distroless
```

Image: `ghcr.io/morzecrew/python-distroless:3.14.8`.

## Layout

- `Dockerfile` — deps stage from `debian:bookworm-slim` (certs, libmagic, runtime dir layout); runtime `FROM al3xos/python-distroless`
- `rootfs/envfile-exec` — the `<NAME>_FILE` launcher above
