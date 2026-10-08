// In-repo SHA-256 pins for GitHub Release native TLS helpers.
//
// Update with:
//   dart run tool/update_native_tls_pins.dart --from-dir <ci-artifacts>
// Prefer hashing the exact CI / Release zip members that will be
// published for nativeTlsPinnedReleaseTag, then commit this file before
// tagging that release.

/// Release tag whose helpers are pinned below (`v` + `pubspec` version).
const String nativeTlsPinnedReleaseTag = 'v0.5.3';

/// Map of `<os>/<arch>` → lowercase hex SHA-256 of the dynamic library.
///
/// Keys match [nativeTlsPinKey].
const Map<String, String> nativeTlsPinnedSha256 = {
  'android/arm':
      'c24126b236de3ddd083624a03893207e11f0e85c1bd88728f49562cfbf6b4888',
  'android/arm64':
      '02210bf803b75fc6c816439190996b4bad404f16e69531747fd58b0ab0d6842b',
  'android/x64':
      '18d0d43145fc363aa2f93053363ff26064992bde6dccc9eb5046b77e45b4116e',
  'linux/x64':
      '6d529a6ab5b06841def0f0d336e243c31917a7705c25f5a44c4586149eb87e46',
  'windows/x64':
      '97284879c4ab18c35bc2f289d42f2a7de8902ab1093eea653bd898df688ab0fc',
};

/// Stable pin map key for a native-assets target.
String nativeTlsPinKey({
  required String operatingSystem,
  required String architecture,
}) =>
    '$operatingSystem/$architecture';

/// Returns the pinned SHA-256 for [releaseTag] + target, or `null` if absent.
String? nativeTlsPinnedDigest({
  required String releaseTag,
  required String operatingSystem,
  required String architecture,
}) {
  if (releaseTag != nativeTlsPinnedReleaseTag) return null;
  return nativeTlsPinnedSha256[nativeTlsPinKey(
    operatingSystem: operatingSystem,
    architecture: architecture,
  )];
}

