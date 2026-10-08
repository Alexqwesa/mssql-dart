// In-repo SHA-256 pins for GitHub Release native TLS helpers.
//
// Update with:
//   dart run tool/update_native_tls_pins.dart --from-dir <ci-artifacts>
// Prefer hashing the exact CI / Release zip members that will be
// published for nativeTlsPinnedReleaseTag, then commit this file before
// tagging that release.

/// Release tag whose helpers are pinned below (`v` + `pubspec` version).
const String nativeTlsPinnedReleaseTag = 'v0.5.4';

/// Map of `<os>/<arch>` → lowercase hex SHA-256 of the dynamic library.
///
/// Keys match [nativeTlsPinKey].
const Map<String, String> nativeTlsPinnedSha256 = {
  'android/arm':
      '0e5e289610a1e07e3479a7f83c20e4968d3c8615a98d968497bedcacf0eb7dd4',
  'android/arm64':
      '58ff7f3c40bab16387179b41f82470fb263898d037524d4bfe7a08c94305f640',
  'android/x64':
      'f4436b829ce2fb6034722c95986ee19877e522cd43f6f77379f13713111f471c',
  'linux/x64':
      '6d529a6ab5b06841def0f0d336e243c31917a7705c25f5a44c4586149eb87e46',
  'windows/x64':
      '4057b5d2455b0894295170b69e6904ba81c8a8fd401cc175f84273d0871d8cf9',
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

