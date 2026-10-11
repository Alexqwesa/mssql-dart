import 'dart:async';
import 'dart:io';
import 'dart:typed_data';

import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:integration_test/integration_test.dart';
import 'package:mssql_driver_with_native_tls/src/native_tls/native_tls_engine.dart';

void main() {
  IntegrationTestWidgetsFlutterBinding.ensureInitialized();

  testWidgets('bundled native TLS helper emits a ClientHello', (_) async {
    final engine = NativeTlsEngine(
      serverName: 'localhost',
      trustServerCertificate: true,
    );
    addTearDown(engine.dispose);

    expect(engine.handshake(), anyOf(1, 2, 3));
    final encrypted = engine.drainEncrypted();
    expect(encrypted.bytes, isNotEmpty);
    expect(encrypted.bytes.first, 0x16);
  });

  testWidgets('Apple system trust accepts a public certificate', (_) async {
    await _handshakePublicTls('www.microsoft.com')
        .timeout(const Duration(seconds: 30));
  });

  testWidgets('Apple system trust rejects an unknown CA', (_) async {
    await withUntrustedTlsServer((port) async {
      await expectLater(
        _handshakePublicTls(
          'localhost',
          port: port,
          address: InternetAddress.loopbackIPv4,
        ).timeout(const Duration(seconds: 30)),
        throwsA(
          isA<StateError>().having(
            (error) => error.toString(),
            'error',
            contains('Apple certificate trust evaluation failed'),
          ),
        ),
      );
    });
  });

  testWidgets('Apple hostname policy rejects a mismatched certificate', (
    _,
  ) async {
    await expectLater(
      _handshakePublicTls('wrong.host.badssl.com')
          .timeout(const Duration(seconds: 30)),
      throwsA(isA<StateError>()),
    );
  });

  testWidgets('trustServerCertificate bypasses Apple trust', (_) async {
    await withUntrustedTlsServer((port) async {
      await _handshakePublicTls(
        'localhost',
        port: port,
        address: InternetAddress.loopbackIPv4,
        trustServerCertificate: true,
      ).timeout(const Duration(seconds: 30));
    });
  });
}

Future<void> withUntrustedTlsServer(
  Future<void> Function(int port) test,
) async {
  final certificate = await rootBundle.load('assets/server.pem');
  final key = await rootBundle.load('assets/server.key');

  final context = SecurityContext()
    ..useCertificateChainBytes(
      certificate.buffer.asUint8List(
        certificate.offsetInBytes,
        certificate.lengthInBytes,
      ),
    )
    ..usePrivateKeyBytes(
      key.buffer.asUint8List(key.offsetInBytes, key.lengthInBytes),
    );

  final server = await SecureServerSocket.bind(
    InternetAddress.loopbackIPv4,
    0,
    context,
  );

  final clients = <SecureSocket>{};

  final subscription = server.listen((socket) {
    clients.add(socket);
    socket.listen(
      (_) {},
      onError: (Object _) {},
      onDone: () {
        clients.remove(socket);
        socket.destroy();
      },
    );
  });

  try {
    await test(server.port);
  } finally {
    for (final socket in clients) {
      socket.destroy();
    }
    await subscription.cancel();
    await server.close();
  }
}

Future<void> _handshakePublicTls(
  String host, {
  int port = 443,
  InternetAddress? address,
  bool trustServerCertificate = false,
}) async {
  final socket = await Socket.connect(address ?? host, port);
  final input = StreamIterator<Uint8List>(socket);
  final engine = NativeTlsEngine(
    serverName: host,
    trustServerCertificate: trustServerCertificate,
  );
  try {
    var result = engine.handshake();
    for (var attempt = 0; attempt < 100; attempt++) {
      var wrote = false;
      while (true) {
        final encrypted = engine.drainEncrypted();
        if (encrypted.code < 0) {
          throw StateError('TLS output failed: ${engine.lastError()}');
        }
        if (encrypted.bytes.isEmpty) break;
        socket.add(encrypted.bytes);
        wrote = true;
      }
      if (wrote) await socket.flush();
      if (result == 3) return;
      if (result < 0) {
        throw StateError('TLS handshake failed: ${engine.lastError()}');
      }
      if (!await input.moveNext()) {
        throw StateError('TLS peer closed during the handshake.');
      }
      var remaining = input.current;
      while (remaining.isNotEmpty) {
        final fed = engine.feedEncrypted(remaining);
        if (fed.code < 0 || fed.consumed <= 0) {
          throw StateError('TLS input failed: ${engine.lastError()}');
        }
        remaining = Uint8List.sublistView(remaining, fed.consumed);
      }
      result = engine.handshake();
    }
    throw StateError('TLS handshake did not finish.');
  } finally {
    await input.cancel();
    socket.destroy();
    engine.dispose();
  }
}
