# syntax=docker/dockerfile:1.29

# renovate: datasource=docker depName=valkey/valkey extractVersion=^(?<version>\d+\.\d+)\.\d+-alpine$
ARG VALKEY_VERSION=9.1

# Alpine, so the shared POSIX-sh helper runs unmodified with no added bash
# (S-0001/D-20, S-0001/D-17).
FROM valkey/valkey:${VALKEY_VERSION}-alpine

# From the `shared` named context declared in docker-bake.hcl, not a copy in
# this directory: a target that does not declare the context cannot reference
# it, so the failure is a build error rather than a stale duplicate drifting
# out of sync (S-0001/D-17).
COPY --from=shared rootfs/lib/envconf.sh /usr/local/lib/envconf.sh

COPY rootfs/allowlist.conf /etc/valkey/allowlist.conf
COPY rootfs/denylist.conf /etc/valkey/denylist.conf
COPY rootfs/entrypoint.sh /usr/local/bin/valkey-entrypoint

RUN chmod 0755 /usr/local/bin/valkey-entrypoint \
    && chmod 0644 /usr/local/lib/envconf.sh /etc/valkey/allowlist.conf /etc/valkey/denylist.conf \
    && mkdir -p /etc/valkey/conf.d \
    && chown -R valkey:valkey /etc/valkey

# Mount fragments here to set directives the curated variables and the
# passthrough allowlist do not cover. They are read after the baked defaults
# and before the environment, which is the precedence S-0001/D-15 fixes.
VOLUME /data

ENTRYPOINT ["/usr/local/bin/valkey-entrypoint"]
CMD []
