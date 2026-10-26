# syntax=docker/dockerfile:1.28

# ....................... #

# The tag edoburu publishes, not PgBouncer's own version: `-p0` is their
# packaging revision of a PgBouncer release, and docker-bake.hcl derives
# `1.26.0` from this value for the image's tag and label. The default keeps a
# bare `docker build images/pgbouncer` working, and
# .github/scripts/arg-defaults.sh fails the build if it drifts from the bake
# (S-0002/D-1).
# renovate: datasource=docker depName=edoburu/pgbouncer versioning=docker
ARG PGBOUNCER_IMAGE_TAG=v1.26.1-p0

# Alpine, so RFC 0001's POSIX-sh helper runs unmodified with no added bash
# (RFC 0001 decision 7).
#
# The base image ships /etc/pgbouncer owned by the `postgres` user it runs as,
# with an empty userlist.txt and an example config -- which is what this image
# needs, since the entrypoint writes both files on every start.
FROM edoburu/pgbouncer:${PGBOUNCER_IMAGE_TAG}

# From the `shared` named context declared in docker-bake.hcl, not a copy in
# this directory: a target that does not declare the context cannot reference
# it, so the failure is a build error rather than a stale duplicate drifting
# out of sync (RFC 0001 decision 6).
COPY --from=shared --chmod=0644 rootfs/lib/envconf.sh /usr/local/lib/envconf.sh

# --chmod rather than a RUN: the base image's USER is `postgres`, so a RUN step
# could not chmod files COPY created as root. Files stay root-owned and
# readable, and /etc/pgbouncer is where the entrypoint writes as postgres.
COPY --chmod=0644 rootfs/allowlist.conf /etc/pgbouncer/allowlist.conf
COPY --chmod=0644 rootfs/denylist.conf /etc/pgbouncer/denylist.conf
COPY --chmod=0755 rootfs/entrypoint.sh /usr/local/bin/pgbouncer-entrypoint

# The /bin/setpriv this base image carries is busybox's, and busybox's setpriv
# has no --reuid, --regid or --clear-groups: the entrypoint's drop-to-postgres
# command fails on it with "unrecognized option: reuid" (S-0003/D-1). Alpine
# ships util-linux's as a package of its own name, which has all three. `apk`
# needs root, which the base image's USER is not, so the switch is made here
# and stands for the rest of the file -- including the USER at the end, whose
# job is the image's runtime uid rather than this install.
USER root
RUN apk add --no-cache setpriv

# 6432, which is what PGBOUNCER_LISTEN_PORT defaults to and what the entrypoint
# writes. The base image's own EXPOSE names 5432 -- the port edoburu's
# generated config listens on -- and EXPOSE is additive, so the metadata names
# both. Nothing listens on 5432.
EXPOSE 6432

ENTRYPOINT ["/usr/local/bin/pgbouncer-entrypoint"]

# Declaring ENTRYPOINT drops the CMD inherited from upstream, which was
# edoburu's own entrypoint and config file. This image's entrypoint writes the
# config itself and execs the pooler with the path it wrote, so there is no
# default command left to name.
CMD []

# Root, so the entrypoint can read a `PGBOUNCER_DB_PASSWORD_FILE` owned by any
# uid at any mode and give what it writes to the user PgBouncer runs as: it
# chowns pgbouncer.ini and userlist.txt to 70:70 and execs the pooler under
# `setpriv --reuid=70 --regid=70 --clear-groups`. PgBouncer itself never runs
# as root. A container started with `user:` is that uid from the first
# instruction, root's duties are skipped, and the password file has to be
# readable by it (S-0003/D-1, README.md).
# hadolint ignore=DL3002
USER root