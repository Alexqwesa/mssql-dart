import 'dart:io';
import 'dart:typed_data';

import '../native_tls/native_tls_transport.dart';

/// Byte transport below TDS framing.
///
/// Implementations own their encryption boundary; [writePacket] receives one
/// complete TDS packet and must not split it into separate logical writes.
abstract interface class TdsTransport {
  bool get isEncrypted;

  Stream<Uint8List> get incoming;

  Future<void> writePacket(Uint8List packet);

  Future<void> close();
}

/// Cleartext transport used when SQL Server TLS is disabled.
final class SocketTdsTransport implements TdsTransport {
  final Socket socket;

  SocketTdsTransport(this.socket);

  @override
  bool get isEncrypted => false;

  @override
  Stream<Uint8List> get incoming => socket.map(Uint8List.fromList);

  @override
  Future<void> writePacket(Uint8List packet) async {
    socket.add(packet);
    await socket.flush();
  }

  @override
  Future<void> close() => socket.close();
}

/// Native OpenSSL transport adapter used after SQL Server's TLS handshake.
final class NativeTlsTdsTransport implements TdsTransport {
  final NativeTlsTransport transport;

  NativeTlsTdsTransport(this.transport);

  @override
  bool get isEncrypted => true;

  @override
  Stream<Uint8List> get incoming => transport.plaintext;

  @override
  Future<void> writePacket(Uint8List packet) => transport.writePacket(packet);

  @override
  Future<void> close() => transport.close();
}
