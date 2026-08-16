#!/bin/sh
# Generate valkey.conf from the environment, refuse the unsafe combinations,
# print what won, and hand off to the upstream entrypoint. See RFC 0006.
#
# Runs before upstream's docker-entrypoint.sh rather than instead of it: that
# script chowns /data and drops to the `valkey` user with setpriv, and
# reimplementing privilege-dropping to save one exec is a bad trade.
set -eu

# shellcheck source=/dev/null
. /usr/local/lib/envconf.sh

PREFIX=VALKEY
CONF_DIR=/etc/valkey
CONF_FILE="${CONF_DIR}/valkey.conf"
FRAGMENT_DIR="${CONF_DIR}/conf.d"
ALLOWLIST="${VALKEY_CONF_ALLOWLIST:-${CONF_DIR}/allowlist.conf}"
DENYLIST="${CONF_DIR}/denylist.conf"

# Decision 10 was left OPEN by RFC 0006 with one instruction: prefer
# embarrassingly small, because an evicting cache is recoverable and an
# OOM-killed host is not. 256 MiB is small enough to be obviously a fallback
# and large enough to start and serve.
FALLBACK_MAXMEMORY=268435456
CGROUP_MAX=/sys/fs/cgroup/memory.max

WORK=$(mktemp -d)
CONF_TMP="${WORK}/valkey.conf"
SRCMAP="${WORK}/srcmap"
PASSTHROUGH="${WORK}/passthrough"
: >"${CONF_TMP}"
: >"${SRCMAP}"
cleanup() { rm -rf "${WORK}"; }
trap cleanup EXIT

# Every curated setting goes through here, so the config file and the summary
# cannot disagree: one call writes both.
#
#   emit <key> <value> <source> <origin>
emit() {
	# Quoted for the config file, raw for the summary. The quoter is the same
	# one envconf_render uses for passthrough values -- writing curated values
	# with a bare `printf '%s %s'` is what let a password containing a space
	# reach valkey.conf as two arguments and stop the server from starting.
	printf '%s %s\n' "$1" "$(envconf_quote_valkeyconf "$2")" >>"${CONF_TMP}"
	printf '%s\0%s\0%s\0%s\0' "$1" "$2" "$3" "${4:-}" >>"${SRCMAP}"
}

# Curated variables the operator actually set. Defaults are deliberately not in
# here: the collision rule (RFC 0001 decision 11) is about an operator setting
# the same thing twice, and every curated knob has a default, so counting
# defaults would make the passthrough channel permanently unusable.
CURATED=""
curated_if_set() {
	# curated_if_set <var-name> <upstream-key>
	eval "_v=\${$1:-}"
	if [ -n "${_v}" ]; then
		CURATED="${CURATED} $2"
	fi
}

# ---------------------------------------------------------------------------
# 1. maxmemory (RFC 0006 §5.2)
# ---------------------------------------------------------------------------
maxmemory_percent="${VALKEY_MAXMEMORY_PERCENT:-75}"
case "${maxmemory_percent}" in
'' | *[!0-9]*) envconf_die "VALKEY_MAXMEMORY_PERCENT must be a whole number, got '${maxmemory_percent}'" ;;
esac
[ "${maxmemory_percent}" -ge 1 ] && [ "${maxmemory_percent}" -le 100 ] ||
	envconf_die "VALKEY_MAXMEMORY_PERCENT must be between 1 and 100, got '${maxmemory_percent}'"

if [ -n "${VALKEY_MAXMEMORY:-}" ]; then
	maxmemory="${VALKEY_MAXMEMORY}"
	maxmemory_source=env
	maxmemory_origin=VALKEY_MAXMEMORY
elif [ -r "${CGROUP_MAX}" ] && cgroup_limit=$(cat "${CGROUP_MAX}") &&
	[ "${cgroup_limit}" != "max" ] && [ -z "${cgroup_limit%%[0-9]*}" ] &&
	[ "${cgroup_limit}" -le 1125899906842624 ]; then
	# Divide before multiplying, deliberately. It loses under 100 bytes of a
	# figure measured in hundreds of megabytes, while multiplying first
	# overflows 64-bit arithmetic on the very large values some runtimes
	# report in place of "max" -- and an overflowed maxmemory is a negative
	# number the server will reject at startup.
	#
	# The 1 PiB ceiling above catches those same runtimes: a container is not
	# really being offered a petabyte, so that value means unlimited and
	# belongs on the warned fallback path rather than being multiplied out.
	maxmemory=$((cgroup_limit / 100 * maxmemory_percent))
	maxmemory_source=derived
	maxmemory_origin="${maxmemory_percent}% of cgroup memory.max"
else
	# The path that will actually be hit in unusual environments -- cgroup v1,
	# an unconstrained container -- so it warns rather than proceeding quietly.
	maxmemory="${FALLBACK_MAXMEMORY}"
	maxmemory_source=fallback
	maxmemory_origin="no cgroup v2 memory limit readable"
	envconf_warn "no readable memory limit at ${CGROUP_MAX}; falling back to ${FALLBACK_MAXMEMORY} bytes. Set VALKEY_MAXMEMORY to choose deliberately."
fi

# ---------------------------------------------------------------------------
# 2. eviction policy, and 3. persistence (RFC 0006 §5.2, §5.3)
# ---------------------------------------------------------------------------
policy_set="${VALKEY_MAXMEMORY_POLICY:-}"
policy="${policy_set:-allkeys-lru}"
persistence="${VALKEY_PERSISTENCE:-off}"

case "${persistence}" in
off | rdb | aof) ;;
*) envconf_die "VALKEY_PERSISTENCE must be off, rdb or aof, got '${persistence}'" ;;
esac

# Both §5.3 refusals are evaluated in section 8, against the assembled
# configuration. Checking them here would only see the curated channel, and
# `VALKEY_CONF__maxmemory-policy` is an allowlisted spelling of the same knob --
# so a genuinely safe durable setup expressed through the passthrough channel
# was being refused for not setting the curated one. The two channels are
# documented as equivalent; the refusals have to agree.

emit maxmemory "${maxmemory}" "${maxmemory_source}" "${maxmemory_origin}"
if [ -n "${policy_set}" ]; then
	emit maxmemory-policy "${policy}" env VALKEY_MAXMEMORY_POLICY
else
	emit maxmemory-policy "${policy}" baked "image default"
fi

case "${persistence}" in
off)
	emit appendonly no baked "VALKEY_PERSISTENCE=off"
	emit save "" baked "VALKEY_PERSISTENCE=off"
	;;
rdb)
	emit appendonly no env VALKEY_PERSISTENCE
	emit save "900 1 300 10 60 10000" env VALKEY_PERSISTENCE
	;;
aof)
	emit appendonly yes env VALKEY_PERSISTENCE
	emit save "" env VALKEY_PERSISTENCE
	emit appendfsync "${VALKEY_APPENDFSYNC:-everysec}" \
		"$([ -n "${VALKEY_APPENDFSYNC:-}" ] && echo env || echo baked)" \
		"${VALKEY_APPENDFSYNC:+VALKEY_APPENDFSYNC}"
	;;
esac

# ---------------------------------------------------------------------------
# 4. secrets from files first (RFC 0006 §5.2, RFC 0001 decision 4)
# ---------------------------------------------------------------------------
password=$(envconf_secret VALKEY_PASSWORD)
if [ -n "${password}" ]; then
	if [ -n "${VALKEY_PASSWORD_FILE:-}" ]; then
		emit requirepass "${password}" env "VALKEY_PASSWORD_FILE=${VALKEY_PASSWORD_FILE}"
	else
		# Named so an operator reading the log can see they took the path that
		# exposes the value to `docker inspect`.
		emit requirepass "${password}" env "VALKEY_PASSWORD (visible in docker inspect)"
	fi
fi

# ---------------------------------------------------------------------------
# 5. remaining curated knobs
# ---------------------------------------------------------------------------
# `if` rather than `[ … ] && emit …`: under `set -e` an AND-OR list whose left
# side fails is exempt only while it is not the last command in the script, so
# the short form is correct here and becomes an exit-1 the moment someone
# reorders these lines to the end.
if [ -n "${VALKEY_DATABASES:-}" ]; then
	emit databases "${VALKEY_DATABASES}" env VALKEY_DATABASES
fi
if [ -n "${VALKEY_LOGLEVEL:-}" ]; then
	emit loglevel "${VALKEY_LOGLEVEL}" env VALKEY_LOGLEVEL
fi
if [ -n "${VALKEY_TCP_KEEPALIVE:-}" ]; then
	emit tcp-keepalive "${VALKEY_TCP_KEEPALIVE}" env VALKEY_TCP_KEEPALIVE
fi

emit protected-mode yes baked "image default"
emit dir /data baked "image default"

# ---------------------------------------------------------------------------
# 6. dangerous commands (RFC 0006 §5.4)
# ---------------------------------------------------------------------------
# The variable is the explicit list of commands to rename, so the default
# documents itself and adding CONFIG is how §5.4's CONFIG opt-in is expressed.
# Empty disables renaming entirely.
rename_list="${VALKEY_RENAME_DANGEROUS-FLUSHALL FLUSHDB KEYS}"
for cmd in ${rename_list}; do
	printf 'rename-command %s ""\n' "${cmd}" >>"${CONF_TMP}"
done

# One summary line for the whole set rather than one per command. Three lines
# saying the same thing crowd out the settings a reader is actually scanning
# for -- and a per-command line would carry the command name in the *key*
# position, where `KEYS` trips the summary's secret-name matching.
if [ -n "${VALKEY_RENAME_DANGEROUS+x}" ]; then
	rename_source=env
else
	rename_source=baked
fi
printf '%s\0%s\0%s\0%s\0' \
	"disabled-commands" "${rename_list:-<none>}" \
	"${rename_source}" "VALKEY_RENAME_DANGEROUS" >>"${SRCMAP}"

# ---------------------------------------------------------------------------
# 7. mounted fragments, then the passthrough channel
# ---------------------------------------------------------------------------
# Precedence is baked < mounted < env, and valkey.conf takes the last
# occurrence of a directive -- so emission order *is* the precedence rule.
if [ -d "${FRAGMENT_DIR}" ]; then
	for fragment in "${FRAGMENT_DIR}"/*.conf; do
		[ -f "${fragment}" ] || continue
		printf '\n# --- from %s ---\n' "${fragment}" >>"${CONF_TMP}"
		cat "${fragment}" >>"${CONF_TMP}"

		# Attributed per directive, not as one "included verbatim" line.
		# RFC 0001 decision 13 requires full source= attribution of images that
		# generate their config from enumerable layers, and this is one --
		# "which layer won" is unanswerable if a whole file collapses to a
		# single summary row.
		while IFS= read -r line || [ -n "${line}" ]; do
			case "${line}" in
			'#'* | '') continue ;;
			esac
			# Strip leading blanks first. `cat` above has already written
			# the line into the config, so a key extracted as empty means the
			# directive applies with no summary row -- applied but invisible,
			# which is worse than either.
			while :; do
				case "${line}" in
				' '* | '	'*) line=${line#?} ;;
				*) break ;;
				esac
			done
			case "${line}" in
			'#'* | '') continue ;;
			esac
			frag_key=${line%%[ 	]*}
			[ -n "${frag_key}" ] || continue
			frag_val=${line#"${frag_key}"}
			# Strip the leading run of blanks between directive and argument.
			while :; do
				case "${frag_val}" in
				' '* | '	'*) frag_val=${frag_val#?} ;;
				*) break ;;
				esac
			done
			printf '%s\0%s\0%s\0%s\0' "${frag_key}" "${frag_val}" mounted "${fragment}" \
				>>"${SRCMAP}"
		done <"${fragment}"
	done
fi

curated_if_set VALKEY_MAXMEMORY maxmemory
curated_if_set VALKEY_MAXMEMORY_POLICY maxmemory-policy
curated_if_set VALKEY_PASSWORD requirepass
curated_if_set VALKEY_PASSWORD_FILE requirepass
curated_if_set VALKEY_DATABASES databases
curated_if_set VALKEY_LOGLEVEL loglevel
curated_if_set VALKEY_TCP_KEEPALIVE tcp-keepalive
curated_if_set VALKEY_APPENDFSYNC appendfsync

# RFC 0001 decision 9: a typo'd curated name is warned about, not ignored.
# Every VALKEY_* the image reads is listed here; adding a curated variable
# without adding it here makes the image warn about its own knob.
#
# VALKEY_VERSION is last and is not ours: the upstream image sets it, and §5.1
# says upstream names are never intercepted. Without it this warns on every
# start about a variable no operator set.
envconf_warn_unknown "${PREFIX}" "\
VALKEY_MAXMEMORY VALKEY_MAXMEMORY_PERCENT VALKEY_MAXMEMORY_POLICY \
VALKEY_PERSISTENCE VALKEY_APPENDFSYNC VALKEY_PASSWORD \
VALKEY_DATABASES VALKEY_LOGLEVEL VALKEY_TCP_KEEPALIVE \
VALKEY_RENAME_DANGEROUS \
VALKEY_VERSION"

envconf_load_allowlist "${ALLOWLIST}"
envconf_load_denylist "${DENYLIST}"
envconf_collect "${PREFIX}" "${CURATED}" >"${PASSTHROUGH}"

if [ -s "${PASSTHROUGH}" ]; then
	printf '\n# --- from the environment ---\n' >>"${CONF_TMP}"
	envconf_render valkeyconf "${PASSTHROUGH}" >>"${CONF_TMP}"
	# Re-read as pairs to extend them into summary quads. The values are
	# newline-free by construction (envconf_collect refuses otherwise), which
	# is what makes reading them a line at a time safe.
	tr '\0' '\n' <"${PASSTHROUGH}" | while IFS= read -r k && IFS= read -r v; do
		printf '%s\0%s\0%s\0%s\0' "${k}" "${v}" env "${PREFIX}_CONF__${k}" >>"${SRCMAP}"
	done
fi

# ---------------------------------------------------------------------------
# 8. re-check the refusals against the assembled config
# ---------------------------------------------------------------------------
# The checks in section 2 read the environment. This one reads what was
# actually assembled, and it is the one that holds: a mounted fragment can set
# `appendonly yes` directly, which turns on persistence without going through
# VALKEY_PERSISTENCE and would otherwise walk straight past a refusal decision
# 6 marks LOCKED. valkey.conf takes the last occurrence of a directive, so the
# effective value is the last match.
effective() {
	awk -v key="$1" '
		{ sub(/#.*/, "") }
		$1 == key { $1 = ""; sub(/^[ \t]+/, ""); v = $0 }
		END { print v }
	' "${CONF_TMP}"
}

eff_appendonly=$(effective appendonly)
eff_save=$(effective save)
eff_policy=$(effective maxmemory-policy)

durable=no
[ "${eff_appendonly}" = "yes" ] && durable=yes
case "${eff_save}" in
'' | '""' | "''") ;;
*) durable=yes ;;
esac

# Was the policy chosen by an operator, through either channel, or is it just
# this image's default? Only the second case is refused below.
# Counted from the assembled file rather than per channel. The image emits
# exactly one `maxmemory-policy` line of its own, so a second occurrence means
# something else set it -- a fragment, or the passthrough channel. Checking the
# channels individually is what made a fragment-set policy look absent.
policy_explicit=no
if [ -n "${policy_set}" ]; then
	policy_explicit=yes
elif [ "$(awk '$1 == "maxmemory-policy"' "${CONF_TMP}" | wc -l)" -gt 1 ]; then
	policy_explicit=yes
fi

if [ "${durable}" = "yes" ]; then
	# Refusal 2 first: otherwise the image's own default supplies the policy
	# that refusal 1 then rejects, and the operator is told off for something
	# they did not set.
	if [ "${policy_explicit}" = "no" ]; then
		envconf_die "persistence is enabled (appendonly=${eff_appendonly}, save=${eff_save}) but no eviction policy was set explicitly. This image defaults to allkeys-lru, which evicts data a durable store is meant to keep, so a durable configuration has to name its policy -- almost certainly VALKEY_MAXMEMORY_POLICY=noeviction (or VALKEY_CONF__maxmemory-policy=noeviction)."
	fi
	case "${eff_policy}" in
	allkeys-*)
		envconf_die "persistence and eviction contradict each other: the assembled configuration enables persistence (appendonly=${eff_appendonly}, save=${eff_save}) while maxmemory-policy=${eff_policy} deletes data under memory pressure, and the loss is silent. Either set the policy to noeviction to keep the data, or turn persistence off if this is a cache. A fragment in ${FRAGMENT_DIR} counts here too."
		;;
	esac
fi

# ---------------------------------------------------------------------------
# 9. install, report, hand off
# ---------------------------------------------------------------------------
mkdir -p "${CONF_DIR}"
{
	echo "# Generated by the morze valkey entrypoint. Do not edit; it is"
	echo "# rewritten on every start. See images/valkey/README.md."
	cat "${CONF_TMP}"
} >"${CONF_FILE}"

# The file carries requirepass, so it is not world-readable. Best-effort:
# the container may already be running as a non-root user via --user.
chmod 0640 "${CONF_FILE}" 2>/dev/null || true
chown valkey:valkey "${CONF_FILE}" 2>/dev/null || true

envconf_summary "${PREFIX}" "${SRCMAP}"

exec /usr/local/bin/docker-entrypoint.sh valkey-server "${CONF_FILE}" "$@"
