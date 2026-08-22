ARG MSSQL_IMAGE=mcr.microsoft.com/mssql/server:2022-latest
FROM ${MSSQL_IMAGE}

ARG MSSQL_LIVE_REVISION=3
LABEL org.mssql.dart.live.revision=${MSSQL_LIVE_REVISION}

USER root

# Place TLS material under /var/opt/mssql. Do not use
# /etc/ssl/private — that directory is typically mode 700 root:root, so the
# mssql user cannot traverse it even when the key file itself is chowned.
RUN mkdir -p /var/opt/mssql/certs

COPY docker/live/certs/server.key /var/opt/mssql/certs/mssql-live.key
COPY docker/live/certs/server.pem /var/opt/mssql/certs/mssql-live.pem

RUN chown -R 10001:0 /var/opt/mssql \
    && chmod 750 /var/opt/mssql/certs \
    && chmod 440 /var/opt/mssql/certs/mssql-live.key /var/opt/mssql/certs/mssql-live.pem

COPY docker/live/mssql.conf /var/opt/mssql/mssql.conf

# SQL Server 2017's current image has no named `mssql` account, while newer
# images do. A numeric UID works on every supported image and needs no passwd
# entry in the base image.
USER 10001
