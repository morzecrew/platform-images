#!/usr/bin/env bash
# Smoke test: does this image actually serve, and does it say what it decided?
# See RFC 0002 §5.5 and RFC 0001 §6 (the summary, the two spellings, decision 9).
set -euo pipefail
IMAGE="${1:?usage: smoke.sh <image-ref>}"
ENGINE="${ENGINE:-podman}"
CTR="smoke-caddy-$$"
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
cleanup() { "${ENGINE}" rm -f "${CTR}" >/dev/null 2>&1 || true; }
trap cleanup EXIT

start() {
	# start <port-mapping> [engine args...]
	local ports="$1"
	shift
	"${ENGINE}" rm -f "${CTR}" >/dev/null 2>&1 || true
	"${ENGINE}" run -d --name "${CTR}" -p "${ports}" "$@" "${IMAGE}" >/dev/null
}

http_code() {
	curl -fsS -o /dev/null -w '%{http_code}' "$1" 2>/dev/null || true
}

wait_health() {
	# wait_health <url>
	local i
	for i in $(seq 1 30); do
		[ "$(http_code "$1")" = "200" ] && return 0
		sleep 1
	done
	echo "FAIL: health never returned 200 at $1"
	"${ENGINE}" logs "${CTR}" 2>&1 | tail -20
	return 1
}

logs_of() { "${ENGINE}" logs "${CTR}" 2>&1; }

expect_in() {
	# expect_in <label> <haystack> <needle>
	case "$2" in
	*"$3"*) echo "ok: $1" ;;
	*)
		echo "FAIL: $1 -- expected '$3'"
		echo "$2" | tail -20
		exit 1
		;;
	esac
}

expect_not_in() {
	case "$2" in
	*"$3"*)
		echo "FAIL: $1 -- '$3' must not appear"
		echo "$2" | tail -20
		exit 1
		;;
	*) echo "ok: $1" ;;
	esac
}

# The nine curated variables, canonical spelling, in the order the entrypoint
# declares them.
CURATED=(
	CADDY_EDGE_ADDRESS
	CADDY_REQUEST_BODY_MAX_SIZE
	CADDY_HEALTH_PATH
	CADDY_AUTO_HTTPS
	CADDY_TEMPLATE_DIR
	CADDY_CONFIG_DIR
	CADDY_SERVERS_DIR
	CADDY_BUILTIN_SNIPPETS_DIR
	CADDY_SNIPPET_DEFS_DIR
)

# --- 1. it serves, and falls through where it says it does -----------------

start 18080:8080
wait_health "http://127.0.0.1:18080/__platform_healthz"
echo "health: 200"

# With no CONFIG_DIR fragment injected, anything else must fall through to the
# documented 501 rather than 404 or a hang.
code=$(http_code "http://127.0.0.1:18080/nothing-here")
[ "${code}" = "501" ] || { echo "FAIL: fallback returned ${code}, expected 501"; exit 1; }
echo "fallback: 501"

# --- 2. the summary reports every curated variable -------------------------

logs="$(logs_of)"
expect_in "summary header" "${logs}" "[envconf] caddy: effective configuration"
# `caddy` has no baked config file and no mounted layer, so the helper's default
# footer would name three layers this image does not have.
expect_in "summary footer" "${logs}" "precedence: image default < environment"
expect_not_in "no borrowed footer" "${logs}" "baked < mounted < env"

for var in "${CURATED[@]}"; do
	rows=$(grep -c "^\[envconf\] .* ${var} = " <<<"${logs}" || true)
	[ "${rows}" = "1" ] || { echo "FAIL: ${var} has ${rows} summary rows, expected 1"; exit 1; }
done
echo "summary: one row for each of ${#CURATED[@]} curated variables"

# RFC 0001 §6: the whole summary appears before the server's first log line.
# Caddy logs JSON; the summary is plain text on stderr.
last_summary=$(grep -n '^\[envconf\]' <<<"${logs}" | tail -1 | cut -d: -f1)
first_caddy=$(grep -n '^{"level"' <<<"${logs}" | head -1 | cut -d: -f1)
[ -n "${first_caddy}" ] || { echo "FAIL: no Caddy log line found at all"; exit 1; }
[ "${last_summary}" -lt "${first_caddy}" ] ||
	{ echo "FAIL: summary line ${last_summary} comes after Caddy's first log line ${first_caddy}"; exit 1; }
echo "summary: complete before Caddy's first log line"

# --- 3. the canonical spelling configures the server -----------------------

start 18081:8081 -e CADDY_EDGE_ADDRESS=:8081
wait_health "http://127.0.0.1:18081/__platform_healthz"
logs="$(logs_of)"
expect_in "canonical value is served" "${logs}" "CADDY_EDGE_ADDRESS = :8081"
echo "canonical: the server listens where CADDY_EDGE_ADDRESS says"

# --- 4. the legacy spelling still works, and says it is legacy -------------

start 18081:8081 -e EDGE_ADDRESS=:8081
wait_health "http://127.0.0.1:18081/__platform_healthz"
logs="$(logs_of)"
expect_in "deprecation warning" "${logs}" "EDGE_ADDRESS is deprecated; use CADDY_EDGE_ADDRESS"
# `source=env` rather than `env-or-default`: the image sets no legacy name, so a
# value under one is provably the operator's.
expect_in "attributed to the legacy name" "${logs}" "source=env"
expect_in "origin names the variable used" "${logs}" "(EDGE_ADDRESS)"
echo "legacy: honoured, attributed, and flagged"

# --- 5. two spellings, two values, one refusal -----------------------------

set +e
out=$("${ENGINE}" run --rm -e EDGE_ADDRESS=:8082 -e CADDY_EDGE_ADDRESS=:8083 "${IMAGE}" 2>&1)
rc=$?
set -e
[ "${rc}" -ne 0 ] || { echo "FAIL: a conflicting pair of spellings started"; exit 1; }
expect_in "refusal names both variables" "${out}" "CADDY_EDGE_ADDRESS=:8083 and EDGE_ADDRESS=:8082"
echo "refused: one setting spelled two ways with two values"

# --- 6. a typo is not silence (RFC 0001 decision 9) ------------------------

start 18080:8080 -e CADDY_EDGE_ADRESS=:9999 -e CADDY_CONF__loglevel=debug
wait_health "http://127.0.0.1:18080/__platform_healthz"
logs="$(logs_of)"
expect_in "typo warned" "${logs}" "CADDY_EDGE_ADRESS is set but this image does not use it"
# The image has no passthrough channel; the helper skips CADDY_CONF__* because
# for every other image that prefix *is* the channel.
expect_in "passthrough attempt warned" "${logs}" "no CADDY_CONF__ passthrough channel"
# Upstream owns CADDY_VERSION and sets it in the base image. Warning about it
# would fire on every start, which is how an ignore list stops being read.
expect_not_in "upstream name not warned" "${logs}" "CADDY_VERSION is set but"
echo "decision 9: typos warn, upstream names do not"

# --- 7. an emptied variable falls back to the image default ----------------

start 18080:8080 -e CADDY_SERVERS_DIR=
wait_health "http://127.0.0.1:18080/__platform_healthz"
logs="$(logs_of)"
expect_in "empty falls back" "${logs}" "source=baked        CADDY_SERVERS_DIR = /etc/caddy/servers.d"
echo "empty: treated as unset, as Caddy's own {\$VAR:default} does"
"${ENGINE}" rm -f "${CTR}" >/dev/null

# --- 8. the three copies of the defaults agree -----------------------------

# entrypoint.sh needs its own copy to tell "you set this" from "the image did"
# (RFC 0001 decision 13), the Dockerfile needs one for anything that bypasses
# the entrypoint, and the README is what an operator reads. Nothing at runtime
# can catch them drifting apart, so it is caught here.
image_env="$("${ENGINE}" image inspect "${IMAGE}" --format '{{range .Config.Env}}{{println .}}{{end}}')"
entry_table="$("${ENGINE}" run --rm --entrypoint cat "${IMAGE}" /entrypoint.sh |
	awk -F'|' '/^CADDY_[A-Z_]+\|/ { print $1 "=" $3 }')"

[ "$(wc -l <<<"${entry_table}")" = "${#CURATED[@]}" ] ||
	{ echo "FAIL: entrypoint declares $(wc -l <<<"${entry_table}") curated rows, expected ${#CURATED[@]}"; exit 1; }

while IFS= read -r pair; do
	expect_in "ENV matches the entrypoint default for ${pair%%=*}" "${image_env}" "${pair}"
done <<<"${entry_table}"

# Trim the cell, do not strip its spaces: `auto_https off` is one default with
# a space in it, and squeezing it out compares two strings neither copy holds.
readme_table="$(awk -F'|' '$2 ~ /`CADDY_[A-Z_]+`/ {
		gsub(/`/, "", $2); gsub(/`/, "", $3)
		gsub(/^[ \t]+|[ \t]+$/, "", $2); gsub(/^[ \t]+|[ \t]+$/, "", $3)
		print $2 "=" $3
	}' "${HERE}/README.md")"
[ "$(wc -l <<<"${readme_table}")" = "${#CURATED[@]}" ] ||
	{ echo "FAIL: README documents $(wc -l <<<"${readme_table}") curated variables, expected ${#CURATED[@]}"; exit 1; }

while IFS= read -r pair; do
	expect_in "README matches the image default for ${pair%%=*}" "${image_env}" "${pair}"
done <<<"${readme_table}"
echo "defaults: entrypoint, Dockerfile and README agree"

echo "PASS: caddy"
