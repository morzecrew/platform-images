# syntax=docker/dockerfile:1.7

ARG PYTHON_VERSION=3.14
ARG DEBIAN_SUITE=trixie

FROM ghcr.io/astral-sh/uv:python${PYTHON_VERSION}-${DEBIAN_SUITE}

ARG HTTP_PROXY
ARG HTTPS_PROXY
ARG NO_PROXY

ENV PIP_DEFAULT_TIMEOUT=10 \
    PYTHONFAULTHANDLER=1 \
    PYTHONUNBUFFERED=1 \
    PYTHONDONTWRITEBYTECODE=1 \
    PIP_DISABLE_PIP_VERSION_CHECK=1 \
    PIP_NO_CACHE_DIR=1 \
    UV_PROJECT_ENVIRONMENT=/opt/venv \
    UV_LINK_MODE=copy \
    UV_NO_PROGRESS=1 \
    HTTP_PROXY=${HTTP_PROXY} \
    HTTPS_PROXY=${HTTPS_PROXY} \
    NO_PROXY=${NO_PROXY}

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