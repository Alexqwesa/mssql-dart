import 'dart:io';

import 'package:mssql/mssql.dart';
import 'package:test/test.dart';

import 'live_test_config.dart';
import 'live_test_gate.dart';

final _config = liveTestConfig;

void main() {
  if (!beginLiveSuite()) return;
  final soak = Platform.environment['MSSQL_SOAK'] == '1';
  final minutes = int.tryParse(Platform.environment['MSSQL_SOAK_MINUTES'] ?? '') ??
      60;
  final budget = soak ? Duration(minutes: minutes) : const Duration(seconds: 90);

  test(
    'mixed pooled traffic stays within pool, session, and memory bounds',
    () async {
      final started = ProcessInfo.currentRss;
      final appName = 'mssql-dart-load';
      final pool = MssqlPool(MssqlPoolConfig(
        host: _config.host,
        port: _config.port,
        user: _config.user,
        password: _config.password,
        database: 'tempdb',
        encrypt: _config.encrypt,
        trustServerCertificate: _config.trustServerCertificate,
        appName: appName,
        connectRetries: 0,
        min: 0,
        max: 4,
      ));
      addTearDown(pool.close);
      final table = 'mssql_dart_load_${DateTime.now().microsecondsSinceEpoch}';
      await pool.execute('CREATE TABLE dbo.[$table] (id bigint NOT NULL)');
      addTearDown(() => pool.execute('DROP TABLE IF EXISTS dbo.[$table]'));
      final deadline = DateTime.now().add(budget);
      var index = 0;
      while (DateTime.now().isBefore(deadline)) {
        final n = index++;
        if (n % 5 == 0) {
          final conn = await pool.acquire();
          try {
            await conn.beginTransaction();
            await conn.execute('SELECT @n', {'n': n});
            await conn.commitTransaction();
          } finally {
            await pool.release(conn);
          }
        } else if (n % 5 == 1) {
          final conn = await pool.acquire();
          try {
            await for (final row in conn.queryStream(
              'SELECT @n AS n',
              {'n': n},
            )) {
              await Future<void>.delayed(const Duration(milliseconds: 5));
              expect(row['n'], n);
            }
          } finally {
            await pool.release(conn);
          }
        } else if (n % 5 == 2) {
          final conn = await pool.acquire();
          try {
            await conn.bulkInsert(
              'dbo.[$table]',
              ['id'],
              [
                [n],
              ],
              columnTypes: const [
                BulkColumn('id', BulkColumnType.bigInt, nullable: false),
              ],
            );
          } finally {
            await pool.release(conn);
          }
        } else {
          expect((await pool.query('SELECT @n AS n', {'n': n}))[0]['n'], n);
        }
        expect(pool.stats.total, lessThanOrEqualTo(4));
      }
      expect(pool.stats.inUse, 0);
      expect(pool.stats.destroyed, 0);
      final sessions = await pool.query(
        'SELECT COUNT(*) AS n FROM sys.dm_exec_sessions WHERE program_name = @name',
        {'name': appName},
      );
      expect(sessions[0]['n'], lessThanOrEqualTo(4));
      // maxRss is a process-wide high-water mark that other suites inflate, so
      // this compares the resident set before and after the load.
      expect(ProcessInfo.currentRss, lessThan(started + 256 * 1024 * 1024));
    },
    timeout: Timeout(Duration(minutes: soak ? minutes + 5 : 3)),
  );
}
