import 'dart:async';

import 'package:mssql/mssql.dart';
import 'package:test/test.dart';

import 'live_test_config.dart';
import 'live_test_gate.dart';

/// Deeper pooled session-isolation coverage.
///
/// `session_db_live_test.dart` covers database switches, `#temp` tables,
/// isolation level, and the common SET options. These cases cover the session
/// state that survives `COMMIT` and is only cleared by TDS RESETCONNECTION:
/// locks, `ROWCOUNT`, the full `@@OPTIONS` bitmap, stacked impersonation,
/// session application locks, cursors, and prepared handles.
final _config = liveTestConfig;

const _borrower = 'mssql_dart_iso_borrower';
const _innerBorrower = 'mssql_dart_iso_inner';

Future<MssqlConnection> _open({String database = 'tempdb'}) => _config.open(
      database: database,
      appName: 'mssql-dart-isolation',
    );

MssqlPool _pool({int max = 1, bool resetOnRelease = true}) => MssqlPool(
      MssqlPoolConfig(
        host: _config.host,
        port: _config.port,
        user: _config.user,
        password: _config.password,
        database: 'tempdb',
        encrypt: _config.encrypt,
        trustServerCertificate: _config.trustServerCertificate,
        connectRetries: 0,
        min: 0,
        max: max,
        resetOnRelease: resetOnRelease,
        appName: 'mssql-dart-isolation',
      ),
    );

/// Creates the impersonation targets, and lets the outer one impersonate the
/// inner one so a nested `EXECUTE AS` is permitted.
Future<void> _ensureBorrower(MssqlConnection conn) async {
  await conn.execute('''
IF DATABASE_PRINCIPAL_ID(N'$_borrower') IS NULL
  CREATE USER $_borrower WITHOUT LOGIN;
IF DATABASE_PRINCIPAL_ID(N'$_innerBorrower') IS NULL
  CREATE USER $_innerBorrower WITHOUT LOGIN;
''');
  await conn.execute(
    'GRANT IMPERSONATE ON USER::$_innerBorrower TO $_borrower;',
  );
}

String _table(String kind) =>
    'mssql_dart_${kind}_${DateTime.now().microsecondsSinceEpoch}';

void main() {
  if (!beginLiveSuite()) return;

  group('pooled session isolation', () {
    test('a killed COMMIT releases its locks for the next writer', () async {
      final admin = await _open();
      addTearDown(admin.close);
      final table = _table('locks');
      await admin.execute(
        'CREATE TABLE dbo.[$table] (id int PRIMARY KEY, n int NOT NULL); '
        'INSERT INTO dbo.[$table] VALUES (1, 0)',
      );
      addTearDown(() => admin.execute('DROP TABLE IF EXISTS dbo.[$table]'));

      final pool = _pool();
      addTearDown(pool.close);
      final conn = await pool.acquire();
      final spid = (await conn.query('SELECT @@SPID AS id'))[0]['id'] as int;
      await conn.beginTransaction();
      await conn.execute('UPDATE dbo.[$table] SET n = 1');

      // The write holds an exclusive key lock that only transaction cleanup
      // releases, so a second session cannot touch the row yet.
      await admin.execute('SET LOCK_TIMEOUT 500');
      await expectLater(
        admin.execute('UPDATE dbo.[$table] SET n = 99'),
        throwsA(isA<MssqlException>()),
      );

      final killed = conn.execute(
        "WAITFOR DELAY '00:00:02'; COMMIT TRANSACTION;",
      );
      final failed = expectLater(
        killed,
        throwsA(anyOf(isA<MssqlException>(), isA<StateError>())),
      );
      await admin.execute('KILL $spid');
      await failed;
      await pool.release(conn);

      // After the rollback, no lock from that session may remain.
      final locks = await admin.query(
        'SELECT COUNT(*) AS n FROM sys.dm_tran_locks WHERE request_session_id = @spid',
        {'spid': spid},
      );
      expect(locks[0]['n'], 0);
      await admin.execute('SET LOCK_TIMEOUT 2000');
      await admin.execute('UPDATE dbo.[$table] SET n = 99');
      final value = await admin.query('SELECT n FROM dbo.[$table]');
      expect(value[0]['n'], 99);
    }, timeout: const Timeout(Duration(minutes: 1)));

    test('ROWCOUNT and TEXTSIZE do not truncate the next borrower', () async {
      final admin = await _open();
      addTearDown(admin.close);
      final table = _table('rowcount');
      await admin.execute(
        'CREATE TABLE dbo.[$table] (n int NOT NULL); '
        'INSERT INTO dbo.[$table] VALUES (1), (2), (3)',
      );
      addTearDown(() => admin.execute('DROP TABLE IF EXISTS dbo.[$table]'));

      final pool = _pool();
      addTearDown(pool.close);
      final first = await pool.acquire();
      await first.beginTransaction();
      await first.execute('SET ROWCOUNT 1; SET TEXTSIZE 64;');
      await first.commitTransaction();
      final truncated = await first.query('SELECT n FROM dbo.[$table]');
      expect(truncated.length, 1, reason: 'ROWCOUNT applies to the borrower');
      await pool.release(first);

      final next = await pool.acquire();
      try {
        final rows = await next.query('SELECT n FROM dbo.[$table]');
        expect(rows.length, 3);
        final textSize = await next.query('SELECT @@TEXTSIZE AS size');
        expect(textSize[0]['size'], isNot(64));
      } finally {
        await pool.release(next);
      }
    }, timeout: const Timeout(Duration(minutes: 1)));

    test('the whole @@OPTIONS bitmap returns to the login default', () async {
      final reference = await _open();
      addTearDown(reference.close);
      final expected =
          (await reference.query('SELECT @@OPTIONS AS options'))[0]['options'];

      final pool = _pool();
      addTearDown(pool.close);
      final first = await pool.acquire();
      await first.beginTransaction();
      await first.execute('''
SET ANSI_NULLS OFF;
SET ANSI_PADDING OFF;
SET ANSI_WARNINGS OFF;
SET CONCAT_NULL_YIELDS_NULL OFF;
SET QUOTED_IDENTIFIER OFF;
SET ARITHABORT ON;
SET NOCOUNT ON;
SET XACT_ABORT ON;
''');
      await first.commitTransaction();
      final dirty = await first.query('SELECT @@OPTIONS AS options');
      expect(dirty[0]['options'], isNot(expected));
      await pool.release(first);

      final next = await pool.acquire();
      try {
        final clean = await next.query('SELECT @@OPTIONS AS options');
        expect(clean[0]['options'], expected);
      } finally {
        await pool.release(next);
      }
    }, timeout: const Timeout(Duration(minutes: 1)));

    test('stacked impersonation is unwound for the next borrower', () async {
      final pool = _pool();
      addTearDown(pool.close);
      final setup = await pool.acquire();
      await _ensureBorrower(setup);
      final loginUser = (await setup.query('SELECT USER_NAME() AS u'))[0]['u'];
      await pool.release(setup);

      final first = await pool.acquire();
      await first.beginTransaction();
      await first.execute("EXECUTE AS USER = '$_borrower';");
      await first.execute("EXECUTE AS USER = '$_innerBorrower';");
      await first.commitTransaction();
      final stacked = await first.query('SELECT USER_NAME() AS u');
      expect(stacked[0]['u'], _innerBorrower);
      await pool.release(first);

      final next = await pool.acquire();
      try {
        // One REVERT would only unwind to the borrower; the reset must unwind
        // the whole stack back to the login principal.
        final clean = await next.query(
          'SELECT USER_NAME() AS u, ORIGINAL_LOGIN() AS original',
        );
        expect(clean[0]['u'], loginUser);
        expect(clean[0]['u'], isNot(_innerBorrower));
        expect(clean[0]['u'], isNot(_borrower));
      } finally {
        await pool.release(next);
      }
    }, timeout: const Timeout(Duration(minutes: 1)));

    test('a session application lock is released on release', () async {
      final pool = _pool();
      addTearDown(pool.close);
      final lockName = 'mssql_dart_${DateTime.now().microsecondsSinceEpoch}';

      final first = await pool.acquire();
      await first.beginTransaction();
      final taken = await first.query(
        "DECLARE @r int; "
        "EXEC @r = sp_getapplock @Resource = @name, @LockMode = 'Exclusive', "
        "@LockOwner = 'Session', @LockTimeout = 1000; SELECT @r AS result",
        {'name': lockName},
      );
      expect(taken[0]['result'], anyOf(0, 1));
      await first.commitTransaction();

      // COMMIT does not drop a session-owned application lock.
      final stillHeld = await first.query(
        'SELECT APPLOCK_MODE(N\'public\', @name, N\'Session\') AS mode',
        {'name': lockName},
      );
      expect(stillHeld[0]['mode'], 'Exclusive');
      await pool.release(first);

      final next = await pool.acquire();
      try {
        final retaken = await next.query(
          "DECLARE @r int; "
          "EXEC @r = sp_getapplock @Resource = @name, @LockMode = 'Exclusive', "
          "@LockOwner = 'Session', @LockTimeout = 2000; SELECT @r AS result",
          {'name': lockName},
        );
        expect(retaken[0]['result'], anyOf(0, 1));
        await next.execute(
          "EXEC sp_releaseapplock @Resource = @name, @LockOwner = 'Session'",
          {'name': lockName},
        );
      } finally {
        await pool.release(next);
      }
    }, timeout: const Timeout(Duration(minutes: 1)));

    test('open cursors and prepared handles do not survive the reset',
        () async {
      final pool = _pool();
      addTearDown(pool.close);
      final first = await pool.acquire();
      await first.beginTransaction();
      // A LOCAL cursor is deallocated when its batch ends, so this uses a
      // GLOBAL cursor, which stays open for the life of the session.
      await first.execute('''
DECLARE cur_probe CURSOR GLOBAL FOR SELECT 1 AS n;
OPEN cur_probe;
''');
      // sp_prepare emits its own result set, so the handle is in the last one.
      final handleSets = await first.queryMultiple(
        "DECLARE @h int; EXEC sp_prepare @h OUTPUT, NULL, N'SELECT 1 AS n'; "
        'SELECT @h AS handle',
      );
      final prepared = handleSets.all.last[0]['handle'] as int;
      await first.commitTransaction();

      final openCursors = await first.query(
        'SELECT COUNT(*) AS n FROM sys.dm_exec_cursors(@@SPID)',
      );
      expect(openCursors[0]['n'], greaterThan(0));
      await pool.release(first);

      final next = await pool.acquire();
      try {
        final cursors = await next.query(
          'SELECT COUNT(*) AS n FROM sys.dm_exec_cursors(@@SPID)',
        );
        expect(cursors[0]['n'], 0);
        await expectLater(
          next.query('EXEC sp_execute @handle', {'handle': prepared}),
          throwsA(isA<MssqlException>()),
        );
      } finally {
        await pool.release(next);
      }
    }, timeout: const Timeout(Duration(minutes: 1)));

    test('deadlock priority and language return to defaults', () async {
      final reference = await _open();
      addTearDown(reference.close);
      final defaultLanguage = (await reference.query(
        'SELECT language AS lang FROM sys.dm_exec_sessions WHERE session_id = @@SPID',
      ))[0]['lang'];

      final pool = _pool();
      addTearDown(pool.close);
      final first = await pool.acquire();
      await first.beginTransaction();
      await first.execute('SET DEADLOCK_PRIORITY HIGH; SET LANGUAGE French;');
      await first.commitTransaction();
      final dirty = await first.query('''
SELECT deadlock_priority AS priority, language AS lang
FROM sys.dm_exec_sessions WHERE session_id = @@SPID
''');
      expect(dirty[0]['priority'], 5);
      expect(dirty[0]['lang'], isNot(defaultLanguage));
      await pool.release(first);

      final next = await pool.acquire();
      try {
        final clean = await next.query('''
SELECT deadlock_priority AS priority, language AS lang
FROM sys.dm_exec_sessions WHERE session_id = @@SPID
''');
        expect(clean[0]['priority'], 0);
        expect(clean[0]['lang'], defaultLanguage);
      } finally {
        await pool.release(next);
      }
    }, timeout: const Timeout(Duration(minutes: 1)));

    test('concurrent borrowers do not observe each other\'s session state',
        () async {
      final pool = _pool(max: 4);
      addTearDown(pool.close);
      final setup = await pool.acquire();
      await _ensureBorrower(setup);
      await pool.release(setup);

      // Each worker dirties a different setting, then re-reads its own value.
      // A reset or routing bug shows up as one worker seeing another's value.
      Future<void> worker(int index) async {
        for (var round = 0; round < 6; round++) {
          final conn = await pool.acquire();
          try {
            final expectedLockTimeout = 1000 + index;
            await conn.execute('SET LOCK_TIMEOUT $expectedLockTimeout;');
            await conn.execute(
              'EXEC sp_set_session_context @key = N\'worker\', @value = @value;',
              {'value': 'worker-$index'},
            );
            await conn.beginTransaction(
              isolation: index.isEven
                  ? MssqlIsolationLevel.serializable
                  : MssqlIsolationLevel.repeatableRead,
            );
            await conn.execute('SELECT @n', {'n': index});
            await conn.commitTransaction();
            final state = await conn.query('''
SELECT @@LOCK_TIMEOUT AS lockTimeout,
       CONVERT(nvarchar(32), SESSION_CONTEXT(N'worker')) AS worker,
       transaction_isolation_level AS isolation
FROM sys.dm_exec_sessions WHERE session_id = @@SPID
''');
            expect(state[0]['lockTimeout'], expectedLockTimeout);
            expect(state[0]['worker'], 'worker-$index');
            expect(state[0]['isolation'], index.isEven ? 4 : 3);
          } finally {
            await pool.release(conn);
          }
        }
      }

      await Future.wait(List.generate(4, worker));
      expect(pool.stats.total, lessThanOrEqualTo(4));
      expect(pool.stats.inUse, 0);

      final after = await pool.acquire();
      try {
        final clean = await after.query('''
SELECT @@LOCK_TIMEOUT AS lockTimeout,
       SESSION_CONTEXT(N'worker') AS worker,
       transaction_isolation_level AS isolation
FROM sys.dm_exec_sessions WHERE session_id = @@SPID
''');
        expect(clean[0]['lockTimeout'], -1);
        expect(clean[0]['worker'], isNull);
        expect(clean[0]['isolation'], 2);
      } finally {
        await pool.release(after);
      }
    }, timeout: const Timeout(Duration(minutes: 2)));

    test('repeated dirty borrows do not accumulate tempdb objects', () async {
      final admin = await _open();
      addTearDown(admin.close);
      Future<int> tempObjectCount() async {
        final rows = await admin.query(
          "SELECT COUNT(*) AS n FROM tempdb.sys.objects WHERE name LIKE '#%'",
        );
        return rows[0]['n'] as int;
      }

      final pool = _pool();
      addTearDown(pool.close);
      // Warm the pool so the baseline excludes first-connection objects.
      final warm = await pool.acquire();
      await pool.release(warm);
      final baseline = await tempObjectCount();

      for (var cycle = 0; cycle < 50; cycle++) {
        final conn = await pool.acquire();
        try {
          await conn.execute(
            'CREATE TABLE #leak_probe (n int NOT NULL); '
            'INSERT INTO #leak_probe VALUES ($cycle);',
          );
          await conn.execute('SET LOCK_TIMEOUT 1234;');
        } finally {
          await pool.release(conn);
        }
      }

      final after = await tempObjectCount();
      expect(after, lessThanOrEqualTo(baseline));
      expect(pool.stats.total, lessThanOrEqualTo(1));
    }, timeout: const Timeout(Duration(minutes: 2)));
  });
}
