# syntax=docker/dockerfile:1.26

ARG PYTHON_VERSION=3.14.8
ARG DEBIAN_SUITE=trixie
ARG UV_VERSION=0.12.24

FROM ghcr.io/astral-sh/uv:${UV_VERSION} AS uv

# The official image on an exact patch, not ghcr.io/astral-sh/uv:python<minor>:
# Astral tags minors only, so the builder floated to the newest patch while
# python-distroless stayed on its pin, and the pair was never the same build.
# python-distroless's /usr/local is an official python build too, so one patch
# here and there gives the same CPython version, configure flags and glibc on
# every platform (compared via sysconfig on amd64 and arm64). The COPY, ENV and
# CMD below are what Astral's tag adds.
FROM python:${PYTHON_VERSION}-${DEBIAN_SUITE}

COPY --from=uv /uv /uvx /usr/local/bin/

ENV UV_TOOL_BIN_DIR=/usr/local/bin \
    PIP_DEFAULT_TIMEOUT=10 \
    PYTHONFAULTHANDLER=1 \
    PYTHONUNBUFFERED=1 \
    PYTHONDONTWRITEBYTECODE=1 \
    PIP_DISABLE_PIP_VERSION_CHECK=1 \
    PIP_NO_CACHE_DIR=1 \
    UV_PROJECT_ENVIRONMENT=/opt/venv \
    UV_LINK_MODE=copy \
    UV_NO_PROGRESS=1

SHELL ["/bin/bash", "-o", "pipefail", "-c"]

RUN apt-get update && apt-get install -y --no-install-recommends \
    bash \
    binutils \
    ca-certificates \
    findutils \
    && rm -rf /var/lib/apt/lists/*

COPY rootfs/build.sh /usr/local/bin/build-uv-app
RUN chmod +x /usr/local/bin/build-uv-app

WORKDIR /app

CMD ["/usr/local/bin/uv"]
