# syntax=docker/dockerfile:1.29

# ....................... #

# renovate: datasource=docker depName=postgres versioning=docker
ARG POSTGRES_IMAGE_TAG=18.7

FROM postgres:${POSTGRES_IMAGE_TAG}

ARG POSTGRES_IMAGE_TAG

# Which extensions to install. Every name must appear in
# rootfs/extensions.manifest; an unknown one fails the build rather than
# quietly producing a smaller image. See S-0001/D-19.
ARG PG_EXTENSIONS="cron pgroonga"

# The extensions label is written here, from the same string that drives the
# install, rather than in docker-bake.hcl beside the tags (S-0001/D-19 puts it
# here). Two literals -- one for `args`, one for `labels` -- can
# disagree, and `--set postgres.args.PG_EXTENSIONS=pgroonga` proved it: the image
# installed pgroonga alone and went on claiming `cron pgroonga`, which
# S-0001/D-19 forbids. From here it cannot disagree, because there is one
# string; and build-extensions refuses a non-canonical spelling, so the one
# string is the canonical spelling the label must carry.
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
# reads in one place.
COPY rootfs/denylist.conf /etc/postgresql/denylist.conf
RUN chown postgres:postgres /etc/postgresql/allowlist.conf /etc/postgresql/denylist.conf \
    && chmod 0644 /etc/postgresql/allowlist.conf /etc/postgresql/denylist.conf

# The shared env-config helper, from the `shared` named context wired up in
# docker-bake.hcl (S-0001/D-17). A target that does not declare the
# context cannot reference it, so a stale copy is not a failure mode here.
COPY --from=shared rootfs/lib/envconf.sh /usr/local/lib/envconf.sh

COPY rootfs/entrypoint.sh /usr/local/bin/entrypoint-merge.sh
RUN chmod +x /usr/local/bin/entrypoint-merge.sh

# ....................... #
# Memory a backend keeps
#
# A backend keeps the most memory its queries have ever allocated. glibc raises
# its mmap threshold each time a large mmapped block is freed, so the next big
# sort or hash is served from the heap and freed there, without being returned.
# Behind a pooler the backends live for days and their high-water marks add up:
# 6.8 GB of anonymous memory on a small host, against 2.6 GB with these two set
# (#122). Fixing either threshold turns the dynamic one off. glibc ignores a
# misspelt tunable in silence, so smoke.sh asks ld.so what it took.
#
# glibc's own variable, not this image's: setting it replaces the whole value,
# and setting it empty gives glibc's defaults back.
ENV GLIBC_TUNABLES=glibc.malloc.mmap_threshold=131072:glibc.malloc.trim_threshold=131072

# ....................... #
# Entrypoint

ENTRYPOINT ["/usr/local/bin/entrypoint-merge.sh"]
CMD ["postgres", "-c", "config_file=/etc/postgresql.conf"]
