# Morze :: Platform Images

Docker definitions for сommon platform images. This repo holds Dockerfiles and config used to build and publish images to [ghcr.io/morzecrew](https://ghcr.io/morzecrew).

## Layout

Every image lives under `images/<name>/` with the **same shape**: a `Dockerfile` at the root of that folder, optional **`rootfs/`** for files that are copied into the image, and a `README.md`. See [images/README.md](./images/README.md) for the full convention.

Tags and build arguments are declared once in **[`docker-bake.hcl`](./docker-bake.hcl)**.

## Building

From the **repo root**. Requires [just](https://github.com/casey/just) and [Docker Buildx](https://docs.docker.com/build/).

```bash
just bake                 # all images (default group)
just bake postgres        # single image
just push postgres 18.4   # push an already-built local tag
just push uv-builder 3.14
```

**Publishing is CI's job, not a local command.** A merge to `main` that touches
`docker-bake.hcl` or `images/**` publishes, as does the weekly rebuild and a
manual run of [publish.yaml](.github/workflows/publish.yaml). Each of those
builds the image, pushes it by digest with no tag attached, smoke-tests that
exact digest, and only then moves the tags.

`just publish` still exists and **refuses by default**, because both of its
failure modes are silent: it skips that smoke gate, and on the default Buildx
driver it publishes no attestations while reporting success. Set
`I_KNOW_THIS_IS_UNGATED=1` if you genuinely mean to bypass both. `just push`
moves an already-built tag and is unaffected.

Pushing uses `gh auth token` for registry login to `ghcr.io`.

Tags follow bake defaults. The image name carries what is inside; bake variables set both the tag and matching build-args.

## Images

| Directory | Description |
|-----------|-------------|
| [postgres](./images/postgres) | PostgreSQL with pg_cron and pgroonga, allowlist-based config overrides via env. |
| [caddy](./images/caddy) | Caddy with Coraza WAF and OWASP CRS; env-templated base, `CONFIG_DIR` / `SERVERS_DIR`, top-level snippet imports (`BUILTIN_SNIPPETS_DIR`, `SNIPPET_DEFS_DIR`). |
| [flyway](./images/flyway) | Flyway with essential JDBC drivers, pinned versions. |
| [uv-builder](./images/uv-builder) | uv-based Python build stage: sync, wheel, slim venv (`build-uv-app`). |
| [python-distroless](./images/python-distroless) | Distroless Python runtime with libmagic and CA bundle for small final images. |

## Consuming these images

Every image publishes **two tags**:

| Tag | Behaviour | Use it when |
|---|---|---|
| `:<version>` | **Mutable.** Repointed on every rebuild, including the weekly one. | You want base-image CVE fixes without editing anything. |
| `:<version>-<yyyymmdd>-<run>` | **Immutable.** Written once, never repointed. | You need the bytes to stay put. |

**Neither is a substitute for the digest.** `@sha256:…` is the only truly
immutable reference; the dated tag is the ergonomic approximation of one.

**On the mutable tag, the bytes behind `:18.6` change even when nothing in this
repo changed.** That is deliberate: a Debian security fix inside an unchanged
upstream tag reaches you no other way. It is also exactly why the dated tag
exists — pin it if a moving base is not acceptable to you.

The rebuild runs **Mondays at 05:00 UTC**, uncached so that it actually picks up
a rebuilt base layer. Every publish — scheduled or not — builds the image, pushes
it **by digest with no tag attached**, starts it and runs that image's smoke
test, and only then points the tags at it. So a tag never moves to an image that
failed to start, and the bytes that were tested are the bytes you pull rather
than a rebuild that ought to be equivalent.

### Attestations

Images carry max-mode [SLSA provenance](https://slsa.dev/) and an SBOM:

```bash
docker buildx imagetools inspect ghcr.io/morzecrew/postgres:18.6
```

These are **unsigned**. They record what the build did and are evidence, not
proof — anyone with push access to this repository could produce them. Signing
is a separate decision with its own identity policy and is not in place yet.

Build arguments are recorded in max-mode provenance, so never pass a secret as
one.

## License

[MIT](./LICENSE) © Morze Technologies
