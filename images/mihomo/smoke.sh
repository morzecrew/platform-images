#!/usr/bin/env bash
# Smoke test for the mihomo image. See images/mihomo/README.md.
#
# Rootless Podman. The secret files and the home directory are created by
# this script's uid and shown to the container as uid 65532's through
# `--userns keep-id`, which is what a host where they belong to 65532 looks
# like from inside. Host networking, so the subscription and the probe's
# target are an HTTP server this script runs on loopback, and the test needs
# no internet.
# The JSON below spells "$file" literally, in single quotes on purpose.
# shellcheck disable=SC2016
set -euo pipefail
IMAGE="${1:?usage: smoke.sh <image-ref>}"
ENGINE="${ENGINE:-podman}"
CTR="smoke-mihomo-$$"
WORK="$(mktemp -d)"
BASE=$((20000 + $$ % 20000))
MIXED_PORT=${BASE}
TARGET_PORT=$((BASE + 1))
# Where the subscription's one server would be. Nothing listens there.
DEAD_PORT=$((BASE + 2))
HTTPD_PID=""
ALL_OUTPUT=""
LAST=""

cleanup() {
	# One name a call: given a name that does not exist, podman 4.9 removes
	# none of the others and still exits 0.
	local ctr
	for ctr in "${CTR}" "${CTR}-refusal"; do
		"${ENGINE}" rm -f "${ctr}" >/dev/null 2>&1 || true
	done
	[ -z "${HTTPD_PID}" ] || kill "${HTTPD_PID}" 2>/dev/null || true
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
# - a mixed (HTTP and SOCKS) inbound on loopback, which the probe goes through;
# - an http proxy provider whose url is a $file reference, served by this
#   script: one base64 vless:// link, as a dotdash subscription is;
# - a classical file rule provider read from /run/secrets, which only the
#   image's default SAFE_PATHS allows, holding the probe's target;
# - RULE-SET,direct,DIRECT before MATCH, so the probe's target goes direct
#   and everything else to the provider's proxy, which nothing serves;
# - a GEOIP rule, so -t fails if mihomo cannot load the seeded geodata
#   without downloading it.
#
#   config <dir> [url-json] [extra top-level members, each followed by a comma] [rules-json]
config() {
	local url="${2:-}" extra="${3:-}" rules="${4:-}"
	[ -n "${url}" ] || url='{"$file": "/run/secrets/subscription_url"}'
	[ -n "${rules}" ] || rules='["RULE-SET,direct,DIRECT", "GEOIP,CN,DIRECT", "MATCH,out"]'
	mkdir -p "$1"
	cat >"$1/config.json" <<-EOF
		{
		  ${extra}
		  "mixed-port": ${MIXED_PORT}, "bind-address": "127.0.0.1", "allow-lan": false,
		  "mode": "rule", "log-level": "info",
		  "proxy-providers": {"sub": {"type": "http", "url": ${url}, "interval": 3600,
		                              "path": "./proxies/sub.yaml", "health-check": {"enable": false}}},
		  "rule-providers": {"direct": {"type": "file", "behavior": "classical", "format": "text",
		                                "path": "/run/secrets/direct_rules"}},
		  "proxy-groups": [{"name": "out", "type": "select", "use": ["sub"]}],
		  "rules": ${rules}
		}
	EOF
}

# --- 1. the image -------------------------------------------------------------

VERSION="$("${ENGINE}" image inspect --format '{{index .Labels "org.opencontainers.image.version"}}' "${IMAGE}")"
[ -n "${VERSION}" ] || fail "no org.opencontainers.image.version label"

cfg="$("${ENGINE}" image inspect --format \
	'user={{.Config.User}} entrypoint={{.Config.Entrypoint}} cmd={{.Config.Cmd}} volumes={{.Config.Volumes}} healthcheck={{.Config.Healthcheck}} env={{.Config.Env}}' \
	"${IMAGE}")"
expect_in "runs as 65532:65532" "${cfg}" "user=65532:65532 "
expect_in "the entrypoint is the helper, run by default" "${cfg}" "entrypoint=[/usr/local/bin/mihomo-entrypoint] cmd=[run]"
expect_in "no VOLUME from upstream" "${cfg}" "volumes=map[]"
expect_in "no baked HEALTHCHECK" "${cfg}" "healthcheck=<nil>"
expect_in "SAFE_PATHS defaults to /run/secrets" "${cfg}" "SAFE_PATHS=/run/secrets"

"${ENGINE}" create --name "${CTR}" "${IMAGE}" >/dev/null
files="$("${ENGINE}" export "${CTR}" | tar -tvf -)"
mkdir -p "${WORK}/pinned"
"${ENGINE}" export "${CTR}" | tar -x -C "${WORK}/pinned" usr/local/share/mihomo
"${ENGINE}" rm "${CTR}" >/dev/null
for f in usr/local/bin/mihomo usr/local/bin/mihomo-entrypoint \
	usr/local/share/mihomo/geoip.metadb usr/local/share/mihomo/geosite.dat usr/local/share/mihomo/geoip.dat; do
	line="$(printf '%s\n' "${files}" | awk -v f="${f}" '$NF == f')"
	expect_in "${f} is present and root's" "${line}" " 0/0 "
done
line="$(printf '%s\n' "${files}" | awk '$NF == "usr/local/share/mihomo/"')"
expect_in "/usr/local/share/mihomo is open to uid 65532" "${line}" "drwxr-xr-x 0/0 "
line="$(printf '%s\n' "${files}" | awk '$NF == "var/lib/mihomo/"')"
expect_in "/var/lib/mihomo is 65532's, mode 0700" "${line}" "drwx------ 65532/65532 "
for f in root/.config/mihomo bin/sh bin/busybox usr/sbin/iptables sbin/iptables; do
	if printf '%s\n' "${files}" | awk '{ print $NF }' | grep -qx "${f}/\?"; then
		fail "${f} is in the image"
	fi
done
echo "ok: no upstream home, shell or iptables"

# --- 2. passthrough -----------------------------------------------------------

out="$("${ENGINE}" run --rm "${IMAGE}" -v)"
expect_in "mihomo is the version the label names (else MIHOMO_IMAGE_DIGEST is stale)" \
	"${out}" "Mihomo Meta v${VERSION} "
out="$("${ENGINE}" run --rm "${IMAGE}" generate vless-x25519)"
expect_in "generate vless-x25519 passes through to mihomo" "${out}" "PrivateKey: "
rc=0
out="$("${ENGINE}" run --rm "${IMAGE}" run -d /tmp 2>&1)" || rc=$?
[ "${rc}" = 2 ] || fail "run with flags: exited ${rc}, expected 2: ${out}"
expect_in "run takes no flags (2)" "${out}" "\`run\` takes no arguments"

# --- 3. a subscription from a file, read-only root ----------------------------

mkdir -p "${WORK}/secrets" "${WORK}/www/sub" "${WORK}/home"
TOKEN="smoke-$$-$(python3 -c 'import secrets; print(secrets.token_hex(8))')"
SUB_URL="http://127.0.0.1:${TARGET_PORT}/sub/${TOKEN}"
printf '%s\n' "${SUB_URL}" >"${WORK}/secrets/subscription_url"
printf 'DOMAIN,direct.test\nIP-CIDR,127.0.0.0/8,no-resolve\n' >"${WORK}/secrets/direct_rules"
printf 'NOT-A-RULE-%s,x\n' "${TOKEN}" >"${WORK}/secrets/bad_rule"
chmod 0400 "${WORK}/secrets/"*
mkdir "${WORK}/secrets/a_directory"
printf 'vless://6b0c7f3e-3c3a-4f43-9a63-1f0b3d1c2e77@127.0.0.1:%s?encryption=none&security=none&type=tcp#smoke-server' "${DEAD_PORT}" |
	base64 -w0 >"${WORK}/www/sub/${TOKEN}"
touch "${WORK}/www/generate_204"
printf '203.0.113.7\n' >"${WORK}/www/ip"
SECRETS=("${SUB_URL}" "${TOKEN}")
config "${WORK}/conf"

python3 -m http.server "${TARGET_PORT}" --bind 127.0.0.1 --directory "${WORK}/www" \
	>"${WORK}/httpd.log" 2>&1 &
HTTPD_PID=$!
for _ in $(seq 1 50); do
	curl --noproxy '' -fs -o /dev/null "http://127.0.0.1:${TARGET_PORT}/generate_204" && break
	sleep 0.2
done

# The home directory starts empty, as a fresh volume does.
"${ENGINE}" run -d --name "${CTR}" "${RUN_ARGS[@]}" --read-only \
	-v "${WORK}/conf:/etc/mihomo:ro" -v "${WORK}/secrets:/run/secrets:ro" -v "${WORK}/home:/var/lib/mihomo" \
	-e MIHOMO_HEALTHCHECK_PROXY="http://127.0.0.1:${MIXED_PORT}" \
	-e MIHOMO_HEALTHCHECK_URL="http://127.0.0.1:${TARGET_PORT}/generate_204" \
	-e MIHOMO_CONF__log_level=debug -e MIHOMO_SMOKE_TYPO=1 \
	"${IMAGE}" >/dev/null

logs=""
for _ in $(seq 1 30); do
	logs="$("${ENGINE}" logs "${CTR}" 2>&1)"
	case "${logs}" in *"Start initial provider direct"*) break ;; esac
	sleep 1
done
ALL_OUTPUT+="${logs}"
expect_in "mihomo listens on the mixed port" "${logs}" "proxy listening at: 127.0.0.1:${MIXED_PORT}"
expect_in "the subscription provider starts" "${logs}" "Start initial provider sub"
expect_in "the rule provider is read from /run/secrets (default SAFE_PATHS)" "${logs}" "Start initial provider direct"
expect_not_in "nothing is downloaded at start" "${logs}" "start download"
expect_in "the subscription was fetched from the URL in the secret" "$(cat "${WORK}/httpd.log")" \
	"\"GET /sub/${TOKEN} HTTP/1.1\" 200"
[ -s "${WORK}/home/proxies/sub.yaml" ] || fail "the provider cache is not in MIHOMO_HOME"
echo "ok: the provider cache is in MIHOMO_HOME"

top="$("${ENGINE}" top "${CTR}" user args | tr -s ' ')"
expect_in "PID 1 is mihomo, as nonroot (65532)" "${top}" \
	"nonroot /usr/local/bin/mihomo -d /var/lib/mihomo -f /var/lib/mihomo/config.json"
[ "$(stat -c %a "${WORK}/home/config.json")" = 600 ] || fail "the resolved config is not mode 0600"
echo "ok: the resolved config is mode 0600"
for f in geoip.metadb geosite.dat geoip.dat; do
	cmp -s "${WORK}/home/${f}" "${WORK}/pinned/usr/local/share/mihomo/${f}" ||
		fail "${f} in a fresh home is not the image's pinned copy"
done
echo "ok: a fresh home is seeded with the pinned geodata"

expect_in "summary header" "${logs}" "[envconf] mihomo: effective configuration"
expect_in "summary footer" "${logs}" "[envconf] precedence: image default < environment"
expect_in "summary names the version" "${logs}" "mihomo = Mihomo Meta v${VERSION} "
expect_in "summary names the source file" "${logs}" "source=config         /etc/mihomo/config.json"
expect_in "summary maps the subscription" "${logs}" \
	"proxy-providers.sub.url <- /run/secrets/subscription_url   (/etc/mihomo/config.json)"
expect_in "MIHOMO_CONF__* is reported, not applied" "${logs}" \
	"WARN: MIHOMO_CONF__log_level is set, but this image has no MIHOMO_CONF__ passthrough channel"
expect_in "an unknown MIHOMO_* name warns" "${logs}" "WARN: MIHOMO_SMOKE_TYPO is set but neither"

# --- 4. the healthcheck -------------------------------------------------------

hc() { "${ENGINE}" exec "$@" "${CTR}" /usr/local/bin/mihomo-entrypoint healthcheck 2>&1; }

out="$(hc)" || fail "healthcheck through the mixed port: ${out}"
ALL_OUTPUT+="${out}"
expect_in "healthcheck exits 0 on a 2xx through the mixed port" "${out}" "200 OK"
logs="$("${ENGINE}" logs "${CTR}" 2>&1)"
expect_in "the probe's target went DIRECT by the rule from /run/secrets" "${logs}" \
	"127.0.0.1:${TARGET_PORT} match RuleSet(direct) using DIRECT"

started=$(date +%s)
rc=0
out="$(hc -e MIHOMO_HEALTHCHECK_URL=http://192.0.2.1/ -e MIHOMO_HEALTHCHECK_TIMEOUT=3s)" || rc=$?
elapsed=$(($(date +%s) - started))
[ "${rc}" = 1 ] || fail "unroutable URL: healthcheck exited ${rc}: ${out}"
[ "${elapsed}" -le 6 ] || fail "unroutable URL: healthcheck took ${elapsed}s against a 3s timeout"
echo "ok: an unroutable URL exits 1 within the timeout (${elapsed}s)"
logs="$("${ENGINE}" logs "${CTR}" 2>&1)"
ALL_OUTPUT+="${logs}"
expect_in "anything else goes to the subscription's one server" "${logs}" \
	"--> 192.0.2.1:80 error: 127.0.0.1:${DEAD_PORT} connect error"

ip=(-e MIHOMO_HEALTHCHECK_URL="http://127.0.0.1:${TARGET_PORT}/ip")
out="$(hc "${ip[@]}" -e MIHOMO_HEALTHCHECK_EXPECT='^203\.0\.113\.7\s*$')" || fail "the expected exit IP: ${out}"
expect_in "a body matching MIHOMO_HEALTHCHECK_EXPECT passes" "${out}" "matches MIHOMO_HEALTHCHECK_EXPECT"
rc=0
out="$(hc "${ip[@]}" -e MIHOMO_HEALTHCHECK_EXPECT='^198\.51\.100\.9\s*$')" || rc=$?
[ "${rc}" = 1 ] || fail "a changed exit IP: healthcheck exited ${rc}: ${out}"
expect_in "a changed exit IP exits 1 and shows the body" "${out}" \
	'does not match MIHOMO_HEALTHCHECK_EXPECT: "203.0.113.7\n"'

out="$(hc -e MIHOMO_HEALTHCHECK_PROXY=)" || fail "liveness: ${out}"
expect_in "without a proxy it checks liveness and says egress was not probed" \
	"${out}" "egress was not probed"

"${ENGINE}" rm -f "${CTR}" >/dev/null

# --- 5. refusals --------------------------------------------------------------

# refuse <label> <needle> <conf-dir> [run args...]: exit 78, needle in output.
# Bounded, so a case that starts mihomo instead fails rather than hangs.
refuse() {
	local label="$1" needle="$2" conf="$3" rc=0 out
	shift 3
	out="$(timeout 60 "${ENGINE}" run --rm --name "${CTR}-refusal" "${RUN_ARGS[@]}" \
		-v "${conf}:/etc/mihomo:ro" -v "${WORK}/secrets:/run/secrets:ro" \
		"$@" "${IMAGE}" 2>&1)" || rc=$?
	"${ENGINE}" rm -f "${CTR}-refusal" >/dev/null 2>&1 || true
	ALL_OUTPUT+="${out}"
	LAST="${out}"
	[ "${rc}" = 78 ] || {
		printf '%s\n' "${out}" | tail -20
		fail "${label}: exited ${rc}, expected 78"
	}
	expect_in "refused (78): ${label}" "${out}" "${needle}"
}

config "${WORK}/missing" '{"$file": "/run/secrets/absent"}'
refuse "a missing file" \
	"/etc/mihomo/config.json: proxy-providers.sub.url: /run/secrets/absent does not exist" "${WORK}/missing"

config "${WORK}/directory" '{"$file": "/run/secrets/a_directory"}'
refuse "a directory at the referenced path" \
	"proxy-providers.sub.url: /run/secrets/a_directory is a directory" "${WORK}/directory"

config "${WORK}/relative" '{"$file": "subscription_url"}'
refuse "a relative path" 'proxy-providers.sub.url: "$file" must be an absolute path' "${WORK}/relative"

config "${WORK}/other-key" '{"$file": "/run/secrets/subscription_url", "other": 1}'
refuse "\$file beside another key" \
	'proxy-providers.sub.url: an object holding "$file" holds nothing else, and this one also holds other' \
	"${WORK}/other-key"

config "${WORK}/yaml"
printf 'log-level: debug\n' >"${WORK}/yaml/config.yaml"
refuse "a .yaml file in the source directory" "/etc/mihomo/config.yaml is not a file named config.json" "${WORK}/yaml"

config "${WORK}/controller" "" '"external-controller": "0.0.0.0:9090",'
refuse "a REST API beyond loopback with no secret" \
	"external-controller is 0.0.0.0:9090, beyond loopback, and secret is empty" "${WORK}/controller"

refuse "CLASH_CONFIG_STRING beside the image's config" "CLASH_CONFIG_STRING is set" \
	"${WORK}/conf" -e CLASH_CONFIG_STRING=bWl4ZWQtcG9ydDogNzg5MAo=

config "${WORK}/rejected" "" "" '[{"$file": "/run/secrets/bad_rule"}, "MATCH,out"]'
refuse "a config mihomo -t rejects" "mihomo -t refused the configuration" "${WORK}/rejected"
expect_in "mihomo's message is shown, the resolved rule redacted" "${LAST}" "rules[0] [<redacted>] error"

printf '%s\n' "x" >"${WORK}/locked"
chmod 0000 "${WORK}/locked"
refuse "a file uid 65532 cannot read" "/run/secrets/subscription_url is not readable by uid 65532" \
	"${WORK}/conf" -v "${WORK}/locked:/run/secrets/subscription_url:ro"

refuse "a healthcheck expression that does not compile" \
	"MIHOMO_HEALTHCHECK_EXPECT is not a regular expression in Go's RE2 syntax" \
	"${WORK}/conf" -e 'MIHOMO_HEALTHCHECK_EXPECT=^(?!10\.)'

refuse "a read-only root without a volume on MIHOMO_HOME" \
	"MIHOMO_HOME is /var/lib/mihomo, which is not writable by uid 65532" "${WORK}/conf" --read-only

# --- 6. no secret anywhere ----------------------------------------------------

for s in "${SECRETS[@]}"; do
	case "${ALL_OUTPUT}" in
	*"${s}"*) fail "a secret value appears in the output" ;;
	esac
done
echo "ok: no subscription URL in any log, summary or refusal"
echo "PASS: mihomo smoke (${IMAGE})"
