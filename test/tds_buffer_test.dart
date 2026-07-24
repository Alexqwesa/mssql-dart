import 'dart:io';
import 'dart:typed_data';

import 'package:mssql/src/tds/buf.dart';
import 'package:mssql/src/tds/constants.dart';
import 'package:test/test.dart';

/// Protocol unit tests for [TdsBuffer], ported from microsoft/go-mssqldb
/// `buf_test.go` patterns — especially multi-byte reads that straddle TDS
/// packet boundaries (the PR #3 corruption class).
///
/// Uses a localhost TCP pair so framing is exercised end-to-end without SQL Server.

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

/// Build a TDS packet: 8-byte header + [body].
Uint8List _packet({
  required int type,
  required List<int> body,
  bool eom = true,
  int seq = 1,
}) {
  final total = headerSize + body.length;
  final pkt = Uint8List(total);
  pkt[0] = type;
  pkt[1] = eom ? statusEOM : statusNormal;
  pkt[2] = (total >> 8) & 0xFF;
  pkt[3] = total & 0xFF;
  pkt[4] = 0;
  pkt[5] = 0;
  pkt[6] = seq & 0xFF;
  pkt[7] = 0;
  pkt.setRange(headerSize, total, body);
  return pkt;
}

Future<void> _send(Socket sock, Uint8List data) async {
  sock.add(data);
  await sock.flush();
}

void main() {
  group('TdsBuffer write framing', () {
    test('single packet write matches go-mssqldb TestWrite layout', () async {
      final pair = await _SocketPair.open();
      addTearDown(pair.close);

      final received = BytesBuilder(copy: false);
      pair.server.listen(received.add);

      final buf = TdsBuffer(pair.client, packetSize: 11);
      buf.beginPacket(1);
      buf.writeByte(2);
      buf.writeBytes([3, 4]);
      await buf.finishPacket(1);

      // Allow the server to drain.
      await Future<void>.delayed(const Duration(milliseconds: 20));

      expect(
        received.toBytes(),
        equals([1, 1, 0, 11, 0, 0, 1, 0, 2, 3, 4]),
      );
    });

    test('multi-packet write splits when body exceeds packet body capacity',
        () async {
      final pair = await _SocketPair.open();
      addTearDown(pair.close);

      final received = BytesBuilder(copy: false);
      pair.server.listen(received.add);

      // packetSize 11 → body capacity 3 bytes.
      final buf = TdsBuffer(pair.client, packetSize: 11);
      buf.beginPacket(2);
      buf.writeBytes([3, 4, 5, 6]);
      await buf.finishPacket(2);

      await Future<void>.delayed(const Duration(milliseconds: 20));

      expect(
        received.toBytes(),
        equals([
          // packet 1: type 2, not EOM, size 11, body 3,4,5
          2, 0, 0, 11, 0, 0, 1, 0, 3, 4, 5,
          // packet 2: type 2, EOM, size 9, body 6
          2, 1, 0, 9, 0, 0, 2, 0, 6,
        ]),
      );
    });
  });

  group('TdsBuffer read — header validation', () {
    test('BeginRead fails when stream is shorter than header', () async {
      final pair = await _SocketPair.open();
      addTearDown(pair.close);

      await _send(pair.server, Uint8List.fromList([0xFF, 0xFF]));
      pair.server.destroy();

      final buf = TdsBuffer(pair.client, packetSize: 100);
      await expectLater(buf.beginRead(), throwsA(isA<StateError>()));
    });

    test('BeginRead succeeds and ReadByte returns payload', () async {
      final pair = await _SocketPair.open();
      addTearDown(pair.close);

      await _send(
        pair.server,
        _packet(type: 0x01, body: [0x02]),
      );

      final buf = TdsBuffer(pair.client, packetSize: 9);
      final id = await buf.beginRead();
      expect(id, equals(1));
      expect(await buf.readUint8(), equals(2));
      await expectLater(buf.readUint8(), throwsA(isA<StateError>()));
    });
  });

  group('TdsBuffer read — multi-byte spanning packet boundaries', () {
    test('readUint16LE across two packets (PR #3 regression)', () async {
      final pair = await _SocketPair.open();
      addTearDown(pair.close);

      // First packet: 1 body byte left for the uint16; second supplies the rest.
      // LE value 0x1234 → bytes 0x34, 0x12
      await _send(
        pair.server,
        _packet(type: packReply, body: [0x34], eom: false, seq: 1),
      );
      await _send(
        pair.server,
        _packet(type: packReply, body: [0x12], eom: true, seq: 2),
      );

      final buf = TdsBuffer(pair.client, packetSize: 9);
      await buf.beginRead();
      expect(await buf.readUint16LE(), equals(0x1234));
    });

    test('readUint16BE across two packets', () async {
      final pair = await _SocketPair.open();
      addTearDown(pair.close);

      // BE value 0xABCD → 0xAB, 0xCD
      await _send(
        pair.server,
        _packet(type: packReply, body: [0xAB], eom: false, seq: 1),
      );
      await _send(
        pair.server,
        _packet(type: packReply, body: [0xCD], eom: true, seq: 2),
      );

      final buf = TdsBuffer(pair.client, packetSize: 9);
      await buf.beginRead();
      expect(await buf.readUint16BE(), equals(0xABCD));
    });

    test('readUint32LE across three packets', () async {
      final pair = await _SocketPair.open();
      addTearDown(pair.close);

      // LE 0x78563412 → 12 34 56 78
      await _send(
        pair.server,
        _packet(type: packReply, body: [0x12], eom: false, seq: 1),
      );
      await _send(
        pair.server,
        _packet(type: packReply, body: [0x34, 0x56], eom: false, seq: 2),
      );
      await _send(
        pair.server,
        _packet(type: packReply, body: [0x78], eom: true, seq: 3),
      );

      final buf = TdsBuffer(pair.client, packetSize: 9);
      await buf.beginRead();
      expect(await buf.readUint32LE(), equals(0x78563412));
    });

    test('readUint64LE straddling mid-value packet boundary', () async {
      final pair = await _SocketPair.open();
      addTearDown(pair.close);

      // LE 0x0807060504030201 → 01..08
      await _send(
        pair.server,
        _packet(
          type: packReply,
          body: [0x01, 0x02, 0x03],
          eom: false,
          seq: 1,
        ),
      );
      await _send(
        pair.server,
        _packet(
          type: packReply,
          body: [0x04, 0x05, 0x06, 0x07, 0x08],
          eom: true,
          seq: 2,
        ),
      );

      final buf = TdsBuffer(pair.client, packetSize: 16);
      await buf.beginRead();
      expect(await buf.readUint64LE(), equals(0x0807060504030201));
    });

    test('readBytes spanning packets preserves all bytes', () async {
      final pair = await _SocketPair.open();
      addTearDown(pair.close);

      await _send(
        pair.server,
        _packet(type: packReply, body: [0xDE, 0xAD], eom: false, seq: 1),
      );
      await _send(
        pair.server,
        _packet(type: packReply, body: [0xBE, 0xEF], eom: true, seq: 2),
      );

      final buf = TdsBuffer(pair.client, packetSize: 16);
      await buf.beginRead();
      expect(await buf.readBytes(4), equals([0xDE, 0xAD, 0xBE, 0xEF]));
    });

    test('token byte then straddling length prefix stays synced', () async {
      // Realistic failure mode from PR #3: NBCROW token (0xD2) left in buffer,
      // then a uint16 length straddles the next packet — leftover must not be
      // discarded or the length becomes garbage.
      final pair = await _SocketPair.open();
      addTearDown(pair.close);

      await _send(
        pair.server,
        _packet(
          type: packReply,
          body: [tokenNbcRow, 0x04], // token + first length byte
          eom: false,
          seq: 1,
        ),
      );
      await _send(
        pair.server,
        _packet(
          type: packReply,
          body: [0x00, 0xAA, 0xBB, 0xCC, 0xDD], // length hi + 4 payload
          eom: true,
          seq: 2,
        ),
      );

      final buf = TdsBuffer(pair.client, packetSize: 16);
      await buf.beginRead();
      expect(await buf.readUint8(), equals(tokenNbcRow));
      expect(await buf.readUint16LE(), equals(4));
      expect(await buf.readBytes(4), equals([0xAA, 0xBB, 0xCC, 0xDD]));
    });
  });

  group('TdsBuffer readAll', () {
    test('concatenates multi-packet message body', () async {
      final pair = await _SocketPair.open();
      addTearDown(pair.close);

      await _send(
        pair.server,
        _packet(type: packReply, body: [1, 2, 3], eom: false, seq: 1),
      );
      await _send(
        pair.server,
        _packet(type: packReply, body: [4, 5], eom: true, seq: 2),
      );

      final buf = TdsBuffer(pair.client, packetSize: 16);
      await buf.beginRead();
      expect(await buf.readAll(), equals([1, 2, 3, 4, 5]));
    });
  });
}
