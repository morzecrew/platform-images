#!/usr/bin/env bash
# Checks arg-defaults.sh itself against a fixture: a bake file and a Dockerfile
# built in a temporary directory, one pair whose values agree and one that
# drifts. See S-0002/D-1.
#
# Invoked as: test-arg-defaults.sh
set -euo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SCRIPT="${HERE}/arg-defaults.sh"
WORK="$(mktemp -d)"
trap 'rm -rf "${WORK}"' EXIT

mkdir -p "${WORK}/images/demo"

# A default group, because `bake --print` with an explicit -f has no implicit
# one to fall back on and would fail with "failed to find target default".
cat > "${WORK}/bake.hcl" <<'HCL'
group "default" {
  targets = ["demo"]
}

target "demo" {
  context    = "./images/demo"
  dockerfile = "Dockerfile"
  args = {
    DEMO_VERSION  = "1.2.3"
    OTHER_VERSION = "9.9.9"
  }
}
HCL

fail() {
	echo "FAIL: $*" >&2
	exit 1
}

# A matching pair, quoted on the Dockerfile side to exercise the quoting. An
# ARG with no default and an ARG the target does not pass are both present, and
# neither may be compared -- the pair still has to exit 0.
cat > "${WORK}/images/demo/Dockerfile" <<'DF'
FROM scratch
ARG DEMO_VERSION="1.2.3"
ARG UNPASSED_VERSION=0.0.1
ARG NO_DEFAULT
DF

if ! output="$( (cd "${WORK}" && bash "${SCRIPT}" -f bake.hcl) 2>&1)"; then
	fail "a matching pair exited non-zero:
${output}"
fi

# The same pair, drifted, unquoted this time, and in the lowercase spelling
# Docker accepts as the same instruction.
cat > "${WORK}/images/demo/Dockerfile" <<'DF'
FROM scratch
arg DEMO_VERSION=1.2.2
DF

status=0
output="$( (cd "${WORK}" && bash "${SCRIPT}" -f bake.hcl) 2>&1)" || status=$?
[ "${status}" -eq 1 ] || fail "a drift exited ${status}, expected 1:
${output}"

case "${output}" in
*demo*) : ;;
*) fail "the drift line does not name the target:
${output}" ;;
esac
case "${output}" in
*DEMO_VERSION*) : ;;
*) fail "the drift line does not name the argument:
${output}" ;;
esac
case "${output}" in
*1.2.2*1.2.3* | *1.2.3*1.2.2*) : ;;
*) fail "the drift line does not give both values:
${output}" ;;
esac

echo "ok: arg-defaults accepts a matching default and rejects a drifted one"