#!/usr/bin/env bash
# Smoke test for the rustfs image. See RFC 0002 §5.5 and RFC 0001 §6.
#
# Half of these assert that the container *refuses to start*. That is the point
# of the image: upstream warns about a missing or default credential and starts
# anyway, so the test that matters is that this image does not.
set -euo pipefail
IMAGE="${1:?usage: smoke.sh <image-ref>}"
ENGINE="${ENGINE:-podman}"
CTR="smoke-rustfs-$$"
SECRETS_VOL="smoke-rustfs-secrets-$$"
WORK="$(mktemp -d)"

# Published rather than reached by `exec`: the S3 assertions are signed HTTP
# requests, and the image carries no signer. 9001 is published too, so "the
# console is off" is an assertion about the container and not about a port
# nobody mapped.
API_PORT=19000
CONSOLE_PORT=19001
ACCESS_KEY=smoke-access-key-3f1a
SECRET_KEY=smoke-secret-key-9c2e

cleanup() {
	"${ENGINE}" rm -f "${CTR}" >/dev/null 2>&1 || true
	"${ENGINE}" volume rm -f "${SECRETS_VOL}" >/dev/null 2>&1 || true
	rm -rf "${WORK}"
}
trap cleanup EXIT

# A SigV4 signer, because the image has no S3 client and path-style signing is
# the only way to assert from outside that the object API answers. Writes the
# status on the first line and the body after it.
cat >"${WORK}/s3.py" <<'PY'
import datetime
import hashlib
import hmac
import http.client
import sys

method, path, body, access, secret = sys.argv[1:6]
port = int(sys.argv[6]) if len(sys.argv) > 6 else 9000
body = body.encode()
host = "127.0.0.1"
region = "us-east-1"
service = "s3"

if access == "-":
    conn = http.client.HTTPConnection(host, port, timeout=10)
    conn.request(method, path, body=body)
    resp = conn.getresponse()
    print(resp.status)
    print(resp.read().decode("utf-8", "replace"), end="")
    raise SystemExit(0)

now = datetime.datetime.now(datetime.timezone.utc)
amzdate = now.strftime("%Y%m%dT%H%M%SZ")
datestamp = now.strftime("%Y%m%d")
payload_hash = hashlib.sha256(body).hexdigest()
signed_headers = "host;x-amz-content-sha256;x-amz-date"
canonical_headers = "\n".join([
    "host:%s:%d" % (host, port),
    "x-amz-content-sha256:%s" % payload_hash,
    "x-amz-date:%s" % amzdate,
]) + "\n"
canonical_request = "\n".join([method, path, "", canonical_headers, signed_headers, payload_hash])
scope = "%s/%s/%s/aws4_request" % (datestamp, region, service)
string_to_sign = "\n".join([
    "AWS4-HMAC-SHA256",
    amzdate,
    scope,
    hashlib.sha256(canonical_request.encode()).hexdigest(),
])
key = ("AWS4" + secret).encode()
for part in (datestamp, region, service, "aws4_request"):
    key = hmac.new(key, part.encode(), hashlib.sha256).digest()
signature = hmac.new(key, string_to_sign.encode(), hashlib.sha256).hexdigest()
authorization = "AWS4-HMAC-SHA256 Credential=%s/%s, SignedHeaders=%s, Signature=%s" % (
    access, scope, signed_headers, signature,
)

conn = http.client.HTTPConnection(host, port, timeout=10)
conn.request(method, path, body=body, headers={
    "Authorization": authorization,
    "x-amz-content-sha256": payload_hash,
    "x-amz-date": amzdate,
    "Content-Length": str(len(body)),
})
resp = conn.getresponse()
print(resp.status)
print(resp.read().decode("utf-8", "replace"), end="")
PY

s3() {
	# s3 <method> <path> [body] [access] [secret]
	python3 "${WORK}/s3.py" "$1" "$2" "${3:-}" "${4:-${ACCESS_KEY}}" "${5:-${SECRET_KEY}}" "${API_PORT}"
}

status_of() {
	# status_of <method> <path> [body] [access] [secret]
	s3 "$@" | head -1
}

start() {
	"${ENGINE}" rm -f "${CTR}" >/dev/null 2>&1 || true
	"${ENGINE}" run -d --name "${CTR}" \
		-p "127.0.0.1:${API_PORT}:9000" -p "127.0.0.1:${CONSOLE_PORT}:9001" \
		"$@" "${IMAGE}" >/dev/null
}

wait_ready() {
	local i code
	for i in $(seq 1 60); do
		code="$(curl -s -o /dev/null -w '%{http_code}' -m 3 \
			"http://127.0.0.1:${API_PORT}/health/ready" 2>/dev/null || true)"
		[ "${code}" = "200" ] && return 0
		sleep 1
	done
	echo "FAIL: /health/ready never returned 200"
	"${ENGINE}" logs "${CTR}" 2>&1 | tail -20
	return 1
}

logs_of() { "${ENGINE}" logs "${CTR}" 2>&1; }

http_code() {
	curl -s -o /dev/null -w '%{http_code}' -m 3 "$1" 2>/dev/null || true
}

expect_in() {
	# expect_in <label> <haystack> <needle>
	case "$2" in
	*"$3"*) echo "ok: $1" ;;
	*)
		echo "FAIL: $1 -- expected '$3'"
		printf '%s\n' "$2" | tail -20
		exit 1
		;;
	esac
}

expect_not_in() {
	# expect_not_in <label> <haystack> <needle>
	case "$2" in
	*"$3"*)
		echo "FAIL: $1 -- '$3' must not appear"
		printf '%s\n' "$2" | tail -20
		exit 1
		;;
	*) echo "ok: $1" ;;
	esac
}

# Runs the image with the given env and expects it to exit non-zero, with
# `needle` in its output. Used for every refusal.
expect_refusal() {
	local label="$1" needle="$2"
	shift 2
	local name="${CTR}-r$$"
	local out rc
	# Bounded twice, because a lost refusal does not exit non-zero -- it starts
	# a server that runs forever, and an unbounded wait reads as an
	# infrastructure problem rather than as the regression it is.
	set +e
	out=$(timeout --kill-after=10 60 "${ENGINE}" run --rm --name "${name}" "$@" "${IMAGE}" 2>&1)
	rc=$?
	set -e
	"${ENGINE}" rm -f "${name}" >/dev/null 2>&1 || true
	if [ "${rc}" -eq 124 ] || [ "${rc}" -eq 137 ]; then
		echo "FAIL: ${label} started and kept running, but it must refuse"
		printf '%s\n' "${out}" | tail -5
		exit 1
	fi
	if [ "${rc}" -eq 0 ]; then
		echo "FAIL: ${label} started, but it must refuse"
		printf '%s\n' "${out}" | tail -5
		exit 1
	fi
	case "${out}" in
	*"${needle}"*) echo "refused: ${label}" ;;
	*)
		echo "FAIL: ${label} refused but did not mention '${needle}'"
		printf '%s\n' "${out}" | tail -10
		exit 1
		;;
	esac
}

mkdir -p "${WORK}/secrets"
printf '%s' "${ACCESS_KEY}" >"${WORK}/secrets/access"
printf '%s' "${SECRET_KEY}" >"${WORK}/secrets/secret"
chmod 0644 "${WORK}/secrets/access" "${WORK}/secrets/secret"

# --- 1. it serves, with a credential, on both health surfaces --------------

start -e RUSTFS_ACCESS_KEY="${ACCESS_KEY}" -e RUSTFS_SECRET_KEY="${SECRET_KEY}"
wait_ready

for path in /health/live /health/ready /minio/health/live; do
	code="$(http_code "http://127.0.0.1:${API_PORT}${path}")"
	[ "${code}" = "200" ] || { echo "FAIL: ${path} returned ${code}"; exit 1; }
	echo "health: ${path} 200"
done

# --- 2. the console is off, which is the image's first default -------------

console="$(http_code "http://127.0.0.1:${CONSOLE_PORT}/health/live")"
# 000 is "no HTTP response at all". An empty reply from a published port with
# nothing behind it is exactly as much a refusal as a connection error.
[ "${console}" = "000" ] ||
	{ echo "FAIL: something answered on the console port (${console})"; exit 1; }
echo "console: nothing listening on 9001"

# --- 3. the server logs to stdout, which is the image's second default -----

logs="$(logs_of)"
# An upstream rustfs line rather than the entrypoint's: the default
# RUSTFS_OBS_LOG_DIRECTORY is /logs, which puts the server's log in a file
# inside the container, and this image empties it so `docker logs` has it.
expect_in "the server's own log reaches the container log" "${logs}" '"target":"rustfs'
expect_in "the summary reports the curated address" "${logs}" "RUSTFS_ADDRESS = :9000"
expect_in "the summary reports the console off" "${logs}" "RUSTFS_CONSOLE_ENABLE = false"

# --- 4. secrets: neither reaches the log, and _FILE alone is enough --------

expect_not_in "the access key is not in the log" "${logs}" "${ACCESS_KEY}"
expect_not_in "the secret key is not in the log" "${logs}" "${SECRET_KEY}"

start -v "${WORK}/secrets/access:/run/access:ro,Z" \
	-v "${WORK}/secrets/secret:/run/secret:ro,Z" \
	-e RUSTFS_ACCESS_KEY_FILE=/run/access \
	-e RUSTFS_SECRET_KEY_FILE=/run/secret
wait_ready
echo "starts: both credentials given only as _FILE"

# --- 5. the object API: signed path-style works, unsigned does not ---------

code="$(status_of PUT /smoke-bucket)"
[ "${code}" = "200" ] || { echo "FAIL: creating a bucket returned ${code}"; exit 1; }
echo "s3: bucket created"

code="$(status_of PUT /smoke-bucket/hello.txt "hello-rustfs")"
[ "${code}" = "200" ] || { echo "FAIL: putting an object returned ${code}"; exit 1; }

got="$(s3 GET /smoke-bucket/hello.txt | tail -n +2)"
[ "${got}" = "hello-rustfs" ] ||
	{ echo "FAIL: the object read back as '${got}'"; exit 1; }
echo "s3: object put and got"

code="$(status_of GET /smoke-bucket/hello.txt "" -)"
[ "${code}" = "403" ] || { echo "FAIL: an anonymous read returned ${code}, expected 403"; exit 1; }
echo "s3: anonymous read refused 403"

code="$(status_of GET /smoke-bucket/hello.txt "" "${ACCESS_KEY}" "not-the-secret")"
[ "${code}" = "403" ] || { echo "FAIL: a wrong secret returned ${code}, expected 403"; exit 1; }
echo "s3: wrong secret refused 403"

# --- 6. the passthrough channel reaches upstream's own name ----------------

"${ENGINE}" rm -f "${CTR}" >/dev/null
start -e RUSTFS_ACCESS_KEY="${ACCESS_KEY}" -e RUSTFS_SECRET_KEY="${SECRET_KEY}" \
	-e RUSTFS_CONF__region=eu-west-1
wait_ready
expect_in "the passthrough key is exported under upstream's name" "$(logs_of)" \
	"RUSTFS_REGION = eu-west-1"
"${ENGINE}" rm -f "${CTR}" >/dev/null

# --- 7. the run that must not happen, every way it is reachable ------------

expect_refusal "a missing credential" "must be set"
expect_refusal "the built-in rustfsadmin credential" "rustfsadmin" \
	-e RUSTFS_ACCESS_KEY=rustfsadmin -e RUSTFS_SECRET_KEY="${SECRET_KEY}"
expect_refusal "an unreadable credential file" "not readable" \
	-e RUSTFS_ACCESS_KEY_FILE=/nonexistent/access -e RUSTFS_SECRET_KEY="${SECRET_KEY}"
# No `--user`, so this is the root path: the entrypoint reads both files and
# refuses the pair itself, before the drop and before anything is exported.
# The wording on the line is upstream's own.
expect_refusal "a credential set as both a value and a file" "not both" \
	-v "${WORK}/secrets/access:/run/access:ro,Z" \
	-e RUSTFS_ACCESS_KEY=plain-value -e RUSTFS_ACCESS_KEY_FILE=/run/access \
	-e RUSTFS_SECRET_KEY="${SECRET_KEY}"
expect_refusal "upstream's pre-rename root credential" "RUSTFS_ROOT_USER" \
	-e RUSTFS_ROOT_USER=legacy -e RUSTFS_ACCESS_KEY="${ACCESS_KEY}" \
	-e RUSTFS_SECRET_KEY="${SECRET_KEY}"
expect_refusal "a passthrough key off the allowlist" "not in the allowlist" \
	-e RUSTFS_ACCESS_KEY="${ACCESS_KEY}" -e RUSTFS_SECRET_KEY="${SECRET_KEY}" \
	-e RUSTFS_CONF__not_a_real_setting=1
expect_refusal "the data directory through the passthrough channel" "denylisted" \
	-e RUSTFS_ACCESS_KEY="${ACCESS_KEY}" -e RUSTFS_SECRET_KEY="${SECRET_KEY}" \
	-e RUSTFS_CONF__VOLUMES=/tmp/elsewhere

# --- 8. a credential file another uid owns, read as root -------------------
#
# This is what the root start buys: a Kubernetes secret or a file an init
# container wrote is mode 0400 and belongs to somebody else, and uid 10001
# cannot read it. The entrypoint reads and checks both as root, exports the
# values, and drops the server to 10001 with them.

# The files are made inside the image under test, as root, on a volume of its
# own: the ownership and the mode are the point, and writing them through the
# engine is what proves they need nothing of the host. The secret file ends in
# CRLF -- the request signed with the unadorned value below is what proves the
# carriage return did not reach the server.
"${ENGINE}" run --rm --user 0 --entrypoint sh \
	-v "${SECRETS_VOL}:/secrets" \
	-e "FILE_ACCESS=${ACCESS_KEY}" -e "FILE_SECRET=${SECRET_KEY}" \
	"${IMAGE}" -c '
	set -eu
	printf "%s\n" "${FILE_ACCESS}" > /secrets/access
	printf "%s\r\n" "${FILE_SECRET}" > /secrets/secret
	chown 65532:65532 /secrets/access /secrets/secret
	chmod 0400 /secrets/access /secrets/secret
'

start -v "${SECRETS_VOL}:/run/secrets:ro" \
	-e RUSTFS_ACCESS_KEY_FILE=/run/secrets/access \
	-e RUSTFS_SECRET_KEY_FILE=/run/secrets/secret
wait_ready

# The server is PID 1 -- upstream's script ends in `exec`, and the entrypoint
# execs through `setpriv` -- and it is uid 10001, not the root the container
# started as. Read inside the container, where 1 is that process.
pid1_uid="$("${ENGINE}" exec "${CTR}" cat /proc/1/status | awk '/^Uid:/{print $2}')"
[ "${pid1_uid}" = "10001" ] ||
	{ echo "FAIL: PID 1 runs as uid ${pid1_uid}, expected 10001"; exit 1; }
echo "root path: PID 1 runs as uid 10001"

code="$(status_of PUT /smoke-bucket)"
[ "${code}" = "200" ] || { echo "FAIL: creating a bucket returned ${code}"; exit 1; }
code="$(status_of PUT /smoke-bucket/root-path.txt "hello-root-path")"
[ "${code}" = "200" ] || { echo "FAIL: putting an object returned ${code}"; exit 1; }
got="$(s3 GET /smoke-bucket/root-path.txt | tail -n +2)"
[ "${got}" = "hello-root-path" ] ||
	{ echo "FAIL: the object read back as '${got}'"; exit 1; }
echo "root path: signed request created a bucket, put and got an object"

logs="$(logs_of)"
expect_not_in "the access key is not in the root path's log" "${logs}" "${ACCESS_KEY}"
expect_not_in "the secret key is not in the root path's log" "${logs}" "${SECRET_KEY}"

# A credential set directly is the server's as given, padding included: only a
# file's content is normalized and exported, so the root path must not hand
# the server a trimmed copy of a value nobody read from a file.
start -e RUSTFS_ACCESS_KEY="${ACCESS_KEY}" -e RUSTFS_SECRET_KEY="${SECRET_KEY} "
wait_ready
code="$(status_of PUT /smoke-bucket/padded.txt "padded" "${ACCESS_KEY}" "${SECRET_KEY} ")"
[ "${code}" = "200" ] ||
	{ echo "FAIL: a padded secret set directly signed a ${code}, expected 200"; exit 1; }
echo "root path: a value set directly reaches the server unchanged"

# --- 9. `--user`: the same image, run as the server's uid ------------------
#
# Pinning `user:` gets none of the above: the container runs as that uid
# throughout and execs upstream's entrypoint unchanged, so the files have to be
# readable by it. World-readable ones still serve.
start --user 10001 \
	-v "${WORK}/secrets/access:/run/access:ro,Z" \
	-v "${WORK}/secrets/secret:/run/secret:ro,Z" \
	-e RUSTFS_ACCESS_KEY_FILE=/run/access \
	-e RUSTFS_SECRET_KEY_FILE=/run/secret
wait_ready
code="$(status_of PUT /smoke-bucket-user)"
[ "${code}" = "200" ] ||
	{ echo "FAIL: creating a bucket as --user 10001 returned ${code}"; exit 1; }
echo "user path: world-readable _FILEs still serve under --user 10001"

# The same volume that worked as root: uid 10001 cannot read it, and the
# refusal names the `_FILE` it could not open.
expect_refusal "--user 10001 with a file it cannot read" \
	"RUSTFS_ACCESS_KEY_FILE is set to '/run/secrets/access', which is not readable" \
	--user 10001 \
	-v "${SECRETS_VOL}:/run/secrets:ro" \
	-e RUSTFS_ACCESS_KEY_FILE=/run/secrets/access \
	-e RUSTFS_SECRET_KEY_FILE=/run/secrets/secret

echo "ok: rustfs smoke"