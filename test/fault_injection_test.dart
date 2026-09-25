import 'package:mssql/mssql.dart';
import 'package:test/test.dart';

import 'helpers/scripted_tds_server.dart';

Future<MssqlConnection> _connect(
  ScriptedTdsServer server, {
  Duration timeout = const Duration(seconds: 2),
  Duration? queryTimeout = const Duration(milliseconds: 400),
}) {
  return MssqlConnection.connect(
    host: '127.0.0.1',
    port: server.port,
    user: 'sa',
    password: 'Secret1',
    database: 'master',
    encrypt: false,
    connectRetries: 0,
    timeout: timeout,
    queryTimeout: queryTimeout,
    keepAlive: Duration.zero,
  );
}

void main() {
  group('offline network faults', () {
    test('login drop fails before a session exists', () async {
      final server = await ScriptedTdsServer.bind(ScriptedFault.loginDrop);
      addTearDown(server.close);
      await expectLater(
        _connect(server),
        throwsA(isA<MssqlException>()),
      );
      expect(server.sqlTexts, isEmpty);
    });

    test('login stall completes within the connect deadline', () async {
      final server = await ScriptedTdsServer.bind(ScriptedFault.loginStall);
      addTearDown(server.close);
      await expectLater(
        _connect(server, timeout: const Duration(milliseconds: 400)),
        throwsA(
          isA<MssqlException>().having(
            (error) => error.message,
            'message',
            contains('Login timed out'),
          ),
        ),
      ).timeout(const Duration(seconds: 3));
    });

    test('dropping after the first row closes the connection', () async {
      final server =
          await ScriptedTdsServer.bind(ScriptedFault.afterFirstRowDrop);
      addTearDown(server.close);
      final conn = await _connect(server);
      addTearDown(conn.close);
      await expectLater(
        conn.query('SELECT 1'),
        throwsA(anyOf(isA<MssqlException>(), isA<StateError>())),
      );
      expect(conn.isOpen, isFalse);
      expect(
        () => conn.execute('SELECT 1'),
        throwsA(isA<StateError>()),
      );
      expect(server.sqlTexts.where((sql) => sql.contains('SELECT 1')).length,
          1);
    });

    test('stalling after the first row closes the connection', () async {
      final server =
          await ScriptedTdsServer.bind(ScriptedFault.afterFirstRowStall);
      addTearDown(server.close);
      final conn = await _connect(server);
      addTearDown(conn.close);
      await expectLater(
        conn.query('SELECT 1'),
        throwsA(anyOf(isA<MssqlException>(), isA<StateError>())),
      ).timeout(const Duration(seconds: 15));
      expect(conn.isOpen, isFalse);
      expect(
        () => conn.execute('SELECT 1'),
        throwsA(isA<StateError>()),
      );
      expect(server.sqlTexts, ['SELECT 1']);
    });

    test('dropping a bulk packet does not replay the load', () async {
      final server = await ScriptedTdsServer.bind(ScriptedFault.bulkDrop);
      addTearDown(server.close);
      final conn = await _connect(server);
      addTearDown(conn.close);
      await expectLater(
        conn.bulkInsert(
          'dbo.Items',
          ['Id'],
          [
            [1],
          ],
          columnTypes: const [BulkColumn('Id', BulkColumnType.bigInt, nullable: true)],
        ),
        throwsA(anyOf(isA<MssqlException>(), isA<StateError>())),
      );
      expect(conn.isOpen, isFalse);
      expect(server.bulkPackets, 1);
      expect(
        server.sqlTexts.where((sql) => sql.startsWith('INSERT BULK')).length,
        1,
      );
    });

    test('stalling a bulk packet closes the connection without replay',
        () async {
      final server = await ScriptedTdsServer.bind(ScriptedFault.bulkStall);
      addTearDown(server.close);
      final conn = await _connect(server);
      addTearDown(conn.close);
      await expectLater(
        conn.bulkInsert(
          'dbo.Items',
          ['Id'],
          [
            [1],
          ],
          columnTypes: const [
            BulkColumn('Id', BulkColumnType.bigInt, nullable: true),
          ],
        ),
        throwsA(isA<MssqlException>()),
      ).timeout(const Duration(seconds: 15));
      expect(conn.isOpen, isFalse);
      expect(server.bulkPackets, 1);
      expect(
        server.sqlTexts.where((sql) => sql.startsWith('INSERT BULK')).length,
        1,
      );
    });

    test('dropping during attention closes the connection', () async {
      final server = await ScriptedTdsServer.bind(ScriptedFault.attentionDrop);
      addTearDown(server.close);
      final conn = await _connect(
        server,
        queryTimeout: const Duration(milliseconds: 200),
      );
      addTearDown(conn.close);
      await expectLater(
        conn.query('WAITFOR DELAY'),
        throwsA(anyOf(isA<MssqlException>(), isA<StateError>())),
      ).timeout(const Duration(seconds: 15));
      expect(conn.isOpen, isFalse);
      expect(server.attentionPackets, 1);
      expect(server.sqlTexts, ['WAITFOR DELAY']);
    });

    test('stalling during attention closes the connection', () async {
      final server = await ScriptedTdsServer.bind(ScriptedFault.attentionStall);
      addTearDown(server.close);
      final conn = await _connect(
        server,
        queryTimeout: const Duration(milliseconds: 200),
      );
      addTearDown(conn.close);
      await expectLater(
        conn.query('WAITFOR DELAY'),
        throwsA(isA<MssqlException>()),
      ).timeout(const Duration(seconds: 15));
      expect(conn.isOpen, isFalse);
      expect(
        () => conn.execute('SELECT 1'),
        throwsA(isA<StateError>()),
      );
      expect(server.attentionPackets, 1);
      expect(server.sqlTexts, ['WAITFOR DELAY']);
    });

    test('dropping during COMMIT does not replay the commit', () async {
      final server = await ScriptedTdsServer.bind(ScriptedFault.commitDrop);
      addTearDown(server.close);
      final conn = await _connect(server);
      addTearDown(conn.close);
      await expectLater(
        conn.transaction((_) async {}),
        throwsA(anyOf(isA<MssqlException>(), isA<StateError>())),
      );
      expect(conn.isOpen, isFalse);
      expect(server.commitPackets, 1);
    });

    test('stalling during COMMIT closes the connection without replay',
        () async {
      final server = await ScriptedTdsServer.bind(ScriptedFault.commitStall);
      addTearDown(server.close);
      final conn = await _connect(server);
      addTearDown(conn.close);
      await conn.beginTransaction();
      await expectLater(
        conn.commitTransaction(),
        throwsA(isA<MssqlException>()),
      ).timeout(const Duration(seconds: 15));
      expect(conn.isOpen, isFalse);
      expect(
        () => conn.execute('SELECT 1'),
        throwsA(isA<StateError>()),
      );
      expect(server.commitPackets, 1);
    });
  });
}
