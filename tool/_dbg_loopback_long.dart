import 'dart:io';
import 'dart:typed_data';

import 'package:async/async.dart';

/// Probes whether Dart's SecureSocket splits a single `add()` into two TLS
/// records once cumulative plaintext crosses its internal buffer size, and
/// whether the bytes stay in order across that split.
Future<void> main(List<String> args) async {
  final payloadLen = int.parse(
    args
        .firstWhere((a) => a.startsWith('--payload='),
            orElse: () => '--payload=56')
        .split('=')[1],
  );

  final certDir = await Directory.systemTemp.createTemp('tls-probe-');
  final keyFile = File('${certDir.path}/key.pem');
  final certFile = File('${certDir.path}/cert.pem');

  final r = await Process.run('openssl', [
    'req', '-x509', '-newkey', 'rsa:2048', '-nodes', '-sha256', '-days', '1',
    '-keyout', keyFile.path, '-out', certFile.path, '-subj', '/CN=localhost',
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
  server.listen((client) {
    client.listen((data) => client.add(data));
  });

  // SecureSocket over a loopback pair, other end pumped to the real server.
  final real = await Socket.connect(InternetAddress.loopbackIPv4, server.port);
  final loop = await ServerSocket.bind(InternetAddress.loopbackIPv4, 0);
  final secSideF = Socket.connect(InternetAddress.loopbackIPv4, loop.port);
  final bridgeSide = await loop.first;
  await loop.close();
  final secSide = await secSideF;
  for (final s in [real, bridgeSide, secSide]) {
    s.setOption(SocketOption.tcpNoDelay, true);
  }

  var appPlaintext = 0; // cumulative plaintext handed to SecureSocket
  final pend = <int>[];
  var recNo = 0;
  bridgeSide.listen((d) {
    pend.addAll(d);
    while (pend.length >= 5) {
      final len = (pend[3] << 8) | pend[4];
      if (pend.length < 5 + len) break;
      recNo++;
      if (pend[0] == 23) {
        print('  rec#$recNo ct=${pend[0]} len=$len (plaintext=${len - 24}) '
            'cumPlaintext=$appPlaintext');
      }
      pend.removeRange(0, 5 + len);
    }
    real.add(d);
  }, onDone: real.destroy);
  real.listen(bridgeSide.add, onDone: bridgeSide.destroy);

  final sock = await SecureSocket.secure(
    secSide,
    host: 'localhost',
    onBadCertificate: (_) => true,
  );
  final reader = ChunkedStreamReader(sock);

  for (var i = 1; i <= 200; i++) {
    final payload = Uint8List(payloadLen);
    for (var j = 0; j < payloadLen; j++) {
      payload[j] = (i * 7 + j) & 0xFF;
    }
    sock.add(payload);
    appPlaintext += payloadLen;
    await sock.flush();
    final echo = await reader.readChunk(payloadLen);
    if (echo.length != payloadLen) {
      print('SHORT echo at $i len=${echo.length}');
      break;
    }
    var bad = -1;
    for (var j = 0; j < payloadLen; j++) {
      if (echo[j] != payload[j]) {
        bad = j;
        break;
      }
    }
    if (bad >= 0) {
      print('CORRUPT echo at iter=$i offset=$bad '
          'expected=${payload[bad]} got=${echo[bad]}');
      break;
    }
  }
  print('done cumPlaintext=$appPlaintext');
  try {
    await sock.close();
  } catch (_) {}
  await server.close();
  await certDir.delete(recursive: true);
  exit(0);
}
