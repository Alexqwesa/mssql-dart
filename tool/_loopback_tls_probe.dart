import 'dart:io';
import 'dart:typed_data';

import 'package:async/async.dart';

/// How many SecureSocket round-trips survive over a loopback TLS server?
Future<void> main() async {
  final certDir = await Directory.systemTemp.createTemp('tls-probe-');
  final keyFile = File('${certDir.path}/key.pem');
  final certFile = File('${certDir.path}/cert.pem');

  final r = await Process.run('openssl', [
    'req',
    '-x509',
    '-newkey',
    'rsa:2048',
    '-nodes',
    '-sha256',
    '-days',
    '1',
    '-keyout',
    keyFile.path,
    '-out',
    certFile.path,
    '-subj',
    '/CN=localhost',
  ]);
  if (r.exitCode != 0) {
    stderr.writeln(r.stderr);
    exit(1);
  }

  final ctx = SecurityContext()
    ..useCertificateChain(certFile.path)
    ..usePrivateKey(keyFile.path);

  final server = await SecureServerSocket.bind(
    InternetAddress.loopbackIPv4,
    0,
    ctx,
  );
  print('server ${server.port}');

  server.listen((client) {
    client.listen((data) {
      client.add(data);
    });
  });

  final sock = await SecureSocket.connect(
    InternetAddress.loopbackIPv4,
    server.port,
    onBadCertificate: (_) => true,
  );
  final reader = ChunkedStreamReader(sock);

  for (var i = 1; i <= 200; i++) {
    final payload = Uint8List.fromList([i & 0xFF, 2, 3, 4, 5, 6, 7, 8]);
    sock.add(payload);
    await sock.flush();
    final echo = await reader.readChunk(payload.length);
    if (echo.length != payload.length || echo[0] != payload[0]) {
      print('bad echo at $i len=${echo.length}');
      break;
    }
    if (i % 50 == 0) print('ok $i');
  }
  print('done');
  await sock.close();
  await server.close();
  await certDir.delete(recursive: true);
}
