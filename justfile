set quiet
set shell := ["bash", "-cu"]

# ----------------------- #
# Paths / constants

_reg := "ghcr.io"
_owner := "morzecrew"
_bake := "docker-bake.hcl"

# ----------------------- #

default:
    @just --list

# Login to the registry.
_login:
    echo "$(gh auth token)" | docker login {{ _reg }} -u dummy --password-stdin

# ----------------------- #
# All builds go through Bake (`docker-bake.hcl` at repo root).

# Build one or more targets; omit names to build the `default` group.
bake *targets:
    docker buildx bake -f {{ _bake }} {{ targets }}

# Build and push every target in `docker-bake.hcl`.
publish: _login
    docker buildx bake -f {{ _bake }} --push

# Push an existing local tag.
push image tag: _login
    docker push {{ _reg }}/{{ _owner }}/{{ image }}:{{ tag }}
