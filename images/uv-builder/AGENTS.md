<!-- torve:managed images/uv-builder — rendered from the corpus; do not edit by hand -->

## Decisions governing `images/uv-builder/`

### S-0001/D-22 — `ASSUMED` (Standing decisions)

One exact-patch `DISTROLESS_PYTHON_VERSION` drives both uv-builder and python-distroless, and uv-builder's tag is the minor.

- Paths: `docker-bake.hcl` `images/uv-builder/Dockerfile` `images/python-distroless/Dockerfile`
- Consequence: an application built on uv-builder runs on the same Python patch in python-distroless

### S-0004/D-1 — `ASSUMED` (test modules and sqlite3 survive the images)

With `REMOVE_TESTS=1`, `build-uv-app` removes directories named `tests` and nothing else. A directory named `test` is kept. `images/uv-builder/README.md` says so, and says why `test` is kept.

- Paths: `images/uv-builder/rootfs/build.sh` `images/uv-builder/README.md`
- Consequence: a package that imports its own `test` module, such as SQLMesh, starts after the build with the defaults

### S-0004/D-2 — `ASSUMED` (test modules and sqlite3 survive the images)

`images/uv-builder/smoke.sh`'s default build covers a project whose package imports a `test` subpackage at import time and also ships a `tests` directory. After the build it asserts that the package imports, that its `test` directory remains and that its `tests` directory is gone.

- Paths: `images/uv-builder/smoke.sh`
- Consequence: a build that prunes a runtime `test` module, or stops pruning `tests`, fails the image's smoke test

<!-- /torve:managed -->
