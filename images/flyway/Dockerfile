# syntax=docker/dockerfile:1.28

# ....................... #

ARG FLYWAY_VERSION=12.5
FROM flyway/flyway:${FLYWAY_VERSION}-alpine

ARG POSTGRES_JDBC_VERSION=42.7.11
ARG CLICKHOUSE_JDBC_VERSION=0.9.8

RUN wget -qO "/flyway/drivers/postgresql-${POSTGRES_JDBC_VERSION}.jar" \
    "https://jdbc.postgresql.org/download/postgresql-${POSTGRES_JDBC_VERSION}.jar" \
    && wget -qO "/flyway/drivers/clickhouse-jdbc-${CLICKHOUSE_JDBC_VERSION}-all.jar" \
    "https://repo1.maven.org/maven2/com/clickhouse/clickhouse-jdbc/${CLICKHOUSE_JDBC_VERSION}/clickhouse-jdbc-${CLICKHOUSE_JDBC_VERSION}-all.jar"

# From the `shared` named context declared in docker-bake.hcl (RFC 0001 decision 6).
COPY --from=shared --chmod=0644 rootfs/lib/envconf.sh /usr/local/lib/envconf.sh
COPY --chmod=0755 rootfs/entrypoint.sh /usr/local/bin/flyway-entrypoint

ENTRYPOINT ["/usr/local/bin/flyway-entrypoint"]
# Declaring ENTRYPOINT drops the CMD inherited from upstream; this is upstream's.
CMD ["-?"]
