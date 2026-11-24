#!/usr/bin/env bash
# Smoke test for the openflux image. See images/openflux/README.md.
#
# No internet and no third-party service: an exit and a client meet over the
# direct transport on the host's network, as uid 65532 under a read-only root
# with every capability dropped. What it shows:
# - the image: uid 65532, the binary as entrypoint, its state directory, and
#   OpenFlux's licence beside the binary;
# - a link made with --make-link reads back with --parse-link;
# - through the client's SOCKS5, a request reaches a target over the exit, and
#   the exit's TCP and UDP both leave through its --upstream-proxy, which
#   logs them (patches/exit-udp-socks5.patch);
# - an upstream that refuses UDP ASSOCIATE gets the exit's UDP dropped, never
#   sent around it.
# Targets listen on this machine's own address, not loopback: the client's
# stack keeps 127.0.0.1 to itself.
set -euo pipefail
IMAGE="${1:?usage: smoke.sh <image-ref>}"
ENGINE="${ENGINE:-podman}"
HERE="$(cd "$(dirname "$0")" && pwd)"
CTR="smoke-openflux-$$"
WORK="$(mktemp -d)"
BASE=$((20000 + $$ % 20000))
HTTP_PORT=${BASE} ECHO_PORT=$((BASE + 1)) DIRECT_PORT=$((BASE + 2)) SOCKS_PORT=$((BASE + 3))
UP_PORT=$((BASE + 4)) TCPONLY_PORT=$((BASE + 5))
PIDS=()

cleanup() {
	local c
	for c in "${CTR}-exit" "${CTR}-client"; do
		"${ENGINE}" rm -f "${c}" >/dev/null 2>&1 || true
	done
	[ "${#PIDS[@]}" = 0 ] || kill "${PIDS[@]}" 2>/dev/null || true
	rm -rf "${WORK}"
}
trap cleanup EXIT

fail() {
	echo "FAIL: $*" >&2
	exit 1
}

# shellcheck disable=SC2054 # the commas are the option's own
RUN_ARGS=(-d --network host --read-only --cap-drop ALL --security-opt no-new-privileges
	--tmpfs /tmp --userns keep-id:uid=65532,gid=65532 -v "${WORK}/k:/k:ro")

# --- 1. the image -------------------------------------------------------------

cfg="$("${ENGINE}" image inspect --format \
	'user={{.Config.User}} entrypoint={{.Config.Entrypoint}} env={{.Config.Env}}' "${IMAGE}")"
case "${cfg}" in *"user=65532:65532 entrypoint=[/usr/local/bin/openflux] "*) ;; *) fail "image config: ${cfg}" ;; esac
case "${cfg}" in *HOME=/var/lib/openflux*) ;; *) fail "HOME is not /var/lib/openflux: ${cfg}" ;; esac
echo "ok: uid 65532, the binary as entrypoint, HOME in its state directory"
"${ENGINE}" create --name "${CTR}-exit" "${IMAGE}" >/dev/null
files="$("${ENGINE}" export "${CTR}-exit" | tar -tvf -)"
"${ENGINE}" rm "${CTR}-exit" >/dev/null
line="$(printf '%s\n' "${files}" | awk '$NF == "var/lib/openflux/"')"
case "${line}" in "drwx------ 65532/65532 "*) ;; *) fail "/var/lib/openflux is not 65532's, mode 0700: ${line}" ;; esac
echo "ok: /var/lib/openflux is 65532's, mode 0700"
for f in LICENSE COPYRIGHT NOTICE; do
	printf '%s\n' "${files}" | awk '{ print $NF }' | grep -qx "usr/local/share/doc/openflux/${f}" ||
		fail "${f} is not in /usr/local/share/doc/openflux"
done
echo "ok: OpenFlux's licence and notices are in /usr/local/share/doc/openflux"

# --- 2. links -----------------------------------------------------------------

# Both answer in JSON: the link, and the profile it holds.
made="$(printf '{"name":"smoke","negotiate":true,"secret":"%s","transports":[{"type":"direct","dial":"127.0.0.1:1"}]}' \
	"$(printf '%048d' 7)" | "${ENGINE}" run --rm -i "${IMAGE}" --make-link -)" || fail "--make-link: ${made}"
link="$(printf '%s' "${made}" | python3 -c 'import json, sys; print(json.load(sys.stdin)["link"])')"
case "${link}" in openflux://v1/*) ;; *) fail "--make-link made: ${link}" ;; esac
parsed="$("${ENGINE}" run --rm "${IMAGE}" --parse-link "${link}")" || fail "--parse-link: ${parsed}"
case "${parsed}" in *'"name":"smoke"'*'"dial":"127.0.0.1:1"'*) ;; *) fail "--parse-link read back: ${parsed}" ;; esac
echo "ok: a link from --make-link reads back with --parse-link"

# --- 3. targets and upstreams on this machine ---------------------------------

HOST_IP="$(python3 -c 'import socket; s = socket.socket(socket.AF_INET, socket.SOCK_DGRAM); s.connect(("192.0.2.1", 9)); print(s.getsockname()[0])')"
case "${HOST_IP}" in 127.*) fail "no address but loopback for the targets" ;; esac
mkdir -p "${WORK}/www" "${WORK}/k" "${WORK}/state"
printf 'ok\n' >"${WORK}/www/ok"
python3 -m http.server "${HTTP_PORT}" --bind "${HOST_IP}" --directory "${WORK}/www" >"${WORK}/http.log" 2>&1 &
PIDS+=($!)
python3 -c '
import socket, sys
s = socket.socket(socket.AF_INET, socket.SOCK_DGRAM)
s.bind((sys.argv[1], int(sys.argv[2])))
while True:
    d, a = s.recvfrom(65535)
    print("echo", len(d), flush=True)
    s.sendto(d, a)' "${HOST_IP}" "${ECHO_PORT}" >"${WORK}/echo.log" 2>&1 &
PIDS+=($!)
python3 "${HERE}/smoke-socks.py" server "${UP_PORT}" udp >"${WORK}/up.log" 2>&1 &
PIDS+=($!)
python3 "${HERE}/smoke-socks.py" server "${TCPONLY_PORT}" noudp >"${WORK}/tcponly.log" 2>&1 &
PIDS+=($!)
KEY="$(python3 -c 'import secrets; print(secrets.token_hex(24))')"
printf '%s\n' "${KEY}" >"${WORK}/k/secret"
chmod 0644 "${WORK}/k/secret"
cat >"${WORK}/k/exit.conf" <<EOF
[Interface]
Role = exit
Mode = l4
EncryptionKeyFile = /k/secret
CookieStore = /var/lib/openflux/cookies.json

[Transport direct]
Type = direct
Priority = 50
Listen = 127.0.0.1:${DIRECT_PORT}
EOF
cat >"${WORK}/k/client.conf" <<EOF
[Interface]
Role = client
Inbound = socks5
Socks5 = 127.0.0.1:${SOCKS_PORT}
EncryptionKeyFile = /k/secret
CookieStore = /tmp/cookies.json

[Transport direct]
Type = direct
Priority = 50
Dial = 127.0.0.1:${DIRECT_PORT}
EOF

# exit <upstream port>: (re)starts the exit, its upstream there.
exit_node() {
	"${ENGINE}" rm -f "${CTR}-exit" >/dev/null 2>&1 || true
	"${ENGINE}" run --name "${CTR}-exit" "${RUN_ARGS[@]}" -v "${WORK}/state:/var/lib/openflux" "${IMAGE}" \
		--config /k/exit.conf --upstream-proxy="127.0.0.1:$1" >/dev/null
}
get() {
	curl -s --max-time 10 --noproxy '' -x "socks5h://127.0.0.1:${SOCKS_PORT}" "http://${HOST_IP}:${HTTP_PORT}/ok" || true
}
wait_up() {
	for _ in $(seq 1 40); do
		[ "$(get)" = ok ] && return 0
		sleep 1
	done
	"${ENGINE}" logs "${CTR}-exit" 2>&1 | tail -15
	"${ENGINE}" logs "${CTR}-client" 2>&1 | tail -15
	fail "nothing through the client after 40 s"
}
udp_ping() { python3 "${HERE}/smoke-socks.py" udp "${SOCKS_PORT}" "${HOST_IP}" "${ECHO_PORT}" || true; }

# --- 4. through an upstream that takes UDP ------------------------------------

exit_node "${UP_PORT}"
"${ENGINE}" run --name "${CTR}-client" "${RUN_ARGS[@]}" "${IMAGE}" --config /k/client.conf >/dev/null
wait_up
echo "ok: a request through the client's SOCKS5 reached the target over the exit"
grep -qx "tcp ${HOST_IP} ${HTTP_PORT}" "${WORK}/up.log" || fail "the exit's TCP did not go through the upstream: $(cat "${WORK}/up.log")"
echo "ok: the exit's TCP left through the upstream"
out="$(udp_ping)"
[ "${out}" = "reply ping" ] || fail "UDP through the client: ${out}"
grep -qx "udp ${HOST_IP} ${ECHO_PORT}" "${WORK}/up.log" || fail "the exit's UDP did not go through the upstream: $(cat "${WORK}/up.log")"
echo "ok: the exit's UDP left through the upstream's UDP ASSOCIATE, and the reply came back"

# --- 5. an upstream that refuses UDP ------------------------------------------

exit_node "${TCPONLY_PORT}"
wait_up
grep -qx "tcp ${HOST_IP} ${HTTP_PORT}" "${WORK}/tcponly.log" || fail "the exit's TCP did not go through the TCP-only upstream"
echoes=$(grep -c '^echo' "${WORK}/echo.log" || true)
out="$(udp_ping)"
[ "${out}" = "no reply" ] || fail "UDP with a TCP-only upstream: ${out}"
sleep 1
[ "$(grep -c '^echo' "${WORK}/echo.log" || true)" = "${echoes}" ] || fail "the exit sent UDP around the upstream that refused it"
echo "ok: an upstream that refuses UDP ASSOCIATE gets the exit's UDP dropped, nothing sent around it"

# --- 6. no key in any log -----------------------------------------------------

logs="$("${ENGINE}" logs "${CTR}-exit" 2>&1)$("${ENGINE}" logs "${CTR}-client" 2>&1)"
case "${logs}" in *"${KEY}"*) fail "the key appears in a log" ;; esac
echo "ok: the key is in no log"
echo "PASS: openflux smoke (${IMAGE})"
