# RFCs

Design proposals for **Morze :: Platform Images**.

## Allocating a number

The next free number is **0010**. Before creating an RFC, glance at the table
below (or `ls` this directory) and take the next unused integer — numbers
collide when minted in parallel. Update this table in the same change.

Filename: `NNNN-kebab-title.md`. Keep the `# RFC NNNN — Title` H1 and the
number in the filename in sync.

## Index

| # | Title | Status | One-line routing description |
|---|---|---|---|
| [0001](0001-shared-env-config-contract.md) | Shared env-config contract | 🚧 In progress | Two images configure themselves from the environment two different ways; one contract for naming, allowlists, precedence and a startup summary, plus a shared helper and how it reaches build contexts. |
| [0002](0002-publishing-pipeline-attestations-tag-policy-rebuild-cadence.md) | Publishing pipeline: attestations, tag policy, rebuild cadence | 🚧 In progress | A published tag cannot say what commit built it, what is inside it, or whether it means the same tomorrow; labels, attestations, an immutable companion tag, a weekly rebuild, rootless smoke tests. |
| [0003](0003-image-admission-and-retirement-rule.md) | Image admission and retirement rule | 🚧 In progress | Nothing decides whether an image belongs here or when it leaves; a two-project admission bar, an annual review, and a retirement checklist that says what happens to the published package. |
| [0004](0004-postgres-extensions-as-a-build-argument.md) | Postgres extensions as a build argument | 📝 Draft | Adding a Postgres extension currently means a second image directory; a `PG_EXTENSIONS` build arg and manifest that also generates the preload line, so combinations become bake targets. |
| [0005](0005-opentelemetry-collector-image.md) | OpenTelemetry Collector image | 📝 Draft | Every project rewrites the same collector config, minus the memory limiter; a contrib image with a curated default pipeline of `${env:}` references, env-selected exporters, and an overlay directory. |
| [0006](0006-valkey-image.md) | Valkey image | 🚧 In progress | Whether the cache/queue gap is real at all, and if so a Valkey whose value is a finite `maxmemory`, one persistence switch, file-first secrets, and refusal of the combinations that lose data silently. |
| [0007](0007-clickhouse-image.md) | ClickHouse image | 📝 Draft | Upstream ClickHouse assumes a dedicated machine; YAML overlays with `from_env`, container-sane memory and cache defaults, a limited default user profile, and a maintained diff from upstream. |
| [0008](0008-javascript-builder-and-distroless-runtime-pair.md) | JavaScript builder and distroless runtime pair | ❌ Superseded | Mirroring `uv-builder`/`python-distroless` for JS: which package manager the builder is named for, and one bake variable coupling builder and runtime majors so they cannot drift. |
| [0009](0009-javascript-static-asset-builder.md) | JavaScript static-asset builder | 📝 Draft | Five projects each wrote their own Node build stage and diverged; one builder image emitting static assets to a known path, with the published `caddy` image as the runtime. |

Departures found while executing these designs are recorded in
[EXECUTION-LOG.md](EXECUTION-LOG.md), which is not an RFC and carries no number.

## Status legend

- 📝 **Draft** — proposed, not started
- 🚧 **In progress** — partially shipped
- ✅ **Complete** — fully shipped
- ❌ **Rejected / withdrawn**
