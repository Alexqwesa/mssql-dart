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
const String nativeTlsPinnedReleaseTag = 'v0.5.10';

/// Map of `<os>/<arch>` → lowercase hex SHA-256 of the dynamic library.
///
/// Keys match [nativeTlsPinKey].
const Map<String, String> nativeTlsPinnedSha256 = {
  'android/arm':
      'e9477c26acd2de98a2a3c7c39b9a69372cfa0efce938b1c568ea543c66e49690',
  'android/arm64':
      '7350f46dd8d17b42fdd4f771d8ee4f3e7f497a38de1f39e336323ec1392656d0',
  'android/x64':
      'd1a7e38b3f8746e3f596f33c89053a6fde3220f756952156d7eb30e4719109ea',
  'ios/iphoneos/arm64':
      '6b6e820b289ab35521297af0826d128b8fed88499b265d18a49448359e5bc768',
  'ios/iphonesimulator/arm64':
      '36b8105ce88b24479053a7826ef2d9ed4a3e119814bb32001ce11c059d37f352',
  'ios/iphonesimulator/x64':
      'cc446be83600bec35d889b15c2208eef95883b99029006946ce14926e84a94bb',
  'linux/x64':
      'ec330078577dfaef66ad70016ca509e495950822698e74fd3484a05bf4abb567',
  'macos/arm64':
      '0039f401699a9144d8d8e598f8d64ff0fd10d2edcb39afa46763a5a9e95e7481',
  'macos/x64':
      '6e7c3464f9c3c69e50536586d76d192e2403c43be2db6e5fe3a7864ea00775c2',
  'windows/x64':
      'dc7244246ede163ca6ec0736784ab2254f7c8ec0a12449b11fa395f45f63391a',
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
