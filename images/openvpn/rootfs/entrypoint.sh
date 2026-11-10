#!/bin/sh
# Start OpenVPN as a client whose network namespace has no way out but the
# tunnel. Before openvpn runs, each default route is swapped for host routes
# to the servers the config names, so nothing leaves while the tunnel is
# down, on the first start too, when openvpn has not yet routed anything into
# it. See images/openvpn/README.md.
#
#   openvpn-entrypoint [run]          check, kill switch, then exec openvpn
#   openvpn-entrypoint healthcheck    pass only while traffic is routed into a tun device
#   openvpn-entrypoint <args...>      exec openvpn with those arguments
set -eu

# shellcheck source=/dev/null
. /usr/local/lib/envconf.sh

CONFIG="${OPENVPN_CONFIG:-/etc/openvpn/client.conf}"

# EX_CONFIG, the code every image in this repository refuses a configuration
# with.
refuse() {
	echo "FATAL: $*" >&2
	exit 78
}

# The device the namespace's catch-all route leads to: openvpn's def1 pair
# (0.0.0.0/1 and 128.0.0.0/1), or a default route.
routed_dev() {
	{ ip -4 route show 0.0.0.0/1; ip -4 route show default; } 2>/dev/null |
		sed -n 's/.* dev \([^ ]*\).*/\1/p' | head -n 1
}

healthcheck() {
	dev="$(routed_dev)"
	[ -n "${dev}" ] || { echo "unhealthy: no route leads anywhere, so the tunnel is not up" >&2; exit 1; }
	[ -e "/sys/class/net/${dev}/tun_flags" ] || { echo "unhealthy: traffic is routed to ${dev}, which is not a tun device" >&2; exit 1; }
	ip -o link show dev "${dev}" | grep -q '[<,]UP[,>]' || { echo "unhealthy: ${dev} is down" >&2; exit 1; }
	echo "healthy: traffic is routed into ${dev}"
}

case "${1:-run}" in
healthcheck) healthcheck; exit 0 ;;
run)
	[ "$#" -le 1 ] || refuse "\`run\` takes no arguments: openvpn is configured by \$OPENVPN_CONFIG. To run openvpn with arguments of your own, give them without \`run\`."
	;;
*) exec openvpn "$@" ;;
esac

envconf_warn_unknown OPENVPN "OPENVPN_CONFIG" "its one setting is OPENVPN_CONFIG"
envconf_refuse_newline OPENVPN_CONFIG "${CONFIG}"
case "${CONFIG}" in /*) ;; *) refuse "OPENVPN_CONFIG is ${CONFIG}, which is not an absolute path" ;; esac
[ -f "${CONFIG}" ] || refuse "OPENVPN_CONFIG is ${CONFIG}, which is not a file. Mount the client config there"
[ -r "${CONFIG}" ] || refuse "${CONFIG} is not readable by uid $(id -u)"
[ -c /dev/net/tun ] || refuse "/dev/net/tun is missing: run with --device /dev/net/tun (Compose: devices: [/dev/net/tun])"

# The config's directives, one per line: comments, blank lines and CRs gone,
# and inline blocks skipped, whose contents are keys and certificates, except
# <connection>, whose contents are directives.
directives() {
	tr -d '\r' <"${CONFIG}" | awk '
		inblock { if ($0 ~ "^[ \t]*</" inblock ">[ \t]*$") inblock = ""; next }
		/^[ \t]*<\/connection>[ \t]*$/ { next }
		/^[ \t]*<[A-Za-z0-9-]+>[ \t]*$/ {
			tag = $0; gsub(/[ \t<>]/, "", tag)
			if (tag != "connection") inblock = tag
			next
		}
		{ sub(/^[ \t]+/, "") }
		/^([#;]|$)/ { next }
		{ print }
	'
}

# Each of these would take openvpn's log away from the container's output.
for d in daemon log log-append syslog; do
	if directives | awk -v d="${d}" '$1 == d { found = 1 } END { exit !found }'; then
		refuse "${CONFIG} has \`${d}\`, which would take openvpn's log away from the container's output. Remove it"
	fi
done
# With no file and no inline block, openvpn asks for the login on a terminal
# the container does not have, and waits there for ever.
if directives | awk '$1 == "auth-user-pass" && NF == 1 { found = 1 } END { exit !found }' &&
	! tr -d '\r' <"${CONFIG}" | grep -q '^[[:space:]]*<auth-user-pass>[[:space:]]*$'; then
	refuse "${CONFIG} asks for a login (auth-user-pass) and holds none. Put it inline: <auth-user-pass>, the user and the password on two lines, then </auth-user-pass>"
fi

hosts="$(directives | awk '$1 == "remote" && NF >= 2 { print $2 }' | sort -u)"
[ -n "${hosts}" ] || refuse "${CONFIG} names no server: it has no \`remote\` line"

addrs=""
for h in ${hosts}; do
	a="$(getent ahosts "${h}" 2>/dev/null | awk '{ print $1 }' | sort -u)"
	if [ -z "${a}" ]; then
		envconf_warn "the server ${h} does not resolve; openvpn cannot reach it"
		continue
	fi
	addrs="${addrs} ${a}"
done
[ -n "${addrs}" ] || refuse "none of the servers in ${CONFIG} resolves (${hosts}), so there is nothing to route to; refusing to start rather than leave the default route in place"

# The kill switch. A server reached through a gateway gets a host route via
# that gateway; one on a network this namespace is directly on needs none.
# Then every default route goes. From here on, an address that is neither a
# server, nor on a directly connected network, nor routed into the tunnel by
# openvpn has no route at all.
pinned=""
for a in ${addrs}; do
	case "${a}" in *:*) fam=-6 ;; *) fam=-4 ;; esac
	r="$(ip "${fam}" -o route get "${a}" 2>/dev/null)" || continue
	via="$(printf '%s\n' "${r}" | sed -n 's/.* via \([^ ]*\).*/\1/p')"
	dev="$(printf '%s\n' "${r}" | sed -n 's/.* dev \([^ ]*\).*/\1/p')"
	[ -n "${via}" ] || continue
	ip "${fam}" route replace "${a}" via "${via}" dev "${dev}" 2>/dev/null ||
		refuse "could not add a route to ${a}: the container needs NET_ADMIN (Compose: cap_add: [NET_ADMIN])"
	pinned="${pinned} ${a}"
done
for fam in -4 -6; do
	while ip "${fam}" route show default 2>/dev/null | grep -q .; do
		ip "${fam}" route del default 2>/dev/null ||
			refuse "could not remove the default route: the container needs NET_ADMIN (Compose: cap_add: [NET_ADMIN])"
	done
done

{
	printf 'OPENVPN_CONFIG\0%s\0%s\0\0' "${CONFIG}" "$([ -n "${OPENVPN_CONFIG:-}" ] && echo env || echo default)"
	printf 'servers\0%s\0config\0%s\0' "$(printf '%s' "${addrs}" | tr -s ' \n' '  ' | sed 's/^ //; s/ $//')" "${CONFIG}"
	printf 'kill switch\0%s\0image\0\0' "default routes removed; host routes to:${pinned:- none needed}"
} | envconf_summary OPENVPN "" "effective configuration" "precedence: image default < environment"

# Later options win over the config's: the tun device and its routes outlive a
# reconnect, so traffic waits in the tunnel instead of finding the way the
# kill switch closed; every IPv4 destination goes into the tunnel even if the
# server pushes no route; and no script runs in this privileged container.
exec openvpn --config "${CONFIG}" --persist-tun --persist-key \
	--redirect-gateway def1 --script-security 1
