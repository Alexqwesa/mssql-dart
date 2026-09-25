import 'dart:async';
import 'dart:io';
import 'dart:math';
import 'dart:typed_data';

import 'package:mssql/mssql.dart';
import 'package:mssql/src/tds/buf.dart';
import 'package:mssql/src/tds/constants.dart';
import 'package:mssql/src/tds/token_stream.dart';
import 'package:test/test.dart';

import 'helpers/tds_socket.dart';

const _seed = 0x4D535351;

int get _fuzzSeed =>
    int.tryParse(Platform.environment['MSSQL_FUZZ_SEED'] ?? '') ?? _seed;

Future<void> _expectPrompt(Future<Object?> parse) async {
  try {
    await parse.timeout(const Duration(milliseconds: 250));
    fail('expected malformed protocol input to be rejected');
  } on TimeoutException {
    fail('parser did not reject malformed protocol input promptly');
  } catch (_) {}
}

Future<void> _feed(
  List<int> body,
  Future<Object?> Function(TdsBuffer buf) parse, {
  MssqlProtocolLimits limits = MssqlProtocolLimits.unlimited,
  bool reject = true,
}) async {
  final pair = await TdsSocketPair.open();
  try {
    await tdsSend(pair.server, tdsPacket(type: packReply, body: body));
    await pair.server.close();
    final future = parse(TdsBuffer(pair.client, limits: limits));
    if (reject) {
      await _expectPrompt(future);
    } else {
      await future.timeout(const Duration(milliseconds: 250));
    }
  } finally {
    await pair.close();
  }
}

List<int> _done({int flags = doneFlagFinal, int rowCount = 0}) {
  final out = BytesBuilder(copy: false);
  out.addByte(tokenDone);
  writeUint16LE(out, flags);
  writeUint16LE(out, 0);
  writeUint64LE(out, rowCount);
  return out.toBytes();
}

List<int> _colInt() {
  const name = 'n';
  final out = BytesBuilder(copy: false);
  out.addByte(tokenColMetadata);
  writeUint16LE(out, 1);
  writeUint32LE(out, 0);
  writeUint16LE(out, 0);
  out.addByte(typeInt4);
  out.addByte(name.length);
  out.add(ucs2(name));
  return out.toBytes();
}

List<int> _row(int value) {
  final out = BytesBuilder(copy: false);
  out.addByte(tokenRow);
  writeUint32LE(out, value);
  return out.toBytes();
}

List<int> _validQuery() =>
    [..._colInt(), ..._row(7), ..._done(flags: doneFlagCount, rowCount: 1)];

List<int> _loginReply() {
  const progName = 'Microsoft SQL Server';
  const database = 'master';
  final ack = BytesBuilder(copy: false)
    ..addByte(1)
    ..add([0x74, 0x00, 0x00, 0x04])
    ..addByte(progName.length)
    ..add(ucs2(progName));
  writeUint32LE(ack, 0x01000000);
  final ackBytes = ack.toBytes();

  final env = BytesBuilder(copy: false)
    ..addByte(envDatabase)
    ..addByte(database.length)
    ..add(ucs2(database))
    ..addByte(database.length)
    ..add(ucs2(database));
  final envBytes = env.toBytes();

  final out = BytesBuilder(copy: false)
    ..addByte(tokenLoginAck)
    ..addByte(ackBytes.length & 0xFF)
    ..addByte((ackBytes.length >> 8) & 0xFF)
    ..add(ackBytes)
    ..addByte(tokenEnvChange)
    ..addByte(envBytes.length & 0xFF)
    ..addByte((envBytes.length >> 8) & 0xFF)
    ..add(envBytes)
    ..add(_done());
  return out.toBytes();
}

/// Sends [body] as two TDS packets split at [cut] and runs [parse].
///
/// The server socket stays open until [parse] finishes so a short first
/// packet is not turned into an end-of-stream before the second packet is read.
Future<T> _split<T>(
  List<int> body,
  int cut,
  Future<T> Function(TdsBuffer buf) parse, {
  int packetType = packReply,
}) async {
  final pair = await TdsSocketPair.open();
  try {
    await tdsSend(
      pair.server,
      tdsPacket(
        type: packetType,
        body: body.sublist(0, cut),
        eom: false,
      ),
    );
    await tdsSend(
      pair.server,
      tdsPacket(
        type: packetType,
        body: body.sublist(cut),
        eom: true,
        seq: 2,
      ),
    );
    return await parse(TdsBuffer(pair.client))
        .timeout(const Duration(milliseconds: 250));
  } finally {
    await pair.close();
  }
}

void main() {
  final random = Random(_fuzzSeed);

  group('protocol fuzz seed $_fuzzSeed', () {
    test('valid replies split at random offsets still parse', () async {
      final query = _validQuery();
      final login = _loginReply();
      final attention = _done(flags: doneFlagAttn);
      for (var i = 0; i < 60; i++) {
        final queryResult = await _split(
          query,
          1 + random.nextInt(query.length - 1),
          (buf) => TokenStream(buf).processQueryResponse(),
        );
        expect(queryResult.rows.single, [7]);

        final loginResult = await _split(
          login,
          1 + random.nextInt(login.length - 1),
          (buf) => TokenStream(buf).processLoginResponse(),
        );
        expect(loginResult.database, 'master');

        final bulkResult = await _split(
          query,
          1 + random.nextInt(query.length - 1),
          (buf) => TokenStream(buf).processQueryResponse(),
          packetType: packBulkLoadBCP,
        );
        expect(bulkResult.rows.single, [7]);

        final attentionResult = await _split(
          attention,
          1 + random.nextInt(attention.length - 1),
          (buf) => TokenStream(buf).processQueryResponse(),
        );
        expect(attentionResult.rows, isEmpty);
      }
    });

    test('truncated prefixes and swapped token types reject promptly', () async {
      final valid = _validQuery();
      for (var length = 0; length < valid.length; length += 3) {
        await _feed(
          valid.sublist(0, length),
          (buf) => TokenStream(buf).processQueryResponse(),
        );
      }
      final swapped = List<int>.from(valid)..[0] = tokenLoginAck;
      await _feed(swapped, (buf) => TokenStream(buf).processQueryResponse());
    });

    test('hostile lengths fail before a large buffer is allocated', () async {
      const limits = MssqlProtocolLimits(maximumTokenBytes: 8);
      expect(
        () => limits.checkTokenBytes(0, 'fuzz'),
        returnsNormally,
      );
      expect(
        () => limits.checkTokenBytes(1, 'fuzz'),
        returnsNormally,
      );
      expect(
        () => limits.checkTokenBytes(0x7FFFFFFF, 'fuzz'),
        throwsA(isA<MssqlProtocolLimitException>()),
      );
      expect(
        () => limits.checkTokenBytes(
          MssqlProtocolLimits.defaultMaximumTokenBytes + 1,
          'fuzz',
        ),
        throwsA(isA<MssqlProtocolLimitException>()),
      );

      final info = BytesBuilder(copy: false)
        ..addByte(tokenInfo)
        ..addByte(0xFF)
        ..addByte(0xFF);
      await _feed(
        info.toBytes(),
        (buf) => TokenStream(buf).processQueryResponse(),
        limits: limits,
      );
    });

    test('ROW before metadata and attention DONE mid-stream reject or end',
        () async {
      await _feed(
        [..._row(1), ..._done()],
        (buf) => TokenStream(buf).processQueryResponse(),
      );
      final midAttn = [..._colInt(), ..._done(flags: doneFlagAttn), ..._row(1)];
      final pair = await TdsSocketPair.open();
      addTearDown(pair.close);
      await tdsSend(pair.server, tdsPacket(type: packReply, body: midAttn));
      await pair.server.close();
      try {
        final result = await TokenStream(TdsBuffer(pair.client))
            .processQueryResponse()
            .timeout(const Duration(milliseconds: 250));
        expect(result.rows, isEmpty);
      } on StateError {
        // Adversarial bytes after the attention DONE are rejected.
      }
    });

    test('duplicated ERROR then a short read rejects promptly', () async {
      final error = BytesBuilder(copy: false)
        ..addByte(tokenError)
        ..addByte(4)
        ..addByte(0)
        ..add([1, 0, 0, 0]);
      await _feed(
        [...error.toBytes(), ...error.toBytes()],
        (buf) => TokenStream(buf).processQueryResponse(),
      );
    });
  });
}
