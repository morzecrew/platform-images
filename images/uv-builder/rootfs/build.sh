#!/usr/bin/env bash
set -Eeuo pipefail

: "${APP_ROOT:=/app}"
: "${VENV_PATH:=/opt/venv}"
: "${UV_GROUPS:=--no-group dev}"
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

uv sync --frozen ${UV_GROUPS}
uv build --wheel

uv pip install --python "${PYTHON_BIN}" --no-deps dist/*.whl
"${PYTHON_BIN}" -OO -m compileall -q -f "${VENV_PATH}"

# Remove Python sources
if [[ "${REMOVE_PY_SOURCES}" == "1" ]]; then
	find "${VENV_PATH}" -type f -name "*.py" -delete || true
fi

# Strip native libraries
if [[ "${STRIP_NATIVE}" == "1" ]]; then
	find "${VENV_PATH}" -type f -name "*.so" -print0 |
		xargs -0 -r strip --strip-unneeded || true
fi

# Remove tests
if [[ "${REMOVE_TESTS}" == "1" ]]; then
	find "${VENV_PATH}" -type d \( -name "tests" -o -name "test" -o -name "__pycache__" \) \
		-prune -exec rm -rf {} + || true
fi

# Remove type hints
if [[ "${REMOVE_TYPE_HINTS}" == "1" ]]; then
	find "${VENV_PATH}" -type f -name "*.pyi" -delete || true
fi

# Remove docs
if [[ "${REMOVE_DOCS}" == "1" ]]; then
	find "${VENV_PATH}" -type d \( \
		-name "docs" -o \
		-name "doc" -o \
		-name "examples" -o \
		-name "example" \
		\) -prune -exec rm -rf {} + || true
fi

# Remove locales
if [[ "${REMOVE_LOCALES}" == "1" ]]; then
	find "${VENV_PATH}" -type d \( \
		-name "locale" -o \
		-name "locales" -o \
		-name "i18n" \
		\) -prune -exec rm -rf {} + || true

	find "${VENV_PATH}" -type f \( -name "*.mo" -o -name "*.po" \) -delete || true
fi

# Remove native debug stuff
if [[ "${REMOVE_C_EXT_DEBUG}" == "1" ]]; then
	find "${VENV_PATH}" -type f \( \
		-name "*.debug" -o -name "*.pdb" -o -name "*.dSYM" \
		\) -delete || true
fi

# Remove static libraries
find "${VENV_PATH}" -type f -name "*.a" -delete || true

# Remove build metadata
if [[ "${REMOVE_BUILD_METADATA}" == "1" ]]; then
	find "${VENV_PATH}" -type d -name "*.dist-info" -prune -exec rm -rf {} + || true
	find "${VENV_PATH}" -type d -name "*.egg-info" -prune -exec rm -rf {} + || true
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
