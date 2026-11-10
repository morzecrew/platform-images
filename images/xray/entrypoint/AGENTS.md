<!-- torve:managed images/xray/entrypoint — rendered from the corpus; do not edit by hand -->

## Decisions governing `images/xray/entrypoint/`

### S-0001/D-18 — `ASSUMED` (Standing decisions)

No entrypoint renders configuration through a templating engine; each image uses its server's native expansion. xray's and mihomo's servers have none, so their entrypoints replace a JSON object that is exactly `{"$file": "<absolute path>"}` with the value that file yields, xray's also `{"$vlessDecryption": "<absolute path>"}`, `{"$vlessClients": "<absolute path>"}`, `{"$proxy": "<absolute path>"}` or `{"$wireguard": "<absolute path>"}`, and substitute nothing else.

- Paths: `images/*/rootfs/entrypoint.sh` `images/caddy/rootfs/Caddyfile` `images/caddy/Dockerfile` `images/xray/entrypoint/main.go` `images/mihomo/entrypoint/main.go` `shared/go/envconf/resolve.go`
- Consequence: configuration is read by the server that owns it, with no second syntax in between

<!-- /torve:managed -->
