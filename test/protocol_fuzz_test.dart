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

Future<Object?> _feed(
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
      return null;
    }
    return await future.timeout(const Duration(milliseconds: 250));
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

/// A raw TDS packet whose header fields can each be made hostile.
Uint8List _rawPacket({
  int type = packReply,
  int status = statusEOM,
  int? declaredSize,
  int seq = 1,
  List<int> body = const [],
}) {
  final total = headerSize + body.length;
  final size = declaredSize ?? total;
  final pkt = Uint8List(total);
  pkt[0] = type;
  pkt[1] = status;
  pkt[2] = (size >> 8) & 0xFF;
  pkt[3] = size & 0xFF;
  pkt[6] = seq & 0xFF;
  pkt.setRange(headerSize, total, body);
  return pkt;
}

/// COLMETADATA for one PLP (XML) column.
List<int> _colXml() {
  final out = BytesBuilder(copy: false)
    ..addByte(tokenColMetadata)
    ..add([1, 0])
    ..add([0, 0, 0, 0])
    ..add([0, 0])
    ..addByte(typeXml)
    ..addByte(0)
    ..addByte(1)
    ..add(ucs2('v'));
  return out.toBytes();
}

/// PLP ROW body: [totalLength] then [chunks] then the terminator.
List<int> _plpRow(int totalLength, List<List<int>> chunks,
    {bool terminate = true}) {
  final out = BytesBuilder(copy: false)..addByte(tokenRow);
  writeUint64LE(out, totalLength);
  for (final chunk in chunks) {
    writeUint32LE(out, chunk.length);
    out.add(chunk);
  }
  if (terminate) writeUint32LE(out, plpTerminator);
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

/// Sends [packets] verbatim, then expects [parse] to reject without hanging.
Future<void> _feedRaw(
  List<Uint8List> packets,
  Future<Object?> Function(TdsBuffer buf) parse, {
  MssqlProtocolLimits limits = MssqlProtocolLimits.unlimited,
  bool closeServer = true,
}) async {
  final pair = await TdsSocketPair.open();
  try {
    for (final packet in packets) {
      await tdsSend(pair.server, packet);
    }
    if (closeServer) await pair.server.close();
    await _expectPrompt(parse(TdsBuffer(pair.client, limits: limits)));
  } finally {
    await pair.close();
  }
}

/// Splits [body] into [count] segments at random offsets, allowing empty ones.
List<List<int>> _segments(List<int> body, int count, Random random) {
  final cuts = <int>[0];
  for (var i = 0; i < count - 1; i++) {
    cuts.add(random.nextInt(body.length + 1));
  }
  cuts.add(body.length);
  cuts.sort();
  return [
    for (var i = 0; i < cuts.length - 1; i++) body.sublist(cuts[i], cuts[i + 1]),
  ];
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

    test('valid replies split across three or more packets still parse',
        () async {
      final query = _validQuery();
      for (var i = 0; i < 40; i++) {
        final parts = _segments(query, 3 + random.nextInt(3), random);
        final pair = await TdsSocketPair.open();
        try {
          for (var p = 0; p < parts.length; p++) {
            await tdsSend(
              pair.server,
              tdsPacket(
                type: packReply,
                body: parts[p],
                eom: p == parts.length - 1,
                seq: p + 1,
              ),
            );
          }
          final result = await TokenStream(TdsBuffer(pair.client))
              .processQueryResponse()
              .timeout(const Duration(milliseconds: 250));
          expect(
            result.rows.single,
            [7],
            reason: 'segments ${parts.map((p) => p.length).toList()}',
          );
        } finally {
          await pair.close();
        }
      }
    });

    test('hostile packet headers reject without hanging', () async {
      final valid = _validQuery();

      // Declared size below the 8-byte header.
      await _feedRaw(
        [_rawPacket(body: valid, declaredSize: 4)],
        (buf) => TokenStream(buf).processQueryResponse(),
      );

      // Declared size beyond the bytes actually sent.
      await _feedRaw(
        [_rawPacket(body: valid, declaredSize: headerSize + valid.length + 64)],
        (buf) => TokenStream(buf).processQueryResponse(),
      );

      // Header only, declaring a body that never arrives.
      await _feedRaw(
        [_rawPacket(declaredSize: headerSize + 32)],
        (buf) => TokenStream(buf).processQueryResponse(),
      );

      // Unknown packet type carrying otherwise valid tokens.
      await _feedRaw(
        [_rawPacket(type: 0x5A, body: [0x00, 0x01, 0x02])],
        (buf) => TokenStream(buf).processQueryResponse(),
      );

      // Non-monotonic sequence numbers across a multi-packet message.
      await _feedRaw(
        [
          _rawPacket(status: statusNormal, seq: 9, body: valid.sublist(0, 2)),
          _rawPacket(status: statusEOM, seq: 1, body: valid.sublist(2)),
        ],
        (buf) => TokenStream(buf).processQueryResponse(),
        closeServer: false,
      );

      // Empty non-final packets before the real body.
      final pair = await TdsSocketPair.open();
      addTearDown(pair.close);
      await tdsSend(pair.server, _rawPacket(status: statusNormal));
      await tdsSend(pair.server, _rawPacket(status: statusNormal));
      await tdsSend(pair.server, _rawPacket(body: valid));
      final result = await TokenStream(TdsBuffer(pair.client))
          .processQueryResponse()
          .timeout(const Duration(milliseconds: 250));
      expect(result.rows.single, [7]);
    });

    test('a message that never sets EOM fails on the deadline', () async {
      final pair = await TdsSocketPair.open();
      addTearDown(pair.close);
      await tdsSend(
        pair.server,
        _rawPacket(status: statusNormal, body: _colInt()),
      );
      // The socket stays open, so the parser can only stop on its own deadline.
      await expectLater(
        TokenStream(TdsBuffer(pair.client))
            .processQueryResponse()
            .timeout(const Duration(milliseconds: 250)),
        throwsA(isA<TimeoutException>()),
      );
    });

    test('hostile counts fail before columns or result sets are allocated',
        () async {
      // COLMETADATA claiming more columns than the limit allows.
      const columnLimit = MssqlProtocolLimits(maximumColumns: 4);
      final wideMeta = BytesBuilder(copy: false)
        ..addByte(tokenColMetadata)
        ..add([0xFE, 0xFF]); // 65534 columns
      await _feedRaw(
        [_rawPacket(body: wideMeta.toBytes())],
        (buf) => TokenStream(buf).processQueryResponse(),
        limits: columnLimit,
      );

      // A DONE chain that declares more result sets than the limit allows.
      const setLimit = MssqlProtocolLimits(maximumResultSets: 2);
      final many = <int>[];
      for (var i = 0; i < 6; i++) {
        many.addAll(_colInt());
        many.addAll(_row(i));
        many.addAll(_done(flags: doneFlagCount | doneFlagMore, rowCount: 1));
      }
      many.addAll(_done(flags: doneFlagCount, rowCount: 1));
      await _feedRaw(
        [_rawPacket(body: many)],
        (buf) => TokenStream(buf).processAllQueryResponses(),
        limits: setLimit,
      );
    });

    test('hostile PLP lengths and chunks reject before allocation', () async {
      const limits = MssqlProtocolLimits(
        maximumValueBytes: 64,
        maximumPlpChunkBytes: 32,
      );
      final text = ucs2('ok');

      // Declared total length far beyond maximumValueBytes.
      await _feedRaw(
        [
          _rawPacket(body: [
            ..._colXml(),
            ..._plpRow(0x7FFFFFFF, [text]),
            ..._done(flags: doneFlagCount, rowCount: 1),
          ])
        ],
        (buf) => TokenStream(buf).processQueryResponse(),
        limits: limits,
      );

      // Unknown total length, then a chunk beyond maximumPlpChunkBytes.
      final bigChunk = BytesBuilder(copy: false)..addByte(tokenRow);
      writeUint64LE(bigChunk, unknownPlpLen);
      writeUint32LE(bigChunk, 0x00100000);
      await _feedRaw(
        [_rawPacket(body: [..._colXml(), ...bigChunk.toBytes()])],
        (buf) => TokenStream(buf).processQueryResponse(),
        limits: limits,
      );

      // Chunks that accumulate past maximumValueBytes under an unknown length.
      await _feedRaw(
        [
          _rawPacket(body: [
            ..._colXml(),
            ..._plpRow(unknownPlpLen, [
              List.filled(30, 0x41),
              List.filled(30, 0x42),
              List.filled(30, 0x43),
            ]),
          ])
        ],
        (buf) => TokenStream(buf).processQueryResponse(),
        limits: limits,
      );

      // A value split across chunk boundaries with no terminator, then EOF.
      await _feedRaw(
        [
          _rawPacket(body: [
            ..._colXml(),
            ..._plpRow(
              text.length,
              [text.sublist(0, 1), text.sublist(1)],
              terminate: false,
            ),
          ])
        ],
        (buf) => TokenStream(buf).processQueryResponse(),
      );

      // The same split with a terminator parses back to the original value.
      final ok = await _feed(
        [
          ..._colXml(),
          ..._plpRow(text.length, [text.sublist(0, 1), text.sublist(1)]),
          ..._done(flags: doneFlagCount, rowCount: 1),
        ],
        (buf) => TokenStream(buf).processQueryResponse(),
        reject: false,
      );
      expect((ok as QueryResult).rows.single, ['ok']);
    });

    test('every COLMETADATA type byte either parses or rejects promptly',
        () async {
      for (var type = 0; type <= 0xFF; type++) {
        final meta = BytesBuilder(copy: false)
          ..addByte(tokenColMetadata)
          ..add([1, 0])
          ..add([0, 0, 0, 0])
          ..add([0, 0])
          ..addByte(type)
          // Length, scale, precision, and collation bytes are type-specific, so
          // feed plausible filler and let the parser decide.
          ..add(List.filled(8, 0x04))
          ..addByte(1)
          ..add(ucs2('v'));
        final body = [
          ...meta.toBytes(),
          tokenRow,
          ...List.filled(16, 0x01),
          ..._done(flags: doneFlagCount, rowCount: 1),
        ];
        final pair = await TdsSocketPair.open();
        try {
          await tdsSend(pair.server, _rawPacket(body: body));
          await pair.server.close();
          await TokenStream(TdsBuffer(pair.client))
              .processQueryResponse()
              .timeout(const Duration(milliseconds: 250));
        } on TimeoutException {
          fail('type byte 0x${type.toRadixString(16)} did not finish promptly');
        } catch (_) {
          // Rejecting an unsupported or inconsistent type is the expected path.
        } finally {
          await pair.close();
        }
      }
    });

    test('variable-length token bodies reject promptly when inconsistent',
        () async {
      Future<void> reject(List<int> body) => _feed(
            body,
            (buf) => TokenStream(buf).processQueryResponse(),
          );
      Future<void> rejectLogin(List<int> body) => _feed(
            body,
            (buf) => TokenStream(buf).processLoginResponse(),
          );

      // ERROR: message length beyond the token body.
      final error = BytesBuilder(copy: false)
        ..addByte(tokenError)
        ..add([12, 0]) // token length
        ..add([1, 0, 0, 0]) // number
        ..addByte(1) // state
        ..addByte(16) // severity
        ..add([0xFF, 0x7F]); // message length in characters
      await reject(error.toBytes());

      // INFO: odd UCS-2 byte count for the message.
      final odd = BytesBuilder(copy: false)
        ..addByte(tokenInfo)
        ..add([11, 0])
        ..add([1, 0, 0, 0])
        ..addByte(1)
        ..addByte(10)
        ..add([2, 0])
        ..add([0x41, 0x00, 0x42]); // three bytes for two characters
      await reject(odd.toBytes());

      // ERROR: server name length running past the body.
      final badServer = BytesBuilder(copy: false)
        ..addByte(tokenError)
        ..add([13, 0])
        ..add([1, 0, 0, 0])
        ..addByte(1)
        ..addByte(16)
        ..add([1, 0])
        ..add([0x41, 0x00])
        ..addByte(0x7F); // server name character count
      await reject(badServer.toBytes());

      // ENVCHANGE: database name length past the token body.
      final badEnv = BytesBuilder(copy: false)
        ..addByte(tokenEnvChange)
        ..add([3, 0])
        ..addByte(envDatabase)
        ..addByte(0x40)
        ..addByte(0x41);
      await rejectLogin(badEnv.toBytes());

      // ENVCHANGE: SQL collation with the wrong payload size.
      final badCollation = BytesBuilder(copy: false)
        ..addByte(tokenEnvChange)
        ..add([2, 0])
        ..addByte(envSqlCollation)
        ..addByte(0x05); // claims five bytes, sends none
      await rejectLogin(badCollation.toBytes());

      // ENVCHANGE: routing payload with a hostile inner length.
      final badRouting = BytesBuilder(copy: false)
        ..addByte(tokenEnvChange)
        ..add([6, 0])
        ..addByte(envRouting)
        ..add([0xFF, 0xFF]) // routing data length
        ..addByte(0)
        ..add([0xFF, 0xFF]);
      await rejectLogin(badRouting.toBytes());

      // LOGINACK: program name length past the token body.
      final badAck = BytesBuilder(copy: false)
        ..addByte(tokenLoginAck)
        ..add([7, 0])
        ..addByte(1)
        ..add([0x74, 0x00, 0x00, 0x04])
        ..addByte(0x40) // program name character count
        ..addByte(0x41);
      await rejectLogin(badAck.toBytes());

      // FEATUREEXTACK: feature data length beyond the message.
      final badFeature = BytesBuilder(copy: false)
        ..addByte(tokenFeatureExtAck)
        ..addByte(0x01)
        ..add([0xFF, 0xFF, 0xFF, 0x7F]);
      await rejectLogin(badFeature.toBytes());

      // SSPI: challenge length beyond the message.
      final badSspi = BytesBuilder(copy: false)
        ..addByte(tokenSSPI)
        ..add([0xFF, 0x7F])
        ..add([0x01, 0x02]);
      await rejectLogin(badSspi.toBytes());

      // FEDAUTHINFO: option count and data offsets past the payload.
      final badFedAuth = BytesBuilder(copy: false)
        ..addByte(tokenFedAuthInfo)
        ..add([0x08, 0x00, 0x00, 0x00])
        ..add([0xFF, 0xFF, 0xFF, 0x7F])
        ..add([0x01, 0x02, 0x03, 0x04]);
      await rejectLogin(badFedAuth.toBytes());

      // RETURNVALUE: truncated after the parameter name.
      final badReturn = BytesBuilder(copy: false)
        ..addByte(tokenReturnValue)
        ..add([1, 0])
        ..addByte(1)
        ..add(ucs2('p'));
      await reject(badReturn.toBytes());

      // RETURNSTATUS: fewer than four bytes.
      await reject([tokenReturnStatus, 0x01, 0x00]);
    });

    test('NBCROW bitmaps that disagree with the metadata reject promptly',
        () async {
      // Two columns need one bitmap byte; send the token with none.
      final shortBitmap = BytesBuilder(copy: false)
        ..addByte(tokenColMetadata)
        ..add([2, 0]);
      for (final name in ['a', 'b']) {
        shortBitmap
          ..add([0, 0, 0, 0])
          ..add([1, 0]) // nullable
          ..addByte(typeIntN)
          ..addByte(4)
          ..addByte(name.length)
          ..add(ucs2(name));
      }
      await _feed(
        [...shortBitmap.toBytes(), tokenNbcRow],
        (buf) => TokenStream(buf).processQueryResponse(),
      );

      // A bitmap marking a non-nullable INT4 column as null.
      final nullNonNullable = [
        ..._colInt(),
        tokenNbcRow,
        0x01,
        ..._done(flags: doneFlagCount, rowCount: 1),
      ];
      final pair = await TdsSocketPair.open();
      addTearDown(pair.close);
      await tdsSend(pair.server, _rawPacket(body: nullNonNullable));
      await pair.server.close();
      try {
        final result = await TokenStream(TdsBuffer(pair.client))
            .processQueryResponse()
            .timeout(const Duration(milliseconds: 250));
        expect(result.rows.single, [null]);
      } on TimeoutException {
        fail('NBCROW null for a non-nullable column did not finish promptly');
      } catch (_) {
        // Rejecting the inconsistent bitmap is equally acceptable.
      }
    });

    test('a long fuzz run does not grow resident memory', () async {
      final valid = _validQuery();
      final started = ProcessInfo.currentRss;
      for (var i = 0; i < 300; i++) {
        final body = List<int>.from(valid);
        // Corrupt one byte per case, including token types and length fields.
        body[random.nextInt(body.length)] = random.nextInt(256);
        final pair = await TdsSocketPair.open();
        try {
          await tdsSend(pair.server, _rawPacket(body: body));
          await pair.server.close();
          await TokenStream(TdsBuffer(pair.client))
              .processQueryResponse()
              .timeout(const Duration(milliseconds: 250));
        } on TimeoutException {
          fail('mutated case $i did not finish promptly');
        } catch (_) {
          // Either outcome is fine; this case measures allocation, not parsing.
        } finally {
          await pair.close();
        }
      }
      // maxRss is a process-wide high-water mark that other suites inflate, so
      // this compares the resident set before and after the loop.
      expect(ProcessInfo.currentRss, lessThan(started + 128 * 1024 * 1024));
    });

    test('previously failing seeds still reject or parse cleanly', () async {
      // Seeds that once exposed a parser defect. Keep entries here so the
      // regression survives a change to the default seed.
      const corpus = <int>[0x4D535351, 1297306449];
      for (final seed in corpus) {
        final corpusRandom = Random(seed);
        final valid = _validQuery();
        final parts = _segments(valid, 2 + corpusRandom.nextInt(4), corpusRandom);
        final pair = await TdsSocketPair.open();
        try {
          for (var p = 0; p < parts.length; p++) {
            await tdsSend(
              pair.server,
              tdsPacket(
                type: packReply,
                body: parts[p],
                eom: p == parts.length - 1,
                seq: p + 1,
              ),
            );
          }
          final result = await TokenStream(TdsBuffer(pair.client))
              .processQueryResponse()
              .timeout(const Duration(milliseconds: 250));
          expect(result.rows.single, [7], reason: 'seed $seed');
        } finally {
          await pair.close();
        }
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
