import 'package:mssql/src/debug.dart';
import 'package:test/test.dart';

/// The diagnostics sink used by teardown and recycling paths, which swallow
/// their errors by design.
void main() {
  final sink = mssqlDebugSink;
  final enabled = mssqlDebugEnabled;
  late List<String> lines;

  setUp(() {
    lines = [];
    mssqlDebugSink = lines.add;
    mssqlDebugEnabled = true;
  });

  tearDown(() {
    mssqlDebugSink = sink;
    mssqlDebugEnabled = enabled;
  });

  test('every line carries the package prefix', () {
    mssqlDebug('closing the socket failed');
    expect(lines.single, 'dart_mssql: closing the socket failed');
  });

  test('an error is appended after the message', () {
    mssqlDebug('closing the socket failed', StateError('boom'));
    expect(
      lines.single,
      'dart_mssql: closing the socket failed: Bad state: boom',
    );
  });

  test('nothing is written while disabled', () {
    mssqlDebugEnabled = false;
    mssqlDebug('closing the socket failed', StateError('boom'));
    expect(lines, isEmpty);
  });
}
