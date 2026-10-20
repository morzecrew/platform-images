# The image torve runs this repository's shell gates in (`runtime.image`):
# torve's base, plus the static checks `.torve/gates.yaml` names. The docker CLI
# comes without a daemon: `bake --print` needs none, and `bake-smoke` drives the
# task's nested daemon through `DOCKER_HOST`.
#
#   docker build -t platform-gates-sandbox:2 .torve/sandbox/platform-gates
ARG BASE=ghcr.io/morzecrew/sandbox-base:0.5.0
FROM hadolint/hadolint:v2.14.0 AS hadolint
FROM docker:28-cli AS docker
FROM ${BASE}
RUN apt-get update \
 && apt-get install -y --no-install-recommends shellcheck \
 && rm -rf /var/lib/apt/lists/*
COPY --from=hadolint /bin/hadolint /usr/local/bin/hadolint
COPY --from=docker /usr/local/bin/docker /usr/local/bin/docker
COPY --from=docker /usr/local/libexec/docker/cli-plugins/docker-buildx /usr/local/libexec/docker/cli-plugins/docker-buildx
RUN shellcheck --version && hadolint --version && docker buildx version
