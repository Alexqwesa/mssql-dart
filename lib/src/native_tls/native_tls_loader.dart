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
  try {
    return DynamicLibrary.open(name);
  } catch (error) {
    throw UnsupportedError(
      'Encrypted SQL Server connections require the optional native TLS helper '
      '($name). Cleartext connections do not require it. ($error)',
    );
  }
}
