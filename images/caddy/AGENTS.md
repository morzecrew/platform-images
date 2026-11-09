<!-- torve:managed images/caddy — rendered from the corpus; do not edit by hand -->

## Decisions governing `images/caddy/`

### S-0001/D-18 — `ASSUMED` (Standing decisions)

No entrypoint renders configuration through a templating engine; each image uses its server's native expansion. xray's and mihomo's servers have none, so their entrypoints replace a JSON object that is exactly `{"$file": "<absolute path>"}` with the value that file yields, xray's also `{"$vlessDecryption": "<absolute path>"}`, `{"$vlessClients": "<absolute path>"}` or `{"$proxy": "<absolute path>"}`, and substitute nothing else.

- Paths: `images/*/rootfs/entrypoint.sh` `images/caddy/rootfs/Caddyfile` `images/caddy/Dockerfile` `images/xray/entrypoint/main.go` `images/mihomo/entrypoint/main.go` `shared/go/envconf/resolve.go`
- Consequence: configuration is read by the server that owns it, with no second syntax in between

### S-0001/D-24 — `ASSUMED` (Standing decisions)

caddy's WAF includes CRS from `/opt/coraza/owasp-crs/*.conf` with upstream's setup example unmodified. Every WAF `Include` must match a file or startup refuses, and `overrides/` ships a placeholder. The Coraza body limit is derived from `CADDY_REQUEST_BODY_MAX_SIZE`.

- Paths: `images/caddy/rootfs/**` `images/caddy/Dockerfile`
- Consequence: the WAF never runs without its rules, and one body limit applies

<!-- /torve:managed -->
