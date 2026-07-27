import 'dart:async';
import 'dart:io';
import 'dart:typed_data';

import 'package:async/async.dart';

import 'constants.dart';

/// Result of a TDS-wrapped TLS upgrade (ms-tds §2.1.1).
class TdsTlsUpgrade {
  /// SecureSocket used for all subsequent TDS I/O.
  final SecureSocket socket;

  /// Underlying TCP socket to SQL Server (bridge lifetime).
  final Socket rawTcpSocket;

  /// Peer certificate when the server presented one (NTLM channel bindings).
  final X509Certificate? peerCertificate;

  const TdsTlsUpgrade({
    required this.socket,
    required this.rawTcpSocket,
    this.peerCertificate,
  });
}

/// Bridges [SecureSocket] ↔ SQL Server TCP for TDS 7.x encryption.
///
/// Handshake records are wrapped in PRELOGIN packets. After the handshake,
/// ciphertext is forwarded as opaque TCP byte chunks (no TLS-record reparse),
/// matching go-mssqldb's `tlsHandshakeConn` → raw passthrough model.
///
/// Note: keeping each **TDS packet** inside one TLS record is handled by
/// [TdsBuffer] (SecureSocket's circular plaintext buffer can otherwise split
/// one `add` across two `SSL_write`s). This bridge only wraps/unwraps PRELOGIN
/// during handshake and shuttles opaque ciphertext afterward.
class TdsTlsBridge {
  TdsTlsBridge._();

  /// Upgrades [rawSocket] (already past cleartext PRELOGIN) to TLS.
  ///
  /// [rawReader] must be the [ChunkedStreamReader] already attached to
  /// [rawSocket] (from [TdsBuffer.rawReader]). After success, callers must
  /// stop using that reader for TDS and switch I/O to [TdsTlsUpgrade.socket].
  ///
  /// [onBridgeDied] is invoked once if the bridge fails while the session
  /// should still be alive (never throws into the zone).
  static Future<TdsTlsUpgrade> upgrade({
    required Socket rawSocket,
    required ChunkedStreamReader<int> rawReader,
    required String host,
    bool trustServerCertificate = false,
    SecurityContext? securityContext,
    String? hostNameInCertificate,
    void Function()? onBridgeDied,
  }) async {
    final loopServer = await ServerSocket.bind(InternetAddress.loopbackIPv4, 0);
    final secSideFuture =
        Socket.connect(InternetAddress.loopbackIPv4, loopServer.port);
    final bridgeSide = await loopServer.first;
    await loopServer.close();
    final secSide = await secSideFuture;

    for (final s in [rawSocket, bridgeSide, secSide]) {
      try {
        s.setOption(SocketOption.tcpNoDelay, true);
      } catch (_) {}
    }

    var handshakeDone = false;
    var bridgeDead = false;

    void markDead() {
      if (bridgeDead) return;
      bridgeDead = true;
      onBridgeDied?.call();
    }

    // Direction A: SecureSocket → secSide → bridgeSide → rawSocket.
    // Capture wrap mode at enqueue time; drain handshake writes before flipping
    // to passthrough (go-mssqldb: Handshake then swap underlying conn).
    Future<void> writeChain = Future<void>.value();

    bridgeSide.listen(
      (data) {
        final wrap = !handshakeDone;
        final bytes = Uint8List.fromList(data);
        writeChain = writeChain.then((_) async {
          if (bridgeDead) return;
          try {
            if (!wrap) {
              rawSocket.add(bytes);
            } else {
              final size = headerSize + bytes.length;
              if (size > 0xFFFF) {
                markDead();
                rawSocket.destroy();
                return;
              }
              final pkt = Uint8List(size);
              pkt[0] = packPrelogin;
              pkt[1] = statusEOM;
              pkt[2] = (size >> 8) & 0xFF;
              pkt[3] = size & 0xFF;
              pkt[6] = 1;
              pkt.setRange(headerSize, size, bytes);
              rawSocket.add(pkt);
            }
          } catch (_) {
            markDead();
            try {
              rawSocket.destroy();
            } catch (_) {}
          }
        });
      },
      onError: (_) {
        markDead();
        try {
          rawSocket.destroy();
        } catch (_) {}
      },
      onDone: () {
        markDead();
        try {
          rawSocket.destroy();
        } catch (_) {}
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

    final tlsHost = hostNameInCertificate ?? host;
    final tls = await SecureSocket.secure(
      secSide,
      host: tlsHost,
      context: securityContext,
      onBadCertificate: trustServerCertificate ? (_) => true : null,
    );
    await writeChain;
    handshakeDone = true;

    return TdsTlsUpgrade(
      socket: tls,
      rawTcpSocket: rawSocket,
      peerCertificate: tls.peerCertificate,
    );
  }

  /// Package-visible entry for offline bridge state-machine tests.
  static Future<void> bridgeReadLoopForTest({
    required ChunkedStreamReader<int> rawReader,
    required Socket bridgeSide,
    required bool Function() isHandshakeDone,
    required void Function() onAbnormal,
  }) =>
      _bridgeReadLoop(
        rawReader: rawReader,
        bridgeSide: bridgeSide,
        isHandshakeDone: isHandshakeDone,
        onAbnormal: onAbnormal,
      );

  /// Phase 1: strip PRELOGIN wrappers. Phase 2: opaque TCP byte passthrough.
  static Future<void> _bridgeReadLoop({
    required ChunkedStreamReader<int> rawReader,
    required Socket bridgeSide,
    required bool Function() isHandshakeDone,
    required void Function() onAbnormal,
  }) async {
    var abnormal = false;
    try {
      while (true) {
        final hdr = await rawReader.readChunk(headerSize);
        if (hdr.length < headerSize) return;

        if (isHandshakeDone()) {
          try {
            bridgeSide.add(Uint8List.fromList(hdr));
          } catch (_) {
            abnormal = true;
            return;
          }
          break;
        }

        if (hdr[0] != packPrelogin && hdr[0] != packReply) {
          abnormal = true;
          return;
        }
        final bodyLen = ((hdr[2] << 8) | hdr[3]) - headerSize;
        if (bodyLen < 0) {
          abnormal = true;
          return;
        }
        if (bodyLen > 0) {
          final body = await rawReader.readChunk(bodyLen);
          if (body.isEmpty) return;
          try {
            bridgeSide.add(Uint8List.fromList(body));
          } catch (_) {
            abnormal = true;
            return;
          }
        }
      }

      await for (final chunk in rawReader.readStream(0x7fffffff)) {
        if (chunk.isEmpty) continue;
        try {
          bridgeSide.add(
            chunk is Uint8List ? chunk : Uint8List.fromList(chunk),
          );
        } catch (_) {
          abnormal = true;
          return;
        }
      }
    } catch (_) {
      // Expected on normal shutdown / peer close.
    } finally {
      try {
        await bridgeSide.close();
      } catch (_) {}
      if (abnormal) onAbnormal();
    }
  }
}
