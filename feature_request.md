# `SecureSocket`: preserve an explicit TLS write boundary

## Summary

`dart:io` `SecureSocket` has no API for submitting one plaintext fragment as
one native TLS write. Its 8 KiB circular buffer may coalesce separate
`Socket.add()` calls and split the result at the buffer's 8191-byte usable
capacity.

This caused an observed Microsoft SQL Server TDS interoperability failure.
Two 4096-byte TDS packets reached BoringSSL as:

```text
SSL_write(8191 bytes)
SSL_write(1 byte)
```

I am requesting an explicit, opt-in API. Existing `Socket.add()` behavior would
remain unchanged:

```dart
final socket = await SecureSocket.connect(host, port);

for (final tdsPacket in packets) {
  await socket.writeTlsFragment(tdsPacket);
}
```

## Proposed Contract

`writeTlsFragment()` should:

- preserve ordering with writes made through the inherited `IOSink`;
- submit the complete input through one native TLS write operation;
- complete after its ciphertext has been flushed to the underlying socket;
- retain the input across TLS retry states;
- reject input larger than the supported plaintext fragment size.

The guarantee concerns the plaintext operation passed to the native TLS
implementation. It need not promise a one-to-one TLS-record mapping if the TLS
implementation performs its own fragmentation procedure.

An additional option could preserve existing behavior by default:

```dart
coalesceWrappedTlsWrites: true // Default: false.
```

That option is useful, but narrower. It can join two physical regions already
present in the circular buffer; it cannot reconstruct an application boundary
after a large `Socket.add()` has been accepted and processed in separate
chunks.

## Reproduction And Validation

Tested from Dart SDK `main` revision
`de2ff206bc5019a090f6d607cb0d159d35f317b6` on Windows x64 against SQL
Server 2022, with the driver's historical TLS-alignment workaround removed:

| SDK behavior | TLS alignment tests |
| --- | --- |
| Unmodified SDK | 0/4 passed |
| Attached wrapped-ring copy patch | 2/4 passed |
| Prototype `writeTlsFragment()` plus wrapped-ring copy | 3/4 passed |
| Prototype plus corrected BCP nullability metadata | 4/4 passed |

The explicit API made the multi-packet trace consistently use 4096-byte native
writes and passed all 120 test iterations. The Attention cancellation test also
passed. Bulk Load initially still returned SQL Server error 4816 after write
boundaries were preserved. 

The attached `dart-secure-socket-wrapped-plaintext.patch` therefore fixes a
real lower-level split, but is not sufficient as the complete API solution.

## TDS Context

Microsoft documents TDS packet framing and negotiated packet-length rules.
The documentation does not explicitly require one TDS packet per TLS record,
so this request reports observed SQL Server interoperability rather than
claiming a normative TLS-record requirement.

- [MS-TDS packet semantics](https://learn.microsoft.com/en-us/openspecs/windows_protocols/ms-tds/e5ea8520-1ea3-4a75-a2a9-c17e63e9ee19)
- [MS-TDS packet length rules](https://learn.microsoft.com/en-us/openspecs/windows_protocols/ms-tds/c1cddd03-b448-470a-946a-9b1b908f27a7)
- [MS-TDS TLS/PRELOGIN negotiation](https://learn.microsoft.com/en-us/openspecs/windows_protocols/ms-tds/60f56408-0188-4cd5-8b90-25c6f2423868)
- [`mssql` 0.4.1 compatibility commit](https://github.com/Alexqwesa/mssql-dart/commit/fea2c6c95478f9c58e5886d2a8bf89466b969df3)

Version 0.4.1 converted the unsafe operations into expected local rejections,
so its suite does not contain unexpected failures:

- [Multi-packet SQLBatch guard](https://github.com/Alexqwesa/mssql-dart/blob/fea2c6c95478f9c58e5886d2a8bf89466b969df3/test/live/tls_alignment_live_test.dart#L45-L60)
- [Bulk Load guard](https://github.com/Alexqwesa/mssql-dart/blob/fea2c6c95478f9c58e5886d2a8bf89466b969df3/test/live/tls_alignment_live_test.dart#L95-L122)
- [Offline TLS guards](https://github.com/Alexqwesa/mssql-dart/blob/fea2c6c95478f9c58e5886d2a8bf89466b969df3/test/tls_align_test.dart#L35-L88)

Relevant Dart SDK code:

- [`secure_socket_filter.cc`](https://github.com/dart-lang/sdk/blob/main/runtime/bin/secure_socket_filter.cc)
- [`secure_socket.dart`](https://github.com/dart-lang/sdk/blob/main/sdk/lib/io/secure_socket.dart)
- [`secure_socket_patch.dart`](https://github.com/dart-lang/sdk/blob/main/sdk/lib/_internal/vm/bin/secure_socket_patch.dart)
