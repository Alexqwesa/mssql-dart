import 'dart:io';

/// Whether [mssqlDebug] writes anything.
///
/// Initialized from `MSSQL_DEBUG` (`1` or `true`); assignable so tests and
/// embedders that cannot set environment variables can still turn it on.
bool mssqlDebugEnabled = _envEnabled();

/// Receives finished diagnostic lines, prefix included. Defaults to stderr.
void Function(String line) mssqlDebugSink = stderr.writeln;

/// Reports a failure on a path that cannot propagate one.
///
/// Teardown and pool recycling swallow errors by design — a socket that refuses
/// to close, a rollback that fails while another error is already in flight —
/// so this sink is the only place those details are observable.
void mssqlDebug(String message, [Object? error]) {
  if (!mssqlDebugEnabled) return;
  mssqlDebugSink(
    error == null ? 'dart_mssql: $message' : 'dart_mssql: $message: $error',
  );
}

bool _envEnabled() {
  try {
    final value = Platform.environment['MSSQL_DEBUG']?.toLowerCase();
    return value == '1' || value == 'true';
  } catch (_) {
    return false; // Embedders may deny environment access.
  }
}
