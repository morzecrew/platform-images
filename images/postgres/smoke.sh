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

echo "PASS: postgres"
