import 'package:mssql/mssql.dart';
import 'package:test/test.dart';

import 'live_test_config.dart';
import 'live_test_gate.dart';

final _config = liveTestConfig;

Future<MssqlConnection> _open() => _config.open(database: 'tempdb');

MssqlPool _pool() => MssqlPool(
      MssqlPoolConfig(
        host: _config.host,
        port: _config.port,
        user: _config.user,
        password: _config.password,
        database: 'tempdb',
        encrypt: false,
        trustServerCertificate: true,
        connectRetries: 0,
        min: 0,
        max: 1,
        resetOnRelease: true,
      ),
    );

String _tableName(String suffix) =>
    'mssql_dart_tx_${suffix}_${DateTime.now().microsecondsSinceEpoch}';

Future<void> _dropTable(String table) async {
  final admin = await _open();
  try {
    await admin.execute("DROP TABLE IF EXISTS tempdb.dbo.[$table]");
  } finally {
    await admin.close();
  }
}

void main() {
  if (!beginLiveSuite()) return;

  group('live transaction failure recovery', () {
    test('constraint violation can be rolled back and connection reused',
        () async {
      final conn = await _open();
      addTearDown(conn.close);
      await conn.execute('CREATE TABLE #tx_constraint (id int PRIMARY KEY)');

      await conn.beginTransaction();
      await conn.execute('INSERT INTO #tx_constraint VALUES (1)');
      await expectLater(
        conn.execute('INSERT INTO #tx_constraint VALUES (1)'),
        throwsA(isA<MssqlException>()),
      );
      await conn.rollbackTransaction();

      final state = await conn.query(
        'SELECT @@TRANCOUNT AS transactions, '
        '(SELECT COUNT(*) FROM #tx_constraint) AS rows',
      );
      expect(state[0]['transactions'], 0);
      expect(state[0]['rows'], 0);
    });

    test('syntax error inside transaction can be rolled back', () async {
      final conn = await _open();
      addTearDown(conn.close);

      await conn.beginTransaction();
      await expectLater(
        conn.execute('SELECT FROM'),
        throwsA(isA<MssqlException>()),
      );
      await conn.rollbackTransaction();
      expect((await conn.query('SELECT @@TRANCOUNT AS n'))[0]['n'], 0);
      expect((await conn.query('SELECT 1 AS ok'))[0]['ok'], 1);
    });

    test('XACT_ABORT reports 3998 and rolls back at the batch boundary',
        () async {
      final conn = await _open();
      addTearDown(conn.close);
      await conn.execute('CREATE TABLE #tx_doomed (id int PRIMARY KEY)');
      await conn.execute('INSERT INTO #tx_doomed VALUES (1)');
      await conn.execute('SET XACT_ABORT ON');

      await conn.beginTransaction();
      try {
        await conn.query('''
BEGIN TRY
  INSERT INTO #tx_doomed VALUES (1);
END TRY
BEGIN CATCH
  SELECT XACT_STATE() AS state, ERROR_NUMBER() AS error;
END CATCH
''');
        fail('Expected SQL Server to reject the uncommittable transaction.');
      } on MssqlException catch (error) {
        expect(error.errorCode, 3998);
      }
      await conn.execute('SET XACT_ABORT OFF');
      final state = await conn.query(
        'SELECT @@TRANCOUNT AS transactions, '
        '(SELECT COUNT(*) FROM #tx_doomed) AS rows',
      );
      expect(state[0]['transactions'], 0);
      expect(state[0]['rows'], 1);
    });

    test('pool reset rolls back an open transaction before handoff', () async {
      final table = _tableName('open');
      final pool = _pool();
      addTearDown(pool.close);
      addTearDown(() => _dropTable(table));

      final first = await pool.acquire();
      await first.execute(
        'CREATE TABLE tempdb.dbo.[$table] (id int NOT NULL PRIMARY KEY)',
      );
      await first.beginTransaction();
      await first.execute('INSERT INTO tempdb.dbo.[$table] VALUES (1)');
      await pool.release(first);

      final next = await pool.acquire();
      try {
        final state = await next.query(
          'SELECT @@TRANCOUNT AS transactions, '
          '(SELECT COUNT(*) FROM tempdb.dbo.[$table]) AS rows',
        );
        expect(state[0]['transactions'], 0);
        expect(state[0]['rows'], 0);
      } finally {
        await pool.release(next);
      }
    });

    test('pool reset cleans a failed XACT_ABORT session before handoff',
        () async {
      final table = _tableName('doomed');
      final pool = _pool();
      addTearDown(pool.close);
      addTearDown(() => _dropTable(table));

      final first = await pool.acquire();
      await first.execute(
        'CREATE TABLE tempdb.dbo.[$table] (id int NOT NULL PRIMARY KEY); '
        'INSERT INTO tempdb.dbo.[$table] VALUES (1); '
        'SET XACT_ABORT ON;',
      );
      await first.beginTransaction();
      try {
        await first.query('''
BEGIN TRY
  INSERT INTO tempdb.dbo.[$table] VALUES (1);
END TRY
BEGIN CATCH
  SELECT XACT_STATE() AS state, ERROR_NUMBER() AS error;
END CATCH
''');
        fail('Expected SQL Server to reject the uncommittable transaction.');
      } on MssqlException catch (error) {
        expect(error.errorCode, 3998);
      }
      await pool.release(first);

      final next = await pool.acquire();
      try {
        final state = await next.query(
          'SELECT @@TRANCOUNT AS transactions, '
          '(SELECT COUNT(*) FROM tempdb.dbo.[$table]) AS rows',
        );
        expect(state[0]['transactions'], 0);
        expect(state[0]['rows'], 1);
      } finally {
        await pool.release(next);
      }
    });
  });
}
