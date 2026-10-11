import 'dart:ffi';
import 'dart:io';

import 'native_tls_asset.dart';

/// Loads the optional native TLS helper only for encrypted connections.
///
/// Resolution order:
/// 1. `MSSQL_TLS_LIBRARY` absolute path override
/// 2. Code asset registered by `hook/build.dart` ([nativeTlsAssetId])
/// 3. Platform linker name (bundled app library, or `PATH` / cwd)
/// 4. Checked-out desktop helper under `native/bin/...` or `dist/macos/...`
DynamicLibrary loadMssqlTls() {
  final platform = Platform.operatingSystem;
  final name = nativeTlsLibraryName(platform);
  final override = Platform.environment['MSSQL_TLS_LIBRARY'];
  if (override != null && override.isNotEmpty) {
    return DynamicLibrary.open(override);
  }

  Object? codeAssetError;
  try {
    // Present on Dart 3.13+ stable; analyzer marks it @Since(3.14).
    // ignore: sdk_version_since
    return DynamicLibrary.codeAsset(nativeTlsAssetId);
  } catch (error) {
    codeAssetError = error;
    // Hooks may be unavailable (older tooling) or not yet run.
  }

  final candidates = nativeTlsLibraryCandidates(
    operatingSystem: platform,
    currentDirectory: Directory.current.path,
    pathSeparator: Platform.pathSeparator,
    architecture: _currentArchitecture(),
  );
  Object? lastError;
  for (final candidate in candidates) {
    try {
      return DynamicLibrary.open(candidate);
    } catch (error) {
      lastError = error;
    }
  }
  throw UnsupportedError(
    'Encrypted SQL Server connections require the native TLS helper '
    '($name). Run `dart pub get` so hook/build.dart can download it, or set '
    'MSSQL_TLS_LIBRARY. Cleartext connections do not require it. '
    'Code asset error: $codeAssetError. Fallback error: $lastError',
  );
}

/// Returns the helper filename for a supported native TLS platform.
String nativeTlsLibraryName(String operatingSystem) =>
    switch (operatingSystem) {
      'windows' => 'mssql_tls.dll',
      'linux' || 'android' => 'libmssql_tls.so',
      'macos' || 'ios' => 'libmssql_tls.dylib',
      _ => throw UnsupportedError(
        'Native SQL Server TLS is not supported on $operatingSystem.',
      ),
    };

/// Returns path-based lookup candidates after the code-asset attempt.
///
/// Mobile dynamic linkers resolve libraries bundled into the app by name.
/// Desktop development keeps a checked-out helper as a convenient fallback.
List<String> nativeTlsLibraryCandidates({
  required String operatingSystem,
  required String currentDirectory,
  required String pathSeparator,
  String? override,
  String? architecture,
}) {
  final name = nativeTlsLibraryName(operatingSystem);
  return <String>[
    if (override != null && override.isNotEmpty) override,
    name,
    if (operatingSystem == 'linux' || operatingSystem == 'windows')
      '$currentDirectory${pathSeparator}native${pathSeparator}bin'
          '$pathSeparator${operatingSystem == 'windows' ? 'windows-x64' : 'linux-x64'}'
          '$pathSeparator$name',
    if (operatingSystem == 'macos' && architecture != null)
      '$currentDirectory${pathSeparator}dist${pathSeparator}macos'
          '$pathSeparator${architecture == 'x64' ? 'x86_64' : architecture}'
          '$pathSeparator$name',
  ];
}

String? _currentArchitecture() {
  final abi = Abi.current();
  if (abi == Abi.androidArm || abi == Abi.iosArm) return 'arm';
  if (abi == Abi.androidArm64 ||
      abi == Abi.iosArm64 ||
      abi == Abi.linuxArm64 ||
      abi == Abi.macosArm64 ||
      abi == Abi.windowsArm64) {
    return 'arm64';
  }
  if (abi == Abi.androidX64 ||
      abi == Abi.iosX64 ||
      abi == Abi.linuxX64 ||
      abi == Abi.macosX64 ||
      abi == Abi.windowsX64) {
    return 'x64';
  }
  return null;
}
