import 'package:mssql/mssql.dart';
import 'package:test/test.dart';

/// Live queryTimeout + appName against Docker SQL Edge (LAN-style SQL auth).
///
/// Requires `dart-mssql` on 127.0.0.1:14330. Skips when unreachable.

const _host = '127.0.0.1';
const _port = 14330;
const _user = 'sa';
const _password = 'Knex_Test1!';

Future<MssqlConnection?> tryOpen({
  Duration? queryTimeout,
  String appName = 'mssql-dart',
}) async {
  try {
    return await MssqlConnection.connect(
      host: _host,
      port: _port,
      user: _user,
      password: _password,
      database: 'master',
      encrypt: false,
      trustServerCertificate: true,
      appName: appName,
      queryTimeout: queryTimeout,
      timeout: const Duration(seconds: 8),
    ).timeout(const Duration(seconds: 8));
  } catch (_) {
    return null;
  }
}

void main() {
  late MssqlConnection conn;
  var available = false;

  setUpAll(() async {
    final c = await tryOpen(appName: 'dart-mssql-lan');
    if (c == null) {
      available = false;
      return;
    }
    conn = c;
    available = true;
  });

  tearDownAll(() async {
    if (available) await conn.close();
  });

  test('appName is visible on the session', () async {
    if (!available) {
      markTestSkipped('SQL Server not available on :$_port');
      return;
    }
    final r = await conn.query(
      'SELECT program_name AS p FROM sys.dm_exec_sessions WHERE session_id = @@SPID',
    );
    expect(r[0]['p'], equals('dart-mssql-lan'));
  });

  test('per-call query timeout cancels WAITFOR and reuses connection', () async {
    if (!available) {
      markTestSkipped('SQL Server not available on :$_port');
      return;
    }

    await expectLater(
      conn.query(
        "WAITFOR DELAY '00:00:15'; SELECT 1 AS v",
        const {},
        const Duration(milliseconds: 500),
      ),
      throwsA(isA<MssqlException>().having(
        (e) => e.message,
        'message',
        contains('Query timed out'),
      )),
    );

    expect(conn.isOpen, isTrue);
    final r = await conn.query('SELECT 31 AS n');
    expect(r[0]['n'], equals(31));
  });

  test('connection queryTimeout default applies', () async {
    if (!available) {
      markTestSkipped('SQL Server not available on :$_port');
      return;
    }

    final timed = await tryOpen(queryTimeout: const Duration(milliseconds: 500));
    if (timed == null) {
      markTestSkipped('SQL Server not available on :$_port');
      return;
    }
    addTearDown(timed.close);

    await expectLater(
      timed.query("WAITFOR DELAY '00:00:15'; SELECT 1 AS v"),
      throwsA(isA<MssqlException>().having(
        (e) => e.message,
        'message',
        contains('Query timed out'),
      )),
    );
    final r = await timed.query('SELECT 33 AS n');
    expect(r[0]['n'], equals(33));
  });
}
