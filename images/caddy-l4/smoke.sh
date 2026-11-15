#!/usr/bin/env bash
# Smoke test for the caddy-l4 image. See images/caddy-l4/README.md.
#
# Offline, with Caddy's internal CA. What it shows:
# - the binary is the Caddy version the label names;
# - every module beyond upstream's standard set is caddy-l4's, the listener
#   wrapper among them, and nothing of images/caddy's is here;
# - the binary's file capability is upstream's, cap_net_bind_service=p, with
#   no effective bit, so it starts under cap_drop ALL;
# - it serves as upstream's image does, from /etc/caddy/Caddyfile with
#   upstream's command, as uid 65532 under a read-only root with every
#   capability dropped and no new privileges;
# - the README's edge: a connection whose ClientHello names the passed-through
#   name reaches a backend that terminates TLS itself, with the backend's own
#   certificate, while any other name gets the edge's own site on the same
#   port.
set -euo pipefail
IMAGE="${1:?usage: smoke.sh <image-ref>}"
ENGINE="${ENGINE:-podman}"
CTR="smoke-caddy-l4-$$"
NET="smoke-caddy-l4-$$"
WORK="$(mktemp -d)"
cleanup() {
	"${ENGINE}" rm -f "${CTR}" "${CTR}-edge" "${CTR}-backend" >/dev/null 2>&1 || true
	"${ENGINE}" network rm "${NET}" >/dev/null 2>&1 || true
	rm -rf "${WORK}"
}
trap cleanup EXIT
fail() {
	echo "FAIL: $*" >&2
	exit 1
}
run() { "${ENGINE}" run --rm "$@"; }

want=$("${ENGINE}" image inspect -f '{{index .Config.Labels "org.opencontainers.image.version"}}' "${IMAGE}")
[ -n "${want}" ] || fail "the image has no org.opencontainers.image.version label"
got=$(run "${IMAGE}" caddy version | awk '{ print $1 }')
[ "${got}" = "v${want}" ] || fail "caddy version is ${got}, the label says ${want}"
echo "ok: Caddy ${got}, as the label says"

extra=$(run "${IMAGE}" caddy list-modules --skip-standard | grep -E '^[a-z0-9_.]+$' || true)
grep -qx 'caddy.listeners.layer4' <<<"${extra}" || fail "no caddy.listeners.layer4 among the modules beyond the standard set"
# caddy-l4 also registers its packet-connection wrapper and an ALPN matcher
# for TLS handshakes.
others=$(grep -vE '^(layer4(\..+)?|caddy\.(listeners|packetconns)\.layer4|tls\.handshake_match\.alpn)$' <<<"${extra}" || true)
[ -z "${others}" ] || fail "modules beyond the standard set that are not caddy-l4's: ${others}"
run "${IMAGE}" caddy list-modules | grep -qE '^http\.handlers\.(waf|rate_limit)$' &&
	fail "the image carries images/caddy's WAF or rate limiting"
run "${IMAGE}" test -e /opt/coraza && fail "the image carries /opt/coraza"
echo "ok: caddy-l4's $(wc -l <<<"${extra}") modules are the only ones beyond the standard set"

caps=$(run "${IMAGE}" getcap /usr/bin/caddy | awk '{ print $2 }')
[ "${caps}" = "cap_net_bind_service=p" ] || fail "the binary's file capability is ${caps:-none}, not upstream's cap_net_bind_service=p"
echo "ok: the binary's file capability is upstream's, cap_net_bind_service=p"

# Polls a URL until it answers the wanted body; extra arguments go to curl.
fetch() {
	local want="$1" url="$2" body=
	shift 2
	for _ in $(seq 1 20); do
		body=$(curl -fsS --noproxy '*' --max-time 2 "$@" "${url}" 2>/dev/null || true)
		[ "${body}" = "${want}" ] && return 0
		sleep 1
	done
	echo "${body:-nothing}"
	return 1
}

cat >"${WORK}/Caddyfile" <<'EOF'
:8080 {
	respond "ok"
}
EOF
chmod -R a+rX "${WORK}"
"${ENGINE}" run -d --name "${CTR}" --user 65532:65532 --read-only \
	--cap-drop ALL --security-opt no-new-privileges \
	--tmpfs /config --tmpfs /data -p 127.0.0.1::8080 \
	-v "${WORK}/Caddyfile:/etc/caddy/Caddyfile:ro" "${IMAGE}" >/dev/null
port=$("${ENGINE}" port "${CTR}" 8080 | sed -n 's/.*://p' | head -n 1)
fetch ok "http://127.0.0.1:${port}/" >/dev/null ||
	{ "${ENGINE}" logs "${CTR}" 2>&1 | tail -10 >&2; fail "it does not serve upstream's way, as uid 65532, read-only, with no capabilities"; }
echo "ok: it serves from /etc/caddy/Caddyfile with upstream's command, as uid 65532, read-only, with no capabilities"

# The edge and its backend on one network. The backend terminates TLS for
# pass.example.test with a certificate of its own CA; the edge never holds one
# for that name, so the backend's issuer in the handshake shows the bytes went
# through untouched.
"${ENGINE}" network create "${NET}" >/dev/null
mkdir "${WORK}/edge" "${WORK}/backend"
cat >"${WORK}/backend/Caddyfile" <<'EOF'
{
	skip_install_trust
	pki {
		ca local {
			name "smoke backend CA"
			intermediate_cn "smoke backend CA"
		}
	}
}

https://pass.example.test:9443 {
	tls internal
	respond "backend"
}
EOF
cat >"${WORK}/edge/Caddyfile" <<'EOF'
{
	skip_install_trust
	auto_https disable_redirects
	servers :8443 {
		listener_wrappers {
			layer4 {
				@passthrough tls sni pass.example.test
				route @passthrough {
					proxy backend:9443
				}
			}
			tls
		}
	}
}

https://other.example.test:8443 {
	tls internal
	respond "edge"
}
EOF
chmod -R a+rX "${WORK}"
"${ENGINE}" run -d --name "${CTR}-backend" --network "${NET}" --network-alias backend \
	-v "${WORK}/backend/Caddyfile:/etc/caddy/Caddyfile:ro" "${IMAGE}" >/dev/null
"${ENGINE}" run -d --name "${CTR}-edge" --network "${NET}" -p 127.0.0.1::8443 \
	-v "${WORK}/edge/Caddyfile:/etc/caddy/Caddyfile:ro" "${IMAGE}" >/dev/null
port=$("${ENGINE}" port "${CTR}-edge" 8443 | sed -n 's/.*://p' | head -n 1)

logs() {
	"${ENGINE}" logs "${CTR}-edge" 2>&1 | tail -10 >&2
	"${ENGINE}" logs "${CTR}-backend" 2>&1 | tail -10 >&2
}
got=$(fetch edge "https://other.example.test:${port}/" -k --resolve "other.example.test:${port}:127.0.0.1") ||
	{ logs; fail "a name the edge serves itself got ${got}, not the edge's own site"; }
echo "ok: a name not passed through gets the edge's own site"
got=$(fetch backend "https://pass.example.test:${port}/" -k --resolve "pass.example.test:${port}:127.0.0.1") ||
	{ logs; fail "the passed-through name got ${got}, not the backend's answer"; }
issuer=$(curl -sS --noproxy '*' --max-time 5 -k -v --resolve "pass.example.test:${port}:127.0.0.1" \
	"https://pass.example.test:${port}/" 2>&1 >/dev/null | sed -n 's/^\*  *issuer: //p')
grep -q "smoke backend CA" <<<"${issuer}" || fail "the passed-through name's certificate is not the backend's: issuer ${issuer:-unknown}"
echo "ok: the passed-through name reaches the backend, under the backend's own certificate"
