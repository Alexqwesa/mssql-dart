import 'dart:io';

import 'package:test/test.dart';

bool get liveTestsEnabled => Platform.environment['MSSQL_LIVE_TESTS'] == '1';

void registerLiveTestsDisabled() {
  test(
    'live SQL Server tests are disabled',
    () {},
    skip: 'Set MSSQL_LIVE_TESTS=1 to run test/live.',
  );
}
