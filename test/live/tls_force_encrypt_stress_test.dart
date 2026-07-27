import 'dart:io';

import 'package:mssql/mssql.dart';
import 'package:test/test.dart';

import 'live_test_config.dart';
import 'live_test_gate.dart';

/// Long-lived TLS stress against a forceencryption=1 SQL Server.
///
/// Requires:
///   MSSQL_LIVE_TESTS=1
///   MSSQL_FORCE_ENCRYPTION=1
///   encrypt:true + trustServerCertificate (self-signed live image)
///
/// Start the force-TLS compose overlay first:
///   docker compose --env-file .env -f docker-compose.live.yml \
///     -f docker-compose.live.force-tls.yml up -d --build
final _host = liveTestConfig.host;
final _port = liveTestConfig.port;
final _user = liveTestConfig.user;
final _password = liveTestConfig.password;

bool get _forceEncryptionEnabled =>
    Platform.environment['MSSQL_FORCE_ENCRYPTION'] == '1';

void main() {
  if (!liveTestsEnabled) {
    registerLiveTestsDisabled();
    return;
  }
  if (!_forceEncryptionEnabled) {
    test(
      'force-encryption TLS stress is disabled',
      () {},
      skip:
          'Set MSSQL_FORCE_ENCRYPTION=1 against a forceencryption=1 container.',
    );
    return;
  }

  group('forceencryption TLS stress', () {
    test('encrypt:false fails with a clear error', () async {
      await expectLater(
        MssqlConnection.connect(
          host: _host,
          port: _port,
          user: _user,
          password: _password,
          database: 'master',
          encrypt: false,
          trustServerCertificate: true,
        ),
        throwsA(
          isA<MssqlException>().having(
            (e) => e.message,
            'message',
            contains('Server requires encryption'),
          ),
        ),
      );
    });

    test('100+ queries on one TLS connection', () async {
      final conn = await MssqlConnection.connect(
        host: _host,
        port: _port,
        user: _user,
        password: _password,
        database: 'master',
        encrypt: true,
        trustServerCertificate: true,
      );
      addTearDown(conn.close);

      for (var i = 1; i <= 120; i++) {
        final r = await conn.query('SELECT @n AS n, @s AS s', {
          'n': i,
          's': 'tls-$i',
        });
        expect(r[0]['n'], equals(i));
        expect(r[0]['s'], equals('tls-$i'));
      }
    });

    test('types round-trip on shared TLS connection', () async {
      final conn = await MssqlConnection.connect(
        host: _host,
        port: _port,
        user: _user,
        password: _password,
        database: 'master',
        encrypt: true,
        trustServerCertificate: true,
      );
      addTearDown(conn.close);

      final r = await conn.query(r'''
SELECT
  CAST(1 AS bit) AS b,
  CAST(42 AS int) AS i,
  CAST(3.14 AS float) AS f,
  CAST(N'hello' AS nvarchar(20)) AS s,
  CAST(0x010203 AS varbinary(8)) AS bin,
  CAST('2024-01-02T03:04:05' AS datetime2) AS dt
''');
      expect(r[0]['b'], equals(true));
      expect(r[0]['i'], equals(42));
      expect(r[0]['f'], closeTo(3.14, 0.001));
      expect(r[0]['s'], equals('hello'));
      expect(r[0]['bin'], equals([1, 2, 3]));
      expect(r[0]['dt'], isA<DateTime>());

      for (var i = 0; i < 40; i++) {
        final again = await conn.query('SELECT @i AS i', {'i': i});
        expect(again[0]['i'], equals(i));
      }
    });

    test('pool acquires and queries under forced TLS', () async {
      final pool = MssqlPool(
        MssqlPoolConfig(
          host: _host,
          port: _port,
          user: _user,
          password: _password,
          database: 'master',
          encrypt: true,
          trustServerCertificate: true,
          min: 1,
          max: 3,
        ),
      );
      addTearDown(pool.close);

      for (var i = 0; i < 30; i++) {
        final conn = await pool.acquire();
        try {
          final r = await conn.query('SELECT @n AS n', {'n': i});
          expect(r[0]['n'], equals(i));
        } finally {
          await pool.release(conn);
        }
      }
    });
  });
}
