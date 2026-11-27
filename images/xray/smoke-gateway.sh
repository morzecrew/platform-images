#!/usr/bin/env bash
# The gateway end to end, for smoke.sh: a dotdash relay of this image in
# front of two stand-in server groups, a and b, each an Xray of this image
# with its own exit and a stand-in for its internal endpoint, and devices of
# each group behind the relay. See images/xray/README.md, "A dotdash relay's
# gateway".
#
# Everything shares one pod with no network but its loopback, so nothing is
# published and the ports are the pod's own. A Python container serves the
# exits (exit-A, exit-B), each group's list and subscriptions (as a server's
# Caddy would at its internal name) and the REALITY target, and is the
# tester: busybox wget through a proxy prints the body.
#
#   smoke-gateway.sh <image-ref>
# The JSON below spells "$gateway" and the rest literally.
# shellcheck disable=SC2016
set -euo pipefail
IMAGE="${1:?usage: smoke-gateway.sh <image-ref>}"
ENGINE="${ENGINE:-podman}"
PYTHON="${PYTHON:-docker.io/library/python:3-alpine}"
POD="smoke-xray-gw-$$"
WORK="$(mktemp -d)"

cleanup() {
	[ -z "${KEEP:-}" ] || return 0
	"${ENGINE}" pod rm -f -t 0 "${POD}" >/dev/null 2>&1 || true
	rm -rf "${WORK}"
}
trap cleanup EXIT

fail() {
	echo "FAIL: $*"
	for c in relay srv-a srv-b client; do
		echo "--- ${c}"
		"${ENGINE}" logs "${POD}-${c}" 2>&1 | grep -v " accepted " | tail -15 || true
	done
	exit 1
}

# Ports inside the pod.
TLS=9443 EXIT_A=9001 EXIT_B=9002 SUB_A=9011 SUB_B=9012 SRV_A=9101 SRV_B=9102
RELAY=9201 RELAY_HY2=9202
# The client's inbounds: a device and a way each.
PA_R=9301 PA_H=9302 PB_R=9303 PB_H=9304 LB_R=9305 DUP_R=9306 STRANGER_R=9307

xray_cli() { # <secrets dir> <args...>: a command of the image's, offline
	local dir="$1"
	shift
	"${ENGINE}" run --rm --network none --userns keep-id:uid=65532,gid=65532 -v "${dir}:/run/secrets:ro" "${IMAGE}" "$@"
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
printf '{"$gateway": {"servers": "/run/secrets/servers", "probeURL": "http://127.0.0.1:%s/"}}\n' "${EXIT_A}" >"${WORK}/relay/gateway.json"
cat >"${WORK}/relay/xray.json" <<-EOF
	{"log": {"loglevel": "warning"},
	 "api": {"tag": "api", "listen": "127.0.0.1:10085", "services": ["HandlerService", "RoutingService", "StatsService"]},
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
	import functools, http.server, socket, ssl, threading, time
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
	serve(9001, type("A", (Exit,), {"body": b"exit-A"}))
	serve(9002, type("B", (Exit,), {"body": b"exit-B"}))
	serve(9011, functools.partial(Files, directory="/w/a"))
	serve(9012, functools.partial(Files, directory="/w/b"))
	ctx = ssl.SSLContext(ssl.PROTOCOL_TLS_SERVER)
	ctx.load_cert_chain("/w/tls.crt", "/w/tls.key")
	ctx.set_alpn_protocols(["h2", "http/1.1"])
	tls = socket.create_server(("127.0.0.1", 9443))
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

# --- the pod -------------------------------------------------------------------

"${ENGINE}" pod create --name "${POD}" --network none --userns keep-id:uid=65532,gid=65532 >/dev/null
"${ENGINE}" run -d --pod "${POD}" --name "${POD}-py" --user 65532:65532 -v "${WORK}/w:/w:ro" \
	"${PYTHON}" python -u /w/stand-ins.py >/dev/null
xray_in_pod() { # <name> <config dir> [run args...]
	local name="$1" conf="$2"
	shift 2
	"${ENGINE}" run -d --pod "${POD}" --name "${POD}-${name}" --read-only --tmpfs /run/xray:rw,mode=1777 \
		-v "${conf}:/etc/xray:ro" -v "${S}:/run/secrets:ro" "$@" "${IMAGE}" >/dev/null
}
xray_in_pod srv-a "${WORK}/srv-a"
xray_in_pod srv-b "${WORK}/srv-b"
xray_in_pod client "${WORK}/client"
xray_in_pod relay "${WORK}/relay" --tmpfs /run/gateway:rw,mode=1777 -e XRAY_GATEWAY_INTERVAL=2s

# get <port> [url]: the body through that client inbound, or why there is none.
get() {
	"${ENGINE}" exec -e "http_proxy=http://127.0.0.1:$1" "${POD}-py" \
		wget -qO- -T 8 "${2:-http://exit.test/}" 2>&1 | tr -d '\r' | head -c 200 || true
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
# refused <label> <port> [url]: nothing comes back, the body is not an exit's.
refused() {
	local out
	out="$(get "$2" "${3:-}")"
	case "${out}" in
	exit-* | subscription* | "# dotdash"*) fail "$1 -- got '${out}'" ;;
	*) echo "ok: $1 (${out:0:60})" ;;
	esac
}
status() { "${ENGINE}" exec "${POD}-relay" /usr/local/bin/xray-entrypoint gateway-status 2>&1 || true; }
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
starts() { "${ENGINE}" logs "${POD}-relay" 2>&1 | grep -c "Xray .* started" || true; }

# --- the checks ----------------------------------------------------------------

wait_status "both groups live through the relay's own tunnels" "gateway: last round"
out="$(status)"
case "${out}" in *"$(row a live "a.test ok")"*"$(row b live "b.test ok")"*) echo "ok: gateway-status: a and b live, a line each" ;;
*) fail "gateway-status:
${out}" ;;
esac
code=0
"${ENGINE}" exec "${POD}-relay" /usr/local/bin/xray-entrypoint gateway-status >/dev/null 2>&1 || code=$?
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
out="$(sub 0123456789ab0123456789abcdef0123)"
case "${out}" in subscription*) fail "a prefix no list has got '${out}'" ;; esac
echo "ok: a token whose prefix no list has gets nothing (${out:0:40})"

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
"${ENGINE}" exec -d -e "http_proxy=http://127.0.0.1:${PA_R}" "${POD}-py" sh -c 'wget -qO /tmp/slow http://exit.test/slow' >/dev/null
sleep 4
before="$("${ENGINE}" exec "${POD}-py" sh -c 'wc -c </tmp/slow')"
[ "${before}" -gt 0 ] || fail "the download through phone@a did not start"
list "${LIST_A}"
for _ in $(seq 1 20); do
	[ "$(starts)" -ge 2 ] && break
	sleep 1
done
[ "$(starts)" -ge 2 ] || fail "phone@a was removed while connected, and Xray did not restart"
case "$("${ENGINE}" logs "${POD}-relay" 2>&1)" in
*"phone@a removed while connected: restarting Xray"*) ;;
*) fail "the restart did not say why" ;;
esac
echo "ok: phone@a removed while connected restarts Xray"
sleep 4
after="$("${ENGINE}" exec "${POD}-py" sh -c 'wc -c </tmp/slow')"
sleep 3
later="$("${ENGINE}" exec "${POD}-py" sh -c 'wc -c </tmp/slow')"
[ "${after}" = "${later}" ] || fail "phone@a's download kept flowing after the restart (${after}, then ${later} bytes)"
echo "ok: phone@a's open download is cut (${before} bytes before, ${after} after)"
refused "phone@a by REALITY after its removal" "${PA_R}"
refused "phone@a by Hysteria2 after its removal" "${PA_H}"
expect_get "phone@b unaffected, from the restart's config" "${PB_R}" exit-B
expect_get "phone@b by Hysteria2 too" "${PB_H}" exit-B

# Group b's only server down: b gets nothing, never a's exit; a is unaffected.
list "${LIST_A}" "${PHONE_A} phone ${TOK_PA:0:12}"
expect_get "phone@a back in" "${PA_R}" exit-A
"${ENGINE}" stop -t 1 "${POD}-srv-b" >/dev/null
wait_status "b down, with its devices kept from its last list" "$(row b down "b.test down")"
refused "phone@b by REALITY with b down" "${PB_R}"
refused "phone@b by Hysteria2 with b down" "${PB_H}"
out="$(sub "${TOK_TB}")"
case "${out}" in subscription*) fail "tablet@b's subscription with b down: '${out}'" ;; esac
echo "ok: tablet@b's subscription with b down gets nothing"
expect_get "phone@a still reaches exit A" "${PA_R}" exit-A

# b down before the relay's first round: b's devices are not even let in.
"${ENGINE}" restart -t 2 "${POD}-relay" >/dev/null
wait_status "after a restart with b down: a live" "$(row a live "a.test ok")"
refused "phone@b after a restart with b down" "${PB_R}"
expect_get "phone@a after a restart with b down" "${PA_R}" exit-A
"${ENGINE}" start "${POD}-srv-b" >/dev/null
expect_get "phone@b once b is back" "${PB_R}" exit-B

# A server that answers it has no list for this relay: b's devices go.
mv "${LIST_B}" "${LIST_B}.gone"
wait_status "b refused, with no list for the relay" "$(row b refused "b.test refused (no list for this relay (404))")"
sleep 3
refused "phone@b once b has no list for the relay" "${PB_R}"
mv "${LIST_B}.gone" "${LIST_B}"
expect_get "phone@b once its list is back" "${PB_R}" exit-B

echo "PASS: xray gateway smoke (${IMAGE})"
