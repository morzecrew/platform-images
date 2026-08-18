#!/usr/bin/env bash
# RFC 0009 §6's battery: what build-js-app actually does.
#
# This cannot live in smoke.sh, which receives one built image reference and is
# meant to be cheap. Every assertion here needs a fixture project and a real
# build, several need a build that must *fail*, and one needs a second image to
# serve the result. Same split as images/postgres/test-extensions.sh.
#
# Rootless Podman throughout, like every other test in this repo (RFC 0002
# §5.5). An earlier revision used `docker buildx` on the belief that
# `--mount=type=cache` was BuildKit-only; Podman supports it, and the buildx
# route was actively wrong here -- CI's buildx builder uses the docker-container
# driver, which cannot resolve a locally built image in `FROM` and tried to pull
# `localhost/npm-builder:scratch` from a registry on port 80.
set -euo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ENGINE="${ENGINE:-podman}"
# Fixed, and deliberately not overridable. This harness *builds* the image it
# tests, so an override would name an image that gets overwritten and then
# deleted on cleanup -- pointing it at a real tag would silently destroy the
# local copy of a published image.
BUILDER="localhost/npm-builder:scratch"
CADDY="${CADDY_REF:-ghcr.io/morzecrew/caddy:2.11.4}"
WORK="$(mktemp -d)"
CTR="njs-test-$$"
FIXTURE="localhost/njs-fixture:$$"
pass=0

cleanup() {
	"${ENGINE}" rm -f "${CTR}" >/dev/null 2>&1 || true
	"${ENGINE}" rmi -f "${FIXTURE}" >/dev/null 2>&1 || true
	"${ENGINE}" rmi -f "${BUILDER}" >/dev/null 2>&1 || true
	rm -rf "${WORK}"
}
trap cleanup EXIT

ok() { echo "  ok: $*"; pass=$((pass + 1)); }
die() { echo "FAIL: $*" >&2; exit 1; }

# --- fixtures --------------------------------------------------------------
#
# A fixture is a package.json whose `build` script is whatever the case under
# test needs, plus a lockfile. Most cases have no dependencies at all, so
# `npm ci` touches the network for nothing and the whole build is a second or
# two. The cache case is the exception and says so.

lockfile_empty() {
	cat >"$1/package-lock.json" <<-JSON
		{
		  "name": "fixture",
		  "version": "1.0.0",
		  "lockfileVersion": 3,
		  "requires": true,
		  "packages": { "": { "name": "fixture", "version": "1.0.0" } }
		}
	JSON
}

# fixture <name> <build-script-json>
fixture() {
	local dir="${WORK}/$1"
	mkdir -p "${dir}"
	cat >"${dir}/package.json" <<-JSON
		{
		  "name": "fixture",
		  "version": "1.0.0",
		  "private": true,
		  "scripts": { "build": $2 }
		}
	JSON
	lockfile_empty "${dir}"
	cat >"${dir}/Dockerfile" <<-DOCKER
		FROM ${BUILDER}
		ARG BUILD_OUTPUT_DIR
		ENV BUILD_OUTPUT_DIR=\${BUILD_OUTPUT_DIR:-dist}
		COPY . .
		RUN build-js-app
	DOCKER
	printf '%s' "${dir}"
}

# expect_build_fails <label> <dir> <needle> [build args...]
expect_build_fails() {
	local label="$1" dir="$2" needle="$3"
	shift 3
	local out
	if out=$("${ENGINE}" build "$@" -t "${FIXTURE}" "${dir}" 2>&1); then
		echo "${out}" | tail -5
		die "${label}: the build succeeded, but it must fail"
	fi
	case "${out}" in
	*"${needle}"*) ok "${label}" ;;
	*)
		echo "${out}" | tail -15
		die "${label}: failed, but without '${needle}' in the output"
		;;
	esac
}

echo "=== building the builder ==="
"${ENGINE}" build -t "${BUILDER}" "${HERE}" >/dev/null ||
	die "the builder image itself did not build"
echo "built ${BUILDER}"

echo
echo "=== 1. a fixture project builds and /srv/index.html exists ==="
d=$(fixture happy '"mkdir -p dist && echo ok > dist/index.html"')
"${ENGINE}" build -t "${FIXTURE}" "${d}" >/dev/null ||
	die "the happy path did not build"
got=$("${ENGINE}" run --rm "${FIXTURE}" cat /srv/index.html | tr -d '\r\n')
[ "${got}" = "ok" ] || die "/srv/index.html is '${got}', expected 'ok'"
ok "assets land in /srv"

echo
echo "=== 2. a build emitting nothing fails (§6: must never be skipped) ==="
# The directory exists and is empty -- the case a `-d` check alone would pass.
d=$(fixture empty '"mkdir -p dist"')
expect_build_fails "empty output dir refused" "${d}" "which exists but is empty"
# Decision 7 requires the message to name the variable and the resolved path.
out=$("${ENGINE}" build -t "${FIXTURE}" "${d}" 2>&1 || true)
case "${out}" in
*"BUILD_OUTPUT_DIR='dist'"*"/app/dist"*) ok "the refusal names the variable and the path" ;;
*) die "the refusal does not name BUILD_OUTPUT_DIR and the resolved path (decision 7)" ;;
esac

echo
echo "=== 3. output with no index.html fails ==="
d=$(fixture noindex '"mkdir -p dist && echo x > dist/main.js"')
expect_build_fails "missing index.html refused" "${d}" "has no index.html"

echo
echo "=== 4. a missing output directory names what was emitted instead ==="
# The real operator error: the framework wrote `out`, the default looked in
# `dist`. Useless unless the message says what it found.
d=$(fixture wrongdir '"mkdir -p out && echo ok > out/index.html"')
expect_build_fails "wrong output dir refused" "${d}" "The build emitted these directories: out"

echo
echo "=== 5. BUILD_OUTPUT_DIR=out and =build both work (the three conventions) ==="
for conv in out build; do
	d=$(fixture "conv-${conv}" "\"mkdir -p ${conv} && echo ${conv} > ${conv}/index.html\"")
	"${ENGINE}" build --build-arg "BUILD_OUTPUT_DIR=${conv}" -t "${FIXTURE}" "${d}" >/dev/null ||
		die "BUILD_OUTPUT_DIR=${conv} did not build"
	got=$("${ENGINE}" run --rm "${FIXTURE}" cat /srv/index.html | tr -d '\r\n')
	[ "${got}" = "${conv}" ] || die "BUILD_OUTPUT_DIR=${conv} served '${got}'"
	ok "BUILD_OUTPUT_DIR=${conv}"
done

echo
echo "=== 6. no lockfile is refused (decision 3) ==="
d=$(fixture nolock '"mkdir -p dist && echo ok > dist/index.html"')
rm -f "${d}/package-lock.json"
expect_build_fails "missing lockfile refused" "${d}" "requires a lockfile"

echo
echo "=== 7. a lockfile disagreeing with package.json fails (decision 3) ==="
# The defect two projects ship today: `npm install` would resolve a fresh tree
# and carry on. `npm ci` must refuse instead of silently installing something
# the lockfile never described.
d=$(fixture desync '"mkdir -p dist && echo ok > dist/index.html"')
python3 - "${d}/package.json" <<'PY'
import json,sys
p=sys.argv[1]; d=json.load(open(p))
d["dependencies"]={"ms":"^2.1.3"}          # declared...
json.dump(d,open(p,"w"),indent=2)          # ...but absent from the lockfile
PY
expect_build_fails "desynced lockfile refused" "${d}" "npm ci"

echo
echo "=== 8. the documented cache mount is genuinely reused ==="
# The only case with a real dependency, because an empty cache makes the
# assertion vacuous. Reuse is asserted by making the second build *offline*:
# if the mount did not persist the store, npm cannot reach the registry and
# fails. That is binary, where timing a build is not.
d="${WORK}/cache"
mkdir -p "${d}"
cat >"${d}/package.json" <<'JSON'
{
  "name": "fixture", "version": "1.0.0", "private": true,
  "dependencies": { "ms": "2.1.3" },
  "scripts": { "build": "mkdir -p dist && echo ok > dist/index.html" }
}
JSON
# Generated rather than hand-written: a lockfile carries integrity hashes, and
# one invented here would be a hash nobody verified.
"${ENGINE}" run --rm -v "${d}:/w:Z" -w /w "${BUILDER}" \
	npm install --package-lock-only --no-audit --no-fund >/dev/null 2>&1 ||
	die "could not generate the fixture lockfile"
[ -f "${d}/package-lock.json" ] || die "no lockfile was generated"

cat >"${d}/Dockerfile" <<DOCKER
FROM ${BUILDER}
ARG OFFLINE=false
ENV npm_config_offline=\${OFFLINE}
COPY . .
RUN --mount=type=cache,target=/cache,sharing=locked build-js-app
DOCKER

# --no-cache so the RUN really re-executes; the cache *mount* is independent of
# the layer cache and persists across both builds, which is the thing under test.
"${ENGINE}" build --no-cache -t "${FIXTURE}" "${d}" >/dev/null ||
	die "the cache-warming build failed"
ok "first build populates /cache"

if out=$("${ENGINE}" build --no-cache --build-arg OFFLINE=true -t "${FIXTURE}" "${d}" 2>&1); then
	ok "second build installs offline from the mounted cache"
else
	echo "${out}" | tail -15
	die "the offline build failed -- the cache mount did not persist the npm store"
fi

echo
echo "=== 9. a stale output directory in the context is refused ==="
# The subtler half of decision 2: a project that commits its output directory,
# or copies one in with `COPY . .`, hands build-js-app a complete-looking bundle
# the build never touched. Every other check here passes on last release's
# assets. Reported by review on PR #37 and reproduced before fixing.
d=$(fixture stale '"true"')
mkdir -p "${d}/dist"
echo "STALE-FROM-LAST-YEAR" >"${d}/dist/index.html"
expect_build_fails "stale output refused" "${d}" "is older than this build"

echo
echo "=== 10. an output directory overlapping APP_DIST is refused ==="
d=$(fixture overlap '"mkdir -p /srv && echo ok > /srv/index.html"')
expect_build_fails "overlapping output refused" "${d}" "which is APP_DIST" \
	--build-arg BUILD_OUTPUT_DIR=/srv

echo
echo "=== 11. the runtime handoff: caddy serves it, deep paths get index.html ==="
# Not a skip. The package is public and anonymously pullable, so a failure here
# is an infrastructure problem, not an optional test -- and a skip would leave
# the battery green with §6's handoff assertion never run, which is exactly the
# silent gap this image exists to remove.
"${ENGINE}" pull -q "${CADDY}" >/dev/null 2>&1 ||
	die "could not pull ${CADDY}; the handoff assertion cannot be skipped (set CADDY_REF to override)"
if true; then
	d="${WORK}/handoff"
	mkdir -p "${d}"
	cat >"${d}/package.json" <<'JSON'
{
  "name": "fixture", "version": "1.0.0", "private": true,
  "scripts": { "build": "mkdir -p dist && echo spa-root > dist/index.html" }
}
JSON
	lockfile_empty "${d}"
	printf 'import spa\n' >"${d}/spa.caddy"
	cat >"${d}/Dockerfile" <<DOCKER
FROM ${BUILDER} AS build
COPY . .
RUN build-js-app

FROM ${CADDY}
COPY --from=build /srv /srv
COPY spa.caddy /etc/caddy/config.d/
DOCKER
	"${ENGINE}" build -t "${FIXTURE}" "${d}" >/dev/null ||
		die "the two-stage handoff did not build"
	"${ENGINE}" rm -f "${CTR}" >/dev/null 2>&1 || true
	"${ENGINE}" run -d --name "${CTR}" -p 18080:8080 "${FIXTURE}" >/dev/null
	for _ in $(seq 1 40); do
		curl -fsS "http://127.0.0.1:18080/__platform_healthz" >/dev/null 2>&1 && break
		sleep 0.5
	done
	root=$(curl -fsS "http://127.0.0.1:18080/" | tr -d '\r\n')
	[ "${root}" = "spa-root" ] || die "/ served '${root}', expected the built index.html"
	ok "/ serves the built bundle"
	# The whole point of `import spa`: a client-side route that is not a file
	# must return index.html, not 404.
	deep=$(curl -fsS "http://127.0.0.1:18080/settings/profile/42" | tr -d '\r\n') ||
		die "a deep path returned a non-200 -- try_files is not in effect"
	[ "${deep}" = "spa-root" ] || die "a deep path served '${deep}', expected index.html"
	ok "a deep path falls back to index.html rather than 404"
	"${ENGINE}" rm -f "${CTR}" >/dev/null 2>&1 || true
fi

echo
echo "PASS: build-js-app (${pass} assertions)"
