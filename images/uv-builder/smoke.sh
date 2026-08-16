#!/usr/bin/env bash
# Smoke test for a build-stage image. See RFC 0002 §5.5.
#
# RFC 0002 §5.5 prescribes running "their entrypoint helper with a --help
# equivalent". build-uv-app has no such flag -- it is a straight-line build
# script that would attempt a real sync against a project that is not there.
# So this asserts the things a build stage can be wrong about instead:
# the toolchain runs, the helper is present and executable, and it is valid
# shell rather than something that only fails when invoked for real.
set -euo pipefail
IMAGE="${1:?usage: smoke.sh <image-ref>}"
ENGINE="${ENGINE:-podman}"

"${ENGINE}" run --rm "${IMAGE}" uv --version >/dev/null || { echo "FAIL: uv missing"; exit 1; }
echo "uv: ok"

"${ENGINE}" run --rm "${IMAGE}" test -x /usr/local/bin/build-uv-app ||
	{ echo "FAIL: build-uv-app missing or not executable"; exit 1; }
echo "build-uv-app: present and executable"

# A syntax error in the helper would otherwise surface only in a consumer's
# build, long after this image was published.
"${ENGINE}" run --rm "${IMAGE}" bash -n /usr/local/bin/build-uv-app ||
	{ echo "FAIL: build-uv-app is not valid bash"; exit 1; }
echo "build-uv-app: parses"

echo "PASS: uv-builder"
