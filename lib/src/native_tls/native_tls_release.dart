/// Describes which GitHub Release zip / member file to fetch for a target.
final class NativeTlsReleaseAsset {
  /// Release asset basename, e.g. `mssql-tls-linux-x64.zip`.
  final String zipName;

  /// Path inside the zip to the dynamic library.
  final String libraryPathInZip;

  /// Filename written next to the extracted library for checksum verification.
  final String libraryFileName;

  /// Checked-out fallback under the package root (may be null).
  final String? localPackageRelativePath;

  const NativeTlsReleaseAsset({
    required this.zipName,
    required this.libraryPathInZip,
    required this.libraryFileName,
    this.localPackageRelativePath,
  });
}

/// Maps a Dart native-assets target to a prebuilt release asset.
///
/// Returns `null` when this package does not ship a helper for the target.
NativeTlsReleaseAsset? nativeTlsReleaseAsset({
  required String operatingSystem,
  required String architecture,
}) {
  switch (operatingSystem) {
    case 'linux':
      if (architecture == 'x64') {
        return const NativeTlsReleaseAsset(
          zipName: 'mssql-tls-linux-x64.zip',
          libraryPathInZip: 'libmssql_tls.so',
          libraryFileName: 'libmssql_tls.so',
          localPackageRelativePath: 'native/bin/linux-x64/libmssql_tls.so',
        );
      }
      return null;
    case 'windows':
      if (architecture == 'x64') {
        return const NativeTlsReleaseAsset(
          zipName: 'mssql-tls-windows-x64.zip',
          libraryPathInZip: 'mssql_tls.dll',
          libraryFileName: 'mssql_tls.dll',
          localPackageRelativePath: 'native/bin/windows-x64/mssql_tls.dll',
        );
      }
      return null;
    case 'android':
      final abi = switch (architecture) {
        'arm64' => 'arm64-v8a',
        'arm' => 'armeabi-v7a',
        'x64' => 'x86_64',
        _ => null,
      };
      if (abi == null) return null;
      return NativeTlsReleaseAsset(
        zipName: 'mssql-tls-android.zip',
        libraryPathInZip: '$abi/libmssql_tls.so',
        libraryFileName: 'libmssql_tls.so',
        localPackageRelativePath: 'dist/android/$abi/libmssql_tls.so',
      );
    default:
      return null;
  }
}

/// Builds the GitHub Releases download URL for [zipName] at [releaseTag].
Uri nativeTlsReleaseUri({
  required String releaseTag,
  required String zipName,
  String repository = 'Alexqwesa/mssql-dart',
}) =>
    Uri.https(
      'github.com',
      '/$repository/releases/download/$releaseTag/$zipName',
    );

/// Parses a `SHA256SUMS` file and returns the expected digest for [fileName].
String? sha256FromSums(String sumsText, String fileName) {
  for (final rawLine in sumsText.split(RegExp(r'\r?\n'))) {
    final line = rawLine.trim();
    if (line.isEmpty || line.startsWith('#')) continue;
    final parts = line.split(RegExp(r'\s+'));
    if (parts.length < 2) continue;
    final hash = parts[0].toLowerCase();
    var name = parts.sublist(1).join(' ');
    if (name.startsWith('*') || name.startsWith(' ')) {
      name = name.substring(1);
    }
    if (name == fileName || name.endsWith('/$fileName')) {
      return hash;
    }
  }
  return null;
}
