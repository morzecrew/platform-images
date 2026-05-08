# Tags use short version identifiers (image name already disambiguates stacks).
# Each *args value tied to a tag should come from the same variable so drift is impossible.

variable "REGISTRY" {
  default = "ghcr.io"
}

variable "OWNER" {
  default = "morzecrew"
}

variable "FLYWAY_VERSION" {
  default = "12.5"
}

variable "CADDY_VERSION" {
  default = "2.11"
}

variable "PG_MAJOR" {
  default = "18"
}

variable "POSTGRES_IMAGE_TAG" {
  default = "18.1"
}

variable "PYTHON_VERSION" {
  default = "3.14"
}

variable "DEBIAN_SUITE" {
  default = "trixie"
}

variable "DISTROLESS_DEBIAN_VERSION" {
  default = "13"
}

target "flyway" {
  context    = "./images/flyway"
  dockerfile = "Dockerfile"
  tags       = ["${REGISTRY}/${OWNER}/flyway:${FLYWAY_VERSION}"]
  args = {
    FLYWAY_VERSION          = FLYWAY_VERSION
    POSTGRES_JDBC_VERSION   = "42.7.11"
    CLICKHOUSE_JDBC_VERSION = "0.9.8"
  }
}

target "caddy" {
  context    = "./images/caddy"
  dockerfile = "Dockerfile"
  tags       = ["${REGISTRY}/${OWNER}/caddy:${CADDY_VERSION}"]
  args = {
    CADDY_VERSION        = CADDY_VERSION
    CORAZA_CADDY_VERSION = "v2.1.0"
    CRS_VERSION          = "v4.24.0"
    MHOLT_RL_SHA         = "b8d8c9a9d99ee352d675cbbe416ec2b489fc8cab"
  }
}

target "postgres" {
  context    = "./images/postgres"
  dockerfile = "Dockerfile"
  tags       = ["${REGISTRY}/${OWNER}/postgres:${PG_MAJOR}"]
  args = {
    POSTGRES_IMAGE_TAG = POSTGRES_IMAGE_TAG
    PG_MAJOR           = PG_MAJOR
  }
}

target "uv-builder" {
  context    = "./images/uv-builder"
  dockerfile = "Dockerfile"
  tags       = ["${REGISTRY}/${OWNER}/uv-builder:${PYTHON_VERSION}"]
  args = {
    PYTHON_VERSION = PYTHON_VERSION
    DEBIAN_SUITE   = DEBIAN_SUITE
  }
}

target "python-distroless" {
  context    = "./images/python-distroless"
  dockerfile = "Dockerfile"
  tags       = ["${REGISTRY}/${OWNER}/python-distroless:${PYTHON_VERSION}"]
  args = {
    PYTHON_VERSION = PYTHON_VERSION
    DEBIAN_VERSION = DISTROLESS_DEBIAN_VERSION
  }
}

group "default" {
  targets = ["flyway", "caddy", "postgres", "uv-builder", "python-distroless"]
}
