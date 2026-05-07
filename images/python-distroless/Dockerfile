# syntax=docker/dockerfile:1.7

ARG PYTHON_VERSION=3.14.3
ARG DEBIAN_VERSION=13

FROM debian:bookworm-slim AS deps

RUN apt-get update && apt-get install -y --no-install-recommends \
    ca-certificates \
    libmagic1 \
    file \
    && rm -rf /var/lib/apt/lists/*

FROM al3xos/python-distroless:${PYTHON_VERSION}-debian${DEBIAN_VERSION}

ENV PYTHONUNBUFFERED=1 \
    PYTHONFAULTHANDLER=1 \
    LANG=C.UTF-8 \
    LC_ALL=C.UTF-8 \
    TZ=UTC \
    TMPDIR=/srv/runtime-tmp \
    XDG_CACHE_HOME=/srv/runtime-tmp/.cache \
    LD_LIBRARY_PATH=/usr/lib

COPY --from=deps /etc/ssl/certs /etc/ssl/certs
COPY --from=deps /usr/lib/x86_64-linux-gnu/libmagic.so.1 /usr/lib/
COPY --from=deps /usr/lib/x86_64-linux-gnu/libbz2.so.1.0 /usr/lib/
COPY --from=deps /usr/lib/x86_64-linux-gnu/liblzma.so.5 /usr/lib/
COPY --from=deps /usr/lib/x86_64-linux-gnu/libz.so.1 /usr/lib/
COPY --from=deps /usr/share/file/magic.mgc /usr/share/file/magic.mgc
COPY --from=deps /usr/share/misc/magic.mgc /usr/share/misc/magic.mgc

USER 65532:65532