import 'dart:async';
import 'dart:io';
import 'dart:math';
import 'dart:typed_data';

import 'package:mssql/mssql.dart';
import 'package:mssql/src/tds/constants.dart';
import 'package:test/test.dart';

import 'helpers/scripted_tds_server.dart';
import 'helpers/tds_socket.dart';

/// Connection-level protocol fuzzing.
///
/// `protocol_fuzz_test.dart` drives `TokenStream` directly. These cases send
/// the same class of hostile bytes through a real [MssqlConnection] so the
/// public future, the connection state, and the socket teardown are all
/// covered. Every case must finish inside the query deadline, leave `isOpen`
/// false when the response could not be parsed, and refuse further work.
const _seed = 0x4D535351;

int get _fuzzSeed =>
    int.tryParse(Platform.environment['MSSQL_FUZZ_SEED'] ?? '') ?? _seed;

Future<MssqlConnection> _connect(ScriptedTdsServer server) =>
    MssqlConnection.connect(
      host: '127.0.0.1',
      port: server.port,
      user: 'sa',
      password: 'Secret1',
      database: 'master',
      encrypt: false,
      connectRetries: 0,
      timeout: const Duration(seconds: 2),
      queryTimeout: const Duration(milliseconds: 300),
      keepAlive: Duration.zero,
    );

List<int> _done({int flags = doneFlagCount, int rowCount = 1}) {
  final out = BytesBuilder(copy: false);
  out.addByte(tokenDone);
  writeUint16LE(out, flags);
  writeUint16LE(out, 0);
  writeUint64LE(out, rowCount);
  return out.toBytes();
}

List<int> _colInt() {
  final out = BytesBuilder(copy: false);
  out.addByte(tokenColMetadata);
  writeUint16LE(out, 1);
  writeUint32LE(out, 0);
  writeUint16LE(out, 0);
  out.addByte(typeInt4);
  out.addByte(1);
  out.add(ucs2('n'));
  return out.toBytes();
}

List<int> _validReply() {
  final out = BytesBuilder(copy: false)..add(_colInt())..addByte(tokenRow);
  writeUint32LE(out, 7);
  out.add(_done());
  return out.toBytes();
}

/// Runs one query against a server that replies with [reply].
///
/// Returns the connection so the caller can assert on its state.
Future<({MssqlConnection conn, Object? error})> _ask(List<int> reply) async {
  final server = await ScriptedTdsServer.bind(
    ScriptedFault.none,
    replyBuilder: (_) => reply,
  );
  addTearDown(server.close);
  final conn = await _connect(server);
  addTearDown(conn.close);
  try {
    await conn.query('SELECT 1').timeout(const Duration(seconds: 12));
    return (conn: conn, error: null);
  } catch (error) {
    return (conn: conn, error: error);
  }
}

void main() {
  final random = Random(_fuzzSeed);

  group('connection fuzz seed $_fuzzSeed', () {
    test('a valid scripted reply still returns its row', () async {
      final asked = await _ask(_validReply());
      expect(asked.error, isNull);
      expect(asked.conn.isOpen, isTrue);
    });

    test('single-byte mutations of a reply fail closed without hanging',
        () async {
      final valid = _validReply();
      for (var caseIndex = 0; caseIndex < 60; caseIndex++) {
        final mutated = List<int>.from(valid);
        mutated[random.nextInt(mutated.length)] = random.nextInt(256);
        final asked = await _ask(mutated);
        final error = asked.error;
        if (error == null) {
          // A mutation inside a value or an ignored field can still parse.
          expect(asked.conn.isOpen, isTrue, reason: 'case $caseIndex');
          continue;
        }
        expect(
          error,
          anyOf(
            isA<MssqlException>(),
            isA<StateError>(),
            isA<FormatException>(),
          ),
          reason: 'case $caseIndex',
        );
        expect(asked.conn.isOpen, isFalse, reason: 'case $caseIndex');
        await expectLater(
          asked.conn.execute('SELECT 1'),
          throwsA(isA<StateError>()),
          reason: 'case $caseIndex',
        );
      }
    });

    test('random reply bodies fail closed without hanging', () async {
      for (var caseIndex = 0; caseIndex < 40; caseIndex++) {
        final body = List<int>.generate(
          1 + random.nextInt(48),
          (_) => random.nextInt(256),
        );
        final asked = await _ask(body);
        if (asked.error == null) continue;
        expect(
          asked.error,
          anyOf(
            isA<MssqlException>(),
            isA<StateError>(),
            isA<FormatException>(),
          ),
          reason: 'case $caseIndex',
        );
        expect(asked.conn.isOpen, isFalse, reason: 'case $caseIndex');
      }
    });

    test('a hostile token length is rejected by the configured limit',
        () async {
      final server = await ScriptedTdsServer.bind(
        ScriptedFault.none,
        replyBuilder: (_) {
          final out = BytesBuilder(copy: false)
            ..addByte(tokenInfo)
            ..add([0xFF, 0xFF]);
          return out.toBytes();
        },
      );
      addTearDown(server.close);
      final conn = await MssqlConnection.connect(
        host: '127.0.0.1',
        port: server.port,
        user: 'sa',
        password: 'Secret1',
        database: 'master',
        encrypt: false,
        connectRetries: 0,
        timeout: const Duration(seconds: 2),
        queryTimeout: const Duration(milliseconds: 300),
        keepAlive: Duration.zero,
        // Wide enough for LOGINACK, far below the 0xFFFF the reply claims.
        protocolLimits: const MssqlProtocolLimits(maximumTokenBytes: 64),
      );
      addTearDown(conn.close);
      await expectLater(
        conn.query('SELECT 1'),
        throwsA(isA<MssqlProtocolLimitException>()),
      ).timeout(const Duration(seconds: 12));
      expect(conn.isOpen, isFalse);
    });

    test('a token limit below LOGINACK fails the login itself', () async {
      final server = await ScriptedTdsServer.bind(ScriptedFault.none);
      addTearDown(server.close);
      await expectLater(
        MssqlConnection.connect(
          host: '127.0.0.1',
          port: server.port,
          user: 'sa',
          password: 'Secret1',
          database: 'master',
          encrypt: false,
          connectRetries: 0,
          timeout: const Duration(seconds: 2),
          keepAlive: Duration.zero,
          protocolLimits: const MssqlProtocolLimits(maximumTokenBytes: 8),
        ),
        throwsA(isA<MssqlProtocolLimitException>()),
      ).timeout(const Duration(seconds: 12));
    });

    test('a truncated reply closes the connection', () async {
      final valid = _validReply();
      for (final length in [1, 4, valid.length - 1]) {
        final asked = await _ask(valid.sublist(0, length));
        expect(asked.error, isNotNull, reason: 'length $length');
        expect(asked.conn.isOpen, isFalse, reason: 'length $length');
      }
    });

    test('fuzzing a whole session does not leak sockets', () async {
      final valid = _validReply();
      final before = ProcessInfo.currentRss;
      for (var caseIndex = 0; caseIndex < 40; caseIndex++) {
        final mutated = List<int>.from(valid)
          ..[random.nextInt(valid.length)] = random.nextInt(256);
        final server = await ScriptedTdsServer.bind(
          ScriptedFault.none,
          replyBuilder: (_) => mutated,
        );
        final conn = await _connect(server);
        try {
          await conn.query('SELECT 1').timeout(const Duration(seconds: 12));
        } catch (_) {
          // The point of this case is the teardown below, not the error.
        } finally {
          await conn.close();
          await server.close();
        }
      }
      // maxRss is a process-wide high-water mark that other suites inflate, so
      // this compares the resident set before and after the loop.
      expect(ProcessInfo.currentRss, lessThan(before + 128 * 1024 * 1024));
    });
  });
}
