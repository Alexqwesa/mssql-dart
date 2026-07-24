# Changelog

## Unreleased

* Fix TDS buffer data corruption when multi-byte reads straddle packet boundaries
  (carry unread remainder into the next packet — upstream PR #3).
* Add protocol unit tests inspired by microsoft/go-mssqldb (`buf_test.go`,
  `bad_server_test.go`): `test/tds_buffer_test.dart`, `test/mock_prelogin_test.dart`.
* Add Login7 golden encode, token-stream, and TypeInfo decode offline unit tests
  (`test/login7_encode_test.dart`, `test/token_stream_test.dart`,
  `test/type_decode_test.dart`) with shared `test/helpers/tds_socket.dart`.
* Add RPC encode tests, DATETIME2/OFFSET/DECIMAL/PLP multi-chunk decode coverage,
  and mock PreLogin→Login7→LOGINACK handshake (`test/rpc_encode_test.dart`,
  `test/mock_full_login_test.dart`).
* Extend token-stream coverage: multi-result sets, ORDER/RETURNVALUE skip,
  ENVCHANGE begin/commit txn descriptor, FeatureExtAck + packet-size; RPC large
  NVARCHAR PLP param encoding.
* Add DML-only DONE, empty COLMETADATA, streamQueryResponse offline tests;
  annotate protocol unit tests with go-mssqldb / Tedious / ms-tds / PR #3 sources.
* Extend offline coverage: DONE_PROC/DONE_IN_PROC/RETURNSTATUS, unknown token,
  multi-set `rowsAffected` sum, 9-col NBCROW bitmap boundary, sql_variant INT/
  NVARCHAR/NULL decode, empty Attention packet framing.
* Extend offline coverage: TEXT/NTEXT/IMAGE COLMETADATA TableName skip + ROW,
  computed TEXT `numParts=0`, ENVCHANGE routing/collation skip, INFO-before-row,
  TEXT/NTEXT/IMAGE TypeInfo decode.
* Extend offline coverage: XML/UDT TYPE_INFO + COLMETADATA/ROW (PLP), Login7
  SSPI + FedAuth feature-data layout, PRELOGIN OOB field length + encryptRequired.
* Extend offline coverage: Attention DONE (`doneFlagAttn`), multi-packet token
  stream straddles for ROW INT4 / NVARCHAR length / COLMETADATA count (PR #3).
* Add `TdsBuffer.sendAttention` / `MssqlConnection.cancel`; offline Attention
  cancel mock; NTLM Type 1 NEGOTIATE encode; Azure AD `extractAccessToken` unit
  tests (no network).
* Fix Attention cancel: drain until DONE `doneAttn` when the server sends a
  separate aborted-batch DONE first (keeps connection usable after cancel).
* Add live cancel + large multi-packet / many-row tests (`attention_live_test.dart`).
* Add `drainUntilAttentionAck`; live `queryStream` cancel (WAITFOR + mid-rows);
  offline stream Attention drain; document that bare stream break still closes.
* Implement NTLM Type 2 parse + Type 3 NTLMv2 authenticate (MD4 + HMAC-MD5)
  with curl/davenport golden vectors; add `package:crypto` dependency.
* Wire NTLM SSPI into login: `MssqlConnection.connectNtlm`, `tokenSSPI` →
  `packSSPIMessage` in `processLoginResponse`; mock SSPI handshake test.
* CI: run unit tests without Docker before the SQL Server 2022 integration suite.
* `MssqlPoolConfig.ntlm` / `ntlmDomain`: pool opens via `connectNtlm` (SSPI).
* `MssqlPoolConfig.azureAd` / `azureAdAuth`: pool opens via `connectAzureAd`
  (FedAuth); Azure AD takes precedence over NTLM/SQL when set.
* NTLM Type 3: Version+MIC header (go-mssqldb 88-byte layout); MIC when
  TargetInfo has MsvAvTimestamp; KEY_EXCH EncryptedRandomSessionKey via RC4.
* NTLM TLS channel bindings: `tls-server-end-point` CBT → MsvAvChannelBindings
  after SecureSocket handshake (SQL Extended Protection).
* Mock FedAuth login handshake: PreLogin(fedAuth) → Login7 FeatureExt →
  FEATUREEXTACK + LOGINACK (`test/mock_fedauth_login_test.dart`).
* Parse `tokenFedAuthInfo` (STS URL / SPN); optional `onFedAuthInfo` sends
  `packFedAuthToken` (ADAL-style); skip safely when handler absent.
* Live Attention cancel over TLS against Docker SQL Edge
  (`test/attention_tls_live_test.dart`): WAITFOR, stream, txn, back-to-back.
* Live cancel scenarios: `queryMultiple`, parameterized RPC, pool acquire
  (plain + TLS) — `test/cancel_scenarios_live_test.dart`.
* LAN focus: login timeout covers full handshake; `queryTimeout` / per-call
  timeout (Attention + drain); expose `appName` + `packetSize` on connect/pool.
* LAN pool health: socket-done marks connection dead; `validateOnAcquire`
  (default true) probes idle connections with `SELECT 1` before reuse.

## 0.1.1

* Remove hardcoded credentials from example and benchmark tool — all connection details now read from environment variables.
* Wrap connection and pool usage in `try/finally` to guarantee `close()` on error.

## 0.1.0

* Initial release.
* Pure-Dart TDS 7.4 driver — no native extensions, no FFI.
* `MssqlConnection` with SQL Server and Azure AD authentication (bearer token, ROPC, client credentials).
* `MssqlPool` with configurable min/max, idle reaping, and acquire timeouts.
* Full read support for all common SQL Server types including `sql_variant`.
* Named-parameter queries using `sp_executesql` (`@name` syntax).
* Streaming large result sets with `queryStream`.
* Multiple result sets via `queryMultiple`.
* Transaction support — callback form (auto commit/rollback) and manual `begin`/`commit`/`rollback`.
* TLS encryption with optional self-signed certificate trust.
* `MssqlException` with `errorCode`, `severity`, and `precedingErrors` for multi-error batches.
