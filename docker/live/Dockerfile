FROM mcr.microsoft.com/mssql/server:2022-latest

USER root

RUN apt-get update \
    && DEBIAN_FRONTEND=noninteractive apt-get install -y --no-install-recommends openssl \
    && rm -rf /var/lib/apt/lists/* \
    && mkdir -p /etc/ssl/private \
    && openssl req -x509 -newkey rsa:2048 -nodes -sha256 -days 7000 \
      -keyout /etc/ssl/private/mssql-live.key \
      -out /etc/ssl/certs/mssql-live.pem \
      -subj "/CN=localhost" \
      -addext "subjectAltName=DNS:localhost,IP:127.0.0.1" \
    && chown 10001:0 /etc/ssl/private/mssql-live.key /etc/ssl/certs/mssql-live.pem \
    && chmod 440 /etc/ssl/private/mssql-live.key /etc/ssl/certs/mssql-live.pem

COPY docker/live/mssql.conf /var/opt/mssql/mssql.conf

USER mssql
