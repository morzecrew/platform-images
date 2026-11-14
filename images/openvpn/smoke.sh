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
	# One name a call: given a name that does not exist, podman 4.9 removes
	# none of the others and still exits 0.
	local name
	for name in "${TAG}-client" "${TAG}-list" "${SRV}" "${TGT}"; do
		"${ENGINE}" rm -f "${name}" >/dev/null 2>&1 || true
	done
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

# A list: each openvpn:// line holds a config, gzipped, then base64url.
enc() { gzip -c | base64 -w0 | tr '+/' '-_' | tr -d '='; }
# Nothing routes into a list's tunnels, so reverse-path filtering, which
# would drop their replies, has to be off.
NO_RP=(--sysctl net.ipv4.conf.all.rp_filter=0 --sysctl net.ipv4.conf.default.rp_filter=0)
LIST=(-e OPENVPN_UPSTREAMS=/etc/openvpn/client.conf "${NET_ADMIN[@]}" "${NO_RP[@]}")
refuse "a config and a list" "are both set" "" -e OPENVPN_CONFIG=/etc/openvpn/client.conf "${LIST[@]}"
refuse "a list with reverse-path filtering" "reverse-path filtering is on (rp_filter all and default: 02)" "" \
	-e OPENVPN_UPSTREAMS=/etc/openvpn/client.conf "${NET_ADMIN[@]}" --sysctl net.ipv4.conf.all.rp_filter=0 --sysctl net.ipv4.conf.default.rp_filter=2
refuse "a list with no openvpn line" "has no openvpn:// line" "socks5://proxy.example:1080 name=p" "${LIST[@]}"
refuse "a bare openvpn line" "line 2 of /etc/openvpn/client.conf names openvpn and holds no config" "# the ways out
openvpn name=vpn" "${LIST[@]}"
refuse "a line that is not base64url" "line 1 of /etc/openvpn/client.conf is not openvpn:// and a config" "openvpn://not*base64" "${LIST[@]}"
refuse "a line not gzipped" "line 1 of /etc/openvpn/client.conf is not openvpn:// and a config" "openvpn://$(client_conf "remote 192.0.2.1 1194" | base64 -w0 | tr '+/' '-_')" "${LIST[@]}"
refuse "a line whose config has a log file" "line 2 of /etc/openvpn/client.conf has \`log\`" "openvpn://$(client_conf "remote 192.0.2.1 1194" | enc) name=a
openvpn://$(printf '%s\nlog /tmp/x\n' "$(client_conf "remote 192.0.2.1 1194")" | enc) name=b" "${LIST[@]}"

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
		--key /pki/server.key --dh none --push 'redirect-gateway def1' --push 'route 203.0.113.0 255.255.255.0' \
		--keepalive 5 15 --duplicate-cn --verb 3" >/dev/null
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
# One tunnel takes the routes its server pushes, so a list's ignoring them
# (section 10) is the list's own doing.
[ -n "$(in_client ip -4 route show 203.0.113.0/24)" ] || fail "the route the server pushes is not in the one tunnel's table"
echo "ok: with the server up, the target only the tunnel reaches answers, and the healthcheck passes"
# Half of def1 gone: the healthcheck wants both halves in the tunnel.
in_client ip route del 128.0.0.0/1
out="$(in_client /usr/local/bin/openvpn-entrypoint healthcheck 2>&1)" && fail "healthy with half of IPv4 outside the tunnel"
case "${out}" in *"128.0.0.0/1 to nowhere"*) ;; *) fail "the healthcheck does not name the missing half: ${out}" ;; esac
in_client ip route add 128.0.0.0/1 via 10.8.0.1 dev tun0
in_client /usr/local/bin/openvpn-entrypoint healthcheck >/dev/null || fail "unhealthy once both halves are back"
echo "ok: with half of def1 gone, the healthcheck fails and names it"

# --- 6. openvpn dies, the container does not ----------------------------------

# A restarted container would get a new network namespace and cut off any
# container sharing this one, so the entrypoint starts openvpn again in place.
connects() { "${ENGINE}" logs "${CLI}" 2>&1 | grep -c "Initialization Sequence Completed" || true; }
started_at() { "${ENGINE}" inspect -f '{{.State.StartedAt}}' "${CLI}"; }
netns_before="$(in_client readlink /proc/1/ns/net)"
started_before="$(started_at)"
before="$(connects)"
in_client pkill -KILL -x openvpn
for _ in $(seq 1 10); do
	logged "openvpn exited with" && break
	sleep 1
done
logged "openvpn exited with" || fail "the entrypoint did not notice openvpn exit"
no_way_out "openvpn killed"
for _ in $(seq 1 60); do
	[ "$(connects)" -gt "${before}" ] && break
	sleep 1
done
[ "$(connects)" -gt "${before}" ] || fail "openvpn did not connect again after it was killed"
[ "$(started_at)" = "${started_before}" ] || fail "the container restarted when openvpn died"
[ "$(in_client readlink /proc/1/ns/net)" = "${netns_before}" ] || fail "the network namespace changed when openvpn died"
[ "$(far)" = far-only ] || fail "the far target did not answer once openvpn was back"
echo "ok: openvpn killed, started again in the same container and namespace, and the tunnel carries traffic"

# --- 7. the server goes away again --------------------------------------------

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

# --- 8. no secret anywhere ----------------------------------------------------

case "$("${ENGINE}" logs "${CLI}" 2>&1)" in *"${KEY_LINE}"*) fail "the client's key is in its log" ;; esac
echo "ok: the client's key appears in no output"

# --- 9. a stop reaches openvpn ------------------------------------------------

# The entrypoint is PID 1, which ignores TERM unless it traps it: without the
# trap, the runtime would wait out the timeout and kill it.
t0="$(date +%s)"
"${ENGINE}" stop -t 20 "${CLI}" >/dev/null
took=$(($(date +%s) - t0))
[ "${took}" -lt 10 ] || fail "stopping took ${took} s, so TERM never reached openvpn"
code="$("${ENGINE}" inspect -f '{{.State.ExitCode}}' "${CLI}")"
[ "${code}" = 0 ] || fail "the client exited with ${code} on a stop"
echo "ok: a stop ends openvpn and the entrypoint at once, with 0"

# --- 10. a list: a tunnel for each openvpn:// line ----------------------------

# Two tunnels to the server, which takes one certificate twice (duplicate-cn),
# and a third to an address where nothing answers. Each runs on the device of
# its line, none takes the routes the server pushes, the default or another,
# and what binds to a tunnel's device leaves through it alone.
LCLI="${TAG}-list"
up="$(client_conf "remote vpn.smoke 1194" | enc)"
{
	echo "# a proxy line, which the tunnels skip"
	echo "socks5://proxy.example:1080 name=p"
	echo "openvpn://${up} name=a"
	echo "openvpn://${up} name=b group=upstream,ipv6"
	echo "openvpn://$(client_conf "remote 192.0.2.1 1194" | enc) name=dead"
} >"${WORK}/upstreams"
CLI="${LCLI}"
"${ENGINE}" start "${SRV}" >/dev/null
"${ENGINE}" run -d --name "${LCLI}" --network "${RIG}" "${NET_ADMIN[@]}" "${NO_RP[@]}" --cap-add NET_RAW "${READ_ONLY[@]}" \
	--add-host "vpn.smoke:${SRV_VPN}" -v "${WORK}/upstreams:/run/secrets/upstreams:ro" \
	-e OPENVPN_UPSTREAMS=/run/secrets/upstreams --entrypoint sh "${IMAGE}" -c "
	ip route replace default via ${SRV_IP} && exec /usr/local/bin/openvpn-entrypoint run" >/dev/null
for _ in $(seq 1 120); do
	[ "$(connects)" -ge 2 ] && break
	sleep 1
done
[ "$(connects)" -ge 2 ] || fail "the list's two tunnels to the server did not both connect"
logged "tunnels = tun0 (line 3), tun1 (line 4), tun2 (line 5)" || fail "the summary does not list the tunnels by line"
[ "$(in_client stat -c %a /dev/shm/openvpn)" = 700 ] || fail "the decoded configs are not in a directory root's alone"
no_way_out "a list's tunnels up"
[ -z "$(in_client ip -4 route show 0.0.0.0/1)" ] || fail "a tunnel took the default route its server pushed"
[ -z "$(in_client ip -4 route show 203.0.113.0/24)" ] || fail "a tunnel took a route its server pushed"
for dev in tun0 tun1; do
	in_client ping -c 1 -W 3 -I "${dev}" "${TGT_IP}" >/dev/null 2>&1 || fail "the far target did not answer through ${dev}"
done
in_client ping -c 1 -W 2 "${TGT_IP}" >/dev/null 2>&1 && fail "the far target answered with no tunnel's device bound"
in_client ping -c 1 -W 2 -I tun2 "${TGT_IP}" >/dev/null 2>&1 && fail "the far target answered through the tunnel that never connected"
echo "ok: a list: each tunnel on its line's device, no default route, the target reached through each device bound"
out="$(in_client /usr/local/bin/openvpn-entrypoint healthcheck 2>&1)" || fail "unhealthy with two of three tunnels up: ${out}"
[ "${out}" = "healthy: up: tun0 tun1; down: tun2" ] || fail "the healthcheck does not name each tunnel: ${out}"
in_client /usr/local/bin/openvpn-entrypoint healthcheck 1 >/dev/null || fail "tun1 is not healthy"
in_client /usr/local/bin/openvpn-entrypoint healthcheck 2 >/dev/null 2>&1 && fail "tun2 is healthy with nothing behind it"
echo "ok: a list: healthy while a tunnel is up, and each tunnel's own healthcheck"

# One openvpn killed: its supervisor starts it again, on its device, and the
# other tunnel carries traffic meanwhile.
before="$(connects)"
in_client pkill -KILL -f -- "--dev tun1 "
for _ in $(seq 1 10); do
	logged "openvpn on tun1 (line 4) exited with" && break
	sleep 1
done
logged "openvpn on tun1 (line 4) exited with" || fail "the supervisor did not notice tun1's openvpn exit"
in_client ping -c 1 -W 3 -I tun0 "${TGT_IP}" >/dev/null 2>&1 || fail "tun0 stopped carrying traffic when tun1's openvpn died"
for _ in $(seq 1 60); do
	[ "$(connects)" -gt "${before}" ] && break
	sleep 1
done
[ "$(connects)" -gt "${before}" ] || fail "tun1's openvpn did not connect again"
in_client ping -c 1 -W 3 -I tun1 "${TGT_IP}" >/dev/null 2>&1 || fail "the far target did not answer through tun1 once it was back"
echo "ok: a list: one openvpn killed comes back on its device, and the other tunnel carried on"

case "$("${ENGINE}" logs "${LCLI}" 2>&1)" in *"${KEY_LINE}"* | *"${up:20:40}"*) fail "a key or a line reached the list client's log" ;; esac
t0="$(date +%s)"
"${ENGINE}" stop -t 20 "${LCLI}" >/dev/null
took=$(($(date +%s) - t0))
[ "${took}" -lt 10 ] || fail "stopping the list client took ${took} s"
[ "$("${ENGINE}" inspect -f '{{.State.ExitCode}}' "${LCLI}")" = 0 ] || fail "the list client exited non-zero on a stop"
echo "ok: a list: no key in its log, and a stop ends every tunnel at once, with 0"

echo "PASS: openvpn smoke (${IMAGE})"
