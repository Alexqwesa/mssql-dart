import 'package:mssql/mssql.dart';
import 'package:test/test.dart';

/// Live INFO / PRINT diagnostics against Docker SQL Edge.
///
/// Skips when 127.0.0.1:14330 is unreachable.

const _host = '127.0.0.1';
const _port = 14330;
const _user = 'sa';
const _password = 'Knex_Test1!';

Future<MssqlConnection?> tryOpen() async {
  try {
    return await MssqlConnection.connect(
      host: _host,
      port: _port,
      user: _user,
      password: _password,
      database: 'master',
      encrypt: false,
      trustServerCertificate: true,
      timeout: const Duration(seconds: 5),
    );
  } catch (_) {
    return null;
  }
}

void main() {
  late MssqlConnection conn;
  var available = false;

  setUpAll(() async {
    final c = await tryOpen();
    if (c == null) return;
    conn = c;
    available = true;
  });

  tearDownAll(() async {
    if (available) await conn.close();
  });

  test('PRINT delivers onInfoMessage', () async {
    if (!available) {
      markTestSkipped('SQL Server not available on :$_port');
      return;
    }

    final infos = <MssqlInfoMessage>[];
    conn.onInfoMessage = infos.add;
    await conn.execute("PRINT N'hello-from-print'");
    expect(infos, isNotEmpty);
    expect(infos.any((i) => i.message.contains('hello-from-print')), isTrue);
  });

  test('ERROR exception includes severity and lineNo', () async {
    if (!available) {
      markTestSkipped('SQL Server not available on :$_port');
      return;
    }

    try {
      await conn.execute('SELECT * FROM dbo.definitely_missing_table_xyz');
      fail('expected MssqlException');
    } on MssqlException catch (e) {
      expect(e.errorCode, equals(208));
      expect(e.severity, isNotNull);
      expect(e.severity!, greaterThanOrEqualTo(11));
      expect(e.lineNo, isNotNull);
    }
  });
}
