# openvpn

An [OpenVPN](https://openvpn.net) client for a Compose bundle that sends its
traffic out through an OpenVPN exit and must leak nothing while the tunnel is
down. Before openvpn starts, the entrypoint swaps each default route for host
routes to the servers the config names. So the namespace has no way out but
the tunnel, on the first start too, before openvpn has routed anything into
it. A healthcheck passes only while traffic is routed into the tunnel.

openvpn is Alpine's package, unchanged. The image adds a POSIX sh entrypoint,
`/usr/local/bin/openvpn-entrypoint`, on the shared `envconf.sh`.

| | |
|---|---|
| Image | `ghcr.io/morzecrew/openvpn:2.6.20` |
| Tag | the version of Alpine's `openvpn` package |
| User | root: openvpn needs `NET_ADMIN` for its tun device and routes, and the kill switch for its routes |
| Base | `alpine:3.22`, floating within the release |
| Config | one client config at `OPENVPN_CONFIG` (`/etc/openvpn/client.conf`), mounted read-only |
| Writes | nothing, so a read-only root works as it is |
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
  # as a SOCKS server other services dial at vpn:1080.
  socks:
    image: ghcr.io/morzecrew/xray:26.10.31
    network_mode: service:vpn
```

The config is a client config as a provider or a router exports it, with
its certificates and keys inline. A login goes inline too:

```text
<auth-user-pass>
user
password
</auth-user-pass>
```

## The kill switch

Before openvpn runs, the entrypoint:

1. reads every `remote` line, those inside `<connection>` blocks included;
2. resolves each host, IPv4 and IPv6, with the system resolver;
3. for each address reached through a gateway, adds a host route via that
   gateway (an address on a network the namespace is directly on needs
   none);
4. deletes every default route, IPv4 and IPv6.

From then on, an address that is not a server, not on a directly connected
network, and not routed into the tunnel by openvpn has no route at all.
While openvpn connects, reconnects or restarts, traffic for the outside
finds nothing to take it.

openvpn is then started with these overrides after the config, so they win:

| Option | Why |
|---|---|
| `--persist-tun`, `--persist-key` | the tun device and its routes outlive a reconnect, so traffic waits in the tunnel instead of meeting no route |
| `--redirect-gateway def1` | every IPv4 destination goes into the tunnel, even if the server pushes no route |
| `--script-security 1` | no script in the config runs in this privileged container |

IPv6 goes into the tunnel only if the server pushes IPv6 routes. Otherwise it
has no route, since its default route is gone.

### Limits

- The routes pin the addresses resolved at start. A provider that moves its
  server to a new address is reached again after a restart, which resolves
  the names again. Until then openvpn can't connect, and nothing leaks.
- Directly connected networks stay reachable directly, as they must, for
  the server or a sidecar's peers to be reached at all.
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

Without `NET_ADMIN`, the route changes fail and it exits 78 saying so.

## Healthcheck

```sh
/usr/local/bin/openvpn-entrypoint healthcheck
```

It exits 0 when the catch-all route, openvpn's `0.0.0.0/1` or a default route,
leads to a tun device that is up, and 1 otherwise, with the reason.

## Environment

| Name | Default | |
|---|---|---|
| `OPENVPN_CONFIG` | `/etc/openvpn/client.conf` | the client config, an absolute path |

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

## Layout

| Path | |
|---|---|
| `Dockerfile` | Alpine, openvpn and iproute2, the version check, the entrypoint |
| `rootfs/entrypoint.sh` | the checks, the kill switch, the healthcheck |
| `smoke.sh` | refusals, then the kill switch against a stand-in server: a fresh start with it down, the tunnel up, and it gone again |
