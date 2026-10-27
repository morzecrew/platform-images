<!-- torve:managed images/uv-builder/rootfs — rendered from the corpus; do not edit by hand -->

## Decisions governing `images/uv-builder/rootfs/`

### S-0004/D-1 — `ASSUMED` (test modules and sqlite3 survive the images) — implementation: none

With `REMOVE_TESTS=1`, `build-uv-app` removes directories named `tests` and nothing else. A directory named `test` is kept. `images/uv-builder/README.md` says so, and says why `test` is kept.

- Paths: `images/uv-builder/rootfs/build.sh` `images/uv-builder/README.md`
- Consequence: a package that imports its own `test` module, such as SQLMesh, starts after the build with the defaults

<!-- /torve:managed -->
