#!/usr/bin/env bash
# Smoke test: does this image actually serve? See RFC 0002 §5.5.
set -euo pipefail
IMAGE="${1:?usage: smoke.sh <image-ref>}"
ENGINE="${ENGINE:-podman}"
CTR="smoke-caddy-$$"
cleanup() { "${ENGINE}" rm -f "${CTR}" >/dev/null 2>&1 || true; }
trap cleanup EXIT

# :8080 is above 1024 precisely so this works rootless without extra capability.
"${ENGINE}" run -d --name "${CTR}" -p 18080:8080 "${IMAGE}" >/dev/null

for _ in $(seq 1 30); do
	code=$(curl -fsS -o /dev/null -w '%{http_code}' \
		"http://127.0.0.1:18080/__platform_healthz" 2>/dev/null || true)
	[ "${code}" = "200" ] && ok=1 && break
	sleep 1
done
[ "${ok:-0}" = 1 ] || { echo "FAIL: health never returned 200"; "${ENGINE}" logs "${CTR}"; exit 1; }
echo "health: 200"

# With no CONFIG_DIR fragment injected, anything else must fall through to the
# documented 501 rather than 404 or a hang.
code=$(curl -fsS -o /dev/null -w '%{http_code}' "http://127.0.0.1:18080/nothing-here" 2>/dev/null || true)
[ "${code}" = "501" ] || { echo "FAIL: fallback returned ${code}, expected 501"; exit 1; }
echo "fallback: 501"

echo "PASS: caddy"
