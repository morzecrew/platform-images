# syntax=docker/dockerfile:1.26

# ....................... #

ARG POSTGRES_IMAGE_TAG=18.1

FROM postgres:${POSTGRES_IMAGE_TAG}

ARG POSTGRES_IMAGE_TAG

# ....................... #
# Install pg_cron and pgroonga

RUN set -eux; \
    PG_MAJOR="${POSTGRES_IMAGE_TAG%%.*}"; \
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

# ....................... #
# Copy configuration files

COPY rootfs/postgresql.conf /etc/postgresql.conf

RUN mkdir -p /etc/postgresql/conf.d \
    && chown -R postgres:postgres /etc/postgresql

COPY rootfs/allowlist.conf /etc/postgresql/allowlist.conf
RUN chown postgres:postgres /etc/postgresql/allowlist.conf \
    && chmod 0644 /etc/postgresql/allowlist.conf

COPY rootfs/entrypoint.sh /usr/local/bin/entrypoint-merge.sh
RUN chmod +x /usr/local/bin/entrypoint-merge.sh

# ....................... #
# Entrypoint

ENTRYPOINT ["/usr/local/bin/entrypoint-merge.sh"]
CMD ["postgres", "-c", "config_file=/etc/postgresql.conf"]
