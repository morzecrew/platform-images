#!/usr/bin/env bash
# RFC 0009 §6's battery: what build-js-app actually does.
#
# This cannot live in smoke.sh, which receives one built image reference and is
# meant to be cheap. Every assertion here needs a fixture project and a real
# build, several need a build that must *fail*, and one needs a second image to
# serve the result. Same split as images/postgres/test-extensions.sh.
#
# docker rather than podman throughout, unlike every other test in this repo:
# `--mount=type=cache` is a BuildKit feature and the cache assertion is the one
# that cannot be expressed without it. The rootless assertions RFC 0002 §5.5
# cares about belong to the runtime images and are made in their own smoke
# tests; nothing here depends on rootless behaviour.
set -euo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
BUILDER="${BUILDER_TAG:-localhost/npm-builder:scratch}"
CADDY="${CADDY_REF:-ghcr.io/morzecrew/caddy:2.11.4}"
WORK="$(mktemp -d)"
CTR="njs-test-$$"
pass=0

cleanup() {
	docker rm -f "${CTR}" >/dev/null 2>&1 || true
	docker rmi -f "${BUILDER}" >/dev/null 2>&1 || true
	docker rmi -f "localhost/njs-fixture:$$" >/dev/null 2>&1 || true
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

# fixture <name> <build-script>
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

# expect_build_fails <label> <dir> <needle> [--build-arg ...]
expect_build_fails() {
	local label="$1" dir="$2" needle="$3"
	shift 3
	local out
	if out=$(docker buildx build --output=type=cacheonly "$@" "${dir}" 2>&1); then
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
docker buildx build --load -t "${BUILDER}" "${HERE}" >/dev/null ||
	die "the builder image itself did not build"
echo "built ${BUILDER}"

echo
echo "=== 1. a fixture project builds and /srv/index.html exists ==="
d=$(fixture happy '"mkdir -p dist && echo ok > dist/index.html"')
docker buildx build --load -t "localhost/njs-fixture:$$" "${d}" >/dev/null ||
	die "the happy path did not build"
got=$(docker run --rm "localhost/njs-fixture:$$" cat /srv/index.html | tr -d '\r\n')
[ "${got}" = "ok" ] || die "/srv/index.html is '${got}', expected 'ok'"
ok "assets land in /srv"

echo
echo "=== 2. a build emitting nothing fails (§6: must never be skipped) ==="
# The directory exists and is empty -- the case a `-d` check alone would pass.
d=$(fixture empty '"mkdir -p dist"')
expect_build_fails "empty output dir refused" "${d}" "which exists but is empty"
# Decision 7 requires the message to name the variable and the resolved path.
out=$(docker buildx build --output=type=cacheonly "${d}" 2>&1 || true)
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
	docker buildx build --load -t "localhost/njs-fixture:$$" \
		--build-arg "BUILD_OUTPUT_DIR=${conv}" "${d}" >/dev/null ||
		die "BUILD_OUTPUT_DIR=${conv} did not build"
	got=$(docker run --rm "localhost/njs-fixture:$$" cat /srv/index.html | tr -d '\r\n')
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
docker run --rm -v "${d}:/w" -w /w "${BUILDER}" \
	npm install --package-lock-only --no-audit --no-fund >/dev/null 2>&1 ||
	die "could not generate the fixture lockfile"
[ -f "${d}/package-lock.json" ] || die "no lockfile was generated"

cat >"${d}/Dockerfile" <<DOCKER
FROM ${BUILDER}
ARG BUST
ARG OFFLINE=false
ENV npm_config_offline=\${OFFLINE}
COPY . .
RUN --mount=type=cache,target=/cache,sharing=locked build-js-app
DOCKER

docker buildx build --output=type=cacheonly --build-arg BUST=1 "${d}" >/dev/null ||
	die "the cache-warming build failed"
ok "first build populates /cache"

if out=$(docker buildx build --output=type=cacheonly \
	--build-arg BUST=2 --build-arg OFFLINE=true "${d}" 2>&1); then
	ok "second build installs offline from the mounted cache"
else
	echo "${out}" | tail -15
	die "the offline build failed -- the cache mount did not persist the npm store"
fi

echo
echo "=== 9. the runtime handoff: caddy serves it, deep paths get index.html ==="
if ! docker pull -q "${CADDY}" >/dev/null 2>&1; then
	echo "  SKIP: ${CADDY} could not be pulled"
else
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
	docker buildx build --load -t "localhost/njs-fixture:$$" "${d}" >/dev/null ||
		die "the two-stage handoff did not build"
	docker rm -f "${CTR}" >/dev/null 2>&1 || true
	docker run -d --name "${CTR}" -p 18080:8080 "localhost/njs-fixture:$$" >/dev/null
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
	docker rm -f "${CTR}" >/dev/null 2>&1 || true
fi

echo
echo "PASS: build-js-app (${pass} assertions)"
