// In-repo SHA-256 pins for GitHub Release native TLS helpers.
//
// Update with:
//   dart run tool/update_native_tls_pins.dart
// Prefer hashing the exact Release zip members (or CI artifacts) that will be
// published for nativeTlsPinnedReleaseTag, then commit this file before
// tagging that release.

/// Release tag whose helpers are pinned below (`v` + `pubspec` version).
const String nativeTlsPinnedReleaseTag = 'v0.5.3';

/// Map of `<os>/<arch>` → lowercase hex SHA-256 of the dynamic library.
///
/// Keys match [nativeTlsPinKey].
const Map<String, String> nativeTlsPinnedSha256 = {
  'linux/x64':
      '85225f1760193c13788b02ac7a51f19e0887c136a348f5ddf2c2a3c6d148778c',
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

