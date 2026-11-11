# syntax=docker/dockerfile:1.28

# Stable releases only: upstream publishes its prereleases under the same
# version form, as image tags too, so the version comes from GitHub releases,
# where they are marked.
# renovate: datasource=github-releases depName=XTLS/Xray-core extractVersion=^v(?<version>.+)$
ARG XRAY_VERSION=26.10.31
# The image index digest of ghcr.io/xtls/xray-core:${XRAY_VERSION}. Upstream
# rebuilds a tag when a prerelease is promoted and on a manual dispatch, and
# each build fetches its geodata from `latest`; the digest is what makes a
# rebuild here ship the same geoip.dat and geosite.dat. Moved by hand with the
# version -- see docker-bake.hcl.
ARG XRAY_IMAGE_DIGEST=sha256:ceabeac03a89d991d2a247361825c1d1d2e9c91cd5dc010f298c7dc0c2f325c9
# renovate: datasource=docker depName=golang extractVersion=^(?<version>\d+\.\d+\.\d+)-alpine$
ARG GO_VERSION=1.27.4

FROM ghcr.io/xtls/xray-core:${XRAY_VERSION}@${XRAY_IMAGE_DIGEST} AS upstream

# The entrypoint is Go, standard library only, because the runtime has no
# shell: resolving the config's file references in sh would need jq as well.
# Its generic half is shared/go, laid out where go.mod's replace expects it.
# Both halves' tests run here, so an image whose helper fails them is not
# built.
FROM golang:${GO_VERSION}-alpine AS entrypoint

WORKDIR /src/images/xray/entrypoint
COPY --from=shared go/ /src/shared/go/
COPY entrypoint/ ./
RUN CGO_ENABLED=0 go test ./... github.com/morzecrew/platform-images/shared/go/... \
    && CGO_ENABLED=0 go build -trimpath -ldflags="-s -w -buildid=" -o /out/xray-entrypoint . \
    && mkdir -p /out/run/xray

# Upstream's own base, but not upstream's image: its two VOLUMEs and the
# placeholder configs under /usr/local/etc/xray, one of which sends the log to
# a file, cannot be removed from a FROM. The base floats, so the weekly rebuild
# brings its CA bundle and tzdata current; Xray and its geodata do not.
FROM gcr.io/distroless/static-debian13:nonroot

COPY --from=upstream --chown=0:0 /usr/local/bin/xray /usr/local/bin/xray
COPY --from=upstream --chown=0:0 /usr/local/share/xray/ /usr/local/share/xray/
COPY --from=entrypoint /out/xray-entrypoint /usr/local/bin/xray-entrypoint
# Writable without a tmpfs. With a read-only root, mount one here.
COPY --from=entrypoint --chown=65532:65532 --chmod=0700 /out/run/xray /run/xray

# The entrypoint applies the same defaults to a variable set empty.
# XRAY_HEALTHCHECK_PROXY is unset on purpose: the probe needs an inbound only
# the operator's config can declare.
ENV XRAY_SOURCE_DIR=/etc/xray \
    XRAY_RUNTIME_DIR=/run/xray \
    XRAY_HEALTHCHECK_URL=https://www.gstatic.com/generate_204 \
    XRAY_HEALTHCHECK_TIMEOUT=10s

USER 65532:65532

ENTRYPOINT ["/usr/local/bin/xray-entrypoint"]
CMD ["run"]
