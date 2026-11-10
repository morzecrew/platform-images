#!/usr/bin/env bash
# Smoke test for the openvpn image. See images/openvpn/README.md.
#
# No internet: the stand-in server is this image running openvpn in server
# mode, and the target is a listener on a second network that only
# the server joins, so a reply from it proves the traffic went through the
# tunnel. The target routes the tunnel's subnet back via the server instead of
# the server masquerading, which would need iptables. Rootless Podman does not
# route between its networks, so the client reaches the server through a
# gateway this way: the server answers on a second address, and the client's
# default route points at the server, as a host's points at its router. The
# kill switch then has a server behind a gateway to pin, as in production.
set -euo pipefail
IMAGE="${1:?usage: smoke.sh <image-ref>}"
ENGINE="${ENGINE:-podman}"
TAG="piovpn-smoke-$$"
WORK="$(mktemp -d)"
RIG="${TAG}-rig" FAR="${TAG}-far"
SRV="${TAG}-server" CLI="${TAG}-client" TGT="${TAG}-target"
# The server's address on the rig network, the address it answers OpenVPN on
# beyond it, its address on the far network, and the target's.
SRV_IP=10.231.77.50 SRV_VPN=10.231.99.50 SRV_FAR=10.231.78.50 TGT_IP=10.231.78.9
NET_ADMIN=(--cap-add NET_ADMIN --device /dev/net/tun)
# Read-only as Docker makes it: a tmpfs at /dev/shm and none at /tmp. Docker's
# --read-only is that already; Podman's adds tmpfs at /tmp and the like, so
# under Podman they are taken away and /dev/shm given back.
READ_ONLY=(--read-only)
# shellcheck disable=SC2054 # the commas are the option's own
[ "${ENGINE##*/}" != podman ] || READ_ONLY+=(--read-only-tmpfs=false --tmpfs /dev/shm:rw,size=1m)

cleanup() {
	"${ENGINE}" rm -f "${CLI}" "${SRV}" "${TGT}" >/dev/null 2>&1 || true
	"${ENGINE}" network rm "${RIG}" "${FAR}" >/dev/null 2>&1 || true
	rm -rf "${WORK}"
}
trap cleanup EXIT

fail() {
	echo "FAIL: $*" >&2
	for c in "${SRV}" "${CLI}"; do
		echo "--- ${c} logs:" >&2
		"${ENGINE}" logs "${c}" 2>&1 | tail -n 20 >&2 || true
	done
	exit 1
}

# --- 1. a throwaway PKI ------------------------------------------------------
# remote-cert-tls refuses a certificate without a key usage, so both carry one
# with the extended key usage of their side.
(
	cd "${WORK}"
	openssl req -x509 -newkey ec -pkeyopt ec_paramgen_curve:prime256v1 -nodes -days 1 \
		-subj /CN=smoke-ca -keyout ca.key -out ca.crt
	for side in server client; do
		openssl req -newkey ec -pkeyopt ec_paramgen_curve:prime256v1 -nodes \
			-subj "/CN=${side}" -keyout "${side}.key" -out "${side}.csr"
		printf 'keyUsage=critical,digitalSignature,keyAgreement\nextendedKeyUsage=%s\n' \
			"$([ "${side}" = server ] && echo serverAuth || echo clientAuth)" >"${side}.ext"
		openssl x509 -req -in "${side}.csr" -CA ca.crt -CAkey ca.key -CAcreateserial -days 1 \
			-extfile "${side}.ext" -out "${side}.crt"
	done
) >/dev/null 2>&1 || fail "could not make the test PKI with openssl"
chmod 0644 "${WORK}"/*.key

# client.conf, the client's whole config with its key inline, as a provider's
# export holds it. $1 replaces the remote line. hand-window is the test's
# own: a client that starts while the server is down retries its handshake
# every 15 s instead of every 60.
client_conf() {
	printf 'client\ndev tun\nproto udp\n%s\nnobind\nremote-cert-tls server\nhand-window 15\nverb 3\n' "$1"
	printf '<ca>\n%s\n</ca>\n<cert>\n%s\n</cert>\n<key>\n%s\n</key>\n' \
		"$(cat "${WORK}/ca.crt")" "$(cat "${WORK}/client.crt")" "$(cat "${WORK}/client.key")"
}
client_conf "remote vpn.smoke 1194" >"${WORK}/client.conf"
# A line of the client's key, which must appear in no output.
KEY_LINE="$(sed -n 2p "${WORK}/client.key")"

# --- 2. refusals --------------------------------------------------------------
# Each exits 78 with the message, before any route changes.

refuse() { # <label> <needle> <config-body or ""> [run args...]
	local label="$1" needle="$2" body="$3" out rc=0
	shift 3
	printf '%s\n' "${body}" >"${WORK}/refuse.conf"
	out="$("${ENGINE}" run --rm --name "${TAG}-refuse" "$@" -v "${WORK}/refuse.conf:/etc/openvpn/client.conf:ro" \
		"${IMAGE}" 2>&1)" || rc=$?
	[ "${rc}" = 78 ] || fail "${label}: exited ${rc}, not 78: ${out}"
	case "${out}" in *"${needle}"*) ;; *) fail "${label}: no \"${needle}\" in: ${out}" ;; esac
	case "${out}" in *"${KEY_LINE}"*) fail "${label}: the key reached the output" ;; esac
	echo "ok: refused (78): ${label}"
}

refuse "a config with no remote" "names no server" "$(client_conf "")" "${NET_ADMIN[@]}"
refuse "a remote that does not resolve" "none of the servers" "$(client_conf "remote vpn.does-not-resolve.invalid 1194")" "${NET_ADMIN[@]}"
refuse "a login asked for and not given" "asks for a login" "$(client_conf "remote 192.0.2.1 1194")
auth-user-pass" "${NET_ADMIN[@]}"
refuse "a log file" "would take openvpn's log away" "$(client_conf "remote 192.0.2.1 1194")
log /tmp/openvpn.log" "${NET_ADMIN[@]}"
refuse "no tun device" "/dev/net/tun is missing" "$(client_conf "remote 192.0.2.1 1194")" --cap-add NET_ADMIN
refuse "a relative OPENVPN_CONFIG" "not an absolute path" "" -e OPENVPN_CONFIG=client.conf "${NET_ADMIN[@]}"

# An inline login is accepted: it gets as far as the kill switch, which needs
# NET_ADMIN this run lacks.
refuse "an inline login without NET_ADMIN" "needs NET_ADMIN" "$(client_conf "remote 192.0.2.1 1194")
auth-user-pass
<auth-user-pass>
smoke-user
smoke-pass
</auth-user-pass>" --device /dev/net/tun

# --- 3. the rig ---------------------------------------------------------------

# IPv6 too, so the client starts with an IPv6 default route for the kill
# switch to remove.
"${ENGINE}" network create --subnet 10.231.77.0/24 --ipv6 --subnet fd00:231:77::/64 "${RIG}" >/dev/null
[ -n "$("${ENGINE}" run --rm --network "${RIG}" --entrypoint ip "${IMAGE}" -6 route show default)" ] ||
	fail "the rig network has no IPv6 default route, so the IPv6 half of the kill switch would go untested"
# Not --internal: Docker drops a packet on an internal network whose source is
# outside its subnet, as the tunnel's are. Neither runtime routes between its
# networks, so the far network is still reached through the server alone.
"${ENGINE}" network create --subnet 10.231.78.0/24 "${FAR}" >/dev/null

# The server: this image's openvpn in server mode, answering on SRV_VPN too,
# from the address each packet came to (--multihome): the client's socket
# takes replies from the address it dialed alone.
"${ENGINE}" create --name "${SRV}" --network "${RIG}" --ip "${SRV_IP}" "${NET_ADMIN[@]}" \
	--sysctl net.ipv4.ip_forward=1 -v "${WORK}:/pki:ro" --entrypoint sh "${IMAGE}" -c "
	ip addr add ${SRV_VPN}/32 dev eth0 && exec openvpn --dev tun --proto udp --port 1194 --multihome \
		--topology subnet --server 10.8.0.0 255.255.255.0 --ca /pki/ca.crt --cert /pki/server.crt \
		--key /pki/server.key --dh none --push 'redirect-gateway def1' --keepalive 5 15 --verb 3" >/dev/null
"${ENGINE}" network connect --ip "${SRV_FAR}" "${FAR}" "${SRV}"

# The target, on the far network alone, routing the tunnel's subnet back.
"${ENGINE}" run -d --name "${TGT}" --network "${FAR}" --ip "${TGT_IP}" --cap-add NET_ADMIN \
	--entrypoint sh "${IMAGE}" -c "
	ip route add 10.8.0.0/24 via ${SRV_FAR} && while :; do echo far-only | nc -l -p 7000; done" >/dev/null

# The client: the image as a consumer runs it, but with its default route
# pointed at the server before the entrypoint starts, so the server is behind
# a gateway. vpn.smoke resolves to the server's second address. Read-only as
# Docker makes it, so openvpn's temporary directory has to be /dev/shm.
"${ENGINE}" run -d --name "${CLI}" --network "${RIG}" "${NET_ADMIN[@]}" "${READ_ONLY[@]}" \
	--add-host "vpn.smoke:${SRV_VPN}" -v "${WORK}/client.conf:/etc/openvpn/client.conf:ro" \
	--entrypoint sh "${IMAGE}" -c "
	ip route replace default via ${SRV_IP} && exec /usr/local/bin/openvpn-entrypoint run" >/dev/null

in_client() { "${ENGINE}" exec "${CLI}" "$@"; }
# Whether the client's log has a line matching $1. grep -c reads it all:
# under pipefail, grep -q's early exit fails the pipeline by SIGPIPE.
logged() { "${ENGINE}" logs "${CLI}" 2>&1 | grep -c -- "$1" >/dev/null; }
far() { in_client sh -c "nc -w 3 ${TGT_IP} 7000" 2>/dev/null || true; }
no_way_out() { # <label>: no default route, and no route to an outside address but the tunnel
	local r
	[ -z "$(in_client ip -4 route show default)" ] || fail "$1: an IPv4 default route is back"
	[ -z "$(in_client ip -6 route show default)" ] || fail "$1: an IPv6 default route is back"
	r="$(in_client ip -4 -o route get 198.51.100.1 2>&1 || true)"
	case "${r}" in *" dev eth0"*) fail "$1: an outside IPv4 address is routed out eth0: ${r}" ;; esac
	r="$(in_client ip -6 -o route get 2001:db8::1 2>&1 || true)"
	case "${r}" in *" dev eth0"*) fail "$1: an outside IPv6 address is routed out eth0: ${r}" ;; esac
}

# --- 4. a fresh start with the server down ------------------------------------

for _ in $(seq 1 30); do
	logged "kill switch" && break
	sleep 1
done
logs="$("${ENGINE}" logs "${CLI}" 2>&1)"
case "${logs}" in *"kill switch = default routes removed; host routes to: ${SRV_VPN}"*) ;;
*) fail "the summary does not show the server pinned behind its gateway" ;; esac
no_way_out "server down from the start"
[ -z "$(far)" ] || fail "the far target answered with the server down"
in_client /usr/local/bin/openvpn-entrypoint healthcheck >/dev/null 2>&1 && fail "healthy with no tunnel"
echo "ok: started with the server down, nothing gets out, and the healthcheck fails"

# --- 5. the server comes up ---------------------------------------------------

"${ENGINE}" start "${SRV}" >/dev/null
for _ in $(seq 1 150); do
	logged "Initialization Sequence Completed" && break
	sleep 1
done
logged "Initialization Sequence Completed" || fail "the client never connected"
[ "$(far)" = far-only ] || fail "the far target did not answer through the tunnel"
in_client /usr/local/bin/openvpn-entrypoint healthcheck >/dev/null || fail "unhealthy with the tunnel up"
no_way_out "tunnel up"
echo "ok: with the server up, the target only the tunnel reaches answers, and the healthcheck passes"
# Half of def1 gone: the healthcheck wants both halves in the tunnel.
in_client ip route del 128.0.0.0/1
out="$(in_client /usr/local/bin/openvpn-entrypoint healthcheck 2>&1)" && fail "healthy with half of IPv4 outside the tunnel"
case "${out}" in *"128.0.0.0/1 to nowhere"*) ;; *) fail "the healthcheck does not name the missing half: ${out}" ;; esac
in_client ip route add 128.0.0.0/1 via 10.8.0.1 dev tun0
in_client /usr/local/bin/openvpn-entrypoint healthcheck >/dev/null || fail "unhealthy once both halves are back"
echo "ok: with half of def1 gone, the healthcheck fails and names it"

# --- 6. the server goes away again --------------------------------------------

# openvpn's restart markers, counted, so a new one after the stop is told
# apart from those of the start, when the server was down.
restarts() { "${ENGINE}" logs "${CLI}" 2>&1 | grep -cE "Inactivity timeout|process restarting" || true; }
before="$(restarts)"
"${ENGINE}" stop -t 1 "${SRV}" >/dev/null
[ "$("${ENGINE}" inspect -f '{{.State.Running}}' "${SRV}")" = false ] || fail "the server did not stop"
for _ in $(seq 1 60); do
	[ "$(restarts)" -gt "${before}" ] && break
	sleep 1
done
[ "$(restarts)" -gt "${before}" ] || fail "the client never noticed the server was gone"
sleep 2
no_way_out "server gone, after openvpn restarted"
[ -z "$(far)" ] || fail "the far target answered with the server gone"
echo "ok: with the server gone, after openvpn's restart, nothing gets out"

# --- 7. no secret anywhere ----------------------------------------------------

case "$("${ENGINE}" logs "${CLI}" 2>&1)" in *"${KEY_LINE}"*) fail "the client's key is in its log" ;; esac
echo "ok: the client's key appears in no output"

echo "PASS: openvpn smoke (${IMAGE})"
