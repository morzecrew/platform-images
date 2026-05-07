# python-distroless

Minimal **runtime** image for Python workloads: [`al3xos/python-distroless`](https://hub.docker.com/r/al3xos/python-distroless) on Docker Hub as the main stage, plus a thin set of libraries copied from **`debian:bookworm-slim`** so common stacks (e.g. **python-magic** / **libmagic**) keep working without a full glibc dev tree.

Intended as the **final stage** after a builder such as [`uv-builder`](../uv-builder): copy `/opt/venv` from the build stage and set `PATH` to the venv’s `bin` if you run your app as the main process.

## Building the image

From the repo root (see [images/README.md](../README.md)):

```bash
just bake python-distroless
```

Published tag: `ghcr.io/morzecrew/python-distroless:<PYTHON_VERSION>`.

`PYTHON_VERSION` and `DEBIAN_VERSION` are build-args from [`docker-bake.hcl`](../../docker-bake.hcl). They must match a real tag on **`al3xos/python-distroless`** (format `python<version>-debian<major>`, e.g. `3.14.3-debian13`). If upstream only publishes full semvers, set `PYTHON_VERSION` in bake to that value so `FROM al3xos/python-distroless:${PYTHON_VERSION}-debian${DEBIAN_VERSION}` resolves.

## Runtime behavior

- **User** `65532:65532` (non-root).
- **Environment** `LANG` / `LC_ALL` `C.UTF-8`, `TZ=UTC`, `PYTHONUNBUFFERED=1`, `PYTHONFAULTHANDLER=1`.
- **Writable temp**: `TMPDIR` and `XDG_CACHE_HOME` under `/srv/runtime-tmp` (ensure this path exists and is writable in your final image or volume—`uv-builder`’s `build-uv-app` creates `/srv/runtime-tmp` with the expected ownership when you use that flow).

Bundled from bookworm: updated CA certs, **`libmagic.so.1`** and **`magic.mgc`** data, plus **`libbz2`**, **`liblzma`**, **`libz`** for typical binary wheels. **`LD_LIBRARY_PATH=/usr/lib`** is set so these libs resolve.

## Layout

- `Dockerfile` — deps stage from `debian:bookworm-slim`; runtime `FROM al3xos/python-distroless`
