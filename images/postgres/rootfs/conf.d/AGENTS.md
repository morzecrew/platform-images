<!-- torve:managed images/postgres/rootfs/conf.d — rendered from the corpus; do not edit by hand -->

## Decisions governing `images/postgres/rootfs/conf.d/`

### S-0001/D-15 — `ASSUMED` (Standing decisions)

Precedence is baked, then mounted, then environment. A startup summary goes to stderr before `exec`: keys printed, values of secret-like keys redacted (`!secret`, and PASSWORD, TOKEN, SECRET, KEY as a segment, HEADERS). `source=` is required only where the layers can be enumerated. postgres prints a fourth layer, `ALTER SYSTEM` (`source=sql`), and caddy prints `image default < environment`.

- Paths: `shared/rootfs/lib/envconf.sh` `images/*/rootfs/entrypoint.sh` `images/postgres/rootfs/conf.d/*`
- Consequence: an operator reads where each setting came from in the container's log, and no secret appears there

<!-- /torve:managed -->
