#!/usr/bin/env bash
# Smoke test for the proxy-warm image. See images/proxy-warm/README.md.
#
# No internet: the upstream is a SOCKS5 proxy with a login, written here in
# Python, which records each login, and the target is a Python web server, both
# on loopback with the container on the host's network. The program's own tests
# (src/main_test.go, run by the build) cover the protocols; this covers the
# image: its user, its refusals, its summary, and spares logged in before any
# client asks.
set -euo pipefail
IMAGE="${1:?usage: smoke.sh <image-ref>}"
ENGINE="${ENGINE:-podman}"
CTR="smoke-proxy-warm-$$"
WORK="$(mktemp -d)"
BASE=$((20000 + $$ % 20000))
UP_PORT=${BASE}
TARGET_PORT=$((BASE + 1))
WARM_PORT=$((BASE + 2))
PROXY_USER=smoke
PROXY_PASS="pw-$$-s3cret"
PIDS=()
# shellcheck disable=SC2054 # the commas are the option's own
RUN_ARGS=(--network host --userns keep-id:uid=65532,gid=65532)

cleanup() {
	"${ENGINE}" rm -f "${CTR}" >/dev/null 2>&1 || true
	for pid in "${PIDS[@]}"; do kill "${pid}" 2>/dev/null || true; done
	rm -rf "${WORK}"
}
trap cleanup EXIT

fail() {
	echo "FAIL: $*"
	"${ENGINE}" logs "${CTR}" 2>&1 | tail -20 || true
	exit 1
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

# --- 1. the image -------------------------------------------------------------

VERSION="$("${ENGINE}" image inspect --format '{{index .Labels "org.opencontainers.image.version"}}' "${IMAGE}")"
[ -n "${VERSION}" ] || fail "no org.opencontainers.image.version label"
cfg="$("${ENGINE}" image inspect --format \
	'user={{.Config.User}} entrypoint={{.Config.Entrypoint}} cmd={{.Config.Cmd}} healthcheck={{.Config.Healthcheck}}' \
	"${IMAGE}")"
expect_in "runs as 65532:65532" "${cfg}" "user=65532:65532 "
expect_in "the entrypoint is the program, run by default" "${cfg}" "entrypoint=[/usr/local/bin/proxy-warm] cmd=[run]"
expect_in "no baked HEALTHCHECK" "${cfg}" "healthcheck=<nil>"
"${ENGINE}" create --name "${CTR}" "${IMAGE}" >/dev/null
files="$("${ENGINE}" export "${CTR}" | tar -tvf -)"
"${ENGINE}" rm "${CTR}" >/dev/null
line="$(printf '%s\n' "${files}" | awk '$NF == "usr/local/bin/proxy-warm"')"
expect_in "the program is present and root's" "${line}" " 0/0 "
for f in bin/sh bin/busybox; do
	if printf '%s\n' "${files}" | awk '{ print $NF }' | grep -qx "${f}"; then
		fail "${f} is in the image"
	fi
done
echo "ok: no shell"

# --- 2. refusals --------------------------------------------------------------

mkdir -p "${WORK}/secrets" "${WORK}/www"
refused() { # <label> <expected message> [run args...]
	local out rc=0
	out="$("${ENGINE}" run --rm "${RUN_ARGS[@]}" -v "${WORK}/secrets:/run/secrets:ro" "${@:3}" "${IMAGE}" 2>&1)" || rc=$?
	[ "${rc}" = 78 ] || fail "$1: exit ${rc}, not 78: ${out}"
	expect_in "$1" "${out}" "$2"
	case "${out}" in *"${PROXY_PASS}"*) fail "$1: the password is in the output" ;; esac
}
refused "refuses to start with no upstreams file" "PROXY_WARM_UPSTREAMS is unset"
printf 'socks5://%s:%s@127.0.0.1:%s name=isp\n' "${PROXY_USER}" "${PROXY_PASS}" "${UP_PORT}" >"${WORK}/secrets/none"
# No warm= line is no refusal: the container runs, idle, and stays healthy.
"${ENGINE}" run -d --name "${CTR}" "${RUN_ARGS[@]}" -v "${WORK}/secrets:/run/secrets:ro" \
	-e PROXY_WARM_UPSTREAMS=/run/secrets/none "${IMAGE}" >/dev/null
sleep 1
expect_in "a file with no warm= line leaves it idle" "$("${ENGINE}" logs "${CTR}" 2>&1)" "has no line tagged warm=: nothing to keep ready"
"${ENGINE}" exec "${CTR}" /usr/local/bin/proxy-warm healthcheck || fail "the healthcheck fails while idle"
echo "ok: idle, it passes its healthcheck"
"${ENGINE}" rm -f "${CTR}" >/dev/null
printf 'socks5://%s:%s@127.0.0.1:%s warm=0\n' "${PROXY_USER}" "${PROXY_PASS}" "${UP_PORT}" >"${WORK}/secrets/zero"
refused "refuses warm=0, without quoting the line" "line 1: warm= is the number of connections" -e PROXY_WARM_UPSTREAMS=/run/secrets/zero
printf 'openvpn://H4sI warm=1\n' >"${WORK}/secrets/tunnel"
refused "refuses warm= on a tunnel" "is for a SOCKS5 or an HTTP proxy" -e PROXY_WARM_UPSTREAMS=/run/secrets/tunnel

# --- 3. spares logged in ahead, and traffic through them ----------------------

: >"${WORK}/www/generate_204"
python3 -m http.server "${TARGET_PORT}" --bind 127.0.0.1 --directory "${WORK}/www" >"${WORK}/httpd.log" 2>&1 &
PIDS+=($!)
# SOCKS5 with a user and a password, CONNECT only. Each connection has a
# number: logins.log gets "login <n>" when it logs in, and "connect <n>" when
# it asks for a CONNECT.
python3 - "${UP_PORT}" "${PROXY_USER}" "${PROXY_PASS}" "${WORK}/logins.log" >"${WORK}/upstream.log" 2>&1 <<'PY' &
import itertools, socket, struct, sys, threading
port, user, password, log = int(sys.argv[1]), sys.argv[2].encode(), sys.argv[3].encode(), sys.argv[4]
numbers, lock = itertools.count(1), threading.Lock()
def note(what, n):
    with lock, open(log, "a") as f:
        f.write("%s %d\n" % (what, n))
def exact(c, n):
    b = b""
    while len(b) < n:
        chunk = c.recv(n - len(b))
        if not chunk:
            raise ConnectionError
        b += chunk
    return b
def pump(a, b):
    try:
        while True:
            d = a.recv(65536)
            if not d:
                break
            b.sendall(d)
    except OSError:
        pass
    for s in (a, b):
        try:
            s.shutdown(socket.SHUT_RDWR)
        except OSError:
            pass
def serve(c, number):
    try:
        ver, n = exact(c, 2)
        if 2 not in exact(c, n):
            c.sendall(b"\x05\xff"); return
        c.sendall(b"\x05\x02")
        _, ulen = exact(c, 2); u = exact(c, ulen)
        plen, = exact(c, 1); p = exact(c, plen)
        if (u, p) != (user, password):
            c.sendall(b"\x01\x01"); return
        c.sendall(b"\x01\x00")
        note("login", number)
        _, cmd, _, atyp = exact(c, 4)
        note("connect", number)
        host = socket.inet_ntoa(exact(c, 4)) if atyp == 1 else exact(c, exact(c, 1)[0]).decode()
        port, = struct.unpack(">H", exact(c, 2))
        t = socket.create_connection((host, port))
        c.sendall(b"\x05\x00\x00\x01\x00\x00\x00\x00\x00\x00")
        threading.Thread(target=pump, args=(t, c), daemon=True).start()
        pump(c, t)
    except (ConnectionError, OSError):
        c.close()
srv = socket.create_server(("127.0.0.1", port))
while True:
    threading.Thread(target=serve, args=(srv.accept()[0], next(numbers)), daemon=True).start()
PY
PIDS+=($!)
for p in "${TARGET_PORT}" "${UP_PORT}"; do
	for _ in $(seq 1 50); do
		(: <"/dev/tcp/127.0.0.1/${p}") 2>/dev/null && break
		sleep 0.2
	done
done
: >"${WORK}/logins.log"

printf '# the gate'"'"'s alone\nhttp://127.0.0.1:9 name=other\nname=isp warm=2 | socks5://%s:%s@127.0.0.1:%s\n' \
	"${PROXY_USER}" "${PROXY_PASS}" "${UP_PORT}" >"${WORK}/secrets/upstreams"
chmod 0644 "${WORK}/secrets/upstreams"
"${ENGINE}" run -d --name "${CTR}" "${RUN_ARGS[@]}" --read-only -v "${WORK}/secrets:/run/secrets:ro" \
	-e PROXY_WARM_UPSTREAMS=/run/secrets/upstreams -e PROXY_WARM_PORT="${WARM_PORT}" -e PROXY_WARM_TYPO=1 \
	"${IMAGE}" >/dev/null
logins() { grep -c '^login ' "${WORK}/logins.log" || true; }
for _ in $(seq 1 50); do
	[ "$(logins)" -ge 2 ] && break
	sleep 0.2
done
logs="$("${ENGINE}" logs "${CTR}" 2>&1)"
expect_in "summary names the version" "${logs}" "proxy-warm = ${VERSION}"
expect_in "summary shows where the port leads" "${logs}" \
	":${WARM_PORT} <- line 3 (isp) socks5 127.0.0.1:${UP_PORT}, 2 kept ready"
expect_in "warns about an unknown PROXY_WARM_ name" "${logs}" "WARN: PROXY_WARM_TYPO is set"
[ "$(logins)" = 2 ] || fail "$(logins) logins before any client, not the 2 spares"
! grep -q '^connect ' "${WORK}/logins.log" || fail "a CONNECT reached the proxy before any client asked"
spares=" $(sed -n 's/^login //p' "${WORK}/logins.log" | tr '\n' ' ')"
echo "ok: two spares logged in before any client asked"

code="$(curl --noproxy '' -s -o /dev/null -w '%{http_code}' --max-time 10 \
	-x "socks5://127.0.0.1:${WARM_PORT}" "http://127.0.0.1:${TARGET_PORT}/generate_204" || true)"
[ "${code}" = 200 ] || fail "a request through the warm port answered ${code}, not 200"
expect_in "the request reached the target" "$(cat "${WORK}/httpd.log")" '"GET /generate_204 HTTP/1.1" 200'
# The CONNECT came on one of the spares, and another connection logged in to
# replace it.
for _ in $(seq 1 50); do
	[ "$(logins)" -ge 3 ] && break
	sleep 0.2
done
used="$(sed -n 's/^connect //p' "${WORK}/logins.log")"
[ "$(printf '%s\n' "${used}" | grep -c .)" = 1 ] || fail "one request made CONNECTs on connections '${used}', not one"
case "${spares}" in *" ${used} "*) ;; *) fail "the CONNECT came on connection ${used}, not a spare (${spares})" ;; esac
[ "$(logins)" = 3 ] || fail "$(logins) logins after one request, not 3"
case "${spares}" in *" $(sed -n 's/^login //p' "${WORK}/logins.log" | tail -1) "*) fail "no new connection replaced the spare" ;; esac
echo "ok: the request went out on a spare logged in before it, which a new connection replaced"

"${ENGINE}" exec "${CTR}" /usr/local/bin/proxy-warm healthcheck || fail "the healthcheck fails on a running container"
echo "ok: the healthcheck passes"
top="$("${ENGINE}" top "${CTR}" user args)"
expect_in "PID 1 is proxy-warm, as nonroot (65532)" "${top}" "/usr/local/bin/proxy-warm run"
case "$(printf '%s\n' "${logs}"; "${ENGINE}" logs "${CTR}" 2>&1)" in
*"${PROXY_PASS}"*) fail "the password is in the log" ;;
esac
echo "ok: the password is nowhere in the log"

start=$(date +%s)
"${ENGINE}" stop -t 10 "${CTR}" >/dev/null
rc="$("${ENGINE}" inspect --format '{{.State.ExitCode}}' "${CTR}")"
[ "$(($(date +%s) - start))" -lt 5 ] || fail "stop took the kill, not SIGTERM"
[ "${rc}" = 0 ] || fail "stopped with exit ${rc}, not 0"
echo "ok: SIGTERM stops it at once, exit 0"

echo "PASS: ${IMAGE}"
