import 'package:mssql/mssql.dart';
import 'package:test/test.dart';

import 'live_test_config.dart';
import 'live_test_gate.dart';

final _config = liveTestConfig;

void main() {
  if (!beginLiveSuite()) return;

  group('live Unicode and hostile parameter values', () {
    late MssqlConnection conn;

    setUpAll(() async {
      conn = await _config.open(database: 'tempdb');
    });

    tearDownAll(() => conn.close());

    const unicodeSamples = <String, String>{
      'Arabic': 'مرحبا بالعالم',
      'Vietnamese': 'Tiếng Việt: Trường Sa',
      'Vietnamese combining': 'Tiếng Việt',
      'precomposed': 'Café',
      'decomposed': 'Café',
      'CJK': '日本語漢字测试',
      'Hindi': 'नमस्ते दुनिया',
      'Cyrillic': 'Привет, мир',
      'supplementary emoji': 'SQL 😀 🚀 𐐷',
    };

    for (final entry in unicodeSamples.entries) {
      test('${entry.key} parameter preserves UTF-16 code units', () async {
        final result = await conn.query(
          'SELECT @value AS value, DATALENGTH(@value) AS bytes',
          {'value': entry.value},
        );
        expect(result[0]['value'], entry.value);
        expect(result[0]['bytes'], entry.value.length * 2);
      });
    }

    test('representative SQL injection strings remain data', () async {
      await conn.execute(
        'CREATE TABLE #parameter_safety (id int NOT NULL PRIMARY KEY, '
        'value nvarchar(max) NOT NULL)',
      );
      const values = <String>[
        "' OR 1=1 --",
        "'; DROP TABLE #parameter_safety; --",
        "' UNION SELECT NULL --",
        "'; WAITFOR DELAY '00:00:05'; --",
        '/* comment */ SELECT 1',
        '-- line comment',
        '; EXEC sp_who;',
        "Robert'); DROP TABLE Students;--",
        "N'quoted''value'",
        'brackets [dbo].[users]; semicolon',
      ];

      for (var index = 0; index < values.length; index++) {
        await conn.execute(
          'INSERT INTO #parameter_safety (id, value) VALUES (@id, @value)',
          {'id': index, 'value': values[index]},
        );
      }

      final rows = await conn.query(
        'SELECT id, value FROM #parameter_safety ORDER BY id',
      );
      expect(rows.rows.map((row) => row['value']).toList(), values);
      expect(rows.length, values.length);
    });
  });
}
