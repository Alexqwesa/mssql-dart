import 'package:mssql/mssql.dart';

/// Checks the "8 KiB circular plaintext buffer" model: the failing query index
/// should move when the TDS packet size changes.
Future<void> main(List<String> args) async {
  final alias = args.isEmpty ? 'nnnn' : args[0];
  final sql = 'SELECT 1 AS $alias';
  // 8 byte TDS header + 22 byte ALL_HEADERS + UCS-2 text.
  final pktSize = 8 + 22 + sql.length * 2;
  const bufSize = 8192;
  const startPos = bufSize ~/ 2;
  const login7 = 224;
  var k = 0;
  while (startPos + login7 + (k + 1) * pktSize <= bufSize) {
    k++;
  }
  print('sql="$sql" tdsPacket=$pktSize predicted failure at query ${k + 1}');

  final conn = await MssqlConnection.connect(
    host: '127.0.0.1',
    port: 14334,
    user: 'sa',
    password: 'Strong_test_password_123!',
    database: 'master',
    encrypt: true,
    trustServerCertificate: true,
  );
  for (var i = 1; i <= 200; i++) {
    try {
      await conn.query(sql);
    } catch (e) {
      print('ACTUAL failure at query $i: $e');
      return;
    }
  }
  print('ACTUAL: survived 200');
  await conn.close();
}
