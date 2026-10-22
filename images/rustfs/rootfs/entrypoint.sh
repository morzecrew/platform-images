#!/bin/sh
# Settle this image's curated settings, refuse the credentials it does not
# take, hand the passthrough environment to upstream's own names, print what
# was decided, and exec upstream's entrypoint. See RFC 0001 and
# images/rustfs/README.md.
#
# Runs before upstream's /entrypoint.sh rather than instead of it: that script
# creates the data and log directories and appends the volume paths to the
# command line, and reimplementing either to save one exec is a bad trade.
set -eu

# shellcheck source=/dev/null
. /usr/local/lib/envconf.sh

PREFIX=RUSTFS
CONF_DIR=/etc/rustfs
ALLOWLIST="${RUSTFS_CONF_ALLOWLIST:-${CONF_DIR}/allowlist.conf}"
DENYLIST="${CONF_DIR}/denylist.conf"

# The upstream keys this image's curated variables write. Setting one of them
# through the passthrough channel aborts, naming both (RFC 0001 decision 11).
CURATED="ADDRESS CONSOLE_ENABLE OBS_LOG_DIRECTORY"

WORK=$(mktemp -d)
SRCMAP="${WORK}/srcmap"
PASSTHROUGH="${WORK}/passthrough"
PAIRS="${WORK}/pairs"
: >"${SRCMAP}"
cleanup() { rm -rf "${WORK}"; }
trap cleanup EXIT

emit() {
	# emit <key> <value> <source> <origin>
	printf '%s\0%s\0%s\0%s\0' "$1" "$2" "$3" "${4:-}" >>"${SRCMAP}"
}

# ---------------------------------------------------------------------------
# 1. the curated settings
# ---------------------------------------------------------------------------
# Every curated setting goes through here, so the exported environment and the
# summary cannot disagree: one call writes both.
#
# These are upstream's own names -- upstream owns every RUSTFS_* spelling, and
# the image only changes what three of them default to. A value equal to the
# Dockerfile's ENV is indistinguishable from an operator's at runtime, which is
# why the source is `env-or-default` rather than a guess (RFC 0001 decision 13).
settle() {
	# settle <var-name> <image-default>
	local name="$1" default="$2" value source origin
	eval "value=\${${name}-}"
	if [ -n "${value}" ]; then
		source=env-or-default
		origin="${name}"
	else
		value="${default}"
		source=baked
		origin=""
	fi
	export "${name}=${value}"
	emit "${name}" "${value}" "${source}" "${origin}"
}

settle RUSTFS_ADDRESS ":9000"
settle RUSTFS_CONSOLE_ENABLE "false"
settle RUSTFS_OBS_LOG_DIRECTORY ""

# ---------------------------------------------------------------------------
# 2. credentials (RFC 0001 decision 4)
# ---------------------------------------------------------------------------
# RUSTFS_ACCESS_KEY and RUSTFS_SECRET_KEY are required, each through its value
# or upstream's own `<NAME>_FILE`. Upstream itself only warns about a missing
# or default credential and starts on its built-in `rustfsadmin`; that is the
# failure this image exists to prevent, so the check is here and it is fatal.
#
# The value is read and never exported: upstream's entrypoint resolves the pair
# itself, so a credential supplied through `_FILE` stays a path in the process
# environment and never reaches `docker inspect`. Reading it here is what lets
# the empty/default check happen at all; the summary prints the key and redacts
# the value.
credential() {
	# credential <NAME>
	local name="$1"
	local file_var="${name}_FILE" file value trimmed origin

	eval "file=\${${file_var}-}"
	value=$(envconf_secret "${name}")
	# Mirrors upstream's own trim: a CRLF-edited file and surrounding blanks
	# must not turn a real default into an accepted one.
	trimmed=$(printf '%s' "${value}" | tr -d '\r' | sed 's/^[[:space:]]*//;s/[[:space:]]*$//')

	if [ -z "${trimmed}" ]; then
		envconf_die "${name} (or ${file_var}) must be set: this image ships no default credential, and upstream starts on its built-in rustfsadmin when neither is set."
	fi
	if [ "${trimmed}" = rustfsadmin ]; then
		envconf_die "${name} is upstream's built-in default credential (rustfsadmin). Set a real one; a deployment that starts on the default is a deployment anyone can write to."
	fi

	if [ -n "${file}" ]; then
		origin="${file_var}=${file}"
	else
		# Named so an operator reading the log can see they took the path that
		# exposes the value to `docker inspect`.
		origin="${name} (visible in docker inspect)"
	fi
	emit "${name}" "${value}" env "${origin}"
}

credential RUSTFS_ACCESS_KEY
credential RUSTFS_SECRET_KEY

# Upstream accepts the pre-rename spellings as legacy aliases and does not
# report which one won. One place a credential comes from is the point of the
# two variables above, so the aliases are refused rather than honoured.
for alias in RUSTFS_ROOT_USER RUSTFS_ROOT_PASSWORD MINIO_ROOT_USER MINIO_ROOT_PASSWORD; do
	eval "value=\${${alias}-}"
	if [ -n "${value}" ]; then
		envconf_die "${alias} is not accepted: this image takes its credentials from RUSTFS_ACCESS_KEY and RUSTFS_SECRET_KEY (or their _FILE forms). Unset ${alias}."
	fi
done

# ---------------------------------------------------------------------------
# 3. the passthrough channel
# ---------------------------------------------------------------------------
# RFC 0001 decision 9: a typo'd name is warned about, not ignored. Every
# RUSTFS_* this image reads is listed here, plus the names its base image sets
# -- upstream names are never intercepted (RFC 0001 §5.1), and warning about
# variables nobody set is the noise the ignore list exists to prevent. Any
# `<NAME>_FILE` is skipped by the helper.
envconf_warn_unknown "${PREFIX}" "\
RUSTFS_ADDRESS RUSTFS_CONSOLE_ENABLE RUSTFS_OBS_LOG_DIRECTORY \
RUSTFS_ACCESS_KEY RUSTFS_SECRET_KEY \
RUSTFS_VOLUMES RUSTFS_OBS_LOGGER_LEVEL RUSTFS_OBS_ENVIRONMENT \
RUSTFS_CONSOLE_CORS_ALLOWED_ORIGINS \
RUSTFS_UID RUSTFS_GID RUSTFS_USERNAME RUSTFS_GROUPNAME"

envconf_load_allowlist "${ALLOWLIST}"
envconf_load_denylist "${DENYLIST}"
envconf_collect "${PREFIX}" "${CURATED}" >"${PASSTHROUGH}"

if [ -s "${PASSTHROUGH}" ]; then
	# NUL pairs become newline pairs in a file, read back without a pipe: a
	# `while` fed by a pipeline runs in a subshell, and an export from a
	# subshell would be gone before the server it is meant for execs.
	tr '\0' '\n' <"${PASSTHROUGH}" >"${PAIRS}"
	while IFS= read -r canon && IFS= read -r value; do
		export "RUSTFS_${canon}=${value}"
		emit "RUSTFS_${canon}" "${value}" env "RUSTFS_CONF__${canon}"
	done <"${PAIRS}"
fi

# ---------------------------------------------------------------------------
# 4. report, hand off
# ---------------------------------------------------------------------------
# No config file and no mounted layer: the defaults are the image's ENV and the
# rest is the environment, so the header and footer say that rather than naming
# layers this image does not have.
envconf_summary "${PREFIX}" "${SRCMAP}" \
	"effective configuration" \
	"precedence: image default < environment"

# The trap does not fire across `exec`, so without this the source map -- which
# names every credential's origin -- would sit in the container's /tmp for the
# life of the process.
rm -rf "${WORK}"
trap - EXIT

exec /entrypoint.sh rustfs "$@"