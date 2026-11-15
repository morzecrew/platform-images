# syntax=docker/dockerfile:1.29

# Upstream's Caddy with one module built in, mholt/caddy-l4, so a server can
# route connections by what they start with, such as a TLS ClientHello's
# server name, before any HTTP: chosen names passed through as raw TCP to a
# backend that terminates TLS itself, everything else on to the HTTP app as
# before. Otherwise upstream's alpine image as it is: the same binary path,
# Caddyfile, command, user and shell. The binary is static, so it can also be
# copied out onto a machine that runs Caddy as a service. Not a variant of
# images/caddy (Coraza, CRS, a platform Caddyfile) or images/caddy-acmedns.

# ....................... #

# renovate: datasource=docker depName=caddy versioning=docker
ARG CADDY_VERSION="2.11.9"
# renovate: datasource=github-releases depName=mholt/caddy-l4
ARG L4_VERSION="v0.1.3"

# ....................... #

FROM caddy:${CADDY_VERSION}-builder AS builder

ARG L4_VERSION

RUN xcaddy build --with "github.com/mholt/caddy-l4@${L4_VERSION}"

# ....................... #

FROM caddy:${CADDY_VERSION}-alpine

COPY --from=builder /usr/bin/caddy /usr/bin/caddy

# The builder leaves the binary cap_net_bind_service=ep. With the effective
# bit set, execve refuses it where the capability is not granted, as under
# cap_drop ALL ("operation not permitted", exit 255). Upstream's image gives
# it +p alone: a low port where the capability is granted, a start anywhere.
RUN setcap cap_net_bind_service=+p /usr/bin/caddy
