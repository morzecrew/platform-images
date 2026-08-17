# syntax=docker/dockerfile:1.26

# ....................... #

ARG POSTGRES_IMAGE_TAG=18.1

FROM postgres:${POSTGRES_IMAGE_TAG}

ARG POSTGRES_IMAGE_TAG

# Which extensions to install. Every name must appear in
# rootfs/extensions.manifest; an unknown one fails the build rather than
# quietly producing a smaller image. See RFC 0004.
ARG PG_EXTENSIONS="cron pgroonga"

# The extensions label is written here, from the same string that drives the
# install, rather than in docker-bake.hcl beside the tags (RFC 0004 §5.3's
# sketch put it there). Two literals -- one for `args`, one for `labels` -- can
# disagree, and `--set postgres.args.PG_EXTENSIONS=pgroonga` proved it: the image
# installed pgroonga alone and went on claiming `cron pgroonga`, which decision
# 10 (`LOCKED`) forbids. From here it cannot disagree, because there is one
# string; and build-extensions refuses a non-canonical spelling, so the one
# string is the canonical one decision 10 requires.
LABEL io.morze.postgres.extensions="${PG_EXTENSIONS}"

# ....................... #
# Install extensions and generate their config
#
# The preload line in conf.d/10-extensions.conf is generated from PG_EXTENSIONS
# by the same script that installs the packages, so it cannot name a library
# that is not there -- which is a fatal startup error, not a warning.

COPY rootfs/extensions.manifest /usr/local/share/postgres-extensions/extensions.manifest
COPY rootfs/conf.d/ /usr/local/share/postgres-extensions/conf.d/
COPY rootfs/build-extensions.sh /usr/local/bin/build-extensions

RUN set -eux; \
    chmod +x /usr/local/bin/build-extensions; \
    PG_MAJOR="${POSTGRES_IMAGE_TAG%%.*}" \
    PG_EXTENSIONS="${PG_EXTENSIONS}" \
    build-extensions

# ....................... #
# Copy configuration files

COPY rootfs/postgresql.conf /etc/postgresql.conf

RUN chown -R postgres:postgres /etc/postgresql

COPY rootfs/allowlist.conf /etc/postgresql/allowlist.conf
# The denylist is data too, and lives beside the allowlist so the whole policy
# reads in one place (RFC 0001 §5.4).
COPY rootfs/denylist.conf /etc/postgresql/denylist.conf
RUN chown postgres:postgres /etc/postgresql/allowlist.conf /etc/postgresql/denylist.conf \
    && chmod 0644 /etc/postgresql/allowlist.conf /etc/postgresql/denylist.conf

# The shared env-config helper, from the `shared` named context wired up in
# docker-bake.hcl (RFC 0001 decision 6). A target that does not declare the
# context cannot reference it, so a stale copy is not a failure mode here.
COPY --from=shared rootfs/lib/envconf.sh /usr/local/lib/envconf.sh

COPY rootfs/entrypoint.sh /usr/local/bin/entrypoint-merge.sh
RUN chmod +x /usr/local/bin/entrypoint-merge.sh

# ....................... #
# Entrypoint

ENTRYPOINT ["/usr/local/bin/entrypoint-merge.sh"]
CMD ["postgres", "-c", "config_file=/etc/postgresql.conf"]
