# syntax=docker/dockerfile:1.28

# Stable releases only. Upstream's one prerelease, Prerelease-Alpha, is marked
# as one on GitHub, and its tag is not a version.
# renovate: datasource=github-releases depName=MetaCubeX/mihomo extractVersion=^v(?<version>.+)$
ARG MIHOMO_VERSION=1.19.34
# The image index digest of docker.io/metacubex/mihomo:v${MIHOMO_VERSION}.
# Each upstream build fetches its geodata from `latest`, so a rebuild of a tag
# is not the same image; the digest is what makes a rebuild here ship the same
# geodata. Moved with the version by .github/workflows/follow-digest.yaml --
# see docker-bake.hcl.
ARG MIHOMO_IMAGE_DIGEST=sha256:4c2495d705f152897a58eac410350f243835fd01ce2fe44949a571faa824d532
# renovate: datasource=docker depName=golang extractVersion=^(?<version>\d+\.\d+\.\d+)-alpine$
ARG GO_VERSION=1.27.4

FROM docker.io/metacubex/mihomo:v${MIHOMO_VERSION}@${MIHOMO_IMAGE_DIGEST} AS upstream

# The entrypoint is Go, standard library only, because the runtime has no
# shell. Its generic half is shared/go, laid out where go.mod's replace
# expects it, and is xray's too. Both halves' tests run here, so an image
# whose helper fails them is not built.
FROM golang:${GO_VERSION}-alpine AS entrypoint
ARG TARGETARCH

WORKDIR /src/images/mihomo/entrypoint
COPY --from=shared go/ /src/shared/go/
COPY entrypoint/ ./
RUN CGO_ENABLED=0 go test ./... github.com/morzecrew/platform-images/shared/go/... \
    && CGO_ENABLED=0 go build -trimpath -ldflags="-s -w -buildid=" -o /out/mihomo-entrypoint . \
    && mkdir -p /out/var/lib/mihomo

# Upstream's binary runs on a base with no libc, so it has to be a static Go
# build, and on amd64 the baseline one (GOAMD64=v1) that runs on any x86-64.
# Both are read from the binary's own build information. If upstream stops
# shipping either, the way out is building the tag here with CGO_ENABLED=0.
RUN --mount=type=bind,from=upstream,source=/mihomo,target=/upstream/mihomo \
    go version -m /upstream/mihomo >/tmp/buildinfo \
    && { grep -Eq '^[[:space:]]+build[[:space:]]+CGO_ENABLED=0$' /tmp/buildinfo \
         || { echo "upstream's mihomo is not a CGO_ENABLED=0 build" >&2; exit 1; }; } \
    && { [ "${TARGETARCH}" != amd64 ] \
         || grep -Eq '^[[:space:]]+build[[:space:]]+GOAMD64=v1$' /tmp/buildinfo \
         || { echo "upstream's amd64 mihomo is not the GOAMD64=v1 baseline build" >&2; exit 1; }; }

# Not upstream's image: it runs as root on Alpine with iptables, and declares
# a VOLUME a FROM cannot remove. The base floats, so the weekly rebuild brings
# its CA bundle and tzdata current; mihomo and its geodata do not.
FROM gcr.io/distroless/static-debian13:nonroot

COPY --from=upstream --chown=0:0 /mihomo /usr/local/bin/mihomo
# No --chmod: with several sources it applies to the directory it creates
# too, which 0644 would close to uid 65532. Upstream's files are 0644.
COPY --from=upstream --chown=0:0 \
    /root/.config/mihomo/geoip.metadb /root/.config/mihomo/geosite.dat /root/.config/mihomo/geoip.dat \
    /usr/local/share/mihomo/
COPY --from=entrypoint /out/mihomo-entrypoint /usr/local/bin/mihomo-entrypoint
# A named volume mounted here starts as a copy of this directory, so uid 65532
# owns it. With a read-only root and no volume, nothing can be written.
COPY --from=entrypoint --chown=65532:65532 --chmod=0700 /out/var/lib/mihomo /var/lib/mihomo

# The entrypoint applies the same defaults to a variable set empty.
# MIHOMO_HEALTHCHECK_PROXY is unset on purpose: the probe needs an inbound only
# the operator's config can declare. SAFE_PATHS is upstream's: rule and
# provider files may then be secrets, and an operator who sets it replaces
# this.
ENV MIHOMO_SOURCE_DIR=/etc/mihomo \
    MIHOMO_HOME=/var/lib/mihomo \
    MIHOMO_HEALTHCHECK_URL=https://www.gstatic.com/generate_204 \
    MIHOMO_HEALTHCHECK_TIMEOUT=10s \
    SAFE_PATHS=/run/secrets

USER 65532:65532

ENTRYPOINT ["/usr/local/bin/mihomo-entrypoint"]
CMD ["run"]
