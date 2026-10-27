<!-- torve:managed images/python-distroless — rendered from the corpus; do not edit by hand -->

## Decisions governing `images/python-distroless/`

### S-0001/D-22 — `ASSUMED` (Standing decisions)

One exact-patch `DISTROLESS_PYTHON_VERSION` drives both uv-builder and python-distroless, and uv-builder's tag is the minor.

- Paths: `docker-bake.hcl` `images/uv-builder/Dockerfile` `images/python-distroless/Dockerfile`
- Consequence: an application built on uv-builder runs on the same Python patch in python-distroless

### S-0002/D-2 — `ASSUMED` (Service images and the drift CI cannot see)

python-distroless is tagged with the minor of `DISTROLESS_PYTHON_VERSION` and with the exact patch, the minor first, as uv-builder is. Its labels keep naming the exact patch.

- Paths: `docker-bake.hcl` `images/python-distroless/README.md`
- Consequence: a consumer pinning `python-distroless:3.14` gets the weekly rebuild again without an edit, and a consumer pinning the patch keeps it

### S-0002/D-3 — `ASSUMED` (Service images and the drift CI cannot see)

python-distroless's `deps` stage builds from `debian:${DEBIAN_VERSION}-slim`, the Debian release its runtime names, so the libraries and CA bundle it copies come from the same release as the runtime's glibc. Its smoke test imports `zlib`, `lzma` and `bz2` and round-trips data through each, beside the libmagic check it already makes.

- Paths: `images/python-distroless/Dockerfile` `images/python-distroless/smoke.sh`
- Consequence: CPython's compression modules load the libraries of the release they were built against. `LD_LIBRARY_PATH=/usr/lib` no longer puts bookworm's `libz`, `liblzma` and `libbz2` ahead of the runtime's own.

### S-0004/D-3 — `ASSUMED` (test modules and sqlite3 survive the images)

`images/python-distroless`'s deps stage installs `libsqlite3-0`, and the runtime copies `libsqlite3.so.0` from it into `/usr/lib` with the same multiarch glob as the other copied libraries. `images/python-distroless/README.md` lists it among the bundled libraries, and names a source-built `psycopg2`'s missing `libpq.so.5` as a known gap.

- Paths: `images/python-distroless/Dockerfile` `images/python-distroless/README.md`
- Consequence: `import sqlite3` works, so pandas' SQL readers work, at about 1.5 MB more per image

### S-0004/D-4 — `ASSUMED` (test modules and sqlite3 survive the images)

`images/python-distroless/smoke.sh` imports `sqlite3`, runs `select sqlite_version()` and writes and reads back a row in an in-memory database. On failure it prints a line naming `sqlite3`.

- Paths: `images/python-distroless/smoke.sh`
- Consequence: an image whose `_sqlite3` cannot load its library fails the smoke test

<!-- /torve:managed -->
