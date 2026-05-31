# python-distroless images

Minimal **runtime** image for Python workloads: [`al3xos/python-distroless`](https://hub.docker.com/r/al3xos/python-distroless) on Docker Hub as the main stage, plus a thin set of libraries copied from **`debian:bookworm-slim`** so common stacks (e.g. **python-magic** / **libmagic**) keep working without a full glibc dev tree.

## Contents

**Tag `3.14.5`** — distroless Python on `al3xos/python-distroless`, with libmagic, CA certs, and common runtime libs from bookworm.

- Intended as the **final stage** after a builder such as [`uv-builder`](../uv-builder): copy `/opt/venv` from the build stage and set `PATH` to the venv’s `bin` if you run your app as the main process.
- **User** `65532:65532` by default (overridable via **`APP_UID`** / **`APP_GID`** build args).
- **Environment** `LANG` / `LC_ALL` `C.UTF-8`, `TZ=UTC`, `PYTHONUNBUFFERED=1`, `PYTHONFAULTHANDLER=1`, plus **`APP_RUNTIME_DIR`**, **`APP_TMP_DIR`** (defaults `/srv/runtime` and `/srv/runtime/tmp`).
- **Writable temp**: `TMPDIR` is **`APP_TMP_DIR`** (default `/srv/runtime/tmp`); `XDG_CACHE_HOME` is `${TMPDIR}/.cache`. Mount a volume over those paths if you need a writable layer at runtime.
- Bundled from bookworm: updated CA certs, **`libmagic.so.1`** and **`magic.mgc`**, plus **`libbz2`**, **`liblzma`**, **`libz`**. **`LD_LIBRARY_PATH=/usr/lib`** is set so these libs resolve.

`DISTROLESS_PYTHON_VERSION` in [`docker-bake.hcl`](../../docker-bake.hcl) sets the registry tag and `PYTHON_VERSION` in [`Dockerfile`](./Dockerfile). `DEBIAN_VERSION` comes from bake’s `DISTROLESS_DEBIAN_VERSION`. They must resolve to a real tag on **`al3xos/python-distroless`**: `FROM al3xos/python-distroless:${PYTHON_VERSION}-debian${DEBIAN_VERSION}` (e.g. `3.14.5-debian13`). If upstream uses full semver, set `DISTROLESS_PYTHON_VERSION` in bake to that exact string.

## Building

From the repo root (see [images/README.md](../README.md)):

```bash
just bake python-distroless
```

Image: `ghcr.io/morzecrew/python-distroless:3.14.5`.

## Layout

- `Dockerfile` — deps stage from `debian:bookworm-slim` (certs, libmagic, runtime dir layout); runtime `FROM al3xos/python-distroless`
