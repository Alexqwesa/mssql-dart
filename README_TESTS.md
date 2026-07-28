# Testing mssql

## Offline tests

```powershell
dart test
```

`test/live/**` is gated: without `MSSQL_LIVE_TESTS=1` those files skip rather
than fail.

## Native TLS C++ tests

The native OpenSSL ABI has an in-memory client/server CTest that covers the
handshake, certificate extraction, and encrypted request/response flow.

GitHub Actions builds and tests self-contained Windows x64 and Linux x64
helpers on every pull request. The `mssql-tls-windows-x64` and
`mssql-tls-linux-x64` workflow artifacts contain the distributable helpers;
tagged builds also attach them, with `SHA256SUMS`, to the GitHub release.

On Windows, with Visual Studio 2022, CMake, Ninja, and OpenSSL installed:

```powershell
.\tool\build_native.ps1
```

On Linux, with a C++ compiler, CMake, Ninja, and OpenSSL development headers:

```bash
cmake -S native -B build/native -G Ninja -DBUILD_TESTING=ON
cmake --build build/native
ctest --test-dir build/native --output-on-failure
```

## Full SQL Server matrix

`tool/full_tests.ps1` builds the native helper, runs offline Dart tests, then
starts normal and force-encryption containers for SQL Server 2017, 2019, 2022,
and 2025. It runs `test/live` once per edition and leaves the matrix running
for reuse on later runs.

```powershell
.\tool\full_tests.ps1
```

Stop the matrix when finished with:

```powershell
docker compose -f .\docker-compose.matrix.yml down
```

The eight host ports are 14330/14331 (2017), 14334/14335 (2019),
14336/14337 (2022), and 14338/14339 (2025). SQL Server 2012 through 2016 have
no official Linux container images; test those releases against externally
provisioned Windows instances by setting the normal `MSSQL_*` environment
variables.

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
standard `/var/opt/mssql` layout, run SQL Server as the `mssql` user, and be
able to install OpenSSL while building the live-test image.

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
