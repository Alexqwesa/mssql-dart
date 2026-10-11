import 'package:flutter_test/flutter_test.dart';
import 'package:integration_test/integration_test.dart';
import 'package:mssql_driver_with_native_tls/src/native_tls/native_tls_engine.dart';

void main() {
  IntegrationTestWidgetsFlutterBinding.ensureInitialized();

  testWidgets('bundled native TLS helper emits a ClientHello', (_) async {
    final engine = NativeTlsEngine(
      serverName: 'localhost',
      trustServerCertificate: true,
    );
    addTearDown(engine.dispose);

    expect(engine.handshake(), anyOf(1, 2, 3));
    final encrypted = engine.drainEncrypted();
    expect(encrypted.bytes, isNotEmpty);
    expect(encrypted.bytes.first, 0x16);
  });
}
