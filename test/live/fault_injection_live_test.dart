import 'dart:async';
import 'dart:io';

import 'package:mssql/mssql.dart';
import 'package:test/test.dart';

import 'live_test_config.dart';
import 'live_test_gate.dart';

final _config = liveTestConfig;

Future<MssqlConnection> _open({String database = 'tempdb'}) => _config.open(
      database: database,
      appName: 'mssql-dart-fault',
    );

Future<({int spid, String connectionId})> _session(MssqlConnection conn) async {
  final row = (await conn.query(
    'SELECT @@SPID AS id, CONVERT(varchar(36), connection_id) AS conn '
    'FROM sys.dm_exec_connections WHERE session_id = @@SPID',
  ))[0];
  return (spid: row['id'] as int, connectionId: row['conn'] as String);
}

MssqlPool _pool() => MssqlPool(
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
        max: 1,
        resetOnRelease: true,
        appName: 'mssql-dart-fault',
      ),
    );

void main() {
  if (!beginLiveSuite()) return;

  group('live network faults', () {
    test('killed COMMIT is not replayed and the pool discards the session',
        () async {
      final admin = await _open();
      addTearDown(admin.close);
      final table =
          'mssql_dart_commit_${DateTime.now().microsecondsSinceEpoch}';
      await admin.execute(
        'CREATE TABLE dbo.[$table] (n int NOT NULL); INSERT INTO dbo.[$table] VALUES (0)',
      );
      addTearDown(() => admin.execute('DROP TABLE IF EXISTS dbo.[$table]'));

      final pool = _pool();
      addTearDown(pool.close);
      final conn = await pool.acquire();
      final session = await _session(conn);
      final killed = conn.query('''
BEGIN TRANSACTION;
UPDATE dbo.[$table] SET n = n + 1;
WAITFOR DELAY '00:00:02';
COMMIT TRANSACTION;
''');
      final failed = expectLater(
        killed,
        throwsA(anyOf(isA<MssqlException>(), isA<StateError>(), isA<SocketException>())),
      );
      await admin.execute('KILL ${session.spid}');
      await failed;
      expect(conn.isOpen, isFalse);
      final before = pool.stats.destroyed;
      await pool.release(conn);
      expect(pool.stats.destroyed, greaterThan(before));

      final next = await pool.acquire();
      try {
        final state = await next.query(
          'SELECT CONVERT(varchar(36), connection_id) AS conn, @@TRANCOUNT AS transactions, n '
          'FROM sys.dm_exec_connections CROSS JOIN dbo.[$table] WHERE session_id = @@SPID',
        );
        expect(state[0]['conn'], isNot(session.connectionId));
        expect(state[0]['transactions'], 0);
        expect(state[0]['n'], anyOf(0, 1));
      } finally {
        await pool.release(next);
      }
    }, timeout: const Timeout(Duration(minutes: 1)));

    test('killed streaming query finishes and the pool discards the session',
        () async {
      final pool = _pool();
      addTearDown(pool.close);
      final killer = await _open();
      addTearDown(killer.close);
      final conn = await pool.acquire();
      final session = await _session(conn);
      final reading = conn.queryStream(
        "WAITFOR DELAY '00:00:02'; SELECT 1 AS n",
      ).toList();
      final failed = expectLater(
        reading,
        throwsA(anyOf(isA<MssqlException>(), isA<StateError>(), isA<SocketException>())),
      );
      await killer.execute('KILL ${session.spid}');
      await failed;
      expect(conn.isOpen, isFalse);
      final before = pool.stats.destroyed;
      await pool.release(conn);
      expect(pool.stats.destroyed, greaterThan(before));
      final next = await pool.acquire();
      final nextSession = await _session(next);
      final transactions = await next.query('SELECT @@TRANCOUNT AS transactions');
      expect(nextSession.connectionId, isNot(session.connectionId));
      expect(transactions[0]['transactions'], 0);
      await pool.release(next);
    }, timeout: const Timeout(Duration(minutes: 1)));

    test('killed bulk load finishes without a second insert', () async {
      final admin = await _open();
      addTearDown(admin.close);
      final table = 'mssql_dart_bulk_${DateTime.now().microsecondsSinceEpoch}';
      await admin.execute('CREATE TABLE dbo.[$table] (id bigint NOT NULL)');
      addTearDown(() => admin.execute('DROP TABLE IF EXISTS dbo.[$table]'));

      final pool = _pool();
      addTearDown(pool.close);
      final conn = await pool.acquire();
      final session = await _session(conn);
      final insert = conn.bulkInsert(
        'dbo.[$table]',
        ['id'],
        List.generate(20000, (index) => [index]),
        columnTypes: const [
          BulkColumn('id', BulkColumnType.bigInt, nullable: false),
        ],
      );
      final failed = expectLater(
        insert,
        throwsA(anyOf(isA<MssqlException>(), isA<StateError>(), isA<SocketException>())),
      );
      await admin.execute('KILL ${session.spid}');
      await failed;
      expect(conn.isOpen, isFalse);
      final count = await admin.query('SELECT COUNT(*) AS n FROM dbo.[$table]');
      expect(count[0]['n'], lessThan(20000));
      final before = pool.stats.destroyed;
      await pool.release(conn);
      expect(pool.stats.destroyed, greaterThan(before));
      final next = await pool.acquire();
      final nextSession = await _session(next);
      final transactions = await next.query('SELECT @@TRANCOUNT AS transactions');
      expect(nextSession.connectionId, isNot(session.connectionId));
      expect(transactions[0]['transactions'], 0);
      await pool.release(next);
    }, timeout: const Timeout(Duration(minutes: 1)));

    test('cancel then a killed attention ack closes the connection', () async {
      final pool = _pool();
      addTearDown(pool.close);
      final killer = await _open();
      addTearDown(killer.close);
      final conn = await pool.acquire();
      final session = await _session(conn);
      final pending = conn.query("WAITFOR DELAY '00:00:05'");
      final failed = expectLater(
        pending,
        throwsA(anyOf(isA<MssqlException>(), isA<StateError>(), isA<SocketException>())),
      );
      // KILL first so the outcome cannot depend on whether the Attention ack
      // wins the race; the cancel then runs against a session already dying.
      await killer.execute('KILL ${session.spid}');
      final cancelDone = conn.cancel().then<void>((_) {}, onError: (_) {});
      await failed;
      await cancelDone;
      expect(conn.isOpen, isFalse);
      final before = pool.stats.destroyed;
      await pool.release(conn);
      expect(pool.stats.destroyed, greaterThan(before));
      final next = await pool.acquire();
      final nextSession = await _session(next);
      final transactions = await next.query('SELECT @@TRANCOUNT AS transactions');
      expect(nextSession.connectionId, isNot(session.connectionId));
      expect(transactions[0]['transactions'], 0);
      await pool.release(next);
    }, timeout: const Timeout(Duration(minutes: 1)));
  });
}
