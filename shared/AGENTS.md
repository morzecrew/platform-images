<!-- torve:managed shared — rendered from the corpus; do not edit by hand -->

## Decisions governing `shared/`

### S-0001/D-17 — `ASSUMED` (Standing decisions)

`shared/` holds only files two or more images use. They reach an image through the bake's named context `contexts = { shared = "./shared" }`, never by copy. The helper is POSIX sh and runs under busybox, dash and bash.

- Paths: `shared/**` `docker-bake.hcl`
- Consequence: a fix to the shared helper reaches every image that uses it at its next build

<!-- /torve:managed -->
