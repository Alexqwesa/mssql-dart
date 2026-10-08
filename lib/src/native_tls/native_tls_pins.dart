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
      '4e9cf58e778cc80e089156b46a806ed8e1e539f10712c7b548fb5cf6de092985',
  'android/arm64':
      'b12a116e41cb43f064c019a8f6218bedca4f533ce698bbc19008150762641dee',
  'android/x64':
      '30daf1ab1d5b1f52aa3231ab75904c5b8ac6031ac664f110b31df700fddf75f8',
  'linux/x64':
      '6d529a6ab5b06841def0f0d336e243c31917a7705c25f5a44c4586149eb87e46',
  'windows/x64':
      '34b45d978d574aac4b8e898d4dd03e986e5a54501f440c2afdb430f1d4d02fc3',
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

