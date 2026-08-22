import 'dart:collection';
import 'dart:typed_data';

import 'package:async/async.dart';
import 'package:mssql/src/native_tls/native_tls_engine.dart';
import 'package:mssql/src/native_tls/native_tls_transport.dart';
import 'package:test/test.dart';

import 'helpers/tds_socket.dart';

void main() {
  test('write queued during runner completion is not stranded', () async {
    final pair = await TdsSocketPair.open();
    final engine = _ScriptedTlsDriver();
    final transport = NativeTlsTransport(
      socket: pair.client,
      reader: ChunkedStreamReader(pair.client),
      engine: engine,
    );
    final plaintextSubscription = transport.plaintext.listen((_) {});
    addTearDown(() async {
      await transport.close();
      await plaintextSubscription.cancel();
      await pair.close();
    });

    await transport
        .writePacket(Uint8List.fromList([1]))
        .timeout(const Duration(seconds: 1));
    await transport
        .writePacket(Uint8List.fromList([2]))
        .timeout(const Duration(seconds: 1));

    expect(engine.writes, 2);
    expect(engine.overlapped, isFalse);
  });
}

final class _ScriptedTlsDriver implements NativeTlsDriver {
  final Queue<Uint8List> _encrypted = Queue();
  var _insideCall = false;
  var overlapped = false;
  var writes = 0;

  T _call<T>(T Function() body) {
    if (_insideCall) overlapped = true;
    _insideCall = true;
    try {
      return body();
    } finally {
      _insideCall = false;
    }
  }

  @override
  NativeTlsRead drainEncrypted({int capacity = 16384}) => _call(() {
        if (_encrypted.isEmpty) return NativeTlsRead(0, Uint8List(0));
        return NativeTlsRead(0, _encrypted.removeFirst());
      });

  @override
  NativeTlsFeed feedEncrypted(Uint8List bytes) =>
      _call(() => NativeTlsFeed(0, bytes.length));

  @override
  int handshake() => 3;

  @override
  bool get hasPendingWrite => false;

  @override
  String lastError() => '';

  @override
  Uint8List peerCertificateDer() => Uint8List(0);

  @override
  NativeTlsRead readPlaintext({int capacity = 16384}) =>
      NativeTlsRead(1, Uint8List(0));

  @override
  int retryWrite() => -4;

  @override
  int writePacket(Uint8List packet) => _call(() {
        writes++;
        _encrypted.add(Uint8List.fromList(packet));
        return 0;
      });

  @override
  void dispose() {}
}
