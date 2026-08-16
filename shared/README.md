# shared

Files consumed by **two or more images**. That is the entry requirement, not a
description: something used by one image belongs in that image's `rootfs/`,
where its only reader can see it.

Nothing here is built. It reaches an image through a bake **named context**:

```hcl
target "valkey" {
  contexts = { shared = "./shared" }
}
```

```dockerfile
COPY --from=shared rootfs/lib/envconf.sh /usr/local/lib/envconf.sh
```

Named contexts rather than copies, and rather than moving every build context
to the repository root (RFC 0001 decision 6). A target that does not declare
the context **cannot reference it** — the build fails — whereas a copy in each
image directory guarantees N copies and a drift check that gets silenced the
first time it is inconvenient.

## Contents

| Path | Consumed by | What it is |
|---|---|---|
| [`rootfs/lib/envconf.sh`](rootfs/lib/envconf.sh) | `valkey` | The env-config contract: allowlist, denylist, secrets, startup summary. See [RFC 0001](../rfcs/0001-shared-env-config-contract.md). |

`postgres` is the second consumer and has not moved yet — RFC 0001 P4 retrofits
it, deliberately last, because it is the only step that can regress a running
deployment.

## Rules

**POSIX `sh`.** It has to run on Alpine without adding `bash`, so no
associative arrays and no `${var,,}`. `local` is used, which is not POSIX but is
implemented by every shell in scope (busybox ash, dash, bash).

**Changing a file here changes every image that embeds it.** They embed it at
build time, so a change reaches a published image only when that image is
rebuilt — which the weekly rebuild does. Two published tags can carry different
revisions of this file in the meantime.

## Tests

```bash
sh shared/test/run.sh        # -v to list each case
```

Runs in CI on every PR. These exercise the helper's functions directly, with no
container and no server, because the properties most worth pinning are startup
*aborts* — a newline refused, a denylisted key rejected in both strict modes —
and provoking those through a running server means asserting on a container
that deliberately failed to start.

That does not replace the per-image smoke tests, and the split is not
arbitrary: this suite proves the helper's semantics, while the image's smoke
test proves the helper is wired into the entrypoint and that the server accepts
what it generated. The bug that motivated the split was found by the second
kind — a dashed environment variable name that the helper read through `eval`,
which silently returned a wrong value — so both are load-bearing.
