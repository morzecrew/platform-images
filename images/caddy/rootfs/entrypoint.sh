#!/bin/sh
set -e

if [ -d /docker-entrypoint.d ]; then
	for f in /docker-entrypoint.d/*.sh; do
		[ -f "$f" ] || continue
		echo "Running $f"
		. "$f"
	done
fi

echo "Validating Caddy config..."
caddy fmt --overwrite /etc/caddy/Caddyfile
caddy adapt --config /etc/caddy/Caddyfile --adapter caddyfile >/dev/null

echo "Launching $*"
exec "$@"
