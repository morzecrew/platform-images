# Caddy images

Custom Caddy Docker images for the Morze platform. Based on official `caddy` with **Coraza WAF** and **OWASP Core Rule Set** (CRS).

## Contents

- **Tag `2.11`** — Caddy with:
  - [Coraza WAF](https://coraza.io/) — Web Application Firewall for Caddy
  - [OWASP CRS](https://coreruleset.org/) — Core Rule Set for ModSecurity/Coraza
- Base config in the image (`rootfs/Caddyfile`, `rootfs/waf/coraza.conf`, `rootfs/waf/crs-setup.conf`) with **overrides** via environment variables and optional **injected Caddyfile fragments** at `/etc/caddy/config/*.caddy`.

Coraza/CRS pin versions are **build args** in [`Dockerfile`](./Dockerfile); `CADDY_VERSION` matches the registry tag (see [`docker-bake.hcl`](../../docker-bake.hcl)).

## Building

From the repo root (see [images/README.md](../README.md)):

```bash
just bake caddy
```

Image: `ghcr.io/morzecrew/caddy:2.11`.

## Configuration overrides

The image uses a custom entrypoint (`rootfs/entrypoint.sh`) that validates the Caddy config and then launches Caddy. The `Caddyfile` is templated with environment variables for the edge listener and Coraza/WAF wrapper.

**Application behavior** (static files, reverse proxies, matchers, headers, `try_files`, etc.) is not set in env. The base site block ends with `import /etc/caddy/config/*.caddy`; put one or more `.caddy` files there (volume mount, `COPY`, or derived image). They are expanded **inside** the same server block as WAF and `encode`—do **not** open a second `:80 { }` or duplicate `{$EDGE_ADDRESS}` in a fragment.

If the glob matches no files, Caddy logs a warning and continues; requests then fall through to the default handler and get `501` with body `No configuration injected`.

### Environment variables

| Variable | Default | Description |
|----------|---------|-------------|
| `EDGE_ADDRESS` | `:80` | Address Caddy listens on (e.g. `:443` for HTTPS). |
| `REQUEST_BODY_MAX_SIZE` | `30MB` | Maximum request body size. |
| `AUTO_HTTPS` | `auto_https off` | Caddy auto-HTTPS directive. |

The baked `Caddyfile` already sets `encode zstd gzip` on the site—skip extra `encode` in fragments unless you need different options.

### Injected config (`/etc/caddy/config/*.caddy`)

Fragments contain **directives that belong inside the site block** (same nesting level as `coraza_waf`). Examples: `root`, named matchers (`@foo`), `header`, `try_files`, `file_server`, `reverse_proxy`, `handle`, etc.

**Vite / SPA static example** (dist on `/srv`, runtime `config.json` uncached, hashed assets long‑cached, SPA fallback):

```caddy
root * /srv

@config path /config.json
header @config {
  Cache-Control "no-store, no-cache, must-revalidate, proxy-revalidate, max-age=0"
  Pragma "no-cache"
  Expires "0"
}

@assets {
  path /assets/*
  path *.js
  path *.css
  path *.svg
  path *.png
  path *.jpg
  path *.woff2
}

header @assets {
  Cache-Control "public, max-age=31536000, immutable"
}

try_files {path} /index.html

file_server
```

Minimal API reverse-proxy fragment:

```caddy
handle /api/* {
  reverse_proxy localhost:8080
}
```

## Layout

- `Dockerfile` — multi-stage Coraza + CRS build and runtime image
- `rootfs/` — `Caddyfile`, `entrypoint.sh`, and `waf/` copied into the image; runtime directory `/etc/caddy/config/` exists for optional fragments
