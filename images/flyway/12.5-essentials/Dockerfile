FROM flyway/flyway:12.5-alpine

RUN wget -qO "/flyway/drivers/postgresql-42.7.11.jar" \
    https://jdbc.postgresql.org/download/postgresql-42.7.11.jar \
    && wget -qO "/flyway/drivers/clickhouse-jdbc-0.9.8-all.jar" \
    https://repo1.maven.org/maven2/com/clickhouse/clickhouse-jdbc/0.9.8/clickhouse-jdbc-0.9.8-all.jar