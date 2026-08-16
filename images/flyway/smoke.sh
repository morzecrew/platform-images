#!/usr/bin/env bash
# Smoke test for a CLI image: does the tool run and are the bundled drivers
# actually loadable? See RFC 0002 §5.5.
set -euo pipefail
IMAGE="${1:?usage: smoke.sh <image-ref>}"
ENGINE="${ENGINE:-podman}"

out=$("${ENGINE}" run --rm "${IMAGE}" -v 2>&1 || true)
echo "${out}" | grep -qi "flyway" || { echo "FAIL: no version output"; echo "${out}"; exit 1; }
echo "version: ok"

# The drivers are the reason this image exists rather than upstream's. A missing
# jar is invisible until a migration runs against that database.
for drv in postgresql clickhouse-jdbc; do
	"${ENGINE}" run --rm --entrypoint sh "${IMAGE}" -c "ls /flyway/drivers | grep -q '^${drv}'" ||
		{ echo "FAIL: ${drv} driver missing from /flyway/drivers"; exit 1; }
	echo "driver: ${drv}"
done

echo "PASS: flyway"
