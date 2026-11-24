# syntax=docker/dockerfile:1.29

# OpenFlux's core (p1neappleXpress/OpenFlux, GPL-3.0): a tunnel over services a
# network still lets through, such as rooms and documents on them. Built here
# from the source of a release tag, because upstream publishes unsigned
# binaries and no image. Its client and its l4 exit need no root and no
# capability. Alpine, not distroless: the bundle that runs it drives one node
# per device from a shell script of its own.

# Releases only: the nightly-* prereleases are not versions, and the pattern
# skips them. A new release is moved by hand, never automerged
# (.github/renovate.json): OPENFLUX_COMMIT moves with it, each patch is dropped
# once a release carries it, and the apps the exits serve must speak it.
# renovate: datasource=github-releases depName=p1neappleXpress/OpenFlux extractVersion=^v(?<version>\d+\.\d+\.\d+)$
ARG OPENFLUX_VERSION=0.17.1
# The commit the tag names, here and in docker-bake.hcl. Upstream has
# force-pushed before, so the build refuses a tag that has moved. By hand:
# `git ls-remote <repo> 'refs/tags/v<version>*'`, the ^{} line's commit for
# an annotated tag, else the tag's own line.
ARG OPENFLUX_COMMIT=f492a1a33b7581ad8f88118f97e0b866adda3cdc
# renovate: datasource=docker depName=golang extractVersion=^(?<version>\d+\.\d+\.\d+)-alpine$
ARG GO_VERSION=1.27.4
# renovate: datasource=docker depName=alpine versioning=docker
ARG ALPINE_VERSION=3.22

FROM golang:${GO_VERSION}-alpine AS build
ARG OPENFLUX_VERSION
ARG OPENFLUX_COMMIT

ADD --checksum=${OPENFLUX_COMMIT} https://github.com/p1neappleXpress/OpenFlux.git#v${OPENFLUX_VERSION} /src
WORKDIR /src
# Changes no release carries yet, each named in README.md; this step goes with
# the last of them. The tests of the package they touch run here, so an image
# whose patch breaks them is not built.
RUN --mount=type=bind,source=patches,target=/patches \
    apk add --no-cache patch >/dev/null \
    && for p in /patches/*.patch; do patch -p1 --no-backup-if-mismatch <"${p}" || exit 1; done
RUN CGO_ENABLED=0 go test ./tunnel/ \
    && CGO_ENABLED=0 go build -trimpath -ldflags="-s -w -buildid=" -o /out/openflux . \
    && mkdir -p /out/var/lib/openflux /out/doc \
    && cp LICENSE COPYRIGHT NOTICE /out/doc/

FROM alpine:${ALPINE_VERSION}

COPY --from=build /out/openflux /usr/local/bin/openflux
# The licence and notices travel with the binary (GPL-3.0-or-later). Its
# source is the tag's, plus patches/ here.
COPY --from=build /out/doc/ /usr/local/share/doc/openflux/
# Rooms, cookie jars and keys, for a node's CookieStore and the like. A named
# volume mounted here starts as a copy, so uid 65532 owns it.
COPY --from=build --chown=65532:65532 --chmod=0700 /out/var/lib/openflux /var/lib/openflux

# uid 65532 has no passwd entry, so HOME would be /.
ENV HOME=/var/lib/openflux
WORKDIR /var/lib/openflux
USER 65532:65532

ENTRYPOINT ["/usr/local/bin/openflux"]
