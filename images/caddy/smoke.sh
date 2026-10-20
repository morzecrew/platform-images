#!/usr/bin/env bash
# Smoke test: does this image actually serve, and does it say what it decided?
# See RFC 0002 §5.5 and RFC 0001 §6 (the summary, the two spellings, decision 9).
set -euo pipefail
IMAGE="${1:?usage: smoke.sh <image-ref>}"
ENGINE="${ENGINE:-podman}"
CTR="smoke-caddy-$$"
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
WORK="$(mktemp -d)"
REFUSE_OUT="${WORK}/refuse.out"
cleanup() {
	"${ENGINE}" rm -f "${CTR}" "${CTR}-refuse" >/dev/null 2>&1 || true
	rm -rf "${WORK}"
}
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

# The ten curated variables, canonical spelling, in the order the entrypoint
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
	CADDY_WAF_ENGINE
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
# -m1, not `| head -1`: under pipefail, grep killed by SIGPIPE once its output
# passes one write fails the script with 141.
first_caddy=$(grep -n -m1 '^{"level"' <<<"${logs}" | cut -d: -f1)
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

# Leaves the container's output in ${REFUSE_OUT} rather than printing it, so
# every caller runs in the main shell. A `$( )`-captured helper would put its
# `exit 1` inside a subshell, where it ends the substitution and not the
# script -- the failure mode that let wave 3's test suite report "failed 0".
refuse() {
	# refuse <label> [engine args...]
	local label="$1"
	shift
	local rc
	# Bounded twice. The failure mode of a lost refusal is not a non-zero exit,
	# it is a server that starts and runs forever, so the outer bound turns a
	# hung job into a failing assertion. `--kill-after` bounds the bound: plain
	# `timeout` sends SIGTERM and then waits, so an engine that does not exit
	# on it hangs exactly as before. That second path exits 137, not 124, and
	# both mean the same thing here.
	set +e
	timeout --kill-after=10 30 "${ENGINE}" run --rm --name "${CTR}-refuse" \
		"$@" "${IMAGE}" >"${REFUSE_OUT}" 2>&1
	rc=$?
	set -e
	"${ENGINE}" rm -f "${CTR}-refuse" >/dev/null 2>&1 || true
	case "${rc}" in
	124 | 137)
		echo "FAIL: ${label} started and kept running"
		exit 1
		;;
	0)
		echo "FAIL: ${label} started"
		tail -5 "${REFUSE_OUT}"
		exit 1
		;;
	esac
}

refuse "a conflicting pair of spellings" -e EDGE_ADDRESS=:8082 -e CADDY_EDGE_ADDRESS=:8083
expect_in "refusal names both variables" "$(cat "${REFUSE_OUT}")" \
	"CADDY_EDGE_ADDRESS=:8083 and EDGE_ADDRESS=:8082"
echo "refused: one setting spelled two ways with two values"

# The pair the image *cannot* tell apart: a canonical value equal to the baked
# default is indistinguishable from unset, so this must not refuse. It takes
# the alias and says which value it started with (README, decision 21).
start 18081:8081 -e CADDY_EDGE_ADDRESS=:8080 -e EDGE_ADDRESS=:8081
wait_health "http://127.0.0.1:18081/__platform_healthz"
logs="$(logs_of)"
expect_in "ambiguous pair names the winning value" "${logs}" \
	"Starting with CADDY_EDGE_ADDRESS=:8081"
expect_in "ambiguous pair is attributed to the alias" "${logs}" "(EDGE_ADDRESS)"
echo "ambiguous: alias wins, and the warning says so"

# --- 5a. a newline in a value is refused, not substituted -------------------

# Caddy expands {$VAR} itself, so a newline is a second directive rather than a
# corrupt record: before this refusal existed, the value below added a whole
# server block on :8099 to the running config.
refuse "a newline-bearing value" -e "CADDY_EDGE_ADDRESS=:8080 {
	respond \"injected\" 200
}
:8099"
expect_in "newline refusal names the variable" "$(cat "${REFUSE_OUT}")" \
	"CADDY_EDGE_ADDRESS contains a newline"
echo "refused: a value containing a newline"

# --- 6. a typo is not silence (RFC 0001 decision 9) ------------------------

start 18080:8080 -e CADDY_EDGE_ADRESS=:9999 -e CADDY_CONF__loglevel=debug
wait_health "http://127.0.0.1:18080/__platform_healthz"
logs="$(logs_of)"
expect_in "typo warned" "${logs}" "CADDY_EDGE_ADRESS is set but this image does not use it"
# The helper's default remediation points at the passthrough channel. This
# image rejects that channel two lines later, so advertising it would send an
# operator straight at the thing the next warning refuses.
expect_in "typo warning offers the right remedy" "${logs}" \
	"this image has no passthrough channel -- Caddy is configured by fragments"
expect_not_in "typo warning does not advertise the channel" "${logs}" \
	"use CADDY_CONF__<directive> for a passthrough setting"
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

# --- 7a. a hook's plain assignment reaches the alias resolution -------------

# The hooks are *sourced*, so `EDGE_ADDRESS=:8081` in one is a shell variable,
# not an environment variable. Reading only `environ` ignored it silently and
# started on the baked default while the entrypoint's comment claimed hooks
# participated. The unexported form is the one that regresses; the exported
# form works either way.
mkdir -p "${WORK}/hooks"
printf '#!/bin/sh\nEDGE_ADDRESS=:8081\n' >"${WORK}/hooks/10-legacy.sh"
start 18081:8081 -v "${WORK}/hooks:/docker-entrypoint.d:ro,Z"
wait_health "http://127.0.0.1:18081/__platform_healthz"
logs="$(logs_of)"
expect_in "hook assignment is honoured" "${logs}" "CADDY_EDGE_ADDRESS = :8081"
expect_in "hook assignment is attributed" "${logs}" "(EDGE_ADDRESS)"
echo "hook: an unexported assignment still configures the server"
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

# --- 9. the WAF runs CRS -----------------------------------------------------

# The include once named a directory that did not exist. Coraza logged an
# empty glob, a warning, and ran without CRS, so both probes below reached the
# upstream. Fixing the include alone made every request 500, health included:
# the image's own crs-setup.conf had replaced upstream's and lacked the
# version marker CRS refuses to run without.
mkdir -p "${WORK}/app"
printf 'handle /v1/forbidden {\n\trespond "app" 403\n}\nhandle /v1/denied {\n\terror 403\n}\nhandle /v1/* {\n\trespond "upstream" 200\n}\n' \
	>"${WORK}/app/10-app.caddy"
start 18080:8080 -e CADDY_REQUEST_BODY_MAX_SIZE=1000 -v "${WORK}/app:/etc/caddy/config.d:ro,Z"
wait_health "http://127.0.0.1:18080/__platform_healthz"
code=$(http_code "http://127.0.0.1:18080/v1/x?id=1")
[ "${code}" = "200" ] || { echo "FAIL: a plain request got ${code}, expected 200"; exit 1; }
for probe in "id=1%27%20OR%20%271%27%3D%271" "q=%3Cscript%3Ealert(1)%3C%2Fscript%3E"; do
	code=$(curl -s -o /dev/null -w '%{http_code}' "http://127.0.0.1:18080/v1/x?${probe}")
	[ "${code}" = "403" ] || { echo "FAIL: WAF let ?${probe} through with ${code}, expected 403"; exit 1; }
done
echo "waf: CRS refuses an SQLi and an XSS probe, a plain request passes"

# CRS allows GET HEAD POST OPTIONS unless told otherwise, and scores any other
# method at the threshold: every PUT, PATCH and DELETE was a 403.
api() {
	# api <method> <path> [curl args...]: the status, with a name in Host
	local method="$1" path="$2"
	shift 2
	curl -s -o /dev/null -w '%{http_code}' -X "${method}" -H 'Host: app.example' "$@" \
		"http://127.0.0.1:18080${path}"
}
for method in PUT PATCH DELETE; do
	code=$(api "${method}" /v1/x -H 'Content-Type: application/json' -d '{"a":1}')
	[ "${code}" = "200" ] || { echo "FAIL: ${method} got ${code}, expected 200"; exit 1; }
done
code=$(api FOO /v1/x)
[ "${code}" = "403" ] || { echo "FAIL: method FOO got ${code}, expected 403"; exit 1; }
echo "waf: PUT, PATCH and DELETE pass, a method outside the list does not"

# The WAF's 403 names its audit-log entry; the application's, and Caddy's own,
# say nothing.
headers=$(curl -s -D - -o /dev/null -H 'Host: app.example' "http://127.0.0.1:18080/v1/x?id=1%27%20OR%20%271%27%3D%271")
marker=$(awk 'tolower($1) == "x-waf-blocked:" { print $2 }' <<<"${headers}" | tr -d '\r')
[ -n "${marker}" ] || { echo "FAIL: a WAF block has no X-Waf-Blocked"; echo "${headers}"; exit 1; }
expect_in "the marker is the audit log's unique_id" "$(logs_of)" "\"unique_id\":\"${marker}\""
for path in /v1/forbidden /v1/denied; do
	headers=$(curl -s -D - -o /dev/null -H 'Host: app.example' "http://127.0.0.1:18080${path}")
	expect_in "${path} is a 403" "${headers}" " 403"
	expect_not_in "${path} is not marked" "${headers,,}" "x-waf-blocked"
done

# What the optional exclusions (section 13) change, refused by default.
code=$(curl -s -o /dev/null -w '%{http_code}' -X POST "http://127.0.0.1:18080/v1/x")
[ "${code}" = "403" ] || { echo "FAIL: a bodiless POST to a numeric Host got ${code}, expected 403"; exit 1; }
for body in '{"filter":{"$and":[{"a":{"$like":"x%"}}]}}' '{"password":"<script>Ab1\"or 1=1"}'; do
	code=$(api POST /v1/x -H 'Content-Type: application/json' -d "${body}")
	[ "${code}" = "403" ] || { echo "FAIL: ${body} got ${code}, expected 403 by default"; exit 1; }
done
echo "waf: a WAF 403 is marked and no other is"

# That warning was the only sign, and it cannot stand out if every start logs
# one: the empty overrides directory did, until it shipped a placeholder.
expect_not_in "a default start logs no empty glob" "$(logs_of)" "empty glob result"

# An Include that matches nothing refuses to start, wherever it is: the image's
# own block with overrides/ mounted empty, and a fragment with the old include.
mkdir -p "${WORK}/empty"
refuse "an empty overrides directory" -v "${WORK}/empty:/opt/coraza/overrides:ro,Z"
expect_in "refusal names the glob" "$(cat "${REFUSE_OUT}")" "/opt/coraza/overrides/*.conf"
mkdir -p "${WORK}/old-include"
# shellcheck disable=SC2016 # the backticks are Caddyfile's, not the shell's
printf 'handle /old/* {\n\tcoraza_waf {\n\t\tdirectives `\n\t\tInclude /opt/coraza/owasp-crs/rules/*.conf\n\t\t`\n\t}\n\trespond "old" 200\n}\n' \
	>"${WORK}/old-include/10-old.caddy"
refuse "a fragment including no file" -v "${WORK}/old-include:/etc/caddy/config.d:ro,Z"
expect_in "refusal names the glob" "$(cat "${REFUSE_OUT}")" "/opt/coraza/owasp-crs/rules/*.conf"
echo "waf: an Include matching no file refuses to start"

# --- 10. the WAF's body limit is CADDY_REQUEST_BODY_MAX_SIZE -----------------

# The WAF had a fixed 12.5 MiB limit of its own. Under a smaller cap it is
# worse than a second limit: a body that runs into request_body's cap while the
# WAF reads it is a 500. So the WAF must refuse first, at the cap.
body_code() {
	# body_code <bytes>: POST a JSON body of exactly that size
	printf '{"a":"%s"}' "$(head -c $(($1 - 8)) /dev/zero | tr '\000' x)" >"${WORK}/body.json"
	curl -s -o /dev/null -w '%{http_code}' -H 'Host: app.example' \
		-H 'Content-Type: application/json' --data-binary "@${WORK}/body.json" \
		"http://127.0.0.1:18080/v1/x"
}
for pair in 999=200 1000=413 5000=413; do
	code=$(body_code "${pair%=*}")
	[ "${code}" = "${pair#*=}" ] ||
		{ echo "FAIL: a ${pair%=*}-byte body under a 1000-byte cap got ${code}, expected ${pair#*=}"; exit 1; }
done
"${ENGINE}" rm -f "${CTR}" >/dev/null
echo "waf: the body limit is the cap, and an oversized body is 413, not 500"

# Caddy parses the size, so its units mean what they mean to request_body.
for pair in 30MiB=31457280 1.5GB=1073741824 0=1073741824; do
	out=$("${ENGINE}" run --rm -e "CADDY_REQUEST_BODY_MAX_SIZE=${pair%=*}" "${IMAGE}" true 2>&1)
	expect_in "CADDY_REQUEST_BODY_MAX_SIZE=${pair%=*} gives the WAF ${pair#*=}" "${out}" \
		"WAF request body limit: ${pair#*=} bytes"
done

# --- 11. CADDY_AUTO_HTTPS=on leaves automatic HTTPS on -----------------------

# Caddy has no `auto_https on`, and an empty value means the default, `off`, so
# a site serving a real domain had no way to say "on". local_certs keeps the
# certificate offline.
mkdir -p "${WORK}/servers"
printf 'local_certs\nskip_install_trust\n' >"${WORK}/servers/10-local.caddy"
start 18443:8443 -e CADDY_AUTO_HTTPS=on -e CADDY_EDGE_ADDRESS=app.example.test:8443 \
	-v "${WORK}/servers:/etc/caddy/servers.d:ro,Z"
for _ in $(seq 1 15); do
	logs="$(logs_of)"
	case "${logs}" in *"enabling automatic TLS certificate management"*) break ;; esac
	sleep 1
done
expect_in "on: certificates are managed" "${logs}" "enabling automatic TLS certificate management"
expect_in "on: the summary says on" "${logs}" "CADDY_AUTO_HTTPS = on"
expect_not_in "on: automatic HTTPS is not disabled" "${logs}" "automatic HTTPS is completely disabled"
"${ENGINE}" rm -f "${CTR}" >/dev/null

out=$("${ENGINE}" run --rm -e CADDY_EDGE_ADDRESS=app.example.test:8443 "${IMAGE}" \
	caddy adapt --config /etc/caddy/Caddyfile --adapter caddyfile 2>&1)
expect_in "default: automatic HTTPS stays off" "${out}" '"automatic_https":{"disable":true}'

# --- 12. CADDY_WAF_ENGINE=DetectionOnly blocks nothing, and says so ---------

# The variable is set after overrides/, so a file setting SecRuleEngine loses,
# and is named rather than ignored in silence.
printf 'SecRuleEngine On\n' >"${WORK}/engine.conf"
start 18080:8080 -e CADDY_WAF_ENGINE=DetectionOnly -v "${WORK}/app:/etc/caddy/config.d:ro,Z" \
	-v "${WORK}/engine.conf:/opt/coraza/overrides/50-engine.conf:ro,Z"
wait_health "http://127.0.0.1:18080/__platform_healthz"
code=$(api GET "/v1/x?id=1%27%20OR%20%271%27%3D%271")
[ "${code}" = "200" ] || { echo "FAIL: DetectionOnly answered an SQLi probe with ${code}, expected 200"; exit 1; }
logs="$(logs_of)"
expect_in "detection: the summary shows the mode" "${logs}" "CADDY_WAF_ENGINE = DetectionOnly"
expect_in "detection: a warning says nothing is blocked" "${logs}" "blocks nothing"
expect_in "detection: the probe is logged" "${logs}" "SQL Injection Attack Detected"
expect_in "detection: an override's SecRuleEngine is named" "${logs}" \
	"/opt/coraza/overrides/50-engine.conf sets SecRuleEngine"
"${ENGINE}" rm -f "${CTR}" >/dev/null
refuse "an engine Coraza takes and this image does not" -e CADDY_WAF_ENGINE=Off
expect_in "refusal names the value" "$(cat "${REFUSE_OUT}")" "CADDY_WAF_ENGINE=Off is not On or DetectionOnly"
echo "waf: DetectionOnly logs and passes, and an unknown engine refuses"

# --- 13. the optional exclusions do what they say, and only that ------------

# Taken from the image, so this tests what ships. A fragment's handle_errors
# rides along: it still writes the WAF's 403, and the marker is added.
mkdir -p "${WORK}/optional" "${WORK}/errors"
for name in ip-host mongo-operators password-fields; do
	"${ENGINE}" run --rm --entrypoint cat "${IMAGE}" "/opt/coraza/optional/${name}.conf" \
		>"${WORK}/optional/${name}.conf"
done
cp "${WORK}/app/10-app.caddy" "${WORK}/errors/"
printf 'handle_errors {\n\trespond "custom {err.status_code}" {err.status_code}\n}\n' >"${WORK}/errors/20-errors.caddy"
start 18080:8080 -v "${WORK}/errors:/etc/caddy/config.d:ro,Z" \
	-v "${WORK}/optional/ip-host.conf:/opt/coraza/overrides/ip-host.conf:ro,Z" \
	-v "${WORK}/optional/mongo-operators.conf:/opt/coraza/overrides/mongo-operators.conf:ro,Z" \
	-v "${WORK}/optional/password-fields.conf:/opt/coraza/overrides/password-fields.conf:ro,Z"
wait_health "http://127.0.0.1:18080/__platform_healthz"
code=$(curl -s -o /dev/null -w '%{http_code}' -X POST "http://127.0.0.1:18080/v1/x")
[ "${code}" = "200" ] || { echo "FAIL: ip-host.conf: a bodiless POST to a numeric Host got ${code}"; exit 1; }
for body in '{"filter":{"$and":[{"a":{"$like":"x%"}}]}}' '{"password":"<script>Ab1\"or 1=1"}' \
	'{"new_password":"<b>x</b>\" OR \"1\"=\"1"}'; do
	code=$(api POST /v1/x -H 'Content-Type: application/json' -d "${body}")
	[ "${code}" = "200" ] || { echo "FAIL: ${body} got ${code} with the exclusions, expected 200"; exit 1; }
done
code=$(api POST /v1/x -H 'Content-Type: application/json' -d '{"username":"1'"'"' OR '"'"'1'"'"'='"'"'1"}')
[ "${code}" = "403" ] || { echo "FAIL: password-fields.conf let SQLi in another field through with ${code}"; exit 1; }
headers=$(curl -s -D - -H 'Host: app.example' "http://127.0.0.1:18080/v1/x?q=%3Cscript%3Ealert(1)%3C%2Fscript%3E")
expect_in "a fragment's handle_errors still writes the WAF's 403" "${headers}" "custom 403"
expect_in "and the marker is added to it" "${headers,,}" "x-waf-blocked: "
"${ENGINE}" rm -f "${CTR}" >/dev/null
echo "waf: each exclusion passes its case, and a field it does not name is still checked"

echo "PASS: caddy"
