# Image layout

Every image under `images/<name>/` follows the same rules:

| Path | Purpose |
|------|---------|
| `Dockerfile` | Build definition; build context is always this directory (`images/<name>/`). |
| `README.md` | What the image is for and how to configure it at runtime. |
| `rootfs/` | Optional. Static files that are `COPY`’d into the image (configs, scripts, bundled assets). Omit when the Dockerfile has nothing to copy besides layers (e.g. Flyway). |

**Registry names** match the directory name under `images/` (e.g. `postgres`, `caddy`, `flyway`, `uv-builder`, `python-distroless`). **Tags** are version strings from bake variables (e.g. `18.4`, `2.11.3`, `12.7`, `3.14`, `3.14.5`); the same variables usually feed both `tags` and `args` in [`docker-bake.hcl`](../docker-bake.hcl). Distroless Python tags must remain valid for upstream `al3xos` bases (see [python-distroless](./python-distroless/README.md)).

Build from the **repository root**:

```bash
just bake               # all images
just bake flyway        # one target
just publish            # build + push (requires gh auth)
just push postgres 18   # push an already-built local tag
```

`just` is a thin wrapper around `docker buildx bake -f docker-bake.hcl` (`just push` uses `docker push` separately).
