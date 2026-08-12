function "tag" {
  params = [name, version]
  result = ["ghcr.io/morzecrew/${name}:${version}"]
}

# MIT covers the Dockerfiles and config here; bundled upstream software keeps
# its own license.
function "label" {
  params = [name, version]
  result = {
    "org.opencontainers.image.title"    = name
    "org.opencontainers.image.version"  = version
    "org.opencontainers.image.licenses" = "MIT"
    "org.opencontainers.image.vendor"   = "Morze Technologies"
    "org.opencontainers.image.source"   = "https://github.com/morzecrew/platform-images"
  }
}

# ....................... #

# renovate: datasource=docker depName=flyway/flyway versioning=docker
variable "FLYWAY_VERSION" {
  default = "13.2"
}

target "flyway" {
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

  validation {
    condition = join(".", slice(split(".", BUILDER_PYTHON_VERSION), 0, 2)) == join(".", slice(split(".", DISTROLESS_PYTHON_VERSION), 0, 2))
    error_message = "Python version drift: BUILDER_PYTHON_VERSION and DISTROLESS_PYTHON_VERSION must agree on major.minor. uv-builder builds the venv that python-distroless runs; a mismatch fails at runtime, not at build."
  }
}

variable "DISTROLESS_DEBIAN_VERSION" {
  default = "13"
}

target "python-distroless" {
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
