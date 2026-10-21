#!/usr/bin/env bash
# Compares each bake target's Dockerfile ARG defaults against the values the
# bake passes for those arguments. See S-0002/D-1.
#
# The drift this catches: a Renovate pull request moves a version in
# docker-bake.hcl and leaves the Dockerfile's copy of the same default behind,
# so a `docker build` outside the bake silently ships the old version.
#
# A target is compared only when its name is the basename of its own context
# directory under images/. A variant target sharing a directory -- postgres-
# pgvector over images/postgres -- passes its own values on purpose and is not
# compared.
#
# Invoked as: arg-defaults.sh [-f <bake-file>]...
# Every -f is passed through to docker buildx bake, so a test can point this at
# a fixture instead of docker-bake.hcl.
set -euo pipefail

usage() {
	echo "usage: arg-defaults.sh [-f <bake-file>]..." >&2
}

bake_opts=()
# A bake file's target paths resolve next to that file: the working directory
# for the repository, which is not where a fixture lives.
bake_dir="$(pwd)"

while [ "$#" -gt 0 ]; do
	case "$1" in
	-f)
		if [ "$#" -lt 2 ]; then
			usage
			exit 2
		fi
		bake_opts+=(-f "$2")
		bake_dir="$(cd "$(dirname "$2")" && pwd)"
		shift 2
		;;
	-h | --help)
		usage
		exit 0
		;;
	*)
		echo "arg-defaults: unknown argument: $1" >&2
		usage
		exit 2
		;;
	esac
done

if ! plan="$(docker buildx bake "${bake_opts[@]}" --print)"; then
	echo "arg-defaults: docker buildx bake --print failed" >&2
	exit 2
fi

ARG_DEFAULTS_PLAN="$plan" ARG_DEFAULTS_BAKE_DIR="$bake_dir" python3 - <<'PY'
import json
import os
import re
import sys

plan = json.loads(os.environ["ARG_DEFAULTS_PLAN"])
bake_dir = os.environ["ARG_DEFAULTS_BAKE_DIR"]

# `ARG NAME=value`, the value taken verbatim bar one pair of surrounding quotes.
# An ARG without `=` has no default and never matches.
ARG_LINE = re.compile(r"\s*ARG\s+([A-Za-z_][A-Za-z0-9_]*)=(.*)$")

drifts = []
for name, target in sorted(plan.get("target", {}).items()):
    norm = os.path.normpath(target.get("context") or "")
    # Only a target named after its own directory directly under images/.
    if os.path.basename(norm) != name:
        continue
    if os.path.basename(os.path.dirname(norm)) != "images":
        continue

    dockerfile_name = target.get("dockerfile") or "Dockerfile"
    dockerfile = os.path.join(bake_dir, norm, dockerfile_name)
    shown = os.path.join(norm, dockerfile_name)

    passed_args = target.get("args") or {}
    try:
        handle = open(dockerfile, encoding="utf-8")
    except OSError as exc:
        print(f"arg-defaults: {name}: cannot read {shown}: {exc}", file=sys.stderr)
        sys.exit(2)

    with handle:
        for line in handle:
            match = ARG_LINE.match(line.rstrip("\n"))
            if match is None:
                continue
            key, default = match.group(1), match.group(2).strip()
            for quote in ('"', "'"):
                if len(default) >= 2 and default.startswith(quote) and default.endswith(quote):
                    default = default[1:-1]
                    break
            # An argument the target does not pass is not compared.
            if key not in passed_args:
                continue
            passed = str(passed_args[key])
            if passed != default:
                drifts.append(
                    f"{name} {shown}: {key}: Dockerfile default {default} != bake value {passed}"
                )

for drift in drifts:
    print(drift)

sys.exit(1 if drifts else 0)
PY