import 'dart:io';
import 'dart:typed_data';

import 'package:archive/archive.dart';
import 'package:code_assets/code_assets.dart';
import 'package:crypto/crypto.dart';
import 'package:hooks/hooks.dart';
import 'package:http/http.dart' as http;
import 'package:mssql_native/src/native_tls/native_tls_asset.dart';
import 'package:mssql_native/src/native_tls/native_tls_release.dart';

Future<void> main(List<String> args) async {
  await build(args, (input, output) async {
    if (!input.config.buildCodeAssets) return;

    final code = input.config.code;
    if (code.linkModePreference == LinkModePreference.static) {
      throw UnsupportedError(
        'mssql_native TLS helper only supports dynamic loading.',
      );
    }

    final asset = nativeTlsReleaseAsset(
      operatingSystem: code.targetOS.name,
      architecture: code.targetArchitecture.name,
    );
    if (asset == null) {
      throw UnsupportedError(
        'No prebuilt native TLS helper for '
        '${code.targetOS.name}/${code.targetArchitecture.name}. '
        'Supported: linux/x64, windows/x64, android arm/arm64/x64.',
      );
    }

    final localOnly = input.userDefines['local_only'] == true;
    final forceDownload = input.userDefines['force_download'] == true;
    final releaseTag = _releaseTag(input);

    final libraryFile = await _resolveLibrary(
      input: input,
      output: output,
      asset: asset,
      releaseTag: releaseTag,
      localOnly: localOnly,
      forceDownload: forceDownload,
    );

    output.assets.code.add(
      CodeAsset(
        package: input.packageName,
        name: nativeTlsAssetName,
        linkMode: DynamicLoadingBundled(),
        file: libraryFile.uri,
      ),
    );
  });
}

String _releaseTag(BuildInput input) {
  final override = input.userDefines['release_tag'];
  if (override is String && override.isNotEmpty) return override;
  final version = _packageVersion(input.packageRoot);
  return version.startsWith('v') ? version : 'v$version';
}

String _packageVersion(Uri packageRoot) {
  final pubspec = File.fromUri(packageRoot.resolve('pubspec.yaml'));
  final text = pubspec.readAsStringSync();
  final match = RegExp(
    r'^version:\s*(\S+)\s*$',
    multiLine: true,
  ).firstMatch(text);
  if (match == null) {
    throw StateError('Could not read version from ${pubspec.path}');
  }
  return match.group(1)!;
}

Future<File> _resolveLibrary({
  required BuildInput input,
  required BuildOutputBuilder output,
  required NativeTlsReleaseAsset asset,
  required String releaseTag,
  required bool localOnly,
  required bool forceDownload,
}) async {
  final packageLocal = asset.localPackageRelativePath == null
      ? null
      : File.fromUri(
          input.packageRoot.resolve(asset.localPackageRelativePath!),
        );
  if (!forceDownload && packageLocal != null && await packageLocal.exists()) {
    output.dependencies.add(packageLocal.uri);
    return packageLocal;
  }

  final cacheDir = Directory.fromUri(
    input.outputDirectoryShared.resolve(
      'mssql_tls/$releaseTag/'
      '${input.config.code.targetOS.name}-'
      '${input.config.code.targetArchitecture.name}/',
    ),
  );
  await cacheDir.create(recursive: true);
  final cachedLibrary = File.fromUri(
    cacheDir.uri.resolve(asset.libraryFileName),
  );
  final cachedSums = File.fromUri(cacheDir.uri.resolve('SHA256SUMS'));
  if (!forceDownload &&
      await cachedLibrary.exists() &&
      await cachedSums.exists()) {
    await _verifySha256(cachedLibrary, cachedSums, asset.libraryFileName);
    return cachedLibrary;
  }

  if (localOnly) {
    throw StateError(
      'Native TLS helper not found locally for '
      '${input.config.code.targetOS.name}/'
      '${input.config.code.targetArchitecture.name}. '
      'Build it with tool/build_native.sh (or the Android script), or unset '
      'hooks.user_defines.mssql_native.local_only to download a release.',
    );
  }

  final uri = nativeTlsReleaseUri(
    releaseTag: releaseTag,
    zipName: asset.zipName,
    repository: nativeTlsReleaseRepo,
  );
  final response = await http.get(uri);
  if (response.statusCode != 200) {
    throw StateError(
      'Failed to download native TLS helper from $uri '
      '(HTTP ${response.statusCode}). '
      'Publish a GitHub Release asset or place the library at '
      '${packageLocal?.path ?? asset.libraryFileName}.',
    );
  }

  final archive = ZipDecoder().decodeBytes(response.bodyBytes);
  final libraryBytes = _archiveFileBytes(archive, asset.libraryPathInZip);
  final sumsBytes = _archiveFileBytes(
    archive,
    _sumsPathFor(asset.libraryPathInZip),
  );

  await cachedLibrary.writeAsBytes(libraryBytes, flush: true);
  await cachedSums.writeAsBytes(sumsBytes, flush: true);
  await _verifySha256(cachedLibrary, cachedSums, asset.libraryFileName);
  return cachedLibrary;
}

String _sumsPathFor(String libraryPathInZip) {
  final slash = libraryPathInZip.lastIndexOf('/');
  if (slash < 0) return 'SHA256SUMS';
  return '${libraryPathInZip.substring(0, slash + 1)}SHA256SUMS';
}

Uint8List _archiveFileBytes(Archive archive, String path) {
  final normalized = path.replaceAll('\\', '/');
  for (final file in archive.files) {
    if (!file.isFile) continue;
    final name = file.name.replaceAll('\\', '/');
    if (name == normalized || name.endsWith('/$normalized')) {
      return Uint8List.fromList(file.content);
    }
  }
  throw StateError('Zip is missing required member "$path".');
}

Future<void> _verifySha256(
  File library,
  File sumsFile,
  String libraryFileName,
) async {
  final expected = sha256FromSums(
    await sumsFile.readAsString(),
    libraryFileName,
  );
  if (expected == null) {
    throw StateError(
      'SHA256SUMS does not list $libraryFileName (${sumsFile.path}).',
    );
  }
  final actual = sha256.convert(await library.readAsBytes()).toString();
  if (actual != expected) {
    throw StateError(
      'Native TLS helper hash mismatch for ${library.path}: '
      'expected $expected, got $actual.',
    );
  }
}
