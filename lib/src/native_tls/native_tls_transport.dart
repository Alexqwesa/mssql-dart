import 'dart:async';
import 'dart:io';
import 'dart:typed_data';

import 'package:async/async.dart';

import 'native_tls_engine.dart';

/// Post-handshake TLS transport backed by the native memory-BIO engine.
///
/// The caller owns TDS framing. Every [writePacket] call maps to exactly one
/// native `SSL_write_ex` request; the raw socket only ever sees ciphertext.
final class NativeTlsTransport {
  final Socket _socket;
  final ChunkedStreamReader<int> _reader;
  final NativeTlsEngine _engine;
  final StreamController<Uint8List> _plaintext = StreamController();
  Future<void>? _pump;
  var _closed = false;

  NativeTlsTransport({
    required Socket socket,
    required ChunkedStreamReader<int> reader,
    required NativeTlsEngine engine,
  })  : _socket = socket,
        _reader = reader,
        _engine = engine;

  Stream<Uint8List> get plaintext => _plaintext.stream;

  /// Begins forwarding ciphertext from the raw socket into the native engine.
  void start() {
    _pump ??= _pumpIncoming();
  }

  Future<void> writePacket(Uint8List packet) async {
    _checkOpen();
    final result = _engine.writePacket(packet);
    if (result != 0) {
      throw StateError('Native TLS packet write failed with code $result.');
    }
    await _drainCiphertext();
  }

  Future<void> _pumpIncoming() async {
    try {
      await for (final chunk in _reader.readStream(0x7fffffff)) {
        if (chunk.isEmpty) continue;
        final result = _engine.feedEncrypted(Uint8List.fromList(chunk));
        if (result < 0) {
          throw StateError('Native TLS input failed with code $result.');
        }
        await _drainCiphertext();
        while (true) {
          final plaintext = _engine.readPlaintext();
          if (plaintext.isEmpty) break;
          _plaintext.add(plaintext);
        }
      }
      await _plaintext.close();
    } catch (error, stackTrace) {
      _plaintext.addError(error, stackTrace);
      await _plaintext.close();
    }
  }

  Future<void> _drainCiphertext() async {
    while (true) {
      final ciphertext = _engine.drainEncrypted();
      if (ciphertext.isEmpty) break;
      _socket.add(ciphertext);
    }
    await _socket.flush();
  }

  Future<void> close() async {
    if (_closed) return;
    _closed = true;
    _engine.dispose();
    await _plaintext.close();
    await _socket.close();
  }

  void _checkOpen() {
    if (_closed) throw StateError('Native TLS transport is closed.');
  }
}
