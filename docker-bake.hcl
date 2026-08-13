# Set by publish CI; empty locally so `just bake` stays cache-stable and does
# not rebuild every layer on each invocation.
variable "GIT_REVISION" {
  default = ""
}

variable "BUILD_DATE" {
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
    "postgres"          = "PostgreSQL with pg_cron and pgroonga, allowlist-based config overrides via env."
    "uv-builder"        = "uv-based Python build stage: sync, wheel, slim venv via build-uv-app."
    "python-distroless" = "Distroless Python runtime with libmagic and CA bundle."
  }
}

function "tag" {
  params = [name, version]
  result = ["ghcr.io/morzecrew/${name}:${version}"]
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
  default = "13.3"
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
    CLICKHOUSE_JDBC_VERSION = "0.9.8"
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
  args = {
    CADDY_VERSION        = CADDY_VERSION
    # renovate: datasource=github-releases depName=corazawaf/coraza-caddy
    CORAZA_CADDY_VERSION = "v2.5.0"
    # renovate: datasource=github-releases depName=coreruleset/coreruleset
    CRS_VERSION          = "v4.28.0"
    MHOLT_RL_SHA         = "16aecbbcb8ca07dc1c671e263379606ff9493c55"
  }
}

# ....................... #

# renovate: datasource=docker depName=postgres versioning=docker
variable "POSTGRES_VERSION" {
  default = "18.4"
}

target "postgres" {
  inherits   = ["_attested"]
  context    = "./images/postgres"
  dockerfile = "Dockerfile"
  tags       = tag("postgres", POSTGRES_VERSION)
  labels     = label("postgres", POSTGRES_VERSION)
  args = {
    POSTGRES_IMAGE_TAG = POSTGRES_VERSION
  }
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

# renovate: datasource=docker depName=al3xos/python-distroless extractVersion=^(?<version>.+)-debian13$
#
# Coupled to BUILDER_PYTHON_VERSION: uv-builder produces /opt/venv and
# python-distroless executes it, so a venv built for one minor and run by
# another gives native-module ABI failures at runtime, not at build. The two
# versions come from different registries and have independent renovate
# annotations, and renovate automerges -- so without this validation a builder
# bump that lands before the distroless base catches up ships a broken pair
# with no human in the loop. Compares major.minor only; the builder pins a
# minor (3.14) and the runtime a patch (3.14.6). See RFC 0008 sec 5.4.
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
  targets = ["flyway", "caddy", "postgres", "uv-builder", "python-distroless"]
}
