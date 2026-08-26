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
  default = "13.4"
}

target "flyway" {
  inherits   = ["_attested"]
  context    = "./images/flyway"
  dockerfile = "Dockerfile"
  tags       = tag("flyway", FLYWAY_VERSION)
  labels     = label("flyway", FLYWAY_VERSION)
  args = {
    FLYWAY_VERSION          = FLYWAY_VERSION
    # renovate: datasource=maven depName=org.postgresql:postgresql
    POSTGRES_JDBC_VERSION   = "42.7.13"
    # renovate: datasource=maven depName=com.clickhouse:clickhouse-jdbc
    CLICKHOUSE_JDBC_VERSION = "0.10.0"
  }
}

# ....................... #

# renovate: datasource=docker depName=caddy versioning=docker
variable "CADDY_VERSION" {
  default = "2.11.4"
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
    CORAZA_CADDY_VERSION = "v2.6.0"
    # renovate: datasource=github-releases depName=coreruleset/coreruleset
    CRS_VERSION          = "v4.29.0"
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

# renovate: datasource=docker depName=ghcr.io/astral-sh/uv extractVersion=^python(?<version>.+)-trixie$
variable "BUILDER_PYTHON_VERSION" {
  default = "3.14"
}

variable "BUILDER_DEBIAN_SUITE" {
  default = "trixie"
}

target "uv-builder" {
  inherits   = ["_attested"]
  context    = "./images/uv-builder"
  dockerfile = "Dockerfile"
  tags       = tag("uv-builder", BUILDER_PYTHON_VERSION)
  labels     = label("uv-builder", BUILDER_PYTHON_VERSION)
  args = {
    PYTHON_VERSION = BUILDER_PYTHON_VERSION
    DEBIAN_SUITE   = BUILDER_DEBIAN_SUITE
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

# renovate: datasource=docker depName=valkey/valkey extractVersion=^(?<version>.+)-alpine$
variable "VALKEY_VERSION" {
  default = "9.1.1"
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

# Coupled to BUILDER_PYTHON_VERSION: uv-builder produces /opt/venv and
# python-distroless executes it, so a venv built for one minor and run by
# another gives native-module ABI failures at runtime, not at build. The two
# versions come from different registries and have independent renovate
# annotations, and renovate automerges -- so without this validation a builder
# bump that lands before the distroless base catches up ships a broken pair
# with no human in the loop. Compares major.minor only; the builder pins a
# minor (3.14) and the runtime a patch (3.14.6). See RFC 0008 sec 5.4.
#
# The annotation below must stay directly above `variable`, with nothing but
# whitespace between: the custom manager in .github/renovate.json matches
# `# renovate: ...\s+variable "..."`, so a comment in the gap silently unhooks
# the variable from Renovate entirely. This one sat above these lines until
# 2026-08-18 and had never produced a bump (EXECUTION-LOG A-42).
# renovate: datasource=docker depName=al3xos/python-distroless extractVersion=^(?<version>.+)-debian13$
variable "DISTROLESS_PYTHON_VERSION" {
  default = "3.14.6"

  # regexall, not split/slice: slice raises a bare "end index greater than the
  # length of the list" on a version with no minor (e.g. "3"), which replaces
  # the message below with an HCL internal error at exactly the moment someone
  # has set something odd. regexall returns [] instead of raising, and the
  # non-empty check then refuses a version that has no major.minor at all --
  # otherwise two malformed values would compare equal and pass.
  validation {
    condition = join("", regexall("^[0-9]+\\.[0-9]+", BUILDER_PYTHON_VERSION)) != "" && join("", regexall("^[0-9]+\\.[0-9]+", BUILDER_PYTHON_VERSION)) == join("", regexall("^[0-9]+\\.[0-9]+", DISTROLESS_PYTHON_VERSION))
    error_message = "Python version drift: BUILDER_PYTHON_VERSION and DISTROLESS_PYTHON_VERSION must agree on major.minor, and both must start with one. uv-builder builds the venv that python-distroless runs; a mismatch fails at runtime, not at build."
  }
}

variable "DISTROLESS_DEBIAN_VERSION" {
  default = "13"
}

target "python-distroless" {
  inherits   = ["_attested"]
  context    = "./images/python-distroless"
  dockerfile = "Dockerfile"
  tags       = tag("python-distroless", DISTROLESS_PYTHON_VERSION)
  labels     = label("python-distroless", DISTROLESS_PYTHON_VERSION)
  args = {
    PYTHON_VERSION = DISTROLESS_PYTHON_VERSION
    DEBIAN_VERSION = DISTROLESS_DEBIAN_VERSION
  }
}

# ....................... #

group "default" {
  targets = [
    "flyway", "caddy", "postgres", "postgres-pgvector", "postgres-cron",
    "uv-builder", "npm-builder", "python-distroless", "valkey",
  ]
}
