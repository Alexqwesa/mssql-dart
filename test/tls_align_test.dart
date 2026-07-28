import 'package:mssql/src/tds/buf.dart';
import 'package:mssql/src/tds/constants.dart';
import 'package:test/test.dart';

import 'helpers/tds_socket.dart';

void main() {
  group('TdsBuffer TLS align nop packet', () {
    test('even size SQLBatch', () {
      final pkt = TdsBuffer.buildTlsAlignNopPacket(totalSize: 128);
      expect(pkt.length, 128);
      expect(pkt[0], packSQLBatch);
      expect(pkt[1], statusEOM);
    });

    test('odd size RPC', () {
      final pkt = TdsBuffer.buildTlsAlignNopPacket(totalSize: 139);
      expect(pkt[0], packRPCRequest);
      expect(pkt.length, 139);
    });

    test('rejects undersized', () {
      expect(
        () => TdsBuffer.buildTlsAlignNopPacket(totalSize: 20),
        throwsArgumentError,
      );
    });

    test('tlsLinearFree at 0 reserves one byte', () {
      expect(TdsBuffer.tlsLinearFree(0), TdsBuffer.tlsPlainBufferSize - 1);
      expect(TdsBuffer.tlsLinearFree(100), TdsBuffer.tlsPlainBufferSize - 100);
    });

    test('Attention rejects an unsafe wrap before writing', () async {
      final pair = await TdsSocketPair.open();
      addTearDown(pair.close);
      final received = <List<int>>[];
      pair.server.listen(received.add);

      final buffer = TdsBuffer(pair.client);
      buffer.enableTlsAlignmentForTesting(
        initialPosition: TdsBuffer.tlsPlainBufferSize - 2,
      );

      await expectLater(buffer.sendAttention(), throwsStateError);
      await Future<void>.delayed(const Duration(milliseconds: 20));
      expect(received, isEmpty);
    });

    test('Bulk Load rejects an unsafe wrap before writing', () async {
      final pair = await TdsSocketPair.open();
      addTearDown(pair.close);
      final received = <List<int>>[];
      pair.server.listen(received.add);

      final buffer = TdsBuffer(pair.client);
      buffer.enableTlsAlignmentForTesting(
        initialPosition: TdsBuffer.tlsPlainBufferSize - 2,
      );
      buffer.beginPacket(packBulkLoadBCP);
      buffer.writeByte(0xD1);

      await expectLater(
        buffer.finishPacket(packBulkLoadBCP),
        throwsStateError,
      );
      await Future<void>.delayed(const Duration(milliseconds: 20));
      expect(received, isEmpty);
    });
  });
}
