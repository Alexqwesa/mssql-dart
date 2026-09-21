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
  for (final key in keys) {
    final value = fields[key]!;
    header
      ..addByte(key)
      ..addByte((offset >> 8) & 0xff)
      ..addByte(offset & 0xff)
      ..addByte((value.length >> 8) & 0xff)
      ..addByte(value.length & 0xff);
    values.add(value);
    offset += value.length;
  }
  header.addByte(preloginTerminator);
  return Uint8List.fromList(<int>[...header.toBytes(), ...values.toBytes()]);
}

Future<void> _readPacket(
  ChunkedStreamReader<int> reader,
  int expectedType,
) async {
  final header = await reader.readChunk(headerSize);
  expect(header[0], expectedType);
  final bodyLength = ((header[2] << 8) | header[3]) - headerSize;
  if (bodyLength > 0) {
    expect((await reader.readChunk(bodyLength)).length, bodyLength);
  }
}

void main() {
  test('encrypt false rejects a server that requires TLS', () async {
    final listener = await ServerSocket.bind(InternetAddress.loopbackIPv4, 0);
    addTearDown(listener.close);

    final serverDone = () async {
      final server = await listener.first;
      try {
        final reader = ChunkedStreamReader(server);
        await _readPacket(reader, packPrelogin);
        server.add(
          tdsPacket(
            type: packReply,
            body: _preloginBody(<int, List<int>>{
              preloginEncryption: <int>[encryptRequired],
            }),
          ),
        );
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
          (error) => error.message,
          'message',
          contains('Server requires encryption'),
        ),
      ),
    );
    await serverDone;
  });

  test('bridge unwraps handshake packets then forwards opaque TLS', () async {
    final feed = await TdsSocketPair.open();
    final output = await TdsSocketPair.open();
    addTearDown(feed.close);
    addTearDown(output.close);

    final received = <int>[];
    final outputDone = Completer<void>();
    output.server.listen(
      received.addAll,
      onDone: outputDone.complete,
      onError: outputDone.completeError,
    );

    var handshakeDone = false;
    final bridgeDone = TdsTlsBridge.bridgeReadLoopForTest(
      rawReader: ChunkedStreamReader(feed.client),
      bridgeSide: output.client,
      isHandshakeDone: () => handshakeDone,
      onAbnormal: () => fail('bridge reported an abnormal stream'),
    );

    final handshake = Uint8List.fromList(<int>[
      0x16,
      0x03,
      0x03,
      0x00,
      0x02,
      0xaa,
      0xbb,
    ]);
    feed.server.add(tdsPacket(type: packPrelogin, body: handshake));
    await feed.server.flush();
    for (
      var attempt = 0;
      attempt < 50 && received.length < handshake.length;
      attempt++
    ) {
      await Future<void>.delayed(const Duration(milliseconds: 10));
    }
    expect(received, handshake);

    handshakeDone = true;
    received.clear();
    final first = <int>[0x17, 0x03, 0x03, 0x00, 0x01, 0xfe];
    final second = <int>[0x17, 0x03, 0x03, 0x00, 0x03, 1, 2, 3];
    feed.server
      ..add(first)
      ..add(second);
    await feed.server.flush();
    await feed.server.close();

    await bridgeDone.timeout(const Duration(seconds: 5));
    await outputDone.future.timeout(const Duration(seconds: 5));
    expect(received, <int>[...first, ...second]);
  });
}
