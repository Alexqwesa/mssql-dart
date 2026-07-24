import 'package:mssql/mssql.dart';
import 'package:test/test.dart';

/// Live round-trips for typed GUID / money / datetimeoffset binders.
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

  test('MssqlGuid round-trip via uniqueidentifier param', () async {
    if (!available) {
      markTestSkipped('SQL Server not available on :$_port');
      return;
    }
    const g = '6F9619FF-8B86-D011-B42D-00C04FC964FF';
    final r = await conn.query(
      'SELECT @g AS v',
      {'g': const MssqlGuid(g)},
    );
    expect((r[0]['v'] as String).toUpperCase(), equals(g));
  });

  test('MssqlMoney / MssqlSmallMoney round-trip', () async {
    if (!available) {
      markTestSkipped('SQL Server not available on :$_port');
      return;
    }
    final r = await conn.query(
      'SELECT @m AS m, @s AS s',
      {
        'm': const MssqlMoney(1234.56),
        's': const MssqlSmallMoney(-99.99),
      },
    );
    expect(r[0]['m'] as double, closeTo(1234.56, 0.001));
    expect(r[0]['s'] as double, closeTo(-99.99, 0.001));
  });

  test('MssqlDateTimeOffset UTC round-trip', () async {
    if (!available) {
      markTestSkipped('SQL Server not available on :$_port');
      return;
    }
    final dt = DateTime.utc(2024, 3, 15, 10, 30, 0);
    final r = await conn.query(
      'SELECT @d AS v',
      {'d': MssqlDateTimeOffset(dt)},
    );
    final out = r[0]['v'] as DateTime;
    expect(out.year, equals(2024));
    expect(out.month, equals(3));
    expect(out.day, equals(15));
    expect(out.hour, equals(10));
    expect(out.minute, equals(30));
  });

  test('MssqlDateTimeOffset encodes offset minutes', () async {
    if (!available) {
      markTestSkipped('SQL Server not available on :$_port');
      return;
    }
    // Instant UTC 04:30 with display offset +05:30 (330 minutes).
    final r = await conn.query(
      'SELECT DATEPART(tzoffset, @d) AS mins, @d AS v',
      {
        'd': MssqlDateTimeOffset(
          DateTime.utc(2024, 1, 1, 4, 30),
          offset: const Duration(hours: 5, minutes: 30),
        ),
      },
    );
    expect(r[0]['mins'], equals(330));
    final v = r[0]['v'] as DateTime;
    expect(v.hour, equals(4));
    expect(v.minute, equals(30));
  });
}
