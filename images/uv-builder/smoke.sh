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
mkdir -p /app/src/smokeapp/test /app/src/smokeapp/tests
printf "VALUE = 1\nfrom smokeapp.test import TEST_VALUE\n" >/app/src/smokeapp/__init__.py
echo "TEST_VALUE = 42" >/app/src/smokeapp/test/__init__.py
printf "def test_smoke():\n    assert True\n" >/app/src/smokeapp/tests/test_smoke.py
cat >/app/pyproject.toml <<EOF
[project]
name = "smokeapp"
version = "0.0.0"
requires-python = ">=3.10"

[build-system]
requires = ["uv_build>=0.7"]
build-backend = "uv_build"
EOF
uv lock -q --offline
out="$(build-uv-app 2>&1)" || { echo "${out}"; exit 1; }
/opt/venv/bin/python - <<EOF
import importlib.util, pathlib, smokeapp
srcs = list(pathlib.Path("/opt/venv").rglob("*.py"))
missing = [str(p) for p in srcs if not pathlib.Path(importlib.util.cache_from_source(p)).is_file()]
assert srcs and not missing, "%d of %d modules have no loadable bytecode, e.g. %s" % (len(missing), len(srcs), missing[:3])
# REMOVE_TESTS prunes `tests` and keeps `test`. This package imports its own
# `test` subpackage, as SQLMesh does, so pruning it would break the import.
site = pathlib.Path(smokeapp.__file__).parent
assert smokeapp.test.TEST_VALUE == 42, "the test subpackage lost its value"
assert (site / "test").is_dir(), "the runtime test/ directory was pruned"
assert not (site / "tests").exists(), "the tests/ directory was not pruned"
EOF
# The build above had no dev group, which the default UV_GROUPS must tolerate;
# this one gets a dev dependency, which the default must leave out. A local
# path package, so it resolves with the network off.
mkdir -p /devdep/src/devdep
touch /devdep/src/devdep/__init__.py
sed "s/smokeapp/devdep/" /app/pyproject.toml >/devdep/pyproject.toml
cat >>/app/pyproject.toml <<EOF

[dependency-groups]
dev = ["devdep"]

[tool.uv.sources]
devdep = { path = "/devdep" }
EOF
uv lock -q --offline
# REMOVE_PY_SOURCES=1 leaves only bytecode. It must still import as the real
# package -- with nothing but __pycache__ it becomes an empty namespace and
# "imports" without running a line of the code.
export UV_PROJECT_ENVIRONMENT=/opt/bare VENV_PATH=/opt/bare REMOVE_PY_SOURCES=1
out="$(build-uv-app 2>&1)" || { echo "${out}"; exit 1; }
/opt/bare/bin/python - <<EOF
import importlib.util, smokeapp
assert getattr(smokeapp, "VALUE", None) == 1, "imported %r without its code" % smokeapp
assert importlib.util.find_spec("devdep") is None, "the dev group was installed"
EOF
' || { echo "FAIL: build-uv-app did not produce a working production venv"; exit 1; }
echo "build-uv-app: loadable bytecode with and without sources; dev group optional and left out"

# The two-layer modes. `deps` runs before any source exists, as it does in a
# Dockerfile that copies only the lock; `app` must leave that venv exactly as
# it was, or the layer split buys nothing.
"${ENGINE}" run --rm --network none "${IMAGE}" bash -euo pipefail -c '
mkdir -p /split && cd /split
cat >pyproject.toml <<EOF
[project]
name = "splitapp"
version = "0.0.0"
requires-python = ">=3.10"

[project.scripts]
splitapp = "splitapp:main"

[build-system]
requires = ["uv_build>=0.7"]
build-backend = "uv_build"
EOF
uv lock -q --offline
export APP_ROOT=/split UV_PROJECT_ENVIRONMENT=/opt/split VENV_PATH=/opt/split APP_PATH=/opt/splitapp
out="$(build-uv-app deps 2>&1)" || { echo "${out}"; exit 1; }
venv_sum() { find /opt/split -type f -print0 | sort -z | xargs -0 sha256sum | sha256sum; }
before="$(venv_sum)"
mkdir -p src/splitapp
printf "def main():\n    print(\"splitapp ran\")\n" >src/splitapp/__init__.py
out="$(build-uv-app app 2>&1)" || { echo "${out}"; exit 1; }
[ "$(venv_sum)" = "${before}" ] || { echo "app mode changed the venv"; exit 1; }
[ ! -e /opt/splitapp/.lock ] || { echo "uv left /opt/splitapp/.lock behind"; exit 1; }
[ "$(/opt/splitapp/bin/splitapp)" = "splitapp ran" ] || { echo "console script did not run"; exit 1; }
/opt/split/bin/python - <<EOF
import importlib.util, pathlib, splitapp
assert splitapp.__file__.startswith("/opt/splitapp/"), splitapp.__file__
srcs = list(pathlib.Path("/opt/splitapp").rglob("*.py"))
missing = [str(p) for p in srcs if not pathlib.Path(importlib.util.cache_from_source(p)).is_file()]
assert srcs and not missing, missing
EOF
rc=0; build-uv-app nonsense >/dev/null 2>&1 || rc=$?
[ "${rc}" = 64 ] || { echo "an unknown mode exited ${rc}, want 64"; exit 1; }
' || { echo "FAIL: build-uv-app deps/app"; exit 1; }
echo "build-uv-app deps/app: deps without sources, app leaves the venv alone, script and bytecode in APP_PATH"

echo "PASS: uv-builder"
