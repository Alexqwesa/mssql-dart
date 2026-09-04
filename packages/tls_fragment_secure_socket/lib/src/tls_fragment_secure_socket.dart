import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:math';
import 'dart:typed_data';

/// A [SecureSocket] with fragment-backed TLS output.
///
/// Creating this type explicitly selects fragment-backed output for the
/// lifetime of the connection. It does not dynamically switch between normal
/// [SecureSocket] writes and fragment writes.
///
/// All inherited [IOSink] output operations, including [add], [write],
/// [writeln], and [addStream], share one serialized queue with
/// [writeTlsFragment]. This preserves call order and prevents an ordinary write
/// from entering the TLS plaintext buffer while an explicit fragment is in
/// progress. Ordinary output larger than [maximumTlsFragmentLength] is split
/// automatically across multiple successful TLS-engine writes.
///
/// Use [writeTlsFragment] when an application protocol must submit one logical
/// fragment for consumption by one successful call to the TLS engine's
/// plaintext-write function and await that operation specifically. In the
/// patched Dart VM, one successful `SSL_write()` consumes the complete
/// fragment. Non-consuming calls may be retried when the TLS engine reports
/// that it needs more input or output capacity. A successful `SSL_write()` may
/// still produce more than one TLS record; this API does not control TLS record
/// boundaries.
///
/// Input behaves like a normal [SecureSocket] stream. Fragment-backed output
/// can reduce throughput, so use this type only for protocols that require
/// control over native TLS write boundaries. Use [SecureSocket] otherwise.
///
/// This class requires a Dart SDK whose [RawSecureSocket] exposes
/// `maximumTlsFragmentLength` and `writeTlsFragment`.
final class TlsFragmentSecureSocket extends Stream<Uint8List>
    implements SecureSocket {
  RawSecureSocket? _raw;
  final StreamController<Uint8List> _controller = StreamController<Uint8List>(
    sync: true,
  );
  late final _TlsFragmentStreamConsumer _consumer;
  late final IOSink _sink;
  StreamSubscription<RawSocketEvent>? _rawSubscription;
  bool _controllerClosed = false;

  final Set<_TlsFragmentWrite> _pendingFragmentWrites = <_TlsFragmentWrite>{};
  final Expando<_TlsFragmentWrite> _fragmentWriteTags =
      Expando<_TlsFragmentWrite>();

  TlsFragmentSecureSocket._(RawSecureSocket raw) : _raw = raw {
    _controller
      ..onListen = _onSubscriptionStateChange
      ..onCancel = _onSubscriptionStateChange
      ..onPause = _onPauseStateChange
      ..onResume = _onPauseStateChange;
    _consumer = _TlsFragmentStreamConsumer(this);
    _sink = IOSink(_consumer);

    raw.readEventsEnabled = false;
    raw.writeEventsEnabled = false;
  }

  /// Connects a TLS client and selects fragment-backed output.
  ///
  /// The connection and TLS options have the same meaning as the corresponding
  /// options on [SecureSocket.connect].
  static Future<TlsFragmentSecureSocket> connect(
    Object host,
    int port, {
    SecurityContext? context,
    bool Function(X509Certificate certificate)? onBadCertificate,
    void Function(String line)? keyLog,
    List<String>? supportedProtocols,
    Duration? timeout,
  }) async {
    final raw = await RawSecureSocket.connect(
      host,
      port,
      context: context,
      onBadCertificate: onBadCertificate,
      keyLog: keyLog,
      supportedProtocols: supportedProtocols,
      timeout: timeout,
    );
    return TlsFragmentSecureSocket._(raw);
  }

  /// Starts a cancellable TLS client connection with fragment-backed output.
  ///
  /// The returned task retains the concrete [TlsFragmentSecureSocket] type, so
  /// [writeTlsFragment] remains available after the connection completes.
  static Future<ConnectionTask<TlsFragmentSecureSocket>> startConnect(
    Object host,
    int port, {
    SecurityContext? context,
    bool Function(X509Certificate certificate)? onBadCertificate,
    void Function(String line)? keyLog,
    List<String>? supportedProtocols,
  }) async {
    final rawTask = await RawSecureSocket.startConnect(
      host,
      port,
      context: context,
      onBadCertificate: onBadCertificate,
      keyLog: keyLog,
      supportedProtocols: supportedProtocols,
    );
    final socket = rawTask.socket.then(TlsFragmentSecureSocket._);
    return ConnectionTask.fromSocket(socket, rawTask.cancel);
  }

  /// Initiates client-side TLS with fragment-backed output on an existing
  /// [RawSocket].
  ///
  /// If [socket] already has a subscription, transfer it through
  /// [subscription] exactly as required by [RawSecureSocket.secure].
  static Future<TlsFragmentSecureSocket> secure(
    RawSocket socket, {
    StreamSubscription<RawSocketEvent>? subscription,
    Object? host,
    SecurityContext? context,
    bool Function(X509Certificate certificate)? onBadCertificate,
    void Function(String line)? keyLog,
    List<String>? supportedProtocols,
  }) async {
    final raw = await RawSecureSocket.secure(
      socket,
      subscription: subscription,
      host: host,
      context: context,
      onBadCertificate: onBadCertificate,
      keyLog: keyLog,
      supportedProtocols: supportedProtocols,
    );
    return TlsFragmentSecureSocket._(raw);
  }

  /// Initiates server-side TLS with fragment-backed output on an existing
  /// [RawSocket].
  static Future<TlsFragmentSecureSocket> secureServer(
    RawSocket socket,
    SecurityContext? context, {
    StreamSubscription<RawSocketEvent>? subscription,
    List<int>? bufferedData,
    bool requestClientCertificate = false,
    bool requireClientCertificate = false,
    List<String>? supportedProtocols,
  }) async {
    final raw = await RawSecureSocket.secureServer(
      socket,
      context,
      subscription: subscription,
      bufferedData: bufferedData,
      requestClientCertificate: requestClientCertificate,
      requireClientCertificate: requireClientCertificate,
      supportedProtocols: supportedProtocols,
    );
    return TlsFragmentSecureSocket._(raw);
  }

  /// The largest plaintext fragment accepted by [writeTlsFragment].
  ///
  /// This is an SDK implementation capacity, not the TLS protocol's maximum
  /// record size. Ordinary [IOSink] output is split at this boundary, while an
  /// oversized explicit fragment completes with an [ArgumentError].
  int get maximumTlsFragmentLength => _requireRaw.maximumTlsFragmentLength;

  /// Queues [data] for one successful TLS-engine plaintext write.
  ///
  /// In the patched Dart VM, one successful `SSL_write()` consumes the complete
  /// fragment. Calls that consume no plaintext may be retried when the TLS
  /// engine needs more input or output capacity. This operation is distinct
  /// from the later writes of encrypted bytes to the operating-system socket.
  ///
  /// The bytes are copied synchronously, so later mutation of [data] cannot
  /// change the queued fragment. The operation is ordered with earlier and
  /// later inherited [IOSink] calls and other calls to this method.
  ///
  /// The returned future completes after the TLS implementation has consumed
  /// the complete plaintext fragment and its generated ciphertext has drained
  /// to the underlying raw socket. Completion does not mean that the peer has
  /// received or processed the data.
  ///
  /// Empty [data] acts as a write-drain barrier and does not produce a TLS
  /// record. If [data] exceeds [maximumTlsFragmentLength], the returned future
  /// completes with an [ArgumentError] and no bytes are queued. Closing,
  /// destroying, or failing the socket completes pending fragment operations
  /// with an error.
  ///
  /// One successful `SSL_write()` does not necessarily produce exactly one TLS
  /// record; the TLS implementation may apply its own record fragmentation.
  Future<void> writeTlsFragment(List<int> data) {
    try {
      final maximumLength = maximumTlsFragmentLength;
      if (data.length > maximumLength) {
        return Future<void>.error(
          ArgumentError.value(
            data.length,
            'data',
            'TLS fragment exceeds the $maximumLength-byte plaintext limit',
          ),
        );
      }

      final command = _TlsFragmentWrite(Uint8List.fromList(data));
      _pendingFragmentWrites.add(command);
      _fragmentWriteTags[command.bytes] = command;
      try {
        _sink.add(command.bytes);
      } catch (error, stackTrace) {
        _pendingFragmentWrites.remove(command);
        return Future<void>.error(error, stackTrace);
      }
      return command.completer.future;
    } catch (error, stackTrace) {
      return Future<void>.error(error, stackTrace);
    }
  }

  RawSecureSocket get _requireRaw {
    final raw = _raw;
    if (raw == null) throw const SocketException.closed();
    return raw;
  }

  Future<void> _writeSinkData(List<int> data) async {
    final command = _fragmentWriteTags[data];
    if (command != null) {
      try {
        await _requireRaw.writeTlsFragment(command.bytes);
        command.completer.complete();
      } catch (error, stackTrace) {
        command.completer.completeError(error, stackTrace);
        rethrow;
      } finally {
        _pendingFragmentWrites.remove(command);
      }
      return;
    }

    if (data.isEmpty) return;
    final raw = _requireRaw;
    final maximumLength = raw.maximumTlsFragmentLength;
    for (var offset = 0; offset < data.length; offset += maximumLength) {
      final end = min(offset + maximumLength, data.length);
      await raw.writeTlsFragment(
        offset == 0 && end == data.length ? data : data.sublist(offset, end),
      );
    }
  }

  void _failPendingFragmentWrites(Object error, [StackTrace? stackTrace]) {
    final pending = _pendingFragmentWrites.toList(growable: false);
    _pendingFragmentWrites.clear();
    for (final command in pending) {
      if (!command.completer.isCompleted) {
        command.completer.completeError(error, stackTrace);
      }
    }
  }

  void _ensureRawSubscription() {
    final raw = _raw;
    if (_rawSubscription == null && raw != null) {
      _rawSubscription = raw.listen(
        _onRawEvent,
        onError: _onRawError,
        onDone: _onRawDone,
        cancelOnError: true,
      );
    }
  }

  void _onRawEvent(RawSocketEvent event) {
    switch (event) {
      case RawSocketEvent.read:
        final data = _raw?.read();
        if (data != null) _controller.add(data);
        break;
      case RawSocketEvent.readClosed:
        _closeController();
        break;
      case RawSocketEvent.write:
      case RawSocketEvent.closed:
        break;
    }
  }

  void _onRawError(Object error, StackTrace stackTrace) {
    if (!_controllerClosed) {
      _controllerClosed = true;
      _controller.addError(error, stackTrace);
      _controller.close();
    }
    _failPendingFragmentWrites(error, stackTrace);
    _consumer.done(error, stackTrace);
  }

  void _onRawDone() {
    _closeController();
    _consumer.done();
  }

  void _closeController() {
    if (_controllerClosed) return;
    _controllerClosed = true;
    _controller.close();
  }

  void _onSubscriptionStateChange() {
    final raw = _raw;
    if (_controller.hasListener) {
      _ensureRawSubscription();
      raw?.readEventsEnabled = true;
    } else {
      _controllerClosed = true;
      raw?.shutdown(SocketDirection.receive);
    }
  }

  void _onPauseStateChange() {
    _raw?.readEventsEnabled = !_controller.isPaused;
  }

  void _consumerDone() {
    final raw = _raw;
    if (raw != null) raw.shutdown(SocketDirection.send);
  }

  @override
  StreamSubscription<Uint8List> listen(
    void Function(Uint8List event)? onData, {
    Function? onError,
    void Function()? onDone,
    bool? cancelOnError,
  }) {
    return _controller.stream.listen(
      onData,
      onError: onError,
      onDone: onDone,
      cancelOnError: cancelOnError,
    );
  }

  @override
  Encoding get encoding => _sink.encoding;

  @override
  set encoding(Encoding value) => _sink.encoding = value;

  /// Converts [object] with [Object.toString], encodes it using [encoding], and
  /// adds the bytes to the serialized fragment queue.
  @override
  void write(Object? object) => _sink.write(object);

  /// Writes [object] followed by a line terminator through the serialized
  /// fragment queue.
  @override
  void writeln([Object? object = '']) => _sink.writeln(object);

  /// Encodes [charCode] using [encoding] and adds it to the serialized fragment
  /// queue.
  @override
  void writeCharCode(int charCode) => _sink.writeCharCode(charCode);

  /// Writes [objects], separated by [separator], through the serialized
  /// fragment queue.
  @override
  void writeAll(Iterable<Object?> objects, [String separator = '']) =>
      _sink.writeAll(objects, separator);

  /// Adds [data] to the serialized fragment queue.
  ///
  /// Unlike [writeTlsFragment], this method does not expose completion for this
  /// specific input and automatically splits oversized input. Use [flush] to
  /// wait for this and all preceding queued output.
  @override
  void add(List<int> data) => _sink.add(data);

  @override
  void addError(Object error, [StackTrace? stackTrace]) {
    throw UnsupportedError('Cannot send errors on sockets');
  }

  /// Adds every chunk from [stream] to the serialized fragment queue.
  ///
  /// The stream is consumed with backpressure while each chunk is submitted.
  /// Chunks larger than [maximumTlsFragmentLength] are split automatically.
  @override
  Future<void> addStream(Stream<List<int>> stream) => _sink.addStream(stream);

  /// Completes after all previously queued plaintext and generated ciphertext
  /// have drained to the underlying raw socket.
  @override
  Future<void> flush() => _sink.flush();

  /// Finishes queued output and then closes the sending side of the socket.
  @override
  Future<void> close() => _sink.close();

  /// Completes when the output sink closes, or with its terminal error.
  @override
  Future<void> get done => _sink.done;

  /// Immediately closes the socket and fails pending fragment operations.
  @override
  void destroy() {
    final raw = _raw;
    if (raw == null) return;
    _raw = null;
    _consumer.stop();
    _failPendingFragmentWrites(const SocketException.closed());
    _rawSubscription?.cancel();
    raw.close();
    _closeController();
  }

  @override
  bool setOption(SocketOption option, bool enabled) =>
      _requireRaw.setOption(option, enabled);

  @override
  Uint8List getRawOption(RawSocketOption option) =>
      _requireRaw.getRawOption(option);

  @override
  void setRawOption(RawSocketOption option) => _requireRaw.setRawOption(option);

  @override
  int get port => _requireRaw.port;

  @override
  InternetAddress get address => _requireRaw.address;

  @override
  int get remotePort => _requireRaw.remotePort;

  @override
  InternetAddress get remoteAddress => _requireRaw.remoteAddress;

  @override
  X509Certificate? get peerCertificate => _requireRaw.peerCertificate;

  @override
  String? get selectedProtocol => _requireRaw.selectedProtocol;

  @override
  void renegotiate({
    bool useSessionCache = true,
    bool requestClientCertificate = false,
    bool requireClientCertificate = false,
  }) {
    // RawSecureSocket exposes this deprecated operation, so the wrapper keeps
    // interface parity even though the SDK currently implements it as a no-op.
    // ignore: deprecated_member_use
    _requireRaw.renegotiate(
      useSessionCache: useSessionCache,
      requestClientCertificate: requestClientCertificate,
      requireClientCertificate: requireClientCertificate,
    );
  }
}

final class _TlsFragmentWrite {
  final Uint8List bytes;
  final Completer<void> completer = Completer<void>();

  _TlsFragmentWrite(this.bytes);
}

final class _TlsFragmentStreamConsumer implements StreamConsumer<List<int>> {
  final TlsFragmentSecureSocket socket;
  StreamSubscription<List<int>>? _subscription;
  Completer<TlsFragmentSecureSocket>? _streamCompleter;

  _TlsFragmentStreamConsumer(this.socket);

  @override
  Future<TlsFragmentSecureSocket> addStream(Stream<List<int>> stream) {
    socket._ensureRawSubscription();
    final completer = _streamCompleter = Completer<TlsFragmentSecureSocket>();
    if (socket._raw == null) {
      done();
      return completer.future;
    }

    _subscription = stream.listen(
      (data) {
        final subscription = _subscription!;
        subscription.pause();
        socket._writeSinkData(data).then(
          (_) => _subscription?.resume(),
          onError: (Object error, StackTrace stackTrace) {
            socket._failPendingFragmentWrites(error, stackTrace);
            socket.destroy();
            stop();
            done(error, stackTrace);
          },
        );
      },
      onError: (Object error, StackTrace stackTrace) {
        socket._failPendingFragmentWrites(error, stackTrace);
        socket.destroy();
        done(error, stackTrace);
      },
      onDone: done,
      cancelOnError: true,
    );
    return completer.future;
  }

  @override
  Future<TlsFragmentSecureSocket> close() {
    socket._consumerDone();
    return Future<TlsFragmentSecureSocket>.value(socket);
  }

  void done([Object? error, StackTrace? stackTrace]) {
    final completer = _streamCompleter;
    if (completer == null) return;
    _streamCompleter = null;
    _subscription = null;
    if (error == null) {
      completer.complete(socket);
    } else {
      completer.completeError(error, stackTrace);
    }
  }

  void stop() {
    _subscription?.cancel();
    _subscription = null;
    socket._failPendingFragmentWrites(const SocketException.closed());
  }
}
