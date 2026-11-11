#!/usr/bin/env bash
# Moves the digest of each upstream image a Dockerfile pins beside its version,
# as `FROM <ref>:${<P>_VERSION}@${<P>_IMAGE_DIGEST}`, when the branch has moved
# that version since <base> and left the digest behind. Renovate reads those
# versions from GitHub releases, where prereleases are marked -- xray publishes
# its prereleases as image tags of the same form -- so it cannot move the
# digest itself. See S-0001/D-23.
#
# A version the branch has not moved is left alone, digest and all: upstream
# rebuilds a tag with fresh geodata, and the pin exists to keep that out. So is
# a digest the branch has already moved, by an earlier run or by hand: the
# digest CI tested, or the one a person chose, is the one that merges, however
# often upstream rebuilds the tag meanwhile.
#
# Invoked as: follow-digest.sh <base>, from the repository root. Prints the
# reference and its new digest for each one moved. RESOLVE_INDEX names a
# command that prints a reference's image index as JSON, so a test can stand
# in for the registry.
set -euo pipefail

if [ "$#" -ne 1 ]; then
	echo "usage: follow-digest.sh <base>" >&2
	exit 2
fi
base=$1

resolve() {
	docker buildx imagetools inspect --format '{{json .Manifest}}' "$1"
}
resolve=${RESOLVE_INDEX:-resolve}

# The default of `ARG <name>=`, read from stdin.
arg() {
	sed -n "s/^ARG $1=//p"
}

for dockerfile in images/*/Dockerfile; do
	from="$(sed -n 's/^FROM \([^ @]*\)@\${\([A-Z0-9_]*\)_IMAGE_DIGEST}.*/\1 \2/p' "${dockerfile}")"
	[ -n "${from}" ] || continue
	ref=${from% *}
	prefix=${from#* }

	version="$(arg "${prefix}_VERSION" <"${dockerfile}")"
	pinned="$(arg "${prefix}_IMAGE_DIGEST" <"${dockerfile}")"
	at_base="$(git show "${base}:${dockerfile}" 2>/dev/null || true)"
	[ "${version}" != "$(arg "${prefix}_VERSION" <<<"${at_base}")" ] || continue
	[ "${pinned}" = "$(arg "${prefix}_IMAGE_DIGEST" <<<"${at_base}")" ] || continue

	ref=${ref/"\${${prefix}_VERSION}"/${version}}
	if ! index="$("${resolve}" "${ref}")"; then
		echo "follow-digest: cannot resolve ${ref}. If upstream has not published it yet, rerun this once it has." >&2
		exit 1
	fi
	# Every target is built for both platforms (S-0001/D-9), and a branch's
	# digest is resolved once, so a single-platform manifest, or an index
	# upstream has not finished, would stick.
	if ! digest="$(jq -er '[.manifests[]?.platform | "\(.os)/\(.architecture)"] as $p
		| select(($p | any(. == "linux/amd64")) and ($p | any(. == "linux/arm64"))) | .digest' \
		<<<"${index}" 2>/dev/null)"; then
		echo "follow-digest: ${ref} is not an image index holding linux/amd64 and linux/arm64" >&2
		exit 1
	fi
	if [[ ! ${digest} =~ ^sha256:[0-9a-f]{64}$ ]]; then
		echo "follow-digest: ${ref} resolved to '${digest}', which is not an image digest" >&2
		exit 1
	fi
	[ "${digest}" != "${pinned}" ] || continue
	if ! grep -q "${pinned}" docker-bake.hcl; then
		echo "follow-digest: docker-bake.hcl does not hold ${prefix}_IMAGE_DIGEST ${pinned}, the Dockerfile's default" >&2
		exit 1
	fi

	sed -i "s/${pinned}/${digest}/" docker-bake.hcl "${dockerfile}"
	echo "${ref} ${digest}"
done
