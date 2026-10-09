# syntax=docker/dockerfile:1.28

ARG PYTHON_VERSION=3.14.6
ARG DEBIAN_VERSION=13
ARG APP_UID=65532
ARG APP_GID=65532
ARG APP_RUNTIME_DIR=/srv/runtime
ARG APP_TMP_DIR=/srv/runtime/tmp

FROM debian:bookworm-slim AS deps

ARG APP_UID
ARG APP_GID
ARG APP_RUNTIME_DIR
ARG APP_TMP_DIR

RUN apt-get update && apt-get install -y --no-install-recommends \
    ca-certificates \
    libmagic1 \
    file \
    && rm -rf /var/lib/apt/lists/*

RUN install -d -m 0750 -o ${APP_UID} -g ${APP_GID} ${APP_RUNTIME_DIR} \
    && install -d -m 0750 -o ${APP_UID} -g ${APP_GID} ${APP_TMP_DIR}

FROM al3xos/python-distroless:${PYTHON_VERSION}-debian${DEBIAN_VERSION} AS upstream

FROM upstream

ARG APP_UID
ARG APP_GID
ARG APP_RUNTIME_DIR
ARG APP_TMP_DIR

ENV PYTHONUNBUFFERED=1 \
    PYTHONFAULTHANDLER=1 \
    LANG=C.UTF-8 \
    LC_ALL=C.UTF-8 \
    TZ=UTC \
    APP_UID=${APP_UID} \
    APP_GID=${APP_GID} \
    APP_RUNTIME_DIR=${APP_RUNTIME_DIR} \
    APP_TMP_DIR=${APP_TMP_DIR} \
    TMPDIR=${APP_TMP_DIR} \
    XDG_CACHE_HOME=${APP_TMP_DIR}/.cache \
    LD_LIBRARY_PATH=/usr/lib

COPY --from=deps /etc/ssl/certs /etc/ssl/certs
# `*-linux-gnu` is the Debian multiarch directory, which differs per platform
# (x86_64-, aarch64-). The deps stage has exactly one, so each glob matches once.
COPY --from=deps /usr/lib/*-linux-gnu/libmagic.so.1 /usr/lib/
COPY --from=deps /usr/lib/*-linux-gnu/libbz2.so.1.0 /usr/lib/
COPY --from=deps /usr/lib/*-linux-gnu/liblzma.so.5 /usr/lib/
COPY --from=deps /usr/lib/*-linux-gnu/libz.so.1 /usr/lib/
COPY --from=deps /usr/share/file/magic.mgc /usr/share/file/magic.mgc
COPY --from=deps /usr/share/misc/magic.mgc /usr/share/misc/magic.mgc

# Upstream copies libffi into /usr/lib/x86_64-linux-gnu/ on every platform, so
# on arm64 the aarch64 build of it sits where the loader never looks and
# `import ctypes` fails. Its own file, onto LD_LIBRARY_PATH; on amd64 this is a
# duplicate of a library already found. The glob keeps working once upstream
# moves it to the right directory.
COPY --from=upstream /usr/lib/*-linux-gnu/libffi.so.8 /usr/lib/

COPY --from=deps ${APP_RUNTIME_DIR} ${APP_RUNTIME_DIR}

USER ${APP_UID}:${APP_GID}