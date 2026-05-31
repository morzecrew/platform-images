# uv-builder images

Build-stage image for Python applications managed with **[uv](https://docs.astral.sh/uv/)**. Based on Astral’s official `ghcr.io/astral-sh/uv:python*` images, with a small Debian layer (`bash`, `binutils`, `findutils`, `ca-certificates`) and a **`build-uv-app`** helper script for reproducible, slimmer venvs.

## Contents

**Tag `3.14`** — `uv` on `ghcr.io/astral-sh/uv:python3.14-trixie`, with **`build-uv-app`** (`rootfs/build.sh`) for sync → wheel → slim venv.

Use in a **multi-stage** Dockerfile: mount or copy your project into `/app`, run `build-uv-app`, then copy `/opt/venv` (and your app if needed) into a minimal runtime image such as [`python-distroless`](../python-distroless).

`BUILDER_PYTHON_VERSION` and `BUILDER_DEBIAN_SUITE` in [`docker-bake.hcl`](../../docker-bake.hcl) set the registry tag and map to `PYTHON_VERSION` / `DEBIAN_SUITE` in [`Dockerfile`](./Dockerfile).

## Building

From the repo root (see [images/README.md](../README.md)):

```bash
just bake uv-builder
```

Image: `ghcr.io/morzecrew/uv-builder:3.14`.

## `build-uv-app`

Entrypoint script: **`/usr/local/bin/build-uv-app`** (`rootfs/build.sh`). It assumes:

- Project root at **`APP_ROOT`** (default `/app`) with a uv project (`pyproject.toml`, lockfile for `--frozen`).
- Virtualenv at **`VENV_PATH`** (default `/opt/venv`), with `UV_PROJECT_ENVIRONMENT=/opt/venv` already set in the image.

Typical flow: `uv sync` → `uv build --wheel` → install wheel into the venv → **`python -OO -m compileall -q -f`** on the venv → optional removal of **`*.py`** (when **`REMOVE_PY_SOURCES=1`**) → optional stripping and cleanup (see environment variables below).

### Environment variables (build)

| Variable | Default | Purpose |
|----------|---------|---------|
| `APP_ROOT` | `/app` | Project directory. |
| `VENV_PATH` | `/opt/venv` | Target venv path. |
| `UV_GROUPS` | `--no-group dev` | Extra arguments passed to `uv sync` (e.g. drop dev groups). |
| `PYTHON_BIN` | `${VENV_PATH}/bin/python` | Python used for `compileall`, `pip uninstall`, and `uv pip install --python`. |
| `REMOVE_PY_SOURCES` | `0` | If `1`, delete `*.py` under the venv (after `compileall`, so bytecode remains). |
| `STRIP_NATIVE` | `1` | Strip `*.so` with `strip --strip-unneeded`. |
| `REMOVE_TESTS` | `1` | Remove `tests` / `test` / `__pycache__` trees under the venv. |
| `REMOVE_DOCS` | `0` | If `1`, remove `docs` / `doc` / `examples` / `example` directories under the venv. |
| `REMOVE_LOCALES` | `1` | If `1`, remove `locale` / `locales` / `i18n` trees and `*.mo` / `*.po` files under the venv. |
| `REMOVE_TYPE_HINTS` | `1` | Delete `*.pyi`. |
| `REMOVE_C_EXT_DEBUG` | `1` | If `1`, delete `*.debug`, `*.pdb`, and `*.dSYM` files under the venv. |
| `REMOVE_BUILD_METADATA` | `0` | If `1`, remove `*.dist-info` / `*.egg-info` (use with care). |
| `REMOVE_PIP` | `1` | Uninstall pip/setuptools/wheel from the venv. |
| `BOTOCORE_SERVICES` | `s3 sts` | If non-empty and botocore is present, keep only these data dirs under `botocore/data` (space-separated names); empty disables pruning. |

`*.a` static libraries under the venv are always removed (not toggled by env).

For proxies during image build, pass standard BuildKit build-args (`HTTP_PROXY`, `HTTPS_PROXY`, `NO_PROXY`) on the `docker buildx bake` invocation; this image does not declare them in the Dockerfile.

## Layout

- `Dockerfile` — uv base + packages + `WORKDIR /app`
- `rootfs/build.sh` — installed as `/usr/local/bin/build-uv-app`
