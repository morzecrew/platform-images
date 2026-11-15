# caddy-l4

Upstream's `caddy:<version>-alpine` with one module built in,
[mholt/caddy-l4](https://github.com/mholt/caddy-l4). A server can then route
a connection by what it starts with, before any HTTP. The use it's here for:
one machine's Caddy keeps ports 80 and 443 for its own sites, and passes the
connections for a few chosen TLS server names through, untouched, to a
service that must terminate TLS itself, such as a REALITY server.

| | |
| --- | --- |
| Image | `ghcr.io/morzecrew/caddy-l4:<caddy version>` |
| Base | upstream's `caddy:<version>-alpine`, unchanged but for the binary |
| Modules | upstream's standard set and caddy-l4's (`layer4`, `layer4.*`, `caddy.listeners.layer4`, `caddy.packetconns.layer4`, `tls.handshake_match.alpn`), nothing else |
| Runs as | upstream's default, root. On the host network, as an edge on 80 and 443 runs, that is what binds them. It also serves as any user under a read-only root with every capability dropped, on ports that user may bind |
| Capability | `cap_net_bind_service=p` on the binary, as upstream's: no effective bit, so it starts under `cap_drop: ALL` |
| Config | `/etc/caddy/Caddyfile`, with upstream's command |

It isn't a variant of [`caddy`](../caddy), which adds Coraza, the OWASP CRS
and a platform Caddyfile, nor of [`caddy-acmedns`](../caddy-acmedns): an edge
has no use for the DNS module, and a backend's own Caddy none for layer4.

## Usage

### Passing chosen names through

caddy-l4 as a listener wrapper on the `:443` server. It reads each
connection's ClientHello. A connection whose server name matches goes to the
backend as raw TCP, byte for byte. Any other goes on to `tls` and the HTTP
app, so every site keeps its certificates and routes as before. HTTP/3 on UDP
443 is not involved.

```caddyfile
{
	servers :443 {
		listener_wrappers {
			layer4 {
				@passthrough tls sni node.example.net
				route @passthrough {
					proxy 127.0.0.1:9443
				}
			}
			tls
		}
	}
}

site.example.net {
	respond "the edge's own site"
}
```

`tls sni` takes several names and wildcards (`*.example.net`); give each
backend its own `@matcher` and `route` for its own port. The backend sees
connections from the edge's address, not the client's. A backend that reads
the PROXY protocol can have it with `proxy { proxy_protocol v2 upstream
127.0.0.1:9443 }`.

Don't pass through a name the edge serves itself, and don't point a
backend's fallback for unauthenticated connections at one of the edge's own
names: the edge would route that connection straight back to the backend.

### Running it

As a container on the host network, in the place of a package-installed
Caddy:

```sh
docker run -d --name edge --restart unless-stopped --network host \
  -v /etc/caddy/Caddyfile:/etc/caddy/Caddyfile:ro \
  -v caddy_data:/data -v caddy_config:/config \
  ghcr.io/morzecrew/caddy-l4:<version>@sha256:<digest>
```

Or the binary alone, for a machine that runs Caddy as a systemd service. It
is static:

```sh
id=$(docker create ghcr.io/morzecrew/caddy-l4:<version>@sha256:<digest>)
docker cp "$id":/usr/bin/caddy /usr/local/bin/caddy
docker rm "$id"
setcap cap_net_bind_service=+ep /usr/local/bin/caddy
/usr/local/bin/caddy list-modules | grep -x caddy.listeners.layer4
```

Then point the unit's `ExecStart` at `/usr/local/bin/caddy`. A package
upgrade replaces `/usr/bin/caddy`, never this one: copy the next build when
this image's tag moves, or hold the package (`apt-mark hold caddy`).
