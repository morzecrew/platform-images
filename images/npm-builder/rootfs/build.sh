#!/usr/bin/env bash
# Install, build, and hand a verified static bundle to /srv.
#
# RFC 0009 §5.2. The verification is the reason this script exists: a build that
# emits nothing currently produces a container that serves 404 for every path,
# diagnosed in a browser long after publish. Here it fails the build instead.
set -Eeuo pipefail

: "${APP_ROOT:=/app}"
: "${BUILD_OUTPUT_DIR:=dist}"
: "${APP_DIST:=/srv}"
: "${BUILD_SCRIPT:=build}"

die() {
	echo "build-js-app: $*" >&2
	exit 1
}

# What the failure message shows when the output directory is wrong. Naming the
# variable is not enough on its own -- the operator needs to see what the build
# *did* emit to know what to set it to (RFC 0009 decision 7).
emitted() {
	local found
	found=$(find "${APP_ROOT}" -maxdepth 1 -mindepth 1 -type d \
		-not -name node_modules -not -name '.*' -printf '%f ' 2>/dev/null || true)
	printf '%s' "${found:-<no directories>}"
}

cd "${APP_ROOT}"

[ -f package.json ] || die "no package.json in ${APP_ROOT}. Is the project copied in before this runs?"

# Decision 3 (LOCKED): installs use a frozen lockfile. `npm ci` requires one and
# refuses when it disagrees with package.json, which is exactly the guarantee
# the two projects running `npm install` today do not have. Checked explicitly
# so the failure names the cause rather than quoting npm's own wording, which
# has changed between majors.
[ -f package-lock.json ] || die "no package-lock.json in ${APP_ROOT}. This builder installs with 'npm ci', which requires a lockfile; 'npm install' is not used because it can silently resolve a different tree than the one committed."

npm ci
npm run "${BUILD_SCRIPT}"

# BUILD_OUTPUT_DIR is documented as relative to APP_ROOT. An absolute path is
# accepted rather than mangled into ${APP_ROOT}//abs, so the diagnostics below
# print something the operator can act on.
case "${BUILD_OUTPUT_DIR}" in
/*) out="${BUILD_OUTPUT_DIR}" ;;
*) out="${APP_ROOT}/${BUILD_OUTPUT_DIR}" ;;
esac

[ -d "${out}" ] ||
	die "BUILD_OUTPUT_DIR='${BUILD_OUTPUT_DIR}' resolved to '${out}', which does not exist. The build emitted these directories: $(emitted). Set BUILD_OUTPUT_DIR to whichever one your framework writes."

[ -n "$(ls -A "${out}" 2>/dev/null)" ] ||
	die "BUILD_OUTPUT_DIR='${BUILD_OUTPUT_DIR}' resolved to '${out}', which exists but is empty. The build script '${BUILD_SCRIPT}' exited 0 without emitting anything."

[ -f "${out}/index.html" ] ||
	die "BUILD_OUTPUT_DIR='${BUILD_OUTPUT_DIR}' resolved to '${out}', which has no index.html. It contains: $(ls -A "${out}" | head -20 | tr '\n' ' '). A static bundle without an index.html serves 404 for every path."

mkdir -p "${APP_DIST}"
# The trailing /. copies the directory's contents rather than the directory, so
# ${APP_DIST}/index.html holds regardless of what the framework named its
# output. Without it, `dist` would land as /srv/dist.
cp -a "${out}/." "${APP_DIST}/"

echo "build-js-app: ${BUILD_OUTPUT_DIR} -> ${APP_DIST} ($(find "${APP_DIST}" -type f | wc -l) files)"
