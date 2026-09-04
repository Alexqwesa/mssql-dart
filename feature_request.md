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

I am requesting two explicit, opt-in primitives on `RawSecureSocket`. The
existing `SecureSocket` API and write behavior would remain unchanged. A
separate package can build a high-level `SecureSocket` implementation on those
raw primitives:

```dart
import 'package:tls_fragment_secure_socket/tls_fragment_secure_socket.dart';

final socket = await TlsFragmentSecureSocket.connect(host, port);
final limit = socket.maximumTlsFragmentLength;

for (final tdsPacket in packets) {
  if (tdsPacket.length > limit) throw StateError('TDS packet is too large');
  await socket.writeTlsFragment(tdsPacket);
}
```

## Proposed Contract

```dart
abstract interface class RawSecureSocket implements RawSocket {
  int get maximumTlsFragmentLength;
  Future<void> writeTlsFragment(List<int> data);
}
```

The SDK primitives should:

- expose the platform capacity through `maximumTlsFragmentLength`;
- make `RawSecureSocket.writeTlsFragment()` submit its complete input through
  one native TLS write operation;
- complete an explicit fragment call after its ciphertext has been flushed to
  the underlying socket;
- retain a submitted fragment across TLS retry states;
- reject explicit fragment input larger than the supported plaintext size;
- leave synchronization with `RawSecureSocket.write()` to the raw API caller.

The companion package demonstrates the high-level policy separately. Its
`TlsFragmentSecureSocket`:

- implements `SecureSocket` without adding a subtype to `dart:io`;
- mirrors `connect`, `startConnect`, `secure`, and `secureServer`, using
  `RawSocket` for the two upgrade factories;
- routes inherited `IOSink` writes and explicit fragments through one queue;
- splits oversized ordinary writes automatically while rejecting oversized
  explicit fragments;
- preserves ordering and captures mutable fragment input at call time.

The guarantee concerns the plaintext operation passed to the native TLS
implementation. It need not promise a one-to-one TLS-record mapping if the TLS
implementation performs its own fragmentation procedure.

The package wrapper may reduce write throughput because ordinary `IOSink` input
also passes through its serialized fragment queue. That cost is isolated to
package users. Ordinary `SecureSocket` and `RawSecureSocket` instances keep
their existing implementation and allocation behavior.

The SDK prototype isolates all fragment state in a lazily allocated private
helper. `_RawSecureSocket` retains only one nullable field plus short-circuited
filter, error, and close hooks, so connections that never use the primitive do
not allocate fragment queues or completers.

## Side note: Prototype Capacity

The current prototype reports `8191`. Dart's plaintext ring is 8192 bytes and
reserves one byte so equal cursors unambiguously mean "empty". After the write
side is fully drained and the native filter is idle, the prototype rebases the
empty ring to `start = end = 0`. This provides one contiguous 8191-byte range
without a scratch buffer or changes to the native C++ filter.

The value is an implementation capacity, not a TLS protocol limit. TLS 1.2 and
TLS 1.3 permit plaintext records of **up to** 2^14 (16384) bytes; they do not
require implementations to emit 16 KiB records. An 8191-byte maximum is
standards-compliant. The capability getter allows a later SDK to support 16384
without changing this API.

Supporting the full 16384 bytes in the current implementation would require a
plaintext ring with at least 16385 physical bytes. The current 10 KiB encrypted
ring and internal BIO would also need either enlargement or explicit validation
of their `WANT_WRITE` drain/retry behavior for a full-sized record. That is a
reasonable follow-up optimization, but it is not required for the API or this
TDS use case.

- [TLS 1.2 record fragmentation, RFC 5246 section 6.2.1](https://www.rfc-editor.org/rfc/rfc5246#section-6.2.1)
- [TLS 1.3 record layer, RFC 8446 section 5.1](https://www.rfc-editor.org/rfc/rfc8446#section-5.1)

## Reproduction And Validation

Tested from Dart SDK tag `3.14.0-165.0.dev` on Windows x64 against SQL Server
2022, with the driver's historical TLS-alignment workaround removed:

The attached `secure_socket_tls_fragment.patch` contains only the
`RawSecureSocket` primitives, empty-ring implementation, and standalone SDK
regression test. The high-level implementation is in
`packages/tls_fragment_secure_socket`.

| SDK behavior | TLS alignment tests |
| --- | --- |
| Unmodified SDK | 0/4 passed |
| Attached wrapped-ring copy patch | 2/4 passed |
| Raw primitive + package wrapper with empty-ring rebasing | 3/4 passed |
| Prototype plus corrected BCP nullability metadata | 4/4 passed |

The explicit API made the multi-packet trace consistently use 4096-byte native
writes and passed all 120 test iterations. The Attention cancellation test also
passed. Bulk Load initially still returned SQL Server error 4816 after write
boundaries were preserved.

The attached `dart-secure-socket-wrapped-plaintext.patch` therefore fixes a
real lower-level split, but is not sufficient as the complete API solution. The
latest explicit-fragment prototype does not need that wrapped-ring copy.

The current driver validation adds a fifth packet-capacity regression. With the
raw primitive, package wrapper, and independent BCP fix, all 5 alignment tests
and all 415 encrypted live tests pass with no skips. The package's direct,
`startConnect`, client-upgrade, and server-upgrade tests also pass.

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
