// Regenerates or verifies lib/src/native_tls/native_tls_pins.dart from local
// helper builds and/or extracted GitHub Release / CI artifact directories.
//
// Examples:
//   dart run tool/update_native_tls_pins.dart
//   dart run tool/update_native_tls_pins.dart --from-dir path/to/native-assets
//   dart run tool/update_native_tls_pins.dart --from-dir path/to/native-assets --check --require-all
//   dart run tool/update_native_tls_pins.dart --tag v0.5.3 --output /tmp/native_tls_pins.dart
import 'dart:io';

import 'package:crypto/crypto.dart';
import 'package:mssql_driver_with_native_tls/src/native_tls/native_tls_pins.dart';
import 'package:mssql_driver_with_native_tls/src/native_tls/native_tls_release.dart';

const _targets = <(String os, String arch)>[
  ('linux', 'x64'),
  ('windows', 'x64'),
  ('android', 'arm64'),
  ('android', 'arm'),
  ('android', 'x64'),
];

Future<void> main(List<String> args) async {
  final root = Directory.current;
  var tag = _readPubspecVersion(root);
  if (!tag.startsWith('v')) tag = 'v$tag';
  Directory? fromDir;
  File? output;
  var check = false;
  var requireAll = false;

  for (var i = 0; i < args.length; i++) {
    final arg = args[i];
    if (arg == '--tag' && i + 1 < args.length) {
      tag = args[++i];
      if (!tag.startsWith('v')) tag = 'v$tag';
    } else if (arg == '--from-dir' && i + 1 < args.length) {
      fromDir = Directory(args[++i]);
    } else if (arg == '--output' && i + 1 < args.length) {
      output = File(args[++i]);
    } else if (arg == '--check') {
      check = true;
    } else if (arg == '--require-all') {
      requireAll = true;
    } else if (arg == '--help' || arg == '-h') {
      stdout.writeln('''
Usage: dart run tool/update_native_tls_pins.dart [options]

Options:
  --tag vX.Y.Z          Release tag to embed (default: v + pubspec version)
  --from-dir <path>     CI/Release artifact root (mssql-tls-* directories)
  --output <path>       Write pins here instead of lib/src/native_tls/native_tls_pins.dart
  --check               Verify artifacts against committed in-repo pins (no write)
  --require-all         Fail if any supported platform library is missing
''');
      return;
    } else {
      stderr.writeln('Unknown argument: $arg');
      exitCode = 64;
      return;
    }
  }

  final found = <String, String>{};
  final missing = <String>[];
  for (final (os, arch) in _targets) {
    final asset = nativeTlsReleaseAsset(
      operatingSystem: os,
      architecture: arch,
    );
    if (asset == null) continue;
    final key = '$os/$arch';
    final file = _locateLibrary(
      root: root,
      fromDir: fromDir,
      asset: asset,
    );
    if (file == null) {
      missing.add(key);
      stdout.writeln('skip  $key (not found)');
      continue;
    }
    final digest = sha256.convert(await file.readAsBytes()).toString();
    found[key] = digest;
    stdout.writeln('hash  $key  $digest  (${file.path})');
  }

  if (found.isEmpty) {
    stderr.writeln(
      'No native libraries found. Build with tool/build_native.sh / '
      'tool/build_android_native.sh, or pass --from-dir with extracted '
      'mssql-tls-* artifacts.',
    );
    exitCode = 1;
    return;
  }

  if (requireAll && missing.isNotEmpty) {
    stderr.writeln(
      'Missing required native libraries: ${missing.join(', ')}',
    );
    exitCode = 1;
    return;
  }

  if (check) {
    var ok = true;
    final tagMatches = nativeTlsPinnedReleaseTag == tag;
    if (!tagMatches) {
      final msg =
          'Pinned release tag is $nativeTlsPinnedReleaseTag but package '
          'expects $tag. Commit an updated pin manifest before tagging.';
      if (requireAll) {
        stderr.writeln(msg);
        ok = false;
      } else {
        stdout.writeln('warn  $msg (skipping digest compare)');
        stdout.writeln('Pin check passed for $tag (incomplete / prep).');
        return;
      }
    }
    for (final entry in found.entries) {
      final pinned = nativeTlsPinnedSha256[entry.key];
      if (pinned == null || pinned.isEmpty) {
        final msg = 'Missing in-repo pin for ${entry.key}';
        if (requireAll) {
          stderr.writeln(msg);
          ok = false;
        } else {
          stdout.writeln('warn  $msg');
        }
        continue;
      }
      if (pinned != entry.value) {
        stderr.writeln(
          'Pin mismatch for ${entry.key}: in-repo $pinned vs artifact '
          '${entry.value}',
        );
        ok = false;
      } else {
        stdout.writeln('ok    ${entry.key}');
      }
    }
    for (final key in nativeTlsPinnedSha256.keys) {
      if (!found.containsKey(key)) {
        final msg =
            'In-repo pin for $key has no matching artifact in this check';
        if (requireAll) {
          stderr.writeln(msg);
          ok = false;
        } else {
          stdout.writeln('warn  $msg');
        }
      }
    }
    if (!ok) {
      exitCode = 1;
      return;
    }
    stdout.writeln('Pin check passed for $tag.');
    return;
  }

  final out = output ??
      File.fromUri(root.uri.resolve('lib/src/native_tls/native_tls_pins.dart'));
  out.parent.createSync(recursive: true);
  await out.writeAsString(_renderPins(tag: tag, pins: found));
  stdout.writeln('Wrote ${out.path}');
}

File? _locateLibrary({
  required Directory root,
  required Directory? fromDir,
  required NativeTlsReleaseAsset asset,
}) {
  final candidates = <File>[];
  if (fromDir != null) {
    // CI download layout: native-assets/mssql-tls-linux-x64/libmssql_tls.so
    // or a flat extract of the zip contents.
    final zipStem = asset.zipName.replaceAll(RegExp(r'\.zip$'), '');
    candidates.addAll([
      File.fromUri(fromDir.uri.resolve('$zipStem/${asset.libraryPathInZip}')),
      File.fromUri(fromDir.uri.resolve(asset.libraryPathInZip)),
      File.fromUri(fromDir.uri.resolve(asset.libraryFileName)),
    ]);
  }
  if (asset.localPackageRelativePath != null) {
    candidates.add(
      File.fromUri(root.uri.resolve(asset.localPackageRelativePath!)),
    );
  }
  for (final file in candidates) {
    if (file.existsSync()) return file;
  }
  return null;
}

String _readPubspecVersion(Directory root) {
  final text = File.fromUri(root.uri.resolve('pubspec.yaml')).readAsStringSync();
  final match = RegExp(
    r'^version:\s*(\S+)\s*$',
    multiLine: true,
  ).firstMatch(text);
  if (match == null) {
    throw StateError('Could not read version from pubspec.yaml');
  }
  return match.group(1)!;
}

String _renderPins({
  required String tag,
  required Map<String, String> pins,
}) {
  final entries = pins.entries.toList()
    ..sort((a, b) => a.key.compareTo(b.key));
  final buffer = StringBuffer()
    ..writeln('// In-repo SHA-256 pins for GitHub Release native TLS helpers.')
    ..writeln('//')
    ..writeln('// Update with:')
    ..writeln('//   dart run tool/update_native_tls_pins.dart --from-dir <ci-artifacts>')
    ..writeln('// Prefer hashing the exact CI / Release zip members that will be')
    ..writeln('// published for nativeTlsPinnedReleaseTag, then commit this file before')
    ..writeln('// tagging that release.')
    ..writeln()
    ..writeln(
      '/// Release tag whose helpers are pinned below (`v` + `pubspec` version).',
    )
    ..writeln("const String nativeTlsPinnedReleaseTag = '$tag';")
    ..writeln()
    ..writeln(
      '/// Map of `<os>/<arch>` → lowercase hex SHA-256 of the dynamic library.',
    )
    ..writeln('///')
    ..writeln('/// Keys match [nativeTlsPinKey].')
    ..writeln('const Map<String, String> nativeTlsPinnedSha256 = {');
  for (final entry in entries) {
    buffer.writeln("  '${entry.key}':");
    buffer.writeln("      '${entry.value}',");
  }
  buffer
    ..writeln('};')
    ..writeln()
    ..writeln('/// Stable pin map key for a native-assets target.')
    ..writeln('String nativeTlsPinKey({')
    ..writeln('  required String operatingSystem,')
    ..writeln('  required String architecture,')
    ..writeln('}) =>')
    ..writeln(r"    '$operatingSystem/$architecture';")
    ..writeln()
    ..writeln(
      '/// Returns the pinned SHA-256 for [releaseTag] + target, or `null` if absent.',
    )
    ..writeln('String? nativeTlsPinnedDigest({')
    ..writeln('  required String releaseTag,')
    ..writeln('  required String operatingSystem,')
    ..writeln('  required String architecture,')
    ..writeln('}) {')
    ..writeln('  if (releaseTag != nativeTlsPinnedReleaseTag) return null;')
    ..writeln('  return nativeTlsPinnedSha256[nativeTlsPinKey(')
    ..writeln('    operatingSystem: operatingSystem,')
    ..writeln('    architecture: architecture,')
    ..writeln('  )];')
    ..writeln('}')
    ..writeln();
  return buffer.toString();
}
