# uv-builder images

Build-stage image for Python applications managed with **[uv](https://docs.astral.sh/uv/)**. Based on the official `python:<patch>-trixie` image with the `uv` binary from `ghcr.io/astral-sh/uv` (what Astral’s `uv:python*` images are, pinned to an exact Python patch), plus a small Debian layer (`bash`, `binutils`, `findutils`, `ca-certificates`) and a **`build-uv-app`** helper script for reproducible, slimmer venvs.

## Contents

**Tag `3.14`** (`linux/amd64`, `linux/arm64`) — `uv` on `python:3.14.8-trixie`, with **`build-uv-app`** (`rootfs/build.sh`) for sync → wheel → slim venv.

Use in a **multi-stage** Dockerfile: mount or copy your project into `/app`, run `build-uv-app`, then copy `/opt/venv` (and your app if needed) into a minimal runtime image such as [`python-distroless`](../python-distroless).

`DISTROLESS_PYTHON_VERSION` in [`docker-bake.hcl`](../../docker-bake.hcl) is the exact Python patch for both this image and [`python-distroless`](../python-distroless), so the venv built here runs on the same CPython build there, on either platform; its major.minor is the tag. `BUILDER_DEBIAN_SUITE` and `UV_VERSION` map to `DEBIAN_SUITE` / `UV_VERSION` in [`Dockerfile`](./Dockerfile).

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

Typical flow: `uv sync` → `uv build --wheel` → install wheel into the venv → **`python -m compileall -q -f`** on the venv (plain `.pyc` in `__pycache__`, which a runtime started without `-OO` loads) → optional removal of **`*.py`** (when **`REMOVE_PY_SOURCES=1`**) → optional stripping and cleanup (see environment variables below).

### Two layers: `build-uv-app deps` and `build-uv-app app`

With no argument, everything above happens in one step, so the dependencies and
the application share one layer and every code change re-ships both. The two
modes split them, so the dependency layer is cached by the lockfile alone:

```dockerfile
FROM ghcr.io/morzecrew/uv-builder:3.14 AS deps
COPY pyproject.toml uv.lock /app/
RUN --mount=type=cache,target=/root/.cache/uv build-uv-app deps

FROM deps AS app
COPY src/ /app/src/
RUN build-uv-app app

FROM ghcr.io/morzecrew/python-distroless:3.14.8
# Changes only with the lock.
COPY --from=deps /opt/venv /opt/venv
# Changes with the code.
COPY --from=app /opt/app /opt/app
ENTRYPOINT ["/opt/app/bin/myapp"]
```

- **`deps`** runs `uv sync --frozen --no-install-project`, so it needs no
  sources, then slims the venv as above. It also writes a `.pth` file into the
  venv's site-packages naming `APP_PATH`, so the application is importable with
  no `PYTHONPATH`.
- **`app`** builds the wheel and installs it with `--no-deps --target
  APP_PATH`, then compiles and slims `APP_PATH` only. The venv is left exactly
  as the deps stage made it.
- **Console scripts land in `APP_PATH/bin`**, with `/opt/venv/bin/python` as
  their shebang. They are not in the venv's `bin` on purpose: the runtime copies
  the venv from the `deps` stage, so anything the `app` stage added there would
  never reach it. `python -m <module>` works too.
- A project whose dependencies include path sources copies those in the `deps`
  stage as well.

### Environment variables (build)

| Variable | Default | Purpose |
|----------|---------|---------|
| `APP_ROOT` | `/app` | Project directory. |
| `VENV_PATH` | `/opt/venv` | Target venv path. |
| `APP_PATH` | `/opt/app` | Where `build-uv-app app` installs the application, and what `deps` puts on `sys.path`. Unused without an argument. |
| `UV_GROUPS` | `--no-dev` | Extra arguments passed to `uv sync`. The default leaves out the `dev` dependency group (or legacy `tool.uv.dev-dependencies`) and works whether or not the project defines one. |
| `PYTHON_BIN` | `${VENV_PATH}/bin/python` | Python used for `compileall`, `pip uninstall`, and `uv pip install --python`. |
| `REMOVE_PY_SOURCES` | `0` | If `1`, delete `*.py` under the venv. Bytecode is then compiled beside each module (`compileall -b`) rather than into `__pycache__`, because Python reads `__pycache__` only for a module whose source still exists. |
| `STRIP_NATIVE` | `1` | Strip `*.so` with `strip --strip-unneeded`. |
| `REMOVE_TESTS` | `1` | Remove `tests` / `test` trees under the venv. `__pycache__` is kept: it holds the compiled bytecode. |
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

- `Dockerfile` — official Python base + uv binary + packages + `WORKDIR /app`
- `rootfs/build.sh` — installed as `/usr/local/bin/build-uv-app`
- `test-build-uv-app.sh` — the two-layer mode built twice onto python-distroless (run in CI after the image builds)
