# caddy-acmedns

Upstream's `caddy:<version>-alpine` with one module built in,
[caddy-dns/acmedns](https://github.com/caddy-dns/acmedns). A site can then
take its certificate, a wildcard included, through a DNS-01 check delegated
to an [acme-dns](https://github.com/joohoi/acme-dns) server by one CNAME,
whatever hosts its DNS.

| | |
| --- | --- |
| Image | `ghcr.io/morzecrew/caddy-acmedns:<caddy version>` |
| Base | upstream's `caddy:<version>-alpine`, unchanged but for the binary |
| Modules | upstream's standard set and `dns.providers.acmedns`, nothing else |
| Runs as | upstream's default, root; it serves as any user under a read-only root, every capability dropped, on ports that user may bind. Ports 80 and 443 then need `net.ipv4.ip_unprivileged_port_start` lowered, as dotdash sets it to 0, or `NET_BIND_SERVICE` granted |
| Capability | `cap_net_bind_service=p` on the binary, as upstream's: no effective bit, so it starts under `cap_drop: ALL` |
| Config | `/etc/caddy/Caddyfile`, with upstream's command |

It isn't a variant of [`caddy`](../caddy), which adds Coraza, the OWASP CRS
and a platform Caddyfile with its own entrypoint. A bundle that runs
upstream's image runs this one in its place, with the same binary path,
Caddyfile, command and shell.

## Usage

1. Register with the acme-dns server:

    ```sh
    curl -s -X POST https://auth.acme-dns.io/register
    ```

    It answers with a `username`, a `password`, a `subdomain` and a
    `fulldomain`.

2. At the DNS host, point the check's name at it. For a wildcard
   `*.r.example.net`, that is the name without the `*.`:

    ```text
    _acme-challenge.r.example.net.  CNAME  <fulldomain>.
    ```

3. Mount the credentials as a file, and name it in the Caddyfile:

    ```json
    {"username": "…", "password": "…", "subdomain": "…", "server_url": "https://auth.acme-dns.io"}
    ```

    ```caddyfile
    {
    	acme_dns acmedns /run/secrets/acmedns.json
    }

    *.r.example.net {
    	respond "ok"
    }
    ```

The credentials can only answer that one name's check. A self-hosted
acme-dns server is better than the public one. Its address is public through
the NS record that delegates its zone, so don't run it on a machine whose
address you mean to keep private.

## Environment

None. Like upstream's image, it reads its Caddyfile, and the Caddyfile reads
the environment through Caddy's own `{$VAR}` expansion. It has no entrypoint
and no curated or passthrough names.

## Tags and versions

Tagged with Caddy's version. `CADDY_VERSION` in
[`docker-bake.hcl`](../../docker-bake.hcl) is shared with
[`caddy`](../caddy), so the two move together. The module's version,
`ACMEDNS_VERSION`, is a build argument there with its own Renovate
annotation. A module release without a Caddy release rebuilds the same tag.

## Smoke test

[`smoke.sh`](smoke.sh) runs offline. It checks that:

- Caddy is the version the label names;
- `acmedns` is the one module beyond the standard set, and nothing of
  `caddy`'s is here;
- a wildcard site that hands its check to `acmedns`, with credentials from a
  mounted file, adapts and validates;
- the binary's file capability is upstream's `cap_net_bind_service=p`;
- the image serves upstream's way as uid 65532 under a read-only root, with
  every capability dropped and no new privileges.

No certificate is issued, since that needs a CA and DNS.
