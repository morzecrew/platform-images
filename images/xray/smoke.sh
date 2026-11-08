#!/usr/bin/env bash
# Smoke test for the xray image. See images/xray/README.md.
#
# Rootless Podman. The secret files are created by this script's uid and shown
# to the container as uid 65532's through `--userns keep-id`, which is what a
# host where they belong to 65532 looks like from inside, without a chown this
# uid cannot do. Host networking, so the egress probe's target is an HTTP server
# this script runs on loopback and the test needs no internet.
# The JSON below spells "$file" literally, in single quotes on purpose.
# shellcheck disable=SC2016
set -euo pipefail
IMAGE="${1:?usage: smoke.sh <image-ref>}"
ENGINE="${ENGINE:-podman}"
CTR="smoke-xray-$$"
WORK="$(mktemp -d)"
BASE=$((20000 + $$ % 20000))
VLESS_PORT=${BASE}
PROBE_PORT=$((BASE + 1))
TARGET_PORT=$((BASE + 2))
SEED_PORT=$((BASE + 3))
CLIENTS_PORT=$((BASE + 4))
PROBE_A_PORT=$((BASE + 5))
PROBE_B_PORT=$((BASE + 6))
TLS_PORT=$((BASE + 7))
UP_SOCKS_PORT=$((BASE + 8))
UP_HTTP_PORT=$((BASE + 9))
PROBE_SOCKS_PORT=$((BASE + 10))
PROBE_HTTP_PORT=$((BASE + 11))
HTTPD_PID=""
TLSD_PID=""
ALL_OUTPUT=""

cleanup() {
	"${ENGINE}" rm -f "${CTR}" "${CTR}-refusal" >/dev/null 2>&1 || true
	[ -z "${HTTPD_PID}" ] || kill "${HTTPD_PID}" 2>/dev/null || true
	[ -z "${TLSD_PID}" ] || kill "${TLSD_PID}" 2>/dev/null || true
	rm -rf "${WORK}"
}
trap cleanup EXIT

fail() {
	echo "FAIL: $*"
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

# shellcheck disable=SC2054 # the commas are the option's own
RUN_ARGS=(--network host --userns keep-id:uid=65532,gid=65532)

# The config every case starts from:
#
# - a VLESS + XHTTP inbound whose id, decryption and path are $file references;
# - a VLESS inbound whose decryption is a $vlessDecryption reference;
# - a loopback HTTP inbound for the probe, routed to a VLESS outbound that
#   connects to the second inbound with the encryption `vless-encryption`
#   printed for the same seed, so a 2xx from the probe proves the pair;
# - a VLESS + REALITY inbound whose clients are a $vlessClients reference and
#   whose flow, Vision, is the inbound's "settings.flow". Two more probe
#   inbounds connect to it through Vision, one as each client, so a 2xx from
#   either proves that client and the flow Xray gave it. Its REALITY target is
#   a TLS server this script runs on loopback;
# - a socks and an http inbound that ask for a user and a password, each the
#   upstream of an outbound of the same kind whose settings are a $proxy
#   reference, and a probe inbound routed to each outbound, so a 2xx from
#   either proves the address, the port and the credentials split from one file;
# - a direct outbound, allowed to reach loopback, where the probe's target is.
#   Xray's default blocks private addresses for a proxied user;
# - geoip and geosite rules, so -test fails if Xray cannot find and load the
#   copied geodata where it looks by default.
#
#   config <dir> [id-json] [seeded-decryption-json] [clients-json] [socks-settings-json]
config() {
	local id="${2:-}" seeded="${3:-}" clients="${4:-}" upstream="${5:-}"
	[ -n "${id}" ] || id='{"$file": "/run/secrets/vless_uuid"}'
	[ -n "${seeded}" ] || seeded='{"$vlessDecryption": "/run/secrets/vless_seed"}'
	[ -n "${clients}" ] || clients='{"$vlessClients": "/run/secrets/vless_clients"}'
	[ -n "${upstream}" ] || upstream='{"$proxy": "/run/secrets/proxy_socks"}'
	local reality_client='{"serverName": "reality.test", "password": {"$file": "/run/secrets/reality_password"}, "shortId": "", "fingerprint": "chrome"}'
	local account='{"user": {"$file": "/run/secrets/proxy_user"}, "pass": {"$file": "/run/secrets/proxy_pass"}}'
	mkdir -p "$1"
	cat >"$1/10-xray.json" <<-EOF
		{
		  "inbounds": [
		    {"tag": "vless", "listen": "127.0.0.1", "port": ${VLESS_PORT}, "protocol": "vless",
		     "settings": {"clients": [{"id": ${id}}],
		                  "decryption": {"\$file": "/run/secrets/vless_decryption"}},
		     "streamSettings": {"network": "xhttp",
		                        "xhttpSettings": {"path": {"\$file": "/run/secrets/xhttp_path"}}}},
		    {"tag": "seeded", "listen": "127.0.0.1", "port": ${SEED_PORT}, "protocol": "vless",
		     "settings": {"clients": [{"id": {"\$file": "/run/secrets/vless_uuid"}}],
		                  "decryption": ${seeded}}},
		    {"tag": "probe", "listen": "127.0.0.1", "port": ${PROBE_PORT}, "protocol": "http"},
		    {"tag": "clients", "listen": "127.0.0.1", "port": ${CLIENTS_PORT}, "protocol": "vless",
		     "settings": {"clients": ${clients}, "decryption": "none", "flow": "xtls-rprx-vision"},
		     "streamSettings": {"network": "raw", "security": "reality",
		                        "realitySettings": {"target": "127.0.0.1:${TLS_PORT}", "serverNames": ["reality.test"],
		                                            "privateKey": {"\$file": "/run/secrets/reality_key"}, "shortIds": [""]}}},
		    {"tag": "probe-a", "listen": "127.0.0.1", "port": ${PROBE_A_PORT}, "protocol": "http"},
		    {"tag": "probe-b", "listen": "127.0.0.1", "port": ${PROBE_B_PORT}, "protocol": "http"},
		    {"tag": "upstream-socks", "listen": "127.0.0.1", "port": ${UP_SOCKS_PORT}, "protocol": "socks",
		     "settings": {"auth": "password", "accounts": [${account}]}},
		    {"tag": "upstream-http", "listen": "127.0.0.1", "port": ${UP_HTTP_PORT}, "protocol": "http",
		     "settings": {"accounts": [${account}]}},
		    {"tag": "probe-socks", "listen": "127.0.0.1", "port": ${PROBE_SOCKS_PORT}, "protocol": "http"},
		    {"tag": "probe-http", "listen": "127.0.0.1", "port": ${PROBE_HTTP_PORT}, "protocol": "http"}
		  ],
		  "outbounds": [
		    {"tag": "direct", "protocol": "freedom", "settings": {"finalRules": [{"action": "allow"}]}},
		    {"tag": "to-seeded", "protocol": "vless",
		     "settings": {"vnext": [{"address": "127.0.0.1", "port": ${SEED_PORT},
		                             "users": [{"id": {"\$file": "/run/secrets/vless_uuid"},
		                                        "encryption": {"\$file": "/run/secrets/vless_encryption"}}]}]}},
		    {"tag": "to-a", "protocol": "vless",
		     "settings": {"vnext": [{"address": "127.0.0.1", "port": ${CLIENTS_PORT},
		                             "users": [{"id": {"\$file": "/run/secrets/vless_uuid"}, "encryption": "none", "flow": "xtls-rprx-vision"}]}]},
		     "streamSettings": {"network": "raw", "security": "reality", "realitySettings": ${reality_client}}},
		    {"tag": "to-b", "protocol": "vless",
		     "settings": {"vnext": [{"address": "127.0.0.1", "port": ${CLIENTS_PORT},
		                             "users": [{"id": {"\$file": "/run/secrets/vless_uuid_b"}, "encryption": "none", "flow": "xtls-rprx-vision"}]}]},
		     "streamSettings": {"network": "raw", "security": "reality", "realitySettings": ${reality_client}}},
		    {"tag": "to-socks", "protocol": "socks", "settings": ${upstream}},
		    {"tag": "to-http", "protocol": "http", "settings": {"\$proxy": "/run/secrets/proxy_http"}}
		  ],
		  "routing": {"rules": [
		    {"inboundTag": ["probe"], "outboundTag": "to-seeded"},
		    {"inboundTag": ["probe-a"], "outboundTag": "to-a"},
		    {"inboundTag": ["probe-b"], "outboundTag": "to-b"},
		    {"inboundTag": ["probe-socks"], "outboundTag": "to-socks"},
		    {"inboundTag": ["probe-http"], "outboundTag": "to-http"},
		    {"ip": ["geoip:private"], "outboundTag": "direct"},
		    {"domain": ["geosite:private"], "outboundTag": "direct"}
		  ]}
		}
	EOF
}

# --- 1. the image -------------------------------------------------------------

VERSION="$("${ENGINE}" image inspect --format '{{index .Labels "org.opencontainers.image.version"}}' "${IMAGE}")"
[ -n "${VERSION}" ] || fail "no org.opencontainers.image.version label"

cfg="$("${ENGINE}" image inspect --format \
	'user={{.Config.User}} entrypoint={{.Config.Entrypoint}} cmd={{.Config.Cmd}} volumes={{.Config.Volumes}} healthcheck={{.Config.Healthcheck}}' \
	"${IMAGE}")"
expect_in "runs as 65532:65532" "${cfg}" "user=65532:65532 "
expect_in "the entrypoint is the helper, run by default" "${cfg}" "entrypoint=[/usr/local/bin/xray-entrypoint] cmd=[run]"
expect_in "no VOLUME from upstream" "${cfg}" "volumes=map[]"
expect_in "no baked HEALTHCHECK" "${cfg}" "healthcheck=<nil>"

"${ENGINE}" create --name "${CTR}" "${IMAGE}" >/dev/null
files="$("${ENGINE}" export "${CTR}" | tar -tvf -)"
"${ENGINE}" rm "${CTR}" >/dev/null
for f in usr/local/bin/xray usr/local/bin/xray-entrypoint \
	usr/local/share/xray/geoip.dat usr/local/share/xray/geosite.dat; do
	line="$(printf '%s\n' "${files}" | awk -v f="${f}" '$NF == f')"
	expect_in "${f} is present and root's" "${line}" " 0/0 "
done
for f in usr/local/etc/xray var/log/xray bin/sh bin/busybox; do
	if printf '%s\n' "${files}" | awk '{ print $NF }' | grep -qx "${f}/\?"; then
		fail "${f} is in the image"
	fi
done
echo "ok: no upstream placeholder configs, log directory or shell"

# --- 2. passthrough -----------------------------------------------------------

out="$("${ENGINE}" run --rm "${IMAGE}" version)"
expect_in "xray is the version the label names (else XRAY_IMAGE_DIGEST is stale)" \
	"${out}" "Xray ${VERSION} ("
uuid="$("${ENGINE}" run --rm "${IMAGE}" uuid)"
printf '%s' "${uuid}" | grep -Eqx '[0-9a-f]{8}-[0-9a-f]{4}-4[0-9a-f]{3}-[89ab][0-9a-f]{3}-[0-9a-f]{12}' ||
	fail "uuid printed '${uuid}'"
echo "ok: uuid passes through to xray"
decryption="$("${ENGINE}" run --rm "${IMAGE}" vlessenc | sed -n 's/^"decryption": "\(.*\)"$/\1/p' | head -1)"
[ -n "${decryption}" ] || fail "vlessenc printed no decryption"
echo "ok: vlessenc passes through to xray"

# --- 3. secrets as files, read-only root --------------------------------------

mkdir -p "${WORK}/secrets" "${WORK}/www"
printf '%s\n' "${uuid}" >"${WORK}/secrets/vless_uuid"
printf '%s\n' "${decryption}" >"${WORK}/secrets/vless_decryption"
XHTTP_PATH="/xh-smoke-$$-path"
printf '%s\n' "${XHTTP_PATH}" >"${WORK}/secrets/xhttp_path"
SEED="$(python3 -c 'import os; print(os.urandom(64).hex())')"
SEED_B64="$(python3 -c 'import base64, sys; print(base64.urlsafe_b64encode(bytes.fromhex(sys.argv[1])).decode().rstrip("="))' "${SEED}")"
printf '%s\n' "${SEED}" >"${WORK}/secrets/vless_seed"
printf '%s\n' "${SEED:0:127}" >"${WORK}/secrets/seed_127"
printf '%s\n' "${SEED:0:127}g" >"${WORK}/secrets/seed_not_hex"
# A REALITY private key as morzer's password generator writes one: 43 random
# characters of the base64url alphabet. The last is picked with its 2 spare
# bits set, the form strict decoding would refuse.
REALITY_KEY="$(python3 -c 'import secrets, string
a = string.ascii_uppercase + string.ascii_lowercase + string.digits + "-_"
print("".join(secrets.choice(a) for _ in range(42)) + secrets.choice([c for i, c in enumerate(a) if i % 4]))')"
printf '%s\n' "${REALITY_KEY}" >"${WORK}/secrets/reality_key"
printf '%s\n' "${REALITY_KEY:0:42}" >"${WORK}/secrets/reality_42"
printf '%s\n' "${REALITY_KEY:0:42}+" >"${WORK}/secrets/reality_std"
printf '%s\n' "${REALITY_KEY}=" >"${WORK}/secrets/reality_padded"
ID_B="$("${ENGINE}" run --rm "${IMAGE}" uuid)"
printf '%s\n' "${ID_B}" >"${WORK}/secrets/vless_uuid_b"
# Two devices as an operator keeps them: a comment, a blank line, a tab, and a
# name on the second.
printf '# <uuid> [name]\n\n%s\n\t%s\tphone\n' "${uuid}" "${ID_B}" >"${WORK}/secrets/vless_clients"
# Client lists section 7 refuses, each naming the line at fault.
printf '# devices\n%s phone spare\n' "${uuid}" >"${WORK}/secrets/clients_three_fields"
printf '%s\n%s\n' "${uuid}" "${ID_B:0:35}g" >"${WORK}/secrets/clients_not_uuid"
printf '%s ph/one\n' "${uuid}" >"${WORK}/secrets/clients_bad_name"
printf '%s\n\n%s phone\n' "${uuid}" "${uuid^^}" >"${WORK}/secrets/clients_same_id"
printf '%s phone\n%s Phone\n' "${uuid}" "${ID_B}" >"${WORK}/secrets/clients_same_name"
printf '# nobody yet\n\n' >"${WORK}/secrets/clients_none"
# An upstream's user and password, which its inbounds read as two files and
# its outbounds as one line each. The password holds ":" and "@", which only
# a split at the last @ and the first colon before it gets right.
PROXY_USER="smoke-proxy-$$"
PROXY_PASS="p:ss@w0rd-$$-$(python3 -c 'import secrets; print(secrets.token_hex(8))')"
printf '%s\n' "${PROXY_USER}" >"${WORK}/secrets/proxy_user"
printf '%s\n' "${PROXY_PASS}" >"${WORK}/secrets/proxy_pass"
printf '%s:%s@127.0.0.1:%s\n' "${PROXY_USER}" "${PROXY_PASS}" "${UP_SOCKS_PORT}" >"${WORK}/secrets/proxy_socks"
printf '%s:%s@127.0.0.1:%s\n' "${PROXY_USER}" "${PROXY_PASS}" "${UP_HTTP_PORT}" >"${WORK}/secrets/proxy_http"
# Proxy lines section 7 refuses. The last is the credentials alone, which an
# error that quoted what it could not parse would print.
printf 'socks5://%s:%s@127.0.0.1:%s\n' "${PROXY_USER}" "${PROXY_PASS}" "${UP_SOCKS_PORT}" >"${WORK}/secrets/proxy_scheme"
printf '%s:%s@127.0.0.1\n' "${PROXY_USER}" "${PROXY_PASS}" >"${WORK}/secrets/proxy_no_port"
printf '%s:%s\n' "${PROXY_USER}" "${PROXY_PASS}" >"${WORK}/secrets/proxy_no_host"
chmod 0400 "${WORK}/secrets/"*
mkdir "${WORK}/secrets/a_directory"
touch "${WORK}/www/generate_204"
printf '203.0.113.7\n' >"${WORK}/www/ip"
SECRETS=("${uuid}" "${uuid^^}" "${ID_B}" "${decryption}" "${XHTTP_PATH}" "${SEED}" "${SEED_B64}" "${REALITY_KEY}"
	"${PROXY_USER}" "${PROXY_PASS}")

# client_value <command> <path>: one of the helper's client-side subcommands,
# with the secrets mounted.
client_value() {
	"${ENGINE}" run --rm "${RUN_ARGS[@]}" -v "${WORK}/secrets:/run/secrets:ro" \
		"${IMAGE}" "$1" "$2"
}
encryption="$(client_value vless-encryption /run/secrets/vless_seed)"
client="$("${ENGINE}" run --rm "${IMAGE}" mlkem768 -i "${SEED_B64}" | sed -n 's/^Client: //p')"
[ -n "${client}" ] || fail "xray mlkem768 -i printed no Client line"
[ "${encryption}" = "mlkem768x25519plus.native.0rtt.${client}" ] ||
	fail "vless-encryption printed '${encryption:0:60}...', not the Client key of xray mlkem768 -i for the same seed"
echo "ok: vless-encryption is the Client key xray mlkem768 -i derives from the seed"
printf '%s\n' "${encryption}" >"${WORK}/secrets/vless_encryption"
chmod 0400 "${WORK}/secrets/vless_encryption"

# client_refuses <command> <file>: exit 78, naming the path.
client_refuses() {
	local rc=0 out
	out="$(client_value "$1" "/run/secrets/$2" 2>&1)" || rc=$?
	ALL_OUTPUT+="${out}"
	[ "${rc}" = 78 ] || fail "$1 on $2: exited ${rc}, expected 78: ${out}"
	expect_in "$1 refuses $2 (78)" "${out}" "/run/secrets/$2 "
}
for bad in seed_127 seed_not_hex a_directory; do
	client_refuses vless-encryption "${bad}"
done

password="$(client_value reality-password /run/secrets/reality_key)"
ALL_OUTPUT+="${password}"
public="$("${ENGINE}" run --rm "${IMAGE}" x25519 -i "${REALITY_KEY}" | sed -n 's/^Password (PublicKey): //p')"
[ -n "${public}" ] || fail "xray x25519 -i printed no Password (PublicKey) line"
[ "${password}" = "${public}" ] ||
	fail "reality-password printed '${password}', not the public key xray x25519 -i derives: '${public}'"
echo "ok: reality-password is the public key xray x25519 -i derives from the private key"
# What the REALITY clients below connect with, so a handshake also proves it.
printf '%s\n' "${password}" >"${WORK}/secrets/reality_password"
chmod 0400 "${WORK}/secrets/reality_password"
for bad in reality_42 reality_std reality_padded a_directory; do
	client_refuses reality-password "${bad}"
done
# The key pasted where its path belongs, as `xray x25519 -i` takes it.
rc=0
out="$("${ENGINE}" run --rm "${IMAGE}" reality-password "${REALITY_KEY}" 2>&1)" || rc=$?
ALL_OUTPUT+="${out}"
[ "${rc}" = 2 ] || fail "reality-password given the key itself: exited ${rc}, expected 2"
expect_in "reality-password refuses the key itself as an argument (2)" "${out}" "not an absolute path"
config "${WORK}/conf"

python3 -m http.server "${TARGET_PORT}" --bind 127.0.0.1 --directory "${WORK}/www" \
	>"${WORK}/httpd.log" 2>&1 &
HTTPD_PID=$!
for _ in $(seq 1 50); do
	curl -fs -o /dev/null "http://127.0.0.1:${TARGET_PORT}/" && break
	sleep 0.2
done

# The REALITY inbound's target, which must speak TLS 1.3: a TLS server with a
# throwaway certificate on loopback, so the test needs no internet.
openssl req -x509 -newkey ec -pkeyopt ec_paramgen_curve:prime256v1 -nodes -days 1 \
	-keyout "${WORK}/tls.key" -out "${WORK}/tls.crt" -subj /CN=reality.test \
	-addext subjectAltName=DNS:reality.test 2>/dev/null
python3 - "${WORK}" "${TLS_PORT}" >"${WORK}/tlsd.log" 2>&1 <<'PY' &
import socket, ssl, sys, threading
work, port = sys.argv[1], int(sys.argv[2])
ctx = ssl.SSLContext(ssl.PROTOCOL_TLS_SERVER)
ctx.load_cert_chain(work + "/tls.crt", work + "/tls.key")
ctx.set_alpn_protocols(["h2", "http/1.1"])
srv = socket.create_server(("127.0.0.1", port))
def serve(conn):
    try:
        with ctx.wrap_socket(conn, server_side=True) as tls:
            tls.recv(1)
    except OSError:
        pass
while True:
    threading.Thread(target=serve, args=(srv.accept()[0],), daemon=True).start()
PY
TLSD_PID=$!
for _ in $(seq 1 50); do
	(: <"/dev/tcp/127.0.0.1/${TLS_PORT}") 2>/dev/null && break
	sleep 0.2
done

# mode=1777 rather than an owner: Docker's uid= is not Podman's, and Podman's
# U is not in every version CI may have. The entrypoint's chmod to 0700 then
# fails quietly, as it does on any tmpfs another uid owns.
"${ENGINE}" run -d --name "${CTR}" "${RUN_ARGS[@]}" --read-only --tmpfs /run/xray:rw,mode=1777 \
	-v "${WORK}/conf:/etc/xray:ro" -v "${WORK}/secrets:/run/secrets:ro" \
	-e XRAY_HEALTHCHECK_PROXY="http://127.0.0.1:${PROBE_PORT}" \
	-e XRAY_HEALTHCHECK_URL="http://127.0.0.1:${TARGET_PORT}/generate_204" \
	-e XRAY_CONF__loglevel=debug -e XRAY_SMOKE_TYPO=1 \
	-e XRAY_LOCATION_CERT=/usr/local/bin \
	"${IMAGE}" >/dev/null

logs=""
for _ in $(seq 1 30); do
	logs="$("${ENGINE}" logs "${CTR}" 2>&1)"
	case "${logs}" in *"Xray ${VERSION} started"*) break ;; esac
	sleep 1
done
ALL_OUTPUT+="${logs}"
expect_in "Xray starts on the resolved config" "${logs}" "Xray ${VERSION} started"
expect_in "it reads the runtime directory" "${logs}" "Reading config: &{Name:/run/xray/10-xray.json"

top="$("${ENGINE}" top "${CTR}" user args | tr -s ' ')"
expect_in "PID 1 is xray, as nonroot (65532)" "${top}" "nonroot /usr/local/bin/xray run -confdir /run/xray"

expect_in "summary header" "${logs}" "[envconf] xray: effective configuration"
expect_in "summary footer" "${logs}" "[envconf] precedence: image default < environment"
expect_in "summary names the version" "${logs}" "xray = Xray ${VERSION} ("
expect_in "summary names the source file" "${logs}" "source=config         /etc/xray/10-xray.json"
expect_in "summary maps the id" "${logs}" \
	"inbounds[0].settings.clients[0].id <- /run/secrets/vless_uuid   (/etc/xray/10-xray.json)"
expect_in "summary maps the decryption" "${logs}" \
	"inbounds[0].settings.decryption <- /run/secrets/vless_decryption"
expect_in "summary maps the path" "${logs}" \
	"inbounds[0].streamSettings.xhttpSettings.path <- /run/secrets/xhttp_path"
expect_in "summary maps the seeded decryption" "${logs}" \
	"inbounds[1].settings.decryption <- \$vlessDecryption /run/secrets/vless_seed"
expect_in "XRAY_CONF__* is reported, not applied" "${logs}" \
	"WARN: XRAY_CONF__loglevel is set, but this image has no XRAY_CONF__ passthrough channel"
expect_in "an unknown XRAY_* name warns" "${logs}" "WARN: XRAY_SMOKE_TYPO is set but neither"
expect_not_in "Xray's own names do not warn" "${logs}" "XRAY_LOCATION_CERT"
expect_in "summary counts the client list" "${logs}" \
	"inbounds[3].settings.clients <- \$vlessClients /run/secrets/vless_clients (2 clients)   (/etc/xray/10-xray.json)"
expect_in "summary shows where the socks upstream is" "${logs}" \
	"outbounds[4].settings <- \$proxy /run/secrets/proxy_socks 127.0.0.1:${UP_SOCKS_PORT}   (/etc/xray/10-xray.json)"
expect_in "summary shows where the http upstream is" "${logs}" \
	"outbounds[5].settings <- \$proxy /run/secrets/proxy_http 127.0.0.1:${UP_HTTP_PORT}   (/etc/xray/10-xray.json)"

# --- 4. one client per device -------------------------------------------------

# via <port>: the status of a GET to the target through that probe inbound.
via() {
	curl --noproxy '' -s -o /dev/null -w '%{http_code}' --max-time 10 \
		-x "http://127.0.0.1:$1" "http://127.0.0.1:${TARGET_PORT}/generate_204" || true
}
[ "$(via "${PROBE_A_PORT}")" = 200 ] || fail "the first client did not connect over REALITY + Vision"
[ "$(via "${PROBE_B_PORT}")" = 200 ] || fail "the named client did not connect over REALITY + Vision"
echo "ok: both clients in the list connect through one REALITY + Vision inbound"

# Revoked by deleting its line and restarting. What is left is a bare UUID and
# a newline, which is how morzer's uuid generator writes the file.
rm -f "${WORK}/secrets/vless_clients"
printf '%s\n' "${uuid}" >"${WORK}/secrets/vless_clients"
chmod 0400 "${WORK}/secrets/vless_clients"
"${ENGINE}" restart "${CTR}" >/dev/null
for _ in $(seq 1 30); do
	logs="$("${ENGINE}" logs "${CTR}" 2>&1)"
	[ "$(printf '%s\n' "${logs}" | grep -c "Xray ${VERSION} started")" -ge 2 ] && break
	sleep 1
done
ALL_OUTPUT+="${logs}"
expect_in "a single bare UUID is a list of one" "${logs}" "/run/secrets/vless_clients (1 client)"
code="$(via "${PROBE_B_PORT}")"
[ "${code}" != 200 ] || fail "the revoked client still connects"
echo "ok: the revoked client is refused (${code})"
[ "$(via "${PROBE_A_PORT}")" = 200 ] || fail "the client left in the list no longer connects"
echo "ok: the client left in the list still connects"

# --- 5. an upstream proxy from one secret -------------------------------------

[ "$(via "${PROBE_SOCKS_PORT}")" = 200 ] || fail "the socks outbound did not get through its upstream"
[ "$(via "${PROBE_HTTP_PORT}")" = 200 ] || fail "the http outbound did not get through its upstream"
echo "ok: a socks and an http outbound reach their upstreams with the credentials split from one line"
# The upstreams refuse a client without the credentials, so the 2xx above
# proves the outbounds sent them.
code="$(curl --noproxy '' -s -o /dev/null -w '%{http_code}' --max-time 10 \
	-x "http://127.0.0.1:${UP_HTTP_PORT}" "http://127.0.0.1:${TARGET_PORT}/generate_204" || true)"
[ "${code}" = 407 ] || fail "the http upstream answered ${code} to a client without credentials, not 407"
if curl --noproxy '' -s -o /dev/null --max-time 10 \
	-x "socks5://127.0.0.1:${UP_SOCKS_PORT}" "http://127.0.0.1:${TARGET_PORT}/generate_204"; then
	fail "the socks upstream let a client without credentials through"
fi
echo "ok: both upstreams refuse a client without the credentials"
logs="$("${ENGINE}" logs "${CTR}" 2>&1)"
ALL_OUTPUT+="${logs}"

# --- 6. the healthcheck -------------------------------------------------------

hc() { "${ENGINE}" exec "$@" "${CTR}" /usr/local/bin/xray-entrypoint healthcheck 2>&1; }

out="$(hc)" || fail "healthcheck through the probe inbound: ${out}"
ALL_OUTPUT+="${out}"
expect_in "healthcheck exits 0 on a 2xx through the probe inbound and the seeded pair" "${out}" "200 OK"
expect_in "the request reached the target" "$(cat "${WORK}/httpd.log")" '"GET /generate_204 HTTP/1.1" 200'

started=$(date +%s)
rc=0
out="$(hc -e XRAY_HEALTHCHECK_URL=http://192.0.2.1/ -e XRAY_HEALTHCHECK_TIMEOUT=3s)" || rc=$?
elapsed=$(($(date +%s) - started))
[ "${rc}" = 1 ] || fail "unroutable URL: healthcheck exited ${rc}: ${out}"
[ "${elapsed}" -le 6 ] || fail "unroutable URL: healthcheck took ${elapsed}s against a 3s timeout"
echo "ok: an unroutable URL exits 1 within the timeout (${elapsed}s)"

rc=0
out="$(hc -e XRAY_HEALTHCHECK_PROXY=http://127.0.0.1:1)" || rc=$?
[ "${rc}" = 1 ] || fail "dead proxy: healthcheck exited ${rc}: ${out}"
echo "ok: the probe goes through the proxy (a dead one fails a reachable URL)"

# #133: the body against XRAY_HEALTHCHECK_EXPECT. /ip answers with a fixed
# address, as an IP-echo endpoint would.
ip=(-e XRAY_HEALTHCHECK_URL="http://127.0.0.1:${TARGET_PORT}/ip")
out="$(hc "${ip[@]}" -e XRAY_HEALTHCHECK_EXPECT='^203\.0\.113\.7\s*$')" || fail "the expected exit IP: ${out}"
expect_in "a body matching XRAY_HEALTHCHECK_EXPECT passes" "${out}" "matches XRAY_HEALTHCHECK_EXPECT"
rc=0
out="$(hc "${ip[@]}" -e XRAY_HEALTHCHECK_EXPECT='^198\.51\.100\.9\s*$')" || rc=$?
[ "${rc}" = 1 ] || fail "a changed exit IP: healthcheck exited ${rc}: ${out}"
expect_in "a changed exit IP exits 1 and shows the body" "${out}" \
	'does not match XRAY_HEALTHCHECK_EXPECT: "203.0.113.7\n"'

out="$(hc -e XRAY_HEALTHCHECK_PROXY=)" || fail "liveness: ${out}"
expect_in "without a proxy it checks liveness and says egress was not probed" \
	"${out}" "egress was not probed"

"${ENGINE}" rm -f "${CTR}" >/dev/null

# --- 7. refusals --------------------------------------------------------------

# refuse <label> <needle> <conf-dir> [run args...]: exit 78, needle in output.
# Bounded, so a case that starts Xray instead fails rather than hangs.
refuse() {
	local label="$1" needle="$2" conf="$3" rc=0 out
	shift 3
	out="$(timeout 60 "${ENGINE}" run --rm --name "${CTR}-refusal" "${RUN_ARGS[@]}" \
		-v "${conf}:/etc/xray:ro" -v "${WORK}/secrets:/run/secrets:ro" \
		"$@" "${IMAGE}" 2>&1)" || rc=$?
	"${ENGINE}" rm -f "${CTR}-refusal" >/dev/null 2>&1 || true
	ALL_OUTPUT+="${out}"
	[ "${rc}" = 78 ] || {
		printf '%s\n' "${out}" | tail -20
		fail "${label}: exited ${rc}, expected 78"
	}
	expect_in "refused (78): ${label}" "${out}" "${needle}"
}

config "${WORK}/missing" '{"$file": "/run/secrets/absent"}'
refuse "a missing file" \
	"/etc/xray/10-xray.json: inbounds[0].settings.clients[0].id: /run/secrets/absent does not exist" \
	"${WORK}/missing"

config "${WORK}/directory" '{"$file": "/run/secrets/a_directory"}'
refuse "a directory at the referenced path" \
	"inbounds[0].settings.clients[0].id: /run/secrets/a_directory is a directory" \
	"${WORK}/directory"

config "${WORK}/relative" '{"$file": "rel/path"}'
refuse "a relative path" \
	'inbounds[0].settings.clients[0].id: "$file" must be an absolute path' "${WORK}/relative"

config "${WORK}/other-key" '{"$file": "/x", "other": 1}'
refuse "\$file beside another key" \
	'inbounds[0].settings.clients[0].id: an object holding "$file" holds nothing else, and this one also holds other' \
	"${WORK}/other-key"

config "${WORK}/yaml"
printf 'log:\n  loglevel: debug\n' >"${WORK}/yaml/20-log.yaml"
refuse "a .yaml file in the source directory" "/etc/xray/20-log.yaml is not a .json file" "${WORK}/yaml"

printf '%s\n' "x" >"${WORK}/locked"
chmod 0000 "${WORK}/locked"
refuse "a file uid 65532 cannot read" "/run/secrets/vless_uuid is not readable by uid 65532" \
	"${WORK}/conf" -v "${WORK}/locked:/run/secrets/vless_uuid:ro"

# Xray quotes the id it rejects. It must not reach the log.
BAD_ID="smoke-secret-not-a-uuid-$$-0123456789"
printf '%s\n' "${BAD_ID}" >"${WORK}/bad_id"
chmod 0400 "${WORK}/bad_id"
refuse "a config xray run -test rejects" "invalid UUID: <redacted>" \
	"${WORK}/conf" -v "${WORK}/bad_id:/run/secrets/vless_uuid:ro"
SECRETS+=("${BAD_ID}")

config "${WORK}/short-seed" "" '{"$vlessDecryption": "/run/secrets/seed_127"}'
refuse "a seed of 127 hex characters" \
	"inbounds[1].settings.decryption: /run/secrets/seed_127 does not hold a seed" "${WORK}/short-seed"

# label:file:message, the message after the path. ids must not be in any.
for case in "three fields:three_fields:line 2: 3 fields" \
	"an id that is not a UUID:not_uuid:line 2: the id is not a UUID" \
	"a name outside the allowed characters:bad_name:line 1: the name is not 1 to 64" \
	"the same id twice, in another case:same_id:line 3: the id is the one on line 1" \
	"the same name twice, in another case:same_name:line 2: the name is the one on line 1" \
	"only comments and blank lines:none:lists no client"; do
	label="${case%%:*}" rest="${case#*:}"
	file="clients_${rest%%:*}" needle="${rest#*:}"
	config "${WORK}/${file}" "" "" "{\"\$vlessClients\": \"/run/secrets/${file}\"}"
	refuse "a client list with ${label}" \
		"inbounds[3].settings.clients: /run/secrets/${file} ${needle}" "${WORK}/${file}"
done

# label:file:message, as above. Neither the user nor the password may be in any.
for case in "a scheme:scheme:holds a URL. Write user:pass@host:port, without the scheme" \
	"no port:no_port:does not hold [user:pass@]host:port: it does not end in a host, a colon and a port" \
	"the credentials and no host:no_host:does not hold [user:pass@]host:port: it does not end in a host, a colon and a port"; do
	label="${case%%:*}" rest="${case#*:}"
	file="proxy_${rest%%:*}" needle="${rest#*:}"
	config "${WORK}/${file}" "" "" "" "{\"\$proxy\": \"/run/secrets/${file}\"}"
	refuse "a proxy line with ${label}" \
		"outbounds[4].settings: /run/secrets/${file} ${needle}" "${WORK}/${file}"
done

# RE2 has no lookahead. Found at deployment, not as an unhealthy container.
refuse "a healthcheck expression that does not compile" \
	"XRAY_HEALTHCHECK_EXPECT is not a regular expression in Go's RE2 syntax" \
	"${WORK}/conf" -e 'XRAY_HEALTHCHECK_EXPECT=^(?!10\.)'

# Docker's read_only. Podman's --read-only also mounts a tmpfs on /run, which
# the image works with.
refuse "a read-only root without a tmpfs" "XRAY_RUNTIME_DIR is /run/xray, which is not writable by uid 65532" \
	"${WORK}/conf" --read-only --read-only-tmpfs=false

# --- 8. no secret anywhere ----------------------------------------------------

for s in "${SECRETS[@]}"; do
	case "${ALL_OUTPUT}" in
	*"${s}"*) fail "a secret value appears in the output" ;;
	esac
done
echo "ok: no secret value in any log, summary or refusal"

echo "PASS: xray smoke (${IMAGE})"
