import 'package:mssql/mssql.dart';
import 'package:test/test.dart';

import 'live_test_config.dart';
import 'live_test_gate.dart';

final _config = liveTestConfig;

void main() {
  if (!beginLiveSuite()) return;

  group('live compound TDS token sequences', () {
    late MssqlConnection conn;

    setUpAll(() async {
      conn = await _config.open(database: 'tempdb');
    });

    tearDownAll(() => conn.close());

    test('PRINT, DONE, empty results, INFO, and results stay ordered',
        () async {
      final infos = <MssqlInfoMessage>[];
      conn.onInfoMessage = infos.add;

      final result = await conn.queryMultiple('''
SET NOCOUNT OFF;
CREATE TABLE #token_order (id int NOT NULL PRIMARY KEY);
PRINT N'before';
INSERT INTO #token_order VALUES (1);
SELECT id, N'first' AS label FROM #token_order;
SELECT id FROM #token_order WHERE 1 = 0;
RAISERROR(N'notice', 10, 1);
UPDATE #token_order SET id = id WHERE id = -1;
SELECT id, N'last' AS label FROM #token_order;
''');

      expect(result.length, 3);
      expect(result[0][0]['label'], 'first');
      expect(result[1].isEmpty, isTrue);
      expect(result[2][0]['label'], 'last');
      expect(
          infos.map((info) => info.message), containsAll(['before', 'notice']));
      expect((await conn.query('SELECT 1 AS ok'))[0]['ok'], 1);
    });

    test('SET NOCOUNT controls DONE row counts without losing results',
        () async {
      await conn.execute('CREATE TABLE #nocount (id int NOT NULL)');
      final counted = await conn.execute(
        'SET NOCOUNT OFF; INSERT INTO #nocount VALUES (1)',
      );
      final suppressed = await conn.execute(
        'SET NOCOUNT ON; INSERT INTO #nocount VALUES (2); SET NOCOUNT OFF;',
      );

      expect(counted, 1);
      expect(suppressed, 0);
      expect(
          (await conn.query('SELECT COUNT(*) AS n FROM #nocount'))[0]['n'], 2);
    });

    test('AFTER trigger DONE tokens do not desynchronize row counts', () async {
      final suffix = DateTime.now().microsecondsSinceEpoch;
      final target = 'mssql_dart_trigger_target_$suffix';
      final audit = 'mssql_dart_trigger_audit_$suffix';
      final trigger = 'mssql_dart_token_trigger_$suffix';
      await conn.execute('''
CREATE TABLE dbo.[$target] (id int NOT NULL PRIMARY KEY);
CREATE TABLE dbo.[$audit] (id int NOT NULL);
''');
      await conn.execute('''
CREATE TRIGGER dbo.[$trigger]
ON dbo.[$target] AFTER INSERT AS
BEGIN
  INSERT INTO dbo.[$audit](id) SELECT id FROM inserted;
END;
''');
      addTearDown(() async {
        try {
          await conn.execute(
            'DROP TRIGGER IF EXISTS dbo.[$trigger]; '
            'DROP TABLE IF EXISTS dbo.[$target]; '
            'DROP TABLE IF EXISTS dbo.[$audit];',
          );
        } catch (_) {}
      });

      final affected = await conn.execute(
        'INSERT INTO dbo.[$target] VALUES (7)',
      );
      expect(affected, greaterThanOrEqualTo(1));
      expect(
        (await conn.query('SELECT COUNT(*) AS n FROM dbo.[$audit]'))[0]['n'],
        1,
      );
      expect((await conn.query('SELECT 1 AS ok'))[0]['ok'], 1);
    });

    test('zero-row UPDATE and DELETE report zero', () async {
      await conn.execute('CREATE TABLE #zero_dml (id int NOT NULL)');
      expect(await conn.execute('UPDATE #zero_dml SET id = 1'), 0);
      expect(await conn.execute('DELETE FROM #zero_dml'), 0);
    });

    test('procedure combines INFO, DONE, result, output, and return status',
        () async {
      final procedure =
          'mssql_dart_tokens_${DateTime.now().microsecondsSinceEpoch}';
      await conn.execute('''
CREATE PROCEDURE dbo.$procedure
  @input int,
  @output int OUTPUT
AS
BEGIN
  SET NOCOUNT OFF;
  PRINT N'procedure-info';
  CREATE TABLE #procedure_rows (value int NOT NULL);
  INSERT INTO #procedure_rows VALUES (@input);
  SELECT value FROM #procedure_rows;
  SET @output = @input + 10;
  RETURN 17;
END
''');
      addTearDown(() async {
        try {
          await conn.execute('DROP PROCEDURE dbo.$procedure');
        } catch (_) {}
      });

      final infos = <MssqlInfoMessage>[];
      conn.onInfoMessage = infos.add;
      final result = await conn.call(
        'dbo.$procedure',
        const {'input': 5, 'output': MssqlOutput(0)},
      );

      expect(result.returnStatus, 17);
      expect(result.output['output'], 15);
      expect(result.resultSets.length, 1);
      expect(result.first[0]['value'], 5);
      expect(
          infos.any((info) => info.message.contains('procedure-info')), isTrue);
    });
  });
}
