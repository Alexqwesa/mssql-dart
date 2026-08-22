import 'package:mssql/mssql.dart';
import 'package:test/test.dart';

import 'live_test_config.dart';
import 'live_test_gate.dart';

final _config = liveTestConfig;

Future<MssqlConnection> _connect({
  String? host,
  int? port,
  String? user,
  String? password,
  String database = 'master',
  Duration timeout = const Duration(seconds: 5),
}) {
  return MssqlConnection.connect(
    host: host ?? _config.host,
    port: port ?? _config.port,
    user: user ?? _config.user,
    password: password ?? _config.password,
    database: database,
    encrypt: false,
    trustServerCertificate: true,
    timeout: timeout,
  );
}

List<MssqlException> _allErrors(MssqlException error) => [
      ...error.precedingErrors,
      error,
    ];

void main() {
  if (!beginLiveSuite()) return;

  group('live initial connection failures', () {
    test('wrong password reports login failure 18456', () async {
      try {
        await _connect(password: 'Definitely_wrong_password_123!');
        fail('Expected login failure.');
      } on MssqlException catch (error) {
        expect(_allErrors(error).map((e) => e.errorCode), contains(18456));
        expect(error.message, isNotEmpty);
      }
    });

    test('unknown SQL login reports login failure 18456', () async {
      try {
        await _connect(user: 'mssql_dart_missing_login');
        fail('Expected login failure.');
      } on MssqlException catch (error) {
        expect(_allErrors(error).map((e) => e.errorCode), contains(18456));
      }
    });

    test('nonexistent database reports a database-open error', () async {
      try {
        await _connect(database: 'mssql_dart_missing_database');
        fail('Expected database-open failure.');
      } on MssqlException catch (error) {
        expect(
          _allErrors(error).map((e) => e.errorCode),
          anyOf(contains(4060), contains(4063)),
        );
      }
    });

    test('refused port is wrapped as MssqlException', () async {
      await expectLater(
        _connect(host: '127.0.0.1', port: 1),
        throwsA(
          isA<MssqlException>().having(
            (e) => e.message,
            'message',
            contains('TCP connect failed'),
          ),
        ),
      );
    });

    test('reserved invalid DNS name fails within the login deadline', () async {
      await expectLater(
        _connect(
          host: 'mssql-dart-does-not-exist.invalid',
          timeout: const Duration(seconds: 3),
        ),
        throwsA(isA<MssqlException>()),
      );
    });
  });
}
