import 'package:mssql/mssql.dart';

Future<void> main() async {
  final conn = await MssqlConnection.connect(
    host: '127.0.0.1',
    port: 14334,
    user: 'sa',
    password: 'Strong_test_password_123!',
    database: 'master',
    encrypt: true,
    trustServerCertificate: true,
  );
  print('open');
  for (var i = 1; i <= 150; i++) {
    try {
      final r = await conn.query('SELECT @n AS n, @s AS s', {
        'n': i,
        's': 'tls-$i',
      });
      if (r[0]['n'] != i) print('bad at $i');
      if (i % 25 == 0) print('ok $i');
    } catch (e) {
      print('FAIL at $i: $e');
      await conn.close();
      return;
    }
  }
  print('survived 150 RPC');
  await conn.close();
}
