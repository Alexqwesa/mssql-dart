# tls_fragment_secure_socket

`TlsFragmentSecureSocket` is a package-owned `SecureSocket` implementation for
protocols that require one successful TLS-engine plaintext write to consume a
complete application-data fragment. In the patched Dart VM, that operation is
a successful `SSL_write()` call. Non-consuming calls may be retried, and a
successful call is not guaranteed to produce exactly one TLS record. The
package keeps this specialized policy out of the existing `SecureSocket` API.

The package requires the companion Dart SDK patch based on
`3.14.0-165.0.dev`. That patch adds only these raw primitives:

```dart
int RawSecureSocket.maximumTlsFragmentLength;
Future<void> RawSecureSocket.writeTlsFragment(List<int> data);
```

Apply and build the SDK patch before resolving this package:

```powershell
git -C C:\path\to\dart-sdk checkout 3.14.0-165.0.dev
git -C C:\path\to\dart-sdk apply C:\path\to\secure_socket_tls_fragment.patch
python C:\path\to\dart-sdk\tools\build.py --mode release --arch x64 create_sdk
```

Then use the `dart` executable from that build for `pub get`, analysis, and
tests. An unpatched SDK rejects the package because the required raw members do
not exist.

Direct connections mirror `SecureSocket`:

```dart
final socket = await TlsFragmentSecureSocket.connect('localhost', 443);
await socket.writeTlsFragment(protocolPacket);
```

TLS upgrades use `RawSocket`, Dart's existing public raw upgrade boundary:

```dart
final raw = await RawSocket.connect('localhost', 443);
final socket = await TlsFragmentSecureSocket.secure(raw);
```

Inherited `IOSink` writes remain supported and are serialized with explicit
fragment writes. Ordinary oversized writes are split automatically; explicit
fragments larger than `maximumTlsFragmentLength` are rejected.
