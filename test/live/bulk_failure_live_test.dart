import 'dart:io';

import 'package:mssql/mssql.dart';
import 'package:test/test.dart';

import 'live_test_config.dart';
import 'live_test_gate.dart';

final _config = liveTestConfig;
final _bulkRowCount = int.tryParse(
      Platform.environment['MSSQL_BULK_STRESS_ROWS'] ?? '10000',
    ) ??
    10000;

Future<MssqlConnection> _open({bool encrypt = false}) =>
    MssqlConnection.connect(
      host: _config.host,
      port: _config.port,
      user: _config.user,
      password: _config.password,
      database: 'tempdb',
      encrypt: encrypt,
      trustServerCertificate: true,
      timeout: const Duration(seconds: 10),
    );

List<List<Object?>> _rows(int count) => List.generate(
      count,
      (index) => <Object?>[index, 'row-$index-${'x' * (index % 97)}'],
      growable: false,
    );

Future<void> _expectHealthy(MssqlConnection connection) async {
  expect((await connection.query('SELECT 1 AS ok'))[0]['ok'], 1);
}

void main() {
  if (!beginLiveSuite()) return;

  group('live Bulk Load scale and failure recovery', () {
    for (final encrypt in [false, true]) {
      test(
        '$_bulkRowCount rows cross packet boundaries '
        '(${encrypt ? 'TLS' : 'TCP'})',
        () async {
          final conn = await _open(encrypt: encrypt);
          addTearDown(conn.close);
          await conn.execute('''
CREATE TABLE #bulk_scale (
  id bigint NOT NULL PRIMARY KEY,
  value nvarchar(4000) NOT NULL
)
''');

          final inserted = await conn.bulkInsert(
            '#bulk_scale',
            const ['id', 'value'],
            _rows(_bulkRowCount),
          );
          expect(inserted, _bulkRowCount);
          final result = await conn.query(
            'SELECT COUNT(*) AS count, SUM(id) AS total FROM #bulk_scale',
          );
          expect(result[0]['count'], _bulkRowCount);
          expect(
            result[0]['total'],
            _bulkRowCount * (_bulkRowCount - 1) ~/ 2,
          );
        },
        timeout: const Timeout(Duration(minutes: 3)),
      );
    }

    test('duplicate key failure leaves connection reusable', () async {
      final conn = await _open();
      addTearDown(conn.close);
      await conn.execute(
        'CREATE TABLE #bulk_duplicate (id bigint NOT NULL PRIMARY KEY)',
      );

      await expectLater(
        conn.bulkInsert(
          '#bulk_duplicate',
          const ['id'],
          const [
            [1],
            [1],
            [2],
          ],
        ),
        throwsA(isA<MssqlException>()),
      );
      await _expectHealthy(conn);
    });

    test('missing destination leaves connection reusable', () async {
      final conn = await _open();
      addTearDown(conn.close);

      await expectLater(
        conn.bulkInsert(
          '#bulk_missing_destination',
          const ['id'],
          const [
            [1],
          ],
        ),
        throwsA(isA<MssqlException>()),
      );
      await _expectHealthy(conn);
    });

    test('local truncation is rejected before BCP and connection is reusable',
        () async {
      final conn = await _open();
      addTearDown(conn.close);
      await conn.execute(
        'CREATE TABLE #bulk_truncate (value nvarchar(3) NOT NULL)',
      );

      await expectLater(
        conn.bulkInsert(
          '#bulk_truncate',
          const ['value'],
          const [
            ['four'],
          ],
          columnTypes: const [
            BulkColumn(
              'value',
              BulkColumnType.nVarChar,
              nVarCharLength: 3,
              nullable: false,
            ),
          ],
        ),
        throwsArgumentError,
      );
      await _expectHealthy(conn);
    });

    test('local type conversion failure leaves connection reusable', () async {
      final conn = await _open();
      addTearDown(conn.close);
      await conn.execute(
        'CREATE TABLE #bulk_conversion (id bigint NOT NULL)',
      );

      await expectLater(
        conn.bulkInsert(
          '#bulk_conversion',
          const ['id'],
          const [
            ['not-an-integer'],
          ],
          columnTypes: const [
            BulkColumn('id', BulkColumnType.bigInt, nullable: false),
          ],
        ),
        throwsArgumentError,
      );
      await _expectHealthy(conn);
    });

    test('explicit rollback removes a successful Bulk Load', () async {
      final conn = await _open();
      addTearDown(conn.close);
      await conn.execute(
        'CREATE TABLE #bulk_rollback (id bigint NOT NULL PRIMARY KEY)',
      );

      await conn.beginTransaction();
      await conn.bulkInsert(
        '#bulk_rollback',
        const ['id'],
        List.generate(100, (index) => <Object?>[index]),
      );
      await conn.rollbackTransaction();

      expect(
        (await conn.query('SELECT COUNT(*) AS n FROM #bulk_rollback'))[0]['n'],
        0,
      );
    });

    test('pool reuses a session after server-side Bulk Load failure', () async {
      final pool = MssqlPool(
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
        ),
      );
      addTearDown(pool.close);

      final first = await pool.acquire();
      await first.execute(
        'CREATE TABLE #bulk_pool_failure (id bigint NOT NULL PRIMARY KEY)',
      );
      await expectLater(
        first.bulkInsert(
          '#bulk_pool_failure',
          const ['id'],
          const [
            [1],
            [1],
          ],
        ),
        throwsA(isA<MssqlException>()),
      );
      await pool.release(first);

      final next = await pool.acquire();
      try {
        await _expectHealthy(next);
      } finally {
        await pool.release(next);
      }
    });
  });
}
