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

# Refuses by default: both of its failure modes are silent. On the default
# buildx driver it publishes no attestations and says nothing about it (RFC 0002
# decision 2), and it skips the smoke gate decision 10 requires of every
# publishing run. The supported path is .github/workflows/publish.yaml, which
# builds by digest, smoke-tests that digest, then promotes the tags.

# Push every target, bypassing the CI smoke gate (refuses unless opted in).
publish:
    #!/usr/bin/env bash
    set -euo pipefail
    if [ "${I_KNOW_THIS_IS_UNGATED:-}" != "1" ]; then
        echo "refusing: this pushes without the smoke gate, and on the default" >&2
        echo "buildx driver it publishes no attestations without saying so." >&2
        echo "" >&2
        echo "Publish through CI (push to main, or run the workflow), or set" >&2
        echo "I_KNOW_THIS_IS_UNGATED=1 if you genuinely mean to bypass both." >&2
        exit 1
    fi
    echo "$(gh auth token)" | docker login {{ _reg }} -u dummy --password-stdin
    docker buildx bake -f {{ _bake }} --push

# Push an existing local tag.
push image tag: _login
    docker push {{ _reg }}/{{ _owner }}/{{ image }}:{{ tag }}
