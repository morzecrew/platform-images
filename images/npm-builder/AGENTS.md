<!-- torve:managed images/npm-builder — rendered from the corpus; do not edit by hand -->

## Decisions governing `images/npm-builder/`

### S-0001/D-21 — `ASSUMED` (Standing decisions)

npm-builder installs with `npm ci` against a lockfile and writes to `/srv`, `BUILD_OUTPUT_DIR` defaulting to `dist`. An empty output, no `index.html`, or output no newer than a pre-build marker fails the build. `NODE_ENV` and `CI` stay unset and the npm cache is `/cache`. Node is the Active LTS major and is never automerged. The runtime is `caddy`, never a Node image.

- Paths: `images/npm-builder/**`
- Consequence: a stale or empty bundle cannot ship as a build's output

<!-- /torve:managed -->
