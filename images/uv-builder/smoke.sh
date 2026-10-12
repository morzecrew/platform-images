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

# The venv it produces must carry bytecode a plain interpreter loads: a
# `<module>.cpython-XY.pyc` for every module, which is what
# importlib.util.cache_from_source names at the default optimization level. It
# once compiled with -OO (`.opt-2.pyc`, ignored by a runtime started without
# -OO) and then deleted every __pycache__ in the REMOVE_TESTS step, so every
# consumer shipped a venv with no bytecode and recompiled each import at
# startup. A no-dependency project on the uv_build backend needs no network.
"${ENGINE}" run --rm --network none "${IMAGE}" bash -euo pipefail -c '
mkdir -p /app/src/smokeapp
echo "VALUE = 1" >/app/src/smokeapp/__init__.py
cat >/app/pyproject.toml <<EOF
[project]
name = "smokeapp"
version = "0.0.0"
requires-python = ">=3.10"

# build-uv-app defaults to --no-group dev, which uv refuses for an undefined group.
[dependency-groups]
dev = []

[build-system]
requires = ["uv_build>=0.7"]
build-backend = "uv_build"
EOF
uv lock -q --offline
out="$(build-uv-app 2>&1)" || { echo "${out}"; exit 1; }
/opt/venv/bin/python - <<EOF
import importlib.util, pathlib
srcs = list(pathlib.Path("/opt/venv").rglob("*.py"))
missing = [str(p) for p in srcs if not pathlib.Path(importlib.util.cache_from_source(p)).is_file()]
assert srcs and not missing, "%d of %d modules have no loadable bytecode, e.g. %s" % (len(missing), len(srcs), missing[:3])
EOF
# REMOVE_PY_SOURCES=1 leaves only bytecode. It must still import as the real
# package -- with nothing but __pycache__ it becomes an empty namespace and
# "imports" without running a line of the code.
export UV_PROJECT_ENVIRONMENT=/opt/bare VENV_PATH=/opt/bare REMOVE_PY_SOURCES=1
out="$(build-uv-app 2>&1)" || { echo "${out}"; exit 1; }
/opt/bare/bin/python - <<EOF
import smokeapp
assert getattr(smokeapp, "VALUE", None) == 1, "imported %r without its code" % smokeapp
EOF
' || { echo "FAIL: build-uv-app left modules without bytecode a plain interpreter loads"; exit 1; }
echo "build-uv-app: venv carries loadable bytecode, with and without sources"

echo "PASS: uv-builder"
