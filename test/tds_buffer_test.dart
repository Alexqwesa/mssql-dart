import 'dart:typed_data';

import 'package:mssql/src/tds/buf.dart';
import 'package:mssql/src/tds/constants.dart';
import 'package:test/test.dart';

import 'helpers/tds_socket.dart';

/// Protocol unit tests for [TdsBuffer].
///
/// Sources:
/// - microsoft/go-mssqldb `buf_test.go` — write framing, header validation,
///   multi-packet uint16/32/64 reads
/// - kartikey321/mssql-dart PR #3 — leftover-byte discard when multi-byte reads
///   straddle TDS packet boundaries (regression cases below)
/// - Tedious `test/unit/packet-test.ts` — packet header / EOM patterns
void main() {
  group('TdsBuffer write framing', () {
    // go-mssqldb: TestWrite / TestWrite_BufferBounds
    test('single packet write matches go-mssqldb TestWrite layout', () async {
      final pair = await TdsSocketPair.open();
      addTearDown(pair.close);

      final received = BytesBuilder(copy: false);
      pair.server.listen(received.add);

      final buf = TdsBuffer(pair.client, packetSize: 11);
      buf.beginPacket(1);
      buf.writeByte(2);
      buf.writeBytes([3, 4]);
      await buf.finishPacket(1);

      await Future<void>.delayed(const Duration(milliseconds: 20));

      expect(
        received.toBytes(),
        equals([1, 1, 0, 11, 0, 0, 1, 0, 2, 3, 4]),
      );
    });

    // go-mssqldb: TestWrite multi-packet split when body exceeds packetSize
    test('multi-packet write splits when body exceeds packet body capacity',
        () async {
      final pair = await TdsSocketPair.open();
      addTearDown(pair.close);

      final received = BytesBuilder(copy: false);
      pair.server.listen(received.add);

      final buf = TdsBuffer(pair.client, packetSize: 11);
      buf.beginPacket(2);
      buf.writeBytes([3, 4, 5, 6]);
      await buf.finishPacket(2);

      await Future<void>.delayed(const Duration(milliseconds: 20));

      expect(
        received.toBytes(),
        equals([
          2, 0, 0, 11, 0, 0, 1, 0, 3, 4, 5,
          2, 1, 0, 9, 0, 0, 2, 0, 6,
        ]),
      );
    });
  });

  group('TdsBuffer read — header validation', () {
    // go-mssqldb: TestStreamShorterThanHeader
    test('BeginRead fails when stream is shorter than header', () async {
      final pair = await TdsSocketPair.open();
      addTearDown(pair.close);

      await tdsSend(pair.server, Uint8List.fromList([0xFF, 0xFF]));
      pair.server.destroy();

      final buf = TdsBuffer(pair.client, packetSize: 100);
      await expectLater(buf.beginRead(), throwsA(isA<StateError>()));
    });

    // go-mssqldb: TestBeginReadSucceeds
    test('BeginRead succeeds and ReadByte returns payload', () async {
      final pair = await TdsSocketPair.open();
      addTearDown(pair.close);

      await tdsSend(pair.server, tdsPacket(type: 0x01, body: [0x02]));

      final buf = TdsBuffer(pair.client, packetSize: 9);
      final id = await buf.beginRead();
      expect(id, equals(1));
      expect(await buf.readUint8(), equals(2));
      await expectLater(buf.readUint8(), throwsA(isA<StateError>()));
    });
  });

  group('TdsBuffer read — multi-byte spanning packet boundaries', () {
    // mssql-dart PR #3 + go-mssqldb uint16/32/64 read paths across packets
    test('readUint16LE across two packets (PR #3 regression)', () async {
      final pair = await TdsSocketPair.open();
      addTearDown(pair.close);

      await tdsSend(
        pair.server,
        tdsPacket(type: packReply, body: [0x34], eom: false, seq: 1),
      );
      await tdsSend(
        pair.server,
        tdsPacket(type: packReply, body: [0x12], eom: true, seq: 2),
      );

      final buf = TdsBuffer(pair.client, packetSize: 9);
      await buf.beginRead();
      expect(await buf.readUint16LE(), equals(0x1234));
    });

    test('readUint16BE across two packets', () async {
      final pair = await TdsSocketPair.open();
      addTearDown(pair.close);

      await tdsSend(
        pair.server,
        tdsPacket(type: packReply, body: [0xAB], eom: false, seq: 1),
      );
      await tdsSend(
        pair.server,
        tdsPacket(type: packReply, body: [0xCD], eom: true, seq: 2),
      );

      final buf = TdsBuffer(pair.client, packetSize: 9);
      await buf.beginRead();
      expect(await buf.readUint16BE(), equals(0xABCD));
    });

    test('readUint32LE across three packets', () async {
      final pair = await TdsSocketPair.open();
      addTearDown(pair.close);

      await tdsSend(
        pair.server,
        tdsPacket(type: packReply, body: [0x12], eom: false, seq: 1),
      );
      await tdsSend(
        pair.server,
        tdsPacket(type: packReply, body: [0x34, 0x56], eom: false, seq: 2),
      );
      await tdsSend(
        pair.server,
        tdsPacket(type: packReply, body: [0x78], eom: true, seq: 3),
      );

      final buf = TdsBuffer(pair.client, packetSize: 9);
      await buf.beginRead();
      expect(await buf.readUint32LE(), equals(0x78563412));
    });

    test('readUint64LE straddling mid-value packet boundary', () async {
      final pair = await TdsSocketPair.open();
      addTearDown(pair.close);

      await tdsSend(
        pair.server,
        tdsPacket(
          type: packReply,
          body: [0x01, 0x02, 0x03],
          eom: false,
          seq: 1,
        ),
      );
      await tdsSend(
        pair.server,
        tdsPacket(
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
      final pair = await TdsSocketPair.open();
      addTearDown(pair.close);

      await tdsSend(
        pair.server,
        tdsPacket(type: packReply, body: [0xDE, 0xAD], eom: false, seq: 1),
      );
      await tdsSend(
        pair.server,
        tdsPacket(type: packReply, body: [0xBE, 0xEF], eom: true, seq: 2),
      );

      final buf = TdsBuffer(pair.client, packetSize: 16);
      await buf.beginRead();
      expect(await buf.readBytes(4), equals([0xDE, 0xAD, 0xBE, 0xEF]));
    });

    // PR #3: token byte left in buffer + length prefix straddling next packet
    test('token byte then straddling length prefix stays synced', () async {
      final pair = await TdsSocketPair.open();
      addTearDown(pair.close);

      await tdsSend(
        pair.server,
        tdsPacket(
          type: packReply,
          body: [tokenNbcRow, 0x04],
          eom: false,
          seq: 1,
        ),
      );
      await tdsSend(
        pair.server,
        tdsPacket(
          type: packReply,
          body: [0x00, 0xAA, 0xBB, 0xCC, 0xDD],
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
      final pair = await TdsSocketPair.open();
      addTearDown(pair.close);

      await tdsSend(
        pair.server,
        tdsPacket(type: packReply, body: [1, 2, 3], eom: false, seq: 1),
      );
      await tdsSend(
        pair.server,
        tdsPacket(type: packReply, body: [4, 5], eom: true, seq: 2),
      );

      final buf = TdsBuffer(pair.client, packetSize: 16);
      await buf.beginRead();
      expect(await buf.readAll(), equals([1, 2, 3, 4, 5]));
    });
  });

  group('TdsBuffer Attention packet', () {
    // ms-tds §2.2.1.7 Attention; go-mssqldb sendAttention — empty body, type 6
    test('empty Attention packet is header-only EOM', () async {
      final pair = await TdsSocketPair.open();
      addTearDown(pair.close);

      final received = BytesBuilder(copy: false);
      pair.server.listen(received.add);

      final buf = TdsBuffer(pair.client, packetSize: 4096);
      await buf.sendAttention();

      await Future<void>.delayed(const Duration(milliseconds: 20));

      expect(
        received.toBytes(),
        equals([packAttention, 1, 0, 8, 0, 0, 1, 0]),
      );
    });
  });
}
