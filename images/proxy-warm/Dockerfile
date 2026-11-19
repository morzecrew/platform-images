# syntax=docker/dockerfile:1.29

# This repository's own program, so the version is ours, moved by hand with
# each change to it (images/proxy-warm/README.md).
ARG PROXY_WARM_VERSION=0.1.1
# renovate: datasource=docker depName=golang extractVersion=^(?<version>\d+\.\d+\.\d+)-alpine$
ARG GO_VERSION=1.27.4

# Go, standard library only, beside the shared module's ReadSecret, laid out
# where go.mod's replace expects it. The tests run here, against a fake proxy
# on loopback, so an image whose program fails them is not built.
FROM golang:${GO_VERSION}-alpine AS build
ARG PROXY_WARM_VERSION

WORKDIR /src/images/proxy-warm/src
COPY --from=shared go/ /src/shared/go/
COPY src/ ./
RUN CGO_ENABLED=0 go test ./... \
    && CGO_ENABLED=0 go build -trimpath \
      -ldflags="-s -w -buildid= -X main.version=${PROXY_WARM_VERSION}" -o /out/proxy-warm .

# The base floats, so the weekly rebuild brings its CA bundle current, which
# an https:// or socks5+tls:// upstream is checked against.
FROM gcr.io/distroless/static-debian13:nonroot

COPY --from=build /out/proxy-warm /usr/local/bin/proxy-warm

# The program applies the same defaults to a variable set empty.
# PROXY_WARM_UPSTREAMS has none: the upstreams file is the operator's.
ENV PROXY_WARM_PORT=1080 \
    PROXY_WARM_MAX_IDLE=90s

USER 65532:65532

ENTRYPOINT ["/usr/local/bin/proxy-warm"]
CMD ["run"]
