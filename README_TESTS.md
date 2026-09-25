# Testing mssql

See [`test/README.md`](test/README.md) for the coverage map organized by test
category and for the external-infrastructure scenarios outside the Docker
matrix.

## Offline tests

```powershell
dart test
```

`test/live/**` is gated: without `MSSQL_LIVE_TESTS=1` those files skip rather
than fail.

## Patched Dart SDK and TLS subpackage

The TLS path requires the SDK patch in
`packages/tls_fragment_secure_socket/secure_socket_tls_fragment.patch`, based
on Dart `3.14.0-165.0.dev`. Build the SDK as described in the
[subpackage README](packages/tls_fragment_secure_socket/README.md), then use
that SDK's `dart` executable for dependency resolution, analysis, and tests.

Run the high-level fragment socket tests separately:

```powershell
Push-Location packages/tls_fragment_secure_socket
C:\path\to\patched-dart-sdk\bin\dart.exe test
Pop-Location
```

The suite covers direct and upgraded TLS connections, serialized inherited
`IOSink` writes, explicit fragment completion, maximum-size enforcement, and
copy-at-submit behavior. Root tests add deterministic TDS PRELOGIN bridge and
opaque-ciphertext passthrough coverage.

## Full SQL Server matrix

The compatibility matrix:
`tool/full_tests.ps1` + `docker-compose.matrix.yml` run SQL Server **2017,
2019, 2022, and 2025**, each with a normal endpoint and a force-TLS sibling.
CI gates that same matrix (one edition per job) in the
`Compatibility matrix (*)` workflow jobs — should reuse it.

`tool/full_tests.ps1` also runs the TLS subpackage and offline Dart tests, then
leaves the eight containers up for reuse. Point it at the patched SDK when that
SDK is not first on `PATH`:

```powershell
$env:MSSQL_PATCHED_DART = 'C:\path\to\patched-dart-sdk\bin\dart.exe'
.\tool\full_tests.ps1
```

Stop the matrix when finished with:

```powershell
docker compose -f .\docker-compose.matrix.yml down
```

The eight host ports are 14170/14171 (2017), 14190/14191 (2019),
14220/14221 (2022), and 14250/14251 (2025). This separate range lets the
matrix run beside the ordinary 14334/14335 live-test stack. SQL Server 2012
through 2016 have no official Linux container images; test those releases
against externally provisioned Windows instances by setting the normal
`MSSQL_*` environment variables.

## Live SQL Server tests

One compose file starts two containers:

| Container | Host port | Used by |
| --- | --- | --- |
| `mssql-dart-live` | **14334** | Most of `test/live` (default `MSSQL_PORT` / `encrypt: false`) |
| `mssql-dart-live-force-tls` | **14335** | `tls_force_encrypt_stress_test.dart` (hard-wired; always `encrypt: true`) |

```powershell
Copy-Item .env.example .env   # once
docker compose --env-file .env -f docker-compose.live.yml up -d --build

$env:MSSQL_LIVE_TESTS = '1'
$env:MSSQL_HOST = '127.0.0.1'
$env:MSSQL_USER = 'sa'
$env:MSSQL_PASSWORD = 'Strong_test_password_123!'
$env:MSSQL_TRUST_SERVER_CERTIFICATE = '1'
# Defaults: MSSQL_PORT=14334, MSSQL_ENCRYPT=0

dart test test/live --concurrency=1

docker compose --env-file .env -f docker-compose.live.yml down
```

`MSSQL_LIVE_IMAGE` selects the SQL Server Linux image for both containers. It
defaults to SQL Server 2022. Set it before Compose (or edit `.env`) to run the
same suite against other releases:

```powershell
$env:MSSQL_LIVE_IMAGE = 'mcr.microsoft.com/mssql/server:2019-latest'
docker compose --env-file .env -f docker-compose.live.yml up -d --build

$env:MSSQL_LIVE_IMAGE = 'mcr.microsoft.com/mssql/server:2025-latest'
docker compose --env-file .env -f docker-compose.live.yml up -d --build
```

Any compatible SQL Server Linux image can be supplied. It must support the
standard `/var/opt/mssql` layout and run SQL Server as the `mssql` user.

`MSSQL_PASSWORD` is required whenever `MSSQL_LIVE_TESTS=1`. Compose has no
persistent volume; `docker compose down` wipes both containers. Do not use
production credentials.

```bash
cp -n .env.example .env
docker compose --env-file .env -f docker-compose.live.yml up -d --build
export MSSQL_LIVE_TESTS=1 MSSQL_HOST=127.0.0.1 \
  MSSQL_USER=sa MSSQL_PASSWORD='Strong_test_password_123!' \
  MSSQL_TRUST_SERVER_CERTIFICATE=1
dart test test/live --concurrency=1
```
