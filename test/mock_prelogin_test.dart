import 'dart:io';
import 'dart:typed_data';

import 'package:async/async.dart';
import 'package:mssql/src/tds/buf.dart';
import 'package:mssql/src/tds/constants.dart';
import 'package:mssql/src/tds/prelogin.dart';
import 'package:test/test.dart';

/// Mock-server PreLogin tests inspired by microsoft/go-mssqldb
/// `bad_server_test.go` — no live SQL Server required.

class _SocketPair {
  _SocketPair(this.client, this.server, this._listener);

  final Socket client;
  final Socket server;
  final ServerSocket _listener;

  static Future<_SocketPair> open() async {
    final listener = await ServerSocket.bind(InternetAddress.loopbackIPv4, 0);
    final clientFuture = Socket.connect(listener.address, listener.port);
    final server = await listener.first;
    final client = await clientFuture;
    return _SocketPair(client, server, listener);
  }

  Future<void> close() async {
    try {
      client.destroy();
    } catch (_) {}
    try {
      server.destroy();
    } catch (_) {}
    await _listener.close();
  }
}

/// Build a PRELOGIN response body (option table + values + terminator).
Uint8List _preloginBody(Map<int, List<int>> fields) {
  final keys = fields.keys.toList()..sort();
  final headerLen = keys.length * 5 + 1;
  var offset = headerLen;
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

Uint8List _tdsPacket({
  required int type,
  required List<int> body,
  bool eom = true,
}) {
  final total = headerSize + body.length;
  final pkt = Uint8List(total);
  pkt[0] = type;
  pkt[1] = eom ? statusEOM : statusNormal;
  pkt[2] = (total >> 8) & 0xFF;
  pkt[3] = total & 0xFF;
  pkt[6] = 1;
  pkt.setRange(headerSize, total, body);
  return pkt;
}

Future<void> _drainPreloginRequest(ChunkedStreamReader<int> reader) async {
  // Read TDS header then body for the client PRELOGIN.
  final hdr = await reader.readChunk(headerSize);
  expect(hdr.length, equals(headerSize));
  expect(hdr[0], equals(packPrelogin));
  final size = (hdr[2] << 8) | hdr[3];
  final bodyLen = size - headerSize;
  if (bodyLen > 0) {
    final body = await reader.readChunk(bodyLen);
    expect(body.length, equals(bodyLen));
  }
}

void main() {
  group('PreLogin mock server (encrypt not supported)', () {
    test('client send + read negotiates encryptNotSupported', () async {
      final pair = await _SocketPair.open();
      addTearDown(pair.close);
      final serverReader = ChunkedStreamReader(pair.server);

      // Server side: drain PRELOGIN request, reply with ENCRYPTION=not supported.
      final serverDone = () async {
        await _drainPreloginRequest(serverReader);
        final body = _preloginBody({
          preloginEncryption: [encryptNotSupported],
        });
        pair.server.add(_tdsPacket(type: packReply, body: body));
        await pair.server.flush();
      }();

      final buf = TdsBuffer(pair.client);
      await Prelogin.send(buf, requestEncrypt: encryptNotSupported);
      final result = await Prelogin.read(buf);
      await serverDone;

      expect(result.encryption, equals(encryptNotSupported));
      expect(result.requiresTls, isFalse);
      expect(result.fedAuthRequired, isFalse);
    });

    test('server advertising encryptOn sets requiresTls', () async {
      final pair = await _SocketPair.open();
      addTearDown(pair.close);
      final serverReader = ChunkedStreamReader(pair.server);

      final serverDone = () async {
        await _drainPreloginRequest(serverReader);
        final body = _preloginBody({
          preloginVersion: [0x0F, 0x00, 0x00, 0x00, 0x00, 0x00],
          preloginEncryption: [encryptOn],
        });
        pair.server.add(_tdsPacket(type: packReply, body: body));
        await pair.server.flush();
      }();

      final buf = TdsBuffer(pair.client);
      await Prelogin.send(buf, requestEncrypt: encryptOn);
      final result = await Prelogin.read(buf);
      await serverDone;

      expect(result.encryption, equals(encryptOn));
      expect(result.requiresTls, isTrue);
    });

    test('fedAuthRequired flag is parsed from server response', () async {
      final pair = await _SocketPair.open();
      addTearDown(pair.close);
      final serverReader = ChunkedStreamReader(pair.server);

      final serverDone = () async {
        await _drainPreloginRequest(serverReader);
        final body = _preloginBody({
          preloginEncryption: [encryptNotSupported],
          preloginFedAuthRequired: [0x01],
        });
        pair.server.add(_tdsPacket(type: packReply, body: body));
        await pair.server.flush();
      }();

      final buf = TdsBuffer(pair.client);
      await Prelogin.send(buf, fedAuthRequired: true);
      final result = await Prelogin.read(buf);
      await serverDone;

      expect(result.fedAuthRequired, isTrue);
    });
  });

  group('PreLogin bad server responses', () {
    test('wrong packet type throws StateError', () async {
      final pair = await _SocketPair.open();
      addTearDown(pair.close);
      final serverReader = ChunkedStreamReader(pair.server);

      final serverDone = () async {
        await _drainPreloginRequest(serverReader);
        // Reply with LOGIN7 type instead of tabular/reply — like bad_server.
        pair.server.add(
          _tdsPacket(type: packLogin7, body: [0x00]),
        );
        await pair.server.flush();
      }();

      final buf = TdsBuffer(pair.client);
      await Prelogin.send(buf, requestEncrypt: encryptNotSupported);
      await expectLater(Prelogin.read(buf), throwsA(isA<StateError>()));
      await serverDone;
    });

    test('empty PRELOGIN option table still yields defaults', () async {
      // go-mssqldb rejects empty prelogin in some paths; our parser returns
      // encryptNotSupported when the encryption field is absent — document that.
      final pair = await _SocketPair.open();
      addTearDown(pair.close);
      final serverReader = ChunkedStreamReader(pair.server);

      final serverDone = () async {
        await _drainPreloginRequest(serverReader);
        // Terminator only — no options.
        pair.server.add(
          _tdsPacket(type: packReply, body: [preloginTerminator]),
        );
        await pair.server.flush();
      }();

      final buf = TdsBuffer(pair.client);
      await Prelogin.send(buf, requestEncrypt: encryptNotSupported);
      final result = await Prelogin.read(buf);
      await serverDone;

      expect(result.encryption, equals(encryptNotSupported));
      expect(result.fedAuthRequired, isFalse);
    });

    test('invalid token id after login-shaped reply is readable as bytes',
        () async {
      // Mirrors TestBadServerInvalidTokenId shape: after a good PRELOGIN,
      // server would send an invalid token. Here we only assert the client
      // can finish PRELOGIN then read a raw reply packet with token 0x00.
      final pair = await _SocketPair.open();
      addTearDown(pair.close);
      final serverReader = ChunkedStreamReader(pair.server);

      final serverDone = () async {
        await _drainPreloginRequest(serverReader);
        final body = _preloginBody({
          preloginEncryption: [encryptNotSupported],
        });
        pair.server.add(_tdsPacket(type: packReply, body: body));
        await pair.server.flush();

        // Fake login-ack path: tabular packet with invalid token id 0x00.
        pair.server.add(_tdsPacket(type: packReply, body: [0x00]));
        await pair.server.flush();
      }();

      final buf = TdsBuffer(pair.client);
      await Prelogin.send(buf, requestEncrypt: encryptNotSupported);
      final result = await Prelogin.read(buf);
      expect(result.encryption, equals(encryptNotSupported));

      final pktType = await buf.beginRead();
      expect(pktType, equals(packReply));
      expect(await buf.readUint8(), equals(0x00));
      await serverDone;
    });
  });

  group('PreLogin client request framing', () {
    test('client PRELOGIN packet is type 0x12 with EOM', () async {
      final pair = await _SocketPair.open();
      addTearDown(pair.close);
      final serverReader = ChunkedStreamReader(pair.server);

      final buf = TdsBuffer(pair.client);
      await Prelogin.send(buf, requestEncrypt: encryptNotSupported);

      final hdr = await serverReader.readChunk(headerSize);
      expect(hdr[0], equals(packPrelogin));
      expect(hdr[1] & statusEOM, equals(statusEOM));
      final size = (hdr[2] << 8) | hdr[3];
      expect(size, greaterThan(headerSize));
      final bodyLen = size - headerSize;
      if (bodyLen > 0) {
        final body = await serverReader.readChunk(bodyLen);
        expect(body.length, equals(bodyLen));
      }
    });
  });
}
