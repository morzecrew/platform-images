<!-- torve:managed images/valkey — rendered from the corpus; do not edit by hand -->

## Decisions governing `images/valkey/`

### S-0001/D-20 — `ASSUMED` (Standing decisions)

valkey's `maxmemory` is 75% of the cgroup's `memory.max`, with a warned 256 MiB fallback. One switch sets persistence, `off`, `rdb` or `aof`. Persistence with an `allkeys-*` or implicit eviction policy is refused, judged on the assembled configuration. `FLUSHALL`, `FLUSHDB` and `KEYS` are renamed. The base is Alpine.

- Paths: `images/valkey/**`
- Consequence: a valkey container neither outgrows its memory limit nor evicts data it was told to persist

<!-- /torve:managed -->
