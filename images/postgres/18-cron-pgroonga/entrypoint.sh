#!/usr/bin/env bash
set -euo pipefail

ORIG_ENTRYPOINT="/usr/local/bin/docker-entrypoint.sh"

OVERRIDES_DIR="/etc/postgresql/conf.d"
OVERRIDES_FILE="${OVERRIDES_DIR}/99-overrides.conf"

# Where the allowlist lives (one parameter name per line).
# Put it into the image (recommended): /etc/postgresql/allowlist.conf
# Or mount/copy it in your image build alongside the script.
ALLOWLIST_PATH="${PG_CONF_ALLOWLIST_PATH:-/etc/postgresql/allowlist.conf}"

# What to do if an override param is not allowed:
#   fail   -> abort container start (recommended for prod)
#   ignore -> just skip it with a warning (handy for dev)
STRICT_MODE="${PG_CONF_STRICT_MODE:-fail}"

mkdir -p "${OVERRIDES_DIR}"
chown -R postgres:postgres "${OVERRIDES_DIR}"

# -------------------------
# Denylist: never allow these, even if present in allowlist.
# (Some are safety/consistency "foot-guns" for your distribution model.)
# -------------------------
declare -A DENY=(
	["shared_preload_libraries"]=1
	["include"]=1
	["include_dir"]=1
	["include_if_exists"]=1
	["config_file"]=1
	["hba_file"]=1
	["ident_file"]=1
	["data_directory"]=1
	["external_pid_file"]=1
	["unix_socket_directories"]=1

	# Hardening / compatibility switches — keep fixed by product policy
	["array_nulls"]=1
	["backslash_quote"]=1
	["escape_string_warning"]=1
	["lo_compat_privileges"]=1
	["quote_all_identifiers"]=1
	["standard_conforming_strings"]=1
	["synchronize_seqscans"]=1
	["transform_null_equals"]=1

	# Prevent changing config via SQL
	["allow_alter_system"]=1
)

normalize_key() {
	# PG_CONF__Foo-Bar -> foo_bar
	local k="$1"
	k="${k,,}"    # lower
	k="${k//-/_}" # dash -> underscore
	echo "$k"
}

die() {
	echo "FATAL: $*" >&2
	exit 1
}

warn() {
	echo "WARN: $*" >&2
}

# -------------------------
# Load allowlist from file into associative array ALLOW[]
# File format:
#   one param per line
#   empty lines and # comments are ignored
# -------------------------
declare -A ALLOW=()

if [[ ! -f "${ALLOWLIST_PATH}" ]]; then
	die "Allowlist file not found: ${ALLOWLIST_PATH}. Provide it in the image or set PG_CONF_ALLOWLIST_PATH."
fi

while IFS= read -r line || [[ -n "${line}" ]]; do
	# strip comments (# ...) and trim spaces
	line="${line%%#*}"
	line="$(echo "${line}" | xargs || true)"
	[[ -z "${line}" ]] && continue

	key="$(normalize_key "${line}")"
	ALLOW["${key}"]=1
done <"${ALLOWLIST_PATH}"

# -------------------------
# Generate overrides file from PG_CONF__* environment variables
# -------------------------
tmp="$(mktemp)"
{
	echo "# Auto-generated overrides. Do not edit."
	echo "# Generated at: $(date -u +"%Y-%m-%dT%H:%M:%SZ")"
	echo
} >"${tmp}"

# Iterate environment safely: "env" lines are KEY=VALUE, VALUE may contain '='; read with -r.
# We'll split only on first '=' by parameter expansion.
while IFS= read -r line; do
	[[ "${line}" == PG_CONF__* ]] || continue

	k="${line%%=*}"
	v="${line#*=}"

	raw_param="${k#PG_CONF__}"
	param="$(normalize_key "${raw_param}")"

	if [[ -n "${DENY[$param]+x}" ]]; then
		die "PG_CONF__${raw_param} is forbidden (denylisted)"
	fi

	if [[ -z "${ALLOW[$param]+x}" ]]; then
		if [[ "${STRICT_MODE}" == "fail" ]]; then
			die "PG_CONF__${raw_param} is not allowed (not in allowlist)"
		else
			warn "Ignoring PG_CONF__${raw_param}: not allowed"
			continue
		fi
	fi

	# Minimal escaping of single quotes for postgresql.conf format
	v_escaped="${v//\'/\'\'}"

	echo "${param} = '${v_escaped}'" >>"${tmp}"
done < <(env)

mv "${tmp}" "${OVERRIDES_FILE}"
chown postgres:postgres "${OVERRIDES_FILE}"
chmod 0644 "${OVERRIDES_FILE}"

exec "${ORIG_ENTRYPOINT}" "$@"
