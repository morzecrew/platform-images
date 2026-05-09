# syntax=docker/dockerfile:1.7

# ....................... #

ARG CADDY_VERSION="2.11"
ARG CORAZA_CADDY_VERSION="v2.1.0"
ARG CRS_VERSION="v4.24.0"
ARG MHOLT_RL_SHA="b8d8c9a9d99ee352d675cbbe416ec2b489fc8cab"

# ....................... #
# Build with Coraza WAF + mholt/caddy-ratelimit

FROM caddy:${CADDY_VERSION}-builder AS builder

ARG CORAZA_CADDY_VERSION
ARG MHOLT_RL_SHA

RUN xcaddy build \
    --with "github.com/corazawaf/coraza-caddy/v2@${CORAZA_CADDY_VERSION}" \
    --with "github.com/mholt/caddy-ratelimit@${MHOLT_RL_SHA}"

# ....................... #
# Get CRS rules

FROM caddy:${CADDY_VERSION}-builder AS crs

ARG CRS_VERSION

RUN set -eux; \
    # Only retrieve and extract rule set if not existing due to cache layer
    if [ ! -d "/var/tmp/owasp-crs" ]; \
    then \
    # Get rule set archive
    wget -q -O "/var/tmp/crs-${CRS_VERSION}.tar.gz" "https://github.com/coreruleset/coreruleset/archive/refs/tags/${CRS_VERSION}.tar.gz"; \
    # Extract rule set
    mkdir /var/tmp/owasp-crs; \
    tar x -z \
    --strip-components=1 \
    -f "/var/tmp/crs-${CRS_VERSION}.tar.gz" \
    -C /var/tmp/owasp-crs \
    ; \
    fi; \
    # Create directory structure for Coraza
    mkdir -p \
    # Main configuration directory
    /opt/coraza/config \
    # Additional rules directory (not used yet)
    /opt/coraza/rules \
    # User configuration directory
    /opt/coraza/config.d \
    # User rule directory
    /opt/coraza/rules.d \
    # Rule/configuration overrides
    /opt/coraza/overrides \
    /opt/coraza/plugins \
    ; \
    # Copy rule set into rules dir
    cp -r /var/tmp/owasp-crs/rules /opt/coraza/owasp-crs; \
    # Copy CRS setup file into config dir
    cp /var/tmp/owasp-crs/crs-setup.conf.example /opt/coraza/config/crs-setup.conf

# ....................... #
# Runtime

FROM caddy:${CADDY_VERSION}-alpine

RUN apk add --no-cache gettext

COPY --from=builder /usr/bin/caddy /usr/bin/caddy
COPY --from=crs /opt/coraza /opt/coraza

COPY rootfs/waf/ /opt/coraza/config/
COPY rootfs/snippets/ /etc/caddy/snippets/
COPY rootfs/Caddyfile /etc/caddy/Caddyfile
COPY rootfs/entrypoint.sh /entrypoint.sh

RUN addgroup -S caddy && adduser -S -G caddy caddy \
    && chmod +x /entrypoint.sh \
    && mkdir -p \
    /etc/caddy/config.d \
    /etc/caddy/servers.d \
    /etc/caddy/snippets \
    /etc/caddy/snippet_defs.d \
    /etc/caddy/templates \
    /docker-entrypoint.d \
    /srv \
    /config/caddy \
    /data/caddy \
    && chown -R caddy:caddy \
    /etc/caddy \
    /docker-entrypoint.d \
    /srv \
    /config \
    /data

ENV EDGE_ADDRESS=":8080" \
    REQUEST_BODY_MAX_SIZE="30MB" \
    AUTO_HTTPS="auto_https off" \
    TEMPLATE_DIR="/etc/caddy/templates" \
    CONFIG_DIR="/etc/caddy/config.d" \
    SERVERS_DIR="/etc/caddy/servers.d" \
    BUILTIN_SNIPPETS_DIR="/etc/caddy/snippets" \
    SNIPPET_DEFS_DIR="/etc/caddy/snippet_defs.d"

EXPOSE 8080

ENTRYPOINT ["/entrypoint.sh"]
CMD ["caddy", "run", "--config", "/etc/caddy/Caddyfile", "--adapter", "caddyfile"]
