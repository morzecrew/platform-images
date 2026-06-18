# syntax=docker/dockerfile:1.25

# ....................... #

ARG FLYWAY_VERSION=12.5
FROM flyway/flyway:${FLYWAY_VERSION}-alpine

ARG POSTGRES_JDBC_VERSION=42.7.11
ARG CLICKHOUSE_JDBC_VERSION=0.9.8

RUN wget -qO "/flyway/drivers/postgresql-${POSTGRES_JDBC_VERSION}.jar" \
    "https://jdbc.postgresql.org/download/postgresql-${POSTGRES_JDBC_VERSION}.jar" \
    && wget -qO "/flyway/drivers/clickhouse-jdbc-${CLICKHOUSE_JDBC_VERSION}-all.jar" \
    "https://repo1.maven.org/maven2/com/clickhouse/clickhouse-jdbc/${CLICKHOUSE_JDBC_VERSION}/clickhouse-jdbc-${CLICKHOUSE_JDBC_VERSION}-all.jar"
