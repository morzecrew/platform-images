# syntax=docker/dockerfile:1.26

# ....................... #

ARG POSTGRES_IMAGE_TAG=18.1

FROM postgres:${POSTGRES_IMAGE_TAG}

ARG POSTGRES_IMAGE_TAG

# Which extensions to install. Every name must appear in
# rootfs/extensions.manifest; an unknown one fails the build rather than
# quietly producing a smaller image. See RFC 0004.
ARG PG_EXTENSIONS="cron pgroonga"

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
RUN chown postgres:postgres /etc/postgresql/allowlist.conf \
    && chmod 0644 /etc/postgresql/allowlist.conf

COPY rootfs/entrypoint.sh /usr/local/bin/entrypoint-merge.sh
RUN chmod +x /usr/local/bin/entrypoint-merge.sh

# ....................... #
# Entrypoint

ENTRYPOINT ["/usr/local/bin/entrypoint-merge.sh"]
CMD ["postgres", "-c", "config_file=/etc/postgresql.conf"]
