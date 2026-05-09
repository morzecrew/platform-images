# Caddy images

Custom Caddy Docker images for the Morze platform. Based on official `caddy` with **Coraza WAF** and **OWASP Core Rule Set** (CRS).

## Contents

- **Tag `2.11`** — Caddy built with [coraza-caddy](https://github.com/corazawaf/coraza-caddy), CRS rules under `/opt/coraza/`, and a small **platform Caddyfile** (`rootfs/Caddyfile`).
- **Runtime injection** — site fragments as `*.caddy` under **`CONFIG_DIR`** (default **`/etc/caddy/config.d`**), plus optional **global options** fragments under **`SERVERS_DIR`** (default **`/etc/caddy/servers.d`**) merged into the top-level `{ }` block (see below).
- **Named snippets** — bundled patterns under **`BUILTIN_SNIPPETS_DIR`** (default **`/etc/caddy/snippets`**) are **`import`ed at top level** in the base Caddyfile, so from **`CONFIG_DIR`** you can compose the app with e.g. `import spa` and `import security_headers`. Add your own **`(name) { }`** definitions as `*.caddy` under **`SNIPPET_DEFS_DIR`** (default **`/etc/caddy/snippet_defs.d`**); see [Snippets](#snippets-composable-patterns).
- **Health** — `GET {$HEALTH_PATH}` (default **`/__platform_healthz`**) → `200` with body `ok`. The base Caddyfile handles this **first** (before `request_body`, Coraza, and **`CONFIG_DIR`** imports) so probes stay cheap and predictable; override with **`HEALTH_PATH`**.

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
| `HEALTH_PATH` | `/__platform_healthz` | Path for the built-in liveness handler (`handle {$HEALTH_PATH:…}` → `200` / `ok`). Must match Caddy’s path matcher form (leading slash). |
| `REQUEST_BODY_MAX_SIZE` | `30MB` | `request_body` max size for the site. |
| `AUTO_HTTPS` | `auto_https off` | Global auto-HTTPS directive in the options block. |
| `TEMPLATE_DIR` | `/etc/caddy/templates` | Reserved for custom templating workflows (not used by the default entrypoint). |
| `CONFIG_DIR` | `/etc/caddy/config.d` | Directory for injected site fragments (`*.caddy`). The Caddyfile uses `import {$CONFIG_DIR}/*.caddy` (with this default). |
| `SERVERS_DIR` | `/etc/caddy/servers.d` | Fragments merged into the **global options** `{ }` block (`import {$SERVERS_DIR}/*.caddy`), after `order coraza_waf after rate_limit`. |
| `BUILTIN_SNIPPETS_DIR` | `/etc/caddy/snippets` | Glob `import {$BUILTIN_SNIPPETS_DIR}/*.caddy` runs **between** the global `{ }` block and the site block so bundled **`(name) { }`** snippets are real definitions. Point elsewhere only if you replace the shipped tree. |
| `SNIPPET_DEFS_DIR` | `/etc/caddy/snippet_defs.d` | Extra top-level snippet definitions (`*.caddy` containing `(myapp) { ... }`). Empty directory logs a harmless import warning. |

### Global / `servers` injection (`SERVERS_DIR`)

Add `*.caddy` files here for directives allowed in the **global** Caddyfile options block—most notably [`servers { ... }`](https://caddyserver.com/docs/caddyfile/options) (`trusted_proxies`, `trusted_proxies_strict`, server names, listener-scoped options, etc.). Content is spliced **inside** the outer `{ }` next to `AUTO_HTTPS` / `order`, **not** inside the site address block.

**Example** (`/etc/caddy/servers.d/10-trusted-proxies.caddy`) when Caddy sits behind another proxy or load balancer:

```caddy
servers {
	trusted_proxies static private_ranges
}
```

You can scope by listener if needed, e.g. `servers :8080 { ... }` (see Caddy global options docs). An empty glob only emits a warning.

Snippet **`(name) { }` definitions** are **not** loaded here (they are invalid inside the global options block). They are loaded via **`BUILTIN_SNIPPETS_DIR`** and **`SNIPPET_DEFS_DIR`**; see [Snippets](#snippets-composable-patterns).

Caddy expands `{$VAR}` and `{$VAR:default}` in the Caddyfile from the environment. The base file already sets **`encode zstd gzip`** on the site; add more `encode` only if you need different options.

### Injected site config (`CONFIG_DIR`, default `/etc/caddy/config.d/*.caddy`)

Add one or more `.caddy` files under **`CONFIG_DIR`** (volume, `COPY`, or derived image). The Caddyfile imports **`{$CONFIG_DIR}/*.caddy`** (default `/etc/caddy/config.d`). Fragments are merged **inside** the same server block as Coraza and `encode`—in glob sort order, **after** the built-in **`HEALTH_PATH`** handler and **before** the `501` fallback.

**Rules:**

- Use **site-level directives only** (`root`, `handle`, `reverse_proxy`, `file_server`, named matchers like `@api`, `header`, `try_files`, etc.).
- Do **not** open another listener block (no second `:80 { }` / duplicate of `{$EDGE_ADDRESS}`).

If the glob matches **no** files, Caddy logs a warning and continues; traffic that does not match your handlers falls through to **`501`** with body **`No configuration injected`** (except **`HEALTH_PATH`**, default **`/__platform_healthz`**).

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

### Snippets (composable patterns)

The base **`Caddyfile`** loads snippet definitions **at top level** (after the global `{ }` block, before the site block):

```caddy
import {$BUILTIN_SNIPPETS_DIR:/etc/caddy/snippets}/*.caddy
import {$SNIPPET_DEFS_DIR:/etc/caddy/snippet_defs.d}/*.caddy
```

That matches Caddy’s rule that **`(snippet_name) { ... }` must not sit inside** the global options `{ }` block **or** inside a site block—only as **top-level** siblings.

**In `CONFIG_DIR`**, invoke by **snippet name** (same as upstream Caddyfile `import`). Snippets can take **arguments** (see [Snippets with arguments](https://caddyserver.com/docs/caddyfile/concepts#snippets-with-arguments)); e.g. **`no_cache`** expects a **matcher** as the first token: `import no_cache @config`.

```caddy
import security_headers
import spa
@config path /config.json
import no_cache @config
handle /api/* {
	import proxy_defaults
}
```

Order your own `*.caddy` files with numeric prefixes if needed (`10-front.caddy`, `20-api.caddy`). Combine snippets with plain directives in the same files.

**Custom definitions:** add `snippet_defs.d/50-myapp.caddy`:

```caddy
(my_api) {
	handle /v1/* {
		reverse_proxy {$API_UPSTREAM:localhost:3000}
	}
}
```

Then in **`CONFIG_DIR`**: `import my_api`.

**`trusted_proxies`:** the `servers { trusted_proxies ... }` directive belongs **only** in **`SERVERS_DIR`**, not inside a site snippet. The shipped `trusted_proxies.caddy` under **`BUILTIN_SNIPPETS_DIR`** is comments only; copy the inner `servers { ... }` into **`servers.d`**.

| File | Snippet name | Purpose |
|------|----------------|--------|
| `spa.caddy` | `spa` | `root`, `handle { try_files …; file_server }`; `{$WEB_ROOT:/srv}` |
| `security.caddy` | `security_headers` | Baseline security headers, strip `Server` |
| `cache_static.caddy` | `cache_static` | Long cache for common static extensions and `/assets/*` |
| `no_cache.caddy` | `no_cache` | No-cache headers on **`{args[0]}`** (pass a matcher, e.g. `import no_cache @config`) |
| `cors.caddy` | `cors_default` | CORS headers + `OPTIONS` → `204`; `{$CORS_ALLOW_ORIGIN:*}` |
| `reverse_proxy.caddy` | `proxy_defaults` | Upstream `{$UPSTREAM:localhost:8080}`, forwarded headers, HTTP transport timeouts |
| `websocket.caddy` | `websocket_proxy` | `reverse_proxy` for `{$WS_UPSTREAM:localhost:8081}` |
| `logging_json.caddy` | `logging_json` | Access log to stdout as JSON |
| `rate_limit.caddy` | `rate_limit_api` | Example **`rate_limit`** zone — see [Rate limiting](#rate-limiting) |
| `trusted_proxies.caddy` | — | Comments only; use **`SERVERS_DIR`** for `servers { trusted_proxies ... }` |

### Rate limiting

The binary includes **[mholt/caddy-ratelimit](https://github.com/mholt/caddy-ratelimit)** via **`xcaddy build`**. The Git commit is pinned with Docker build-arg **`MHOLT_RL_SHA`** (default **`b8d8c9a9d99ee352d675cbbe416ec2b489fc8cab`**), mirrored by **`MHOLT_RL_SHA`** in **[`docker-bake.hcl`](../../docker-bake.hcl)** so Bake and `docker build` stay aligned.

**Global directive order** in `rootfs/Caddyfile` is **`order coraza_waf after rate_limit`**, so **`rate_limit` runs before Coraza** when you add zones under **`CONFIG_DIR`**. (Using **`order rate_limit before coraza_waf`** fails Caddyfile parsing for this directive pair in current Caddy — prefer **`coraza_waf after rate_limit`**.)

Use the module’s Caddyfile syntax (`rate_limit { zone ... { key, events, window } }` — see the [upstream README](https://github.com/mholt/caddy-ratelimit/blob/master/README.md)). The bundled snippet **`rate_limit.caddy`** defines **`(rate_limit_api)`**; from **`CONFIG_DIR`** use `import rate_limit_api` (or inline the body).

**Check:** `caddy list-modules` should list **`http.handlers.rate_limit`** (use **`docker run --entrypoint caddy … list-modules`** if your entrypoint runs validation first).

## Files in this directory

- `Dockerfile` — multi-stage Coraza + CRS build, **`xcaddy`** with Coraza + **mholt/caddy-ratelimit** (`MHOLT_RL_SHA`), optional **`caddy` user** + ownership, **`HEALTH_PATH`**, **`CONFIG_DIR`** / **`SERVERS_DIR`** / **`snippet_defs.d`**
- `rootfs/Caddyfile` — global `{ }` (`AUTO_HTTPS`, **`order coraza_waf after rate_limit`**, **`import {$SERVERS_DIR}/*.caddy`**) + top-level **`import {$BUILTIN_SNIPPETS_DIR}/*.caddy`** + **`import {$SNIPPET_DEFS_DIR}/*.caddy`** + templated site + **`HEALTH_PATH`** handle (first) + **`import {$CONFIG_DIR}/*.caddy`** + fallback
- `rootfs/entrypoint.sh` — `docker-entrypoint.d`, validate, exec
- `rootfs/waf/` — Coraza config copied to `/opt/coraza/config/`
- `rootfs/snippets/` — copied to `/etc/caddy/snippets/`
