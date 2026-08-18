# npm-builder images

Build-stage image for JavaScript applications that produce **static assets**. Based on the official `node` Debian images, with a **`build-js-app`** helper that installs from a frozen lockfile, runs the project's build, and hands a **verified** bundle to `/srv`.

There is no matching runtime image, and that is deliberate (RFC 0009 decision 1): the runtime for static assets is the already-published [`caddy`](../caddy) image, so this builder pairs with something that exists rather than shipping a second half nobody asked for.

## Contents

**Tag `24`** — `node:24-trixie`, with **`build-js-app`** (`rootfs/build.sh`) for install → build → verify → `/srv`.

`BUILDER_NODE_VERSION` and `BUILDER_NODE_SUITE` in [`docker-bake.hcl`](../../docker-bake.hcl) set the registry tag and map to `NODE_VERSION` / `DEBIAN_SUITE` in [`Dockerfile`](./Dockerfile).

Node **24** is the Active LTS line (EOL 2028-04-30). One major ships at a time; a second target is added when a consumer actually needs one, not in advance.

## Building

From the repo root (see [images/README.md](../README.md)):

```bash
just bake npm-builder
```

Image: `ghcr.io/morzecrew/npm-builder:24`.

## The contract

`build-js-app` does four things, and the fourth is why the image exists:

1. Refuses to run without a `package-lock.json`.
2. `npm ci` — a frozen install. A lockfile that disagrees with `package.json` fails rather than resolving a fresh tree.
3. `npm run build` (or `${BUILD_SCRIPT}`).
4. **Verifies the output**, then copies it to `/srv`.

A build that emits nothing — wrong output directory, or a build script that exited `0` without writing anything — currently produces a container that serves **404 for every path**, and is diagnosed in a browser after deploy. Here it fails the build, and the message names `BUILD_OUTPUT_DIR`, the path that was checked, and what the build emitted instead:

```
build-js-app: BUILD_OUTPUT_DIR='dist' resolved to '/app/dist', which does not exist.
The build emitted these directories: out. Set BUILD_OUTPUT_DIR to whichever one
your framework writes.
```

### Environment variables (build)

| Variable | Default | Purpose |
|----------|---------|---------|
| `BUILD_OUTPUT_DIR` | `dist` | Where **your framework** writes its bundle, relative to `APP_ROOT`. Vite writes `dist`, Next `out`, react-scripts `build`. An absolute path is accepted as-is. |
| `BUILD_SCRIPT` | `build` | The `package.json` script to run. A name that does not exist fails the build, because `npm run` exits non-zero. |
| `APP_ROOT` | `/app` | Project directory, and the image's `WORKDIR`. |
| `APP_DIST` | `/srv` | Where the verified bundle lands. `/srv` is what the [`caddy`](../caddy) image serves and what its `spa` snippet defaults to via `{$WEB_ROOT:/srv}`. |

## Use it in a two-stage build

```dockerfile
FROM ghcr.io/morzecrew/npm-builder:24 AS build
COPY . .
RUN --mount=type=cache,target=/cache,sharing=locked build-js-app

FROM ghcr.io/morzecrew/caddy:2.11.4
COPY --from=build /srv /srv
COPY spa.caddy /etc/caddy/config.d/
```

…where `spa.caddy` is one line:

```caddy
import spa
```

That snippet is bundled in the `caddy` image and does the `try_files {path} /index.html` fallback, so a client-side route like `/settings/profile/42` returns your `index.html` instead of a 404. Replacing a hand-written Caddyfile with that single `import` is the whole runtime half of a migration.

### The cache mount is yours to add

The image fixes npm's store at **`/cache`** (`npm_config_cache`). It cannot carry the mount itself — `--mount=type=cache` is a flag on **your** `RUN` instruction — so the line above is the contract: mount a cache over `/cache` and installs stop re-downloading the dependency tree on every build. Omit it and everything still works, just slower.

`sharing=locked` matters when several images build in parallel; npm's store is not safe under concurrent writes.

## Build arguments are recorded in the attestation

This image passes the build environment through untouched, because the variables that static builds bake in — `VITE_*`, `REACT_APP_*`, `NEXT_PUBLIC_*` — belong to the project, not to the builder.

**Do not pass secrets this way.** Two separate reasons, and the second is the worse one:

- Every image this repo publishes carries `mode=max` provenance (RFC 0002 decision 2), so build args are recorded in the attestation and readable by anyone who can pull the image.
- A static bundle **ships whatever it was built with**. An API key baked into a `REACT_APP_*` variable is in the JavaScript served to every visitor, whether or not this repo ever attested it.

If a value must stay secret, it cannot be a build-time variable of a static site at all — it belongs behind a backend the browser calls.

## Migrating an existing project

| Current runtime | What changes |
|---|---|
| This repo's `caddy`, or upstream Caddy | Delete the hand-written Caddyfile, add `import spa`. The builder replaces your `node:*` build stage. |
| nginx | Keep your nginx config and its runtime stage; only the build stage changes. You lose nothing and gain the frozen install and the empty-output check. |

Two things worth checking before you migrate:

- **`npm install` → `npm ci`.** If your lockfile is stale, `npm ci` fails where `npm install` quietly resolved something else. That failure is the point, but it is a real change, and it is the one most likely to surprise on the first build.
- **`NODE_ENV` and `CI` are deliberately unset** in this image. Setting `NODE_ENV=production` makes `npm ci` skip the devDependencies that hold your build tool; `CI=true` makes react-scripts treat warnings as errors. If your current Dockerfile sets either, decide whether you meant to.

## Tests

- [`smoke.sh`](./smoke.sh) — RFC 0002 §5.5's build-stage shape: the toolchain runs, the helper is present and parses, the npm cache path is where consumers mount, and the two footgun variables are unset.
- [`test-build-js-app.sh`](./test-build-js-app.sh) — RFC 0009 §6's battery: the three output conventions, the refusals, the cache mount proven by an offline second build, and the caddy handoff serving a deep path.

## Layout

- `Dockerfile` — node base, npm store at `/cache`, `WORKDIR /app`
- `rootfs/build.sh` — installed as `/usr/local/bin/build-js-app`
