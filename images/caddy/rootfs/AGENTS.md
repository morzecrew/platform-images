<!-- torve:managed images/caddy/rootfs — rendered from the corpus; do not edit by hand -->

## Decisions governing `images/caddy/rootfs/`

### S-0001/D-14 — `ASSUMED` (Standing decisions)

A curated and a passthrough setting for one key, or two spellings of one name, abort startup naming both. The wire format is NUL-delimited and a value with a newline is refused. Values are read through `awk ENVIRON`, never `eval`.

- Paths: `shared/rootfs/lib/envconf.sh` `images/caddy/rootfs/entrypoint.sh` `images/postgres/rootfs/entrypoint.sh` `images/valkey/rootfs/entrypoint.sh`
- Consequence: no value can add configuration it does not name, and no ambiguity is resolved silently

### S-0001/D-18 — `ASSUMED` (Standing decisions)

No entrypoint renders configuration through a templating engine; each image uses its server's native expansion.

- Paths: `images/*/rootfs/entrypoint.sh` `images/caddy/rootfs/Caddyfile` `images/caddy/Dockerfile`
- Consequence: configuration is read by the server that owns it, with no second syntax in between

### S-0001/D-24 — `ASSUMED` (Standing decisions)

caddy's WAF includes CRS from `/opt/coraza/owasp-crs/*.conf` with upstream's setup example unmodified. Every WAF `Include` must match a file or startup refuses, and `overrides/` ships a placeholder. The Coraza body limit is derived from `CADDY_REQUEST_BODY_MAX_SIZE`.

- Paths: `images/caddy/rootfs/**` `images/caddy/Dockerfile`
- Consequence: the WAF never runs without its rules, and one body limit applies

<!-- /torve:managed -->
