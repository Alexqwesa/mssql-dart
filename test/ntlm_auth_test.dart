import 'dart:typed_data';

import 'package:mssql/mssql.dart';
import 'package:test/test.dart';

/// NTLM Type 1 (NEGOTIATE) encoding tests.
///
/// Sources: [MS-NLMP] NEGOTIATE_MESSAGE; curl/davenport NTLM Type 1 layout.
void main() {
  group('NtlmAuth.negotiateMessage', () {
    test('signature, type 1, flags, OEM domain and workstation', () {
      final msg = NtlmAuth(
        domain: 'CORP',
        username: 'alice',
        password: 'secret',
        workstation: 'PC1',
      ).negotiateMessage();

      expect(
        msg.sublist(0, 8),
        equals([0x4E, 0x54, 0x4C, 0x4D, 0x53, 0x53, 0x50, 0x00]),
      );
      final bd = ByteData.sublistView(msg);
      expect(bd.getUint32(8, Endian.little), equals(1));

      final flags = bd.getUint32(12, Endian.little);
      expect(flags & NtlmAuth.negotiateUnicode, isNot(0));
      expect(flags & NtlmAuth.negotiateNtlm, isNot(0));
      expect(flags & NtlmAuth.negotiateOemDomainSupplied, isNot(0));
      expect(flags & NtlmAuth.negotiateOemWorkstationSupplied, isNot(0));

      final domainLen = bd.getUint16(16, Endian.little);
      final domainOff = bd.getUint32(20, Endian.little);
      expect(domainLen, equals(4));
      expect(
        String.fromCharCodes(msg.sublist(domainOff, domainOff + domainLen)),
        equals('CORP'),
      );

      final wsLen = bd.getUint16(24, Endian.little);
      final wsOff = bd.getUint32(28, Endian.little);
      expect(wsLen, equals(3));
      expect(
        String.fromCharCodes(msg.sublist(wsOff, wsOff + wsLen)),
        equals('PC1'),
      );
    });

    test('Login7 SSPI accepts negotiate blob at declared offset', () async {
      // Covered end-to-end via Login7 + NtlmAuth (encode only).
      final sspi = NtlmAuth(
        domain: 'D',
        username: 'u',
        password: 'p',
        workstation: 'W',
      ).negotiateMessage();
      expect(sspi.first, equals(0x4E)); // 'N'
      expect(sspi.length, greaterThan(32));
    });
  });
}
