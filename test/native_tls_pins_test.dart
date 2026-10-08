import 'package:mssql_driver_with_native_tls/src/native_tls/native_tls_pins.dart';
import 'package:test/test.dart';

void main() {
  test('pinned native release tag and hashes are valid', () {
    expect(nativeTlsPinnedReleaseTag, startsWith('v'));
    expect(nativeTlsPinnedSha256, isNotEmpty);
    expect(nativeTlsPinnedSha256['linux/x64'], hasLength(64));
  });

  test('nativeTlsPinnedDigest only resolves the pinned tag', () {
    expect(
      nativeTlsPinnedDigest(
        releaseTag: nativeTlsPinnedReleaseTag,
        operatingSystem: 'linux',
        architecture: 'x64',
      ),
      nativeTlsPinnedSha256['linux/x64'],
    );
    expect(
      nativeTlsPinnedDigest(
        releaseTag: 'v0.0.0-missing',
        operatingSystem: 'linux',
        architecture: 'x64',
      ),
      isNull,
    );
  });

  test('pin keys are os/arch', () {
    expect(
      nativeTlsPinKey(operatingSystem: 'android', architecture: 'arm64'),
      'android/arm64',
    );
  });
}
