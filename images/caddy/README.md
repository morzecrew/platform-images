# Caddy images

Custom Caddy Docker images for the Morze platform. Based on official `caddy` with **Coraza WAF** and **OWASP Core Rule Set** (CRS).

## Contents

- **Caddy 2.11** (variant `2.11-coraza-crs`) with:
  - [Coraza WAF](https://coraza.io/) — Web Application Firewall for Caddy
  - [OWASP CRS](https://coreruleset.org/) — Core Rule Set for ModSecurity/Coraza
- Base config in the image (`Caddyfile`, `waf/coraza.conf`, `waf/crs-setup.conf`) plus **overrides** via environment variables.

## Building

Build from the **repo root** with [just](https://github.com/casey/just):

```bash
just build -t caddy -v 2.11-coraza-crs
```

Image: `ghcr.io/morzecrew/caddy:2.11-coraza-crs`.

Optional: `--push` to push after build, or run `just push -t caddy -v 2.11-coraza-crs` separately.

## Configuration overrides

The image uses a custom entrypoint (`entrypoint.sh`) that validates the Caddy config and then launches Caddy. The `Caddyfile` is templated with environment variables.

### Environment variables

| Variable | Default | Description |
|----------|---------|-------------|
| `EDGE_ADDRESS` | `:80` | Address Caddy listens on (e.g. `:443` for HTTPS). |
| `REQUEST_BODY_MAX_SIZE` | `30MB` | Maximum request body size. |
| `AUTO_HTTPS` | `auto_https off` | Caddy auto-HTTPS directive. |
| `ROUTES` | `""` | Caddy route blocks to inject (e.g. reverse proxy, file server). |

If `ROUTES` is empty, Caddy responds with `501 Routes are not configured`.

## Layout

- `2.11-coraza-crs/` — Caddy 2.11 + Coraza + CRS: `Dockerfile`, `Caddyfile`, `entrypoint.sh`, `waf/coraza.conf`, `waf/crs-setup.conf`
