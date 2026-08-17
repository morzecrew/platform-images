#!/bin/sh
# Render PG_CONF__* into an overrides file, print what the server will actually
# use, then hand off to the upstream entrypoint.
#
# RFC 0001 P4. This replaced a bash implementation of the same two channels: the
# logic now lives in the shared helper, so `postgres` and every later image
# refuse the same keys, quote values the same way, and print the same summary.
# The published surface is unchanged (decision 10) -- PG_CONF__*,
# PG_CONF_ALLOWLIST_PATH and PG_CONF_STRICT_MODE all keep working.
set -eu

# shellcheck disable=SC1091
. /usr/local/lib/envconf.sh

ORIG_ENTRYPOINT="/usr/local/bin/docker-entrypoint.sh"

BAKED_CONF="/etc/postgresql.conf"
CONF_D="/etc/postgresql/conf.d"
BAKED_LIST="${CONF_D}/.baked-fragments"
OVERRIDES_FILE="${CONF_D}/99-overrides.conf"

# Published names, kept (RFC 0001 decision 10). The helper reads PG_CONF_STRICT
# and PG_CONF_ALLOWLIST; this image published PG_CONF_STRICT_MODE and
# PG_CONF_ALLOWLIST_PATH before the contract existed, and breaking a shipped
# surface to gain a naming convention is not a trade worth making.
#
# Both spellings are accepted. Setting both to different values is refused
# rather than resolved, for the reason decision 11 gives about any one setting
# reachable two ways: an operator who sets both would otherwise get whichever
# the code happens to read, and could not tell from the README which that is.
alias_control() {
	published="$1"
	contract="$2"
	eval "pub=\${${published}-}"
	eval "con=\${${contract}-}"

	if [ -n "${pub}" ] && [ -n "${con}" ] && [ "${pub}" != "${con}" ]; then
		envconf_die "${published}=${pub} and ${contract}=${con} are two spellings of one setting with two different values. Set ${published} alone."
	fi
	[ -n "${pub}" ] || return 0
	export "${contract}=${pub}"
}

alias_control PG_CONF_STRICT_MODE PG_CONF_STRICT
alias_control PG_CONF_ALLOWLIST_PATH PG_CONF_ALLOWLIST

ALLOWLIST="${PG_CONF_ALLOWLIST:-/etc/postgresql/allowlist.conf}"
export PG_CONF_ALLOWLIST="${ALLOWLIST}"

mkdir -p "${CONF_D}"
chown postgres:postgres "${CONF_D}"

# The bash version ran `chown -R` here, which aborts the container when any
# fragment is mounted read-only -- the natural way to mount one, and the layer
# RFC 0001 decision 3 (`LOCKED`) requires every image to support:
#
#   chown: changing ownership of '/etc/postgresql/conf.d/50-tuning.conf':
#          Read-only file system
#
# Reproduced against the published pre-retrofit image, so this is not a
# regression from the retrofit -- it is a defect the retrofit's own §6 battery
# is what finally caught. Taking ownership is still attempted, because a
# read-write fragment with a restrictive mode does need it, but failing to
# re-own a file the image does not own is not this script's business to die
# over: what matters is whether the server can read it, which it reports itself.
if ! chown -R postgres:postgres "${CONF_D}" 2>/dev/null; then
	envconf_warn "could not take ownership of every file in ${CONF_D}; a read-only mount is the usual reason. The server must be able to read them as the postgres user."
fi

envconf_load_allowlist "${ALLOWLIST}"
envconf_load_denylist /etc/postgresql/denylist.conf

# --- the environment channel ------------------------------------------------

SRCMAP=$(mktemp)
COLLECTED=$(mktemp)
cleanup() { rm -f "${SRCMAP}" "${COLLECTED}"; }
trap cleanup EXIT

envconf_collect PG >"${COLLECTED}"

# Written to a temporary file and moved into place, so a failure between here
# and the move leaves the previous overrides rather than half a file. The
# generated header is unchanged from the bash version: an operator who diffs
# the file across an upgrade should see only their own settings move.
tmp_overrides=$(mktemp)
{
	echo "# Auto-generated overrides. Do not edit."
	echo "# Generated at: $(date -u +"%Y-%m-%dT%H:%M:%SZ")"
	echo
	envconf_render pgconf "${COLLECTED}"
} >"${tmp_overrides}"

mv "${tmp_overrides}" "${OVERRIDES_FILE}"
chown postgres:postgres "${OVERRIDES_FILE}"
chmod 0644 "${OVERRIDES_FILE}"

# --- the source map ---------------------------------------------------------

# Three layers, in the order Postgres reads them: the baked file, then conf.d
# alphabetically, then the overrides this script just wrote (which sorts last by
# its 99- prefix, and is attributed to the environment rather than to the file).
#
# Decision 13 requires full source= attribution from an image that generates its
# configuration from enumerable layers, and this is the image that motivated the
# row. `caddy` prints env-or-default because it cannot do better; here every
# value has a file behind it.
envconf_scan_pgconf "${BAKED_CONF}" baked "${BAKED_CONF}" >>"${SRCMAP}"

for f in "${CONF_D}"/*.conf; do
	[ -f "${f}" ] || continue
	base=$(basename "${f}")

	[ "${f}" = "${OVERRIDES_FILE}" ] && continue

	# An image-shipped fragment is one this build recorded. Anything else in
	# the include directory arrived from outside the image.
	if [ -r "${BAKED_LIST}" ] && grep -qxF "${base}" "${BAKED_LIST}"; then
		envconf_scan_pgconf "${f}" baked "${f}" >>"${SRCMAP}"
	else
		envconf_scan_pgconf "${f}" mounted "${f}" >>"${SRCMAP}"
	fi
done

# The env channel is attributed to the variable that supplied it, not to the
# file it was rendered into -- the file is this script's own output, and naming
# it would tell an operator where the value landed rather than where it came
# from.
#
# Read through a pipe rather than a here-document: `$(...)` strips trailing
# newlines, so a final pair whose value is empty -- PG_CONF__log_line_prefix=
# renders `log_line_prefix = ''` -- would lose its value line and be dropped
# from the summary while still reaching the file. That is wave 3's A-10 in a
# different costume.
tr '\0' '\n' <"${COLLECTED}" |
	while IFS= read -r key && IFS= read -r value; do
		printf '%s\0%s\0%s\0%s\0' "${key}" "${value}" env "PG_CONF__${key}" >>"${SRCMAP}"
	done

envconf_summary postgres "${SRCMAP}"

# Decision 9. The upstream names are the ones the base image sets; PGDATA has no
# underscore after the prefix and never matches.
envconf_warn_unknown PG "PG_MAJOR PG_VERSION PG_CONF_STRICT_MODE PG_CONF_ALLOWLIST_PATH"

# The trap does not fire across `exec`.
cleanup
trap - EXIT

exec "${ORIG_ENTRYPOINT}" "$@"
