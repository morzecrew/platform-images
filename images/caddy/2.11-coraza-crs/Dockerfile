# syntax=docker/dockerfile:1.7

# ....................... #

ARG CADDY_VERSION="2.11"
ARG CORAZA_CADDY_VERSION="v2.1.0"
ARG CRS_VERSION="v4.24.0"

# ....................... #
# Build with Coraza WAF

FROM caddy:${CADDY_VERSION}-builder AS builder

RUN xcaddy build --with "github.com/corazawaf/coraza-caddy/v2@${CORAZA_CADDY_VERSION}"

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

COPY --from=builder /usr/bin/caddy /usr/bin/caddy
COPY --from=crs /opt/coraza /opt/coraza

COPY 2.11-coraza-crs/waf/ /opt/coraza/config/
COPY 2.11-coraza-crs/Caddyfile /etc/caddy/Caddyfile
COPY 2.11-coraza-crs/entrypoint.sh /entrypoint.sh

RUN chmod +x /entrypoint.sh

ENV EDGE_ADDRESS=${EDGE_ADDRESS:-:80} \
    REQUEST_BODY_MAX_SIZE=${REQUEST_BODY_MAX_SIZE:-"30MB"} \
    AUTO_HTTPS=${AUTO_HTTPS:-"auto_https off"} \
    ROUTES=${ROUTES:-""}

ENTRYPOINT ["/entrypoint.sh"]
CMD ["caddy", "run", "--config", "/etc/caddy/Caddyfile", "--adapter", "caddyfile"]