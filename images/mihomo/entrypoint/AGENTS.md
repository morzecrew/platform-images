<!-- torve:managed images/mihomo/entrypoint — rendered from the corpus; do not edit by hand -->

## Decisions governing `images/mihomo/entrypoint/`

### S-0001/D-18 — `ASSUMED` (Standing decisions)

No entrypoint renders configuration through a templating engine; each image uses its server's native expansion. xray's and mihomo's servers have none, so their entrypoints replace a JSON object that is exactly `{"$file": "<absolute path>"}` with the value that file yields, xray's also `{"$vlessDecryption": "<absolute path>"}`, `{"$vlessClients": "<absolute path>"}` or `{"$vlessClients": {"devices": "<absolute path>", "relays": "<absolute path>" or an array of relay/1 lines, "seed": "<absolute path>"}}`, `{"$hysteriaUsers": "<absolute path>"}`, `{"$proxy": "<absolute path>"}`, `{"$wireguard": "<absolute path>"}`, `{"$upstreams": "<absolute path>"}`, `{"$subscription": "<absolute path>"}`, `{"$gateway": {"servers": "<absolute path>", ...}}` or `{"$gatewayClients": "vless" or "hysteria"}`, and substitute nothing else.

- Paths: `images/*/rootfs/entrypoint.sh` `images/caddy/rootfs/Caddyfile` `images/caddy/Dockerfile` `images/xray/entrypoint/main.go` `images/mihomo/entrypoint/main.go` `shared/go/envconf/resolve.go`
- Consequence: configuration is read by the server that owns it, with no second syntax in between

<!-- /torve:managed -->
