import 'dart:async';
import 'dart:collection';
import 'dart:io';
import 'dart:typed_data';

import 'package:tls_fragment_secure_socket/tls_fragment_secure_socket.dart';

/// Byte transport below TDS framing.
///
/// Implementations own their encryption boundary; [writePacket] receives one
/// complete TDS packet and must not split it into separate logical writes.
abstract interface class TdsTransport {
  bool get isEncrypted;

  Stream<Uint8List> get incoming;

  Future<void> writePacket(Uint8List packet, {bool urgent = false});

  Future<void> writePackets(List<Uint8List> packets, {bool urgent = false});

  Future<void> close();
}

/// Cleartext transport used when SQL Server TLS is disabled.
final class SocketTdsTransport implements TdsTransport {
  final Socket socket;
  final Queue<_SocketWriteRequest> _urgentWrites = Queue();
  final Queue<_SocketWriteRequest> _writes = Queue();

  _SocketWriteRequest? _activeWrite;
  Future<void>? _runner;
  Object? _failure;
  StackTrace? _failureStack;
  bool _closed = false;

  SocketTdsTransport(this.socket);

  @override
  bool get isEncrypted => false;

  @override
  Stream<Uint8List> get incoming => socket.map(Uint8List.fromList);

  @override
  Future<void> writePacket(Uint8List packet, {bool urgent = false}) {
    _checkOpen();
    final request = _SocketWriteRequest(Uint8List.fromList(packet));
    (urgent ? _urgentWrites : _writes).add(request);
    _schedule();
    return request.done.future;
  }

  @override
  Future<void> writePackets(
    List<Uint8List> packets, {
    bool urgent = false,
  }) async {
    for (final packet in packets) {
      await writePacket(packet, urgent: urgent);
    }
  }

  @override
  Future<void> close() async {
    if (_closed) return;
    _closed = true;
    final error = StateError('Socket TDS transport is closed.');
    if (_activeWrite case final active? when !active.done.isCompleted) {
      active.done.completeError(error);
    }
    _activeWrite = null;
    for (final request in [..._urgentWrites, ..._writes]) {
      if (!request.done.isCompleted) request.done.completeError(error);
    }
    _urgentWrites.clear();
    _writes.clear();
    await socket.close();
  }

  void _schedule() {
    if (_runner != null || _closed || _failure != null) return;
    _runner = _run().whenComplete(() {
      _runner = null;
      if (!_closed &&
          _failure == null &&
          (_urgentWrites.isNotEmpty || _writes.isNotEmpty)) {
        _schedule();
      }
    });
  }

  Future<void> _run() async {
    try {
      while (!_closed) {
        final request = _activeWrite = _urgentWrites.isNotEmpty
            ? _urgentWrites.removeFirst()
            : (_writes.isNotEmpty ? _writes.removeFirst() : null);
        if (request == null) return;
        socket.add(request.packet);
        await socket.flush();
        if (_closed) return;
        _activeWrite = null;
        if (!request.done.isCompleted) request.done.complete();
      }
    } catch (error, stackTrace) {
      _failure = error;
      _failureStack = stackTrace;
      if (_activeWrite case final active? when !active.done.isCompleted) {
        active.done.completeError(error, stackTrace);
      }
      _activeWrite = null;
      for (final request in [..._urgentWrites, ..._writes]) {
        if (!request.done.isCompleted) {
          request.done.completeError(error, stackTrace);
        }
      }
      _urgentWrites.clear();
      _writes.clear();
      unawaited(socket.close());
    }
  }

  void _checkOpen() {
    if (_closed || _failure != null) {
      Error.throwWithStackTrace(
        _failure ?? StateError('Socket TDS transport is closed.'),
        _failureStack ?? StackTrace.current,
      );
    }
  }
}

final class _SocketWriteRequest {
  final Uint8List packet;
  final Completer<void> done = Completer<void>();

  _SocketWriteRequest(this.packet);
}

/// Dart TLS transport used after SQL Server's PRELOGIN-wrapped handshake.
///
/// The local queue retains urgent Attention ordering. The fragment socket then
/// serializes the selected request with TLS-engine activity and preserves one
/// complete TDS packet per explicit plaintext write.
final class TlsFragmentTdsTransport implements TdsTransport {
  final TlsFragmentSecureSocket socket;
  final Queue<_SocketWriteRequest> _urgentWrites = Queue();
  final Queue<_SocketWriteRequest> _writes = Queue();

  _SocketWriteRequest? _activeWrite;
  Future<void>? _runner;
  Object? _failure;
  StackTrace? _failureStack;
  bool _closed = false;

  TlsFragmentTdsTransport(this.socket);

  @override
  bool get isEncrypted => true;

  @override
  Stream<Uint8List> get incoming => socket;

  @override
  Future<void> writePacket(Uint8List packet, {bool urgent = false}) {
    _checkOpen();
    if (packet.length > socket.maximumTlsFragmentLength) {
      return Future<void>.error(
        ArgumentError.value(
          packet.length,
          'packet',
          'TDS packet exceeds the TLS fragment capacity '
              '(${socket.maximumTlsFragmentLength} bytes)',
        ),
      );
    }
    final request = _SocketWriteRequest(Uint8List.fromList(packet));
    (urgent ? _urgentWrites : _writes).add(request);
    _schedule();
    return request.done.future;
  }

  @override
  Future<void> writePackets(
    List<Uint8List> packets, {
    bool urgent = false,
  }) async {
    for (final packet in packets) {
      await writePacket(packet, urgent: urgent);
    }
  }

  @override
  Future<void> close() async {
    if (_closed) return;
    _closed = true;
    final error = StateError('TLS TDS transport is closed.');
    if (_activeWrite case final active? when !active.done.isCompleted) {
      active.done.completeError(error);
    }
    _activeWrite = null;
    for (final request in <_SocketWriteRequest>[..._urgentWrites, ..._writes]) {
      if (!request.done.isCompleted) request.done.completeError(error);
    }
    _urgentWrites.clear();
    _writes.clear();
    await socket.close();
  }

  void _schedule() {
    if (_runner != null || _closed || _failure != null) return;
    _runner = _run().whenComplete(() {
      _runner = null;
      if (!_closed &&
          _failure == null &&
          (_urgentWrites.isNotEmpty || _writes.isNotEmpty)) {
        _schedule();
      }
    });
  }

  Future<void> _run() async {
    try {
      while (!_closed) {
        final request = _activeWrite = _urgentWrites.isNotEmpty
            ? _urgentWrites.removeFirst()
            : (_writes.isNotEmpty ? _writes.removeFirst() : null);
        if (request == null) return;
        await socket.writeTlsFragment(request.packet);
        if (_closed) return;
        _activeWrite = null;
        if (!request.done.isCompleted) request.done.complete();
      }
    } catch (error, stackTrace) {
      _failure = error;
      _failureStack = stackTrace;
      if (_activeWrite case final active? when !active.done.isCompleted) {
        active.done.completeError(error, stackTrace);
      }
      _activeWrite = null;
      for (final request in <_SocketWriteRequest>[
        ..._urgentWrites,
        ..._writes,
      ]) {
        if (!request.done.isCompleted) {
          request.done.completeError(error, stackTrace);
        }
      }
      _urgentWrites.clear();
      _writes.clear();
      socket.destroy();
    }
  }

  void _checkOpen() {
    if (_closed || _failure != null) {
      Error.throwWithStackTrace(
        _failure ?? StateError('TLS TDS transport is closed.'),
        _failureStack ?? StackTrace.current,
      );
    }
  }
}
