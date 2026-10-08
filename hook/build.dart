import 'dart:io';
import 'dart:typed_data';

import 'package:archive/archive.dart';
import 'package:code_assets/code_assets.dart';
import 'package:crypto/crypto.dart';
import 'package:hooks/hooks.dart';
import 'package:http/http.dart' as http;
import 'package:mssql_driver_with_native_tls/src/native_tls/native_tls_asset.dart';
import 'package:mssql_driver_with_native_tls/src/native_tls/native_tls_pins.dart';
import 'package:mssql_driver_with_native_tls/src/native_tls/native_tls_release.dart';

Future<void> main(List<String> args) async {
  await build(args, (input, output) async {
    if (!input.config.buildCodeAssets) return;

    final code = input.config.code;
    if (code.linkModePreference == LinkModePreference.static) {
      throw UnsupportedError(
        'mssql_driver_with_native_tls TLS helper only supports dynamic loading.',
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
      operatingSystem: code.targetOS.name,
      architecture: code.targetArchitecture.name,
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
  return nativeTlsPinnedReleaseTag;
}

String _requirePin({
  required String releaseTag,
  required String operatingSystem,
  required String architecture,
}) {
  final pin = nativeTlsPinnedDigest(
    releaseTag: releaseTag,
    operatingSystem: operatingSystem,
    architecture: architecture,
  );
  if (pin != null && pin.isNotEmpty) return pin;

  final key = nativeTlsPinKey(
    operatingSystem: operatingSystem,
    architecture: architecture,
  );
  if (releaseTag != nativeTlsPinnedReleaseTag) {
    throw StateError(
      'No in-repo SHA-256 pin for release $releaseTag ($key). '
      'Pinned tag is $nativeTlsPinnedReleaseTag. Either use that tag, or run '
      '`dart run tool/update_native_tls_pins.dart --tag $releaseTag` and '
      'commit lib/src/native_tls/native_tls_pins.dart.',
    );
  }
  throw StateError(
    'No in-repo SHA-256 pin for $key at $releaseTag. '
    'Add it with `dart run tool/update_native_tls_pins.dart` '
    '(preferably from the CI/Release artifacts) and commit '
    'lib/src/native_tls/native_tls_pins.dart before publishing.',
  );
}

Future<File> _resolveLibrary({
  required BuildInput input,
  required BuildOutputBuilder output,
  required NativeTlsReleaseAsset asset,
  required String releaseTag,
  required String operatingSystem,
  required String architecture,
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
    // Dev/CI local builds skip the release pin so iteration is not blocked.
    // Downloaded helpers always require an in-repo pin.
    return packageLocal;
  }

  final pinnedSha256 = _requirePin(
    releaseTag: releaseTag,
    operatingSystem: operatingSystem,
    architecture: architecture,
  );

  final cacheDir = Directory.fromUri(
    input.outputDirectoryShared.resolve(
      'mssql_tls/$releaseTag/$operatingSystem-$architecture/',
    ),
  );
  await cacheDir.create(recursive: true);
  final cachedLibrary = File.fromUri(
    cacheDir.uri.resolve(asset.libraryFileName),
  );
  if (!forceDownload && await cachedLibrary.exists()) {
    await _verifyPinnedSha256(cachedLibrary, pinnedSha256);
    return cachedLibrary;
  }

  if (localOnly) {
    throw StateError(
      'Native TLS helper not found locally for '
      '$operatingSystem/$architecture. '
      'Build it with tool/build_native.sh (or the Android script), or unset '
      'hooks.user_defines.mssql_driver_with_native_tls.local_only to download a release.',
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
  final sumsDigest = sha256FromSums(
    String.fromCharCodes(sumsBytes),
    asset.libraryFileName,
  );
  if (sumsDigest == null) {
    throw StateError(
      'Release zip $uri is missing SHA256SUMS entry for '
      '${asset.libraryFileName}.',
    );
  }
  if (sumsDigest != pinnedSha256) {
    throw StateError(
      'Release zip SHA256SUMS for ${asset.libraryFileName} ($sumsDigest) '
      'does not match the in-repo pin ($pinnedSha256) for $releaseTag. '
      'Refusing to install. Update pins only from trusted CI artifacts.',
    );
  }

  await cachedLibrary.writeAsBytes(libraryBytes, flush: true);
  await _verifyPinnedSha256(cachedLibrary, pinnedSha256);
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

Future<void> _verifyPinnedSha256(File library, String expected) async {
  final actual = sha256.convert(await library.readAsBytes()).toString();
  if (actual != expected) {
    throw StateError(
      'Native TLS helper hash mismatch for ${library.path}: '
      'expected pinned $expected, got $actual.',
    );
  }
}
