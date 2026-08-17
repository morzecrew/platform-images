#!/usr/bin/env bash
# RFC 0004 §6's build-mechanism tests: the ones that assert what the *build*
# does with a PG_EXTENSIONS value, rather than what a built image does.
#
# smoke.sh cannot cover these. It receives one image reference and every shipped
# variant contains `cron`, so the case §6 calls "the one test that must never be
# skipped" -- an image whose preload line correctly omits pg_cron -- has no
# shipped tag to run against. These builds are throwaway: nothing is tagged for
# publication and nothing is pushed.
#
# Invoked as: test-extensions.sh [builder-name]
set -euo pipefail

BUILDER="${1:-}"
ENGINE="${ENGINE:-podman}"
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT="$(cd "${HERE}/../.." && pwd)"
WORK="$(mktemp -d)"
CTR="test-ext-$$"

cleanup() {
	"${ENGINE}" rm -f "${CTR}" >/dev/null 2>&1 || true
	"${ENGINE}" rmi -f "${TEST_TAG}" >/dev/null 2>&1 || true
	rm -rf "${WORK}"
}
trap cleanup EXIT

cd "${ROOT}"

# Throwaway builds are tagged as such. Without this they carry the postgres
# target's real tags, so a test build would overwrite the locally loaded
# `postgres:18.6` and the assertions below could not tell which image they were
# inspecting.
TEST_TAG="localhost/postgres-extension-test:scratch"

bake() {
	# bake <extensions> <dest|-> ; prints combined output, returns bake's status
	local exts="$1" dest="$2"
	local args=(buildx)
	[ -n "${BUILDER}" ] && args+=(--builder "${BUILDER}")
	args+=(bake --allow=fs.write="${WORK}"
		--set "postgres.args.PG_EXTENSIONS=${exts}"
		--set "postgres.tags=${TEST_TAG}")
	if [ "${dest}" = "-" ]; then
		# No exporter: the validation this asserts happens in the first RUN
		# layer, so there is nothing to export and no reason to pay for one.
		args+=(--set "postgres.output=type=cacheonly")
	else
		args+=(--set "postgres.output=type=oci,dest=${dest}")
	fi
	args+=(postgres)
	docker "${args[@]}" 2>&1
}

fail() {
	echo "FAIL: $*"
	exit 1
}

# --- 1. an unknown name fails the build, and says what is valid --------------

echo "--- unknown extension name"
set +e
out=$(bake "cron pgvektor" -)
rc=$?
set -e
[ "${rc}" -ne 0 ] || fail "PG_EXTENSIONS='cron pgvektor' built successfully"
case "${out}" in
*"unknown extension 'pgvektor'"*) ;;
*) fail "refusal did not name the unknown extension" ;;
esac
# Listing the valid names is the half that makes the refusal actionable.
case "${out}" in
*"Valid names:"*cron*pgroonga*pgvector*) ;;
*) fail "refusal did not list the valid names" ;;
esac
echo "ok: an unknown name fails the build and lists the valid names"

# --- 2. a non-canonical order fails, naming the canonical one ----------------

# Wave 1's A-2: the label is set from PG_EXTENSIONS as given, so accepting
# "pgroonga cron" would publish two different labels for one extension set.
echo "--- non-canonical order"
set +e
out=$(bake "pgroonga cron" -)
rc=$?
set -e
[ "${rc}" -ne 0 ] || fail "PG_EXTENSIONS='pgroonga cron' built successfully"
case "${out}" in
*"must be in manifest order"*"expected 'cron pgroonga'"*) ;;
*) fail "refusal did not name the canonical spelling" ;;
esac
echo "ok: a non-canonical order fails the build and names the canonical one"

# --- 3. the §3 trap: an image without cron ----------------------------------

# The regression this RFC exists to prevent is a preload line naming a library
# the build did not install -- a fatal startup error. The inverse case is the one
# that must be proven: omitting cron omits pg_cron from the preload line, and the
# server starts.
echo "--- an image built without cron (full build)"
bake "pgroonga" "${WORK}/nocron.tar" >"${WORK}/nocron.log" 2>&1 ||
	{ tail -20 "${WORK}/nocron.log"; fail "a build without cron did not succeed"; }
"${ENGINE}" load -i "${WORK}/nocron.tar" >/dev/null 2>&1
ref="${TEST_TAG}"
"${ENGINE}" image exists "${ref}" || fail "the no-cron image did not load as ${ref}"

"${ENGINE}" run -d --name "${CTR}" -e POSTGRES_PASSWORD=x "${ref}" >/dev/null
ready=0
for _ in $(seq 1 60); do
	if "${ENGINE}" exec "${CTR}" pg_isready -U postgres >/dev/null 2>&1; then
		ready=1
		break
	fi
	sleep 2
done
[ "${ready}" = 1 ] || {
	"${ENGINE}" logs "${CTR}" | tail -20
	fail "the no-cron image never became ready"
}
echo "ok: an image without cron starts"

preload=$("${ENGINE}" exec "${CTR}" psql -U postgres -tAc "SHOW shared_preload_libraries")
[ "${preload}" = "pg_stat_statements" ] ||
	fail "preload line is '${preload}', expected 'pg_stat_statements' alone"
echo "ok: the preload line omits pg_cron rather than naming an absent library"

# §6's snippet coupling: no cron.* settings anywhere, in any file.
leaked=$("${ENGINE}" exec "${CTR}" sh -c \
	'grep -rl "^[[:space:]]*cron\." /etc/postgresql/ /etc/postgresql.conf 2>/dev/null || true')
[ -z "${leaked}" ] || fail "cron.* settings present without cron: ${leaked}"
echo "ok: no cron.* settings survive in an image without cron"

# The label is the build's own record and must agree with what was asked for.
labelled=$("${ENGINE}" image inspect \
	--format '{{ index .Config.Labels "io.morze.postgres.extensions" }}' "${ref}")
[ "${labelled}" = "pgroonga" ] || fail "label is '${labelled}', expected 'pgroonga'"
echo "ok: the label records the selection the build was given"

echo "PASS: postgres extension mechanism"
