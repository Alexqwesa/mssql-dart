# Changelog

## Unreleased

* LAN typed binders: `MssqlXml` / `MssqlVarbinary` for `xml` and sized
  `varbinary(n)` / `varbinary(max)` params (bare `String` → nvarchar; bare
  `List<int>` stays `varbinary(max)`).
* LAN typed binders: `MssqlDateTime` / `MssqlSmallDateTime` for legacy
  `datetime` / `smalldatetime` params (go-mssqldb `DateTime1`; bare
  `DateTime` stays `datetime2`).
* LAN session resilience: TCP `keepAlive` (go-mssqldb default 30s;
  `KeepAlive=` in connection strings; `Duration.zero` disables) +
  `TCP_NODELAY`; `sessionInitSql` after login and after `resetSession`
  (go-mssqldb `SessionInitSQL`).
* LAN typed binders: `MssqlVarchar`, `MssqlDate`, `MssqlTime` for varchar /
  date / time params (bare `String`/`DateTime` stay nvarchar/datetime2).
* LAN Always On / HA: `ApplicationIntent=ReadOnly` (`readOnlyIntent` → LOGIN7
  `fReadOnlyIntent`); ENVCHANGE type 20 routing reconnect (one hop);
  `FailoverPartner` / `FailoverPort` on primary connect failure;
  `MultiSubnetFailover` parallel DNS dial; connection-string + pool knobs.
* LAN typed binders: `MssqlGuid`, `MssqlMoney`, `MssqlSmallMoney`,
  `MssqlDateTimeOffset`, `MssqlDecimal` for uniqueidentifier / money /
  datetimeoffset / decimal|numeric params.
* LAN transactions: `MssqlIsolationLevel`, `beginTransaction(isolation:)`,
  `savepoint` / `rollbackTo`, `transaction(isolation:)` on connection + pool.
* LAN diagnostics + resilience: parse full INFO/ERROR metadata (`state`,
  `severity`, `serverName`, `procName`, `lineNo`); `onInfoMessage` on
  connection/pool; `MssqlTransient.isTransient` / `retry`; pool/connect
  `connectRetries` (pool default 2).
* LAN RPC / stored procedures: `MssqlConnection.call` / `MssqlPool.call` with
  `MssqlOutput` parameters; capture `RETURNSTATUS` + `RETURNVALUE` into
  `MssqlProcedureResult` (go-mssqldb / ms-tds RETURNVALUE).

## 0.2.0

LAN / on-prem hardening wave: cancel, NTLM, timeouts, pool health, named
instances, session reset, connection strings, bulk insert, and TVP.

* Fix TDS buffer data corruption when multi-byte reads straddle packet boundaries
  (carry unread remainder into the next packet — upstream PR #3).
* Protocol offline unit coverage (buffer, PreLogin, Login7, tokens, types, RPC,
  Attention, FedAuth mock) inspired by microsoft/go-mssqldb / Tedious / ms-tds.
* `TdsBuffer.sendAttention` / `MssqlConnection.cancel` with `drainUntilAttentionAck`;
  live cancel suites (plain + TLS + pool / multi / RPC).
* NTLM Type 1–3 (NTLMv2, MIC, KEY_EXCH, TLS channel bindings); `connectNtlm`;
  pool `ntlm` / `ntlmDomain`.
* Pool Azure AD: `azureAd` / `azureAdAuth` (FedAuth; takes precedence over NTLM/SQL).
* LAN timeouts: login covers full handshake; `queryTimeout` / per-call Attention;
  expose `appName` + `packetSize`.
* Pool health: dead-socket detection; `validateOnAcquire` (default true).
* Named instances: `HOST\INSTANCE` parse, SQL Browser UDP 1434, PRELOGIN INSTOPT.
* Session DB tracking (`database` / `initialDatabase` / `resetDatabase`);
  TDS RESETCONNECTION via `resetSession`; pool `resetOnRelease` (default true).
* Connection strings: ADO.NET + `sqlserver://` (`connectFromString`,
  `MssqlPoolConfig.fromConnectionString`).
* Bulk insert (`bulkInsert` BCP) and TVP (`MssqlTvp` type 0xF3).
* README LAN / on-prem cookbook; CI unit job before Docker integration.

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
