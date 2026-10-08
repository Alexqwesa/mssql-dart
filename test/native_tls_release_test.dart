import 'package:mssql_driver_with_native_tls/src/native_tls/native_tls_release.dart';
import 'package:test/test.dart';

void main() {
  group('nativeTlsReleaseAsset', () {
    test('maps desktop x64 targets', () {
      expect(
        nativeTlsReleaseAsset(operatingSystem: 'linux', architecture: 'x64')!
            .zipName,
        'mssql-tls-linux-x64.zip',
      );
      expect(
        nativeTlsReleaseAsset(operatingSystem: 'windows', architecture: 'x64')!
            .libraryFileName,
        'mssql_tls.dll',
      );
    });

    test('maps Android ABIs', () {
      expect(
        nativeTlsReleaseAsset(operatingSystem: 'android', architecture: 'arm64')!
            .libraryPathInZip,
        'arm64-v8a/libmssql_tls.so',
      );
      expect(
        nativeTlsReleaseAsset(operatingSystem: 'android', architecture: 'arm')!
            .libraryPathInZip,
        'armeabi-v7a/libmssql_tls.so',
      );
      expect(
        nativeTlsReleaseAsset(operatingSystem: 'android', architecture: 'x64')!
            .libraryPathInZip,
        'x86_64/libmssql_tls.so',
      );
    });

    test('returns null for unsupported targets', () {
      expect(
        nativeTlsReleaseAsset(operatingSystem: 'macos', architecture: 'arm64'),
        isNull,
      );
      expect(
        nativeTlsReleaseAsset(operatingSystem: 'linux', architecture: 'arm64'),
        isNull,
      );
    });
  });

  test('nativeTlsReleaseUri builds a GitHub release URL', () {
    expect(
      nativeTlsReleaseUri(
        releaseTag: 'v0.5.2',
        zipName: 'mssql-tls-linux-x64.zip',
      ).toString(),
      'https://github.com/Alexqwesa/mssql-dart/releases/download/v0.5.2/mssql-tls-linux-x64.zip',
    );
  });

  test('sha256FromSums parses GNU coreutils-style checksum files', () {
    const sums = '''
# comment
abc123  libmssql_tls.so
def456 *other.so
''';
    expect(sha256FromSums(sums, 'libmssql_tls.so'), 'abc123');
    expect(sha256FromSums(sums, 'other.so'), 'def456');
    expect(sha256FromSums(sums, 'missing.so'), isNull);
  });
}
