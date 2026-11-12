#!/usr/bin/env bash
# Smoke test for the caddy-acmedns image. See images/caddy-acmedns/README.md.
#
# No internet and no ACME CA, so no certificate is issued here; what can be
# shown offline is:
# - the binary is the Caddy version the label names;
# - the one module beyond upstream's standard set is dns.providers.acmedns,
#   and nothing of images/caddy's (no WAF, no rate limiting, no /opt/coraza);
# - a Caddyfile that hands the DNS-01 check to acme-dns, for a wildcard site,
#   with the credentials in a mounted JSON file, adapts to an issuer that
#   solves DNS-01 through acmedns, and validates, the module provisioned from
#   the file;
# - the binary's file capability is upstream's, cap_net_bind_service=p, with
#   no effective bit: with one, execve refuses the binary wherever the
#   capability is outside the bounding set, as under cap_drop ALL;
# - it serves as upstream's image does, from /etc/caddy/Caddyfile with
#   upstream's command, as a non-root user under a read-only root, with every
#   capability dropped and no new privileges, as a hardened service runs it.
set -euo pipefail
IMAGE="${1:?usage: smoke.sh <image-ref>}"
ENGINE="${ENGINE:-podman}"
CTR="smoke-caddy-acmedns-$$"
WORK="$(mktemp -d)"
cleanup() {
	"${ENGINE}" rm -f "${CTR}" >/dev/null 2>&1 || true
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
[ "${extra}" = "dns.providers.acmedns" ] || fail "the modules beyond the standard set are not acmedns alone: ${extra:-none}"
run "${IMAGE}" caddy list-modules | grep -qE '^http\.handlers\.(waf|rate_limit)$' &&
	fail "the image carries images/caddy's WAF or rate limiting"
run "${IMAGE}" test -e /opt/coraza && fail "the image carries /opt/coraza"
echo "ok: acmedns is the one module beyond the standard set, and nothing of images/caddy's is here"

cat >"${WORK}/acmedns.json" <<'EOF'
{"username": "5d26a340-2e1d-4b6b-af1a-4aab569897b7", "password": "smoke-password-not-a-secret",
 "subdomain": "37c51280-79ca-435f-af32-c775eb67e2ab", "server_url": "https://auth.example.test"}
EOF
cat >"${WORK}/Caddyfile" <<'EOF'
{
	acme_dns acmedns /etc/caddy/acmedns.json
}

*.r.example.test {
	respond "ok"
}
EOF
chmod -R a+rX "${WORK}"
mounts=(-v "${WORK}/Caddyfile:/etc/caddy/Caddyfile:ro" -v "${WORK}/acmedns.json:/etc/caddy/acmedns.json:ro")
json=$(run "${mounts[@]}" "${IMAGE}" caddy adapt --config /etc/caddy/Caddyfile --adapter caddyfile 2>/dev/null) ||
	fail "a Caddyfile handing DNS-01 to acmedns does not adapt"
# Where Caddy puts the policy moves between versions; that it is there, and
# the site is the wildcard's, does not.
jq -e '[.apps.tls | .. | objects | select(.provider?.name? == "acmedns")] | length > 0' <<<"${json}" >/dev/null ||
	fail "no issuer solves DNS-01 through acmedns: $(jq -c '.apps.tls' <<<"${json}")"
jq -e '[.apps.http | .. | strings | select(. == "*.r.example.test")] | length > 0' <<<"${json}" >/dev/null ||
	fail "the site is not the wildcard's"
run "${mounts[@]}" "${IMAGE}" caddy validate --config /etc/caddy/Caddyfile --adapter caddyfile >/dev/null 2>&1 ||
	fail "a Caddyfile handing DNS-01 to acmedns does not validate"
echo "ok: a wildcard site hands its DNS-01 check to acmedns, credentials from a file"

caps=$(run "${IMAGE}" getcap /usr/bin/caddy | awk '{ print $2 }')
[ "${caps}" = "cap_net_bind_service=p" ] || fail "the binary's file capability is ${caps:-none}, not upstream's cap_net_bind_service=p"
echo "ok: the binary's file capability is upstream's, cap_net_bind_service=p"

cat >"${WORK}/Caddyfile" <<'EOF'
:8080 {
	respond "ok"
}
EOF
"${ENGINE}" run -d --name "${CTR}" --user 65532:65532 --read-only \
	--cap-drop ALL --security-opt no-new-privileges \
	--tmpfs /config --tmpfs /data -p 127.0.0.1::8080 \
	-v "${WORK}/Caddyfile:/etc/caddy/Caddyfile:ro" "${IMAGE}" >/dev/null
port=$("${ENGINE}" port "${CTR}" 8080 | sed -n 's/.*://p' | head -n 1)
body=
for _ in $(seq 1 20); do
	body=$(curl -fsS --noproxy '*' --max-time 2 "http://127.0.0.1:${port}/" 2>/dev/null || true)
	[ "${body}" = ok ] && break
	sleep 1
done
[ "${body}" = ok ] || { "${ENGINE}" logs "${CTR}" 2>&1 | tail -10 >&2; fail "it does not serve upstream's way, as uid 65532, read-only, with no capabilities"; }
echo "ok: it serves from /etc/caddy/Caddyfile with upstream's command, as uid 65532, read-only, with no capabilities"
