import 'dart:async';
import 'dart:io';
import 'dart:typed_data';

import 'package:async/async.dart';
import 'package:tls_fragment_secure_socket/tls_fragment_secure_socket.dart';

import 'constants.dart';

/// Result of a TDS 7.x PRELOGIN-wrapped TLS upgrade.
final class TdsTlsUpgrade {
  /// Fragment-writing TLS socket used for subsequent TDS traffic.
  final TlsFragmentSecureSocket socket;

  /// TCP socket connected to SQL Server and owned by the bridge.
  final Socket rawTcpSocket;

  const TdsTlsUpgrade({required this.socket, required this.rawTcpSocket});
}

/// Bridges Dart TLS to SQL Server's TDS 7.x encryption negotiation.
///
/// TLS handshake records are wrapped in PRELOGIN packets. Once the handshake
/// completes, TLS ciphertext is forwarded unchanged. TDS packet boundaries in
/// application data are preserved separately by [TlsFragmentSecureSocket].
final class TdsTlsBridge {
  TdsTlsBridge._();

  /// Upgrades [rawSocket], which must already be past cleartext PRELOGIN.
  static Future<TdsTlsUpgrade> upgrade({
    required Socket rawSocket,
    required ChunkedStreamReader<int> rawReader,
    required String host,
    bool trustServerCertificate = false,
    String? trustedCertificateFile,
    String? trustedCertificateDirectory,
    void Function()? onBridgeDied,
  }) async {
    final context = _securityContext(
      trustedCertificateFile: trustedCertificateFile,
      trustedCertificateDirectory: trustedCertificateDirectory,
    );
    final loopServer = await ServerSocket.bind(InternetAddress.loopbackIPv4, 0);
    final tlsSideFuture = RawSocket.connect(
      InternetAddress.loopbackIPv4,
      loopServer.port,
    );
    final bridgeSide = await loopServer.first;
    await loopServer.close();
    final tlsSide = await tlsSideFuture;

    for (final socket in <Socket>[rawSocket, bridgeSide]) {
      try {
        socket.setOption(SocketOption.tcpNoDelay, true);
      } catch (_) {}
    }
    try {
      tlsSide.setOption(SocketOption.tcpNoDelay, true);
    } catch (_) {}

    var handshakeDone = false;
    var bridgeDead = false;

    void markDead() {
      if (bridgeDead) return;
      bridgeDead = true;
      onBridgeDied?.call();
    }

    // Serialize and flush this direction explicitly. A failed forwarding
    // operation is handled inside the chain, so one error cannot leave later
    // callbacks attached to a permanently failed Future without observation.
    Future<void> writeChain = Future<void>.value();
    bridgeSide.listen(
      (data) {
        final wrapAsPrelogin = !handshakeDone;
        final bytes = Uint8List.fromList(data);
        writeChain = writeChain.then((_) async {
          if (bridgeDead) return;
          try {
            if (wrapAsPrelogin) {
              final size = headerSize + bytes.length;
              if (size > 0xffff) {
                throw StateError(
                  'TLS handshake fragment exceeds the TDS packet limit.',
                );
              }
              final packet = Uint8List(size);
              packet[0] = packPrelogin;
              packet[1] = statusEOM;
              packet[2] = (size >> 8) & 0xff;
              packet[3] = size & 0xff;
              packet[6] = 1;
              packet.setRange(headerSize, size, bytes);
              rawSocket.add(packet);
            } else {
              rawSocket.add(bytes);
            }
            await rawSocket.flush();
          } catch (_) {
            markDead();
            rawSocket.destroy();
          }
        });
      },
      onError: (Object _, StackTrace _) {
        markDead();
        rawSocket.destroy();
      },
      onDone: () {
        markDead();
        rawSocket.destroy();
      },
      cancelOnError: true,
    );

    unawaited(
      _bridgeReadLoop(
        rawReader: rawReader,
        bridgeSide: bridgeSide,
        isHandshakeDone: () => handshakeDone,
        onAbnormal: markDead,
      ),
    );

    try {
      final tls = await TlsFragmentSecureSocket.secure(
        tlsSide,
        host: host,
        context: context,
        onBadCertificate: trustServerCertificate ? (_) => true : null,
      );
      await writeChain;
      if (bridgeDead) {
        tls.destroy();
        throw const SocketException('TLS bridge closed during handshake');
      }
      handshakeDone = true;
      return TdsTlsUpgrade(socket: tls, rawTcpSocket: rawSocket);
    } catch (_) {
      bridgeSide.destroy();
      await tlsSide.close();
      rawSocket.destroy();
      rethrow;
    }
  }

  /// Package-visible entry used by deterministic bridge tests.
  static Future<void> bridgeReadLoopForTest({
    required ChunkedStreamReader<int> rawReader,
    required Socket bridgeSide,
    required bool Function() isHandshakeDone,
    required void Function() onAbnormal,
  }) => _bridgeReadLoop(
    rawReader: rawReader,
    bridgeSide: bridgeSide,
    isHandshakeDone: isHandshakeDone,
    onAbnormal: onAbnormal,
  );

  static Future<void> _bridgeReadLoop({
    required ChunkedStreamReader<int> rawReader,
    required Socket bridgeSide,
    required bool Function() isHandshakeDone,
    required void Function() onAbnormal,
  }) async {
    var abnormal = false;
    try {
      while (true) {
        final header = await rawReader.readChunk(headerSize);
        if (header.length < headerSize) return;

        if (isHandshakeDone()) {
          bridgeSide.add(Uint8List.fromList(header));
          break;
        }

        if (header[0] != packPrelogin && header[0] != packReply) {
          abnormal = true;
          return;
        }
        final bodyLength = ((header[2] << 8) | header[3]) - headerSize;
        if (bodyLength < 0) {
          abnormal = true;
          return;
        }
        if (bodyLength > 0) {
          final body = await rawReader.readChunk(bodyLength);
          if (body.length < bodyLength) return;
          bridgeSide.add(Uint8List.fromList(body));
        }
      }

      await for (final chunk in rawReader.readStream(0x7fffffff)) {
        if (chunk.isNotEmpty) {
          bridgeSide.add(
            chunk is Uint8List ? chunk : Uint8List.fromList(chunk),
          );
        }
      }
    } catch (_) {
      abnormal = true;
    } finally {
      try {
        await bridgeSide.close();
      } catch (_) {}
      if (abnormal) onAbnormal();
    }
  }

  static SecurityContext? _securityContext({
    String? trustedCertificateFile,
    String? trustedCertificateDirectory,
  }) {
    if (trustedCertificateFile == null && trustedCertificateDirectory == null) {
      return null;
    }

    final context = SecurityContext(withTrustedRoots: true);
    if (trustedCertificateFile != null) {
      context.setTrustedCertificates(trustedCertificateFile);
    }
    if (trustedCertificateDirectory != null) {
      final entries =
          Directory(trustedCertificateDirectory)
              .listSync(followLinks: true)
              .whereType<File>()
              .toList(growable: false)
            ..sort((a, b) => a.path.compareTo(b.path));
      for (final certificate in entries) {
        context.setTrustedCertificates(certificate.path);
      }
    }
    return context;
  }
}
