<!-- torve:managed images/uv-builder — rendered from the corpus; do not edit by hand -->

## Decisions governing `images/uv-builder/`

### S-0001/D-22 — `ASSUMED` (Standing decisions)

One exact-patch `DISTROLESS_PYTHON_VERSION` drives both uv-builder and python-distroless, and uv-builder's tag is the minor.

- Paths: `docker-bake.hcl` `images/uv-builder/Dockerfile` `images/python-distroless/Dockerfile`
- Consequence: an application built on uv-builder runs on the same Python patch in python-distroless

<!-- /torve:managed -->
