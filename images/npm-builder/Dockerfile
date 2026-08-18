# syntax=docker/dockerfile:1.26

ARG NODE_VERSION=24
ARG DEBIAN_SUITE=trixie

FROM node:${NODE_VERSION}-${DEBIAN_SUITE}

# The npm store lives at a fixed, documented path so a consumer's
# `RUN --mount=type=cache,target=/cache` has something stable to mount over.
# The image cannot carry the mount itself -- that is a flag on the consumer's
# RUN instruction -- so the contract this image can keep is the path.
# See images/npm-builder/README.md and RFC 0009 decision 12.
ENV npm_config_cache=/cache \
    npm_config_update_notifier=false \
    npm_config_fund=false \
    npm_config_audit=false \
    npm_config_progress=false

# Two variables are deliberately NOT set here, both of which look like obvious
# build-stage hygiene and both of which break real builds:
#
#   NODE_ENV=production  -- makes `npm ci` skip devDependencies, and the build
#                           tool itself (vite, react-scripts, next) is a
#                           devDependency in all five projects. The install
#                           succeeds and the build then fails on a missing
#                           binary, which reads as a project bug.
#   CI=true              -- react-scripts turns warnings into errors under it,
#                           so a project that builds locally fails here for
#                           reasons that have nothing to do with this image.
#
# A project that wants either can set it; the builder does not decide it.

SHELL ["/bin/bash", "-o", "pipefail", "-c"]

COPY rootfs/build.sh /usr/local/bin/build-js-app
RUN chmod +x /usr/local/bin/build-js-app

WORKDIR /app
