import 'dart:ffi';
import 'dart:typed_data';

import 'package:ffi/ffi.dart';

import 'native_tls_loader.dart';

final class _MssqlTlsConfig extends Struct {
  external Pointer<Utf8> serverName;
  external Pointer<Utf8> caFile;
  external Pointer<Utf8> caPath;
  @Int32()
  external int trustServerCertificate;
  @Int32()
  external int verifyHostname;
  @Size()
  external int maximumPlaintextPacket;
}

/// Minimal FFI owner for one OpenSSL memory-BIO TLS session.
final class NativeTlsEngine implements Finalizable {
  static final _finalizer = NativeFinalizer(
    loadMssqlTls()
        .lookup<NativeFunction<Void Function(Pointer<Void>)>>(
          'mssql_tls_destroy',
        )
        .cast(),
  );

  final DynamicLibrary _library;
  late final Pointer<Void> _handle;
  late final Pointer<NativeFunction<Void Function(Pointer<Void>)>> _destroy;
  late final int Function(Pointer<Void>, Pointer<Uint8>, int, Pointer<IntPtr>)
      _feedEncrypted;
  late final int Function(Pointer<Void>, Pointer<Uint8>, int, Pointer<IntPtr>)
      _drainEncrypted;
  late final int Function(Pointer<Void>, Pointer<Uint8>, int) _writePacket;
  late final int Function(Pointer<Void>) _retryWrite;
  late final int Function(Pointer<Void>, Pointer<Uint8>, int, Pointer<IntPtr>)
      _readPlaintext;

  NativeTlsEngine({
    required String serverName,
    required bool trustServerCertificate,
  }) : _library = loadMssqlTls() {
    final create = _library.lookupFunction<
        Pointer<Void> Function(Pointer<_MssqlTlsConfig>),
        Pointer<Void> Function(Pointer<_MssqlTlsConfig>)>('mssql_tls_create');
    final config = calloc<_MssqlTlsConfig>();
    final name = serverName.toNativeUtf8();
    try {
      config.ref
        ..serverName = name
        ..caFile = nullptr
        ..caPath = nullptr
        ..trustServerCertificate = trustServerCertificate ? 1 : 0
        ..verifyHostname = trustServerCertificate ? 0 : 1
        ..maximumPlaintextPacket = 16383;
      _handle = create(config);
      if (_handle == nullptr) {
        throw StateError('Unable to create native SQL Server TLS session.');
      }
      _destroy = _library.lookup('mssql_tls_destroy');
      _feedEncrypted = _library.lookupFunction<
          Int32 Function(Pointer<Void>, Pointer<Uint8>, Size, Pointer<IntPtr>),
          int Function(Pointer<Void>, Pointer<Uint8>, int,
              Pointer<IntPtr>)>('mssql_tls_feed_encrypted');
      _drainEncrypted = _library.lookupFunction<
          Int32 Function(Pointer<Void>, Pointer<Uint8>, Size, Pointer<IntPtr>),
          int Function(Pointer<Void>, Pointer<Uint8>, int,
              Pointer<IntPtr>)>('mssql_tls_drain_encrypted');
      _writePacket = _library.lookupFunction<
          Int32 Function(Pointer<Void>, Pointer<Uint8>, Size),
          int Function(Pointer<Void>, Pointer<Uint8>, int)>(
        'mssql_tls_write_packet',
      );
      _retryWrite = _library.lookupFunction<Int32 Function(Pointer<Void>),
          int Function(Pointer<Void>)>('mssql_tls_retry_write');
      _readPlaintext = _library.lookupFunction<
          Int32 Function(Pointer<Void>, Pointer<Uint8>, Size, Pointer<IntPtr>),
          int Function(Pointer<Void>, Pointer<Uint8>, int,
              Pointer<IntPtr>)>('mssql_tls_read_plaintext');
      _finalizer.attach(this, _handle, detach: this);
    } finally {
      calloc.free(name);
      calloc.free(config);
    }
  }

  /// Starts or continues the TLS handshake. The caller drains ciphertext after.
  int handshake() => _library.lookupFunction<Int32 Function(Pointer<Void>),
      int Function(Pointer<Void>)>('mssql_tls_handshake')(_handle);

  int feedEncrypted(Uint8List bytes) {
    final input = calloc<Uint8>(bytes.length);
    final consumed = calloc<IntPtr>();
    try {
      input.asTypedList(bytes.length).setAll(0, bytes);
      final code = _feedEncrypted(_handle, input, bytes.length, consumed);
      if (consumed.value != bytes.length) {
        throw StateError('Native TLS consumed only ${consumed.value} bytes.');
      }
      return code;
    } finally {
      calloc.free(consumed);
      calloc.free(input);
    }
  }

  Uint8List drainEncrypted({int capacity = 16384}) =>
      _read(_drainEncrypted, capacity);

  Uint8List readPlaintext({int capacity = 16384}) =>
      _read(_readPlaintext, capacity);

  int writePacket(Uint8List packet) {
    final input = calloc<Uint8>(packet.length);
    try {
      input.asTypedList(packet.length).setAll(0, packet);
      return _writePacket(_handle, input, packet.length);
    } finally {
      calloc.free(input);
    }
  }

  int retryWrite() => _retryWrite(_handle);

  Uint8List _read(
    int Function(Pointer<Void>, Pointer<Uint8>, int, Pointer<IntPtr>) call,
    int capacity,
  ) {
    final output = calloc<Uint8>(capacity);
    final written = calloc<IntPtr>();
    try {
      final code = call(_handle, output, capacity, written);
      if (code < 0) throw StateError('Native TLS read failed with code $code.');
      return Uint8List.fromList(output.asTypedList(written.value));
    } finally {
      calloc.free(written);
      calloc.free(output);
    }
  }

  void dispose() {
    _finalizer.detach(this);
    _destroy.asFunction<void Function(Pointer<Void>)>()(_handle);
  }
}
