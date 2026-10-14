#!/bin/sh
# Resolves FLYWAY_URL, FLYWAY_USER and FLYWAY_PASSWORD from their _FILE
# variants (RFC 0001 decision 4), then hands every argument to upstream's
# flyway unchanged. Flyway itself has no _FILE support.
set -eu

. /usr/local/lib/envconf.sh

for name in FLYWAY_URL FLYWAY_USER FLYWAY_PASSWORD; do
	eval "file=\${${name}_FILE:-}"
	[ -n "${file}" ] || continue
	eval "note=\${${name}+\" (plain ${name} ignored)\"}"
	# The X keeps a newline the file ends with past command substitution;
	# envconf_secret has already stripped exactly one.
	value=$(envconf_secret "${name}"; printf X)
	export "${name}=${value%X}"
	unset "${name}_FILE"
	echo "[envfile] ${name} <- ${name}_FILE=${file}${note}" >&2
done

exec flyway "$@"
