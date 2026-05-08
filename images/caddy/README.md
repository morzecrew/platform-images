# Caddy images

Custom Caddy Docker images for the Morze platform. Based on official `caddy` with **Coraza WAF** and **OWASP Core Rule Set** (CRS).

## Contents

- **Tag `2.11`** — Caddy built with [coraza-caddy](https://github.com/corazawaf/coraza-caddy), CRS rules under `/opt/coraza/`, and a small **platform Caddyfile** (`rootfs/Caddyfile`).
- **Runtime injection** — site fragments as `*.caddy` under **`CONFIG_DIR`** (default **`/etc/caddy/config.d`**), plus optional **global options** fragments under **`SERVERS_DIR`** (default **`/etc/caddy/servers.d`**) merged into the top-level `{ }` block (see below).
- **Bundled snippets** — `/etc/caddy/snippets/*.caddy` are **reference** patterns (headers, SPA, proxy defaults, etc.); see [Snippets directory](#snippets-directory) below.
- **Health** — `GET /__platform_healthz` → `200` with body `ok` (defined in the base Caddyfile, before the fallback handler).

Coraza/CRS versions are **build args** in [`Dockerfile`](./Dockerfile); `CADDY_VERSION` matches the registry tag (see [`docker-bake.hcl`](../../docker-bake.hcl)).

## Building

From the repo root (see [images/README.md](../README.md)):

```bash
just bake caddy
```

Image: `ghcr.io/morzecrew/caddy:2.11`.

## Process and layout

- **User:** The image defines a **`caddy` account** and `chown`s `/etc/caddy`, `/docker-entrypoint.d`, `/srv`, `/config`, and `/data` so you can run the process **non-root** when you want (`docker run --user caddy`, Kubernetes `securityContext.runAsUser`, etc.). There is **no** `USER` in the Dockerfile, so the **default** is **root**—pick root or `caddy` to match your platform and volume permissions.
- Listens on **`EDGE_ADDRESS`** (default **`:8080`**); image `EXPOSE 8080`.
- Writable locations (typical volume mounts): **`/config`**, **`/data`**, **`/srv`** (e.g. static assets).
- **`/docker-entrypoint.d/*.sh`** — optional shell hooks sourced in lexical order before config validation (same idea as other official images).
- **`gettext`** is installed if you want `envsubst`-style templating in those hooks or sidecar steps; the stock entrypoint does not rewrite the Caddyfile.
- **Coraza** loads `/opt/coraza/config/coraza.conf`, `crs-setup.conf`, **`/opt/coraza/overrides/*.conf`** (optional; mount or bake files there), then OWASP CRS rules.

## Configuration

The entrypoint runs `caddy fmt` and `caddy adapt` on `/etc/caddy/Caddyfile`, then execs the main command.

### Environment variables

| Variable | Default | Description |
|----------|---------|-------------|
| `EDGE_ADDRESS` | `:8080` | Site block address (e.g. `:443` with TLS). |
| `REQUEST_BODY_MAX_SIZE` | `30MB` | `request_body` max size for the site. |
| `AUTO_HTTPS` | `auto_https off` | Global auto-HTTPS directive in the options block. |
| `TEMPLATE_DIR` | `/etc/caddy/templates` | Reserved for custom templating workflows (not used by the default entrypoint). |
| `CONFIG_DIR` | `/etc/caddy/config.d` | Directory for injected site fragments (`*.caddy`). The Caddyfile uses `import {$CONFIG_DIR}/*.caddy` (with this default). |
| `SERVERS_DIR` | `/etc/caddy/servers.d` | Fragments merged into the **global options** `{ }` block (`import {$SERVERS_DIR}/*.caddy`), after `order coraza_waf after rate_limit`. |

### Global / `servers` injection (`SERVERS_DIR`)

Add `*.caddy` files here for directives allowed in the **global** Caddyfile options block—most notably [`servers { ... }`](https://caddyserver.com/docs/caddyfile/options) (`trusted_proxies`, `trusted_proxies_strict`, server names, listener-scoped options, etc.). Content is spliced **inside** the outer `{ }` next to `AUTO_HTTPS` / `order`, **not** inside the site address block.

**Example** (`/etc/caddy/servers.d/10-trusted-proxies.caddy`) when Caddy sits behind another proxy or load balancer:

```caddy
servers {
	trusted_proxies static private_ranges
}
```

You can scope by listener if needed, e.g. `servers :8080 { ... }` (see Caddy global options docs). An empty glob only emits a warning.

You may also use a fragment here only for **`import`** lines—for example loading snippet definitions before they are invoked from **`CONFIG_DIR`**:

```caddy
import /etc/caddy/snippets/security.caddy
import /etc/caddy/snippets/cache_static.caddy
import /etc/caddy/snippets/spa.caddy
```

Caddy expands `{$VAR}` and `{$VAR:default}` in the Caddyfile from the environment. The base file already sets **`encode zstd gzip`** on the site; add more `encode` only if you need different options.

### Injected site config (`CONFIG_DIR`, default `/etc/caddy/config.d/*.caddy`)

Add one or more `.caddy` files under **`CONFIG_DIR`** (volume, `COPY`, or derived image). The Caddyfile imports **`{$CONFIG_DIR}/*.caddy`** (default `/etc/caddy/config.d`). Fragments are merged **inside** the same server block as Coraza and `encode`—in glob sort order, before `handle /__platform_healthz` and the `501` fallback.

**Rules:**

- Use **site-level directives only** (`root`, `handle`, `reverse_proxy`, `file_server`, named matchers like `@api`, `header`, `try_files`, etc.).
- Do **not** open another listener block (no second `:80 { }` / duplicate of `{$EDGE_ADDRESS}`).

If the glob matches **no** files, Caddy logs a warning and continues; traffic that does not match your handlers falls through to **`501`** with body **`No configuration injected`** (except `/__platform_healthz`).

**Example — Vite / SPA** (dist on `/srv`, uncached `config.json`, long-lived hashed assets, SPA fallback):

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

**Example — API reverse proxy:**

```caddy
handle /api/* {
	reverse_proxy localhost:8080
}
```

### Snippets directory

These files define **named reusable blocks** in Caddyfile syntax, e.g. `(spa) { ... }`, `(security_headers) { ... }`. In Caddy, such definitions must live at **global** scope. This image’s main template imports **`config.d` only inside the site block**, so you **cannot** reliably `import` a snippet file from `config.d` and then invoke `spa` on the next line—Caddy will reject `(name) { }` when that import is expanded inside the server.

**Practical use:** open the snippet, copy the **inner** directives into your `config.d` fragment (or flatten multiple snippets into one file); use **`SERVERS_DIR`** for global `servers { }` / [`trusted_proxies`](https://caddyserver.com/docs/caddyfile/options#trusted-proxies); or **`import`** snippet files from a **`SERVERS_DIR`** fragment so definitions exist before you invoke snippets from **`CONFIG_DIR`**.

| File | Purpose |
|------|---------|
| `spa.caddy` | `root`, `try_files` → `/index.html`, `file_server`; `{$WEB_ROOT:/srv}` |
| `security.caddy` | Baseline security headers, strip `Server` |
| `cache_static.caddy` | Long cache for common static extensions and `/assets/*` |
| `no_cache.caddy` | `Cache-Control` / `Pragma` / `Expires` for no caching |
| `cors.caddy` | CORS headers + `OPTIONS` → `204`; `{$CORS_ALLOW_ORIGIN:*}` |
| `reverse_proxy.caddy` | `(proxy_defaults)` — upstream `{$UPSTREAM:localhost:8080}`, forwarded headers, HTTP transport timeouts |
| `websocket.caddy` | `reverse_proxy` for `{$WS_UPSTREAM:localhost:8081}` |
| `logging_json.caddy` | Access log to stdout as JSON |
| `rate_limit.caddy` | Example **`rate_limit`** zone (`rate_limit_api`) — module is compiled into the image; see [Rate limiting](#rate-limiting) |
| `trusted_proxies.caddy` | Wraps `servers { trusted_proxies ... }` — deploy the **inner** `servers` block via **`SERVERS_DIR`**, not **`CONFIG_DIR`** |

### Rate limiting

The binary includes **[mholt/caddy-ratelimit](https://github.com/mholt/caddy-ratelimit)** via **`xcaddy build`**. The Git commit is pinned with Docker build-arg **`MHOLT_RL_SHA`** (default **`b8d8c9a9d99ee352d675cbbe416ec2b489fc8cab`**), mirrored by **`MHOLT_RL_SHA`** in **[`docker-bake.hcl`](../../docker-bake.hcl)** so Bake and `docker build` stay aligned.

**Global directive order** in `rootfs/Caddyfile` is **`order coraza_waf after rate_limit`**, so **`rate_limit` runs before Coraza** when you add zones under **`CONFIG_DIR`**. (Using **`order rate_limit before coraza_waf`** fails Caddyfile parsing for this directive pair in current Caddy — prefer **`coraza_waf after rate_limit`**.)

Use the module’s Caddyfile syntax (`rate_limit { zone ... { key, events, window } }` — see the [upstream README](https://github.com/mholt/caddy-ratelimit/blob/master/README.md)). The bundled snippet **`rate_limit.caddy`** defines a **named snippet** `(rate_limit_api)`; invoke or inline it per normal snippet rules.

**Check:** `caddy list-modules` should list **`http.handlers.rate_limit`** (use **`docker run --entrypoint caddy … list-modules`** if your entrypoint runs validation first).

## Files in this directory

- `Dockerfile` — multi-stage Coraza + CRS build, **`xcaddy`** with Coraza + **mholt/caddy-ratelimit** (`MHOLT_RL_SHA`), optional **`caddy` user** + ownership, **`CONFIG_DIR`** / **`SERVERS_DIR`**
- `rootfs/Caddyfile` — global `{ }` (`AUTO_HTTPS`, **`order coraza_waf after rate_limit`**, **`import {$SERVERS_DIR}/*.caddy`**) + templated site + **`import {$CONFIG_DIR}/*.caddy`** + health + fallback
- `rootfs/entrypoint.sh` — `docker-entrypoint.d`, validate, exec
- `rootfs/waf/` — Coraza config copied to `/opt/coraza/config/`
- `rootfs/snippets/` — copied to `/etc/caddy/snippets/`
