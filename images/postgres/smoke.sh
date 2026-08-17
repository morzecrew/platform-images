#!/usr/bin/env bash
# Smoke test: does this image actually run? See RFC 0002 §5.5.
# Invoked as: smoke.sh <image-ref>. Runs under rootless Podman in CI.
set -euo pipefail
IMAGE="${1:?usage: smoke.sh <image-ref>}"
ENGINE="${ENGINE:-podman}"
CTR="smoke-postgres-$$"
MANIFEST_PATH=/usr/local/share/postgres-extensions/extensions.manifest
cleanup() { "${ENGINE}" rm -f "${CTR}" >/dev/null 2>&1 || true; }
trap cleanup EXIT

# Expectations are derived from the image, not hard-coded: PG_EXTENSIONS is a
# build input, and RFC 0004 decision 7 admits three variants. A test that
# asserts the default set would reject a healthy variant while proving nothing
# extra about the default.
#
# The label is the build's own record of what was selected (decision 10), and
# the build refuses a non-canonical spelling, so reading it in order yields
# manifest order. That is what makes deriving the preload list from it valid.
selected=$("${ENGINE}" image inspect \
	--format '{{ index .Config.Labels "io.morze.postgres.extensions" }}' "${IMAGE}")
echo "selected extensions (label): ${selected:-<none>}"

# POSTGRES_PASSWORD is required by the upstream entrypoint; without it the
# container refuses to initialise and the test would fail for the wrong reason.
"${ENGINE}" run -d --name "${CTR}" -e POSTGRES_PASSWORD=smoke "${IMAGE}" >/dev/null

for _ in $(seq 1 60); do
	if "${ENGINE}" exec "${CTR}" pg_isready -U postgres >/dev/null 2>&1; then ready=1; break; fi
	sleep 2
done
[ "${ready:-0}" = 1 ] || { echo "FAIL: never became ready"; "${ENGINE}" logs "${CTR}"; exit 1; }

manifest=$("${ENGINE}" exec "${CTR}" cat "${MANIFEST_PATH}")

# Column 3 is the SQL name, column 4 the preload library. Both are needed
# because neither is derivable from the other: cron's preload and SQL name are
# both pg_cron, while pgroonga has a control file and no preload at all.
field() {
	echo "${manifest}" | awk -F: -v want="$1" -v idx="$2" '
		{ sub(/#.*/, ""); n=$1; gsub(/^[ \t]+|[ \t]+$/, "", n)
		  if (n == want) { v=$idx; gsub(/^[ \t]+|[ \t]+$/, "", v); print v } }'
}

expected_preloads=()
expected_available=()
for name in ${selected}; do
	sql=$(field "${name}" 3)
	pre=$(field "${name}" 4)
	[ -n "${sql}" ] || { echo "FAIL: ${name} is labelled but absent from the manifest"; exit 1; }
	expected_available+=("${sql}")
	[ -n "${pre}" ] && expected_preloads+=("${pre}")
done

# pg_stat_statements ships with the server and is preloaded unconditionally, so
# it is outside the label (decision 10) and appended here rather than derived.
expected_preloads+=("pg_stat_statements")
expected_available+=("pg_stat_statements")
expected_csv=$(IFS=,; echo "${expected_preloads[*]}")

# The preload line is generated at build time from PG_EXTENSIONS; if it named a
# library that was not installed the server would not have started at all, so
# reaching here already proves the RFC 0004 trap is closed. Assert the value too,
# because order is observable and the refactor promised to preserve it.
preload=$("${ENGINE}" exec "${CTR}" psql -U postgres -tAc "SHOW shared_preload_libraries")
echo "shared_preload_libraries = ${preload}"
[ "${preload}" = "${expected_csv}" ] || {
	echo "FAIL: preload list is '${preload}', expected '${expected_csv}'"; exit 1; }

available() {
	"${ENGINE}" exec "${CTR}" psql -U postgres -tAc \
		"SELECT count(*) FROM pg_available_extensions WHERE name = '$1'"
}

for ext in "${expected_available[@]}"; do
	[ "$(available "${ext}")" = "1" ] || { echo "FAIL: ${ext} not available"; exit 1; }
	echo "available: ${ext}"
done

# The other direction, and it is not symmetry for its own sake: checking only
# that the label's extensions are present passes an image that installed more
# than it admits to, and the label is what consumers read to know what is in
# here (decision 10). The manifest is the closed set of optional extensions --
# anything in it that was not selected must be absent -- which catches both an
# under-claiming label and a build that installed something nobody asked for.
# Contrib modules shipped by the server are not manifest rows, so they are out
# of scope here and correctly not asserted absent.
for name in $(echo "${manifest}" | awk -F: '{ sub(/#.*/, ""); n=$1
	gsub(/^[ \t]+|[ \t]+$/, "", n); if (n != "") print n }'); do
	case " ${selected} " in *" ${name} "*) continue ;; esac
	sql=$(field "${name}" 3)
	[ "$(available "${sql}")" = "0" ] || {
		echo "FAIL: ${sql} is available but ${name} is not in the label '${selected}'"
		exit 1
	}
	echo "absent as expected: ${sql}"
done

# pg_cron's settings arrive with pg_cron, not from the base config -- so this
# only applies to a build that selected it.
case " ${selected} " in
*" cron "*)
	cron_db=$("${ENGINE}" exec "${CTR}" psql -U postgres -tAc "SHOW cron.database_name")
	[ "${cron_db}" = "postgres" ] || { echo "FAIL: cron.database_name=${cron_db}"; exit 1; }
	echo "cron.database_name: ${cron_db}"
	;;
esac


# ===========================================================================
# RFC 0001 §6 — the env-config contract, on the image that motivated it.
#
# Every case below existed as a claim in the README before P4 and was tested by
# nothing. The retrofit is the point at which they became shared behaviour, so
# they are asserted here rather than trusted to the helper's own suite: the
# helper's suite proves the functions work, and these prove this image wired
# them up.
# ===========================================================================

logs_of() { "${ENGINE}" logs "${CTR}" 2>&1; }

# expect_in <label> <haystack> <needle>, matching images/caddy/smoke.sh. The
# needle is quoted inside the pattern so `[envconf]` is literal text rather than
# a character class.
expect_in() {
	case "$2" in
	*"$3"*) echo "ok: $1" ;;
	*)
		echo "FAIL: $1"
		echo "  wanted: $3"
		exit 1
		;;
	esac
}

expect_not_in() {
	case "$2" in
	*"$3"*)
		echo "FAIL: $1 (found '$3')"
		exit 1
		;;
	*) echo "ok: $1" ;;
	esac
}

# The container from the extension checks above is still running with no
# PG_CONF__* set, so this is the summary an operator sees by default.
logs="$(logs_of)"
expect_in "summary is printed" "${logs}" "[envconf] postgres: effective non-default settings"
expect_in "summary states the precedence" "${logs}" "precedence: baked < mounted < env"
# Decision 13 (LOCKED) requires per-setting attribution from this image, and the
# baked file is the layer it would be easiest to summarise as one line.
expect_in "baked file is attributed per setting" "${logs}" "source=baked        shared_buffers"
expect_in "baked file is named" "${logs}" "(/etc/postgresql.conf)"
# The build records which conf.d fragments it shipped; without that list these
# read as operator-supplied.
expect_in "image fragment reads as baked" "${logs}" "source=baked        pg_stat_statements.max"

# The summary must precede the server, or it describes a configuration that is
# already in use by the time anyone can read it.
first_server_line=$(logs_of | grep -n "database system is ready to accept" | head -1 | cut -d: -f1)
last_summary_line=$(logs_of | grep -n "precedence: baked < mounted < env" | head -1 | cut -d: -f1)
[ -n "${first_server_line}" ] && [ -n "${last_summary_line}" ] &&
	[ "${last_summary_line}" -lt "${first_server_line}" ] ||
	{ echo "FAIL: summary does not precede the server's ready line"; exit 1; }
echo "ok: summary completes before the server is ready"

"${ENGINE}" rm -f "${CTR}" >/dev/null

# --- refusals ---------------------------------------------------------------

REFUSE_OUT="$(mktemp)"
trap '"${ENGINE}" rm -f "${CTR}" "${CTR}-r" >/dev/null 2>&1 || true; rm -f "${REFUSE_OUT}"' EXIT

# Bounded twice: a refusal that stops refusing starts a server that runs
# forever, and plain `timeout` waits after SIGTERM for a process that may not
# take it. The kill path exits 137 rather than 124 and means the same thing.
refuse() {
	local label="$1"
	shift
	local rc
	set +e
	timeout --kill-after=10 40 "${ENGINE}" run --rm --name "${CTR}-r" \
		-e POSTGRES_PASSWORD=smoke "$@" "${IMAGE}" >"${REFUSE_OUT}" 2>&1
	rc=$?
	set -e
	"${ENGINE}" rm -f "${CTR}-r" >/dev/null 2>&1 || true
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

refuse "a denylisted key" -e PG_CONF__data_directory=/tmp
expect_in "denylist refusal names the variable" "$(cat "${REFUSE_OUT}")" "PG_CONF__data_directory"

# The allowlist is operator-replaceable, so "denylisted" has to mean refused even
# when the operator's own allowlist permits it. The README says so; nothing
# tested it before this battery.
ALT_ALLOWLIST="$(mktemp)"
printf 'work_mem\nlog_line_prefix !secret\ndata_directory\n' >"${ALT_ALLOWLIST}"
chmod 0644 "${ALT_ALLOWLIST}"
refuse "a denylisted key the operator's allowlist permits" \
	-v "${ALT_ALLOWLIST}:/tmp/al.conf:ro,Z" -e PG_CONF_ALLOWLIST_PATH=/tmp/al.conf \
	-e PG_CONF__data_directory=/tmp/elsewhere
expect_in "denylist outranks the allowlist" "$(cat "${REFUSE_OUT}")" "PG_CONF__data_directory"

# Decision 2: a missing allowlist is a build defect, not a runtime condition.
refuse "a missing allowlist file" -e PG_CONF_ALLOWLIST_PATH=/nonexistent.conf
expect_in "missing allowlist names the path" "$(cat "${REFUSE_OUT}")" "/nonexistent.conf"

# The property most likely to regress in a rewrite (§6), and the one this image
# had no test for: ignore mode must not soften the denylist.
refuse "a denylisted key under strict=ignore" -e PG_CONF_STRICT_MODE=ignore -e PG_CONF__include=/tmp/x
expect_in "denylist holds in ignore mode" "$(cat "${REFUSE_OUT}")" "PG_CONF__include"

refuse "a key outside the allowlist" -e PG_CONF__nonexistent_thing=1
expect_in "allowlist refusal names the variable" "$(cat "${REFUSE_OUT}")" "PG_CONF__nonexistent_thing"

# Decision 12: no config format in scope can represent an embedded newline, so
# it is refused rather than written and left to the server's parser.
refuse "a value containing a newline" -e "PG_CONF__log_line_prefix=a
b"
expect_in "newline refusal names the variable" "$(cat "${REFUSE_OUT}")" "PG_CONF__log_line_prefix"

# Two spellings of one control variable with two values. Neither would silently
# win before P4 -- the bash script simply never read PG_CONF_STRICT.
refuse "both spellings of the strict control" \
	-e PG_CONF_STRICT_MODE=fail -e PG_CONF_STRICT=ignore
expect_in "control collision names both" "$(cat "${REFUSE_OUT}")" "PG_CONF_STRICT_MODE=fail and PG_CONF_STRICT=ignore"

# Decision 4: an unreadable secret file aborts rather than falling back. This
# name is upstream's, so upstream's file_env enforces it -- asserted here
# because the contract requires the behaviour, not a particular implementation.
set +e
timeout --kill-after=10 40 "${ENGINE}" run --rm --name "${CTR}-r" \
	-e POSTGRES_PASSWORD_FILE=/nonexistent "${IMAGE}" >"${REFUSE_OUT}" 2>&1
rc=$?
set -e
"${ENGINE}" rm -f "${CTR}-r" >/dev/null 2>&1 || true
case "${rc}" in
0 | 124 | 137) echo "FAIL: an unreadable POSTGRES_PASSWORD_FILE started"; exit 1 ;;
esac
echo "ok: refused an unreadable POSTGRES_PASSWORD_FILE"

# --- ignore mode, and what it does not soften -------------------------------

"${ENGINE}" run -d --name "${CTR}" -e POSTGRES_PASSWORD=smoke \
	-e PG_CONF_STRICT_MODE=ignore -e PG_CONF__nonexistent_thing=1 \
	-e PG_CONF__work_mem=48MB "${IMAGE}" >/dev/null
for _ in $(seq 1 60); do
	"${ENGINE}" exec "${CTR}" pg_isready -U postgres >/dev/null 2>&1 && break
	sleep 2
done
logs="$(logs_of)"
expect_in "ignore mode warns by name" "${logs}" "PG_CONF__nonexistent_thing"
# Decision 8 (LOCKED): the summary is diagnostic output about configuration and
# belongs on stderr, so stdout stays clean for anyone shipping structured logs.
# Asserted by taking stdout alone -- every other assertion here reads the streams
# merged and so cannot tell the two apart.
stdout_only=$("${ENGINE}" logs "${CTR}" 2>/dev/null || true)
expect_not_in "summary is not on stdout" "${stdout_only}" "[envconf]"
got=$("${ENGINE}" exec "${CTR}" psql -U postgres -tAc "SHOW work_mem")
[ "${got}" = "48MB" ] || { echo "FAIL: work_mem=${got}, expected 48MB"; exit 1; }
echo "ok: an allowed key still applies while an unknown one is skipped"
"${ENGINE}" rm -f "${CTR}" >/dev/null

# --- value safety and redaction (§6) ----------------------------------------

# A tab is the case that made the wire format NUL-delimited rather than
# `key<TAB>value` (decision 12). It has to survive into the rendered file and
# into the running server, not merely be accepted.
"${ENGINE}" run -d --name "${CTR}" -e POSTGRES_PASSWORD=smoke \
	-v "${ALT_ALLOWLIST}:/tmp/al.conf:ro,Z" -e PG_CONF_ALLOWLIST_PATH=/tmp/al.conf \
	-e "PG_CONF__log_line_prefix=%m$(printf '\t')[%p] " "${IMAGE}" >/dev/null
for _ in $(seq 1 60); do
	"${ENGINE}" exec "${CTR}" pg_isready -U postgres >/dev/null 2>&1 && break
	sleep 2
done
got=$("${ENGINE}" exec "${CTR}" psql -U postgres -tAc "SHOW log_line_prefix" | od -c | head -1)
case "${got}" in
*'\t'*) echo "ok: a tab survives into the server's effective config" ;;
*)
	echo "FAIL: tab lost, effective value is ${got}"
	exit 1
	;;
esac

# The same allowlist marks log_line_prefix !secret, so the summary must print the
# key and redact only the value.
logs="$(logs_of)"
expect_in "a !secret key is redacted" "${logs}" "log_line_prefix = <redacted>"
expect_not_in "the secret value does not appear" "${logs}" "[%p] "
# ...and a non-secret key on the same allowlist is printed in full.
expect_in "a non-secret key is not redacted" "${logs}" "source=baked        work_mem"
echo "ok: redaction applies per allowlist marker, not per row"
"${ENGINE}" rm -f "${CTR}" >/dev/null

# --- decision 9: a guessed curated name is not silence ----------------------

# This image has no curated channel, so PG_SHARED_BUFFERS is a plausible guess
# that configures nothing. Warning is the whole point of decision 9.
"${ENGINE}" run -d --name "${CTR}" -e POSTGRES_PASSWORD=smoke \
	-e PG_SHARED_BUFFERS=1GB "${IMAGE}" >/dev/null
for _ in $(seq 1 60); do
	"${ENGINE}" exec "${CTR}" pg_isready -U postgres >/dev/null 2>&1 && break
	sleep 2
done
logs="$(logs_of)"
expect_in "a guessed name warns" "${logs}" "PG_SHARED_BUFFERS is set but this image does not use it"
expect_in "the remedy names the passthrough channel" "${logs}" "PG_CONF__<directive>"
# Upstream sets these two on every start; warning about them is how an ignore
# list stops being read.
expect_not_in "upstream PG_MAJOR not warned" "${logs}" "PG_MAJOR is set but"
expect_not_in "upstream PG_VERSION not warned" "${logs}" "PG_VERSION is set but"
echo "ok: decision 9 warns on a guess and stays quiet about upstream's names"
"${ENGINE}" rm -f "${CTR}" >/dev/null

# --- precedence across all three layers (§6's last case) --------------------

# work_mem is set by the baked file; a mounted fragment and the environment both
# override it. The env value must win, and each layer must be attributed.
WORKDIR="$(mktemp -d)"
trap '"${ENGINE}" rm -f "${CTR}" "${CTR}-r" >/dev/null 2>&1 || true; rm -rf "${REFUSE_OUT}" "${ALT_ALLOWLIST}" "${WORKDIR}"' EXIT
# Two keys on purpose. `work_mem` is contested by all three layers, so the
# summary must collapse it to the env row -- which means it cannot also be the
# key that proves mounted attribution works. `temp_buffers` is set by this
# fragment alone.
printf 'work_mem = 8MB\ntemp_buffers = 12MB\n' >"${WORKDIR}/50-tuning.conf"
chmod 0644 "${WORKDIR}/50-tuning.conf"

"${ENGINE}" run -d --name "${CTR}" -e POSTGRES_PASSWORD=smoke \
	-v "${WORKDIR}/50-tuning.conf:/etc/postgresql/conf.d/50-tuning.conf:ro,Z" \
	-e PG_CONF__work_mem=64MB "${IMAGE}" >/dev/null
for _ in $(seq 1 60); do
	"${ENGINE}" exec "${CTR}" pg_isready -U postgres >/dev/null 2>&1 && break
	sleep 2
done
got=$("${ENGINE}" exec "${CTR}" psql -U postgres -tAc "SHOW work_mem")
[ "${got}" = "64MB" ] || { echo "FAIL: env should win, work_mem=${got}"; exit 1; }
logs="$(logs_of)"
expect_in "mounted fragment is attributed" "${logs}" "source=mounted      temp_buffers = 12MB"
expect_in "mounted fragment is named" "${logs}" "50-tuning.conf"
expect_in "the winning value is the env one" "${logs}" "source=env          work_mem = 64MB"
# One row per key, or the summary is claiming two effective values for one
# setting. The leading space matters: `maintenance_work_mem` ends in the same
# nine characters, and counting without it reports two rows for one key.
rows=$(logs_of | grep -cE " work_mem = ")
[ "${rows}" = 1 ] || { echo "FAIL: ${rows} rows for work_mem, expected 1"; exit 1; }
echo "ok: baked < mounted < env, each attributed, one row for the key"

# A mounted file is not on the build's fragment list, so it must not read as
# baked -- the distinction the manifest exists to make. Asserted on the key only
# this fragment sets, since a contested key's mounted row is collapsed away.
expect_not_in "mounted fragment does not read as baked" "${logs}" "source=baked        temp_buffers"
"${ENGINE}" rm -f "${CTR}" >/dev/null

# --- a mount that replaces an image fragment at its own path -----------------

# The build records a digest per shipped fragment, not just a name: mounting over
# `12-cron.conf` puts the operator's content at a path the image also ships, and
# matching on the name alone reported it back to them as `source=baked`.
printf 'cron.log_run = off\n' >"${WORKDIR}/12-cron.conf"
chmod 0644 "${WORKDIR}/12-cron.conf"
"${ENGINE}" run -d --name "${CTR}" -e POSTGRES_PASSWORD=smoke \
	-v "${WORKDIR}/12-cron.conf:/etc/postgresql/conf.d/12-cron.conf:ro,Z" "${IMAGE}" >/dev/null
for _ in $(seq 1 60); do
	"${ENGINE}" exec "${CTR}" pg_isready -U postgres >/dev/null 2>&1 && break
	sleep 2
done
logs="$(logs_of)"
expect_in "a replaced fragment reads as mounted" "${logs}" "source=mounted      cron.log_run = off"
expect_not_in "a replaced fragment does not read as baked" "${logs}" "source=baked        cron.log_run"
echo "ok: replacing a shipped fragment is attributed to the operator"
"${ENGINE}" rm -f "${CTR}" >/dev/null

# --- ALTER SYSTEM is a fourth layer, and it outranks the other three ---------

# postgresql.auto.conf is read after postgresql.conf and everything its
# include_dir pulled in, so a value written by SQL beats the env channel. The
# summary reported `source=env` for a value the server had stopped using.
"${ENGINE}" run -d --name "${CTR}" -e POSTGRES_PASSWORD=smoke \
	-e PG_CONF__work_mem=64MB "${IMAGE}" >/dev/null
for _ in $(seq 1 60); do
	"${ENGINE}" exec "${CTR}" pg_isready -U postgres >/dev/null 2>&1 && break
	sleep 2
done
got=$("${ENGINE}" exec "${CTR}" psql -U postgres -tAc "SHOW work_mem")
[ "${got}" = "64MB" ] || { echo "FAIL: env value not applied, work_mem=${got}"; exit 1; }
"${ENGINE}" exec "${CTR}" psql -U postgres -qc "ALTER SYSTEM SET work_mem='7MB'" >/dev/null

# Restarted rather than reloaded: the claim under test is about the order the
# files are read in at startup, which is when the summary is printed.
"${ENGINE}" restart "${CTR}" >/dev/null
for _ in $(seq 1 60); do
	"${ENGINE}" exec "${CTR}" pg_isready -U postgres >/dev/null 2>&1 && break
	sleep 2
done
got=$("${ENGINE}" exec "${CTR}" psql -U postgres -tAc "SHOW work_mem")
[ "${got}" = "7MB" ] || { echo "FAIL: ALTER SYSTEM should outrank env, work_mem=${got}"; exit 1; }
# The container has been restarted, so its log holds two summaries. The first
# one said `source=env  work_mem = 64MB` and was right at the time: no
# postgresql.auto.conf existed yet. Only the most recent block describes the
# running server, so the assertions below read that block rather than the log.
last_summary() {
	logs_of | awk '
		/\[envconf\] postgres: effective non-default settings/ { n = 0; delete a }
		{ a[++n] = $0 }
		END { for (i = 1; i <= n; i++) print a[i] }'
}

logs="$(last_summary)"
expect_in "the SQL layer is reported" "${logs}" "source=sql          work_mem = 7MB"
expect_in "the SQL layer names ALTER SYSTEM" "${logs}" "(ALTER SYSTEM)"
expect_in "the footer names the fourth layer" "${logs}" "precedence: baked < mounted < env < ALTER SYSTEM"
# The whole point: the current summary must not still be claiming the env value
# won, since the server has stopped using it.
expect_not_in "the beaten env value is not reported as effective" "${logs}" "source=env          work_mem = 64MB"
echo "ok: ALTER SYSTEM is reported as the layer that won"
"${ENGINE}" rm -f "${CTR}" >/dev/null

echo "PASS: postgres"
