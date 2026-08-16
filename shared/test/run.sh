#!/bin/sh
# Tests for shared/rootfs/lib/envconf.sh. See RFC 0001 §6.
#
# These run the helper's functions directly, with no container and no server.
# That is the point: the properties most worth pinning here -- a newline
# refused, a tab surviving, a denylisted key rejected in *both* strict modes --
# are startup aborts, and provoking a startup abort through a running Valkey
# means asserting on a container that deliberately failed to start. Cheap to
# run means they run on every PR.
#
# Usage: sh shared/test/run.sh [-v]
set -eu

HERE=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)
HELPER="${HERE}/../rootfs/lib/envconf.sh"
TMP=$(mktemp -d)
VERBOSE="${1:-}"
PASS=0
FAIL=0

cleanup() { rm -rf "${TMP}"; }
trap cleanup EXIT

[ -f "${HELPER}" ] || { echo "helper not found: ${HELPER}" >&2; exit 1; }

cat >"${TMP}/allow.conf" <<'EOF'
# comment, ignored
maxmemory-policy
notify-keyspace-events
timeout
databases
loglevel

requirepass !secret
tcp-keepalive
server_cpulist
EOF

cat >"${TMP}/deny.conf" <<'EOF'
include
rename-command
EOF

ok() {
	PASS=$((PASS + 1))
	[ "${VERBOSE}" = "-v" ] && echo "  ok   $1" || true
}

bad() {
	FAIL=$((FAIL + 1))
	echo "  FAIL $1" >&2
	[ -n "${2:-}" ] && echo "       $2" >&2 || true
}

# Each case runs in a subshell so a die() (which exits) cannot take the runner
# with it, and so globals set by one case cannot leak into the next.
run() {
	# run <name> <expected-status> <script>
	name="$1"
	want="$2"
	script="$3"
	out=$(
		set +e
		(
			# shellcheck disable=SC1090
			. "${HELPER}"
			envconf_load_allowlist "${TMP}/allow.conf"
			envconf_load_denylist "${TMP}/deny.conf"
			eval "${script}"
		) 2>&1
		echo "rc=$?"
	)
	got=${out##*rc=}
	body=${out%rc=*}
	if [ "${got}" = "${want}" ]; then
		ok "${name}"
		printf '%s' "${body}"
	else
		bad "${name}" "expected rc=${want}, got rc=${got}: ${body}"
		printf '%s' "${body}"
	fi
}

expect_contains() {
	# expect_contains <name> <haystack> <needle>
	case "$2" in
	*"$3"*) ok "$1" ;;
	*) bad "$1" "expected to contain '$3', got: $2" ;;
	esac
}

expect_equals() {
	if [ "$2" = "$3" ]; then ok "$1"; else bad "$1" "expected [$3], got [$2]"; fi
}

echo "envconf.sh"

# --- allowlist / denylist -------------------------------------------------

out=$(VALKEY_CONF__databases=8 run "allowed key is collected" 0 \
	'envconf_collect VALKEY | tr "\0" "|"')
expect_contains "  ...as key|value" "${out}" "databases|8|"

out=$(VALKEY_CONF__nope=1 run "unknown key aborts under strict=fail (default)" 1 \
	'envconf_collect VALKEY')
expect_contains "  ...names the variable" "${out}" "VALKEY_CONF__nope"

out=$(VALKEY_CONF__nope=1 VALKEY_CONF_STRICT=ignore \
	run "unknown key warns under strict=ignore" 0 'envconf_collect VALKEY')
expect_contains "  ...warns" "${out}" "WARN"

# The property most likely to regress in a rewrite (RFC 0001 §6): a denylisted
# key must abort in BOTH modes. strict=ignore governs the allowlist only.
out=$(VALKEY_CONF__include=/etc/evil.conf \
	run "denylisted key aborts under strict=fail" 1 'envconf_collect VALKEY')
expect_contains "  ...says denylisted" "${out}" "denylisted"

out=$(VALKEY_CONF__include=/etc/evil.conf VALKEY_CONF_STRICT=ignore \
	run "denylisted key aborts under strict=ignore TOO" 1 'envconf_collect VALKEY')
expect_contains "  ...says denylisted" "${out}" "denylisted"

run "an invalid strict mode aborts" 1 \
	'VALKEY_CONF_STRICT=maybe envconf_collect VALKEY' >/dev/null

run "a missing allowlist aborts" 1 \
	'envconf_load_allowlist /nonexistent/allow.conf' >/dev/null

# Padding check: 'max' must not match 'maxmemory-policy' by substring.
out=$(VALKEY_CONF__max=1 run "a prefix of an allowed key is not allowed" 1 \
	'envconf_collect VALKEY')
expect_contains "  ...names the variable" "${out}" "VALKEY_CONF__max"

# --- value safety (RFC 0001 decision 12) ----------------------------------

out=$(VALKEY_CONF__loglevel="a	b" run "a tab survives collection" 0 \
	'envconf_collect VALKEY | tr "\0" "|"')
expect_contains "  ...tab intact" "${out}" "loglevel|a	b|"

out=$(VALKEY_CONF__loglevel="one
two" run "a newline is refused" 1 'envconf_collect VALKEY')
expect_contains "  ...names the variable" "${out}" "VALKEY_CONF__loglevel"

out=$(VALKEY_CONF__loglevel="$(printf 'a\rb')" run "a carriage return is refused" 1 \
	'envconf_collect VALKEY')
expect_contains "  ...names the variable" "${out}" "VALKEY_CONF__loglevel"

# --- normalization --------------------------------------------------------

# Both spellings of the variable reach one allowlist entry, and what comes out
# is the allowlist's spelling -- not the normalized form. Rendering depends on
# this: valkey.conf wants `tcp-keepalive`, and `tcp_keepalive` is silently
# ignored by the server.
out=$(VALKEY_CONF__TCP_KEEPALIVE=60 run "uppercase input matches the allowlist" 0 \
	'envconf_collect VALKEY | tr "\0" "|"')
expect_contains "  ...emits the canonical spelling" "${out}" "tcp-keepalive|60|"

out=$(VALKEY_CONF__tcp_keepalive=60 run "underscore input matches the dashed entry" 0 \
	'envconf_collect VALKEY | tr "\0" "|"')
expect_contains "  ...emits the canonical spelling" "${out}" "tcp-keepalive|60|"

# The inverse mapping trap: valkey really does have directives with
# underscores, so a renderer that turned _ into - would corrupt these.
out=$(VALKEY_CONF__SERVER_CPULIST=0-3 run "an underscore directive keeps its underscores" 0 \
	'envconf_collect VALKEY | tr "\0" "|"')
expect_contains "  ...not dashed" "${out}" "server_cpulist|0-3|"

# A dashed variable name is not exotic -- §5.1 normalizes `-` to `_`, so it is
# an expected spelling -- and it is the case where `eval "v=\${$name}"` silently
# returns a wrong value: ${VALKEY_CONF__notify-keyspace-events} parses as
# "VALKEY_CONF__notify, defaulting to the literal keyspace-events".
# `env` is required to set it: a dashed name is not a valid shell assignment
# target, so it cannot be set as a prefix on a function call.
dashed() {
	env "VALKEY_CONF__notify-keyspace-events=$1" sh -c '
		. "$1"
		envconf_load_allowlist "$2"
		envconf_load_denylist "$3"
		envconf_collect VALKEY | tr "\0" "|"
	' _ "${HELPER}" "${TMP}/allow.conf" "${TMP}/deny.conf"
}

out=$(dashed KEA)
expect_equals "a dashed variable name yields its real value" \
	"${out}" "notify-keyspace-events|KEA|"

out=$(dashed "")
expect_equals "a dashed variable set to empty stays empty" \
	"${out}" "notify-keyspace-events||"

# --- channel collision (RFC 0001 decision 11) -----------------------------

out=$(VALKEY_CONF__maxmemory_policy=noeviction \
	run "passthrough colliding with a curated key aborts" 1 \
	'envconf_collect VALKEY "maxmemory_policy databases"')
expect_contains "  ...names the variable" "${out}" "VALKEY_CONF__maxmemory_policy"

out=$(VALKEY_CONF__loglevel=debug \
	run "a non-colliding passthrough is unaffected" 0 \
	'envconf_collect VALKEY "maxmemory_policy" | tr "\0" "|"')
expect_contains "  ...collected" "${out}" "loglevel|debug|"

# envconf_collect claims sorted output so two runs with the same environment
# render byte-identically. Nothing asserted it, and removing the sort survived
# a mutation run.
out=$(VALKEY_CONF__loglevel=a VALKEY_CONF__databases=1 VALKEY_CONF__timeout=2 \
	run "collect emits keys in sorted order" 0 'envconf_collect VALKEY | tr "\0" "|"')
expect_equals "  ...deterministic" "${out}" "databases|1|loglevel|a|timeout|2|"

# --- render ---------------------------------------------------------------

out=$(run "valkeyconf renders bare when it can" 0 \
	'printf "databases\0008\000" | envconf_render valkeyconf')
expect_contains "  ...bare" "${out}" "databases 8"

out=$(run "valkeyconf quotes a value with a space" 0 \
	'printf "loglevel\000a b\000" | envconf_render valkeyconf')
expect_contains "  ...quoted" "${out}" 'loglevel "a b"'

# \042 is a double quote; writing it literally would need escaping through both
# the single-quoted argument and eval, which is how the first attempt broke.
out=$(run "valkeyconf escapes a quote" 0 \
	'printf "loglevel\000a\042b\000" | envconf_render valkeyconf')
expect_contains "  ...escaped" "${out}" 'loglevel "a\"b"'

out=$(run "valkeyconf escapes a backslash" 0 \
	'printf "loglevel\000a\134b\000" | envconf_render valkeyconf')
expect_contains "  ...escaped" "${out}" 'loglevel "a\\b"'

out=$(run "valkeyconf quotes an empty value" 0 \
	'printf "loglevel\000\000" | envconf_render valkeyconf')
expect_contains "  ...quoted empty" "${out}" 'loglevel ""'

# Declared by RFC 0001 §5.2, deliberately unimplemented until they have a
# consumer. They must refuse loudly rather than emit nothing.
run "pgconf refuses, it has no consumer yet" 1 \
	'printf "a\000b\000" | envconf_render pgconf' >/dev/null
run "keyvalue refuses, it has no consumer yet" 1 \
	'printf "a\000b\000" | envconf_render keyvalue' >/dev/null
run "an unknown format refuses" 1 \
	'printf "a\000b\000" | envconf_render nonsense' >/dev/null

# --- secrets (RFC 0001 decision 4) ----------------------------------------

printf 'from-file' >"${TMP}/secret"
printf 'with-newline\n' >"${TMP}/secret-nl"
chmod 000 "${TMP}/unreadable" 2>/dev/null || printf 'x' >"${TMP}/unreadable"
chmod 000 "${TMP}/unreadable"

out=$(run "plain variable is used when no _FILE" 0 \
	'VALKEY_PASSWORD=plain envconf_secret VALKEY_PASSWORD')
expect_equals "  ...value" "${out}" "plain"

out=$(VALKEY_PASSWORD=plain VALKEY_PASSWORD_FILE="${TMP}/secret" \
	run "_FILE beats the plain variable" 0 'envconf_secret VALKEY_PASSWORD')
expect_equals "  ...value" "${out}" "from-file"

# The X guard matters: `$(...)` strips trailing newlines, so without it this
# test passes whether or not the helper strips anything -- it was a surviving
# mutant before the guard was added.
out=$(VALKEY_PASSWORD_FILE="${TMP}/secret-nl" sh -c '
	. "$1"
	v=$(envconf_secret VALKEY_PASSWORD; printf X)
	printf "[%s]" "${v%X}"
' _ "${HELPER}")
expect_equals "_FILE strips exactly one trailing newline" "${out}" "[with-newline]"

printf 'two-newlines\n\n' >"${TMP}/secret-nl2"
out=$(VALKEY_PASSWORD_FILE="${TMP}/secret-nl2" sh -c '
	. "$1"
	v=$(envconf_secret VALKEY_PASSWORD; printf X)
	printf "[%s]" "${v%X}"
' _ "${HELPER}")
expect_equals "  ...only one, the rest is the file's business" "${out}" "[two-newlines
]"

# Root can read a 000 file, so this case would silently pass as a false green.
if [ "$(id -u)" = "0" ]; then
	echo "  skip unreadable _FILE aborts (running as root, chmod 000 is not a barrier)"
else
	out=$(VALKEY_PASSWORD=plain VALKEY_PASSWORD_FILE="${TMP}/unreadable" \
		run "an unreadable _FILE aborts, it does not fall back" 1 \
		'envconf_secret VALKEY_PASSWORD')
	expect_contains "  ...does not leak the fallback" "${out}" "not readable"
	case "${out}" in
	*plain*) bad "  ...must not print the plain value" "${out}" ;;
	*) ok "  ...does not print the plain value" ;;
	esac
fi

# --- summary --------------------------------------------------------------

out=$(run "summary prints value and origin" 0 \
	'printf "databases\0008\000baked\000/etc/valkey/valkey.conf\000" | envconf_summary VALKEY')
expect_contains "  ...value" "${out}" "databases = 8"
expect_contains "  ...source" "${out}" "source=baked"
expect_contains "  ...origin" "${out}" "/etc/valkey/valkey.conf"

out=$(run "summary redacts a !secret key from the allowlist" 0 \
	'printf "requirepass\000hunter2\000env\000VALKEY_PASSWORD\000" | envconf_summary VALKEY')
expect_contains "  ...redacted" "${out}" "requirepass = <redacted>"
case "${out}" in
*hunter2*) bad "  ...value must not appear" "${out}" ;;
*) ok "  ...value does not appear" ;;
esac

out=$(run "summary redacts by name pattern even if not marked" 0 \
	'printf "some_token\000abc123\000env\000X\000" | envconf_summary VALKEY')
case "${out}" in
*abc123*) bad "  ...value must not appear" "${out}" ;;
*) ok "  ...pattern-matched value does not appear" ;;
esac

out=$(run "summary redacts KEY as a whole segment" 0 \
	'printf "api_key\000abc123\000env\000X\000" | envconf_summary VALKEY')
case "${out}" in
*abc123*) bad "  ...value must not appear" "${out}" ;;
*) ok "  ...api_key redacted" ;;
esac

# RFC 0001 §5.2's bare *KEY* substring would redact this, and it is a real
# allowlisted valkey directive whose value an operator needs to read.
out=$(run "summary does NOT redact notify-keyspace-events" 0 \
	'printf "notify-keyspace-events\000KEA\000env\000X\000" | envconf_summary VALKEY')
expect_contains "  ...value shown" "${out}" "notify-keyspace-events = KEA"

out=$(run "summary does NOT redact tcp-keepalive" 0 \
	'printf "tcp-keepalive\000300\000env\000X\000" | envconf_summary VALKEY')
expect_contains "  ...value shown" "${out}" "tcp-keepalive = 300"

out=$(run "summary prints the precedence line" 0 \
	'printf "" | envconf_summary VALKEY')
expect_contains "  ...precedence" "${out}" "baked < mounted < env"

# --- result ---------------------------------------------------------------

echo
echo "passed ${PASS}, failed ${FAIL}"
[ "${FAIL}" -eq 0 ] || exit 1
