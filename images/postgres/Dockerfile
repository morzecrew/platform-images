ARG POSTGRES_IMAGE_TAG=18.1
FROM postgres:${POSTGRES_IMAGE_TAG}

ARG PG_MAJOR=18

# hadolint ignore=DL3008,DL3015,DL4006,DL3047
RUN set -eux; \
    apt-get update; \
    apt-get install -y --no-install-recommends ca-certificates wget gnupg lsb-release "postgresql-${PG_MAJOR}-cron"; \
    echo "OS:"; cat /etc/os-release; \
    echo "CODENAME:"; lsb_release --codename --short; \
    \
    CODENAME="$(lsb_release --codename --short)"; \
    wget -O /tmp/groonga-apt-source.deb \
    "https://packages.groonga.org/debian/groonga-apt-source-latest-${CODENAME}.deb"; \
    apt-get install -y -V /tmp/groonga-apt-source.deb; \
    rm -f /tmp/groonga-apt-source.deb; \
    \
    apt-get update; \
    apt-cache search pgroonga | head -n 50; \
    \
    apt-get install -y -V "postgresql-${PG_MAJOR}-pgdg-pgroonga"; \
    \
    apt-get clean; \
    rm -rf /var/lib/apt/lists/*

COPY rootfs/postgresql.conf /etc/postgresql.conf

RUN mkdir -p /etc/postgresql/conf.d \
    && chown -R postgres:postgres /etc/postgresql

COPY rootfs/allowlist.conf /etc/postgresql/allowlist.conf
RUN chown postgres:postgres /etc/postgresql/allowlist.conf \
    && chmod 0644 /etc/postgresql/allowlist.conf

COPY rootfs/entrypoint.sh /usr/local/bin/entrypoint-merge.sh
RUN chmod +x /usr/local/bin/entrypoint-merge.sh

ENTRYPOINT ["/usr/local/bin/entrypoint-merge.sh"]
CMD ["postgres", "-c", "config_file=/etc/postgresql.conf"]
