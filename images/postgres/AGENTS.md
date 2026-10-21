<!-- torve:managed images/postgres — rendered from the corpus; do not edit by hand -->

## Decisions governing `images/postgres/`

### S-0001/D-19 — `ASSUMED` (Standing decisions)

`PG_EXTENSIONS` is checked against the five-column manifest, and an unknown name fails the build. The preload line and the `io.morze.postgres.extensions` label are generated from that one argument, the label in the Dockerfile. A variant is a tag suffix on one package, its set written literally in its target, and there are at most three variants with the default; the unsuffixed tag is cron and pgroonga.

- Paths: `images/postgres/Dockerfile` `images/postgres/rootfs/*extensions*` `images/postgres/test-extensions.sh` `docker-bake.hcl`
- Consequence: an image's extensions are what its label says, and adding one is a manifest line and a target

<!-- /torve:managed -->
