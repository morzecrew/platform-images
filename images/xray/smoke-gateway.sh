#!/usr/bin/env bash
# The gateway end to end, for smoke.sh: a dotdash relay of this image in
# front of two stand-in server groups, a and b, each an Xray of this image
# with its own exit and a stand-in for its internal endpoint, and devices of
# each group behind the relay. See images/xray/README.md, "A dotdash relay's
# gateway".
#
# As smoke.sh, rootless Podman on the host's network, every listener on
# loopback, and nothing but the image under test: Python on the host serves
# the exits (exit-A, exit-B), each group's list and subscriptions (as a
# server's Caddy would at its internal name) and the REALITY target, and
# curl is the tester. The gateway's own fixed ports, 10810, 10811 and 10900
# up, must be free on the host's loopback.
#
#   smoke-gateway.sh <image-ref>
# The JSON below spells "$gateway" and the rest literally.
# shellcheck disable=SC2016
set -euo pipefail
IMAGE="${1:?usage: smoke-gateway.sh <image-ref>}"
ENGINE="${ENGINE:-podman}"
CTR="smoke-xray-gw-$$"
WORK="$(mktemp -d)"
PIDS=()

cleanup() {
	[ -z "${KEEP:-}" ] || return 0
	local c
	# One name a call: given a name that does not exist, podman 4.9 removes
	# none of the others.
	for c in relay srv-a srv-b client; do
		"${ENGINE}" rm -f -t 0 "${CTR}-${c}" >/dev/null 2>&1 || true
	done
	[ "${#PIDS[@]}" = 0 ] || kill "${PIDS[@]}" 2>/dev/null || true
	rm -rf "${WORK}"
}
trap cleanup EXIT

fail() {
	echo "FAIL: $*"
	for c in relay srv-a srv-b client; do
		echo "--- ${c}"
		"${ENGINE}" logs "${CTR}-${c}" 2>&1 | grep -v " accepted " | tail -15 || true
	done
	exit 1
}

# On loopback, out of smoke.sh's range (20000 up to 40017).
BASE=$((40100 + $$ % 15000))
TLS=${BASE} EXIT_A=$((BASE + 1)) EXIT_B=$((BASE + 2)) SUB_A=$((BASE + 3)) SUB_B=$((BASE + 4))
SRV_A=$((BASE + 5)) SRV_B=$((BASE + 6)) RELAY=$((BASE + 7)) RELAY_HY2=$((BASE + 8)) API=$((BASE + 9))
# The client's inbounds: a device and a way each.
PA_R=$((BASE + 10)) PA_H=$((BASE + 11)) PB_R=$((BASE + 12)) PB_H=$((BASE + 13)) LB_R=$((BASE + 14))
DUP_R=$((BASE + 15)) STRANGER_R=$((BASE + 16))
# shellcheck disable=SC2054 # the commas are the option's own
RUN_ARGS=(--network host --userns keep-id:uid=65532,gid=65532)

xray_cli() { # <secrets dir> <args...>: a command of the image's, offline
	local dir="$1"
	shift
	"${ENGINE}" run --rm "${RUN_ARGS[@]}" -v "${dir}:/run/secrets:ro" "${IMAGE}" "$@"
}
hex() { python3 -c 'import os, sys; print(os.urandom(int(sys.argv[1])).hex())' "$1"; }
b64key() { python3 -c 'import base64, os; print(base64.urlsafe_b64encode(os.urandom(32)).decode().rstrip("="))'; }
sha32() { printf '%s' "$1" | sha256sum | cut -c1-32; }

# --- the keys, the lists and the configs ---------------------------------------

S="${WORK}/secrets"
mkdir -p "${S}" "${WORK}/w/a" "${WORK}/w/b" "${WORK}/relay" "${WORK}/srv-a" "${WORK}/srv-b" "${WORK}/client"
for m in a b r; do
	b64key >"${S}/${m}_key"
done
hex 32 >"${S}/a_seed"
hex 32 >"${S}/b_seed"
NONCE="$(hex 8)"
chmod 0400 "${S}/"*
PBK_A="$(xray_cli "${S}" reality-password /run/secrets/a_key)"
PBK_B="$(xray_cli "${S}" reality-password /run/secrets/b_key)"
PBK_R="$(xray_cli "${S}" reality-password /run/secrets/r_key)"
# The relay's id on each server, which each server derives from its own
# seed, the relay's name and its nonce.
RID_A="$(xray_cli "${S}" relay-id /run/secrets/a_seed r1 "${NONCE}")"
RID_B="$(xray_cli "${S}" relay-id /run/secrets/b_seed r1 "${NONCE}")"
[ "${RID_A}" != "${RID_B}" ] || fail "the relay has one id on two groups"
RELAY_LINE="relay/1 r1 ${NONCE} relay.test relay.test ${PBK_R} 0a1b none"

openssl req -x509 -newkey ec -pkeyopt ec_paramgen_curve:prime256v1 -nodes -days 1 \
	-keyout "${S}/tls.key" -out "${S}/tls.crt" -subj /CN=relay.test \
	-addext subjectAltName=DNS:relay.test 2>/dev/null
chmod 0400 "${S}/tls.key" "${S}/tls.crt"
cp "${S}/tls.key" "${S}/tls.crt" "${WORK}/w/"

uuid() { python3 -c 'import uuid; print(uuid.uuid4())'; }
PHONE_A="$(uuid)" PHONE_B="$(uuid)" TABLET_B="$(uuid)" LAPTOP_B="$(uuid)" STRANGER="$(uuid)"
# PHONE_B but for bytes 6 and 7, which Xray ignores: one id to it.
DUP="${PHONE_B:0:14}4fff${PHONE_B:18}"
TOK_PA="$(hex 16)" TOK_TB="$(hex 16)"
LIST_A="${WORK}/w/a/$(sha32 "${RID_A}:list")"
LIST_B="${WORK}/w/b/$(sha32 "${RID_B}:list")"
list() { # <file> <lines...>: a server's list for the relay
	local f="$1"
	shift
	{
		echo "# dotdash relay list v1"
		[ $# = 0 ] || printf '%s\n' "$@"
	} >"${f}.new"
	mv "${f}.new" "${f}"
}
list "${LIST_A}" "${PHONE_A} phone ${TOK_PA:0:12}"
list "${LIST_B}" "${PHONE_B} phone" "${TABLET_B} tablet ${TOK_TB:0:12}"
echo "subscription of phone@a" >"${WORK}/w/a/${TOK_PA}"
echo "subscription of tablet@b" >"${WORK}/w/b/${TOK_TB}"
echo '{"subscription_of": "tablet@b"}' >"${WORK}/w/b/${TOK_TB}.json"
chmod -R a+rX "${WORK}/w"

# A stand-in server: its devices plus the relay, by the id it derives
# ($vlessClients's object form, the relay line written in as a template
# writes a parameter); its internal names for relays alone; everything else
# to its exit.
server() { # <group> <port> <exit port> <sub port>
	echo "0f0e0d0c-0b0a-4908-8706-050403020100 own-device" >"${S}/$1_clients"
	chmod 0400 "${S}/$1_clients"
	cat >"${WORK}/srv-$1/config.json" <<-EOF
		{"log": {"loglevel": "warning"},
		 "inbounds": [{"tag": "in", "listen": "127.0.0.1", "port": $2, "protocol": "vless",
		   "settings": {"clients": {"\$vlessClients": {"devices": "/run/secrets/$1_clients", "relays": ["${RELAY_LINE}"], "seed": "/run/secrets/$1_seed"}},
		                "flow": "xtls-rprx-vision", "decryption": "none"},
		   "streamSettings": {"network": "raw", "security": "reality", "realitySettings": {"target": "127.0.0.1:${TLS}", "serverNames": ["$1.test"],
		     "privateKey": {"\$file": "/run/secrets/$1_key"}, "shortIds": ["0a1b"]}}}],
		 "outbounds": [
		   {"tag": "direct", "protocol": "freedom", "settings": {"redirect": "127.0.0.1:$3", "finalRules": [{"action": "allow"}]}},
		   {"tag": "sub", "protocol": "freedom", "settings": {"redirect": "127.0.0.1:$4", "finalRules": [{"action": "allow"}]}},
		   {"tag": "block", "protocol": "blackhole"}],
		 "routing": {"rules": [
		   {"domain": ["domain:sub.dotdash.internal"], "user": ["regexp:^relay-"], "outboundTag": "sub"},
		   {"domain": ["domain:sub.dotdash.internal"], "outboundTag": "block"},
		   {"network": "tcp,udp", "outboundTag": "direct"}]}}
	EOF
}
server a "${SRV_A}" "${EXIT_A}" "${SUB_A}"
server b "${SRV_B}" "${EXIT_B}" "${SUB_B}"

# The relay: its servers secret, a server/1 line per group, as each one's
# relay-config prints it; $gateway; and its device inbounds.
printf '%s\n' "# server/1 lines" \
	"server/1 a a.test ${SRV_A} ${PBK_A} 0a1b none ${RID_A} address=127.0.0.1" \
	"server/1 b b.test ${SRV_B} ${PBK_B} 0a1b none ${RID_B} address=127.0.0.1" >"${S}/servers"
chmod 0400 "${S}/servers"
printf '{"$gateway": {"servers": "/run/secrets/servers", "probeURL": "http://127.0.0.1:%s/", "listen": "127.0.0.1"}}\n' "${EXIT_A}" >"${WORK}/relay/gateway.json"
cat >"${WORK}/relay/xray.json" <<-EOF
	{"log": {"loglevel": "warning"},
	 "api": {"tag": "api", "listen": "127.0.0.1:${API}", "services": ["HandlerService", "RoutingService", "StatsService"]},
	 "stats": {}, "policy": {"levels": {"0": {"statsUserOnline": true}}},
	 "inbounds": [
	  {"tag": "devices", "listen": "127.0.0.1", "port": ${RELAY}, "protocol": "vless",
	   "settings": {"clients": {"\$gatewayClients": "vless"}, "flow": "xtls-rprx-vision", "decryption": "none"},
	   "streamSettings": {"network": "raw", "security": "reality", "realitySettings": {"target": "127.0.0.1:${TLS}", "serverNames": ["relay.test"],
	     "privateKey": {"\$file": "/run/secrets/r_key"}, "shortIds": ["0a1b"]}}},
	  {"tag": "devices-hy2", "listen": "127.0.0.1", "port": ${RELAY_HY2}, "protocol": "hysteria",
	   "settings": {"version": 2, "users": {"\$gatewayClients": "hysteria"}},
	   "streamSettings": {"network": "hysteria", "security": "tls",
	     "tlsSettings": {"alpn": ["h3"], "certificates": [{"certificateFile": "/run/secrets/tls.crt", "keyFile": "/run/secrets/tls.key"}]},
	     "hysteriaSettings": {"version": 2, "udpIdleTimeout": 60}}}]}
EOF

# The devices: an http inbound each, through the relay by REALITY or
# Hysteria2, from 127.0.0.2: Xray counts no user online from 127.0.0.1, and
# the agent tells a removed device still connected by that count.
reality() { # <tag> <id>
	printf '{"tag": "%s", "sendThrough": "127.0.0.2", "protocol": "vless", "settings": {"address": "127.0.0.1", "port": %s, "id": "%s", "encryption": "none", "flow": "xtls-rprx-vision"}, "streamSettings": {"network": "raw", "security": "reality", "realitySettings": {"serverName": "relay.test", "fingerprint": "chrome", "password": "%s", "shortId": "0a1b"}}}' \
		"$1" "${RELAY}" "$2" "${PBK_R}"
}
hy2() { # <tag> <id>
	printf '{"tag": "%s", "sendThrough": "127.0.0.2", "protocol": "hysteria", "settings": {"version": 2, "address": "127.0.0.1", "port": %s}, "streamSettings": {"network": "hysteria", "security": "tls", "tlsSettings": {"serverName": "relay.test", "alpn": ["h3"], "certificates": [{"usage": "verify", "certificateFile": "/run/secrets/tls.crt"}]}, "hysteriaSettings": {"version": 2, "auth": "%s"}}}' \
		"$1" "${RELAY_HY2}" "$2"
}
ins="" outs="" rules=""
way() { # <port> <outbound json>
	local tag
	tag="$(printf '%s' "$2" | python3 -c 'import json, sys; print(json.load(sys.stdin)["tag"])')"
	ins+="${ins:+,}{\"tag\": \"${tag}\", \"listen\": \"127.0.0.1\", \"port\": $1, \"protocol\": \"http\"}"
	outs+="${outs:+,}$2"
	rules+="${rules:+,}{\"inboundTag\": [\"${tag}\"], \"outboundTag\": \"${tag}\"}"
}
way "${PA_R}" "$(reality pa-r "${PHONE_A}")"
way "${PA_H}" "$(hy2 pa-h "${PHONE_A}")"
way "${PB_R}" "$(reality pb-r "${PHONE_B}")"
way "${PB_H}" "$(hy2 pb-h "${PHONE_B}")"
way "${LB_R}" "$(reality lb-r "${LAPTOP_B}")"
way "${DUP_R}" "$(reality dup-r "${DUP}")"
way "${STRANGER_R}" "$(reality stranger-r "${STRANGER}")"
printf '{"log": {"loglevel": "warning"}, "inbounds": [%s], "outbounds": [%s], "routing": {"rules": [%s]}}\n' \
	"${ins}" "${outs}" "${rules}" >"${WORK}/client/config.json"
chmod -R a+rX "${WORK}/relay" "${WORK}/srv-a" "${WORK}/srv-b" "${WORK}/client"

cat >"${WORK}/w/stand-ins.py" <<-'PY'
	import functools, http.server, socket, ssl, sys, threading, time
	w, (tls_port, exit_a, exit_b, sub_a, sub_b) = sys.argv[1], map(int, sys.argv[2:])
	class Exit(http.server.BaseHTTPRequestHandler):
	    body = b""
	    def do_GET(s):
	        s.send_response(200)
	        s.send_header("Content-Type", "text/plain")
	        if s.path.startswith("/slow"):
	            s.end_headers()
	            for _ in range(90):
	                s.wfile.write(b"x"); s.wfile.flush(); time.sleep(1)
	            return
	        s.send_header("Content-Length", str(len(s.body))); s.end_headers(); s.wfile.write(s.body)
	    def log_message(s, *a): pass
	class Files(http.server.SimpleHTTPRequestHandler):
	    def log_message(s, *a): pass
	def serve(port, handler):
	    srv = http.server.ThreadingHTTPServer(("127.0.0.1", port), handler)
	    threading.Thread(target=srv.serve_forever, daemon=True).start()
	serve(exit_a, type("A", (Exit,), {"body": b"exit-A"}))
	serve(exit_b, type("B", (Exit,), {"body": b"exit-B"}))
	serve(sub_a, functools.partial(Files, directory=w + "/a"))
	serve(sub_b, functools.partial(Files, directory=w + "/b"))
	ctx = ssl.SSLContext(ssl.PROTOCOL_TLS_SERVER)
	ctx.load_cert_chain(w + "/tls.crt", w + "/tls.key")
	ctx.set_alpn_protocols(["h2", "http/1.1"])
	tls = socket.create_server(("127.0.0.1", tls_port))
	def handshake(c):
	    try:
	        with ctx.wrap_socket(c, server_side=True) as t:
	            t.recv(1)
	    except OSError:
	        pass
	while True:
	    threading.Thread(target=handshake, args=(tls.accept()[0],), daemon=True).start()
PY
chmod a+r "${WORK}/w/stand-ins.py"

# --- the run -------------------------------------------------------------------

python3 "${WORK}/w/stand-ins.py" "${WORK}/w" "${TLS}" "${EXIT_A}" "${EXIT_B}" "${SUB_A}" "${SUB_B}" >"${WORK}/stand-ins.log" 2>&1 &
PIDS+=($!)
for _ in $(seq 1 50); do
	[ "$(curl --noproxy '*' -s -m 2 "http://127.0.0.1:${EXIT_A}/" || true)" = exit-A ] && break
	sleep 0.2
done
[ "$(curl --noproxy '*' -s -m 2 "http://127.0.0.1:${EXIT_A}/" || true)" = exit-A ] || fail "the stand-ins did not start: $(cat "${WORK}/stand-ins.log")"
xray() { # <name> <config dir> [run args...]
	local name="$1" conf="$2"
	shift 2
	"${ENGINE}" run -d --name "${CTR}-${name}" "${RUN_ARGS[@]}" --read-only --tmpfs /run/xray:rw,mode=1777 \
		-v "${conf}:/etc/xray:ro" -v "${S}:/run/secrets:ro" "$@" "${IMAGE}" >/dev/null
}
xray srv-a "${WORK}/srv-a"
xray srv-b "${WORK}/srv-b"
xray client "${WORK}/client"
xray relay "${WORK}/relay" --tmpfs /run/gateway:rw,mode=1777 -e XRAY_GATEWAY_INTERVAL=2s

# probe <port> [url]: through that client inbound, curl's exit code, then the
# HTTP status, then the body.
probe() {
	local out rc=0
	out="$(curl --noproxy '' -s -m 8 -x "http://127.0.0.1:$1" -w '\n%{http_code}' "${2:-http://exit.test/}" 2>/dev/null)" || rc=$?
	printf '%s %s %s' "${rc}" "${out##*$'\n'}" "${out%$'\n'*}"
}
# get <port> [url]: the body through that client inbound, if a 200 brought one.
get() {
	local p
	p="$(probe "$@")"
	case "${p}" in "0 200 "*) printf '%s' "${p#0 200 }" ;; esac
}
# expect_get <label> <port> <body> [url], tried for up to 20 s.
expect_get() {
	local out=""
	for _ in $(seq 1 20); do
		out="$(get "$2" "${4:-}")"
		[ "${out}" = "$3" ] && {
			echo "ok: $1"
			return
		}
		sleep 1
	done
	fail "$1 -- expected '$3', got '${out}'"
}
# refused <label> <port> [url]: the request reached the client's inbound,
# and got no 200 and no body of an exit's, a subscription or a list. The
# control, exit A answering curl directly, shows curl and the stand-ins work.
refused() {
	local p rc
	[ "$(curl --noproxy '*' -s -m 5 "http://127.0.0.1:${EXIT_A}/" || true)" = exit-A ] ||
		fail "$1 -- the control, exit A asked directly, did not answer"
	p="$(probe "$2" "${3:-}")"
	rc="${p%% *}"
	case "${rc}" in 5 | 6 | 7) fail "$1 -- the probe never reached the client's inbound (curl exit ${rc})" ;; esac
	case "${p}" in
	"0 200 "* | *" exit-"* | *" subscription"* | *"# dotdash"*) fail "$1 -- got '${p}'" ;;
	*) echo "ok: $1 (curl exit ${rc}, HTTP ${p#* })" ;;
	esac
}
status() { "${ENGINE}" exec "${CTR}-relay" /usr/local/bin/xray-entrypoint gateway-status 2>&1 || true; }
# row <group> <state> <legs>: a group's line, as gateway-status prints it.
row() { printf '%-16s %-8s %s' "$1" "$2" "$3"; }
# wait_status <label> <needle>: gateway-status says it within 20 s.
wait_status() {
	local out=""
	for _ in $(seq 1 20); do
		out="$(status)"
		case "${out}" in *"$2"*)
			echo "ok: $1"
			return
			;;
		esac
		sleep 1
	done
	fail "$1 -- gateway-status lacks '$2':
${out}"
}
starts() { "${ENGINE}" logs "${CTR}-relay" 2>&1 | grep -c "Xray .* started" || true; }

# --- the checks ----------------------------------------------------------------

wait_status "both groups live through the relay's own tunnels" "gateway: last round"
out="$(status)"
case "${out}" in *"$(row a live "a.test ok")"*"$(row b live "b.test ok")"*) echo "ok: gateway-status: a and b live, a line each" ;;
*) fail "gateway-status:
${out}" ;;
esac
code=0
"${ENGINE}" exec "${CTR}-relay" /usr/local/bin/xray-entrypoint gateway-status >/dev/null 2>&1 || code=$?
[ "${code}" = 0 ] || fail "gateway-status exited ${code} with every round reaching the API"

# Devices added at run time through the API, each to its own group's exit,
# by REALITY and by Hysteria2, with no restart.
expect_get "phone@a through the relay by REALITY reaches exit A" "${PA_R}" exit-A
expect_get "phone@a through the relay by Hysteria2 reaches exit A" "${PA_H}" exit-A
expect_get "phone@b through the relay by REALITY reaches exit B" "${PB_R}" exit-B
expect_get "phone@b through the relay by Hysteria2 reaches exit B" "${PB_H}" exit-B
refused "a device in no list gets nothing" "${STRANGER_R}"
[ "$(starts)" = 1 ] || fail "Xray restarted to add devices"
echo "ok: added through the API, with no restart"

# A device may not ask for a server's internal names, which the server
# would hand the relay's own user.
refused "phone@a asking for a's list by its internal name" "${PA_R}" "http://list.sub.dotdash.internal/${LIST_A##*/}"

# Subscriptions through the relay's subscriptions inbound, as its Caddy sends
# them: by the token's first 12 hex characters.
sub() { get 10810 "http://${1:0:12}.sub.dotdash.internal/$1${2:-}"; }
expect_get "tablet@b's subscription, routed to b by its prefix" 10810 "subscription of tablet@b" "http://${TOK_TB:0:12}.sub.dotdash.internal/${TOK_TB}"
[ "$(sub "${TOK_TB}" .json)" = '{"subscription_of": "tablet@b"}' ] || fail "tablet@b's .json subscription"
[ "$(sub "${TOK_PA}")" = "subscription of phone@a" ] || fail "phone@a's subscription, routed to a"
echo "ok: phone@a's and tablet@b's subscriptions, each from its own group's server"
refused "a token whose prefix no list has" 10810 "http://0123456789ab.sub.dotdash.internal/0123456789ab0123456789abcdef0123"

# A device added on its server gets in within a round or two, no restart.
list "${LIST_B}" "${PHONE_B} phone" "${TABLET_B} tablet ${TOK_TB:0:12}" "${LAPTOP_B} laptop"
expect_get "laptop@b, added to b's list, gets in" "${LB_R}" exit-B
[ "$(starts)" = 1 ] || fail "Xray restarted to add laptop@b"

# An id two groups share, once bytes 6 and 7 are zeroed, goes from both.
list "${LIST_A}" "${PHONE_A} phone ${TOK_PA:0:12}" "${DUP} dup"
wait_status "phone@b and dup@a, one id to Xray, are named" "dropped: dup@a, phone@b: one id, once bytes 6 and 7 are zeroed"
sleep 3
refused "dup@a, dropped" "${DUP_R}"
refused "phone@b, dropped with it" "${PB_R}"
list "${LIST_A}" "${PHONE_A} phone ${TOK_PA:0:12}"
expect_get "phone@b back once the copy is gone" "${PB_R}" exit-B

# Removing a device that is connected: the API can't cut its connection, so
# the agent restarts Xray on the new lists.
curl --noproxy '' -sN -m 60 -x "http://127.0.0.1:${PA_R}" http://exit.test/slow >"${WORK}/slow" &
PIDS+=($!)
sleep 4
before="$(wc -c <"${WORK}/slow")"
[ "${before}" -gt 0 ] || fail "the download through phone@a did not start"
list "${LIST_A}"
for _ in $(seq 1 20); do
	[ "$(starts)" -ge 2 ] && break
	sleep 1
done
[ "$(starts)" -ge 2 ] || fail "phone@a was removed while connected, and Xray did not restart"
case "$("${ENGINE}" logs "${CTR}-relay" 2>&1)" in
*"phone@a removed while connected: restarting Xray"*) ;;
*) fail "the restart did not say why" ;;
esac
echo "ok: phone@a removed while connected restarts Xray"
sleep 4
after="$(wc -c <"${WORK}/slow")"
sleep 3
later="$(wc -c <"${WORK}/slow")"
[ "${after}" = "${later}" ] || fail "phone@a's download kept flowing after the restart (${after}, then ${later} bytes)"
echo "ok: phone@a's open download is cut (${before} bytes before, ${after} after)"
refused "phone@a by REALITY after its removal" "${PA_R}"
refused "phone@a by Hysteria2 after its removal" "${PA_H}"
expect_get "phone@b unaffected, from the restart's config" "${PB_R}" exit-B
expect_get "phone@b by Hysteria2 too" "${PB_H}" exit-B

# Group b's only server down: b gets nothing, never a's exit; a is unaffected.
list "${LIST_A}" "${PHONE_A} phone ${TOK_PA:0:12}"
expect_get "phone@a back in" "${PA_R}" exit-A
"${ENGINE}" stop -t 1 "${CTR}-srv-b" >/dev/null
wait_status "b down, with its devices kept from its last list" "$(row b down "b.test down")"
refused "phone@b by REALITY with b down" "${PB_R}"
refused "phone@b by Hysteria2 with b down" "${PB_H}"
refused "tablet@b's subscription with b down" 10810 "http://${TOK_TB:0:12}.sub.dotdash.internal/${TOK_TB}"
expect_get "phone@a still reaches exit A" "${PA_R}" exit-A

# b down before the relay's first round: b's devices are not even let in.
"${ENGINE}" restart -t 2 "${CTR}-relay" >/dev/null
wait_status "after a restart with b down: a live" "$(row a live "a.test ok")"
refused "phone@b after a restart with b down" "${PB_R}"
expect_get "phone@a after a restart with b down" "${PA_R}" exit-A
"${ENGINE}" start "${CTR}-srv-b" >/dev/null
expect_get "phone@b once b is back" "${PB_R}" exit-B

# A server that answers it has no list for this relay: b's devices go.
mv "${LIST_B}" "${LIST_B}.gone"
wait_status "b refused, with no list for the relay" "$(row b refused "b.test refused (no list for this relay (404))")"
sleep 3
refused "phone@b once b has no list for the relay" "${PB_R}"
mv "${LIST_B}.gone" "${LIST_B}"
expect_get "phone@b once its list is back" "${PB_R}" exit-B

echo "PASS: xray gateway smoke (${IMAGE})"
