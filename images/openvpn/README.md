# openvpn

An [OpenVPN](https://openvpn.net) client for a Compose bundle that sends its
traffic out through an OpenVPN exit and must leak nothing while the tunnel is
down. Before openvpn starts, the entrypoint swaps each default route for host
routes to the servers the config names. So the namespace has no way out but
the tunnel, on the first start too, before openvpn has routed anything into
it. A healthcheck passes only while traffic is routed into the tunnel.
Given an upstreams list instead, it runs a tunnel for each `openvpn://` line,
each on its own device, for a proxy beside it to dial out through one at a
time ([Several tunnels](#several-tunnels-from-an-upstreams-list)).

openvpn is Alpine's package, unchanged. The image adds a POSIX sh entrypoint,
`/usr/local/bin/openvpn-entrypoint`, on the shared `envconf.sh`.

| | |
|---|---|
| Image | `ghcr.io/morzecrew/openvpn:2.6.20` |
| Tag | the version of Alpine's `openvpn` package |
| User | root: openvpn needs `NET_ADMIN` for its tun device and routes, and the kill switch for its routes |
| Base | `alpine:3.22`, floating within the release |
| Config | one client config at `OPENVPN_CONFIG` (`/etc/openvpn/client.conf`), mounted read-only, or an upstreams list at `OPENVPN_UPSTREAMS` |
| Writes | nothing but openvpn's temporary directory, `/dev/shm`, and a list's decoded configs there, so a read-only root works as it is |
| Logs | openvpn's log, which `docker logs` shows |

This image meets neither route of the
[admission rule](../README.md#which-images-belong-here), because only one
project uses it. It was admitted on the owner's call. See "Admissions on record"
there and [#144](https://github.com/morzecrew/platform-images/issues/144).

## Usage

```yaml
services:
  vpn:
    image: ghcr.io/morzecrew/openvpn:2.6.20
    cap_add: [NET_ADMIN]
    devices: [/dev/net/tun]
    read_only: true
    environment:
      OPENVPN_CONFIG: /run/secrets/upstream
    secrets: [upstream]
    healthcheck:
      test: ["CMD", "/usr/local/bin/openvpn-entrypoint", "healthcheck"]
      interval: 30s
  # Anything that should leave through the tunnel joins its namespace, such
  # as a SOCKS server other services dial at vpn:1080, once it is healthy,
  # and again after each restart of vpn, which brings a new namespace.
  socks:
    image: ghcr.io/morzecrew/xray:26.10.31
    network_mode: service:vpn
    depends_on:
      vpn: {condition: service_healthy, restart: true}
```

The config is a client config as a provider or a router exports it, with
its certificates and keys inline. A login goes inline too:

```text
<auth-user-pass>
user
password
</auth-user-pass>
```

## Several tunnels from an upstreams list

`OPENVPN_UPSTREAMS` names an upstreams list, the file the
[xray image's `$upstreams`](../xray/README.md#any-number-of-upstreams-from-one-list)
reads, in place of `OPENVPN_CONFIG`. Each line whose URL is `openvpn://`
holds a client config, gzipped, then base64url-encoded (padding optional),
and runs as a tunnel of its own:

```sh
printf 'openvpn://%s name=vpn-a\n' "$(gzip -c client.ovpn | base64 -w0 | tr '+/' '-_' | tr -d '=')"
```

```yaml
services:
  vpn:
    image: ghcr.io/morzecrew/openvpn:2.6.20
    cap_add: [NET_ADMIN]
    devices: [/dev/net/tun]
    read_only: true
    # Nothing routes into these tunnels, so the filter would drop their replies.
    sysctls: {net.ipv4.conf.all.rp_filter: 0, net.ipv4.conf.default.rp_filter: 0}
    environment:
      OPENVPN_UPSTREAMS: /run/secrets/upstreams
    secrets: [upstreams]
```

- The k-th line naming `openvpn`, counting from 0 in the file's order, runs
  on `tun<k>`. The xray image counts the same lines for an alias's ports, so
  with `XRAY_UPSTREAM_ALIASES=openvpn=socks5://vpn:1080` the k-th line dials
  `vpn:1080+k`, where a proxy beside this container sends what it is given
  into `tun<k>`. Other lines are skipped. A tunnel whose servers don't
  resolve doesn't start, and keeps its number.
- No tunnel takes a route. What dials out binds to a tunnel's device
  (`SO_BINDTODEVICE`, Xray's `sockopt.interface`), and the kernel sends a
  socket bound to a device out of it, with an IPv4 route there or not. So each
  openvpn ignores the IPv4 routes its server pushes, `redirect-gateway` and
  `route` alike, which would claim destinations, the default among them, for
  one tunnel. IPv6 has no such rule, so it needs a route the server pushes
  (`route-ipv6`), which stays. A config's own `route` or `redirect-gateway`
  still applies, and sends what binds to no device into that tunnel.
- Reverse-path filtering must be off. The replies come from addresses no
  route leads back to, so the filter drops them. `/proc/sys` is read-only in a
  container, so the runtime sets it: `sysctls` as above. Otherwise the
  entrypoint refuses to start.
- Each openvpn has its own supervisor, which starts it again when it exits,
  as for one tunnel. The decoded configs are in `/dev/shm/openvpn`, a
  directory only root reads, and never in the log.
- The kill switch pins every tunnel's servers. The rest of it is as below.

## The kill switch

Before openvpn runs, the entrypoint:

1. deletes every default route, IPv4 and IPv6, noting their gateways. This
   comes first, before any check or lookup, so a container sharing the
   namespace has no way out from the moment this one starts;
2. gives a resolver beyond the namespace's networks, as a host's own can be,
   a host route via the noted gateway. Docker's (127.0.0.11) and Podman's (on
   the bridge) are directly reachable and need none;
3. reads every `remote` line, those inside `<connection>` blocks included,
   and resolves each host, IPv4 and IPv6;
4. gives each server address a host route via the noted gateway of its
   family, unless it is on a network the namespace is directly on.

From then on, an address that is not a server, not such a resolver, not on a
directly connected network, and not routed into the tunnel by openvpn has no
route at all.
While openvpn connects, reconnects or restarts, traffic for the outside
finds nothing to take it.

openvpn is then started with these overrides after the config, so they win:

| Option | Why |
|---|---|
| `--persist-tun`, `--persist-key` | the tun device and its routes outlive a reconnect, so traffic waits in the tunnel instead of meeting no route |
| `--redirect-gateway def1` | every IPv4 destination goes into the tunnel, even if the server pushes no route |
| `--script-security 1` | no script in the config runs in this privileged container |
| `--tmp-dir /dev/shm` | openvpn refuses to start without a writable temporary directory, and `/tmp` is not one under Docker's `read_only`; `/dev/shm` is a tmpfs Docker and Podman mount even then |

IPv6 goes into the tunnel only if the server pushes IPv6 routes. Otherwise it
has no route, since its default route is gone.

### When openvpn exits

openvpn runs as the entrypoint's child, not in its place, and the entrypoint
starts it again whenever it exits. The wait between tries doubles up to a
minute while openvpn keeps failing at once, and goes back to a second after
a run of a minute or more. The container doesn't restart, so its network
namespace stays the same. A restarted container would get a new namespace,
and a container sharing it (Compose: `network_mode: service:<this>`) would
keep the old one, cut off from the tunnel. The kill switch holds between
tries: openvpn's tun device and routes go with it, and nothing else has a
way out.

`TERM` and `INT` stop openvpn and then the entrypoint, which exits 0. `HUP`
and `USR1` go to openvpn, for its own restarts.

### Limits

- The routes pin the addresses resolved at start. A provider that moves its
  server to a new address is reached again after a restart of the container,
  which resolves the names again. Until then openvpn can't connect, and
  nothing leaks. A container sharing the namespace must restart after this
  one (Compose: `depends_on` with `restart: true`), into the new namespace.
- Directly connected networks stay reachable directly, as they must, for
  the server or a sidecar's peers to be reached at all.
- The default route exists from the moment the runtime creates the
  namespace until the entrypoint's first command deletes it. Start anything
  that joins the namespace once this container is healthy (Compose:
  `depends_on` with `condition: service_healthy`), and that window is
  closed to it.
- The healthcheck shows that traffic is routed into the tunnel. It can't tell
  a live server from a dead one, because `persist-tun` keeps the device and
  routes through a reconnect. Prove end-to-end egress through whatever
  dials out through it, as the xray image's healthcheck does.

### Refusals

Each of these exits 78 before any route changes. The message names the
problem, never the config's contents:

- `OPENVPN_CONFIG` that is not an absolute path, not a file, or not readable;
- no `/dev/net/tun`;
- no `remote` line, or no remote that resolves;
- a bare `auth-user-pass` with no inline `<auth-user-pass>` block, on which
  openvpn would wait for a terminal for ever;
- `daemon`, `log`, `log-append` or `syslog`, each of which would take
  openvpn's log away from the container's output.

With a list, these are refused too. The message names the line, never its
contents:

- `OPENVPN_CONFIG` set as well;
- no `openvpn://` line, or a bare `openvpn` with no config after it;
- a line that is not a gzipped config in base64url, or whose config fails
  the checks above;
- reverse-path filtering on (`rp_filter` not 0 in `all` and `default`).

Without `NET_ADMIN`, the route changes fail and it exits 78 saying so.

## Healthcheck

```sh
/usr/local/bin/openvpn-entrypoint healthcheck
```

It exits 0 when the catch-all route leads to a tun device that is up: both
halves of openvpn's `def1` pair, `0.0.0.0/1` and `128.0.0.0/1`, to the same
device, or else a default route. Otherwise it exits 1, with the reason.

With a list, it exits 0 while any tunnel's device is up with an address, and
names each: `healthy: up: tun0 tun1; down: tun2`. `healthcheck <k>` checks
`tun<k>` alone. As for one tunnel, it can't tell a live server from a dead one.

## Environment

| Name | Default | |
|---|---|---|
| `OPENVPN_CONFIG` | `/etc/openvpn/client.conf` | the client config, an absolute path |
| `OPENVPN_UPSTREAMS` | unset | an upstreams list, an absolute path: a tunnel for each `openvpn://` line, in place of `OPENVPN_CONFIG` |

An unknown `OPENVPN_*` name warns. openvpn itself reads no environment
variable.

### Startup summary

```text
[envconf] OPENVPN: effective configuration
[envconf]   source=env          OPENVPN_CONFIG = /run/secrets/upstream
[envconf]   source=config       servers = 203.0.113.7                      (/run/secrets/upstream)
[envconf]   source=image        kill switch = default routes removed; host routes to: 203.0.113.7
[envconf] precedence: image default < environment
```

## Other commands

Arguments other than `run` and `healthcheck` go to openvpn as they are:
`openvpn-entrypoint --version`, or server mode, as the smoke test's stand-in
server runs it. The kill switch is the `run` command's alone.

## Versions

The tag is Alpine's `openvpn` package version for `ALPINE_VERSION`. Both are
in [`docker-bake.hcl`](../../docker-bake.hcl), each with its Renovate
annotation: `alpine` from Docker Hub, and `openvpn` from Repology, whose
package name holds the Alpine release (`alpine_3_22/openvpn`), so moving
`ALPINE_VERSION` means moving that name too. Alpine keeps one version per
branch, so the build refuses a package that no longer matches
`OPENVPN_VERSION`, rather than ship it under the wrong tag.

Renovate's pull request for a new Alpine release moves only `ALPINE_VERSION`,
to the release (`3.24`, never a patch tag). It never automerges, and it fails
that check whenever the new release ships another openvpn. Finish it on its
branch: move the Repology name to the new release and `OPENVPN_VERSION` to the
package that release ships.

## Layout

| Path | |
|---|---|
| `Dockerfile` | Alpine, openvpn and iproute2, the version check, the entrypoint |
| `rootfs/entrypoint.sh` | the checks, the kill switch, openvpn started again when it exits, a list's tunnels, the healthcheck |
| `smoke.sh` | refusals, then the kill switch against a stand-in server: a fresh start with it down, the tunnel up, openvpn killed and started again in place, the server gone again, and a stop; then a list of three tunnels, two up and one dead, each reached through its device |
