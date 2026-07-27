import 'dart:async';
import 'dart:io';
import 'dart:typed_data';

import 'package:async/async.dart';
import 'package:mssql/mssql.dart';
import 'package:mssql/src/tds/constants.dart';
import 'package:mssql/src/tds/tls_bridge.dart';
import 'package:test/test.dart';

import 'helpers/tds_socket.dart';

Uint8List _preloginBody(Map<int, List<int>> fields) {
  final keys = fields.keys.toList()..sort();
  var offset = keys.length * 5 + 1;
  final header = BytesBuilder(copy: false);
  final values = BytesBuilder(copy: false);
  for (final k in keys) {
    final v = fields[k]!;
    header.addByte(k);
    header.addByte((offset >> 8) & 0xFF);
    header.addByte(offset & 0xFF);
    header.addByte((v.length >> 8) & 0xFF);
    header.addByte(v.length & 0xFF);
    values.add(v);
    offset += v.length;
  }
  header.addByte(preloginTerminator);
  return Uint8List.fromList([...header.toBytes(), ...values.toBytes()]);
}

Future<void> _readPacket(
  ChunkedStreamReader<int> reader,
  int expectType,
) async {
  final hdr = await reader.readChunk(headerSize);
  expect(hdr[0], equals(expectType));
  final size = (hdr[2] << 8) | hdr[3];
  final bodyLen = size - headerSize;
  if (bodyLen > 0) {
    final body = await reader.readChunk(bodyLen);
    expect(body.length, equals(bodyLen));
  }
}

/// Offline TLS negotiation + bridge passthrough coverage (no live SQL).
void main() {
  group('encrypt negotiation via MssqlConnection', () {
    test('encrypt:false fails clearly when server requires TLS', () async {
      final listener = await ServerSocket.bind(InternetAddress.loopbackIPv4, 0);
      addTearDown(listener.close);

      final serverDone = () async {
        final server = await listener.first;
        try {
          final serverReader = ChunkedStreamReader(server);
          await _readPacket(serverReader, packPrelogin);
          server.add(tdsPacket(
            type: packReply,
            body: _preloginBody({
              preloginEncryption: [encryptRequired],
            }),
          ));
          await server.flush();
        } finally {
          server.destroy();
        }
      }();

      await expectLater(
        MssqlConnection.connect(
          host: InternetAddress.loopbackIPv4.address,
          port: listener.port,
          user: 'sa',
          password: 'Secret1',
          database: 'master',
          encrypt: false,
        ),
        throwsA(
          isA<MssqlException>().having(
            (e) => e.message,
            'message',
            contains('Server requires encryption'),
          ),
        ),
      );

      await serverDone;
    });
  });

  group('TdsTlsBridge opaque passthrough', () {
    test('handshake unwrap then opaque bytes survive', () async {
      // feed.server → feed.client (rawReader); bridge → out.client; listen out.server
      final feed = await TdsSocketPair.open();
      final out = await TdsSocketPair.open();
      addTearDown(feed.close);
      addTearDown(out.close);

      final rawReader = ChunkedStreamReader(feed.client);
      final received = <int>[];
      final done = Completer<void>();

      out.server.listen(
        (data) => received.addAll(data),
        onDone: () {
          if (!done.isCompleted) done.complete();
        },
        onError: (Object e, StackTrace st) {
          if (!done.isCompleted) done.completeError(e, st);
        },
      );

      var handshakeDone = false;
      final loop = TdsTlsBridge.bridgeReadLoopForTest(
        rawReader: rawReader,
        bridgeSide: out.client,
        isHandshakeDone: () => handshakeDone,
        onAbnormal: () {},
      );

      // Phase 1: PRELOGIN-wrapped fake TLS handshake bytes.
      final tlsHs =
          Uint8List.fromList([0x16, 0x03, 0x01, 0x00, 0x02, 0xAA, 0xBB]);
      feed.server.add(tdsPacket(type: packPrelogin, body: tlsHs));
      await feed.server.flush();

      for (var i = 0; i < 50 && received.length < tlsHs.length; i++) {
        await Future<void>.delayed(const Duration(milliseconds: 10));
      }
      expect(received, equals(tlsHs));

      // Phase 2: opaque passthrough (no TLS-record reparse).
      handshakeDone = true;
      received.clear();
      final opaque1 = Uint8List.fromList([0x17, 0x03, 0x03, 0x00, 0x01, 0xFE]);
      final opaque2 =
          Uint8List.fromList([0x17, 0x03, 0x03, 0x00, 0x03, 1, 2, 3]);
      feed.server.add(opaque1);
      feed.server.add(opaque2);
      await feed.server.flush();
      await feed.server.close();

      await loop.timeout(const Duration(seconds: 5));
      await done.future.timeout(const Duration(seconds: 5));

      expect(received, equals([...opaque1, ...opaque2]));
    });
  });
}
