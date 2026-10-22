<!-- torve:managed rfcs — rendered from the corpus; do not edit by hand -->

## Decisions governing `rfcs/`

### S-0001/D-26 — `ASSUMED` (Standing decisions)

An executor never edits a LOCKED row. A departure goes into the append-only execution log with a class and a proposed row, ratified by merging its pull request. An RFC's status block moves with the work, and `rfcs/INDEX.md` stays in step.

- Paths: `rfcs/*.md`
- Consequence: a design and what was built from it never silently disagree

<!-- /torve:managed -->
