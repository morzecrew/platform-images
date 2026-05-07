#!/bin/sh
set -e

echo "Validating Caddy config..."
caddy fmt --overwrite /etc/caddy/Caddyfile
caddy adapt --config /etc/caddy/Caddyfile --adapter caddyfile >/dev/null

echo "Launching $*"
exec "$@"
