#!/usr/bin/env bash
# build-uv-app [deps|app]
#
#   (none)  sync, build and install the project into VENV_PATH, then slim it.
#   deps    dependencies only, from pyproject.toml and uv.lock; no sources needed.
#   app     the project's wheel into APP_PATH, in a stage built FROM the deps one.
#
# The split is for layer caching: the venv changes only with the lock, and the
# layer that changes with every commit holds the application alone.
set -Eeuo pipefail

MODE="${1:-}"
case "${MODE}" in
"" | deps | app) ;;
*)
	echo "usage: build-uv-app [deps|app]" >&2
	exit 64
	;;
esac

: "${APP_ROOT:=/app}"
: "${VENV_PATH:=/opt/venv}"
: "${APP_PATH:=/opt/app}"
# --no-dev, not --no-group dev: the latter fails outright on a project with no
# dev group, and --no-dev drops the dev group and the legacy dev-dependencies alike.
: "${UV_GROUPS:=--no-dev}"
: "${PYTHON_BIN:=${VENV_PATH}/bin/python}"
: "${STRIP_NATIVE:=1}"
: "${REMOVE_TESTS:=1}"
: "${REMOVE_DOCS:=0}"
: "${REMOVE_LOCALES:=1}"
: "${REMOVE_TYPE_HINTS:=1}"
: "${REMOVE_BUILD_METADATA:=0}"
: "${REMOVE_PIP:=1}"
: "${REMOVE_C_EXT_DEBUG:=1}"
: "${REMOVE_PY_SOURCES:=0}"
: "${BOTOCORE_SERVICES:=s3 sts}"

cd "${APP_ROOT}"

# The directory everything below compiles and slims.
dir="${VENV_PATH}"
case "${MODE}" in
"")
	uv sync --frozen ${UV_GROUPS}
	uv build --wheel
	uv pip install --python "${PYTHON_BIN}" --no-deps dist/*.whl
	;;
deps)
	uv sync --frozen ${UV_GROUPS} --no-install-project
	# Puts APP_PATH on sys.path from this layer, so the app layer needs no
	# PYTHONPATH. Python skips a .pth line naming a directory that does not
	# exist, which APP_PATH does not until the app stage.
	site="$("${PYTHON_BIN}" -c 'import sysconfig; print(sysconfig.get_path("purelib"))')"
	echo "${APP_PATH}" >"${site}/_build_uv_app.pth"
	;;
app)
	uv build --wheel
	# --target leaves the venv, the deps stage's layer, untouched. Console
	# scripts land in APP_PATH/bin, with the venv's python as their shebang.
	uv pip install --python "${PYTHON_BIN}" --no-deps --target "${APP_PATH}" dist/*.whl
	rm -f "${APP_PATH}/.lock"
	dir="${APP_PATH}"
	# The venv was slimmed in the deps stage; these two act on it alone.
	REMOVE_PIP=0
	BOTOCORE_SERVICES=""
	;;
esac

# No -OO: that writes `.opt-2.pyc`, which only an interpreter started with -OO
# reads. python-distroless and most runtimes start without it, so the venv
# would ship bytecode nothing loads and recompile every import at startup.
#
# With sources removed, bytecode has to sit beside them (-b): an interpreter
# reads __pycache__ only for a module whose .py still exists, and imports a
# package left with nothing but __pycache__ as an empty namespace.
legacy=""
[[ "${REMOVE_PY_SOURCES}" == "1" ]] && legacy="-b"
"${PYTHON_BIN}" -m compileall -q -f ${legacy} "${dir}"

# Remove Python sources
if [[ "${REMOVE_PY_SOURCES}" == "1" ]]; then
	find "${dir}" -type f -name "*.py" -delete || true
fi

# Strip native libraries
if [[ "${STRIP_NATIVE}" == "1" ]]; then
	find "${dir}" -type f -name "*.so" -print0 |
		xargs -0 -r strip --strip-unneeded || true
fi

# Remove tests. Not __pycache__: that is where the bytecode compiled above lives.
if [[ "${REMOVE_TESTS}" == "1" ]]; then
	find "${dir}" -type d \( -name "tests" -o -name "test" \) \
		-prune -exec rm -rf {} + || true
fi

# Remove type hints
if [[ "${REMOVE_TYPE_HINTS}" == "1" ]]; then
	find "${dir}" -type f -name "*.pyi" -delete || true
fi

# Remove docs
if [[ "${REMOVE_DOCS}" == "1" ]]; then
	find "${dir}" -type d \( \
		-name "docs" -o \
		-name "doc" -o \
		-name "examples" -o \
		-name "example" \
		\) -prune -exec rm -rf {} + || true
fi

# Remove locales
if [[ "${REMOVE_LOCALES}" == "1" ]]; then
	find "${dir}" -type d \( \
		-name "locale" -o \
		-name "locales" -o \
		-name "i18n" \
		\) -prune -exec rm -rf {} + || true

	find "${dir}" -type f \( -name "*.mo" -o -name "*.po" \) -delete || true
fi

# Remove native debug stuff
if [[ "${REMOVE_C_EXT_DEBUG}" == "1" ]]; then
	find "${dir}" -type f \( \
		-name "*.debug" -o -name "*.pdb" -o -name "*.dSYM" \
		\) -delete || true
fi

# Remove static libraries
find "${dir}" -type f -name "*.a" -delete || true

# Remove build metadata
if [[ "${REMOVE_BUILD_METADATA}" == "1" ]]; then
	find "${dir}" -type d -name "*.dist-info" -prune -exec rm -rf {} + || true
	find "${dir}" -type d -name "*.egg-info" -prune -exec rm -rf {} + || true
fi

# Remove pip
if [[ "${REMOVE_PIP}" == "1" ]]; then
	"${PYTHON_BIN}" -m pip uninstall -y pip setuptools wheel || true
	rm -rf \
		"${VENV_PATH}"/lib/python*/site-packages/pip* \
		"${VENV_PATH}"/lib/python*/site-packages/setuptools* \
		"${VENV_PATH}"/lib/python*/site-packages/wheel* \
		"${VENV_PATH}"/bin/pip* || true
fi

# Optional botocore pruning:
# BOTOCORE_SERVICES="s3 sts"
if [[ -n "${BOTOCORE_SERVICES}" ]]; then
	bc_dir="$(find "${VENV_PATH}"/lib/python*/site-packages/botocore/data -maxdepth 0 -type d 2>/dev/null | head -n1 || true)"
	if [[ -n "${bc_dir}" ]]; then
		keep=" endpoints.json partitions.json sdk-default-configuration.json regions.json ${BOTOCORE_SERVICES} "
		cd "${bc_dir}"
		for x in *; do
			if [[ "${keep}" != *" ${x} "* ]]; then
				rm -rf "${x}"
			fi
		done
	fi
fi
