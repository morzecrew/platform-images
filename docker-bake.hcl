# Set by publish CI; empty locally so `just bake` stays cache-stable and does
# not rebuild every layer on each invocation.
variable "GIT_REVISION" {
  default = ""
}

variable "BUILD_DATE" {
  default = ""
}

# <yyyymmdd>-<run_id>.<run_attempt>, set by publish CI. Empty locally, which
# suppresses the dated tag entirely -- see tag() below.
variable "BUILD_STAMP" {
  default = ""
}

# One line per image. Shown on the GHCR package page, so it lives here rather
# than only in the root README. Keys are quoted: bare hyphenated keys parse as
# subtraction.
#
# Indexed directly rather than through lookup() with a default: a target with no
# entry here must fail the build, not publish an empty description label. Bake
# evaluates every target on every invocation, so a missing row breaks `just
# bake` immediately and names the line, rather than surfacing on the GHCR page
# after a push. images/README.md lists the entry as an admission touchpoint and
# its removal as a retirement step.
variable "DESCRIPTIONS" {
  default = {
    "flyway"            = "Flyway with PostgreSQL and ClickHouse JDBC drivers, pinned."
    "caddy"             = "Caddy with Coraza WAF and OWASP CRS, env-configured with snippet and config directories."
    # Deliberately does not list extensions. Three tags share this package and
    # each installs a different set, so any list here is wrong for two of them --
    # measured: `:18.6-cron` advertised pgroonga it does not have and
    # `:18.6-pgvector` omitted the extension it exists for. The set each image
    # actually has is the `io.morze.postgres.extensions` label, generated from the
    # build arg (RFC 0004 row 16), and images/postgres/README.md has the
    # per-tag table for humans.
    "postgres"          = "PostgreSQL with allowlist-based config overrides via env; the installed extension set is in the io.morze.postgres.extensions label."
    "uv-builder"        = "uv-based Python build stage: sync, wheel, slim venv via build-uv-app."
    "npm-builder"       = "Node build stage for static assets: frozen npm install, project build, verified bundle to /srv via build-js-app."
    "python-distroless" = "Distroless Python runtime with libmagic and CA bundle."
    "valkey"            = "Valkey with a finite maxmemory, one persistence switch, file-first secrets, and env-generated config."
    "rustfs"            = "RustFS S3-compatible object storage: console off by default, both credentials required, env-configured."
    "pgbouncer"         = "PgBouncer with an entrypoint-generated config, file-first credentials, and allowlist-based overrides via env."
  }
}

# Two tag forms, both published:
#
#   :<version>                      mutable, repointed on every rebuild. Track
#                                   this to get CVE fixes without action.
#   :<version>-<BUILD_STAMP>        written once, never repointed. Pin this, or
#                                   pin the digest.
#
# BUILD_STAMP is empty for local builds, which emit the mutable tag alone -- a
# developer's `just bake postgres` should not mint dated tags. CI sets it to
# <yyyymmdd>-<run_id>.<run_attempt>. The attempt is not decoration: re-running a
# workflow reuses both run_id and run_number, so either alone would let a second
# attempt repoint a tag this file calls immutable.
#
# Neither tag is a substitute for the digest, which is the only true immutable
# reference. See RFC 0002.
function "tag" {
  params = [name, version]
  result = compact([
    "ghcr.io/morzecrew/${name}:${version}",
    BUILD_STAMP == "" ? "" : "ghcr.io/morzecrew/${name}:${version}-${BUILD_STAMP}",
  ])
}

# MIT covers the Dockerfiles and config here; bundled upstream software keeps
# its own license.
function "label" {
  params = [name, version]
  result = {
    "org.opencontainers.image.title"       = name
    "org.opencontainers.image.version"     = version
    "org.opencontainers.image.licenses"    = "MIT"
    "org.opencontainers.image.vendor"      = "Morze Technologies"
    "org.opencontainers.image.source"      = "https://github.com/morzecrew/platform-images"
    "org.opencontainers.image.description" = DESCRIPTIONS[name]
    "org.opencontainers.image.revision"    = GIT_REVISION
    "org.opencontainers.image.created"     = BUILD_DATE
  }
}

# Provenance and SBOM are inherited by every target below.
#
# mode=max over the default min: min records only the materials, and the
# question a consumer asks -- which build steps ran -- needs max. Both are
# emitted by buildx for free on --push, and neither can be applied
# retroactively to already-published tags.
#
# These are UNSIGNED attestations: evidence about what the build did, not proof.
# Signing is a separate decision with its own identity policy. See RFC 0002.
#
# Must be the `attest` list form. The `provenance = "mode=max"` / `sbom = true`
# shorthand is accepted without error by buildx 0.35 and then silently produces
# no attestation at all -- verified with `bake --print`, which shows no attest
# entry for it. A green build would have claimed coverage it did not have.
target "_attested" {
  attest = [
    "type=provenance,mode=max",
    "type=sbom",
  ]
}

# ....................... #

# renovate: datasource=docker depName=flyway/flyway versioning=docker
variable "FLYWAY_VERSION" {
  default = "13.10"
}

target "flyway" {
  inherits   = ["_attested"]
  context    = "./images/flyway"
  dockerfile = "Dockerfile"
  tags       = tag("flyway", FLYWAY_VERSION)
  labels     = label("flyway", FLYWAY_VERSION)
  contexts   = { shared = "./shared" }
  args = {
    FLYWAY_VERSION          = FLYWAY_VERSION
    # renovate: datasource=maven depName=org.postgresql:postgresql
    POSTGRES_JDBC_VERSION   = "42.7.14"
    # renovate: datasource=maven depName=com.clickhouse:clickhouse-jdbc
    CLICKHOUSE_JDBC_VERSION = "0.11.0"
  }
}

# ....................... #

# renovate: datasource=docker depName=caddy versioning=docker
variable "CADDY_VERSION" {
  default = "2.11.7"
}

target "caddy" {
  inherits   = ["_attested"]
  context    = "./images/caddy"
  dockerfile = "Dockerfile"
  tags       = tag("caddy", CADDY_VERSION)
  labels     = label("caddy", CADDY_VERSION)

  # The shared env-config helper reaches this build as a named context rather
  # than a copy under images/caddy/ (RFC 0001 decision 6).
  contexts = {
    shared = "./shared"
  }

  args = {
    CADDY_VERSION        = CADDY_VERSION
    # renovate: datasource=github-releases depName=corazawaf/coraza-caddy
    CORAZA_CADDY_VERSION = "v2.6.2"
    # renovate: datasource=github-releases depName=coreruleset/coreruleset
    CRS_VERSION          = "v4.30.0"
    MHOLT_RL_SHA         = "16aecbbcb8ca07dc1c671e263379606ff9493c55"
  }
}

# ....................... #

# renovate: datasource=docker depName=postgres versioning=docker
variable "POSTGRES_VERSION" {
  default = "18.6"
}

# Three extension sets, three targets, one registry name (RFC 0004 decision 3).
# The unsuffixed tag keeps its published meaning -- cron + pgroonga -- so nobody
# pinning `postgres:18.6` sees a change; variants take a suffix.
#
# The sets are written literally rather than through a bake variable. A variable
# is settable from the environment, so anything that exported
# POSTGRES_EXTENSIONS changed what `postgres:18.6` contained while the tag stayed
# put -- wave 1's R-7, whose remaining bite this removes. Experimenting locally
# still works with `--set postgres.args.PG_EXTENSIONS=...`, which is explicit
# about being a one-off.
#
# `inherits` merges args per key with the child's value winning, so a variant
# declares only what it changes (decision 6, measured on buildx 0.35).
#
# Ceiling is three including the default (decision 7), and this reaches it: each
# is a full --no-cache slot in the weekly rebuild, so a fourth request is the
# prompt to ask whether the answer is no.
target "postgres" {
  inherits   = ["_attested"]
  context    = "./images/postgres"
  contexts   = { shared = "./shared" }
  dockerfile = "Dockerfile"
  tags       = tag("postgres", POSTGRES_VERSION)
  labels     = label("postgres", POSTGRES_VERSION)
  args = {
    POSTGRES_IMAGE_TAG = POSTGRES_VERSION
    PG_EXTENSIONS      = "cron pgroonga"
  }
}

# The default set plus pgvector. §3.1's measured demand is not "vector instead of
# what this image has" but "vector as well": two projects left for
# pgvector/pgvector and gave up cron and pgroonga to get it.
#
# `image.version` stays the base version, as §5.3's sketch has it -- a variant is
# the same Postgres with a different extension set, and the tag is what says
# which set.
target "postgres-pgvector" {
  inherits = ["postgres"]
  tags     = tag("postgres", "${POSTGRES_VERSION}-pgvector")
  labels   = label("postgres", POSTGRES_VERSION)
  args     = { PG_EXTENSIONS = "cron pgroonga pgvector" }
}

# The default set minus pgroonga, for a consumer that wants cron and was paying
# for the groonga apt source, the package and the image size to get it (§3.1,
# morze-erp-backend-v2). Needs no manifest row: omitting is subtraction.
target "postgres-cron" {
  inherits = ["postgres"]
  tags     = tag("postgres", "${POSTGRES_VERSION}-cron")
  labels   = label("postgres", POSTGRES_VERSION)
  args     = { PG_EXTENSIONS = "cron" }
}

# ....................... #

variable "BUILDER_DEBIAN_SUITE" {
  default = "trixie"
}

# renovate: datasource=docker depName=ghcr.io/astral-sh/uv versioning=docker
variable "UV_VERSION" {
  default = "0.13.5"
}

# Python comes from DISTROLESS_PYTHON_VERSION below, the exact patch both images
# build on. Tagged with the minor and with that patch: the patch tag is what
# lets a consumer pin the builder to the python-distroless it runs on. The minor
# stays first, because CI and publish.yaml read the repository from tags[0].
target "uv-builder" {
  inherits   = ["_attested"]
  context    = "./images/uv-builder"
  dockerfile = "Dockerfile"
  tags = concat(
    tag("uv-builder", regex("^[0-9]+\\.[0-9]+", DISTROLESS_PYTHON_VERSION)),
    tag("uv-builder", DISTROLESS_PYTHON_VERSION),
  )
  labels     = label("uv-builder", regex("^[0-9]+\\.[0-9]+", DISTROLESS_PYTHON_VERSION))
  args = {
    PYTHON_VERSION = DISTROLESS_PYTHON_VERSION
    DEBIAN_SUITE   = BUILDER_DEBIAN_SUITE
    UV_VERSION     = UV_VERSION
  }
}

# ....................... #

# The major is chosen against the Node release schedule, not by recency: 24 is
# the Active LTS line (EOL 2028-04-30). A Renovate proposal moving this to a
# Current-phase major is a downgrade in support, so it gets read rather than
# merged -- see RFC 0009 decision 9.
# renovate: datasource=docker depName=node extractVersion=^(?<version>\d+)-trixie$
variable "BUILDER_NODE_VERSION" {
  default = "24"
}

variable "BUILDER_NODE_SUITE" {
  default = "trixie"
}

target "npm-builder" {
  inherits   = ["_attested"]
  context    = "./images/npm-builder"
  dockerfile = "Dockerfile"
  tags       = tag("npm-builder", BUILDER_NODE_VERSION)
  labels     = label("npm-builder", BUILDER_NODE_VERSION)
  args = {
    NODE_VERSION = BUILDER_NODE_VERSION
    DEBIAN_SUITE = BUILDER_NODE_SUITE
  }
}

# ....................... #

# Versions come from patch tags only: upstream points `X.Y-alpine` at a release
# candidate before X.Y.0 ships (`9.2-alpine` was `9.2.0-rc1-alpine`), so a
# minor appears here once it has a stable release.
# renovate: datasource=docker depName=valkey/valkey extractVersion=^(?<version>\d+\.\d+)\.\d+-alpine$
variable "VALKEY_VERSION" {
  default = "9.1"
}

target "valkey" {
  inherits   = ["_attested"]
  context    = "./images/valkey"
  dockerfile = "Dockerfile"
  tags       = tag("valkey", VALKEY_VERSION)
  labels     = label("valkey", VALKEY_VERSION)

  # The shared env-config helper reaches this build as a named context rather
  # than a copy under images/valkey/ (RFC 0001 decision 6). Every image that
  # sources envconf.sh declares this line; an image that forgets it fails to
  # build rather than shipping a stale copy.
  contexts = {
    shared = "./shared"
  }

  args = {
    VALKEY_VERSION = VALKEY_VERSION
  }
}

# ....................... #

# Pinned by full patch, not by minor: upstream's floating tags move under a
# consumer, and this base image is the whole of what the image ships. The
# variable is passed straight through as the Dockerfile's ARG, so the pin and
# the build cannot drift apart.
# renovate: datasource=docker depName=rustfs/rustfs versioning=docker
variable "RUSTFS_VERSION" {
  default = "1.0.3"
}

# A thin image on purpose: three defaults changed, a credential check, and the
# env contract. It starts upstream's /entrypoint.sh rather than reimplementing
# it, so the data and log directories come from upstream and not from here.
target "rustfs" {
  inherits   = ["_attested"]
  context    = "./images/rustfs"
  dockerfile = "Dockerfile"
  tags       = tag("rustfs", RUSTFS_VERSION)
  labels     = label("rustfs", RUSTFS_VERSION)

  # The shared env-config helper, as a named context rather than a copy under
  # images/rustfs/ (RFC 0001 decision 6).
  contexts = {
    shared = "./shared"
  }

  args = {
    RUSTFS_VERSION = RUSTFS_VERSION
  }
}

# ....................... #

# The one Python version for both uv-builder and python-distroless: uv-builder
# produces /opt/venv and python-distroless executes it, on every platform. It
# used to be two variables checked for matching major.minor (RFC 0008 sec 5.4),
# which still let the builder float to a newer patch than the runtime; one
# variable makes the pair the same build by construction. A Renovate bump here
# moves both images, and python:<patch>-trixie exists before al3xos publishes
# the same patch, so the distroless registry sets the pace.
#
# The annotation below must stay directly above `variable`, with nothing but
# whitespace between: the custom manager in .github/renovate.json matches
# `# renovate: ...\s+variable "..."`, so a comment in the gap silently unhooks
# the variable from Renovate entirely. This one sat above these lines until
# 2026-08-18 and had never produced a bump (EXECUTION-LOG A-42).
# renovate: datasource=docker depName=al3xos/python-distroless extractVersion=^(?<version>.+)-debian13$
variable "DISTROLESS_PYTHON_VERSION" {
  default = "3.14.8"

  # A full patch, never a minor: "3.14" resolves to whatever each registry's
  # floating tag points at today, and the two registries move independently.
  # regexall rather than regex so a bad value gets this message, not an HCL
  # "pattern did not match" from the uv-builder tag expression.
  validation {
    condition     = length(regexall("^[0-9]+\\.[0-9]+\\.[0-9]+$", DISTROLESS_PYTHON_VERSION)) > 0
    error_message = "DISTROLESS_PYTHON_VERSION must be an exact major.minor.patch. uv-builder and python-distroless both build on it, and a floating minor lets them become different Pythons."
  }
}

variable "DISTROLESS_DEBIAN_VERSION" {
  default = "13"
}

# Tagged with the minor and with the exact patch, the minor first, as uv-builder
# is. The minor tag is back because a consumer pinning python-distroless:3.14
# gets the weekly rebuild again without an edit, while a consumer on the patch
# keeps it; the patch tag is what pins a runtime to the builder that made its
# venv. tags[0] stays the minor, so CI and publish.yaml keep reading the
# repository from it. The labels name the exact patch either way.
target "python-distroless" {
  inherits   = ["_attested"]
  context    = "./images/python-distroless"
  dockerfile = "Dockerfile"
  tags = concat(
    tag("python-distroless", regex("^[0-9]+\\.[0-9]+", DISTROLESS_PYTHON_VERSION)),
    tag("python-distroless", DISTROLESS_PYTHON_VERSION),
  )
  labels     = label("python-distroless", DISTROLESS_PYTHON_VERSION)
  args = {
    PYTHON_VERSION = DISTROLESS_PYTHON_VERSION
    DEBIAN_VERSION = DISTROLESS_DEBIAN_VERSION
  }
}

# ....................... #

# The tag names two things: PgBouncer's version, and edoburu's own packaging
# revision of it as a `-p<x>` suffix. The suffix is not something the upstream
# project publishes and not something `versioning=` can be pointed at, so the
# docker versioning compares the tags as edoburu writes them, and the model
# below is only what a consumer is choosing between.
# renovate: datasource=docker depName=edoburu/pgbouncer versioning=docker
variable "PGBOUNCER_VERSION" {
  default = "v1.26.1-p0"
}

# PgBouncer's own version, out of the tag: `v1.26.0-p0` -> `1.26.0`. That is
# what the image is tagged and labelled with, because it is the version of the
# pooler inside -- and what `pgbouncer --version` prints, which
# images/pgbouncer/smoke.sh compares against the label, so a tag whose edoburu
# suffix moved to another upstream release cannot pass unnoticed.
#
# Matched rather than captured: the pattern has no group, so it returns the
# match itself whichever of `regex`'s two conventions bake's HCL follows.
# A value with no dotted triple in it fails the build here, naming this
# function, rather than shipping a tag like `latest`.
function "pgbouncer_version" {
  params = [tag]
  result = regex("[0-9]+\\.[0-9]+\\.[0-9]+", tag)
}

target "pgbouncer" {
  inherits   = ["_attested"]
  context    = "./images/pgbouncer"
  dockerfile = "Dockerfile"
  tags       = tag("pgbouncer", pgbouncer_version(PGBOUNCER_VERSION))
  labels     = label("pgbouncer", pgbouncer_version(PGBOUNCER_VERSION))

  # The shared env-config helper reaches this build as a named context rather
  # than a copy under images/pgbouncer/ (RFC 0001 decision 6). Every image that
  # sources envconf.sh declares this line; an image that forgets it fails to
  # build rather than shipping a stale copy.
  contexts = {
    shared = "./shared"
  }

  # The base image tag, passed under the name the Dockerfile gives it, so
  # .github/scripts/arg-defaults.sh compares the two and a Renovate bump that
  # touches only one of them fails the build (S-0002/D-1).
  args = {
    PGBOUNCER_IMAGE_TAG = PGBOUNCER_VERSION
  }
}

# ....................... #

group "default" {
  targets = [
    "flyway", "caddy", "postgres", "postgres-pgvector", "postgres-cron",
    "uv-builder", "npm-builder", "python-distroless", "valkey", "rustfs", "pgbouncer",
  ]
}
