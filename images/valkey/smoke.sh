#!/usr/bin/env bash
# Smoke test for the valkey image. See RFC 0006 §6 and RFC 0002 §5.5.
#
# Half of these assert that the container *refuses to start*. That is the point
# of the image: the two §5.3 combinations lose data silently, so the test that
# matters is that they are rejected loudly rather than accepted.
set -euo pipefail
IMAGE="${1:?usage: smoke.sh <image-ref>}"
ENGINE="${ENGINE:-podman}"
CTR="smoke-valkey-$$"
WORK="$(mktemp -d)"
cleanup() {
	"${ENGINE}" rm -f "${CTR}" >/dev/null 2>&1 || true
	rm -rf "${WORK}"
}
trap cleanup EXIT

start() {
	# start <name> [engine args...]
	local name="$1"
	shift
	"${ENGINE}" rm -f "${name}" >/dev/null 2>&1 || true
	"${ENGINE}" run -d --name "${name}" "$@" "${IMAGE}" >/dev/null
}

wait_ready() {
	local name="$1"
	local i reply
	# NOAUTH counts as ready: the server is up and answering, it just wants a
	# password. Treating it as not-ready made every password case print a
	# tolerated "never became ready" and dump logs, which buries real failures.
	for i in $(seq 1 40); do
		reply="$("${ENGINE}" exec "${name}" valkey-cli PING 2>&1 || true)"
		case "${reply}" in
		*PONG* | *NOAUTH*) return 0 ;;
		esac
		sleep 0.5
	done
	echo "FAIL: ${name} never became ready"
	"${ENGINE}" logs "${name}" 2>&1 | tail -20
	return 1
}

cfg() {
	# cfg <container> <directive> -> value
	"${ENGINE}" exec "$1" valkey-cli CONFIG GET "$2" | sed -n '2p' | tr -d '\r'
}

# Runs the image with the given env and expects it to exit non-zero, with
# `needle` in its output. Used for every refusal.
expect_refusal() {
	local label="$1" needle="$2"
	shift 2
	local name="${CTR}-r$$"
	local out rc
	# Bounded twice, because a lost refusal does not exit non-zero -- it starts
	# a server that runs forever. Unbounded, this assertion hangs until CI
	# kills the job, which reads as an infrastructure problem rather than as
	# the data-loss regression it is. `--kill-after` bounds the bound: plain
	# `timeout` sends SIGTERM and then waits for a process that may not take
	# it. The kill path exits 137 rather than 124, and both mean the same
	# thing here.
	set +e
	out=$(timeout --kill-after=10 60 "${ENGINE}" run --rm --name "${name}" "$@" "${IMAGE}" 2>&1)
	rc=$?
	set -e
	"${ENGINE}" rm -f "${name}" >/dev/null 2>&1 || true
	if [ "${rc}" -eq 124 ] || [ "${rc}" -eq 137 ]; then
		echo "FAIL: ${label} started and kept running, but it must refuse"
		echo "${out}" | tail -5
		exit 1
	fi
	if [ "${rc}" -eq 0 ]; then
		echo "FAIL: ${label} started, but it must refuse"
		echo "${out}" | tail -5
		exit 1
	fi
	case "${out}" in
	*"${needle}"*) echo "refused: ${label}" ;;
	*)
		echo "FAIL: ${label} refused but did not mention '${needle}'"
		echo "${out}" | tail -10
		exit 1
		;;
	esac
}

# --- 1. starts with no configuration, and evicts by default ----------------

start "${CTR}"
wait_ready "${CTR}"

maxmemory="$(cfg "${CTR}" maxmemory)"
[ "${maxmemory}" != "0" ] || { echo "FAIL: maxmemory is 0 (unlimited)"; exit 1; }
echo "maxmemory: ${maxmemory}"

policy="$(cfg "${CTR}" maxmemory-policy)"
[ "${policy}" = "allkeys-lru" ] || { echo "FAIL: maxmemory-policy=${policy}"; exit 1; }
echo "maxmemory-policy: ${policy}"

# --- 2. renamed commands are gone, CONFIG still works ----------------------

# CONFIG GET already worked above, which is the assertion: several client
# libraries call it at connect time to warn about eviction, and disabling it
# breaks them (RFC 0006 decision 8).
echo "CONFIG GET: works"

for cmd in FLUSHALL FLUSHDB KEYS; do
	out="$("${ENGINE}" exec "${CTR}" valkey-cli "${cmd}" 2>&1 || true)"
	case "${out}" in
	*"unknown command"*) echo "disabled: ${cmd}" ;;
	*) echo "FAIL: ${cmd} is still callable: ${out}"; exit 1 ;;
	esac
done

# --- 3. the startup summary reports what an operator needs -----------------

logs="$("${ENGINE}" logs "${CTR}" 2>&1)"
for needle in "maxmemory = " "maxmemory-policy = " "disabled-commands" "precedence:"; do
	case "${logs}" in
	*"${needle}"*) ;;
	*) echo "FAIL: summary missing '${needle}'"; exit 1 ;;
	esac
done
echo "summary: present"
"${ENGINE}" rm -f "${CTR}" >/dev/null

# --- 4. the cgroup path, which is the one most likely to be silently wrong --

start "${CTR}" --memory 256m
wait_ready "${CTR}"

# Rootless engines cannot always apply a memory limit -- it needs cgroup v2
# with delegation -- and where it is not applied the image correctly takes its
# warned fallback. Distinguish the two rather than asserting a number, so this
# reports on the image and not on the runtime it happens to be running under.
# Captured rather than piped to grep -q: under `set -o pipefail`, grep exiting
# early SIGPIPEs the writer and the pipeline reports 141.
mem_logs="$("${ENGINE}" logs "${CTR}" 2>&1)"
case "${mem_logs}" in
*"source=derived"*)
	derived="$(cfg "${CTR}" maxmemory)"
	# 75% of 256 MiB = 201326592, less up to 99 bytes for the divide-first
	# rounding, plus slack for runtimes that round the limit itself.
	if [ "${derived}" -lt 195000000 ] || [ "${derived}" -gt 210000000 ]; then
		echo "FAIL: under a 256m limit, derived maxmemory=${derived}, expected ~201326592"
		"${ENGINE}" logs "${CTR}" 2>&1 | head -5
		exit 1
	fi
	echo "derived from cgroup: ${derived} (~75% of 256m)"
	;;
*"source=fallback"*)
	echo "skip cgroup derivation: this runtime did not apply --memory;"
	echo "     the image took its warned fallback, which is the documented behaviour"
	;;
*)
	echo "FAIL: maxmemory was neither derived nor the fallback"
	printf '%s\n' "${mem_logs}" | head -10
	exit 1
	;;
esac
"${ENGINE}" rm -f "${CTR}" >/dev/null

# --- 5. secrets: _FILE beats plain, unreadable _FILE aborts ----------------

printf 'from-file' >"${WORK}/pw"
chmod 0644 "${WORK}/pw"
start "${CTR}" -v "${WORK}/pw:/run/pw:ro,Z" \
	-e VALKEY_PASSWORD=from-env -e VALKEY_PASSWORD_FILE=/run/pw
wait_ready "${CTR}"
if "${ENGINE}" exec "${CTR}" valkey-cli -a from-file PING 2>/dev/null | grep -q PONG; then
	echo "_FILE beats the plain variable"
else
	echo "FAIL: password did not come from VALKEY_PASSWORD_FILE"
	"${ENGINE}" logs "${CTR}" 2>&1 | tail -5
	exit 1
fi
# The plain value must not be what is in force.
if "${ENGINE}" exec "${CTR}" valkey-cli -a from-env PING 2>/dev/null | grep -q PONG; then
	echo "FAIL: the plain VALKEY_PASSWORD was used despite _FILE being set"
	exit 1
fi
# ...and the summary must not print either of them.
case "$("${ENGINE}" logs "${CTR}" 2>&1)" in
*from-file* | *from-env*) echo "FAIL: the summary leaked the password"; exit 1 ;;
*) echo "summary redacts the password" ;;
esac
"${ENGINE}" rm -f "${CTR}" >/dev/null

expect_refusal "an unreadable VALKEY_PASSWORD_FILE" "not readable" \
	-e VALKEY_PASSWORD=fallback -e VALKEY_PASSWORD_FILE=/nonexistent/pw

# --- 6. the two §5.3 refusals ----------------------------------------------

expect_refusal "persistence with an evicting policy" "contradict each other" \
	-e VALKEY_PERSISTENCE=rdb -e VALKEY_MAXMEMORY_POLICY=allkeys-lru

expect_refusal "persistence without an explicit policy" "explicitly" \
	-e VALKEY_PERSISTENCE=rdb

# --- 7. channel collision (RFC 0001 decision 11) ---------------------------

expect_refusal "curated and passthrough setting the same key" "both set it" \
	-e VALKEY_MAXMEMORY_POLICY=noeviction -e VALKEY_CONF__maxmemory_policy=noeviction

# --- 8. allowlist and denylist --------------------------------------------

expect_refusal "a key outside the allowlist" "not in the allowlist" \
	-e VALKEY_CONF__definitely_not_a_directive=1

expect_refusal "a denylisted key, even under strict=ignore" "denylisted" \
	-e VALKEY_CONF_STRICT=ignore -e VALKEY_CONF__include=/tmp/evil.conf

expect_refusal "a passthrough value containing a newline" "newline" \
	-e "VALKEY_CONF__loglevel=one
two"

# --- 9. the durable path actually works and survives a restart -------------

start "${CTR}" -e VALKEY_PERSISTENCE=rdb -e VALKEY_MAXMEMORY_POLICY=noeviction
wait_ready "${CTR}"
[ "$(cfg "${CTR}" maxmemory-policy)" = "noeviction" ] ||
	{ echo "FAIL: durable config did not take"; exit 1; }
"${ENGINE}" exec "${CTR}" valkey-cli SET durable-key durable-value >/dev/null
"${ENGINE}" exec "${CTR}" valkey-cli SAVE >/dev/null
"${ENGINE}" restart "${CTR}" >/dev/null
wait_ready "${CTR}"
got="$("${ENGINE}" exec "${CTR}" valkey-cli GET durable-key | tr -d '\r')"
[ "${got}" = "durable-value" ] ||
	{ echo "FAIL: data did not survive a restart, got '${got}'"; exit 1; }
echo "persistence: data survived a restart"

# --- 10. passthrough reaches the server, with the right spelling -----------

"${ENGINE}" rm -f "${CTR}" >/dev/null
start "${CTR}" -e VALKEY_CONF__MAXMEMORY_SAMPLES=7 -e VALKEY_CONF__notify-keyspace-events=KEA
wait_ready "${CTR}"
[ "$(cfg "${CTR}" maxmemory-samples)" = "7" ] ||
	{ echo "FAIL: VALKEY_CONF__MAXMEMORY_SAMPLES did not reach the server"; exit 1; }
echo "passthrough: uppercase/underscore input reached maxmemory-samples"
[ "$(cfg "${CTR}" notify-keyspace-events)" = "gxeKEA" ] ||
	[ -n "$(cfg "${CTR}" notify-keyspace-events)" ] ||
	{ echo "FAIL: notify-keyspace-events did not reach the server"; exit 1; }
# It must not be redacted -- it is a directive an operator needs to read back.
case "$("${ENGINE}" logs "${CTR}" 2>&1)" in
*"notify-keyspace-events = KEA"*) echo "passthrough: not falsely redacted" ;;
*) echo "FAIL: notify-keyspace-events was redacted or missing from the summary"; exit 1 ;;
esac

# --- 11. the mounted layer ------------------------------------------------

mkdir -p "${WORK}/conf.d"
printf 'maxmemory-samples 9\nloglevel notice\n' >"${WORK}/conf.d/50-tuning.conf"
"${ENGINE}" rm -f "${CTR}" >/dev/null
start "${CTR}" -v "${WORK}/conf.d:/etc/valkey/conf.d:ro,Z"
wait_ready "${CTR}"
[ "$(cfg "${CTR}" maxmemory-samples)" = "9" ] ||
	{ echo "FAIL: a mounted fragment did not reach the server"; exit 1; }
echo "mounted fragment: applied"

# Per directive, not one "included verbatim" line: RFC 0001 decision 13
# requires real attribution from an image that assembles enumerable layers.
case "$("${ENGINE}" logs "${CTR}" 2>&1)" in
*"source=mounted"*"maxmemory-samples = 9"*) echo "mounted fragment: attributed per directive" ;;
*) echo "FAIL: fragment settings are not attributed individually"; exit 1 ;;
esac

# Env must still beat a mounted fragment (precedence: baked < mounted < env).
"${ENGINE}" rm -f "${CTR}" >/dev/null
start "${CTR}" -v "${WORK}/conf.d:/etc/valkey/conf.d:ro,Z" -e VALKEY_CONF__maxmemory_samples=3
wait_ready "${CTR}"
[ "$(cfg "${CTR}" maxmemory-samples)" = "3" ] ||
	{ echo "FAIL: env did not override a mounted fragment"; exit 1; }
echo "precedence: env beats mounted"
"${ENGINE}" rm -f "${CTR}" >/dev/null

# A fragment can enable persistence without going through VALKEY_PERSISTENCE.
# The refusal is checked against the assembled config, so this is caught too --
# otherwise decision 6 would hold only for the environment channel.
mkdir -p "${WORK}/bypass"
printf 'appendonly yes\n' >"${WORK}/bypass/60-persist.conf"
# The fragment sets appendonly with no policy anywhere, so the missing-policy
# refusal fires first -- the right order, and why the needle is that message.
expect_refusal "a fragment enabling persistence with no explicit policy" \
	"no eviction policy was set explicitly" -v "${WORK}/bypass:/etc/valkey/conf.d:ro,Z"

# With a policy that evicts, the other refusal fires on the same path.
printf 'appendonly yes\nmaxmemory-policy allkeys-lru\n' >"${WORK}/bypass/60-persist.conf"
expect_refusal "a fragment enabling persistence under an evicting policy" \
	"contradict each other" -v "${WORK}/bypass:/etc/valkey/conf.d:ro,Z"

# --- 12. protected-mode, which is the behaviour most likely to surprise ----

# RFC 0006 §5.4 requires the bind behaviour be stated rather than inherited
# silently, so it is asserted rather than described: with no password, a
# connection from anywhere but loopback is refused.
#
# The container's own non-loopback address is used rather than a second
# container on a user-defined network. It exercises the same code path in the
# server and needs no network to be created, which keeps this from going red
# for reasons that have nothing to do with the image.
"${ENGINE}" rm -f "${CTR}" >/dev/null
start "${CTR}"
wait_ready "${CTR}"

peer="$("${ENGINE}" exec "${CTR}" sh -c 'valkey-cli -h "$(hostname -i)" PING 2>&1 | head -1' || true)"
case "${peer}" in
*DENIED*) echo "protected-mode: an unauthenticated non-loopback peer is denied, as documented" ;;
*PONG*) echo "FAIL: an unauthenticated peer connected; the README says it cannot"; exit 1 ;;
*) echo "FAIL: unexpected peer response: ${peer}"; exit 1 ;;
esac

# ...and with a password it works, which is what the README tells people to do.
"${ENGINE}" rm -f "${CTR}" >/dev/null
start "${CTR}" -e VALKEY_PASSWORD=smoke-pw
wait_ready "${CTR}"
peer="$("${ENGINE}" exec "${CTR}" sh -c \
	'valkey-cli -h "$(hostname -i)" -a smoke-pw --no-auth-warning PING 2>&1 | head -1' || true)"
case "${peer}" in
*PONG*) echo "protected-mode: an authenticated non-loopback peer connects" ;;
*) echo "FAIL: authenticated peer could not connect: ${peer}"; exit 1 ;;
esac
"${ENGINE}" rm -f "${CTR}" >/dev/null

# --- 13. a typo'd curated name is warned about (RFC 0001 decision 9) -------

"${ENGINE}" rm -f "${CTR}" >/dev/null
start "${CTR}" -e VALKEY_MAXMEMROY=100mb
wait_ready "${CTR}"
case "$("${ENGINE}" logs "${CTR}" 2>&1)" in
*"VALKEY_MAXMEMROY is set but this image does not use it"*)
	echo "typo'd curated name: warned, and the server still started"
	;;
*) echo "FAIL: a typo'd curated variable was ignored silently"; exit 1 ;;
esac
"${ENGINE}" rm -f "${CTR}" >/dev/null

# --- 14. values needing quoting reach the server intact -------------------

# A curated value is written by the entrypoint, not by envconf_render, so it
# only stays safe while both use the same quoter. A password with a space made
# valkey exit with "wrong number of arguments" when they diverged.
"${ENGINE}" rm -f "${CTR}" >/dev/null
start "${CTR}" -e "VALKEY_PASSWORD=two words"
wait_ready "${CTR}"
if "${ENGINE}" exec "${CTR}" valkey-cli -a "two words" --no-auth-warning PING 2>/dev/null | grep -q PONG; then
	echo "curated value with a space: quoted and in force"
else
	echo "FAIL: a password containing a space did not survive into valkey.conf"
	"${ENGINE}" logs "${CTR}" 2>&1 | tail -5
	exit 1
fi

# Valkey splits a quoted argument back into tokens, so a multi-argument
# directive survives the same quoting.
"${ENGINE}" rm -f "${CTR}" >/dev/null
start "${CTR}" -e "VALKEY_CONF__client-output-buffer-limit=normal 0 0 0"
wait_ready "${CTR}"
case "$(cfg "${CTR}" client-output-buffer-limit)" in
"normal 0 0 0"*) echo "multi-argument passthrough: applied" ;;
*) echo "FAIL: client-output-buffer-limit did not apply: $(cfg "${CTR}" client-output-buffer-limit)"; exit 1 ;;
esac

# --- 15. the summary reports the layer that won, once ---------------------

"${ENGINE}" rm -f "${CTR}" >/dev/null
mkdir -p "${WORK}/override"
printf 'loglevel notice\n' >"${WORK}/override/50-log.conf"
start "${CTR}" -v "${WORK}/override:/etc/valkey/conf.d:ro,Z" -e VALKEY_CONF__loglevel=debug
wait_ready "${CTR}"
[ "$(cfg "${CTR}" loglevel)" = "debug" ] || { echo "FAIL: env did not win"; exit 1; }
rows="$("${ENGINE}" logs "${CTR}" 2>&1 | grep -c 'loglevel = ' || true)"
[ "${rows}" = "1" ] || {
	echo "FAIL: summary shows ${rows} rows for loglevel; an overridden key must appear once"
	"${ENGINE}" logs "${CTR}" 2>&1 | grep 'loglevel'
	exit 1
}
case "$("${ENGINE}" logs "${CTR}" 2>&1 | grep 'loglevel = ')" in
*"source=env"*"debug"*) echo "summary: overridden key shown once, attributed to the winner" ;;
*) echo "FAIL: the single loglevel row is not the winning one"; exit 1 ;;
esac
"${ENGINE}" rm -f "${CTR}" >/dev/null

# --- 16. the two channels are equivalent for the refusals -----------------

# maxmemory-policy is allowlisted, so it has a passthrough spelling. A durable
# setup expressed that way is safe and must start; the refusals evaluate the
# assembled config, not just the curated channel.
"${ENGINE}" rm -f "${CTR}" >/dev/null
start "${CTR}" -e VALKEY_PERSISTENCE=aof -e "VALKEY_CONF__maxmemory-policy=noeviction"
wait_ready "${CTR}"
[ "$(cfg "${CTR}" maxmemory-policy)" = "noeviction" ] ||
	{ echo "FAIL: a safe durable config set through the passthrough channel did not apply"; exit 1; }
echo "channels equivalent: durable config via passthrough starts"
"${ENGINE}" rm -f "${CTR}" >/dev/null

# ...and the refusals still fire when the policy really is missing or evicting.
expect_refusal "persistence with an evicting policy set via passthrough" \
	"contradict each other" \
	-e VALKEY_PERSISTENCE=aof -e "VALKEY_CONF__maxmemory-policy=allkeys-lru"

# --- 17. an indented fragment directive is still attributed ---------------

mkdir -p "${WORK}/indented"
printf '  maxmemory-samples 9\n' >"${WORK}/indented/50-indented.conf"
start "${CTR}" -v "${WORK}/indented:/etc/valkey/conf.d:ro,Z"
wait_ready "${CTR}"
[ "$(cfg "${CTR}" maxmemory-samples)" = "9" ] ||
	{ echo "FAIL: an indented fragment directive did not apply"; exit 1; }
# It applies either way -- the bug was that it applied *without* a summary row,
# which is the combination an operator cannot diagnose.
case "$("${ENGINE}" logs "${CTR}" 2>&1)" in
*"source=mounted"*"maxmemory-samples = 9"*) echo "indented fragment: applied and attributed" ;;
*) echo "FAIL: an indented fragment applied without a summary row"; exit 1 ;;
esac
"${ENGINE}" rm -f "${CTR}" >/dev/null

# --- 18. a runtime CONFIG REWRITE does not survive a restart --------------
#
# RFC 0006 §10 question 4. `CONFIG SET` changes the running server only, but
# `CONFIG REWRITE` writes that change into the generated valkey.conf -- so a
# persistence channel does exist, and it outranks nothing only because the
# entrypoint regenerates the file from the environment on every start.
#
# The rewrite is asserted *before* the restart on purpose. Without it this
# section would still pass against an image where CONFIG REWRITE quietly did
# nothing, which is the same assertion with none of the meaning.
#
# This is the property postgres does not have: ALTER SYSTEM writes into PGDATA,
# which is a mounted volume the entrypoint must not overwrite. The difference is
# where the file lives, not what either RFC decided.

start "${CTR}" -e VALKEY_MAXMEMORY=100mb
wait_ready "${CTR}"
[ "$(cfg "${CTR}" maxmemory)" = "104857600" ] ||
	{ echo "FAIL: VALKEY_MAXMEMORY did not take"; exit 1; }

"${ENGINE}" exec "${CTR}" valkey-cli CONFIG SET maxmemory 7mb >/dev/null
[ "$(cfg "${CTR}" maxmemory)" = "7340032" ] ||
	{ echo "FAIL: CONFIG SET did not change the running value"; exit 1; }
"${ENGINE}" exec "${CTR}" valkey-cli CONFIG REWRITE >/dev/null
"${ENGINE}" exec "${CTR}" grep -q '^maxmemory 7mb' /etc/valkey/valkey.conf ||
	{ echo "FAIL: CONFIG REWRITE did not reach the generated conf -- this test proves nothing"; exit 1; }
echo "runtime drift: CONFIG REWRITE does reach the generated conf"

"${ENGINE}" restart "${CTR}" >/dev/null
wait_ready "${CTR}"
[ "$(cfg "${CTR}" maxmemory)" = "104857600" ] ||
	{ echo "FAIL: a CONFIG REWRITE survived a restart; the summary now lies at boot"; exit 1; }
"${ENGINE}" exec "${CTR}" grep -q '^maxmemory 100mb' /etc/valkey/valkey.conf ||
	{ echo "FAIL: valkey.conf was not regenerated from the environment"; exit 1; }
echo "runtime drift: erased by the restart, conf regenerated from the environment"
"${ENGINE}" rm -f "${CTR}" >/dev/null

echo "PASS: valkey"
