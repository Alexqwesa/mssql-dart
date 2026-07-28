import 'dart:io';

import 'package:mssql/mssql.dart';
import 'package:test/test.dart';

void main() {
  final enabled = Platform.environment['MSSQL_LIVE_TESTS'] == '1';
  final skipReason = enabled ? false : 'Set MSSQL_LIVE_TESTS=1';

  group('TLS alignment live regressions', () {
    test(
      'alignment does not change @@ROWCOUNT between requests',
      () async {
        final conn = await _connect();
        addTearDown(conn.close);

        await conn.execute('''
CREATE TABLE #tls_rowcount_test (
  id int NOT NULL PRIMARY KEY,
  value int NOT NULL
);
INSERT INTO #tls_rowcount_test(id, value) VALUES (1, 0);
''');

        for (var i = 0; i < 1200; i++) {
          final pad = _repeat('x', i % 251);
          await conn.execute('''
UPDATE #tls_rowcount_test
SET value = value + 1
WHERE id = 1;
-- $pad
''');

          final result = await conn.query('SELECT @@ROWCOUNT AS affected');
          expect(
            result.first['affected'],
            1,
            reason: 'An internal alignment SELECT/RPC ran before the '
                '@@ROWCOUNT query at iteration $i.',
          );
        }
      },
      skip: skipReason,
      timeout: const Timeout(Duration(minutes: 2)),
    );

    test(
      'multi-packet SQLBatch never receives an injected request in the middle',
      () async {
        final conn = await _connect();
        addTearDown(conn.close);

        for (var i = 0; i < 120; i++) {
          // First vary the ring position with a short request.
          final prefixPad = _repeat('p', i % 97);
          await conn.query('SELECT 1 AS n; -- $prefixPad');

          // This batch is larger than the usual 4096-byte TDS packet and must
          // be sent as one TDS message containing multiple packets.
          final payload = _repeat('z', 6000 + (i % 257));
          final result = await conn.query(
            "SELECT LEN(N'$payload') AS payload_length",
          );

          expect(result.first['payload_length'], payload.length);
          final health = await conn.query('SELECT 1 AS ok');
          expect(health.first['ok'], 1);
        }
      },
      skip: skipReason,
      timeout: const Timeout(Duration(minutes: 2)),
    );

    test(
      'timeout Attention never loses the active response or poisons connection',
      () async {
        final conn = await _connect();
        addTearDown(conn.close);

        for (var i = 0; i < 80; i++) {
          final pad = _repeat('a', i % 113);
          await conn.query('SELECT 1 AS n; -- $pad');

          await expectLater(
            conn.query(
              "WAITFOR DELAY '00:00:02'; SELECT 42 AS late_value",
              const {},
              const Duration(milliseconds: 80),
            ),
            throwsA(isA<MssqlException>()),
          );

          final health = await conn.query('SELECT 1 AS ok');
          expect(
            health.first['ok'],
            1,
            reason: 'Connection was desynchronized after Attention at '
                'iteration $i.',
          );
        }
      },
      skip: skipReason,
      timeout: const Timeout(Duration(minutes: 2)),
    );

    test(
      'Bulk Load never receives SQL/RPC alignment traffic inside BCP phase',
      () async {
        final conn = await _connect();
        addTearDown(conn.close);

        await conn.execute('''
CREATE TABLE #tls_bulk_test (
  id bigint NOT NULL,
  label nvarchar(4000) NOT NULL
);
''');

        var expectedRows = 0;
        for (var batch = 0; batch < 80; batch++) {
          final pad = _repeat('b', batch % 127);
          await conn.query('SELECT 1 AS n; -- $pad');

          final rows = <List<Object?>>[
            for (var i = 0; i < 12; i++)
              <Object?>[
                batch * 1000 + i,
                'row-$batch-$i-${_repeat('v', (batch + i) % 73)}',
              ],
          ];

          final inserted = await conn.bulkInsert(
            '#tls_bulk_test',
            const ['id', 'label'],
            rows,
          );
          expectedRows += rows.length;
          expect(inserted, rows.length);

          final health = await conn.query('SELECT 1 AS ok');
          expect(health.first['ok'], 1);
        }

        final count = await conn.query(
          'SELECT COUNT_BIG(*) AS total FROM #tls_bulk_test',
        );
        expect(count.first['total'], expectedRows);
      },
      skip: skipReason,
      timeout: const Timeout(Duration(minutes: 3)),
    );
  });
}

Future<MssqlConnection> _connect() {
  final env = Platform.environment;
  return MssqlConnection.connect(
    host: env['MSSQL_HOST'] ?? '127.0.0.1',
    port: int.parse(env['MSSQL_PORT'] ?? '14334'),
    user: env['MSSQL_USER'] ?? 'sa',
    password: env['MSSQL_PASSWORD'] ?? 'Strong_test_password_123!',
    database: env['MSSQL_DATABASE'] ?? 'master',
    encrypt: true,
    trustServerCertificate: true,
    timeout: const Duration(seconds: 15),
  );
}

String _repeat(String value, int count) => List.filled(count, value).join();
