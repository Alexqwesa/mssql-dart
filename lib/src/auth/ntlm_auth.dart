import 'dart:convert';
import 'dart:typed_data';

/// Windows / NTLM authentication helpers for TDS SSPI.
///
/// Currently builds the NTLMSSP Type 1 (NEGOTIATE) message used as the initial
/// SSPI blob in LOGIN7. Type 2/3 (challenge response) is not implemented yet.
///
/// Spec: [MS-NLMP] NEGOTIATE_MESSAGE; layout also matches go-mssqldb / curl NTLM.
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

    // Fixed header = 32 bytes; payload follows.
    const headerLen = 32;
    final total = headerLen + domainBytes.length + wsBytes.length;
    final out = Uint8List(total);
    final bd = ByteData.sublistView(out);

    // Signature "NTLMSSP\0"
    out.setRange(0, 8, const [0x4E, 0x54, 0x4C, 0x4D, 0x53, 0x53, 0x50, 0x00]);
    bd.setUint32(8, 1, Endian.little); // MessageType = NtLmNegotiate
    bd.setUint32(12, flags, Endian.little);

    var payloadOff = headerLen;
    // DomainNameFields
    bd.setUint16(16, domainBytes.length, Endian.little);
    bd.setUint16(18, domainBytes.length, Endian.little);
    bd.setUint32(20, domainBytes.isEmpty ? 0 : payloadOff, Endian.little);
    if (domainBytes.isNotEmpty) {
      out.setRange(payloadOff, payloadOff + domainBytes.length, domainBytes);
      payloadOff += domainBytes.length;
    }

    // WorkstationFields
    bd.setUint16(24, wsBytes.length, Endian.little);
    bd.setUint16(26, wsBytes.length, Endian.little);
    bd.setUint32(28, wsBytes.isEmpty ? 0 : payloadOff, Endian.little);
    if (wsBytes.isNotEmpty) {
      out.setRange(payloadOff, payloadOff + wsBytes.length, wsBytes);
    }

    return out;
  }
}
