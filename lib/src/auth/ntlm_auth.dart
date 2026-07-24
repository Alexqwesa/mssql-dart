import 'dart:convert';
import 'dart:math';
import 'dart:typed_data';

import 'package:crypto/crypto.dart';

import 'md4.dart';

/// Parsed NTLMSSP Type 2 CHALLENGE message ([MS-NLMP] CHALLENGE_MESSAGE).
class NtlmChallenge {
  final int flags;
  final Uint8List serverChallenge;
  final String targetName;
  final Uint8List targetInfo;

  const NtlmChallenge({
    required this.flags,
    required this.serverChallenge,
    required this.targetName,
    required this.targetInfo,
  });

  static const int negotiateTargetInfo = 0x00800000;

  /// Parses a Type 2 message. Throws [FormatException] if the header is invalid.
  factory NtlmChallenge.parse(Uint8List msg) {
    if (msg.length < 32) {
      throw FormatException('NTLM Type 2 too short (${msg.length})');
    }
    if (!_hasSignature(msg)) {
      throw FormatException('NTLM Type 2 missing NTLMSSP signature');
    }
    final bd = ByteData.sublistView(msg);
    final type = bd.getUint32(8, Endian.little);
    if (type != 2) {
      throw FormatException('Expected NTLM Type 2, got $type');
    }

    final targetLen = bd.getUint16(12, Endian.little);
    final targetOff = bd.getUint32(16, Endian.little);
    final flags = bd.getUint32(20, Endian.little);
    final challenge = Uint8List.fromList(msg.sublist(24, 32));

    var targetName = '';
    if (targetLen > 0 && targetOff + targetLen <= msg.length) {
      final raw = msg.sublist(targetOff, targetOff + targetLen);
      targetName = (flags & NtlmAuth.negotiateUnicode) != 0
          ? _fromUtf16Le(raw)
          : latin1.decode(raw);
    }

    var targetInfo = Uint8List(0);
    if (msg.length >= 48 && (flags & negotiateTargetInfo) != 0) {
      final infoLen = bd.getUint16(40, Endian.little);
      final infoOff = bd.getUint32(44, Endian.little);
      if (infoLen > 0 && infoOff + infoLen <= msg.length) {
        targetInfo = Uint8List.fromList(msg.sublist(infoOff, infoOff + infoLen));
      }
    }

    return NtlmChallenge(
      flags: flags,
      serverChallenge: challenge,
      targetName: targetName,
      targetInfo: targetInfo,
    );
  }
}

/// Windows / NTLM authentication helpers for TDS SSPI.
///
/// Supports:
/// - Type 1 NEGOTIATE ([negotiateMessage])
/// - Type 2 parse ([NtlmChallenge.parse])
/// - Type 3 AUTHENTICATE with NTLMv2 ([authenticateMessage])
///
/// Spec: [MS-NLMP]; vectors from curl/davenport NTLM docs.
class NtlmAuth {
  final String domain;
  final String username;
  final String password;
  final String? workstation;

  NtlmAuth({
    required this.domain,
    required this.username,
    required this.password,
    this.workstation,
  });

  // Common negotiate flags (MS-NLMP §2.2.2.5).
  static const int negotiateUnicode = 0x00000001;
  static const int negotiateOem = 0x00000002;
  static const int requestTarget = 0x00000004;
  static const int negotiateNtlm = 0x00000200;
  static const int negotiateAlwaysSign = 0x00008000;
  static const int negotiateOemDomainSupplied = 0x00001000;
  static const int negotiateOemWorkstationSupplied = 0x00002000;
  static const int negotiateExtendedSessionSecurity = 0x00080000;
  static const int negotiateTargetInfo = 0x00800000;

  /// Builds an NTLMSSP Type 1 NEGOTIATE message (OEM domain + workstation).
  Uint8List negotiateMessage() {
    final domainBytes = latin1.encode(domain.toUpperCase());
    final wsName = (workstation ?? 'WORKSTATION').toUpperCase();
    final wsBytes = latin1.encode(wsName);

    var flags = negotiateUnicode |
        negotiateOem |
        requestTarget |
        negotiateNtlm |
        negotiateAlwaysSign |
        negotiateExtendedSessionSecurity;
    if (domainBytes.isNotEmpty) flags |= negotiateOemDomainSupplied;
    if (wsBytes.isNotEmpty) flags |= negotiateOemWorkstationSupplied;

    const headerLen = 32;
    final total = headerLen + domainBytes.length + wsBytes.length;
    final out = Uint8List(total);
    final bd = ByteData.sublistView(out);

    out.setRange(0, 8, _signature);
    bd.setUint32(8, 1, Endian.little);
    bd.setUint32(12, flags, Endian.little);

    var payloadOff = headerLen;
    bd.setUint16(16, domainBytes.length, Endian.little);
    bd.setUint16(18, domainBytes.length, Endian.little);
    bd.setUint32(20, domainBytes.isEmpty ? 0 : payloadOff, Endian.little);
    if (domainBytes.isNotEmpty) {
      out.setRange(payloadOff, payloadOff + domainBytes.length, domainBytes);
      payloadOff += domainBytes.length;
    }

    bd.setUint16(24, wsBytes.length, Endian.little);
    bd.setUint16(26, wsBytes.length, Endian.little);
    bd.setUint32(28, wsBytes.isEmpty ? 0 : payloadOff, Endian.little);
    if (wsBytes.isNotEmpty) {
      out.setRange(payloadOff, payloadOff + wsBytes.length, wsBytes);
    }

    return out;
  }

  /// Builds an NTLMSSP Type 3 AUTHENTICATE (NTLMv2) in response to [challenge].
  ///
  /// [clientChallenge] and [timestamp] may be supplied for deterministic tests
  /// (curl/davenport vectors); otherwise random / current FILETIME are used.
  Uint8List authenticateMessage(
    NtlmChallenge challenge, {
    Uint8List? clientChallenge,
    Uint8List? timestamp,
  }) {
    final cc = clientChallenge ?? _randomBytes(8);
    if (cc.length != 8) {
      throw ArgumentError('clientChallenge must be 8 bytes');
    }
    final ts = timestamp ?? _windowsFiletimeNow();
    if (ts.length != 8) {
      throw ArgumentError('timestamp must be 8 bytes');
    }

    final targetForHash =
        challenge.targetName.isNotEmpty ? challenge.targetName : domain;
    final ntHash = ntPasswordHash(password);
    final ntlmv2Hash = ntowfV2(ntHash, username, targetForHash);

    final blob = _ntlmv2Blob(ts, cc, challenge.targetInfo);
    final ntProof = _hmacMd5(ntlmv2Hash, [...challenge.serverChallenge, ...blob]);
    final ntResponse = Uint8List.fromList([...ntProof, ...blob]);

    final lmProof = _hmacMd5(ntlmv2Hash, [...challenge.serverChallenge, ...cc]);
    final lmResponse = Uint8List.fromList([...lmProof, ...cc]);

    final domainU = _utf16Le(domain);
    final userU = _utf16Le(username);
    final wsU = _utf16Le(workstation ?? 'WORKSTATION');

    // Authenticate message fixed header is 64 bytes (no MIC / Version).
    const headerLen = 64;
    final total = headerLen +
        lmResponse.length +
        ntResponse.length +
        domainU.length +
        userU.length +
        wsU.length;
    final out = Uint8List(total);
    final bd = ByteData.sublistView(out);

    out.setRange(0, 8, _signature);
    bd.setUint32(8, 3, Endian.little);

    var off = headerLen;
    void writeBuf(int fieldOff, Uint8List data) {
      bd.setUint16(fieldOff, data.length, Endian.little);
      bd.setUint16(fieldOff + 2, data.length, Endian.little);
      bd.setUint32(fieldOff + 4, off, Endian.little);
      out.setRange(off, off + data.length, data);
      off += data.length;
    }

    writeBuf(12, lmResponse); // LmChallengeResponse
    writeBuf(20, ntResponse); // NtChallengeResponse
    writeBuf(28, domainU);
    writeBuf(36, userU);
    writeBuf(44, wsU);
    // EncryptedRandomSessionKey — empty
    bd.setUint16(52, 0, Endian.little);
    bd.setUint16(54, 0, Endian.little);
    bd.setUint32(56, 0, Endian.little);

    var flags = challenge.flags | negotiateUnicode | negotiateNtlm;
    flags &= ~negotiateOem; // prefer Unicode in Type 3
    bd.setUint32(60, flags, Endian.little);

    return out;
  }

  /// NT hash = MD4(UTF-16LE(password)).
  static Uint8List ntPasswordHash(String password) => md4(_utf16Le(password));

  /// NTOWFv2 = HMAC_MD5(NT hash, UTF-16LE(Upper(User) + Domain)).
  static Uint8List ntowfV2(Uint8List ntHash, String user, String domain) {
    final identity = _utf16Le('${user.toUpperCase()}$domain');
    return _hmacMd5(ntHash, identity);
  }

  static Uint8List _ntlmv2Blob(
    Uint8List timestamp,
    Uint8List clientChallenge,
    Uint8List targetInfo,
  ) {
    final out = BytesBuilder(copy: false);
    out.add([0x01, 0x01, 0x00, 0x00]); // blob signature
    out.add([0x00, 0x00, 0x00, 0x00]); // reserved
    out.add(timestamp);
    out.add(clientChallenge);
    out.add([0x00, 0x00, 0x00, 0x00]); // unknown
    out.add(targetInfo);
    out.add([0x00, 0x00, 0x00, 0x00]); // unknown
    return out.toBytes();
  }

  static Uint8List _hmacMd5(List<int> key, List<int> data) {
    final hmac = Hmac(md5, key);
    return Uint8List.fromList(hmac.convert(data).bytes);
  }

  static Uint8List _utf16Le(String s) {
    final out = Uint8List(s.length * 2);
    for (var i = 0; i < s.length; i++) {
      final c = s.codeUnitAt(i);
      out[i * 2] = c & 0xFF;
      out[i * 2 + 1] = (c >> 8) & 0xFF;
    }
    return out;
  }

  static Uint8List _windowsFiletimeNow() {
    // 100-ns intervals since 1601-01-01.
    final unixNs = DateTime.now().toUtc().microsecondsSinceEpoch * 10;
    final ft = unixNs + 116444736000000000;
    final out = Uint8List(8);
    ByteData.sublistView(out).setUint64(0, ft, Endian.little);
    return out;
  }

  static Uint8List _randomBytes(int n) {
    final r = Random.secure();
    return Uint8List.fromList(List.generate(n, (_) => r.nextInt(256)));
  }
}

const _signature = [0x4E, 0x54, 0x4C, 0x4D, 0x53, 0x53, 0x50, 0x00];

bool _hasSignature(Uint8List msg) {
  for (var i = 0; i < 8; i++) {
    if (msg[i] != _signature[i]) return false;
  }
  return true;
}

String _fromUtf16Le(List<int> bytes) {
  final codes = <int>[];
  for (var i = 0; i + 1 < bytes.length; i += 2) {
    codes.add(bytes[i] | (bytes[i + 1] << 8));
  }
  return String.fromCharCodes(codes);
}
