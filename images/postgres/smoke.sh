#!/usr/bin/env bash
# Smoke test: does this image actually run? See RFC 0002 §5.5.
# Invoked as: smoke.sh <image-ref>. Runs under rootless Podman in CI.
set -euo pipefail
IMAGE="${1:?usage: smoke.sh <image-ref>}"
CTR="smoke-postgres-$$"
cleanup() { "${ENGINE}" rm -f "${CTR}" >/dev/null 2>&1 || true; }
ENGINE="${ENGINE:-podman}"
trap cleanup EXIT

# POSTGRES_PASSWORD is required by the upstream entrypoint; without it the
# container refuses to initialise and the test would fail for the wrong reason.
"${ENGINE}" run -d --name "${CTR}" -e POSTGRES_PASSWORD=smoke "${IMAGE}" >/dev/null

for _ in $(seq 1 60); do
	if "${ENGINE}" exec "${CTR}" pg_isready -U postgres >/dev/null 2>&1; then ready=1; break; fi
	sleep 2
done
[ "${ready:-0}" = 1 ] || { echo "FAIL: never became ready"; "${ENGINE}" logs "${CTR}"; exit 1; }

# The preload line is generated at build time from PG_EXTENSIONS; if it named a
# library that was not installed the server would not have started at all, so
# reaching here already proves the RFC 0004 trap is closed. Assert the value too,
# because order is observable and the refactor promised to preserve it.
preload=$("${ENGINE}" exec "${CTR}" psql -U postgres -tAc "SHOW shared_preload_libraries")
echo "shared_preload_libraries = ${preload}"
[ "${preload}" = "pg_cron,pg_stat_statements" ] || {
	echo "FAIL: unexpected preload list"; exit 1; }

for ext in pg_cron pgroonga pg_stat_statements; do
	found=$("${ENGINE}" exec "${CTR}" psql -U postgres -tAc \
		"SELECT count(*) FROM pg_available_extensions WHERE name = '${ext}'")
	[ "${found}" = "1" ] || { echo "FAIL: ${ext} not available"; exit 1; }
	echo "available: ${ext}"
done

# pg_cron's settings arrive with pg_cron, not from the base config.
cron_db=$("${ENGINE}" exec "${CTR}" psql -U postgres -tAc "SHOW cron.database_name")
[ "${cron_db}" = "postgres" ] || { echo "FAIL: cron.database_name=${cron_db}"; exit 1; }

echo "PASS: postgres"
