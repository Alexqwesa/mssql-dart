// In-repo SHA-256 pins for GitHub Release native TLS helpers.
//
// Update with:
//   dart run tool/update_native_tls_pins.dart --from-dir <ci-artifacts>
// Prefer hashing the exact CI / Release zip members that will be
// published for nativeTlsPinnedReleaseTag, then commit this file before
// tagging that release.

/// Release tag whose helpers are pinned below (`v` + `pubspec` version).
const String nativeTlsPinnedReleaseTag = 'v0.5.5';

/// Map of `<os>/<arch>` → lowercase hex SHA-256 of the dynamic library.
///
/// Keys match [nativeTlsPinKey].
const Map<String, String> nativeTlsPinnedSha256 = {
  'android/arm':
      '51c2ee3bf88799143ecb2faf02f972eca7a830a209a4f970a2b619368cbe4c09',
  'android/arm64':
      'a9b5498eb716afac147aff59214d90e49ec6cf5c8e6662b1cbc154483bebeb02',
  'android/x64':
      'beff68270388aaec846dde7263c76ccc2ecf02dbc28fa2bb97897003358328ad',
  'linux/x64':
      '6d529a6ab5b06841def0f0d336e243c31917a7705c25f5a44c4586149eb87e46',
  'windows/x64':
      '2d934723ef9a35baf5d5579446a1196a1b598dfebd68b88fc9d6422dbf531949',
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

