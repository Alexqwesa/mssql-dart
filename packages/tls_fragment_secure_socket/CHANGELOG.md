## 0.1.0-dev

- Add `TlsFragmentSecureSocket` with direct, cancellable, client-upgrade, and
  server-upgrade factories.
- Serialize inherited `IOSink` writes with explicit native TLS fragment writes.
- Require the companion `RawSecureSocket` patch based on Dart
  `3.14.0-165.0.dev`.
