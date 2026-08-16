#!/usr/bin/env bash
# Smoke test for a distroless runtime. See RFC 0002 §5.5.
#
# No shell in the image, so everything goes through the python entrypoint.
set -euo pipefail
IMAGE="${1:?usage: smoke.sh <image-ref>}"
ENGINE="${ENGINE:-podman}"

# libmagic is the one claim this image's README makes that a build cannot
# verify: the .so is copied in from a different distro's layer, so it either
# resolves at runtime or it does not.
"${ENGINE}" run --rm "${IMAGE}" -c "import ctypes.util, ctypes; \
lib = ctypes.util.find_library('magic') or 'libmagic.so.1'; \
ctypes.CDLL(lib); print('libmagic:', lib)" ||
	{ echo "FAIL: libmagic did not load"; exit 1; }

# Non-root by construction, and the README says 65532.
uid=$("${ENGINE}" run --rm "${IMAGE}" -c "import os; print(os.getuid())")
[ "${uid}" = "65532" ] || { echo "FAIL: running as uid ${uid}, expected 65532"; exit 1; }
echo "uid: ${uid}"

# TMPDIR must be writable or every consumer that writes a temp file breaks.
"${ENGINE}" run --rm "${IMAGE}" -c "import tempfile, os; \
f = tempfile.NamedTemporaryFile(); f.write(b'x'); f.flush(); \
print('tmpdir writable:', os.environ.get('TMPDIR'))" ||
	{ echo "FAIL: TMPDIR not writable"; exit 1; }

echo "PASS: python-distroless"
