FROM postgres:18.1

# hadolint ignore=DL3008,DL3015,DL4006,DL3047
RUN set -eux; \
    apt-get update; \
    apt-get install -y --no-install-recommends ca-certificates wget gnupg lsb-release postgresql-18-cron; \
    echo "OS:"; cat /etc/os-release; \
    echo "CODENAME:"; lsb_release --codename --short; \
    \
    # Groonga APT source
    CODENAME="$(lsb_release --codename --short)"; \
    wget -O /tmp/groonga-apt-source.deb \
    "https://packages.groonga.org/debian/groonga-apt-source-latest-${CODENAME}.deb"; \
    apt-get install -y -V /tmp/groonga-apt-source.deb; \
    rm -f /tmp/groonga-apt-source.deb; \
    \
    apt-get update; \
    apt-cache search pgroonga | head -n 50; \
    \
    # TRY install (will fail build if not found)
    apt-get install -y -V postgresql-18-pgdg-pgroonga; \
    \
    apt-get clean; \
    rm -rf /var/lib/apt/lists/*

COPY 18-cron-pgroonga/postgres.conf /etc/postgresql.conf

RUN mkdir -p /etc/postgresql/conf.d \
    && chown -R postgres:postgres /etc/postgresql

COPY allowlists/base.conf /tmp/base.conf
COPY allowlists/18.conf /tmp/version.conf

RUN cat /tmp/base.conf /tmp/version.conf > /etc/postgresql/allowlist.conf \
    && rm /tmp/base.conf /tmp/version.conf \
    && chown postgres:postgres /etc/postgresql/allowlist.conf \
    && chmod 0644 /etc/postgresql/allowlist.conf

COPY 18-cron-pgroonga/entrypoint.sh /usr/local/bin/entrypoint-merge.sh
RUN chmod +x /usr/local/bin/entrypoint-merge.sh

ENTRYPOINT ["/usr/local/bin/entrypoint-merge.sh"]
CMD ["postgres", "-c", "config_file=/etc/postgresql.conf"]