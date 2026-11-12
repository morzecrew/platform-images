# syntax=docker/dockerfile:1.29

# Upstream's Caddy with one module built in, caddy-dns/acmedns, so a site can
# take its certificate, a wildcard included, through a DNS-01 check delegated
# by one CNAME to an acme-dns server, whatever hosts its DNS. Otherwise
# upstream's alpine image as it is: the same binary path, Caddyfile, command,
# user and shell, so a bundle that runs upstream's image runs this one in its
# place. Not a variant of images/caddy, which brings Coraza, CRS and a platform
# Caddyfile with an entrypoint of its own.

# ....................... #

# renovate: datasource=docker depName=caddy versioning=docker
ARG CADDY_VERSION="2.11.9"
# renovate: datasource=github-releases depName=caddy-dns/acmedns
ARG ACMEDNS_VERSION="v0.7.0"

# ....................... #

FROM caddy:${CADDY_VERSION}-builder AS builder

ARG ACMEDNS_VERSION

RUN xcaddy build --with "github.com/caddy-dns/acmedns@${ACMEDNS_VERSION}"

# ....................... #

FROM caddy:${CADDY_VERSION}-alpine

COPY --from=builder /usr/bin/caddy /usr/bin/caddy

# The builder leaves the binary cap_net_bind_service=ep. With the effective
# bit set, execve refuses it where the capability is not granted, as under
# cap_drop ALL ("operation not permitted", exit 255). Upstream's image gives
# it +p alone: a low port where the capability is granted, a start anywhere.
RUN setcap cap_net_bind_service=+p /usr/bin/caddy
