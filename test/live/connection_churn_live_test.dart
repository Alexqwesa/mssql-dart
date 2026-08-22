import 'dart:io';

import 'package:mssql/mssql.dart';
import 'package:test/test.dart';

import 'live_test_config.dart';
import 'live_test_gate.dart';

final _config = liveTestConfig;
final _forceTlsPort = int.tryParse(
      Platform.environment['MSSQL_FORCE_TLS_PORT'] ?? '14335',
    ) ??
    14335;

Future<MssqlConnection> _open({bool encrypt = false, int? port}) =>
    MssqlConnection.connect(
      host: _config.host,
      port: port ?? _config.port,
      user: _config.user,
      password: _config.password,
      database: 'master',
      encrypt: encrypt,
      trustServerCertificate: true,
      timeout: const Duration(seconds: 10),
    );

MssqlPool _pool({
  bool encrypt = false,
  int? port,
  int max = 10,
}) =>
    MssqlPool(
      MssqlPoolConfig(
        host: _config.host,
        port: port ?? _config.port,
        user: _config.user,
        password: _config.password,
        database: 'master',
        encrypt: encrypt,
        trustServerCertificate: true,
        connectRetries: 0,
        min: 0,
        max: max,
      ),
    );

void main() {
  if (!beginLiveSuite()) return;

  group('live connection churn and sustained concurrency', () {
    test('50 rapid connect-query-close cycles', () async {
      for (var index = 0; index < 50; index++) {
        final conn = await _open();
        try {
          expect((await conn.query('SELECT @n AS n', {'n': index}))[0]['n'],
              index);
        } finally {
          await conn.close();
        }
      }
    }, timeout: const Timeout(Duration(minutes: 3)));

    test('20 simultaneous TLS connections are independent', () async {
      final connections = await Future.wait(
        List.generate(20, (_) => _open(encrypt: true)),
      );
      try {
        final results = await Future.wait(
          List.generate(
            connections.length,
            (index) => connections[index].query(
              'SELECT @n AS n, @@SPID AS spid',
              {'n': index},
            ),
          ),
        );
        expect(
          results.map((result) => result[0]['n']).toList(),
          List.generate(20, (index) => index),
        );
        expect(results.map((result) => result[0]['spid']).toSet().length, 20);
      } finally {
        await Future.wait(connections.map((connection) => connection.close()));
      }
    }, timeout: const Timeout(Duration(minutes: 2)));

    test('40 delayed pool queries complete under randomized ordering',
        () async {
      final pool = _pool(max: 8);
      addTearDown(pool.close);
      final results = await Future.wait(
        List.generate(40, (index) {
          final hundredths = (index * 7) % 5;
          return pool.query(
            "WAITFOR DELAY '00:00:00.0$hundredths'; SELECT @n AS n",
            {'n': index},
          );
        }),
      );
      expect(
        results.map((result) => result[0]['n']).toSet(),
        Set<int>.from(List.generate(40, (index) => index)),
      );
    });

    test('200 acquire-query-release cycles retain bounded pool size', () async {
      final pool = _pool(max: 4);
      addTearDown(pool.close);
      for (var index = 0; index < 200; index++) {
        final conn = await pool.acquire();
        try {
          expect((await conn.query('SELECT @n AS n', {'n': index}))[0]['n'],
              index);
        } finally {
          await pool.release(conn);
        }
      }
      expect(pool.size, lessThanOrEqualTo(4));
      expect(pool.borrowed, 0);
    }, timeout: const Timeout(Duration(minutes: 3)));

    test('20 concurrent pool queries succeed under forced TLS', () async {
      final pool = _pool(encrypt: true, port: _forceTlsPort, max: 5);
      addTearDown(pool.close);
      final results = await Future.wait(
        List.generate(
          20,
          (index) => pool.query(
            "WAITFOR DELAY '00:00:00.0${index % 3}'; SELECT @n AS n",
            {'n': index},
          ),
        ),
      );
      expect(
        results.map((result) => result[0]['n']).toSet(),
        Set<int>.from(List.generate(20, (index) => index)),
      );
    }, timeout: const Timeout(Duration(minutes: 2)));

    test('killed borrowers are replaced while pool waiters are queued',
        () async {
      final pool = _pool(max: 3);
      addTearDown(pool.close);
      final borrowed = await Future.wait(
        List.generate(3, (_) => pool.acquire()),
      );
      final spids = await Future.wait(
        borrowed.map(
          (connection) async =>
              (await connection.query('SELECT @@SPID AS id'))[0]['id'] as int,
        ),
      );

      final waiting = List.generate(6, (index) async {
        final connection = await pool.acquire();
        try {
          return (await connection.query('SELECT @n AS n', {'n': index}))[0]
              ['n'];
        } finally {
          await pool.release(connection);
        }
      });
      await Future<void>.delayed(const Duration(milliseconds: 50));
      expect(pool.pending, 6);

      final killer = await _open();
      try {
        for (final spid in spids) {
          await killer.execute('KILL $spid');
        }
      } finally {
        await killer.close();
      }
      await Future<void>.delayed(const Duration(milliseconds: 300));
      await Future.wait(borrowed.map(pool.release));

      expect(await Future.wait(waiting), List.generate(6, (index) => index));
      expect(pool.pending, 0);
      expect(pool.borrowed, 0);
      expect(pool.size, lessThanOrEqualTo(3));
    }, timeout: const Timeout(Duration(minutes: 2)));
  });
}
