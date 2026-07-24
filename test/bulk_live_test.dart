import 'package:mssql/mssql.dart';
import 'package:test/test.dart';

/// Live TDS bulk insert against Docker SQL Edge.
///
/// Requires `dart-mssql` on 127.0.0.1:14330. Skips when unreachable.

const _host = '127.0.0.1';
const _port = 14330;
const _user = 'sa';
const _password = 'Knex_Test1!';

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
  late bool available;

  setUpAll(() async {
    available = await sqlUp();
  });

  test('bulkInsert loads rows into a temp table', () async {
    if (!available) {
      markTestSkipped('SQL Server not available on :$_port');
      return;
    }

    final conn = await MssqlConnection.connect(
      host: _host,
      port: _port,
      user: _user,
      password: _password,
      database: 'tempdb',
      encrypt: false,
      trustServerCertificate: true,
    );
    addTearDown(conn.close);

    await conn.query('''
      IF OBJECT_ID('tempdb..#bulk_demo') IS NOT NULL DROP TABLE #bulk_demo;
      CREATE TABLE #bulk_demo (
        Id BIGINT NULL,
        Name NVARCHAR(100) NULL,
        Active BIT NULL,
        Amt FLOAT NULL,
        Ts DATETIME2(7) NULL
      );
    ''');

    final n = await conn.bulkInsert(
      '#bulk_demo',
      ['Id', 'Name', 'Active', 'Amt', 'Ts'],
      [
        [1, 'alpha', true, 1.25, DateTime.utc(2024, 6, 1, 12)],
        [2, 'beta', false, 3.5, DateTime.utc(2024, 6, 2, 13)],
        [null, null, null, null, null],
      ],
    );
    expect(n, greaterThanOrEqualTo(3));

    final rows = await conn.query(
      'SELECT Id, Name, Active, Amt FROM #bulk_demo ORDER BY '
      'CASE WHEN Id IS NULL THEN 1 ELSE 0 END, Id',
    );
    expect(rows.length, 3);
    expect(rows[0]['Id'], 1);
    expect(rows[0]['Name'], 'alpha');
    expect(rows[0]['Active'], isTrue);
    expect(rows[1]['Id'], 2);
    expect(rows[2]['Id'], isNull);
  });

  test('bulkInsert empty rows returns 0', () async {
    if (!available) {
      markTestSkipped('SQL Server not available on :$_port');
      return;
    }
    final conn = await MssqlConnection.connect(
      host: _host,
      port: _port,
      user: _user,
      password: _password,
      database: 'tempdb',
      encrypt: false,
      trustServerCertificate: true,
    );
    addTearDown(conn.close);
    final n = await conn.bulkInsert('#nope', ['Id'], []);
    expect(n, 0);
  });
}
