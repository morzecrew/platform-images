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
	# Sorted so the message is the same on every run -- find walks the
	# filesystem in whatever order it gets, and a diagnostic that reshuffles
	# between builds is one nobody trusts.
	found=$(find "${APP_ROOT}" -maxdepth 1 -mindepth 1 -type d \
		-not -name node_modules -not -name '.*' -printf '%f\n' 2>/dev/null |
		sort | tr '\n' ' ' || true)
	found="${found% }"
	printf '%s' "${found:-<none>}"
}

canon() { readlink -f -- "$1" 2>/dev/null || printf '%s' "$1"; }

cd "${APP_ROOT}"

[ -f package.json ] || die "no package.json in ${APP_ROOT}. Is the project copied in before this runs?"

# Decision 3 (LOCKED): installs use a frozen lockfile. `npm ci` requires one and
# refuses when it disagrees with package.json, which is exactly the guarantee
# the two projects running `npm install` today do not have. Checked explicitly
# so the failure names the cause rather than quoting npm's own wording, which
# has changed between majors.
[ -f package-lock.json ] || die "no package-lock.json in ${APP_ROOT}. This builder installs with 'npm ci', which requires a lockfile; 'npm install' is not used because it can silently resolve a different tree than the one committed."

# BUILD_OUTPUT_DIR is documented as relative to APP_ROOT. An absolute path is
# accepted rather than mangled into ${APP_ROOT}//abs, so the diagnostics below
# print something the operator can act on.
case "${BUILD_OUTPUT_DIR}" in
/*) out="${BUILD_OUTPUT_DIR}" ;;
*) out="${APP_ROOT}/${BUILD_OUTPUT_DIR}" ;;
esac

# Resolved before the install, not after: an overlap is a configuration error
# that no amount of building will fix, and finding it first saves the operator
# a full `npm ci` before the refusal.
out_c="$(canon "${out}")"
dist_c="$(canon "${APP_DIST}")"
case "${out_c}" in
"${dist_c}" | "${dist_c}"/*)
	die "BUILD_OUTPUT_DIR='${BUILD_OUTPUT_DIR}' resolves to '${out_c}', which is APP_DIST ('${APP_DIST}') or inside it. The build output and the destination would be the same tree, so copying it would be copying a directory into itself. Point BUILD_OUTPUT_DIR at the directory your framework writes inside the project."
	;;
esac
case "${dist_c}" in
"${out_c}"/*)
	die "BUILD_OUTPUT_DIR='${BUILD_OUTPUT_DIR}' resolves to '${out_c}', which contains APP_DIST ('${APP_DIST}'). Copying it into APP_DIST would copy the destination into itself."
	;;
esac

# A reference point for "did this build actually write the bundle?". A project
# that commits its output directory, or copies one in with `COPY . .`, hands
# build-js-app a complete-looking bundle that the build never touched -- so
# every check below would pass on last release's assets. Compared by mtime
# rather than by clearing the directory first, because deleting a path derived
# from a caller-supplied variable is a much worse failure than the one it
# prevents.
STARTED_AT="$(mktemp)"
trap 'rm -f "${STARTED_AT}"' EXIT

npm ci
npm run "${BUILD_SCRIPT}"

[ -d "${out}" ] ||
	die "BUILD_OUTPUT_DIR='${BUILD_OUTPUT_DIR}' resolved to '${out}', which does not exist. The build emitted these directories: $(emitted). Set BUILD_OUTPUT_DIR to whichever one your framework writes."

[ -n "$(ls -A "${out}" 2>/dev/null)" ] ||
	die "BUILD_OUTPUT_DIR='${BUILD_OUTPUT_DIR}' resolved to '${out}', which exists but is empty. The build script '${BUILD_SCRIPT}' exited 0 without emitting anything."

[ -f "${out}/index.html" ] ||
	die "BUILD_OUTPUT_DIR='${BUILD_OUTPUT_DIR}' resolved to '${out}', which has no index.html. It contains: $(ls -A "${out}" | head -20 | tr '\n' ' '). A static bundle without an index.html serves 404 for every path."

[ "${out}/index.html" -nt "${STARTED_AT}" ] ||
	die "'${out}/index.html' is older than this build, so the build script '${BUILD_SCRIPT}' did not write it. The directory was already in the build context -- committed to the repository, or copied in by 'COPY . .' -- and shipping it would publish whatever it held rather than what this build produced. Add '${BUILD_OUTPUT_DIR}' to .dockerignore, or fix the build script so it regenerates the bundle."

mkdir -p "${APP_DIST}"
# The trailing /. copies the directory's contents rather than the directory, so
# ${APP_DIST}/index.html holds regardless of what the framework named its
# output. Without it, `dist` would land as /srv/dist.
cp -a "${out}/." "${APP_DIST}/"

echo "build-js-app: ${BUILD_OUTPUT_DIR} -> ${APP_DIST} ($(find "${APP_DIST}" -type f | wc -l) files)"
