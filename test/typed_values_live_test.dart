import 'package:mssql/mssql.dart';
import 'package:test/test.dart';

/// Live round-trips for typed SQL binders (GUID / money / DTO / decimal /
/// varchar / date / time).
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

  test('MssqlDecimal round-trip', () async {
    if (!available) {
      markTestSkipped('SQL Server not available on :$_port');
      return;
    }
    final r = await conn.query(
      'SELECT @d AS d, @n AS n',
      {
        'd': MssqlDecimal(1234.56, precision: 10, scale: 2),
        'n': MssqlDecimal.parse(
          '-99.9900',
          precision: 10,
          scale: 4,
          asNumeric: true,
        ),
      },
    );
    expect(r[0]['d'] as double, closeTo(1234.56, 0.001));
    expect(r[0]['n'] as double, closeTo(-99.99, 0.0001));
  });

  test('MssqlVarchar / MssqlDate / MssqlTime round-trip', () async {
    if (!available) {
      markTestSkipped('SQL Server not available on :$_port');
      return;
    }
    final r = await conn.query(
      'SELECT @v AS v, @d AS d, @t AS t, '
      "SQL_VARIANT_PROPERTY(CAST(@v AS sql_variant), 'BaseType') AS vb, "
      "SQL_VARIANT_PROPERTY(CAST(@d AS sql_variant), 'BaseType') AS db, "
      "SQL_VARIANT_PROPERTY(CAST(@t AS sql_variant), 'BaseType') AS tb",
      {
        'v': const MssqlVarchar('lan-ascii'),
        'd': MssqlDate(2024, 7, 24),
        't': MssqlTime(hour: 14, minute: 30, second: 45, microsecond: 123000),
      },
    );
    expect(r[0]['v'], equals('lan-ascii'));
    expect((r[0]['vb'] as String).toLowerCase(), equals('varchar'));
    expect((r[0]['db'] as String).toLowerCase(), equals('date'));
    expect((r[0]['tb'] as String).toLowerCase(), equals('time'));

    final d = r[0]['d'] as DateTime;
    expect(d.year, equals(2024));
    expect(d.month, equals(7));
    expect(d.day, equals(24));

    final t = r[0]['t'] as DateTime;
    expect(t.hour, equals(14));
    expect(t.minute, equals(30));
    expect(t.second, equals(45));
  });

  test('MssqlVarchar into varchar column avoids nvarchar mismatch', () async {
    if (!available) {
      markTestSkipped('SQL Server not available on :$_port');
      return;
    }
    await conn.execute(
      'IF OBJECT_ID(\'tempdb..#vt\') IS NOT NULL DROP TABLE #vt;'
      'CREATE TABLE #vt (name varchar(32) NOT NULL);',
    );
    await conn.execute(
      'INSERT INTO #vt (name) VALUES (@n)',
      {'n': const MssqlVarchar('bob')},
    );
    final r = await conn.query('SELECT name FROM #vt');
    expect(r[0]['name'], equals('bob'));
  });

  test('MssqlDateTime / MssqlSmallDateTime round-trip', () async {
    if (!available) {
      markTestSkipped('SQL Server not available on :$_port');
      return;
    }
    final r = await conn.query(
      'SELECT @dt AS dt, @sd AS sd, '
      "SQL_VARIANT_PROPERTY(CAST(@dt AS sql_variant), 'BaseType') AS dtb, "
      "SQL_VARIANT_PROPERTY(CAST(@sd AS sql_variant), 'BaseType') AS sdb",
      {
        'dt': MssqlDateTime(DateTime.utc(2024, 3, 15, 10, 30, 0)),
        'sd': MssqlSmallDateTime(DateTime.utc(2024, 3, 15, 10, 30, 45)),
      },
    );
    expect((r[0]['dtb'] as String).toLowerCase(), equals('datetime'));
    expect((r[0]['sdb'] as String).toLowerCase(), equals('smalldatetime'));

    final dt = r[0]['dt'] as DateTime;
    expect(dt.year, equals(2024));
    expect(dt.month, equals(3));
    expect(dt.day, equals(15));
    expect(dt.hour, equals(10));
    expect(dt.minute, equals(30));

    // 45s rounds to next minute for smalldatetime
    final sd = r[0]['sd'] as DateTime;
    expect(sd.hour, equals(10));
    expect(sd.minute, equals(31));
    expect(sd.second, equals(0));
  });
}
