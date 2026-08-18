#!/usr/bin/env bash
# Smoke test for a build-stage image. See RFC 0002 §5.5.
#
# RFC 0002 §5.5 prescribes running "their entrypoint helper with a --help
# equivalent". build-js-app has no such flag -- it is a straight-line build
# script that would attempt a real install against a project that is not there.
# So this asserts what a build stage can be wrong about on its own: the
# toolchain runs, the helper is present and executable, it is valid shell, and
# the two environment footguns the Dockerfile deliberately leaves unset are
# still unset.
#
# What build-js-app actually *does* is verified by test-build-js-app.sh, which
# needs fixture projects and several builds and so cannot run from one image
# reference. RFC 0009 §6 is that file's contract, not this one's.
set -euo pipefail
IMAGE="${1:?usage: smoke.sh <image-ref>}"
ENGINE="${ENGINE:-podman}"

"${ENGINE}" run --rm "${IMAGE}" node --version >/dev/null ||
	{ echo "FAIL: node missing"; exit 1; }
echo "node: ok"

"${ENGINE}" run --rm "${IMAGE}" npm --version >/dev/null ||
	{ echo "FAIL: npm missing"; exit 1; }
echo "npm: ok"

# The tag is the only thing telling a consumer which Node major they pin, and
# nothing else in the image restates it. If BUILDER_NODE_VERSION and the base
# image ever disagree -- a bake edit that misses the Dockerfile default, a
# hand-built image -- every consumer pins a major they are not getting, with no
# error anywhere. Wave 6 shipped exactly this divergence in the postgres
# extensions label (D-040); it is cheap to pin and invisible when it breaks.
want="$("${ENGINE}" image inspect "${IMAGE}" \
	--format '{{ index .Config.Labels "org.opencontainers.image.version" }}' 2>/dev/null | tr -d '\r')"
case "${want}" in
'' | '<no value>')
	# A plain `docker build` carries no bake labels; fall back to the tag.
	want="${IMAGE##*:}"
	case "${want}" in
	*[!0-9]* | '') want="" ;;
	esac
	;;
esac
if [ -n "${want}" ]; then
	got="$("${ENGINE}" run --rm "${IMAGE}" node --version | tr -d '\r')"
	case "${got}" in
	"v${want}."*) echo "node major: ${got} matches the declared ${want}" ;;
	*)
		echo "FAIL: image declares Node ${want} but ships ${got}"
		exit 1
		;;
	esac
else
	echo "node major: SKIP (image declares no version label and the ref has no numeric tag)"
fi

"${ENGINE}" run --rm "${IMAGE}" test -x /usr/local/bin/build-js-app ||
	{ echo "FAIL: build-js-app missing or not executable"; exit 1; }
echo "build-js-app: present and executable"

# A syntax error in the helper would otherwise surface only in a consumer's
# build, long after this image was published.
"${ENGINE}" run --rm "${IMAGE}" bash -n /usr/local/bin/build-js-app ||
	{ echo "FAIL: build-js-app is not valid bash"; exit 1; }
echo "build-js-app: parses"

# The npm store path is the half of the cache contract this image can keep
# (decision 12). A consumer mounts a cache over it; if the path moves, every
# consumer's mount silently stops matching and the cache goes cold without any
# error -- the exact failure mode a smoke test should catch.
got="$("${ENGINE}" run --rm "${IMAGE}" npm config get cache | tr -d '\r')"
[ "${got}" = "/cache" ] ||
	{ echo "FAIL: npm cache path is '${got}', expected /cache -- consumer cache mounts target /cache"; exit 1; }
echo "npm cache: /cache"

# NODE_ENV=production would make `npm ci` skip the devDependencies that hold
# every one of these projects' build tools; CI=true makes react-scripts treat
# warnings as errors. Both look like build-stage hygiene and both break real
# builds, so their absence is asserted rather than left to a comment.
for var in NODE_ENV CI; do
	val="$("${ENGINE}" run --rm "${IMAGE}" printenv "${var}" 2>/dev/null || true)"
	[ -z "${val}" ] ||
		{ echo "FAIL: ${var} is set to '${val}' in the image; it must be the project's choice"; exit 1; }
done
echo "NODE_ENV, CI: unset, as intended"

echo "PASS: npm-builder"
