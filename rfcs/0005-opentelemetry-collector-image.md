# RFC 0005 — OpenTelemetry Collector image

- **Status:** 📝 Draft — **gated**, not scheduled. See §gate.
- **Gate:** A collector is already hand-configured in **two or more** projects, or
  will be within the quarter — RFC 0003's admission bar, applied. If observability
  currently means "logs to stdout and hope", this image is speculative
  infrastructure and the gate is unmet.
- **Scope:** An `otelcol-contrib`-based image carrying a default pipeline whose
  values are `${env:}` references, a mandatory memory limiter, env-selected
  exporters, a config-directory overlay, and a health check. Covers the image,
  its env surface, and the overlay's merge semantics. Does **not** build a custom
  OCB distribution, bundle any backend, set sampling policy, or add a templating
  layer.
- **Related:** [images/caddy/rootfs/Caddyfile](../images/caddy/rootfs/Caddyfile)
  (the closest existing shape — native env expansion, directory overlay),
  [docker-bake.hcl](../docker-bake.hcl), RFC 0001 (env contract; this image is a
  partial exception, §5.5), RFC 0002 (attestations, smoke tests), RFC 0003
  (the gate).
- **Origin:** `candidate-images.md` §2.

---

## 1. Summary

Package `otel/opentelemetry-collector-contrib` with a curated default pipeline —
OTLP gRPC and HTTP in, memory limiter and batch and resource detection through
the middle, exporters chosen by one environment variable — where every varying
value is an `${env:}` reference the Collector expands itself. Projects that need
more drop `.yaml` fragments into a config directory. The image is curation, not
mechanism: no templating engine, no generated config, and roughly no code.

## 2. Motivation

Upstream ships `otelcol-contrib` with no default pipeline and a hard requirement
for a config file, so every project that runs one writes the same thirty lines:
OTLP receiver on 4317/4318, a memory limiter, a batch processor, one or two
exporters. Copy-pasted, subtly different each time, and the differences are
invisible until something drops spans under load.

The specific value is `memory_limiter`. It is the most commonly omitted processor
in hand-written configs, and a collector without it is an OOM kill waiting for a
traffic spike — the collector dies at exactly the moment its telemetry is most
wanted. Baking it in *is* the image.

This is the strongest fit of the four candidates for this repo's thesis: upstream
is technically excellent and operationally unopinionated, and the shareable part
is the opinions.

## 3. Current state

Nothing exists in this repo. What matters is what upstream already provides, and
two facts shrink the work considerably:

- **The Collector expands `${env:VAR}` inside its config file natively.** So the
  image needs no templating engine, no `envsubst` pass, and no generated config —
  just a well-designed default config whose values are env references. That is a
  far smaller artifact than Caddy's snippet tree and far more maintainable.
- **The contrib image is distroless.** It carries the binary and little else. Do
  not rebuild it, and note the consequence in §5.5: **there is no shell**, so
  this image cannot run RFC 0001's sourced entrypoint helper.

The nearest existing precedent in this repo is `caddy`: native `{$VAR}`
expansion with `ENV` defaults baked in the Dockerfile
([Dockerfile:96-104](../images/caddy/Dockerfile#L96-L104)), plus glob-imported
overlay directories ([Caddyfile:8-9,31](../images/caddy/rootfs/Caddyfile#L8-L9)).
This image is the same shape in a different config language, which is an argument
for it: the repo would have one pattern applied twice rather than two patterns.

## 4. Goals / Non-goals

**Goals**

- A collector that is useful with zero configuration and correct under load.
- A memory limit that a project cannot accidentally remove.
- Additive per-project configuration that does not require restating the default
  pipeline.

**Non-goals**

- **A custom OCB (OpenTelemetry Collector Builder) distribution.** Tempting —
  contrib is several hundred MB. It is also a build pipeline that breaks on every
  upstream release and a component set that must be curated forever. *Reopens if*
  image size becomes a real constraint in an air-gapped bundle, and then as a
  variant target, not a replacement.
- **Bundling a backend.** No Prometheus, no Jaeger, no Tempo. This is a pipe.
- **Sampling policy defaults.** Tail sampling is application-specific and a wrong
  default silently discards the traces that were wanted. An image that drops
  telemetry by default is worse than no image.
- **A templating layer** — RFC 0001 decision 5.

## 5. Design

### 5.1 Base and default config

`FROM otel/opentelemetry-collector-contrib:<pinned>`, with the version as a bake
variable carrying a Renovate annotation, matching every other target. The default
config ships at `/etc/otelcol/config.yaml` and is used when nothing is mounted:

```yaml
receivers:
  otlp:
    protocols:
      grpc: { endpoint: "0.0.0.0:4317" }
      http: { endpoint: "0.0.0.0:4318" }

processors:
  memory_limiter:
    check_interval: 1s
    limit_mib: ${env:OTEL_MEMORY_LIMIT_MIB}
  batch:
    timeout: ${env:OTEL_BATCH_TIMEOUT}
  resourcedetection:
    detectors: [env, system]

exporters:
  otlp:
    endpoint: ${env:OTEL_EXPORTER_OTLP_ENDPOINT}
    headers: ${env:OTEL_EXPORTER_OTLP_HEADERS}

extensions:
  health_check:
    endpoint: "0.0.0.0:13133"

service:
  extensions: [health_check]
  pipelines:
    traces:  { receivers: [otlp], processors: [memory_limiter, batch, resourcedetection], exporters: [otlp] }
    metrics: { receivers: [otlp], processors: [memory_limiter, batch, resourcedetection], exporters: [otlp] }
    logs:    { receivers: [otlp], processors: [memory_limiter, batch, resourcedetection], exporters: [otlp] }
```

`memory_limiter` first in every chain and `health_check` on by default — the
alternative to the second is a container reported "up" while its pipeline is
broken.

Ports 4317, 4318 and 13133 are all above 1024, so the image is rootless-clean by
construction (RFC 0002 §5.5).

### 5.2 Exporter selection

`OTEL_EXPORTER` takes `otlp`, `debug`, `prometheus`, or a comma-separated list.
Selection is by config-file switching, not config surgery: the image ships one
small file per exporter and the Collector is invoked with the base config plus
the selected exporter files, relying on its own multi-`--config` merge.

The `${env:}` mechanism cannot express "include this exporter conditionally" —
it substitutes values, not structure — so exporter *selection* is the one place
that needs something outside the config language. Choosing between multiple
`--config` arguments is the smallest such thing, and it is a mechanism the
Collector already has.

### 5.3 Config directory overlay

Files dropped into `CONFIG_DIR` (default `/etc/otelcol/config.d`) are passed as
additional `--config` sources after the default, mirroring `caddy`'s
`CONFIG_DIR` in name and intent. A project adding one receiver should not have to
restate the pipeline.

**The merge rule is the dangerous part, and it is the reason P2 exists.** The
Collector merges multiple config sources by deep-merging maps and **replacing
sequences**. A project that overlays `service.pipelines.traces.processors` to
append its own processor replaces the entire list — and silently loses
`memory_limiter`, the exact thing this image exists to guarantee.

Three responses, in order of strength:

1. **Move the limit out of the pipeline.** contrib ships a memory-limiter
   *extension* as well as the processor; an extension applies at the service
   level and is not in any `processors` list, so a pipeline overlay cannot
   remove it. If it is present and functional in the pinned version, this makes
   decision 2 real instead of aspirational. **This is the design's preferred
   answer and it is unverified** — see §10.
2. **Document the sequence-replace rule in the image README**, in those words,
   with the concrete failure spelled out. Mandatory regardless of 1.
3. **Test it**: an overlay that redefines a processor list is asserted to still
   run under a memory limit (§6).

Response 2 alone is not a mitigation, it is a warning label. If 1 is
unavailable, decision 2 must be re-graded honestly rather than restated more
firmly.

### 5.4 Env surface, first cut

`OTEL_EXPORTER`, `OTEL_EXPORTER_OTLP_ENDPOINT`, `OTEL_EXPORTER_OTLP_HEADERS`,
`OTEL_MEMORY_LIMIT_MIB`, `OTEL_BATCH_TIMEOUT`, `OTEL_LOG_LEVEL`,
`OTEL_PROMETHEUS_PORT`, `OTEL_SERVICE_NAME_OVERRIDE`, `CONFIG_DIR`.

Names reuse the upstream OTel SDK spec wherever it already defines one — a
variable meaning something different here than in the SDK spec is a trap, since
the same container often carries both. Under RFC 0001 §5.1 these are the
*upstream* channel for the `OTEL_EXPORTER_OTLP_*` names and the *curated* channel
for the rest. There is no `OTEL_CONF__` passthrough channel: the config is nested
YAML, not key-value, and a flat passthrough over it would be a fiction.

### 5.5 Relationship to RFC 0001

This image satisfies RFC 0001's naming, precedence and secret rules and **cannot
satisfy its startup summary** as specified: the base is distroless, so the sourced
`sh` helper has nothing to run in. The options are to add a shell layer — giving
up the property that makes this base worth using — or to declare this image an
explicit, documented exception whose closest equivalent is the Collector's own
startup logging at `OTEL_LOG_LEVEL=debug`.

Recommendation: **exception, documented in both READMEs**. An unsummarized
collector is a smaller problem than a collector with a shell in it. Decision 5
records this as open, because the answer depends on what the pinned Collector
version actually logs about its resolved config (§10).

`OTEL_EXPORTER_OTLP_HEADERS` carries credentials and is therefore in RFC 0001's
redaction set — relevant wherever this image's configuration is echoed, including
by RFC 0002's smoke tests.

### Alternatives considered

- **An `envsubst` pass over a template.** Rejected: `${env:}` already does this,
  natively, with the Collector's own error messages. Adding a rendering step
  would add a failure mode the Collector cannot diagnose.
- **A generated config assembled by a script at startup.** Rejected for the same
  reason plus §5.5 — there is no shell to generate it in.
- **One config file per project, no default pipeline.** That is upstream, and the
  thirty duplicated lines are the problem statement.
- **Making `memory_limiter` configurable off** for a project that manages memory
  another way. Rejected: it is the single behaviour that justifies the image.

## 6. Tests

Per RFC 0002 §5.5, under rootless Podman:

- Starts with no configuration at all and reports healthy on `:13133`.
- Accepts an OTLP span on 4317 and on 4318 and exports it to a `debug` exporter.
- **Overlay merge:** a `CONFIG_DIR` fragment adding one receiver leaves the
  default pipeline intact; a fragment that redefines `traces.processors` is
  asserted against the memory-limit guarantee. This is the phase-2 test and the
  one whose result may change the design.
- **Exporter matrix:** every selectable value of `OTEL_EXPORTER` starts. A
  misconfigured exporter is a startup failure, not a warning, so an unexercised
  exporter value is an untested failure path.
- `OTEL_MEMORY_LIMIT_MIB` at a small value causes refusal under load rather than
  an OOM kill.

## 7. Docs

`images/otelcol/README.md`, with three things the reader needs and will not
guess:

1. **The sequence-replace merge rule**, with the `memory_limiter` failure
   spelled out concretely (§5.3). Mandatory.
2. The default pipeline, printed in full — an image whose value is curation must
   show the curation.
3. What this image changed from upstream defaults and why.

Plus a row in the root README table, and the RFC 0001 exception (§5.5) recorded
in [images/README.md](../images/README.md) so it is visible as an exception
rather than as an oversight.

## 8. Out of scope

- **A `-alpine`/shell variant** to satisfy the startup summary. Named as the
  escape hatch for §5.5, deliberately not built.
- **Receivers beyond OTLP** (Prometheus scrape, filelog, host metrics). Each is
  a project-specific decision and each is one overlay file.
- **Persistent queueing / `file_storage`.** Turning a stateless pipe into a
  stateful component needs a volume story this repo does not have.
- **Multiple collector roles** (agent vs gateway config sets). Wanted later,
  cheaply expressible as two overlays; not a second image.

## 9. Risks

- **The merge semantics undermine the image's core promise** (§5.3). The most
  important risk in this RFC and the one P2 exists to resolve.
- **Contrib image size**, several hundred MB, in air-gapped bundle contexts —
  the named reopening condition for the OCB non-goal.
- **`${env:}` coverage may not be total.** If some value cannot be expressed as
  an env reference — nested exporter headers being the suspected case — the
  design either shrinks its env surface or reaches for the templating it just
  refused. Measure before P1 (§10).
- **Upstream release cadence.** The Collector moves fast and contrib components
  change stability tiers between releases; a pinned minor plus Renovate is the
  same mitigation every other image here uses.
- **Read as an observability platform.** It is a pipe with good defaults. The
  README leading with the non-goals is the mitigation.

## 10. Unresolved questions

Each of these is a measurement against the *pinned version*, not a judgement:

1. **Does contrib's memory-limiter extension exist and work as §5.3 assumes?**
   This determines whether decision 2 is enforceable or merely documented, and it
   is the highest-value question in this RFC.
2. **Exact merge semantics** for the pinned version — verify, do not trust §5.3's
   paragraph.
3. **Does `${env:}` expansion cover every needed value**, including inside nested
   exporter headers?
4. **What does the Collector log about its resolved config at startup?** Settles
   §5.5 and decision 5.

## 11. Decisions

| # | Grade | Decision |
| --- | --- | --- |
| 1 | `LOCKED` | Native `${env:}` expansion, no templating layer. A case `${env:}` cannot express gets a config-dir overlay, never a template. Consistent with RFC 0001 decision 5. |
| 2 | `LOCKED` | A memory limit is always in effect and is not disableable by environment. **Enforceability is unproven** — §5.3 response 1 makes it real, response 2 only warns. If §10's first question comes back negative, this row is superseded by an honest one, not restated. |
| 3 | `LOCKED` | `contrib` distribution, not a custom OCB build. Consequence: several hundred MB per image, permanently, until the air-gapped reopening condition fires. |
| 4 | `LOCKED` | Credential-bearing headers are never printed by any summary or smoke test (RFC 0001 redaction set). |
| 5 | `OPEN` | Whether this image is an explicit exception to RFC 0001's startup summary or gains a shell layer to satisfy it. Recommendation: exception. Settled by §10 question 4; log the answer in both READMEs. |
| 6 | `OPEN` | Exporter selection by multiple `--config` files (§5.2) versus a single file with all exporters defined and only the selected ones referenced in the pipeline. The second is simpler and validates unused exporter blocks at startup, which may be a feature or a foot-gun. |
| 7 | `ASSUMED` | No `OTEL_CONF__` passthrough channel; nested YAML does not flatten honestly. Depart if a real case appears that overlays cannot cover. |
| 8 | `ASSUMED` | Upstream SDK-spec variable names are reused verbatim where they exist. Depart only where upstream's meaning genuinely differs here — and then rename ours, never theirs. |

## 12. Phasing

- **P1 — base, default pipeline, `${env:}` surface, health check.** No overlay.
  Blocked on §10 question 3.
- **P2 — `CONFIG_DIR` overlay and its merge tests.** The phase with the real
  failure modes; §10 questions 1 and 2 must be answered inside it, and decision 2
  is re-graded here if they come back badly.
- **P3 — exporter matrix**, each selectable exporter verified to start.

Gated behind RFC 0003's admission bar throughout. If the gate is unmet, this RFC
stays Draft and is not scheduled — that is the intended resting state, not a
stalled one.
