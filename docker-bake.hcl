function "tag" {
  params = [name, version]
  result = ["ghcr.io/morzecrew/${name}:${version}"]
}

# ....................... #

variable "FLYWAY_VERSION" {
  default = "12.7"
}

target "flyway" {
  context    = "./images/flyway"
  dockerfile = "Dockerfile"
  tags       = tag("flyway", FLYWAY_VERSION)
  args = {
    FLYWAY_VERSION          = FLYWAY_VERSION
    POSTGRES_JDBC_VERSION   = "42.7.11" # pin manually to avoid drift
    CLICKHOUSE_JDBC_VERSION = "0.9.8" # pin manually to avoid drift
  }
}

# ....................... #

variable "CADDY_VERSION" {
  default = "2.11.3"
}

target "caddy" {
  context    = "./images/caddy"
  dockerfile = "Dockerfile"
  tags       = tag("caddy", CADDY_VERSION)
  args = {
    CADDY_VERSION        = CADDY_VERSION
    CORAZA_CADDY_VERSION = "v2.5.0" # pin manually to avoid drift
    CRS_VERSION          = "v4.26.0" # pin manually to avoid drift
    MHOLT_RL_SHA         = "16aecbbcb8ca07dc1c671e263379606ff9493c55" # pin manually to avoid drift
  }
}

# ....................... #

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

variable "PYTHON_VERSION" {
  default = "3.14"
}

variable "DEBIAN_SUITE" {
  default = "trixie"
}

variable "DISTROLESS_DEBIAN_VERSION" {
  default = "13"
}

target "uv-builder" {
  context    = "./images/uv-builder"
  dockerfile = "Dockerfile"
  tags       = tag("uv-builder", PYTHON_VERSION)
  args = {
    PYTHON_VERSION = PYTHON_VERSION
    DEBIAN_SUITE   = DEBIAN_SUITE
  }
}

target "python-distroless" {
  context    = "./images/python-distroless"
  dockerfile = "Dockerfile"
  tags       = tag("python-distroless", PYTHON_VERSION)
  args = {
    PYTHON_VERSION = PYTHON_VERSION
    DEBIAN_VERSION = DISTROLESS_DEBIAN_VERSION
  }
}

# ....................... #

group "default" {
  targets = ["flyway", "caddy", "postgres", "uv-builder", "python-distroless"]
}
