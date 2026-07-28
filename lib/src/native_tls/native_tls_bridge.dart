import 'dart:io';
import 'dart:typed_data';

import 'package:async/async.dart';

import '../tds/constants.dart';
import 'native_tls_engine.dart';
import 'native_tls_transport.dart';

/// Completes SQL Server's TDS-wrapped TLS handshake with the native engine.
final class NativeTlsBridge {
  NativeTlsBridge._();

  static Future<NativeTlsTransport> upgrade({
    required Socket rawSocket,
    required ChunkedStreamReader<int> rawReader,
    required String host,
    required bool trustServerCertificate,
  }) async {
    final engine = NativeTlsEngine(
      serverName: host,
      trustServerCertificate: trustServerCertificate,
    );
    try {
      var result = engine.handshake();
      while (true) {
        await _drainHandshakeOutput(rawSocket, engine);
        if (result == 3) break;
        if (result < 0) {
          throw StateError('Native TLS handshake failed with code $result.');
        }

        final header = await rawReader.readChunk(headerSize);
        if (header.length != headerSize) {
          throw StateError('Connection closed during TLS handshake.');
        }
        final length = (header[2] << 8) | header[3];
        if ((header[0] != packPrelogin && header[0] != packReply) ||
            length < headerSize) {
          throw FormatException('Invalid TDS TLS handshake packet.');
        }
        final body = await rawReader.readChunk(length - headerSize);
        if (body.length != length - headerSize) {
          throw StateError('Connection closed during TLS handshake packet.');
        }
        engine.feedEncrypted(Uint8List.fromList(body));
        result = engine.handshake();
      }
      return NativeTlsTransport(
        socket: rawSocket,
        reader: rawReader,
        engine: engine,
      );
    } catch (_) {
      engine.dispose();
      rethrow;
    }
  }

  static Future<void> _drainHandshakeOutput(
    Socket socket,
    NativeTlsEngine engine,
  ) async {
    while (true) {
      final ciphertext = engine.drainEncrypted();
      if (ciphertext.isEmpty) break;
      final packet = Uint8List(headerSize + ciphertext.length);
      packet[0] = packPrelogin;
      packet[1] = statusEOM;
      packet[2] = (packet.length >> 8) & 0xff;
      packet[3] = packet.length & 0xff;
      packet[6] = 1;
      packet.setRange(headerSize, packet.length, ciphertext);
      socket.add(packet);
    }
    await socket.flush();
  }
}
