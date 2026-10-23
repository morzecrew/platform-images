# This repository's claude seat: torve's published claude seat image, plus the
# static checks `.torve/gates.yaml` names. An attempt's battery and the lane's
# run in the executor seat's image, so the gate tools live in the seat; an image
# of their own would never be used. The docker CLI and buildx come from the
# base, on the version of the nested daemon, and without a daemon of their own:
# `bake --print` needs none, and `bake-smoke` drives the task's nested daemon
# through `DOCKER_HOST`.
#
#   docker build -t platform-claude-sandbox:2.1.283-torve0.6.3 .torve/sandbox/platform-claude
ARG BASE=ghcr.io/morzecrew/claude-sandbox:2.1.283-torve0.6.3
FROM hadolint/hadolint:v2.14.0 AS hadolint
FROM ${BASE}
RUN apt-get update \
 && apt-get install -y --no-install-recommends shellcheck \
 && rm -rf /var/lib/apt/lists/*
COPY --from=hadolint /bin/hadolint /usr/local/bin/hadolint
RUN shellcheck --version && hadolint --version && docker buildx version
