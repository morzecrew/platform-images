# openflux

The core of [OpenFlux](https://github.com/p1neappleXpress/OpenFlux): a tunnel whose client and exit meet
on a shared carrier, such as a room or a document on a service that a restricted network still lets
through. The client offers a SOCKS5 proxy, and the exit opens the connections on the free side.

Upstream publishes unsigned binaries and no image, so this one is built from the source of a release tag,
pinned by its commit.

| | |
| --- | --- |
| Image | `ghcr.io/morzecrew/openflux:<OpenFlux version>` |
| Base | `alpine:<release>`, which floats within the release, so the weekly rebuild keeps musl and the CA bundle current |
| Source | `p1neappleXpress/OpenFlux` at tag `v<version>`, refused if the tag no longer names `OPENFLUX_COMMIT`, plus [`patches/`](patches) |
| Runs as | uid 65532, with `HOME` at `/var/lib/openflux` |
| Capability | none, for the `l4` exit and the SOCKS5 client |
| State | `/var/lib/openflux`, owned by 65532, mode 0700. Mount a volume there for rooms, cookie jars and keys |
| Entrypoint | the `openflux` binary itself, so arguments are its flags |
| Licence | GPL-3.0-or-later, as OpenFlux. `LICENSE`, `COPYRIGHT` and `NOTICE` are in `/usr/local/share/doc/openflux` |

The image is Alpine, not distroless, because a bundle may drive several nodes from a shell script of its
own. The `l3` exit and the `tun` inbound need root and `NET_ADMIN`. Nothing here is built or tested for
them.

## Usage

### An exit behind a SOCKS5 upstream

Given `--upstream-proxy`, the exit sends every connection it opens through the proxy: TCP with CONNECT, and UDP with UDP ASSOCIATE.
If the proxy refuses UDP ASSOCIATE, as a TCP-only proxy does, the exit drops that UDP. Nothing goes around
the proxy. Only the carrier's own connections leave directly.

```ini
# /etc/openflux/exit.conf
[Interface]
Role = exit
Mode = l4
EncryptionKeyFile = /run/secrets/openflux_key
CookieStore = /var/lib/openflux/cookies.json

[Transport main]
Type = <transport>
URL = <the carrier's link>
```

The key file must be readable by uid 65532.

```sh
docker run -d --read-only --tmpfs /tmp --cap-drop ALL --security-opt no-new-privileges \
  -v /etc/openflux:/etc/openflux:ro -v /etc/openflux/key:/run/secrets/openflux_key:ro \
  -v openflux:/var/lib/openflux \
  ghcr.io/morzecrew/openflux:0.17.1 --config /etc/openflux/exit.conf --upstream-proxy=gate:1080
```

`--upstream-proxy` takes `host:port` or `socks5://user:pass@host:port`.

### Links

`--make-link -` reads a profile as JSON on stdin and answers with JSON holding the `openflux://` link that
apps scan or paste. `--parse-link <link>` reads one back. A link carries the key, so treat it as a secret.

```sh
echo '{"name":"phone","negotiate":true,"secret":"<key>","transports":[{"type":"<transport>","url":"<link>"}]}' |
  docker run --rm -i ghcr.io/morzecrew/openflux:0.17.1 --make-link -
```

## Patches

Changes that no release carries yet, applied in the order of their names. Each is dropped once a release
carries it.

| Patch | What | From |
| --- | --- | --- |
| [`01-exit-udp-socks5.patch`](patches/01-exit-udp-socks5.patch) | The `l4` exit's UDP through `--upstream-proxy` with SOCKS5 UDP ASSOCIATE, refused where the proxy refuses it. Without it, UDP leaves the exit directly. | [OpenFluxTeam/OpenFlux#12](https://github.com/OpenFluxTeam/OpenFlux/pull/12) (merged there), [#13](https://github.com/OpenFluxTeam/OpenFlux/pull/13) |
| [`02-exit-udp-socks5-hardening.patch`](patches/02-exit-udp-socks5-hardening.patch) | On top of it, from this repository's review:<ul><li>the handshake runs off gVisor's forwarder;</li><li>a wildcard relay is taken on a named proxy's address (`gate:1080`);</li><li>the flow ends with its control connection;</li><li>fragments are dropped;</li><li>the tests check what they are sent.</li></ul> | here |

## Environment

None of the image's own. OpenFlux reads a few variables itself; the patch adds `OPENFLUX_EXIT_SOCKS5` (a
default for `--upstream-proxy`) and `OPENFLUX_STRICT_PROXY=1` (no direct dial without one). The image sets
neither.

## Tags and versions

Tagged with OpenFlux's version, from its GitHub releases. The `nightly-*` prereleases are skipped. A new
release is moved by hand, and Renovate's pull request never merges on its own:

- `OPENFLUX_COMMIT` moves with the version, in [`docker-bake.hcl`](../../docker-bake.hcl) and as the
  Dockerfile's default: `git ls-remote https://github.com/p1neappleXpress/OpenFlux.git 'refs/tags/v<version>*'`,
  the `^{}` line's commit for an annotated tag, else the tag's own;
- each patch that release carries is dropped;
- the apps that the exits serve must speak the new core, because a key derivation change has broken
  handshakes between versions before.

## Smoke test

[`smoke.sh`](smoke.sh) runs offline, over the `direct` transport on the host's network, as uid 65532 under
a read-only root with every capability dropped. [`smoke-socks.py`](smoke-socks.py) stands in for the
upstream proxy and logs each destination. The test checks:

- the image's user, entrypoint, state directory and licence files;
- that a link made with `--make-link` reads back with `--parse-link`;
- that a request through the client reaches a target over the exit, and that the exit's TCP and UDP both
  leave through the upstream;
- that with an upstream that refuses UDP ASSOCIATE, UDP gets no reply and nothing reaches the target around
  the upstream;
- that the key appears in no log.

No third-party carrier is tested, since those are other companies' services.
