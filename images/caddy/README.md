# Caddy images

Custom Caddy Docker images for the Morze platform. Based on official `caddy` with **Coraza WAF** and **OWASP Core Rule Set** (CRS).

## Contents

- **Tag `2.11`** — Caddy with:
  - [Coraza WAF](https://coraza.io/) — Web Application Firewall for Caddy
  - [OWASP CRS](https://coreruleset.org/) — Core Rule Set for ModSecurity/Coraza
- Base config in the image (`rootfs/Caddyfile`, `rootfs/waf/coraza.conf`, `rootfs/waf/crs-setup.conf`) plus **overrides** via environment variables.

Coraza/CRS pin versions are **build args** in [`Dockerfile`](./Dockerfile); `CADDY_VERSION` matches the registry tag (see [`docker-bake.hcl`](../../docker-bake.hcl)).

## Building

From the repo root (see [images/README.md](../README.md)):

```bash
just bake caddy
```

Image: `ghcr.io/morzecrew/caddy:2.11`.

## Configuration overrides

The image uses a custom entrypoint (`rootfs/entrypoint.sh`) that validates the Caddy config and then launches Caddy. The `Caddyfile` is templated with environment variables.

### Environment variables

| Variable | Default | Description |
|----------|---------|-------------|
| `EDGE_ADDRESS` | `:80` | Address Caddy listens on (e.g. `:443` for HTTPS). |
| `REQUEST_BODY_MAX_SIZE` | `30MB` | Maximum request body size. |
| `AUTO_HTTPS` | `auto_https off` | Caddy auto-HTTPS directive. |
| `ROUTES` | `""` | Caddy route blocks to inject (e.g. reverse proxy, file server). |

If `ROUTES` is empty, Caddy responds with `501 Routes are not configured`.

## Layout

- `Dockerfile` — multi-stage Coraza + CRS build and runtime image
- `rootfs/` — `Caddyfile`, `entrypoint.sh`, and `waf/` copied into the image
