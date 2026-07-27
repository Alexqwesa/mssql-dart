FROM mcr.microsoft.com/mssql/server:2022-latest

USER root

# Place TLS material under /var/opt/mssql (owned by mssql). Do not use
# /etc/ssl/private — that directory is typically mode 700 root:root, so the
# mssql user cannot traverse it even when the key file itself is chowned.
RUN apt-get update \
    && DEBIAN_FRONTEND=noninteractive apt-get install -y --no-install-recommends openssl \
    && rm -rf /var/lib/apt/lists/* \
    && mkdir -p /var/opt/mssql/certs \
    && openssl req -x509 -newkey rsa:2048 -nodes -sha256 -days 7000 \
      -keyout /var/opt/mssql/certs/mssql-live.key \
      -out /var/opt/mssql/certs/mssql-live.pem \
      -subj "/CN=localhost" \
      -addext "subjectAltName=DNS:localhost,IP:127.0.0.1" \
    && chown -R 10001:0 /var/opt/mssql/certs \
    && chmod 750 /var/opt/mssql/certs \
    && chmod 440 /var/opt/mssql/certs/mssql-live.key /var/opt/mssql/certs/mssql-live.pem

COPY docker/live/mssql.conf /var/opt/mssql/mssql.conf

USER mssql
