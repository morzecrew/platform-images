#!/bin/sh
# Start OpenVPN as a client whose network namespace has no way out but the
# tunnel. Before openvpn runs, each default route is swapped for host routes
# to the servers the config names, so nothing leaves while the tunnel is
# down, on the first start too, when openvpn has not yet routed anything into
# it. With OPENVPN_UPSTREAMS, one openvpn for each openvpn:// line of an
# upstreams list, each on a device of its own. See images/openvpn/README.md.
#
#   openvpn-entrypoint [run]              check, kill switch, then openvpn, started again whenever it exits
#   openvpn-entrypoint healthcheck [<k>]  pass only while traffic is routed into a tun device; with a list,
#                                         while any tunnel is up, or tun<k>
#   openvpn-entrypoint <args...>          exec openvpn with those arguments
set -eu

# shellcheck source=/dev/null
. /usr/local/lib/envconf.sh

CONFIG="${OPENVPN_CONFIG:-/etc/openvpn/client.conf}"
LIST="${OPENVPN_UPSTREAMS:-}"
# Where a list's tunnels go, decoded, one config per device: a tmpfs Docker
# and Podman mount even under a read-only root, in a directory root's alone.
TUNNELS=/dev/shm/openvpn

# EX_CONFIG, the code every image in this repository refuses a configuration
# with.
refuse() {
	echo "FATAL: $*" >&2
	exit 78
}

# The device a route leads to, or nothing.
dev_of() { sed -n 's/.* dev \([^ ]*\).*/\1/p' | head -n 1; }

# The catch-all route must lead into the tunnel whole: openvpn's def1 pair,
# both halves to one device, or else a default route.
healthcheck() {
	lo="$(ip -4 route show 0.0.0.0/1 2>/dev/null | dev_of)"
	hi="$(ip -4 route show 128.0.0.0/1 2>/dev/null | dev_of)"
	if [ -n "${lo}${hi}" ]; then
		[ "${lo}" = "${hi}" ] || { echo "unhealthy: 0.0.0.0/1 leads to ${lo:-nowhere} and 128.0.0.0/1 to ${hi:-nowhere}" >&2; exit 1; }
		dev="${lo}"
	else
		dev="$(ip -4 route show default 2>/dev/null | dev_of)"
	fi
	[ -n "${dev}" ] || { echo "unhealthy: no route leads anywhere, so the tunnel is not up" >&2; exit 1; }
	[ -e "/sys/class/net/${dev}/tun_flags" ] || { echo "unhealthy: traffic is routed to ${dev}, which is not a tun device" >&2; exit 1; }
	ip -o link show dev "${dev}" | grep -q '[<,]UP[,>]' || { echo "unhealthy: ${dev} is down" >&2; exit 1; }
	echo "healthy: traffic is routed into ${dev}"
}

# With a list, nothing is routed into a tunnel: what dials out binds to its
# device. A tunnel is up while its device is, with an address, as openvpn
# leaves it once connected and keeps it through a reconnect (persist-tun).
# Healthy while any is, or, given k, while tun<k> is.
healthcheck_list() {
	case "${1-x}" in x | [0-9] | [1-9][0-9]) ;; *) echo "unhealthy: \`healthcheck\` takes a tunnel's number, such as 0 for tun0" >&2; exit 1 ;; esac
	up="" down=""
	for f in "${TUNNELS}"/tun*.conf; do
		[ -e "${f}" ] || continue
		dev="${f##*/}" && dev="${dev%.conf}"
		[ -z "${1:-}" ] || [ "${dev}" = "tun$1" ] || continue
		if [ -e "/sys/class/net/${dev}/tun_flags" ] &&
			ip -o link show dev "${dev}" 2>/dev/null | grep -q '[<,]UP[,>]' &&
			ip -o addr show dev "${dev}" 2>/dev/null | grep -q ' inet'; then
			up="${up} ${dev}"
		else
			down="${down} ${dev}"
		fi
	done
	[ -n "${up}${down}" ] || { echo "unhealthy: no tunnel${1:+ tun$1} was started" >&2; exit 1; }
	[ -n "${up}" ] || { echo "unhealthy: down:${down}" >&2; exit 1; }
	echo "healthy: up:${up}${down:+; down:${down}}"
}

case "${1:-run}" in
healthcheck)
	shift
	if [ -n "${LIST}" ]; then
		healthcheck_list "$@"
	else
		[ "$#" = 0 ] || { echo "unhealthy: a tunnel's number is for OPENVPN_UPSTREAMS, which is unset" >&2; exit 1; }
		healthcheck
	fi
	exit 0
	;;
run)
	[ "$#" -le 1 ] || refuse "\`run\` takes no arguments: openvpn is configured by \$OPENVPN_CONFIG or \$OPENVPN_UPSTREAMS. To run openvpn with arguments of your own, give them without \`run\`."
	;;
*) exec openvpn "$@" ;;
esac

# The kill switch's first half, before anything else runs: each default route
# goes, its gateway noted, so that a container sharing this namespace has no
# way out from the moment this one starts. Names still resolve: Docker's
# resolver (127.0.0.11) and Podman's (on the bridge) are on networks this
# namespace is directly on.
gw4="$(ip -4 route show default 2>/dev/null | sed -n '1s/^default via \([^ ]*\) dev \([^ ]*\).*/\1 \2/p')"
gw6="$(ip -6 route show default 2>/dev/null | sed -n '1s/^default via \([^ ]*\) dev \([^ ]*\).*/\1 \2/p')"
for fam in -4 -6; do
	while ip "${fam}" route show default 2>/dev/null | grep -q .; do
		ip "${fam}" route del default 2>/dev/null ||
			refuse "could not remove the default route: the container needs NET_ADMIN (Compose: cap_add: [NET_ADMIN])"
	done
done

# pin <address>: a host route via the noted gateway of its family, unless the
# address is on a network this namespace is directly on, which needs none.
pinned=""
pin() {
	case "$1" in *:*) fam=-6 gw="${gw6}" ;; *) fam=-4 gw="${gw4}" ;; esac
	ip "${fam}" -o route get "$1" >/dev/null 2>&1 && return 0
	[ -n "${gw}" ] || return 0
	ip "${fam}" route replace "$1" via "${gw% *}" dev "${gw#* }" 2>/dev/null ||
		refuse "could not add a route to $1: the container needs NET_ADMIN (Compose: cap_add: [NET_ADMIN])"
	pinned="${pinned} $1"
}

# A resolver beyond this namespace's networks, as a host's own can be, keeps a
# route of its own, so the servers' names can still be looked up.
# shellcheck disable=SC2013 # one address per line, and a while loop would lose pinned in its subshell
for ns in $(awk '$1 == "nameserver" { print $2 }' /etc/resolv.conf 2>/dev/null); do
	case "${ns}" in 127.* | ::1) ;; *) pin "${ns}" ;; esac
done

envconf_warn_unknown OPENVPN "OPENVPN_CONFIG OPENVPN_UPSTREAMS" "its settings are OPENVPN_CONFIG and OPENVPN_UPSTREAMS"

# check_file <name> <path>: the file a setting names is one this user reads.
check_file() {
	envconf_refuse_newline "$1" "$2"
	case "$2" in /*) ;; *) refuse "$1 is $2, which is not an absolute path" ;; esac
	[ -f "$2" ] || refuse "$1 is $2, which is not a file. Mount it there"
	[ -r "$2" ] || refuse "$2 is not readable by uid $(id -u)"
}

# A config's directives, one per line: comments, blank lines and CRs gone,
# and inline blocks skipped, whose contents are keys and certificates, except
# <connection>, whose contents are directives.
directives() {
	tr -d '\r' <"$1" | awk '
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
has() { directives "$1" | awk -v d="$2" '$1 == d { found = 1 } END { exit !found }'; }

# check_config <path> <label>: refuses what would hang openvpn or take its log
# away, then prints the addresses its servers resolve to, or nothing.
check_config() {
	for d in daemon log log-append syslog; do
		! has "$1" "${d}" || refuse "$2 has \`${d}\`, which would take openvpn's log away from the container's output. Remove it"
	done
	# With no file and no inline block, openvpn asks for the login on a
	# terminal the container does not have, and waits there for ever.
	if directives "$1" | awk '$1 == "auth-user-pass" && NF == 1 { found = 1 } END { exit !found }' &&
		! tr -d '\r' <"$1" | grep -q '^[[:space:]]*<auth-user-pass>[[:space:]]*$'; then
		refuse "$2 asks for a login (auth-user-pass) and holds none. Put it inline: <auth-user-pass>, the user and the password on two lines, then </auth-user-pass>"
	fi
	hosts="$(directives "$1" | awk '$1 == "remote" && NF >= 2 { print $2 }' | sort -u)"
	[ -n "${hosts}" ] || refuse "$2 names no server: it has no \`remote\` line"
	for h in ${hosts}; do
		a="$(getent ahosts "${h}" 2>/dev/null | awk '{ print $1 }' | sort -u)"
		[ -n "${a}" ] || envconf_warn "$2: the server ${h} does not resolve; openvpn cannot reach it"
		printf '%s\n' "${a}"
	done
}

# The tunnels a list holds, one per line: "<device> <line number> <config>".
tunnels=""
if [ -n "${LIST}" ]; then
	[ -z "${OPENVPN_CONFIG:-}" ] || refuse "OPENVPN_CONFIG and OPENVPN_UPSTREAMS are both set: one tunnel, or one for each line of a list, not both"
	check_file OPENVPN_UPSTREAMS "${LIST}"
else
	check_file OPENVPN_CONFIG "${CONFIG}"
fi
[ -c /dev/net/tun ] || refuse "/dev/net/tun is missing: run with --device /dev/net/tun (Compose: devices: [/dev/net/tun])"
# Reverse-path filtering drops what comes back through a tunnel no route
# leads into, as a list's are: the source is reachable by no route at all.
# The namespace's own setting, which only the runtime can change: /proc/sys
# is read-only in a container. A device takes default's when created.
if [ -n "${LIST}" ]; then
	rp="$(cat /proc/sys/net/ipv4/conf/all/rp_filter /proc/sys/net/ipv4/conf/default/rp_filter 2>/dev/null | tr -d '\n')"
	[ "${rp}" = 00 ] || refuse "reverse-path filtering is on (rp_filter all and default: ${rp}), which drops the replies that come back through a tunnel: run with --sysctl net.ipv4.conf.all.rp_filter=0 --sysctl net.ipv4.conf.default.rp_filter=0 (Compose: sysctls: {net.ipv4.conf.all.rp_filter: 0, net.ipv4.conf.default.rp_filter: 0})"
fi

if [ -n "${LIST}" ]; then
	rm -rf "${TUNNELS}"
	(umask 077 && mkdir -p "${TUNNELS}")
	# "<line number> <what follows openvpn://>" for each line naming openvpn,
	# as the xray image counts them, and "-" when nothing follows.
	lines="$(tr -d '\r' <"${LIST}" | awk '
		{ sub(/^[ \t]+/, "") }
		/^#/ || NF == 0 { next }
		$1 == "openvpn" || $1 == "openvpn://" { print NR, "-"; next }
		$1 ~ /^openvpn:\/\// { print NR, substr($1, 11) }
	')"
	[ -n "${lines}" ] || refuse "${LIST} has no openvpn:// line, so there is no tunnel to run"
	addrs="" k=0
	while read -r n body; do
		label="line ${n} of ${LIST}"
		[ "${body}" != - ] || refuse "${label} names openvpn and holds no config: write openvpn://, then the config gzipped and base64url-encoded"
		f="${TUNNELS}/tun${k}.conf"
		case $((${#body} % 4)) in 2) body="${body}==" ;; 3) body="${body}=" ;; esac
		if ! { printf '%s' "${body}" | tr '_-' '/+' | base64 -d >"${f}.gz" 2>/dev/null &&
			gunzip -c "${f}.gz" >"${f}" 2>/dev/null; }; then
			refuse "${label} is not openvpn:// and a config, gzipped and base64url-encoded"
		fi
		rm -f "${f}.gz"
		a="$(check_config "${f}" "${label}")"
		if [ -n "${a}" ]; then
			addrs="${addrs} ${a}"
			tunnels="${tunnels}tun${k} ${n} ${f}
"
		else
			envconf_warn "none of the servers on ${label} resolves, so tun${k} does not start"
		fi
		k=$((k + 1))
	done <<EOF
${lines}
EOF
	[ -n "${addrs}" ] || refuse "none of the servers in ${LIST} resolves, so there is nothing to route to"
else
	addrs="$(check_config "${CONFIG}" "${CONFIG}")"
	[ -n "${addrs}" ] || refuse "none of the servers in ${CONFIG} resolves, so there is nothing to route to"
fi

# The kill switch's second half: each server keeps a route, via the gateway
# it was reached by. From here on, an address that is neither a server, nor a
# resolver, nor on a directly connected network, nor routed into a tunnel by
# openvpn has no route at all.
# shellcheck disable=SC2086 # one address per word
addrs="$(printf '%s\n' ${addrs} | sort -u | tr '\n' ' ' | sed 's/ $//')"
for a in ${addrs}; do
	pin "${a}"
done

{
	if [ -n "${LIST}" ]; then
		printf 'OPENVPN_UPSTREAMS\0%s\0env\0\0' "${LIST}"
		printf 'tunnels\0%s\0list\0%s\0' "$(printf '%s' "${tunnels}" | awk '{ printf "%s%s (line %s)", (NR > 1 ? ", " : ""), $1, $2 }')" "${LIST}"
	else
		printf 'OPENVPN_CONFIG\0%s\0%s\0\0' "${CONFIG}" "$([ -n "${OPENVPN_CONFIG:-}" ] && echo env || echo default)"
	fi
	printf 'servers\0%s\0config\0%s\0' "${addrs}" "${LIST:-${CONFIG}}"
	printf 'kill switch\0%s\0image\0\0' "default routes removed; host routes to:${pinned:- none needed}"
} | envconf_summary OPENVPN "" "effective configuration" "precedence: image default < environment"

# supervise <label> <config> [<openvpn options>...]: openvpn as this shell's
# child, started again whenever it exits, rather than in this shell's place.
# A restarted container gets a new network namespace, and a container sharing
# this one, such as a proxy that dials out through the tunnel, would keep the
# old one, cut off from it. The kill switch outlives openvpn: when openvpn
# exits, its tun device and routes go with it, and nothing has a route out. A
# server that moved to a new address still takes a restart of the container,
# which resolves the names again.
#
# Later options win over the config's: the tun device and its routes outlive
# a reconnect, so traffic waits in the tunnel instead of finding the way the
# kill switch closed, and no script runs in this privileged container. The
# temporary directory openvpn refuses to start without is /dev/shm, a tmpfs
# Docker and Podman mount even under a read-only root, where /tmp is not one
# under Docker's read_only, unless the config names its own or a chroot,
# inside which the directory would be looked for, or TMPDIR names one.
#
# TERM and INT stop openvpn, then this shell. HUP and USR1 go to openvpn,
# for its own restarts.
supervise() {
	label="$1" cfg="$2"
	shift 2
	set -- --config "${cfg}" --persist-tun --persist-key --script-security 1 "$@"
	if [ -z "${TMPDIR:-}" ] && ! has "${cfg}" tmp-dir && ! has "${cfg}" chroot; then
		set -- "$@" --tmp-dir /dev/shm
	fi
	child=""
	stopping=""
	trap 'stopping=1; [ -z "${child}" ] || kill -TERM "${child}" 2>/dev/null || true' TERM INT
	trap '[ -z "${child}" ] || kill -HUP "${child}" 2>/dev/null || true' HUP
	trap '[ -z "${child}" ] || kill -USR1 "${child}" 2>/dev/null || true' USR1
	delay=1
	while :; do
		started="$(date +%s)"
		openvpn "$@" &
		child=$!
		rc=0
		wait "${child}" || rc=$?
		# A trapped signal ends wait early, with openvpn still running.
		while kill -0 "${child}" 2>/dev/null; do
			rc=0
			wait "${child}" || rc=$?
		done
		child=""
		[ -z "${stopping}" ] || exit 0

		# Doubling up to a minute while it keeps failing at once, as a refused
		# config would; back to a second after a run of a minute or more.
		ran=$(($(date +%s) - started))
		[ "${ran}" -lt 60 ] || delay=1
		envconf_warn "${label} exited with ${rc} after ${ran} s; starting it again in ${delay} s, in the same network namespace"
		sleep "${delay}" &
		wait $! || true
		[ -z "${stopping}" ] || exit 0
		delay=$((delay * 2))
		[ "${delay}" -le 60 ] || delay=60
	done
}

# One tunnel: every IPv4 destination goes into it, even if the server pushes
# no route.
[ -n "${LIST}" ] || supervise openvpn "${CONFIG}" --redirect-gateway def1

# A list: an openvpn for each tunnel, on the device of its line, tun0 for the
# first openvpn:// line whether or not it started, each with a supervisor of
# its own. What dials out binds to a tunnel's device (SO_BINDTODEVICE), and
# the kernel sends a socket bound to a device out of that device, with an
# IPv4 route there or not. So each ignores the IPv4 routes its server pushes,
# redirect-gateway and plain route alike, which would claim destinations,
# the default among them, for its own tunnel. IPv6 has no such rule, so a
# pushed route-ipv6 stays.
pids=""
while read -r dev n f; do
	[ -n "${dev}" ] || continue
	supervise "openvpn on ${dev} (line ${n})" "${f}" --dev "${dev}" --dev-type tun \
		--pull-filter ignore redirect-gateway --pull-filter ignore "route " &
	pids="${pids} $!"
done <<EOF
${tunnels}
EOF

# TERM and INT stop every supervisor, and with it its openvpn; HUP and USR1
# reach each openvpn.
trap 'for p in ${pids}; do kill -TERM "${p}" 2>/dev/null || true; done' TERM INT
trap 'for p in ${pids}; do kill -HUP "${p}" 2>/dev/null || true; done' HUP
trap 'for p in ${pids}; do kill -USR1 "${p}" 2>/dev/null || true; done' USR1
for p in ${pids}; do
	while kill -0 "${p}" 2>/dev/null; do wait "${p}" || true; done
done
exit 0
