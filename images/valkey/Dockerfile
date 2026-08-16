# syntax=docker/dockerfile:1.26

ARG VALKEY_VERSION=9.0

# Alpine, so RFC 0001's POSIX-sh helper runs unmodified with no added bash
# (RFC 0006 decision 9, RFC 0001 decision 7).
FROM valkey/valkey:${VALKEY_VERSION}-alpine

# From the `shared` named context declared in docker-bake.hcl, not a copy in
# this directory: a target that does not declare the context cannot reference
# it, so the failure is a build error rather than a stale duplicate drifting
# out of sync (RFC 0001 decision 6).
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
# and before the environment, which is the precedence RFC 0001 decision 3 fixes.
VOLUME /data

ENTRYPOINT ["/usr/local/bin/valkey-entrypoint"]
CMD []
