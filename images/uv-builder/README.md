# uv-builder

Build-stage image for Python applications managed with **[uv](https://docs.astral.sh/uv/)**. Based on Astral’s official `ghcr.io/astral-sh/uv:python*` images, with a small Debian layer (`bash`, `binutils`, `findutils`) and a **`build-uv-app`** helper script for reproducible, slimmer venvs.

Use this image in a **multi-stage** Dockerfile: mount or copy your project into `/app`, run `build-uv-app`, then copy `/opt/venv` (and your app if needed) into a minimal runtime image such as [`python-distroless`](../python-distroless).

## Building the image

From the repo root (see [images/README.md](../README.md)):

```bash
just bake uv-builder
```

Published tag: `ghcr.io/morzecrew/uv-builder:<PYTHON_VERSION>` (see [`docker-bake.hcl`](../../docker-bake.hcl); defaults align `PYTHON_VERSION` and `DEBIAN_SUITE` with the upstream uv base).

## Using `build-uv-app`

Entrypoint script: **`/usr/local/bin/build-uv-app`** (`rootfs/build.sh`). It assumes:

- Project root at **`APP_ROOT`** (default `/app`) with a uv project (`pyproject.toml`, lockfile for `--frozen`).
- Virtualenv at **`VENV_PATH`** (default `/opt/venv`), with `UV_PROJECT_ENVIRONMENT=/opt/venv` already set in the image.

Typical flow: `uv sync` → `uv build --wheel` → install wheel into the venv → `compileall` → optional stripping and cleanup (see environment variables below).

### Environment variables (build)

| Variable | Default | Purpose |
|----------|---------|---------|
| `APP_ROOT` | `/app` | Project directory. |
| `VENV_PATH` | `/opt/venv` | Target venv path. |
| `UV_GROUPS` | `--no-group dev` | Extra arguments passed to `uv sync` (e.g. drop dev groups). |
| `STRIP_NATIVE` | `1` | Strip `*.so` with `strip --strip-unneeded`. |
| `REMOVE_TESTS` | `1` | Remove `tests` / `test` / `__pycache__` trees under the venv. |
| `REMOVE_TYPE_HINTS` | `1` | Delete `*.pyi`. |
| `REMOVE_BUILD_METADATA` | `0` | If `1`, remove `*.dist-info` / `*.egg-info` (use with care). |
| `REMOVE_PIP` | `1` | Uninstall pip/setuptools/wheel from the venv. |
| `BOTOCORE_SERVICES` | `s3 sts` | If non-empty and botocore is present, keep only these data dirs under `botocore/data` (space-separated names); empty disables pruning. |

Proxy build-args **`HTTP_PROXY`**, **`HTTPS_PROXY`**, **`NO_PROXY`** are passed through as environment in the image for corporate networks.

The script creates **`/srv/runtime-tmp`** owned by `65532:65532` mode `0750` for compatibility with non-root distroless runtimes.

## Layout

- `Dockerfile` — uv base + packages + `WORKDIR /app`
- `rootfs/build.sh` — installed as `/usr/local/bin/build-uv-app`
