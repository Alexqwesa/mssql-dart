import 'dart:convert';
import 'dart:ffi';
import 'dart:io';
import 'dart:isolate';

import 'package:crypto/crypto.dart';

import 'native_tls_asset.dart';

DynamicLibrary? _loaded;

/// Loads the optional native TLS helper only for encrypted connections, once per isolate.
///
/// Resolution order:
/// 1. `MSSQL_TLS_LIBRARY` absolute path override
/// 2. Code asset registered by `hook/build.dart` ([nativeTlsAssetId]). On Windows, in `dart run` / `dart test`
///    runs, from a private copy ([privateNativeTlsCopy]) instead of the file the Dart tool bundled: every
///    `dart run` / `dart test` of the package replaces that file, and Windows cannot replace a loaded DLL, so a
///    second command would fail while a first one (a running server) has it loaded.
/// 3. Apple framework embedded beside the application executable
/// 4. Platform linker name (bundled app library, or `PATH` / cwd)
/// 5. Checked-out desktop helper under `native/bin/...` or `dist/macos/...`
DynamicLibrary loadMssqlTls() => _loaded ??= _loadMssqlTls();

DynamicLibrary _loadMssqlTls() {
  final platform = Platform.operatingSystem;
  final name = nativeTlsLibraryName(platform);
  final override = Platform.environment['MSSQL_TLS_LIBRARY'];
  if (override != null && override.isNotEmpty) {
    return DynamicLibrary.open(override);
  }

  if (platform == 'windows') {
    final copy = _privateCopyOfBundledAsset();
    if (copy != null) return copy;
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

  final candidates = [
    if (platform == 'macos' || platform == 'ios') _appleFrameworkPath(platform),
    ...nativeTlsLibraryCandidates(
      operatingSystem: platform,
      currentDirectory: Directory.current.path,
      pathSeparator: Platform.pathSeparator,
      architecture: _currentArchitecture(),
    ),
  ];
  Object? lastError;
  for (final candidate in candidates) {
    try {
      return DynamicLibrary.open(candidate);
    } catch (error) {
      lastError = error;
    }
  }
  throw UnsupportedError(
    'Encrypted SQL Server connections need the native TLS helper ($name); '
    'cleartext connections (encrypt: false) do not. The package build hook '
    'downloads it when the program is started or built by the Dart or Flutter '
    'tool (`dart run`, `dart test`, `dart build`, `flutter run`, '
    '`flutter build`; not `dart pub get`). Without network access, see '
    "DEV_README.md, 'Native TLS — local build'. Or set MSSQL_TLS_LIBRARY to "
    'the library file. Code asset error: $codeAssetError. Fallback error: '
    '$lastError',
  );
}

/// The helper as the Dart tool bundled it for a `dart run` / `dart test` run, loaded from a private copy; null
/// when this is not such a run (a compiled or Flutter app) or anything fails (then the code asset is loaded).
DynamicLibrary? _privateCopyOfBundledAsset() {
  try {
    final packageConfig = Isolate.packageConfigSync;
    if (packageConfig == null || !packageConfig.isScheme('file')) return null;
    final mapping = File.fromUri(packageConfig.resolve('native_assets.yaml'));
    if (!mapping.existsSync()) return null;
    final bundled = nativeAssetPathFromMapping(
      mapping.readAsStringSync(),
      target: Abi.current().toString(),
      assetId: nativeTlsAssetId,
    );
    if (bundled == null || !File(bundled).existsSync()) return null;
    return DynamicLibrary.open(privateNativeTlsCopy(File(bundled)));
  } catch (_) {
    return null;
  }
}

/// The file that the native-assets mapping of a `dart run` / `dart test` run (`.dart_tool/native_assets.yaml`,
/// written by the Dart tool) gives for [assetId] on [target] (`Abi.current()`, e.g. `windows_x64`); null when it
/// has none.
String? nativeAssetPathFromMapping(
  String mapping, {
  required String target,
  required String assetId,
}) {
  // JSON after `#` comment lines.
  final json = const LineSplitter()
      .convert(mapping)
      .where((line) => !line.trimLeft().startsWith('#'))
      .join('\n');
  final decoded = jsonDecode(json);
  if (decoded is! Map) return null;
  final assets = decoded['native-assets'];
  if (assets is! Map) return null;
  final forTarget = assets[target];
  if (forTarget is! Map) return null;
  final entry = forTarget[assetId];
  if (entry is List &&
      entry.length == 2 &&
      entry[0] == 'absolute' &&
      entry[1] is String) {
    return entry[1] as String;
  }
  return null;
}

/// Copies [source] to `<temp>/mssql_driver_with_native_tls/<SHA-256 of its content>/` (temp: [root], default
/// the user's temporary directory) unless that copy exists, and returns the copy's path. Named by content:
/// processes share a copy, a changed helper gets a new folder, and an existing copy is never written again, so
/// none is replaced while a process has it loaded.
String privateNativeTlsCopy(File source, {Directory? root}) {
  final sep = Platform.pathSeparator;
  final bytes = source.readAsBytesSync();
  final digest = sha256.convert(bytes).toString();
  final dir = Directory(
    '${(root ?? Directory.systemTemp).path}${sep}mssql_driver_with_native_tls$sep$digest',
  );
  final copy = File('${dir.path}$sep${source.uri.pathSegments.last}');
  if (copy.existsSync() && copy.lengthSync() == bytes.length) return copy.path;

  dir.createSync(recursive: true);
  // Isolates share a pid, so a pid-based filename is not unique. Keep each
  // writer in its own directory on the same filesystem for an atomic rename.
  final staging = dir.createTempSync('copy-');
  final partial = File('${staging.path}${sep}library.partial');
  try {
    partial.writeAsBytesSync(bytes, flush: true);
    try {
      partial.renameSync(copy.path);
    } on FileSystemException {
      // Another process/isolate published the copy and may have loaded it.
      if (!copy.existsSync() || copy.lengthSync() != bytes.length) rethrow;
    }
  } finally {
    staging.deleteSync(recursive: true);
  }
  return copy.path;
}

String _appleFrameworkPath(String platform) {
  final executableDir = File(Platform.resolvedExecutable).parent;

  final frameworksDir = platform == 'macos'
      ? executableDir.parent
      : executableDir;

  return '${frameworksDir.path}/Frameworks/'
      'mssql_tls.framework/mssql_tls';
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
