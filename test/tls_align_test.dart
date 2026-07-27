import 'package:mssql/src/tds/buf.dart';
import 'package:mssql/src/tds/constants.dart';
import 'package:test/test.dart';

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
  });
}
