import 'package:mssql/mssql.dart';
import 'package:test/test.dart';

import 'live_test_config.dart';
import 'live_test_gate.dart';

final _config = liveTestConfig;

Future<MssqlConnection> _open({required bool encrypt}) =>
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

void main() {
  if (!beginLiveSuite()) return;

  group('live cancellable Bulk Load', () {
    for (final encrypt in [false, true]) {
      test(
        'cancel after BCP starts keeps connection reusable '
        '(${encrypt ? 'TLS' : 'TCP'})',
        () async {
          final connection = await _open(encrypt: encrypt);
          addTearDown(connection.close);
          await connection.execute('''
CREATE TABLE #bulk_cancel (
  id bigint NOT NULL PRIMARY KEY,
  value nvarchar(4000) NOT NULL
)
''');

          final rows = List.generate(
            10000,
            (index) => <Object?>[index, 'row-$index-${'x' * 128}'],
            growable: false,
          );
          final operation = connection.startBulkInsert(
            '#bulk_cancel',
            const ['id', 'value'],
            rows,
            columnTypes: const [
              BulkColumn('id', BulkColumnType.bigInt, nullable: false),
              BulkColumn(
                'value',
                BulkColumnType.nVarChar,
                nullable: false,
              ),
            ],
          );
          final resultExpectation = expectLater(
            operation.result,
            throwsA(isA<MssqlOperationCancelledException>()),
          );

          expect(
            await operation.transferStarted.timeout(
              const Duration(seconds: 10),
            ),
            isTrue,
          );
          await Future.wait([
            operation.cancel(),
            operation.cancel(),
          ]).timeout(const Duration(seconds: 10));
          await resultExpectation;

          final count = await connection.query(
            'SELECT COUNT(*) AS count FROM #bulk_cancel',
          );
          expect(count[0]['count'], 0);
          expect((await connection.query('SELECT 1 AS ok'))[0]['ok'], 1);
        },
        timeout: const Timeout(Duration(minutes: 2)),
      );
    }
  });
}
