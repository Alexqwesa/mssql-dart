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
* CI: run unit tests without Docker before the SQL Server 2022 integration suite.

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
