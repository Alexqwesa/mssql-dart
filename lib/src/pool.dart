import 'dart:async';

import 'auth/azure_ad_auth.dart';
import 'connection.dart';
import 'exception.dart';
import 'result.dart';
import 'tds/constants.dart';

/// Configuration for [MssqlPool].
class MssqlPoolConfig {
  final String host;
  final int port;

  /// Optional named instance (`SQLEXPRESS`, etc.). Also parsed from
  /// `host\INSTANCE` / `host\INSTANCE,port` in [host].
  final String? instanceName;
  final String user;
  final String password;
  final String database;
  final String appName;
  final int packetSize;
  final bool encrypt;
  final bool trustServerCertificate;
  final Duration connectionTimeout;

  /// Default query deadline applied to pooled connections (null = none).
  final Duration? queryTimeout;

  /// When non-null, [MssqlPool] opens connections via
  /// [MssqlConnection.connectAzureAd] (FedAuth). Takes precedence over
  /// [ntlmDomain] and SQL auth.
  final AzureAdAuth? azureAdAuth;

  /// When non-null (and [azureAdAuth] is null), [MssqlPool] opens connections
  /// via [MssqlConnection.connectNtlm] (Windows SSPI / NTLMv2).
  final String? ntlmDomain;

  /// Optional workstation name for NTLM (used only when [ntlmDomain] is set).
  final String? ntlmWorkstation;

  /// Minimum number of idle connections to keep open (default 0).
  final int min;

  /// Maximum number of total connections (default 10).
  final int max;

  /// Close idle connections that have been unused for this duration (default 30s).
  final Duration idleTimeout;

  /// Throw [MssqlException] if a connection cannot be acquired within this duration (default 15s).
  final Duration acquireTimeout;

  /// When true (default), idle connections are probed with `SELECT 1` before
  /// reuse so half-open LAN sockets (server KILL, reboot, firewall) are
  /// discarded instead of handed to callers.
  final bool validateOnAcquire;

  /// When true (default), [MssqlPool.release] runs `USE` back to [database]
  /// (or the connection's login database) so a caller that switched databases
  /// does not poison the next acquire.
  final bool resetOnRelease;

  const MssqlPoolConfig({
    required this.host,
    this.port = 1433,
    this.instanceName,
    required this.user,
    required this.password,
    this.database = '',
    this.appName = 'mssql-dart',
    this.packetSize = defaultPacketSize,
    this.encrypt = true,
    this.trustServerCertificate = false,
    this.connectionTimeout = const Duration(seconds: 15),
    this.queryTimeout,
    this.azureAdAuth,
    this.ntlmDomain,
    this.ntlmWorkstation,
    this.min = 0,
    this.max = 10,
    this.idleTimeout = const Duration(seconds: 30),
    this.acquireTimeout = const Duration(seconds: 15),
    this.validateOnAcquire = true,
    this.resetOnRelease = true,
  });

  /// Pool config that opens connections with Azure AD (FedAuth).
  ///
  /// [encrypt] is always true (Azure AD requires TLS). [user]/[password] are
  /// unused placeholders for the shared config shape.
  factory MssqlPoolConfig.azureAd({
    required String host,
    int port = 1433,
    String? instanceName,
    required AzureAdAuth azureAdAuth,
    String database = '',
    String appName = 'mssql-dart',
    int packetSize = defaultPacketSize,
    bool trustServerCertificate = false,
    Duration connectionTimeout = const Duration(seconds: 15),
    Duration? queryTimeout,
    int min = 0,
    int max = 10,
    Duration idleTimeout = const Duration(seconds: 30),
    Duration acquireTimeout = const Duration(seconds: 15),
    bool validateOnAcquire = true,
    bool resetOnRelease = true,
  }) {
    return MssqlPoolConfig(
      host: host,
      port: port,
      instanceName: instanceName,
      user: '',
      password: '',
      database: database,
      appName: appName,
      packetSize: packetSize,
      encrypt: true,
      trustServerCertificate: trustServerCertificate,
      connectionTimeout: connectionTimeout,
      queryTimeout: queryTimeout,
      azureAdAuth: azureAdAuth,
      min: min,
      max: max,
      idleTimeout: idleTimeout,
      acquireTimeout: acquireTimeout,
      validateOnAcquire: validateOnAcquire,
      resetOnRelease: resetOnRelease,
    );
  }

  /// Pool config that opens connections with Windows NTLM (SSPI).
  factory MssqlPoolConfig.ntlm({
    required String host,
    int port = 1433,
    String? instanceName,
    required String domain,
    required String user,
    required String password,
    String? workstation,
    String database = '',
    String appName = 'mssql-dart',
    int packetSize = defaultPacketSize,
    bool encrypt = true,
    bool trustServerCertificate = false,
    Duration connectionTimeout = const Duration(seconds: 15),
    Duration? queryTimeout,
    int min = 0,
    int max = 10,
    Duration idleTimeout = const Duration(seconds: 30),
    Duration acquireTimeout = const Duration(seconds: 15),
    bool validateOnAcquire = true,
    bool resetOnRelease = true,
  }) {
    return MssqlPoolConfig(
      host: host,
      port: port,
      instanceName: instanceName,
      user: user,
      password: password,
      database: database,
      appName: appName,
      packetSize: packetSize,
      encrypt: encrypt,
      trustServerCertificate: trustServerCertificate,
      connectionTimeout: connectionTimeout,
      queryTimeout: queryTimeout,
      ntlmDomain: domain,
      ntlmWorkstation: workstation,
      min: min,
      max: max,
      idleTimeout: idleTimeout,
      acquireTimeout: acquireTimeout,
      validateOnAcquire: validateOnAcquire,
      resetOnRelease: resetOnRelease,
    );
  }
}

class _IdleEntry {
  final MssqlConnection connection;
  final DateTime idleSince;
  _IdleEntry(this.connection) : idleSince = DateTime.now();
}

/// A pool of [MssqlConnection]s.
///
/// Mirrors the node-mssql / tarn pattern:
/// - [min] idle connections are kept alive.
/// - [max] caps total open connections.
/// - Callers that exceed [max] are queued until a connection is released.
/// - Idle connections older than [idleTimeout] are closed.
///
/// ```dart
/// final pool = MssqlPool(MssqlPoolConfig(
///   host: 'localhost', user: 'sa', password: 'P@ssw0rd',
/// ));
/// await pool.open();
///
/// final result = await pool.query('SELECT * FROM users WHERE id = @id', {'id': 1});
///
/// await pool.close();
/// ```
///
/// Auth variants:
/// - SQL: default [MssqlPoolConfig] constructor
/// - Azure AD: [MssqlPoolConfig.azureAd]
/// - Windows NTLM: [MssqlPoolConfig.ntlm] (domain-joined SQL that accepts SSPI)
class MssqlPool {
  final MssqlPoolConfig config;

  final _idle = <_IdleEntry>[];
  final _pending = <Completer<MssqlConnection>>[];
  int _total = 0;
  bool _closed = false;
  Timer? _idleTimer;

  MssqlPool(this.config);

  /// Opens the pool and pre-creates [config.min] connections.
  Future<void> open() async {
    _startIdleTimer();
    if (config.min > 0) {
      await Future.wait([
        for (int i = 0; i < config.min; i++) _createAndIdle(),
      ]);
    }
  }

  /// Acquires a connection from the pool.
  ///
  /// Returns immediately if an idle connection is available or total < max.
  /// Otherwise queues the caller until a connection is released.
  /// Throws [MssqlException] if [config.acquireTimeout] is exceeded.
  ///
  /// When [MssqlPoolConfig.validateOnAcquire] is true, idle connections are
  /// probed before reuse; dead ones are discarded and replaced.
  Future<MssqlConnection> acquire() async {
    if (_closed) throw StateError('Pool is closed');

    // Return an idle connection if available (and still healthy).
    while (_idle.isNotEmpty) {
      final entry = _idle.removeLast();
      if (!entry.connection.isOpen) {
        _total--;
        continue;
      }
      if (config.validateOnAcquire) {
        final ok = await entry.connection.validate();
        if (!ok) {
          _total--;
          continue;
        }
      }
      return entry.connection;
    }

    // Create a new connection if under the cap.
    if (_total < config.max) {
      _total++;
      try {
        final conn = await _openConnection();
        if (_closed) {
          // Pool was closed while we were connecting — discard the new connection.
          unawaited(conn.close());
          throw MssqlException('Pool closed');
        }
        return conn;
      } catch (_) {
        _total--;
        rethrow;
      }
    }

    // Pool is at max — queue.
    final completer = Completer<MssqlConnection>();
    _pending.add(completer);
    return completer.future.timeout(
      config.acquireTimeout,
      onTimeout: () {
        _pending.remove(completer);
        throw MssqlException(
          'Pool acquire timeout: no connection available within '
          '${config.acquireTimeout.inSeconds}s (pool size: ${config.max})',
        );
      },
    );
  }

  /// Releases a connection back to the pool.
  ///
  /// When [MssqlPoolConfig.resetOnRelease] is true, switches the session back
  /// to the pool database (or login database) via `USE` before reuse. Failed
  /// resets discard the connection.
  ///
  /// If there are pending callers, the connection is handed directly to the
  /// next waiter. Otherwise it goes to the idle list.
  Future<void> release(MssqlConnection conn) async {
    if (_closed || !conn.isOpen) {
      _discard(conn);
      return;
    }

    if (config.resetOnRelease) {
      final target =
          config.database.isNotEmpty ? config.database : conn.initialDatabase;
      if (target.isNotEmpty) {
        final ok = await conn.resetDatabase(target);
        if (!ok || !conn.isOpen) {
          _discard(conn);
          return;
        }
      }
    }

    // Hand off to the next waiter first.
    while (_pending.isNotEmpty) {
      final completer = _pending.removeAt(0);
      if (!completer.isCompleted) {
        completer.complete(conn);
        return;
      }
    }

    // No waiters — keep idle.
    _idle.add(_IdleEntry(conn));
  }

  // ── Convenience query methods ──────────────────────────────────────────────

  /// Runs [sql] on an acquired connection, releases it when done.
  Future<MssqlResult> query(
    String sql, [
    Map<String, Object?> parameters = const {},
  ]) async {
    final conn = await acquire();
    try {
      return await conn.query(sql, parameters);
    } finally {
      await release(conn);
    }
  }

  /// Runs [sql] and returns all result sets.
  Future<MssqlMultiResult> queryMultiple(
    String sql, [
    Map<String, Object?> parameters = const {},
  ]) async {
    final conn = await acquire();
    try {
      return await conn.queryMultiple(sql, parameters);
    } finally {
      await release(conn);
    }
  }

  /// Runs [sql] and returns rows affected.
  Future<int> execute(
    String sql, [
    Map<String, Object?> parameters = const {},
  ]) async {
    final conn = await acquire();
    try {
      return await conn.execute(sql, parameters);
    } finally {
      await release(conn);
    }
  }

  /// Streams rows from [sql] on an acquired connection.
  Stream<MssqlRow> queryStream(
    String sql, [
    Map<String, Object?> parameters = const {},
  ]) async* {
    final conn = await acquire();
    try {
      await for (final row in conn.queryStream(sql, parameters)) {
        yield row;
      }
    } finally {
      await release(conn);
    }
  }

  /// Runs [fn] inside a transaction on an acquired connection.
  ///
  /// Commits on success, rolls back on error, then releases the connection.
  Future<T> transaction<T>(Future<T> Function(MssqlConnection conn) fn) async {
    final conn = await acquire();
    try {
      return await conn.transaction(fn);
    } finally {
      await release(conn);
    }
  }

  /// Closes all idle connections and waits for active connections to be released.
  Future<void> close() async {
    _closed = true;
    _idleTimer?.cancel();
    _idleTimer = null;

    // Reject any pending waiters.
    for (final c in _pending) {
      if (!c.isCompleted) {
        c.completeError(MssqlException('Pool closed'));
      }
    }
    _pending.clear();

    // Close all idle connections.
    final closing = _idle.map((e) => e.connection.close()).toList();
    _idle.clear();
    await Future.wait(closing, eagerError: false);
  }

  // ── Internals ──────────────────────────────────────────────────────────────

  Future<MssqlConnection> _openConnection() {
    final aad = config.azureAdAuth;
    if (aad != null) {
      return MssqlConnection.connectAzureAd(
        host: config.host,
        port: config.port,
        instanceName: config.instanceName,
        azureAdAuth: aad,
        database: config.database,
        appName: config.appName,
        packetSize: config.packetSize,
        trustServerCertificate: config.trustServerCertificate,
        timeout: config.connectionTimeout,
        queryTimeout: config.queryTimeout,
      );
    }
    final domain = config.ntlmDomain;
    if (domain != null) {
      return MssqlConnection.connectNtlm(
        host: config.host,
        port: config.port,
        instanceName: config.instanceName,
        domain: domain,
        user: config.user,
        password: config.password,
        workstation: config.ntlmWorkstation,
        database: config.database,
        appName: config.appName,
        packetSize: config.packetSize,
        encrypt: config.encrypt,
        trustServerCertificate: config.trustServerCertificate,
        timeout: config.connectionTimeout,
        queryTimeout: config.queryTimeout,
      );
    }
    return MssqlConnection.connect(
      host: config.host,
      port: config.port,
      instanceName: config.instanceName,
      user: config.user,
      password: config.password,
      database: config.database,
      appName: config.appName,
      packetSize: config.packetSize,
      encrypt: config.encrypt,
      trustServerCertificate: config.trustServerCertificate,
      timeout: config.connectionTimeout,
      queryTimeout: config.queryTimeout,
    );
  }

  Future<void> _createAndIdle() async {
    _total++;
    try {
      final conn = await _openConnection();
      _idle.add(_IdleEntry(conn));
    } catch (_) {
      _total--;
      rethrow;
    }
  }

  void _discard(MssqlConnection conn) {
    _total--;
    if (conn.isOpen) conn.close();
  }

  void _startIdleTimer() {
    _idleTimer =
        Timer.periodic(const Duration(seconds: 10), (_) => _reapIdle());
  }

  void _reapIdle() {
    final cutoff = DateTime.now().subtract(config.idleTimeout);
    final toKeep = <_IdleEntry>[];
    for (final entry in _idle) {
      final overMin = (_idle.length - toKeep.length) > config.min;
      if (overMin && entry.idleSince.isBefore(cutoff)) {
        _discard(entry.connection);
      } else {
        toKeep.add(entry);
      }
    }
    _idle
      ..clear()
      ..addAll(toKeep);
  }
}
