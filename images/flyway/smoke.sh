#!/usr/bin/env bash
# Smoke test for a CLI image: does the tool run and are the bundled drivers
# actually loadable? See RFC 0002 §5.5.
set -euo pipefail
IMAGE="${1:?usage: smoke.sh <image-ref>}"
ENGINE="${ENGINE:-podman}"

out=$("${ENGINE}" run --rm "${IMAGE}" -v 2>&1 || true)
echo "${out}" | grep -qi "flyway" || { echo "FAIL: no version output"; echo "${out}"; exit 1; }
echo "version: ok"

# The drivers are the reason this image exists rather than upstream's. A missing
# jar is invisible until a migration runs against that database.
for drv in postgresql clickhouse-jdbc; do
	"${ENGINE}" run --rm --entrypoint sh "${IMAGE}" -c "ls /flyway/drivers | grep -q '^${drv}'" ||
		{ echo "FAIL: ${drv} driver missing from /flyway/drivers"; exit 1; }
	echo "driver: ${drv}"
done

# Declaring an ENTRYPOINT drops the CMD inherited from upstream. Flyway prints
# a usage text either way, but not the same one, so the config is what's checked.
cmd=$("${ENGINE}" image inspect --format '{{json .Config.Cmd}}' "${IMAGE}")
[ "${cmd}" = '["-?"]' ] || { echo "FAIL: CMD is ${cmd}, upstream's is [\"-?\"]"; exit 1; }
echo "CMD: upstream's"

# FLYWAY_*_FILE. A stub `flyway` ahead of upstream's on PATH prints the
# arguments and environment the real one would have received.
with_stub() {
	"${ENGINE}" run --rm --entrypoint sh "$@" "${IMAGE}" -c '
mkdir -p /tmp/stub && printf "#!/bin/sh\necho \"args: \$*\"\nenv\n" >/tmp/stub/flyway
chmod +x /tmp/stub/flyway
printf "jdbc:postgresql://db/app\n" >/tmp/url && printf "app\n" >/tmp/user && printf "s3cret\n" >/tmp/pw
printf "pass\377" >/tmp/notutf8 && head -c 65537 /dev/zero | tr "\000" a >/tmp/big
PATH=/tmp/stub:$PATH exec /usr/local/bin/flyway-entrypoint migrate -X'
}
out=$(with_stub -e FLYWAY_URL_FILE=/tmp/url -e FLYWAY_USER_FILE=/tmp/user \
	-e FLYWAY_PASSWORD_FILE=/tmp/pw -e FLYWAY_PASSWORD=plain 2>&1) ||
	{ echo "FAIL: entrypoint with _FILE secrets did not run flyway"; echo "${out}"; exit 1; }
for want in "args: migrate -X" "FLYWAY_URL=jdbc:postgresql://db/app" "FLYWAY_USER=app" "FLYWAY_PASSWORD=s3cret" \
	"[envfile] FLYWAY_PASSWORD <- FLYWAY_PASSWORD_FILE=/tmp/pw (plain FLYWAY_PASSWORD ignored)"; do
	echo "${out}" | grep -qxF "${want}" || { echo "FAIL: flyway did not get '${want}'"; echo "${out}"; exit 1; }
done
echo "${out}" | grep -q "^FLYWAY_[A-Z]*_FILE=" && { echo "FAIL: a _FILE variable reached flyway"; echo "${out}"; exit 1; }
echo "FLYWAY_*_FILE: resolved, file wins over plain, arguments passed through"

# 78 (EX_CONFIG) and the same checks as python-distroless's envfile-exec.
for path in /nonexistent /tmp /tmp/notutf8 /tmp/big; do
	rc=0
	out=$(with_stub -e FLYWAY_PASSWORD=plain -e "FLYWAY_PASSWORD_FILE=${path}" 2>&1) || rc=$?
	[ "${rc}" = 78 ] ||
		{ echo "FAIL: FLYWAY_PASSWORD_FILE=${path} exited ${rc}, want 78"; echo "${out}"; exit 1; }
	echo "${out}" | grep -q "FLYWAY_PASSWORD_FILE is set to '${path}'" ||
		{ echo "FAIL: refusal does not name FLYWAY_PASSWORD_FILE"; echo "${out}"; exit 1; }
	echo "refused: FLYWAY_PASSWORD_FILE=${path}"
done

echo "PASS: flyway"
