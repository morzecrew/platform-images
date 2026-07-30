function "tag" {
  params = [name, version]
  result = ["ghcr.io/morzecrew/${name}:${version}"]
}

# ....................... #

# renovate: datasource=docker depName=flyway/flyway versioning=docker
variable "FLYWAY_VERSION" {
  default = "13.1"
}

target "flyway" {
  context    = "./images/flyway"
  dockerfile = "Dockerfile"
  tags       = tag("flyway", FLYWAY_VERSION)
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
  args = {
    PYTHON_VERSION = BUILDER_PYTHON_VERSION
    DEBIAN_SUITE   = BUILDER_DEBIAN_SUITE
  }
}

# ....................... #

# renovate: datasource=docker depName=al3xos/python-distroless extractVersion=^(?<version>.+)-debian13$
variable "DISTROLESS_PYTHON_VERSION" {
  default = "3.14.5"
}

variable "DISTROLESS_DEBIAN_VERSION" {
  default = "13"
}

target "python-distroless" {
  context    = "./images/python-distroless"
  dockerfile = "Dockerfile"
  tags       = tag("python-distroless", DISTROLESS_PYTHON_VERSION)
  args = {
    PYTHON_VERSION = DISTROLESS_PYTHON_VERSION
    DEBIAN_VERSION = DISTROLESS_DEBIAN_VERSION
  }
}

# ....................... #

group "default" {
  targets = ["flyway", "caddy", "postgres", "uv-builder", "python-distroless"]
}
