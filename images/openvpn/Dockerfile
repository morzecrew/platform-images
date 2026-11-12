# syntax=docker/dockerfile:1.29

# The Alpine release whose openvpn package this image ships. The base floats
# within it, so the weekly rebuild brings musl, OpenSSL and the CA bundle
# current.
# renovate: datasource=docker depName=alpine versioning=docker
ARG ALPINE_VERSION=3.22
# That release's openvpn package, by Repology's name for it, which names the
# release too: moving ALPINE_VERSION moves the depName with it. Alpine keeps
# one version per branch, so the build below refuses a package that has moved
# on rather than ship it under this tag.
# renovate: datasource=repology depName=alpine_3_22/openvpn versioning=loose
ARG OPENVPN_VERSION=2.6.20

FROM alpine:${ALPINE_VERSION}
ARG ALPINE_VERSION
ARG OPENVPN_VERSION

# iproute2 rather than busybox's ip: the entrypoint reads `ip -o route get`.
RUN apk add --no-cache openvpn iproute2 \
    && installed="$(openvpn --version | sed -n '1s/^OpenVPN \([0-9][0-9.]*\) .*/\1/p')" \
    && { [ "${installed}" = "${OPENVPN_VERSION}" ] \
         || { echo "Alpine ${ALPINE_VERSION} ships openvpn ${installed}, not ${OPENVPN_VERSION}: move OPENVPN_VERSION in docker-bake.hcl" >&2; exit 1; }; }

COPY --from=shared rootfs/lib/envconf.sh /usr/local/lib/envconf.sh
COPY rootfs/entrypoint.sh /usr/local/bin/openvpn-entrypoint
RUN chmod 0755 /usr/local/bin/openvpn-entrypoint && chmod 0644 /usr/local/lib/envconf.sh

# Root, because openvpn needs NET_ADMIN for its tun device and routes, and the
# entrypoint for the kill switch. openvpn insists on a writable --tmp-dir,
# which the entrypoint points at /dev/shm, a tmpfs Docker and Podman mount
# even under a read-only root, so a read-only root needs nothing more. No
# OPENVPN_CONFIG here: the entrypoint's default is /etc/openvpn/client.conf,
# and set, it would stand in the way of OPENVPN_UPSTREAMS.

ENTRYPOINT ["/usr/local/bin/openvpn-entrypoint"]
CMD ["run"]
