# syntax=docker/dockerfile:1.28

ARG RUSTFS_VERSION=1.0.1

# Upstream publishes the server, the S3 endpoint on 9000 and its console on
# 9001, and runs as uid 10001 with /data as the volume. This image adds the
# environment contract (RFC 0001) and three defaults, and changes nothing else.
FROM rustfs/rustfs:${RUSTFS_VERSION}

# From the `shared` named context declared in docker-bake.hcl, not a copy in
# this directory: a target that does not declare the context cannot reference
# it, so the failure is a build error rather than a stale duplicate drifting
# out of sync (RFC 0001 decision 6).
#
# Modes are set by `--chmod` rather than by a following `RUN chmod`: the base
# image sets `USER rustfs` (uid 10001), so a `RUN` step is not root and cannot
# chmod files this layer's `COPY` leaves owned by root. `docker buildx` would
# fail the build outright rather than ship an entrypoint the runtime cannot
# execute (`bake-smoke` red on `chmod: Operation not permitted`). `--chmod`
# also pins the modes whatever a checkout's umask hands the shared context.
COPY --chmod=0644 --from=shared rootfs/lib/envconf.sh /usr/local/lib/envconf.sh

COPY --chmod=0644 rootfs/allowlist.conf /etc/rustfs/allowlist.conf
COPY --chmod=0644 rootfs/denylist.conf /etc/rustfs/denylist.conf
COPY --chmod=0755 rootfs/entrypoint.sh /usr/local/bin/rustfs-entrypoint

# The curated defaults live here as well as in the entrypoint, so `docker
# inspect` shows them and an entrypoint override still lands on them. The
# entrypoint's summary cannot tell a value set here from one set by an operator
# -- both are the same string in `environ` (RFC 0001 decision 13) -- which is
# why it attributes them `env-or-default`.
#
# RUSTFS_OBS_LOG_DIRECTORY is emptied on purpose. Upstream sets /logs, and a
# non-empty directory is where the server writes its log instead of stdout, so
# `docker logs` would show the entrypoint and nothing else.
ENV RUSTFS_ADDRESS=:9000 \
    RUSTFS_CONSOLE_ENABLE=false \
    RUSTFS_OBS_LOG_DIRECTORY=

# /data, already declared by the base image. RUSTFS_CONF__VOLUMES is refused
# rather than re-declared: the data directory is this image's contract with its
# volume mount, and moving it silently strands existing data.
ENTRYPOINT ["/usr/local/bin/rustfs-entrypoint"]
CMD []