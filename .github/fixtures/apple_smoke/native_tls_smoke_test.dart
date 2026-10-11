import 'dart:async';
import 'dart:io';
import 'dart:typed_data';

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
    await expectLater(
      _handshakePublicTls('self-signed.badssl.com')
          .timeout(const Duration(seconds: 30)),
      throwsA(isA<StateError>()),
    );
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

  testWidgets('trustServerCertificate bypasses Apple trust evaluation', (
    _,
  ) async {
    await _handshakePublicTls(
      'self-signed.badssl.com',
      trustServerCertificate: true,
    ).timeout(const Duration(seconds: 30));
  });
}

Future<void> _handshakePublicTls(
  String host, {
  bool trustServerCertificate = false,
}) async {
  final socket = await Socket.connect(host, 443);
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
