import 'dart:ffi';
import 'dart:io';

/// Loads the optional native TLS helper only for encrypted connections.
DynamicLibrary loadMssqlTls() {
  final name = switch (Platform.operatingSystem) {
    'windows' => 'mssql_tls.dll',
    'linux' => 'libmssql_tls.so',
    _ => throw UnsupportedError(
        'Native SQL Server TLS is not supported on ${Platform.operatingSystem}.',
      ),
  };
  final override = Platform.environment['MSSQL_TLS_LIBRARY'];
  final candidates = <String>[
    if (override != null && override.isNotEmpty) override,
    name,
    '${Directory.current.path}${Platform.pathSeparator}native'
        '${Platform.pathSeparator}bin${Platform.pathSeparator}'
        '${Platform.isWindows ? 'windows-x64' : 'linux-x64'}'
        '${Platform.pathSeparator}$name',
  ];
  Object? lastError;
  for (final candidate in candidates) {
    try {
      return DynamicLibrary.open(candidate);
    } catch (error) {
      lastError = error;
    }
  }
  {
    throw UnsupportedError(
      'Encrypted SQL Server connections require the optional native TLS helper '
      '($name). Cleartext connections do not require it. ($lastError)',
    );
  }
}
