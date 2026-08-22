import 'dart:io';

import 'package:mssql/mssql.dart';
import 'package:test/test.dart';

import 'live_test_config.dart';
import 'live_test_gate.dart';

final _config = liveTestConfig;
final _caFile = File('docker/live/certs/ca.pem').absolute.path;
final _caDirectory = Directory('docker/live/certs/trusted').absolute.path;

Future<MssqlConnection> _connect({
  String? host,
  String? trustedCertificateFile,
  String? trustedCertificateDirectory,
  String? hostNameInCertificate,
}) {
  return MssqlConnection.connect(
    host: host ?? 'localhost',
    port: _config.port,
    user: _config.user,
    password: _config.password,
    database: 'master',
    encrypt: true,
    trustServerCertificate: false,
    trustedCertificateFile: trustedCertificateFile,
    trustedCertificateDirectory: trustedCertificateDirectory,
    hostNameInCertificate: hostNameInCertificate,
    timeout: const Duration(seconds: 8),
  );
}

void main() {
  if (!beginLiveSuite()) return;

  group('live TLS certificate validation', () {
    test('custom CA file and matching hostname succeed', () async {
      final conn = await _connect(trustedCertificateFile: _caFile);
      addTearDown(conn.close);
      expect((await conn.query('SELECT 1 AS ok'))[0]['ok'], 1);
    });

    test('custom CA directory and matching hostname succeed', () async {
      final conn = await _connect(trustedCertificateDirectory: _caDirectory);
      addTearDown(conn.close);
      expect((await conn.query('SELECT 1 AS ok'))[0]['ok'], 1);
    });

    test('unknown CA fails', () async {
      await expectLater(_connect(), throwsA(isA<MssqlException>()));
    });

    test('wrong hostname fails', () async {
      await expectLater(
        _connect(host: '127.0.0.1', trustedCertificateFile: _caFile),
        throwsA(isA<MssqlException>()),
      );
    });

    test('hostNameInCertificate validates an IP connection', () async {
      final conn = await _connect(
        host: '127.0.0.1',
        trustedCertificateFile: _caFile,
        hostNameInCertificate: 'localhost',
      );
      addTearDown(conn.close);
      expect((await conn.query('SELECT 1 AS ok'))[0]['ok'], 1);
    });

    test('missing CA file fails cleanly', () async {
      await expectLater(
        _connect(trustedCertificateFile: 'missing-mssql-test-ca.pem'),
        throwsA(isA<MssqlException>()),
      );
    });

    test('invalid CA file fails cleanly', () async {
      final directory = await Directory.systemTemp.createTemp('mssql-bad-ca-');
      addTearDown(() => directory.delete(recursive: true));
      final invalid = File('${directory.path}${Platform.pathSeparator}ca.pem');
      await invalid.writeAsString('not a PEM certificate');

      await expectLater(
        _connect(trustedCertificateFile: invalid.path),
        throwsA(isA<MssqlException>()),
      );
    });

    test('pool retains no connection after certificate failure', () async {
      final pool = MssqlPool(
        MssqlPoolConfig(
          host: '127.0.0.1',
          port: _config.port,
          user: _config.user,
          password: _config.password,
          database: 'master',
          encrypt: true,
          trustServerCertificate: false,
          trustedCertificateFile: _caFile,
          connectRetries: 0,
          min: 0,
          max: 1,
        ),
      );
      addTearDown(pool.close);

      await expectLater(pool.query('SELECT 1'), throwsA(isA<MssqlException>()));
      expect(pool.size, 0);
      expect(pool.borrowed, 0);
      expect(pool.available, 0);
    });
  });
}
