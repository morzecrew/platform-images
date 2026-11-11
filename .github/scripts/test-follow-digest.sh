#!/usr/bin/env bash
# Checks follow-digest.sh against a fixture repository, with a resolver that
# stands in for the registry and records what it was asked. See S-0001/D-23.
#
# Invoked as: test-follow-digest.sh
set -euo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SCRIPT="${HERE}/follow-digest.sh"
WORK="$(mktemp -d)"
trap 'rm -rf "${WORK}"' EXIT

OLD=sha256:$(printf 'a%.0s' {1..64})
NEW=sha256:$(printf 'b%.0s' {1..64})

fail() {
	echo "FAIL: $*" >&2
	exit 1
}

# Prints NEW for v1.1.0, something that is not a digest for v1.3.0, and fails
# for anything else, as a registry does for a tag not yet published.
cat >"${WORK}/resolve" <<EOF
#!/bin/sh
echo "\$1" >>"${WORK}/asked"
[ "\$1" = "example.org/demo:v1.3.0" ] && { echo "<html>rate limited</html>"; exit 0; }
[ "\$1" = "example.org/demo:v1.1.0" ] || exit 1
echo "${NEW}"
EOF
chmod +x "${WORK}/resolve"
export RESOLVE_DIGEST="${WORK}/resolve"

cd "${WORK}"
mkdir -p repo/images/demo repo/images/plain
cd repo
git init -q
git config user.email test@example.org
git config user.name test

pin() {
	cat >images/demo/Dockerfile <<EOF
ARG DEMO_VERSION=$1
ARG DEMO_IMAGE_DIGEST=$2
FROM example.org/demo:v\${DEMO_VERSION}@\${DEMO_IMAGE_DIGEST} AS upstream
EOF
	printf 'variable "DEMO_VERSION" {\n  default = "%s"\n}\n    DEMO_IMAGE_DIGEST = "%s"\n' "$1" "$2" >docker-bake.hcl
}

# An image pinned by tag alone has no digest to move and must be skipped.
# shellcheck disable=SC2016 # a literal ${...} for the Dockerfile
printf 'ARG PLAIN_VERSION=1\nFROM example.org/plain:${PLAIN_VERSION}\n' >images/plain/Dockerfile
pin 1.0.0 "${OLD}"
git add -A
git commit -qm base
base="$(git rev-parse HEAD)"

# Renovate's change: the version moves, the digest stays.
pin 1.1.0 "${OLD}"
git commit -qam bump

out="$(bash "${SCRIPT}" "${base}")" || fail "a moved version exited non-zero"
[ "${out}" = "example.org/demo:v1.1.0 ${NEW}" ] || fail "printed '${out}'"
grep -q "ARG DEMO_IMAGE_DIGEST=${NEW}" images/demo/Dockerfile || fail "the Dockerfile kept the old digest"
grep -q "DEMO_IMAGE_DIGEST = \"${NEW}\"" docker-bake.hcl || fail "the bake kept the old digest"
grep -q "${OLD}" docker-bake.hcl images/demo/Dockerfile && fail "the old digest survives"

# A second run finds the digest already moved.
out="$(bash "${SCRIPT}" "${base}")" || fail "a rerun exited non-zero"
[ -z "${out}" ] || fail "a rerun printed '${out}'"
git commit -qam follow

# A version the branch did not move is not resolved at all, so a tag upstream
# rebuilt never moves the pin on an unrelated pull request.
: >"${WORK}/asked"
out="$(bash "${SCRIPT}" HEAD)" || fail "an unmoved version exited non-zero"
[ -z "${out}" ] && [ ! -s "${WORK}/asked" ] || fail "an unmoved version was resolved: $(cat "${WORK}/asked")"

# A tag upstream has not published fails, and changes nothing.
pin 1.2.0 "${OLD}"
git commit -qam unpublished
if bash "${SCRIPT}" HEAD~1 2>"${WORK}/err"; then
	fail "an unpublished tag exited zero"
fi
grep -q "cannot resolve example.org/demo:v1.2.0" "${WORK}/err" || fail "unpublished: $(cat "${WORK}/err")"
git diff --quiet || fail "an unpublished tag changed the tree"

# Whatever the registry answers is written into two files only if it is a
# digest.
pin 1.3.0 "${OLD}"
git commit -qam garbled
if bash "${SCRIPT}" HEAD~1 2>"${WORK}/err"; then
	fail "an answer that is not a digest exited zero"
fi
grep -q "which is not an image digest" "${WORK}/err" || fail "garbled: $(cat "${WORK}/err")"
git diff --quiet || fail "an answer that is not a digest changed the tree"

echo "ok: follow-digest moves a digest only with its version, and only to a published one"
