import 'live_test_config.dart';
import 'live_test_gate.dart';
import 'package:mssql/mssql.dart';
import 'package:test/test.dart';

/// Live USE / ENVCHANGE + TDS RESETCONNECTION pool reset.
///
/// Requires `dart-mssql` on 127.0.0.1:14330. Skips when unreachable.

final _host = liveTestConfig.host;
final _port = liveTestConfig.port;
final _user = liveTestConfig.user;
final _password = liveTestConfig.password;

Future<bool> sqlUp() async {
  try {
    final c = await MssqlConnection.connect(
      host: _host,
      port: _port,
      user: _user,
      password: _password,
      database: 'master',
      encrypt: false,
      trustServerCertificate: true,
      timeout: const Duration(seconds: 5),
    );
    await c.close();
    return true;
  } catch (_) {
    return false;
  }
}

void main() {
  if (!beginLiveSuite()) return;
  late bool available;

  setUpAll(() async {
    available = await sqlUp();
  });

  test('USE updates conn.database; resetDatabase restores login DB', () async {
    if (!available) {
      markTestSkipped('SQL Server not available on :$_port');
      return;
    }
    final c = await MssqlConnection.connect(
      host: _host,
      port: _port,
      user: _user,
      password: _password,
      database: 'master',
      encrypt: false,
      trustServerCertificate: true,
    );
    addTearDown(c.close);

    expect(c.database.toLowerCase(), 'master');
    expect(c.initialDatabase.toLowerCase(), 'master');

    await c.query('USE tempdb');
    expect(c.database.toLowerCase(), 'tempdb');

    expect(await c.resetDatabase(), isTrue);
    expect(c.database.toLowerCase(), 'master');
  });

  test('pool resetOnRelease undoes USE before next acquire', () async {
    if (!available) {
      markTestSkipped('SQL Server not available on :$_port');
      return;
    }

    final pool = MssqlPool(MssqlPoolConfig(
      host: _host,
      port: _port,
      user: _user,
      password: _password,
      database: 'master',
      encrypt: false,
      trustServerCertificate: true,
      min: 0,
      max: 1,
      validateOnAcquire: true,
      resetOnRelease: true,
    ));
    await pool.open();
    addTearDown(pool.close);

    final a = await pool.acquire();
    await a.query('USE tempdb');
    expect(a.database.toLowerCase(), 'tempdb');
    await pool.release(a);

    final b = await pool.acquire();
    expect(identical(a, b), isTrue);
    expect(b.database.toLowerCase(), 'master');
    final name = await b.query('SELECT DB_NAME() AS db');
    expect((name[0]['db'] as String).toLowerCase(), 'master');
    await pool.release(b);
  });

  test('resetOnRelease false leaves switched database', () async {
    if (!available) {
      markTestSkipped('SQL Server not available on :$_port');
      return;
    }

    final pool = MssqlPool(MssqlPoolConfig(
      host: _host,
      port: _port,
      user: _user,
      password: _password,
      database: 'master',
      encrypt: false,
      trustServerCertificate: true,
      min: 0,
      max: 1,
      validateOnAcquire: false,
      resetOnRelease: false,
    ));
    await pool.open();
    addTearDown(pool.close);

    final a = await pool.acquire();
    await a.query('USE tempdb');
    await pool.release(a);

    final b = await pool.acquire();
    expect(b.database.toLowerCase(), 'tempdb');
    await pool.release(b);
  });

  test('resetSession clears temp table and restores database', () async {
    if (!available) {
      markTestSkipped('SQL Server not available on :$_port');
      return;
    }
    final c = await MssqlConnection.connect(
      host: _host,
      port: _port,
      user: _user,
      password: _password,
      database: 'master',
      encrypt: false,
      trustServerCertificate: true,
    );
    addTearDown(c.close);

    await c.query('USE tempdb');
    // Temp tables need a SQL batch (not sp_executesql) for session scope.
    await c.query(
      'CREATE TABLE #reset_probe (id INT); INSERT INTO #reset_probe VALUES (1)',
    );
    final before = await c.query('SELECT id FROM #reset_probe');
    expect(before[0]['id'], 1);

    expect(await c.resetSession(), isTrue);
    expect(c.database.toLowerCase(), 'master');

    await expectLater(
      c.query('SELECT id FROM #reset_probe'),
      throwsA(isA<MssqlException>()),
    );
  });

  test('pool resetOnRelease clears temp table for next borrower', () async {
    if (!available) {
      markTestSkipped('SQL Server not available on :$_port');
      return;
    }

    final pool = MssqlPool(MssqlPoolConfig(
      host: _host,
      port: _port,
      user: _user,
      password: _password,
      database: 'master',
      encrypt: false,
      trustServerCertificate: true,
      min: 0,
      max: 1,
      validateOnAcquire: false,
      resetOnRelease: true,
    ));
    await pool.open();
    addTearDown(pool.close);

    final a = await pool.acquire();
    await a.query(
      'CREATE TABLE #pool_probe (id INT); INSERT INTO #pool_probe VALUES (42)',
    );
    await pool.release(a);

    final b = await pool.acquire();
    expect(identical(a, b), isTrue);
    await expectLater(
      b.query('SELECT id FROM #pool_probe'),
      throwsA(isA<MssqlException>()),
    );
    await pool.release(b);
  });

  test('pool reset clears isolation and session settings after COMMIT',
      () async {
    if (!available) {
      markTestSkipped('SQL Server not available on :$_port');
      return;
    }
    final pool = MssqlPool(MssqlPoolConfig(
      host: _host,
      port: _port,
      user: _user,
      password: _password,
      database: 'tempdb',
      encrypt: false,
      trustServerCertificate: true,
      min: 0,
      max: 1,
      resetOnRelease: true,
    ));
    await pool.open();
    addTearDown(pool.close);
    await _ensureBorrower(pool);

    final first = await pool.acquire();
    await first.beginTransaction(isolation: MssqlIsolationLevel.serializable);
    await first.execute('SET LOCK_TIMEOUT 4321; SET XACT_ABORT ON; SET DATEFORMAT dmy;');
    await first.execute('SET CONTEXT_INFO 0x0102;');
    await first.execute(
      "EXEC sp_set_session_context @key = N'mssql_dart', @value = N'borrowed';",
    );
    await first.execute(
      'CREATE TABLE #iso_write (n int NOT NULL); INSERT INTO #iso_write VALUES (1);',
    );
    await first.execute("EXECUTE AS USER = 'mssql_dart_borrower';");
    await first.commitTransaction();
    final dirty = await _sessionSnapshot(first);
    expect(dirty['isolation'], 4);
    expect(dirty['lockTimeout'], 4321);
    expect(dirty['user'], 'mssql_dart_borrower');
    await pool.release(first);

    final next = await pool.acquire();
    try {
      final clean = await _sessionSnapshot(next);
      expect(clean['transactions'], 0);
      expect(clean['isolation'], 2);
      expect(clean['lockTimeout'], -1);
      expect(clean['xactAbort'], 0);
      expect(clean['dateFormat'], isNot('dmy'));
      expect(clean['context'], isNull);
      expect(clean['sessionContext'], isNull);
      expect(clean['user'], isNot('mssql_dart_borrower'));
    } finally {
      await pool.release(next);
    }
  });

  test('resetOnRelease false keeps isolation and impersonation after COMMIT',
      () async {
    if (!available) {
      markTestSkipped('SQL Server not available on :$_port');
      return;
    }
    final pool = MssqlPool(MssqlPoolConfig(
      host: _host,
      port: _port,
      user: _user,
      password: _password,
      database: 'tempdb',
      encrypt: false,
      trustServerCertificate: true,
      min: 0,
      max: 1,
      validateOnAcquire: false,
      resetOnRelease: false,
    ));
    await pool.open();
    addTearDown(pool.close);
    await _ensureBorrower(pool);

    final first = await pool.acquire();
    await first.beginTransaction(isolation: MssqlIsolationLevel.serializable);
    await first.execute("EXECUTE AS USER = 'mssql_dart_borrower';");
    await first.commitTransaction();
    await pool.release(first);

    final next = await pool.acquire();
    try {
      expect(identical(first, next), isTrue);
      final kept = await _sessionSnapshot(next);
      expect(kept['isolation'], 4);
      expect(kept['user'], 'mssql_dart_borrower');
      expect(kept['transactions'], 0);
    } finally {
      await next.execute('REVERT;');
      await pool.release(next);
    }
  });

  test('killed COMMIT leaves the next borrower with a clean session', () async {
    if (!available) {
      markTestSkipped('SQL Server not available on :$_port');
      return;
    }
    final pool = MssqlPool(MssqlPoolConfig(
      host: _host,
      port: _port,
      user: _user,
      password: _password,
      database: 'tempdb',
      encrypt: false,
      trustServerCertificate: true,
      min: 0,
      max: 1,
      resetOnRelease: true,
    ));
    await pool.open();
    addTearDown(pool.close);
    await _ensureBorrower(pool);

    final admin = await MssqlConnection.connect(
      host: _host,
      port: _port,
      user: _user,
      password: _password,
      database: 'tempdb',
      encrypt: false,
      trustServerCertificate: true,
    );
    addTearDown(admin.close);
    final table = 'mssql_dart_iso_${DateTime.now().microsecondsSinceEpoch}';
    await admin.execute(
      'CREATE TABLE dbo.[$table] (n int NOT NULL); INSERT INTO dbo.[$table] VALUES (0)',
    );
    addTearDown(() => admin.execute('DROP TABLE IF EXISTS dbo.[$table]'));

    final first = await pool.acquire();
    final spid = (await first.query('SELECT @@SPID AS id'))[0]['id'] as int;
    await first.beginTransaction(isolation: MssqlIsolationLevel.serializable);
    await first.execute(
      'SET LOCK_TIMEOUT 4321; SET XACT_ABORT ON; SET DATEFORMAT dmy;',
    );
    await first.execute('SET CONTEXT_INFO 0x0102;');
    await first.execute(
      "EXEC sp_set_session_context @key = N'mssql_dart', @value = N'borrowed';",
    );
    await first.execute('UPDATE dbo.[$table] SET n = n + 1');
    await first.execute("EXECUTE AS USER = 'mssql_dart_borrower';");
    final killed = first.execute(
      "WAITFOR DELAY '00:00:02'; COMMIT TRANSACTION;",
    );
    final failed = expectLater(
      killed,
      throwsA(anyOf(isA<MssqlException>(), isA<StateError>())),
    );
    await admin.execute('KILL $spid');
    await failed;
    final before = pool.stats.destroyed;
    await pool.release(first);
    expect(pool.stats.destroyed, greaterThan(before));

    final next = await pool.acquire();
    try {
      final clean = await _sessionSnapshot(next);
      expect(clean['transactions'], 0);
      expect(clean['isolation'], 2);
      expect(clean['lockTimeout'], -1);
      expect(clean['xactAbort'], 0);
      expect(clean['dateFormat'], isNot('dmy'));
      expect(clean['context'], isNull);
      expect(clean['sessionContext'], isNull);
      expect(clean['user'], isNot('mssql_dart_borrower'));
      final n = await next.query('SELECT n FROM dbo.[$table]');
      expect(n[0]['n'], anyOf(0, 1));
    } finally {
      await pool.release(next);
    }
  }, timeout: const Timeout(Duration(minutes: 1)));
}

Future<void> _ensureBorrower(MssqlPool pool) async {
  final admin = await pool.acquire();
  try {
    await admin.execute('''
IF DATABASE_PRINCIPAL_ID(N'mssql_dart_borrower') IS NULL
  CREATE USER mssql_dart_borrower WITHOUT LOGIN;
''');
  } finally {
    await pool.release(admin);
  }
}

Future<MssqlRow> _sessionSnapshot(MssqlConnection conn) async {
  final rows = await conn.query('''
SELECT
  @@TRANCOUNT AS transactions,
  transaction_isolation_level AS isolation,
  @@LOCK_TIMEOUT AS lockTimeout,
  CASE WHEN (@@OPTIONS & 16384) = 16384 THEN 1 ELSE 0 END AS xactAbort,
  date_format AS dateFormat,
  CONTEXT_INFO() AS context,
  SESSION_CONTEXT(N'mssql_dart') AS sessionContext,
  USER_NAME() AS [user]
FROM sys.dm_exec_sessions
WHERE session_id = @@SPID
''');
  return rows.first;
}
