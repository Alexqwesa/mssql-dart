# Test suite overview

The suite is organized by the behavior being verified, not only by source
file. Tests fall into three execution tiers:

| Tier | Location | Requires |
| --- | --- | --- |
| Dart protocol and API tests | `test/*_test.dart` | Patched Dart SDK |
| TLS fragment socket tests | `packages/tls_fragment_secure_socket/test/` | Patched Dart SDK |
| Live SQL Server tests | `test/live/` | A configured SQL Server |

## Dart protocol and API tests

Run all tests that do not require SQL Server:

```powershell
$files = Get-ChildItem test -File -Filter '*_test.dart'
dart test $files.FullName
```

The offline tests cover these categories:

| Category | Main test files | Coverage |
| --- | --- | --- |
| TDS framing and limits | `tds_buffer_test.dart`, `unit_test.dart` | Packet splitting, packet headers, protocol limits, malformed lengths |
| PRELOGIN and LOGIN7 | `mock_prelogin_test.dart`, `mock_full_login_test.dart`, `login7_encode_test.dart` | Negotiation, malformed replies, complete mock login, password encoding |
| Query tokens and types | `token_stream_test.dart`, `type_decode_test.dart` | Metadata, rows, DONE, ERROR/INFO, ENVCHANGE, PLP, SQL type decoding |
| RPC and parameters | `rpc_encode_test.dart`, `typed_values_test.dart` | `sp_executesql`, typed values, output parameters, identifier validation |
| Bulk Load and TVP | `bulk_encode_test.dart`, `tvp_encode_test.dart` | BCP metadata, destination nullability, row validation, TVP encoding |
| Authentication | `ntlm_auth_test.dart`, `mock_sspi_login_test.dart`, `azure_ad_auth_test.dart`, `mock_fedauth_login_test.dart` | NTLMv2, channel binding, SSPI exchange, FedAuth tokens |
| Connection options | `connection_string_test.dart`, `named_instance_test.dart`, `timeout_unit_test.dart` | ADO/URL parsing, SQL Browser, PRELOGIN and TLS handshake deadlines |
| Pool and retry logic | `pool_stats_test.dart`, `transient_test.dart`, `pool_*_config_test.dart` | Counters, configuration, transient classification, retry behavior |
| TLS bridge and fragment output | `tls_bridge_test.dart`, `packages/tls_fragment_secure_socket/test/` | PRELOGIN unwrap/passthrough, raw TLS upgrades, fragment serialization, oversized writes, and inherited IOSink ordering |

## Live SQL Server categories

Set `MSSQL_LIVE_TESTS=1` before running anything under `test/live`. The normal
Docker endpoint permits cleartext or negotiated TLS; the force-encryption
endpoint rejects cleartext.

| Category | Main test files | Coverage |
| --- | --- | --- |
| Connection lifecycle | `connection_live_test.dart`, `connection_lifecycle_test.dart`, `connection_failures_live_test.dart` | Open/close, busy guards, wrong credentials, missing database, DNS and refused endpoint failures |
| CRUD and SQL semantics | `crud_live_test.dart`, `scenarios_test.dart`, `integration_test.dart` | DDL/DML, parameterized CRUD, streaming, multiple results |
| SQL types | `types_test.dart`, `legacy_types_test.dart`, `typed_values_live_test.dart`, `tls_types_test.dart` | Numeric boundaries, temporal types, PLP, XML, GUID, money, rowversion, legacy types |
| Unicode and hostile values | `unicode_parameters_live_test.dart` | Multilingual UTF-16, combining forms, supplementary characters, representative injection strings as parameters |
| Transactions and session reset | `transaction_live_test.dart`, `transaction_failure_live_test.dart`, `session_db_live_test.dart` | Savepoints, isolation, constraint/syntax failures, XACT_ABORT automatic rollback, open-transaction pool cleanup |
| Bulk Load | `bulk_live_test.dart`, `bulk_failure_live_test.dart`, `bulk_cancel_live_test.dart`, `tls_alignment_live_test.dart` | Nullable metadata, 10,000-row TCP/TLS loads, packet boundaries, explicit cancellation, failures, rollback and reuse |
| Cancellation and timeouts | `attention_live_test.dart`, `attention_tls_live_test.dart`, `bulk_cancel_live_test.dart`, `cancel_scenarios_live_test.dart`, `timeout_live_test.dart` | Attention during batch, RPC, streaming, Bulk Load, transactions and pooled use |
| TLS | `tls_test.dart`, `tls_certificate_live_test.dart`, `tls_alignment_live_test.dart`, `tls_force_encrypt_stress_test.dart` | Negotiated/forced TLS, CA and hostname validation, multi-packet requests, Bulk Load and Attention |
| Stored procedures and tokens | `stored_procs_test.dart`, `info_live_test.dart`, `token_sequences_live_test.dart` | Return/output values, INFO/ERROR, DONE, NOCOUNT, triggers, empty and multiple results |
| Pool behavior and concurrency | `pool_*_live_test.dart`, `race_conditions_test.dart`, `connection_churn_live_test.dart` | Waiter FIFO, reset/validation, killed sessions, close races, 50 concurrent calls, connection churn, forced-TLS concurrency |
| HA options | `ha_live_test.dart` | Read-only intent and initial failover partner against standalone SQL Server |
| API examples | `readme_api_test.dart`, `connection_string_live_test.dart` | Public examples and connection-string behavior remain executable |

Run the normal live suite:

```powershell
$env:MSSQL_LIVE_TESTS = '1'
$env:MSSQL_HOST = '127.0.0.1'
$env:MSSQL_PORT = '14334'
$env:MSSQL_FORCE_TLS_PORT = '14335'
$env:MSSQL_USER = 'sa'
$env:MSSQL_PASSWORD = 'Strong_test_password_123!'
dart test test/live --concurrency=1
```

Bulk scale tests use 10,000 rows by default. Set
`MSSQL_BULK_STRESS_ROWS=100000` for the heavier TCP and TLS run without adding
permanently skipped stress tests.

Run fragment-socket, offline, and live tests against SQL Server 2017, 2019, 2022, and
2025 with:

```powershell
.\tool\full_tests.ps1
```

## Certificate fixtures

`docker/live/certs/` contains a test-only private CA and a CA-signed server
certificate for `localhost`. The private server key is intentionally committed
for deterministic local and CI testing. It must never be used outside the
Docker test servers. `tls_certificate_live_test.dart` verifies both a PEM file
and a PEM certificate directory.

Changing the certificate or Docker image setup requires incrementing
`MSSQL_LIVE_REVISION` in `docker/live/Dockerfile` and the matching
`matrixImageRevision` in `tool/full_tests.ps1`.

## External infrastructure coverage

The standard Docker matrix cannot provide these environments:

- domain-joined SQL Server for real NTLM authentication;
- Azure SQL with a real bearer token and public certificate;
- SQL Browser backed by a real named instance;
- an Always On availability group with routing and multisubnet failover;
- Android device/emulator runtime TLS against SQL Server;
- SQL Server 2012 through 2016, for which Microsoft provides no Linux images.

Their protocol encoders and mock handshakes are tested offline, but release
claims must distinguish that coverage from a real infrastructure test.
