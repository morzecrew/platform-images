<!-- torve:managed images/valkey/rootfs — rendered from the corpus; do not edit by hand -->

## Decisions governing `images/valkey/rootfs/`

### S-0001/D-14 — `ASSUMED` (Standing decisions)

A curated and a passthrough setting for one key, or two spellings of one name, abort startup naming both. The wire format is NUL-delimited and a value with a newline is refused. Values are read through `awk ENVIRON`, never `eval`.

- Paths: `shared/rootfs/lib/envconf.sh` `images/caddy/rootfs/entrypoint.sh` `images/postgres/rootfs/entrypoint.sh` `images/valkey/rootfs/entrypoint.sh`
- Consequence: no value can add configuration it does not name, and no ambiguity is resolved silently

### S-0001/D-16 — `ASSUMED` (Standing decisions)

`<NAME>_FILE` wins over `<NAME>` for an image-owned or declared name. A file that is missing, unreadable, not regular, over 64 KiB, not UTF-8 or holds a NUL exits 78, naming the variable and the path and never the content, and the file is read once. postgres keeps upstream's handling, and python-distroless resolves only `ENVFILE_NAMES` through the opt-in `envfile-exec`.

- Paths: `shared/rootfs/lib/envconf.sh` `images/flyway/rootfs/entrypoint.sh` `images/valkey/rootfs/entrypoint.sh` `images/python-distroless/rootfs/envfile-exec`
- Consequence: a secret mounted as a file is read safely or the container refuses to start

<!-- /torve:managed -->
