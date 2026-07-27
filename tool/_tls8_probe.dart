import 'dart:io';

import 'package:async/async.dart';
import 'package:mssql/mssql.dart';
import 'package:mssql/src/tds/buf.dart';
import 'package:mssql/src/tds/constants.dart';
import 'package:mssql/src/tds/login7.dart';
import 'package:mssql/src/tds/prelogin.dart';
import 'package:mssql/src/tds/token_stream.dart';

/// Experimental TDS 8.0-style: TLS first, then PRELOGIN inside TLS.
Future<void> main() async {
  final raw = await Socket.connect('127.0.0.1', 14334);
  final tls = await SecureSocket.secure(
    raw,
    host: '127.0.0.1',
    onBadCertificate: (_) => true,
  );
  final buf = TdsBuffer(tls);

  await Prelogin.send(buf, requestEncrypt: encryptOn);
  final pre = await Prelogin.read(buf);
  print('prelogin enc=${pre.encryption} requiresTls=${pre.requiresTls}');

  await Login7.send(
    buf,
    const LoginConfig(
      host: '127.0.0.1',
      username: 'sa',
      password: 'Strong_test_password_123!',
      serverName: '127.0.0.1',
      database: 'master',
    ),
  );
  final login = await TokenStream(buf).processLoginResponse();
  print('login ok ${login.serverVersion}');

  for (var i = 1; i <= 200; i++) {
    try {
      buf.beginPacket(packSQLBatch);
      final sql = 'SELECT 1 AS n';
      for (final c in sql.codeUnits) {
        buf.writeByte(c);
        buf.writeByte(0);
      }
      await buf.finishPacket(packSQLBatch);
      await TokenStream(buf).processQueryResponse();
      if (i % 25 == 0) print('ok $i');
    } catch (e) {
      print('FAIL at $i: $e');
      break;
    }
  }
  await tls.close();
}
