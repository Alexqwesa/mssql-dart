import 'dart:typed_data';

import 'package:mssql/mssql.dart';
import 'package:mssql/src/auth/md4.dart';
import 'package:test/test.dart';

/// NTLM Type 1/2/3 tests with curl/davenport / [MS-NLMP] golden vectors.
void main() {
  group('MD4 / NT hash', () {
    // curl NTLM docs: password SecREt01 → MD4 UTF-16LE
    test('NT hash of SecREt01 matches davenport vector', () {
      final hash = NtlmAuth.ntPasswordHash('SecREt01');
      expect(
        hash,
        equals(_hex('cd06ca7c7e10c99b1d33b7485a2ed808')),
      );
    });

    test('md4 empty string RFC 1320', () {
      // RFC 1320 appendix A: MD4("") = 31d6cfe0d16ae931b73c59d7e0c089c0
      expect(md4([]), equals(_hex('31d6cfe0d16ae931b73c59d7e0c089c0')));
    });
  });

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
  });

  group('NtlmChallenge.parse (Type 2)', () {
    // Minimal Type 2 with challenge 0123456789abcdef and empty target
    test('parses server challenge and flags', () {
      final msg = _type2(
        flags: NtlmAuth.negotiateUnicode | NtlmAuth.negotiateNtlm,
        challenge: _hex('0123456789abcdef'),
      );
      final c = NtlmChallenge.parse(msg);
      expect(c.serverChallenge, equals(_hex('0123456789abcdef')));
      expect(c.flags & NtlmAuth.negotiateUnicode, isNot(0));
      expect(c.targetInfo, isEmpty);
    });

    test('parses Unicode target name and target info', () {
      final target = _ucs2('DOMAIN');
      final info = _hex(
        '02000c0044004f004d00410049004e00'
        '01000c00530045005200560045005200'
        '0400140064006f006d00610069006e00'
        '2e0063006f006d000300220073006500'
        '72007600650072002e0064006f006d00'
        '610069006e002e0063006f006d0000000000',
      );
      final msg = _type2(
        flags: NtlmAuth.negotiateUnicode |
            NtlmAuth.negotiateNtlm |
            NtlmAuth.negotiateTargetInfo,
        challenge: _hex('0123456789abcdef'),
        targetName: target,
        targetInfo: info,
      );
      final c = NtlmChallenge.parse(msg);
      expect(c.targetName, equals('DOMAIN'));
      expect(c.targetInfo, equals(info));
    });

    test('rejects non-Type-2', () {
      final bad = Uint8List.fromList([
        ...[0x4E, 0x54, 0x4C, 0x4D, 0x53, 0x53, 0x50, 0x00],
        1, 0, 0, 0, // type 1
        ...List.filled(20, 0),
      ]);
      expect(() => NtlmChallenge.parse(bad), throwsFormatException);
    });
  });

  group('NtlmAuth.authenticateMessage (Type 3 / NTLMv2)', () {
    // curl/davenport NTLMv2 example
    test('NTProofStr matches davenport vector', () {
      final targetInfo = _hex(
        '02000c0044004f004d00410049004e00'
        '01000c00530045005200560045005200'
        '0400140064006f006d00610069006e00'
        '2e0063006f006d000300220073006500'
        '72007600650072002e0064006f006d00'
        '610069006e002e0063006f006d0000000000',
      );
      final challenge = NtlmChallenge(
        flags: NtlmAuth.negotiateUnicode |
            NtlmAuth.negotiateNtlm |
            NtlmAuth.negotiateTargetInfo,
        serverChallenge: _hex('0123456789abcdef'),
        targetName: 'DOMAIN',
        targetInfo: targetInfo,
      );

      final auth = NtlmAuth(
        domain: 'DOMAIN',
        username: 'user',
        password: 'SecREt01',
        workstation: 'WORKSTATION',
      );

      // Intermediate: NTOWFv2
      final ntHash = NtlmAuth.ntPasswordHash('SecREt01');
      final v2 = NtlmAuth.ntowfV2(ntHash, 'user', 'DOMAIN');
      expect(v2, equals(_hex('04b8e0ba74289cc540826bab1dee63ae')));

      final type3 = auth.authenticateMessage(
        challenge,
        clientChallenge: _hex('ffffff0011223344'),
        timestamp: _hex('0090d336b734c301'),
      );

      final bd = ByteData.sublistView(type3);
      expect(bd.getUint32(8, Endian.little), equals(3));

      final ntLen = bd.getUint16(20, Endian.little);
      final ntOff = bd.getUint32(24, Endian.little);
      final ntResp = type3.sublist(ntOff, ntOff + ntLen);
      // First 16 bytes = NTProofStr
      expect(
        ntResp.sublist(0, 16),
        equals(_hex('cbabbca713eb795d04c97abc01ee4983')),
      );
    });

    test('Type 3 embeds Unicode username and domain', () {
      final challenge = NtlmChallenge(
        flags: NtlmAuth.negotiateUnicode | NtlmAuth.negotiateNtlm,
        serverChallenge: _hex('0123456789abcdef'),
        targetName: 'DOMAIN',
        targetInfo: Uint8List(0),
      );
      final type3 = NtlmAuth(
        domain: 'DOMAIN',
        username: 'user',
        password: 'SecREt01',
      ).authenticateMessage(
        challenge,
        clientChallenge: _hex('aaaaaaaaaaaaaaaa'),
        timestamp: _hex('0000000000000000'),
      );

      final bd = ByteData.sublistView(type3);
      final domLen = bd.getUint16(28, Endian.little);
      final domOff = bd.getUint32(32, Endian.little);
      final userLen = bd.getUint16(36, Endian.little);
      final userOff = bd.getUint32(40, Endian.little);

      expect(_fromUcs2(type3.sublist(domOff, domOff + domLen)), equals('DOMAIN'));
      expect(_fromUcs2(type3.sublist(userOff, userOff + userLen)), equals('user'));
    });
  });
}

Uint8List _hex(String s) {
  final clean = s.replaceAll(RegExp(r'\s'), '');
  final out = Uint8List(clean.length ~/ 2);
  for (var i = 0; i < out.length; i++) {
    out[i] = int.parse(clean.substring(i * 2, i * 2 + 2), radix: 16);
  }
  return out;
}

Uint8List _ucs2(String s) {
  final out = Uint8List(s.length * 2);
  for (var i = 0; i < s.length; i++) {
    final c = s.codeUnitAt(i);
    out[i * 2] = c & 0xFF;
    out[i * 2 + 1] = (c >> 8) & 0xFF;
  }
  return out;
}

String _fromUcs2(List<int> bytes) {
  final codes = <int>[];
  for (var i = 0; i + 1 < bytes.length; i += 2) {
    codes.add(bytes[i] | (bytes[i + 1] << 8));
  }
  return String.fromCharCodes(codes);
}

Uint8List _type2({
  required int flags,
  required Uint8List challenge,
  Uint8List? targetName,
  Uint8List? targetInfo,
}) {
  final target = targetName ?? Uint8List(0);
  final info = targetInfo ?? Uint8List(0);
  final hasInfo = info.isNotEmpty;
  final headerLen = hasInfo ? 48 : 32;
  final out = Uint8List(headerLen + target.length + info.length);
  final bd = ByteData.sublistView(out);
  out.setRange(0, 8, const [0x4E, 0x54, 0x4C, 0x4D, 0x53, 0x53, 0x50, 0x00]);
  bd.setUint32(8, 2, Endian.little);
  var off = headerLen;
  bd.setUint16(12, target.length, Endian.little);
  bd.setUint16(14, target.length, Endian.little);
  bd.setUint32(16, target.isEmpty ? 0 : off, Endian.little);
  bd.setUint32(20, flags, Endian.little);
  out.setRange(24, 32, challenge);
  if (target.isNotEmpty) {
    out.setRange(off, off + target.length, target);
    off += target.length;
  }
  if (hasInfo) {
    // context zeros at 32..40
    bd.setUint16(40, info.length, Endian.little);
    bd.setUint16(42, info.length, Endian.little);
    bd.setUint32(44, off, Endian.little);
    out.setRange(off, off + info.length, info);
  }
  return out;
}
