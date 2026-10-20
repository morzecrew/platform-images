#!/usr/bin/env bash
# torve's `bake-smoke` gate (`.torve/gates.yaml`): the "Bake and smoke" job of
# `.github/workflows/bake.yaml`, over the targets a candidate touches, on the
# task's own nested Docker daemon. Each target is built once and its smoke test
# runs the image that build produced, as in CI.
#
#   bash .torve/gates/bake-smoke.sh <base>
#
# Where it differs from CI, on purpose:
# - One platform, the host's, on the nested daemon's default `docker` driver.
#   That driver stores the image where `docker run` finds it and refuses
#   attestations, so the gate turns `_attested`'s off. CI still judges the
#   attested build on both platforms.
# - ENGINE=docker: the smoke scripts default to rootless Podman, and the
#   sandbox's engine is the nested daemon.
# - TMPDIR inside the checkout. The daemon runs in a side container that
#   shares the checkout's mount and not the sandbox's /tmp, so a bind mount
#   from a `mktemp` directory under /tmp would reach the container empty.
set -euo pipefail

base="${1:?usage: bake-smoke.sh <base>}"

plan="$(docker buildx bake --print 2>/dev/null)"
# Against the tree, not HEAD, with untracked files: a candidate run by hand
# need not have committed what it changed.
changed="$(
	git diff --name-only "${base}"
	git ls-files --others --exclude-standard
)"

# A target is touched when a changed path lies under its context or under one
# of its local named contexts. A change to any definition file bake loads
# without `-f`, overrides included, touches every target.
targets="$(
	PLAN="${plan}" CHANGED="${changed}" python3 -c '
import json, os, posixpath

plan = json.loads(os.environ["PLAN"])["target"]
changed = [path for path in os.environ["CHANGED"].splitlines() if path]

def local(ref):
    return "://" not in ref and not ref.startswith("target:")

def under(path, directory):
    return path == directory or path.startswith(directory.rstrip("/") + "/")

# The default file lookup of buildx, which the bare docker buildx bake in CI uses.
definitions = {
    "compose.yaml", "compose.yml", "docker-compose.yml", "docker-compose.yaml",
    "docker-bake.json", "docker-bake.hcl",
    "compose.override.yaml", "compose.override.yml",
    "docker-compose.override.yml", "docker-compose.override.yaml",
    "docker-bake.override.json", "docker-bake.override.hcl",
}
everything = any(path in definitions for path in changed)

for name, target in sorted(plan.items()):
    roots = [target["context"], *(ref for ref in (target.get("contexts") or {}).values() if local(ref))]
    roots = [posixpath.normpath(root) for root in roots]

    if everything or any(under(path, root) for root in roots for path in changed):
        print(name)
'
)"

if [ -z "${targets}" ]; then
	echo "no bake target is touched"
	exit 0
fi

export ENGINE=docker
export TMPDIR="${PWD}/.torve/tmp/bake-smoke"
mkdir -p "${TMPDIR}"

failed=0

for name in ${targets}; do
	context="$(echo "${plan}" | python3 -c "import json,sys; print(json.load(sys.stdin)['target']['${name}']['context'])")"
	ref="$(echo "${plan}" | python3 -c "import json,sys; print(json.load(sys.stdin)['target']['${name}']['tags'][0])")"
	script="${context}/smoke.sh"

	echo "== build ${name}"
	docker buildx bake --provenance=false --sbom=false "${name}"

	if [ ! -f "${script}" ]; then
		echo "FAIL: ${name} has no ${script}"
		failed=1
		continue
	fi

	echo "== smoke ${name} (${ref})"

	if bash "${script}" "${ref}"; then
		echo "ok: ${name}"
	else
		echo "FAIL: smoke ${name} (${ref})"
		failed=1
	fi
done

exit "${failed}"
