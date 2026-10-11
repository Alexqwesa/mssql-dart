// In-repo SHA-256 pins for GitHub Release native TLS helpers.
//
// Update with:
//   dart run tool/update_native_tls_pins.dart --from-dir <ci-artifacts>
// Prefer hashing the exact CI / Release zip members that will be
// published for nativeTlsPinnedReleaseTag, then commit this file before
// tagging that release.

/// Release tag whose helpers are pinned below.
///
/// This may be older than the package version when native code is unchanged.
const String nativeTlsPinnedReleaseTag = 'v0.5.9';

/// Map of `<os>/<arch>` → lowercase hex SHA-256 of the dynamic library.
///
/// Keys match [nativeTlsPinKey].
const Map<String, String> nativeTlsPinnedSha256 = {
  'android/arm':
      '9fbd94324dd2037ee857d4bd0cf23cc20a1e684bddbbb69b44c8d9e710e040ba',
  'android/arm64':
      'aafe3d7c5d3af48ee116d25de06af36ed365b59974aa91fc45357258252f7ea0',
  'android/x64':
      '8cf337552cf5d35f12f72bad54d4c1d4042a99e4d966b4d0aa4b416427e6d586',
  'ios/iphoneos/arm64':
      '8ea90c1b899f4d3cd2c6a96381bbd7887d8370a8fea41d62e4eeded1903a40ff',
  'ios/iphonesimulator/arm64':
      'ddcb36fd4c0c05790c415bd6c11841791d1b7a9eb4b0edeed08b619c1d379526',
  'ios/iphonesimulator/x64':
      'ecae4ea5ac822159633e830094a07f84f3f08c892fe68e8693fce3b19cf4a5be',
  'linux/x64':
      'ec330078577dfaef66ad70016ca509e495950822698e74fd3484a05bf4abb567',
  'macos/arm64':
      '6d9ae9a92d91235460a8789a909b195250991801e999100f988eebe1b9866a05',
  'macos/x64':
      '2ad96907f608746098ca32de85d60b5ab8319b343b8c16ba6371981783e9c850',
  'windows/x64':
      '7cba320887ac96058ad87d5213c2e5519599c7b124b72a47f25f689eb982c42f',
};

/// Stable pin map key for a native-assets target.
String nativeTlsPinKey({
  required String operatingSystem,
  required String architecture,
  String? platformVariant,
}) => platformVariant == null
    ? '$operatingSystem/$architecture'
    : '$operatingSystem/$platformVariant/$architecture';

/// Returns the pinned SHA-256 for [releaseTag] + target, or `null` if absent.
String? nativeTlsPinnedDigest({
  required String releaseTag,
  required String operatingSystem,
  required String architecture,
  String? platformVariant,
}) {
  if (releaseTag != nativeTlsPinnedReleaseTag) return null;
  return nativeTlsPinnedSha256[nativeTlsPinKey(
    operatingSystem: operatingSystem,
    architecture: architecture,
    platformVariant: platformVariant,
  )];
}
