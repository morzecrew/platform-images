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
# use is on its way out. A variable added after the rule has no legacy name.
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
CADDY_WAF_ENGINE||On
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
	legacy_value=""
	[ -z "${legacy}" ] || legacy_value=$(var_value "${legacy}")

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

# Caddy substitutes it into the WAF's directives, and Coraza would also take
# `Off`. Blocking or logging are the two this image offers.
case "${CADDY_WAF_ENGINE}" in
On | DetectionOnly) ;;
*) envconf_die "CADDY_WAF_ENGINE=${CADDY_WAF_ENGINE} is not On or DetectionOnly." ;;
esac

envconf_summary caddy "${SRCMAP}" \
	"effective configuration" \
	"precedence: image default < environment"

[ "${CADDY_WAF_ENGINE}" = On ] ||
	envconf_warn "CADDY_WAF_ENGINE=DetectionOnly: the WAF logs what it would block and blocks nothing."

# The image's WAF block sets SecRuleEngine after overrides/, so the variable
# wins and the summary stays true. A file setting it would be ignored silently.
for f in /opt/coraza/overrides/*.conf; do
	if grep -qiE '^[[:space:]]*SecRuleEngine' "${f}" 2>/dev/null; then
		envconf_warn "${f} sets SecRuleEngine, which CADDY_WAF_ENGINE overrides. Set the variable instead."
	fi
done

# The trap does not fire across `exec`, so without this the source map sits in
# the running container's /tmp for the life of the process -- a file describing
# the configuration, left where nothing will ever read it again.
rm -f "${SRCMAP}"
trap - EXIT

# `on` leaves Caddy's automatic HTTPS alone. Caddy has no `auto_https on`, and
# an empty value means the image default, which is off -- so before this an
# image serving a real domain had to put some other global option here to get
# certificates. The summary above says `on`; the Caddyfile gets an empty line.
[ "${CADDY_AUTO_HTTPS}" != on ] || export CADDY_AUTO_HTTPS=

echo "Validating Caddy config..."
caddy fmt --overwrite /etc/caddy/Caddyfile
config=$(caddy adapt --config /etc/caddy/Caddyfile --adapter caddyfile)

# Every WAF `Include` in the adapted config, fragments included, one per line.
# The directives are a JSON string, so a line break in them is a literal `\n`.
waf_includes() {
	printf '%s' "$1" | grep -oE '"directives":"([^"\\]|\\.)*"' | awk '
		{
			n = split($0, line, /\\n/)
			for (i = 1; i <= n; i++) {
				s = line[i]
				sub(/^"directives":"/, "", s)
				sub(/^(\\t| )+/, "", s)
				if (match(s, /^[Ii][Nn][Cc][Ll][Uu][Dd][Ee](\\t| )+/)) {
					s = substr(s, RLENGTH + 1)
					sub(/[ "\\].*$/, "", s)
					print s
				}
			}
		}
	'
}

# shellcheck disable=SC2086 # expanding the glob is the point
glob_matches() {
	set -- $1
	[ -e "$1" ]
}

# Coraza skips an Include that matches no file, logs `empty glob result` as a
# warning, and runs without those rules: that is how this image served with no
# CRS at all (EXECUTION-LOG D-068). overrides/ ships a placeholder, so the
# image's own block always matches.
while IFS= read -r pattern; do
	[ -n "${pattern}" ] || continue
	glob_matches "${pattern}" ||
		envconf_die "the WAF includes ${pattern}, which matches no file. Coraza would skip it and run without those rules. A mounted directory needs at least one .conf file; a comment-only one will do."
done <<EOF
$(waf_includes "${config}")
EOF

# The WAF buffers a body to inspect it and refuses one past a limit of its own.
# Set apart from CADDY_REQUEST_BODY_MAX_SIZE, that limit was a second, smaller
# cap: 12.5 MiB under the 30MB default, so an image raising only the documented
# one still refused anything above 12.5 MiB with 413.
#
# Caddy parses the size, so `30MB`, `30MiB` and `1.5GB` mean what they mean to
# request_body; an invalid one has already failed the adapt above. The limit
# is the cap itself, not one byte more: the WAF refuses a body that reaches its
# limit with 413, while one that reaches request_body's cap first, mid-read,
# comes back as 500. Coraza takes 1 byte to 1 GiB, so a cap of 0 (no limit) or
# above 1 GiB gets 1 GiB.
CADDY_WAF_REQUEST_BODY_LIMIT=$(
	printf ':1 {\n\trequest_body {\n\t\tmax_size %s\n\t}\n}\n' "${CADDY_REQUEST_BODY_MAX_SIZE}" |
		caddy adapt --adapter caddyfile --config /dev/stdin 2>/dev/null |
		awk -F'"max_size":' 'NF > 1 { n = $2 + 0 } END { print (n < 1 || n > 1073741824) ? 1073741824 : n }'
)
export CADDY_WAF_REQUEST_BODY_LIMIT
echo "WAF request body limit: ${CADDY_WAF_REQUEST_BODY_LIMIT} bytes (CADDY_REQUEST_BODY_MAX_SIZE=${CADDY_REQUEST_BODY_MAX_SIZE})"

echo "Launching $*"
exec "$@"
