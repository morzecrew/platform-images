#!/bin/sh
# Resolve this image's curated variables, print what was decided, then hand off
# to Caddy. See RFC 0001 §5.4 (this image gains the summary) and the two-channel
# contract in images/README.md.
set -e

# shellcheck disable=SC1091
. /usr/local/lib/envconf.sh

# Curated variables: canonical name | legacy name | image default.
#
# The canonical spelling is `CADDY_<NAME>`, per RFC 0001 decision 1. The legacy
# column is the name this image published before that rule reached it; it still
# works, and setting it is reported rather than silently honoured, because an
# operator reading only the README would otherwise never learn the name they
# use is on its way out.
#
# The default column duplicates the Dockerfile's ENV block on purpose: knowing
# the baked value is what lets the summary distinguish "you set this" from "the
# image did". smoke.sh asserts the two copies agree, since nothing at runtime
# can -- an operator-supplied value and a baked one are the same string in
# `environ` (RFC 0001 decision 13).
CURATED="
CADDY_EDGE_ADDRESS|EDGE_ADDRESS|:8080
CADDY_REQUEST_BODY_MAX_SIZE|REQUEST_BODY_MAX_SIZE|30MB
CADDY_HEALTH_PATH|HEALTH_PATH|/__platform_healthz
CADDY_AUTO_HTTPS|AUTO_HTTPS|auto_https off
CADDY_TEMPLATE_DIR|TEMPLATE_DIR|/etc/caddy/templates
CADDY_CONFIG_DIR|CONFIG_DIR|/etc/caddy/config.d
CADDY_SERVERS_DIR|SERVERS_DIR|/etc/caddy/servers.d
CADDY_BUILTIN_SNIPPETS_DIR|BUILTIN_SNIPPETS_DIR|/etc/caddy/snippets
CADDY_SNIPPET_DEFS_DIR|SNIPPET_DEFS_DIR|/etc/caddy/snippet_defs.d
"

# Upstream's own name, set by caddy:*-alpine. RFC 0001 decision 1 says upstream
# names are never intercepted, so it must not be warned about -- the same trap
# VALKEY_VERSION sprang in wave 3.
UPSTREAM_NAMES="CADDY_VERSION"

SRCMAP=$(mktemp)
trap 'rm -f "${SRCMAP}"' EXIT

# Read a variable, whether or not it was exported.
#
# `awk ENVIRON` sees only the environment, and `/docker-entrypoint.d/*.sh` are
# **sourced** — a hook writing the natural `EDGE_ADDRESS=:8081` sets a shell
# variable, which ENVIRON cannot see, so the alias resolution below silently
# ignored it. Reading the shell scope covers both cases, since an exported
# variable is also a shell variable.
#
# EXECUTION-LOG D-016 forbids `eval` on a name you did not construct, because
# shell parameter syntax claims `-`, `:`, `#`, `%` and `?` and returns
# something plausible instead of failing. Every name here comes from the
# literal table above; the guard is what keeps that true if someone later adds
# a row with a character that is not identifier-safe.
var_value() {
	local v
	case "$1" in
	'' | *[!A-Za-z0-9_]* | [0-9]*)
		envconf_die "internal: '$1' is not a shell identifier and cannot be read safely"
		;;
	esac
	eval "v=\${$1-}"
	printf '%s' "${v}"
}

# Anything an operator drops in runs before resolution, so a hook setting a
# legacy name reaches the alias handling below rather than bypassing it.
if [ -d /docker-entrypoint.d ]; then
	for f in /docker-entrypoint.d/*.sh; do
		[ -f "$f" ] || continue
		echo "Running $f"
		# shellcheck disable=SC1090
		. "$f"
	done
fi

known=""
while IFS='|' read -r canon legacy default; do
	[ -n "${canon}" ] || continue
	known="${known} ${canon}"

	canon_value=$(var_value "${canon}")
	legacy_value=$(var_value "${legacy}")

	# Caddy substitutes these into the Caddyfile itself, so a newline is not a
	# corrupt record -- it is a second directive. Measured before this check
	# existed: a newline in CADDY_EDGE_ADDRESS added a whole server block to
	# the running configuration, invisible in the file on disk.
	envconf_refuse_newline "${canon}" "${canon_value}"
	envconf_refuse_newline "${legacy}" "${legacy_value}"

	if [ -n "${legacy_value}" ]; then
		# Both spellings set to different values: one of them would be
		# discarded, and which one is not something an operator can predict
		# from the README. Refuse naming both, as RFC 0001 decision 11 does
		# for a curated name colliding with a passthrough key.
		#
		# The one case this cannot catch is a canonical value that equals the
		# image default -- indistinguishable from unset, by decision 13 -- so
		# the warning below names the value that won rather than staying
		# silent about the choice.
		if [ -n "${canon_value}" ] &&
			[ "${canon_value}" != "${default}" ] &&
			[ "${canon_value}" != "${legacy_value}" ]; then
			envconf_die "${canon}=${canon_value} and ${legacy}=${legacy_value} are two spellings of one setting with two different values. Set ${canon} alone."
		fi
		envconf_warn "${legacy} is deprecated; use ${canon}. Starting with ${canon}=${legacy_value}."
		value="${legacy_value}"
		source="env"
		origin="${legacy}"
	elif [ -n "${canon_value}" ]; then
		value="${canon_value}"
		# Not `env`: the Dockerfile's ENV block puts this variable in `environ`
		# whether or not anybody set it, and nothing here can tell the two
		# apart (RFC 0001 decision 13).
		source="env-or-default"
		origin="${canon}"
	else
		# Absent or explicitly emptied. Caddy's own `{$VAR:default}` form treats
		# both as "use the default", and a variable emptied into an `import`
		# path would glob from the filesystem root.
		value="${default}"
		source="baked"
		origin=""
	fi

	export "${canon}=${value}"
	printf '%s\0%s\0%s\0%s\0' "${canon}" "${value}" "${source}" "${origin}" >>"${SRCMAP}"
done <<EOF
${CURATED}
EOF

# A misspelled CADDY_* name is caught here (RFC 0001 decision 9). A misspelled
# legacy name cannot be -- `EDGE_ADRESS` is indistinguishable from an unrelated
# variable in the operator's environment, which is the concrete failure RFC 0001
# §2 opens with and the reason to migrate.
#
# The remediation sentence is this image's, not the helper's default: the
# default points at the passthrough channel, and pointing at a channel the next
# check rejects is worse than saying nothing.
envconf_warn_unknown CADDY "${known} ${UPSTREAM_NAMES}" \
	"this image has no passthrough channel -- Caddy is configured by fragments under CADDY_CONFIG_DIR and CADDY_SERVERS_DIR"

# This image has no passthrough channel (RFC 0001 §5.4: the summary only). The
# helper skips `<PREFIX>_CONF__*` because for every other image those are the
# passthrough channel, so without this an operator copying the postgres pattern
# would get exactly the silence decision 9 exists to prevent.
awk 'BEGIN { for (k in ENVIRON) if (index(k, "CADDY_CONF__") == 1) print k }' |
	while IFS= read -r name; do
		envconf_warn "${name} is set, but this image has no CADDY_CONF__ passthrough channel. Caddy is configured by Caddyfile fragments -- see images/caddy/README.md."
	done

envconf_summary caddy "${SRCMAP}" \
	"effective configuration" \
	"precedence: image default < environment"

# The trap does not fire across `exec`, so without this the source map sits in
# the running container's /tmp for the life of the process -- a file describing
# the configuration, left where nothing will ever read it again.
rm -f "${SRCMAP}"
trap - EXIT

echo "Validating Caddy config..."
caddy fmt --overwrite /etc/caddy/Caddyfile
caddy adapt --config /etc/caddy/Caddyfile --adapter caddyfile >/dev/null

echo "Launching $*"
exec "$@"
