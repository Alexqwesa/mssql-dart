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
      '5b8aa381f604bfe6ea803c229357f8cbf772e446a2b3e0ea2ebf52bf639d2c8c',
  'android/arm64':
      '0b296ae9cb776ed3e78729cce15cefddad22fd5c25c99cf0edfd4652cba28cda',
  'android/x64':
      '9f6afe7de73d862ccf228f42d0094f9e0af3495f301ccbb5644201cf81f9ce71',
  'ios/iphoneos/arm64':
      '064116612b9da7f26cfc6c5ad5266208c05d08491ac5e4af80fe22b0860fd54e',
  'ios/iphonesimulator/arm64':
      '8387220069b7bcfdc738b300e5990989a7618762102292344e1110b2c95d124c',
  'ios/iphonesimulator/x64':
      'd2ecbe2a1f7347219ffa672cce6f6afe6e2764d9846547c797f8239cc22dff17',
  'linux/x64':
      'ec330078577dfaef66ad70016ca509e495950822698e74fd3484a05bf4abb567',
  'macos/arm64':
      '946596548a7bd011f4f23cda9060b94933e56e0eb6a5962bc35fa00532070b36',
  'macos/x64':
      '56be77ab36e2a3b8b76fcf7bbf2f857cb196b131fa79c201f9020acc659e5e55',
  'windows/x64':
      '5803ce24408ba8981bc7286d9e1454dd5ce48121a281eddb55376656e5ce7ebd',
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
