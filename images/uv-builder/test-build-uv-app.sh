#!/usr/bin/env bash
# build-uv-app's two-layer mode, end to end: a fixture built twice, with only
# its source changed in between, onto the python-distroless it would ship on.
#
# Not in smoke.sh, which receives one image: this needs two, and two builds.
# Rootless Podman builds, for the reason images/npm-builder/test-build-js-app.sh
# gives: CI's buildx driver cannot use a locally loaded image in `FROM`.
#
#   UV_BUILDER_REF=<image> DISTROLESS_REF=<image> bash test-build-uv-app.sh
set -euo pipefail

ENGINE="${ENGINE:-podman}"
BUILDER="${UV_BUILDER_REF:?set UV_BUILDER_REF to the uv-builder image under test}"
RUNTIME="${DISTROLESS_REF:?set DISTROLESS_REF to the python-distroless image to run on}"
WORK="$(mktemp -d)"
FIXTURE="localhost/uv-layers-fixture"

cleanup() {
	"${ENGINE}" rmi -f "${FIXTURE}:1" "${FIXTURE}:2" >/dev/null 2>&1 || true
	rm -rf "${WORK}"
}
trap cleanup EXIT

die() { echo "FAIL: $*" >&2; exit 1; }

# A path dependency gives the deps layer real content with the network off.
mkdir -p "${WORK}/vendor/dep/src/dep" "${WORK}/src/layerapp"
touch "${WORK}/vendor/dep/src/dep/__init__.py"
cat >"${WORK}/vendor/dep/pyproject.toml" <<'EOF'
[project]
name = "dep"
version = "0.0.0"

[build-system]
requires = ["uv_build>=0.7"]
build-backend = "uv_build"
EOF
cat >"${WORK}/pyproject.toml" <<'EOF'
[project]
name = "layerapp"
version = "0.0.0"
requires-python = ">=3.10"
dependencies = ["dep"]

[project.scripts]
layerapp = "layerapp:main"

[tool.uv.sources]
dep = { path = "vendor/dep" }

[build-system]
requires = ["uv_build>=0.7"]
build-backend = "uv_build"
EOF
cat >"${WORK}/Containerfile" <<'EOF'
ARG BUILDER
ARG RUNTIME

FROM ${BUILDER} AS deps
COPY pyproject.toml uv.lock /app/
COPY vendor /app/vendor
RUN build-uv-app deps

FROM deps AS app
COPY src /app/src
RUN build-uv-app app

FROM ${RUNTIME}
COPY --from=deps /opt/venv /opt/venv
COPY --from=app /opt/app /opt/app
ENTRYPOINT ["/opt/app/bin/layerapp"]
EOF
"${ENGINE}" run --rm --network none -v "${WORK}:/app:Z" "${BUILDER}" uv lock -q --offline ||
	die "could not lock the fixture"

build() {
	printf 'import dep\nVALUE = %s\ndef main():\n    print(VALUE, dep.__name__)\n' "$1" \
		>"${WORK}/src/layerapp/__init__.py"
	local out
	out="$("${ENGINE}" build --network none -f "${WORK}/Containerfile" \
		--build-arg "BUILDER=${BUILDER}" --build-arg "RUNTIME=${RUNTIME}" \
		-t "${FIXTURE}:$1" "${WORK}" 2>&1)" || { echo "${out}"; die "fixture build $1 failed"; }
}
layers() { "${ENGINE}" image inspect --format '{{json .RootFS.Layers}}' "$1"; }

build 1
build 2

# The last two layers are the venv and the app. Only the source changed, so
# the venv layer must be the same layer and the app layer must not.
read -r venv1 app1 < <(layers "${FIXTURE}:1" | python3 -c 'import json,sys; print(*json.load(sys.stdin)[-2:])')
read -r venv2 app2 < <(layers "${FIXTURE}:2" | python3 -c 'import json,sys; print(*json.load(sys.stdin)[-2:])')
[ "${venv1}" = "${venv2}" ] || die "a source-only change rebuilt the venv layer (${venv1} -> ${venv2})"
[ "${app1}" != "${app2}" ] || die "the app layer did not change with the source"
echo "  ok: source-only change: venv layer identical, app layer new"

got="$("${ENGINE}" run --rm "${FIXTURE}:2")"
[ "${got}" = "2 dep" ] || die "entry point printed '${got}', want '2 dep'"
echo "  ok: the console script runs on python-distroless"

# A bare `python`, found on PATH, as `docker exec <container> python` finds it.
"${ENGINE}" run --rm --entrypoint python "${FIXTURE}:2" -c 'import layerapp, dep' ||
	die "a bare python on PATH is not the venv's: it cannot import the application"
echo "  ok: python on PATH is the venv's"

# Both layers' bytecode is what the runtime loads, not a recompile.
trace="$("${ENGINE}" run --rm --entrypoint /opt/venv/bin/python "${FIXTURE}:2" -v -c 'import layerapp' 2>&1)"
for want in "/opt/app/layerapp/" "/opt/venv/lib/python3.*/site-packages/dep/"; do
	echo "${trace}" | grep -q "^# code object from '${want}__pycache__/__init__\.cpython-.*\.pyc'" ||
		die "${want} ran without its bytecode"
done
echo "  ok: bytecode loaded from APP_PATH and from the venv"

echo "PASS: build-uv-app two-layer mode"
