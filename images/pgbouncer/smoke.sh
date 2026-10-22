#!/usr/bin/env bash
# Smoke test for the pgbouncer image. See RFC 0001 §6 and RFC 0003 §5.5.
#
# This image is a pooler, so it needs something to pool: a `postgres:18` sidecar
# on a network of its own runs with scram-sha-256, which means the password the
# pooler logs in with can only have come from the auth_file the entrypoint
# wrote. Sections 1-7 exercise what the image promises when it works; 8 asserts
# the several ways it must refuse to start instead.
set -euo pipefail
IMAGE="${1:?usage: smoke.sh <image-ref>}"
ENGINE="${ENGINE:-podman}"
CTR="smoke-pgbouncer-$$"
PGSIDE="smoke-pgbouncer-pg-$$"
NET="smoke-pgbouncer-$$"
# The credential for both sides. Not a secret and not random: it appears in this
# file, in the sidecar's environment and in the secret file, and the image has
# to be the only thing that keeps it out of its own output.
PW="smoke-pgbouncer-pw"
WORK="$(mktemp -d)"

cleanup() {
	"${ENGINE}" rm -f "${CTR}" "${PGSIDE}" >/dev/null 2>&1 || true
	"${ENGINE}" network rm "${NET}" >/dev/null 2>&1 || true
	rm -rf "${WORK}"
}
trap cleanup EXIT

fail() {
	echo "FAIL: $*"
	"${ENGINE}" logs "${CTR}" 2>&1 | tail -20 || true
	exit 1
}

# The secret file is read by the entrypoint running as `postgres`, whose uid is
# not this one: rootless engines map it to a subuid, so the directory has to be
# traversable and the file world-readable. The container's own 0600 userlist is
# where the value is supposed to end up, not where it comes from.
printf '%s' "${PW}" >"${WORK}/pw"
chmod 0755 "${WORK}"
chmod 0644 "${WORK}/pw"

# start_pooler [engine args...]
start_pooler() {
	"${ENGINE}" rm -f "${CTR}" >/dev/null 2>&1 || true
	"${ENGINE}" run -d --name "${CTR}" --network "${NET}" \
		-e PGBOUNCER_DB_HOST="${PGSIDE}" \
		-e PGBOUNCER_DB_USER=postgres \
		-e PGBOUNCER_DB_PASSWORD_FILE=/run/secrets/pw \
		-v "${WORK}/pw:/run/secrets/pw:ro,Z" \
		"$@" "${IMAGE}" >/dev/null
}

# The health check images/pgbouncer/README.md gives operators, used here so it
# is asserted rather than described. The README says it proves PgBouncer
# answers, not that Postgres does; this is the half of that claim an operator
# can observe from inside the container.
#
# The sidecar resolving the pooler's name is part of ready, because every
# assertion connects by that name: under rootless Podman a container recreated
# under the same name reaches the network's DNS a moment after it answers, and
# arm64 CI read that as "could not translate host name".
wait_pooler() {
	for _ in $(seq 1 60); do
		if "${ENGINE}" exec "${CTR}" pg_isready -h 127.0.0.1 -p 6432 >/dev/null 2>&1 &&
			"${ENGINE}" exec "${PGSIDE}" getent hosts "${CTR}" >/dev/null 2>&1; then
			return 0
		fi
		# A refusal is not slow-starting: it is a container that has already
		# exited with its reason on stderr. Waiting the full 30s for it and
		# then reporting "never answered" hides the message that says why.
		if ! "${ENGINE}" inspect -f '{{.State.Running}}' "${CTR}" 2>/dev/null | grep -q true; then
			fail "${CTR} exited instead of serving"
		fi
		sleep 0.5
	done
	fail "${CTR} never answered pg_isready within 30s"
}

# psql_client <password> <database> [psql args...]
#
# Run from the sidecar, deliberately: it is postgres:18, so its psql has the
# named-prepared-statement meta-commands section 5 needs. The pooler image's own
# client is whatever alpine ships, which is not 18.
psql_client() {
	local password="$1" dbname="$2"
	shift 2
	"${ENGINE}" exec -i -e PGPASSWORD="${password}" -e PGCONNECT_TIMEOUT=10 \
		"${PGSIDE}" psql -X -q -t -A -h "${CTR}" -p 6432 -U postgres -d "${dbname}" "$@"
}

# Runs the image with the given env and expects it to exit non-zero, with
# `needle` in its output. Used for every refusal.
expect_refusal() {
	local label="$1" needle="$2"
	shift 2
	local name="${CTR}-r$$"
	local out rc
	# Bounded twice, because a lost refusal does not exit non-zero -- it starts
	# a pooler that runs forever. Unbounded, this assertion hangs until CI kills
	# the job, which reads as an infrastructure problem rather than as the
	# missing refusal it is. `--kill-after` bounds the bound: plain `timeout`
	# sends SIGTERM and then waits for a process that may not take it. The kill
	# path exits 137 rather than 124, and both mean the same thing here.
	set +e
	out=$(timeout --kill-after=10 60 "${ENGINE}" run --rm --name "${name}" "$@" "${IMAGE}" 2>&1)
	rc=$?
	set -e
	"${ENGINE}" rm -f "${name}" >/dev/null 2>&1 || true
	if [ "${rc}" -eq 124 ] || [ "${rc}" -eq 137 ]; then
		echo "FAIL: ${label} started and kept running, but it must refuse"
		echo "${out}" | tail -5
		exit 1
	fi
	if [ "${rc}" -eq 0 ]; then
		echo "FAIL: ${label} started, but it must refuse"
		echo "${out}" | tail -5
		exit 1
	fi
	case "${out}" in
	*"${needle}"*) echo "refused: ${label}" ;;
	*)
		echo "FAIL: ${label} refused but did not mention '${needle}'"
		echo "${out}" | tail -10
		exit 1
		;;
	esac
}

# --- 1. the label and the binary name the same PgBouncer ------------------

# The tag is edoburu's (`v1.26.0-p0`) and the label is PgBouncer's own version,
# derived from that tag by docker-bake.hcl. Deriving is only safe while the two
# agree, so this is what turns a wrong derivation into a failed build.
want="$("${ENGINE}" image inspect "${IMAGE}" \
	--format '{{ index .Config.Labels "org.opencontainers.image.version" }}' 2>/dev/null | tr -d '\r')"
if [ -z "${want}" ]; then
	echo "FAIL: the image has no org.opencontainers.image.version label"
	exit 1
fi
have="$("${ENGINE}" run --rm --entrypoint pgbouncer "${IMAGE}" --version 2>&1 || true)"
case "${have}" in
*"${want}"*) echo "version: label ${want} matches '${have}'" ;;
*)
	echo "FAIL: the label says ${want} and pgbouncer --version says '${have}'"
	exit 1
	;;
esac

# --- 2. it starts, and the sidecar it pools is really scram -----------------

"${ENGINE}" network create "${NET}" >/dev/null
"${ENGINE}" run -d --name "${PGSIDE}" --network "${NET}" \
	-e POSTGRES_PASSWORD="${PW}" \
	-e POSTGRES_HOST_AUTH_METHOD=scram-sha-256 \
	-e POSTGRES_INITDB_ARGS=--auth-host=scram-sha-256 \
	postgres:18 >/dev/null

ready=0
for _ in $(seq 1 120); do
	if "${ENGINE}" exec "${PGSIDE}" pg_isready -U postgres -h 127.0.0.1 >/dev/null 2>&1; then
		ready=1
		break
	fi
	sleep 0.5
done
if [ "${ready}" -ne 1 ]; then
	echo "FAIL: the postgres:18 sidecar never became ready"
	"${ENGINE}" logs "${PGSIDE}" 2>&1 | tail -20 || true
	exit 1
fi

start_pooler
wait_pooler

# --- 3. a login through 6432, the password given only as _FILE ------------

# The login is most of this image in one assertion: the client authenticates
# against the userlist.txt the entrypoint wrote, and the pooler logs into
# Postgres with the same credential -- so a value that only ever existed as a
# file has been read, redacted, written 0600, and used to reach a backend that
# will not accept it from anywhere else.
got="$(psql_client "${PW}" postgres -c 'select current_user' 2>&1 || true)"
[ "${got}" = "postgres" ] ||
	fail "a login through 6432 returned '${got}', expected the pooled user"

# The plain variable is set to a value that must *not* be in force: _FILE wins
# (RFC 0001 decision 4).
"${ENGINE}" rm -f "${CTR}" >/dev/null
start_pooler -e PGBOUNCER_DB_PASSWORD=not-the-file-password
wait_pooler
got="$(psql_client "${PW}" postgres -c 'select 1' 2>&1 || true)"
[ "${got}" = "1" ] || fail "the password from _FILE was not the one in force: ${got}"
if psql_client "not-the-file-password" postgres -c 'select 1' >/dev/null 2>&1; then
	fail "PGBOUNCER_DB_PASSWORD was used even though _FILE was set"
fi
echo "login: works through 6432, with _FILE beating the plain variable"

# A wrong password is refused rather than pooled.
out=""
if out="$(psql_client "not-the-password" postgres -c 'select 1' 2>&1)"; then
	fail "a wrong password was accepted: ${out}"
fi
case "${out}" in
*"authentication failed"*) echo "login: a wrong password is refused" ;;
*) fail "a wrong password failed, but not as an auth failure: ${out}" ;;
esac

# --- 4. what the running pooler is actually configured with ---------------

# The admin console, not the file: this is the configuration the process is
# using, so a value that reached pgbouncer.ini but was not read cannot pass.
show="$(psql_client "${PW}" pgbouncer -c 'SHOW CONFIG' 2>&1 || true)"
for pair in pool_mode=transaction auth_type=scram-sha-256 \
	max_prepared_statements=200 max_client_conn=1000 default_pool_size=30; do
	key="${pair%%=*}"
	value="${pair#*=}"
	got="$(printf '%s\n' "${show}" | awk -F'|' -v k="${key}" '$1 == k { print $2 }')"
	[ "${got}" = "${value}" ] || fail "SHOW CONFIG reports ${key}=${got:-<absent>}, expected ${value}"
done
echo "SHOW CONFIG: transaction, scram-sha-256, 200, 1000, 30"

# --- 5. a named prepared statement across several transactions ------------

# `server_lifetime=1` is what makes this mean anything. A single client keeps
# landing on the same server connection, and there its named statement exists
# whether the pooler tracks it or not. With the connection retired a second
# after it goes idle, each transaction after the first opens a new one, and the
# statement has to be re-prepared on it -- which is what
# max_prepared_statements buys, and 200 is the default this image bakes.
#
# It is also the passthrough channel doing something useful in the test: a key
# off the curated list, set through PGBOUNCER_CONF__, reaching the running
# pooler.
"${ENGINE}" rm -f "${CTR}" >/dev/null
start_pooler -e PGBOUNCER_CONF__server_lifetime=1
wait_pooler

# \parse and \bind_named are psql 18's meta-commands for the extended protocol:
# they name a prepared statement and then execute it, and each `\g` is its own
# transaction. The sleep covers the retirement above, so the two executions
# cannot be served by one server connection.
prepared='SELECT $1::int AS n \parse stmt1
\bind_named stmt1 41 \g
SELECT pg_sleep(2.5) \g
\bind_named stmt1 42 \g'
out="$(printf '%s\n' "${prepared}" | psql_client "${PW}" postgres 2>&1 || true)"
case "${out}" in
*ERROR* | *"does not exist"*) fail "a named prepared statement errored: ${out}" ;;
esac
case "${out}" in
*41*42*) echo "prepared statement: a named statement executed across transactions" ;;
*) fail "a named prepared statement did not survive across transactions: ${out}" ;;
esac

# --- 6. the credential is in the file that needs it and nowhere else ------

logs="$("${ENGINE}" logs "${CTR}" 2>&1 || true)"
case "${logs}" in
*"${PW}"*) fail "the password appears in the container log" ;;
*) echo "password: absent from the log" ;;
esac
case "${logs}" in
*"[envconf] PGBOUNCER: effective configuration"*) ;;
*) fail "the startup summary is missing from the log" ;;
esac
case "${logs}" in
*"precedence: image default < environment"*) ;;
*) fail "the startup summary does not state its precedence" ;;
esac

ini="$("${ENGINE}" exec "${CTR}" cat /etc/pgbouncer/pgbouncer.ini 2>&1 || true)"
case "${ini}" in
*"${PW}"*) fail "the password appears in pgbouncer.ini" ;;
*) echo "password: absent from pgbouncer.ini" ;;
esac
# ...because the [databases] line names the user and takes the password from
# auth_file. Without that, the backend login would need `password=` here.
case "${ini}" in
*"user=postgres"*) ;;
*) fail "the [databases] line does not name the server user" ;;
esac

mode="$("${ENGINE}" exec "${CTR}" stat -c %a /etc/pgbouncer/userlist.txt 2>/dev/null | tr -d '\r' || true)"
[ "${mode}" = "600" ] || fail "userlist.txt is mode ${mode:-unknown}, expected 600"

# ...and not on disk anywhere else either. The entrypoint keeps its source map
# -- which holds every value in the clear, the password among them -- in a
# directory under /tmp, and an EXIT trap does not fire across the `exec` that
# hands off to the pooler, so the directory is removed explicitly. Without
# that, "the credential lives in userlist.txt alone" is true of the two files
# the image installs and false of the running container.
leftover="$("${ENGINE}" exec "${CTR}" grep -rl "${PW}" /tmp /var/tmp 2>/dev/null || true)"
[ -z "${leftover}" ] || fail "the password is left on disk outside userlist.txt: ${leftover}"
echo "userlist.txt: 0600, and the password is nowhere else"

# --- 7. a changed environment takes effect on a restart -------------------

# edoburu's entrypoint generates pgbouncer.ini only when the file is missing, so
# a restart brings back whatever the previous start wrote. Every runtime this
# image is for recreates a container to change its environment, so the stale
# file is written directly here -- it is the same file, and it has to lose to
# the environment exactly as it would after a rollout.
"${ENGINE}" rm -f "${CTR}" >/dev/null
start_pooler -e PGBOUNCER_MAX_CLIENT_CONN=111 -e PGBOUNCER_POOL_MODE=session
wait_pooler
got="$(psql_client "${PW}" pgbouncer -c 'SHOW CONFIG' 2>&1 || true)"
value="$(printf '%s\n' "${got}" | awk -F'|' '$1 == "max_client_conn" { print $2 }')"
[ "${value}" = "111" ] || fail "max_client_conn was ${value:-<absent>} before the restart, expected 111"

"${ENGINE}" exec "${CTR}" sed -i \
	-e 's/^max_client_conn = 111$/max_client_conn = 999/' \
	-e 's/^pool_mode = session$/pool_mode = statement/' \
	/etc/pgbouncer/pgbouncer.ini
"${ENGINE}" exec "${CTR}" grep -q '^max_client_conn = 999$' /etc/pgbouncer/pgbouncer.ini ||
	fail "the stale config could not be written, so this section proves nothing"

"${ENGINE}" restart "${CTR}" >/dev/null
wait_pooler
"${ENGINE}" exec "${CTR}" grep -q '^max_client_conn = 111$' /etc/pgbouncer/pgbouncer.ini ||
	fail "pgbouncer.ini was not regenerated from the environment on restart"
got="$(psql_client "${PW}" pgbouncer -c 'SHOW CONFIG' 2>&1 || true)"
conn="$(printf '%s\n' "${got}" | awk -F'|' '$1 == "max_client_conn" { print $2 }')"
pmode="$(printf '%s\n' "${got}" | awk -F'|' '$1 == "pool_mode" { print $2 }')"
[ "${conn}" = "111" ] && [ "${pmode}" = "session" ] ||
	fail "after the restart the pooler runs max_client_conn=${conn:-<absent>} pool_mode=${pmode:-<absent>}, not the environment's"
echo "restart: the environment, not the file on disk, decides"
"${ENGINE}" rm -f "${CTR}" >/dev/null

# --- 8. the several ways it refuses to start ------------------------------

# Every one of these needs the three required variables, or the "required"
# checks fire first and the refusal under test is never reached.
DBARGS=(-e PGBOUNCER_DB_HOST=nowhere.invalid -e PGBOUNCER_DB_USER=postgres \
	-e PGBOUNCER_DB_PASSWORD="${PW}")

expect_refusal "a passthrough key outside the allowlist" "not in the allowlist" \
	"${DBARGS[@]}" -e PGBOUNCER_CONF__no_such_setting=1

expect_refusal "a denylisted key" "denylisted" \
	"${DBARGS[@]}" -e PGBOUNCER_CONF__auth_file=/tmp/elsewhere.txt

expect_refusal "the curated and passthrough channels setting pool_mode" "both set it" \
	"${DBARGS[@]}" -e PGBOUNCER_POOL_MODE=session -e PGBOUNCER_CONF__pool_mode=transaction

# trust admits every user in the auth file without a password, and `any` admits
# every user there is; both are refused by name, which is why the image curates
# this setting instead of defaulting it and leaving it open.
expect_refusal "PGBOUNCER_AUTH_TYPE=trust" "authenticates nobody" \
	"${DBARGS[@]}" -e PGBOUNCER_AUTH_TYPE=trust

# auth_type is allowlisted, so the passthrough channel is another spelling of
# the same setting, and PgBouncer takes the last occurrence of a repeated key.
# The refusal is therefore re-checked against the assembled file, not only
# against the environment.
expect_refusal "PGBOUNCER_CONF__auth_type=trust, the allowlisted spelling" \
	"assembled pgbouncer.ini" "${DBARGS[@]}" -e PGBOUNCER_CONF__auth_type=trust

# The two things a value in this format cannot be, refused before they are
# written rather than left for PgBouncer's parser to misread.
expect_refusal "a passthrough value that opens a section" "opens a section" \
	"${DBARGS[@]}" -e 'PGBOUNCER_CONF__application_name_add_host=[databases]'

expect_refusal "a passthrough value that starts an include" "%include" \
	"${DBARGS[@]}" -e 'PGBOUNCER_CONF__track_extra_parameters=%include /tmp/evil.conf'

echo "PASS: pgbouncer"