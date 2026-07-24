import 'dart:typed_data';

import 'package:mssql/mssql.dart';
import 'package:mssql/src/tds/buf.dart';
import 'package:mssql/src/tds/constants.dart';
import 'package:mssql/src/tds/token_stream.dart';
import 'package:test/test.dart';

import 'helpers/tds_socket.dart';

/// Crafted token-stream packets for [TokenStream].
///
/// Sources:
/// - microsoft/go-mssqldb `token.go` parsers (ERROR, DONE, LOGINACK, ENVCHANGE,
///   COLMETADATA, ROW, NBCROW, ORDER, RETURNVALUE, FEATUREEXTACK)
/// - Tedious `test/unit/token/*-token-parser-test.ts`
/// - ms-tds §2.2.7 token stream grammar

Uint8List _errorToken({
  required int number,
  required String message,
  int state = 1,
  int clazz = 16,
}) {
  final msg = ucs2(message);
  final payload = BytesBuilder(copy: false);
  writeUint32LE(payload, number);
  payload.addByte(state);
  payload.addByte(clazz);
  writeUint16LE(payload, message.length);
  payload.add(msg);
  // serverName B_VARCHAR empty, procName empty, lineNumber
  payload.addByte(0);
  payload.addByte(0);
  writeUint32LE(payload, 1);

  final data = payload.toBytes();
  final out = BytesBuilder(copy: false);
  out.addByte(tokenError);
  writeUint16LE(out, data.length);
  out.add(data);
  return Uint8List.fromList(out.toBytes());
}

Uint8List _infoToken(String message) {
  // Same shape as ERROR but tokenInfo — skipped by query/login parsers.
  final msg = ucs2(message);
  final payload = BytesBuilder(copy: false);
  writeUint32LE(payload, 0);
  payload.addByte(0);
  payload.addByte(0);
  writeUint16LE(payload, message.length);
  payload.add(msg);
  payload.addByte(0);
  payload.addByte(0);
  writeUint32LE(payload, 0);

  final data = payload.toBytes();
  final out = BytesBuilder(copy: false);
  out.addByte(tokenInfo);
  writeUint16LE(out, data.length);
  out.add(data);
  return Uint8List.fromList(out.toBytes());
}

Uint8List _doneToken({
  int flags = doneFlagFinal,
  int curCmd = 0,
  int rowCount = 0,
}) {
  final out = BytesBuilder(copy: false);
  out.addByte(tokenDone);
  writeUint16LE(out, flags);
  writeUint16LE(out, curCmd);
  writeUint64LE(out, rowCount);
  return Uint8List.fromList(out.toBytes());
}

Uint8List _loginAckToken(String progName) {
  final name = ucs2(progName);
  final data = BytesBuilder(copy: false);
  data.addByte(1); // interface
  // TDS version BE-ish bytes (parser does not interpret them)
  data.add([0x74, 0x00, 0x00, 0x04]);
  data.addByte(progName.length);
  data.add(name);
  writeUint32LE(data, 0x01000000); // prog version

  final bytes = data.toBytes();
  final out = BytesBuilder(copy: false);
  out.addByte(tokenLoginAck);
  writeUint16LE(out, bytes.length);
  out.add(bytes);
  return Uint8List.fromList(out.toBytes());
}

Uint8List _envChangeDatabase(String newDb, String oldDb) {
  final payload = BytesBuilder(copy: false);
  payload.addByte(envDatabase);
  payload.addByte(newDb.length);
  payload.add(ucs2(newDb));
  payload.addByte(oldDb.length);
  payload.add(ucs2(oldDb));

  final data = payload.toBytes();
  final out = BytesBuilder(copy: false);
  out.addByte(tokenEnvChange);
  writeUint16LE(out, data.length);
  out.add(data);
  return Uint8List.fromList(out.toBytes());
}

/// COLMETADATA for a single INT4 column named [name].
Uint8List _colMetaInt(String name) {
  final out = BytesBuilder(copy: false);
  out.addByte(tokenColMetadata);
  writeUint16LE(out, 1); // column count
  writeUint32LE(out, 0); // userType
  writeUint16LE(out, 0); // flags
  out.addByte(typeInt4);
  out.addByte(name.length);
  out.add(ucs2(name));
  return Uint8List.fromList(out.toBytes());
}

/// COLMETADATA for two INTN (nullable INT) columns.
Uint8List _colMetaTwoNullableInts(String a, String b) {
  final out = BytesBuilder(copy: false);
  out.addByte(tokenColMetadata);
  writeUint16LE(out, 2);
  for (final name in [a, b]) {
    writeUint32LE(out, 0);
    writeUint16LE(out, 1); // nullable
    out.addByte(typeIntN);
    out.addByte(4); // MaxLen
    out.addByte(name.length);
    out.add(ucs2(name));
  }
  return Uint8List.fromList(out.toBytes());
}

Uint8List _rowInt(int value) {
  final out = BytesBuilder(copy: false);
  out.addByte(tokenRow);
  writeUint32LE(out, value);
  return Uint8List.fromList(out.toBytes());
}

/// NBCROW: first column null, second column = [value].
Uint8List _nbcRowSecondInt(int value) {
  final out = BytesBuilder(copy: false);
  out.addByte(tokenNbcRow);
  out.addByte(0x01); // bitmap: bit0 set → col0 null
  // col1 present: BYTELEN INTN → len 4 + int32
  out.addByte(4);
  writeUint32LE(out, value);
  return Uint8List.fromList(out.toBytes());
}

/// COLMETADATA for [count] nullable INTN columns named c0..c{n-1}.
Uint8List _colMetaNullableInts(int count) {
  final out = BytesBuilder(copy: false);
  out.addByte(tokenColMetadata);
  writeUint16LE(out, count);
  for (var i = 0; i < count; i++) {
    final name = 'c$i';
    writeUint32LE(out, 0);
    writeUint16LE(out, 1); // nullable
    out.addByte(typeIntN);
    out.addByte(4);
    out.addByte(name.length);
    out.add(ucs2(name));
  }
  return Uint8List.fromList(out.toBytes());
}

/// 9-col NBCROW: null,1,null,2,null,3,null,4,null — spans bitmap byte boundary.
Uint8List _nbcRowNineColBoundary() {
  final out = BytesBuilder(copy: false);
  out.addByte(tokenNbcRow);
  // bits 0..7: 1,0,1,0,1,0,1,0 → 0x55; bit 8 null → second byte 0x01
  out.addByte(0x55);
  out.addByte(0x01);
  for (final v in [1, 2, 3, 4]) {
    out.addByte(4);
    writeUint32LE(out, v);
  }
  return Uint8List.fromList(out.toBytes());
}

Uint8List _envChangePacketSize(String size) {
  final payload = BytesBuilder(copy: false);
  payload.addByte(envPacketSize);
  payload.addByte(size.length);
  payload.add(ucs2(size));
  payload.addByte(size.length);
  payload.add(ucs2(size));
  final data = payload.toBytes();
  final out = BytesBuilder(copy: false);
  out.addByte(tokenEnvChange);
  writeUint16LE(out, data.length);
  out.add(data);
  return Uint8List.fromList(out.toBytes());
}

Uint8List _envChangeBeginTran(int descriptor) {
  final payload = BytesBuilder(copy: false);
  payload.addByte(envBeginTran);
  payload.addByte(8); // new value length
  for (var i = 0; i < 8; i++) {
    payload.addByte((descriptor >> (i * 8)) & 0xFF);
  }
  payload.addByte(0); // old empty
  final data = payload.toBytes();
  final out = BytesBuilder(copy: false);
  out.addByte(tokenEnvChange);
  writeUint16LE(out, data.length);
  out.add(data);
  return Uint8List.fromList(out.toBytes());
}

Uint8List _envChangeCommitTran() {
  final payload = BytesBuilder(copy: false);
  payload.addByte(envCommitTran);
  payload.addByte(0);
  payload.addByte(0);
  final data = payload.toBytes();
  final out = BytesBuilder(copy: false);
  out.addByte(tokenEnvChange);
  writeUint16LE(out, data.length);
  out.add(data);
  return Uint8List.fromList(out.toBytes());
}

Uint8List _orderToken() {
  // One column ordinal (1) — skipped by parser.
  final data = [0x01, 0x00];
  final out = BytesBuilder(copy: false);
  out.addByte(tokenOrder);
  writeUint16LE(out, data.length);
  out.add(data);
  return Uint8List.fromList(out.toBytes());
}

Uint8List _returnValueInt({required String name, required int value}) {
  final out = BytesBuilder(copy: false);
  out.addByte(tokenReturnValue);
  writeUint16LE(out, 1); // ordinal
  out.addByte(name.length);
  out.add(ucs2(name));
  out.addByte(0x01); // status OUTPUT
  writeUint32LE(out, 0); // userType
  writeUint16LE(out, 0); // flags
  out.addByte(typeIntN);
  out.addByte(4); // MaxLen
  out.addByte(4); // value len
  writeUint32LE(out, value);
  return Uint8List.fromList(out.toBytes());
}

Uint8List _featureExtAck({int featureId = featExtFedAuth}) {
  final out = BytesBuilder(copy: false);
  out.addByte(tokenFeatureExtAck);
  out.addByte(featureId);
  writeUint32LE(out, 2); // feature data len
  out.add([0x00, 0x00]);
  out.addByte(featExtTerminator);
  return Uint8List.fromList(out.toBytes());
}

typedef _Fed = ({TdsBuffer buf, TdsSocketPair pair});

Future<_Fed> _openWithBody(List<int> body) async {
  final pair = await TdsSocketPair.open();
  await tdsSend(pair.server, tdsPacket(type: packReply, body: body));
  return (buf: TdsBuffer(pair.client), pair: pair);
}

void main() {
  group('TokenStream login response', () {
    // go-mssqldb parseLoginAck + ENVCHANGE database; Tedious loginack-token-parser
    test('LOGINACK + ENVCHANGE database + DONE', () async {
      final body = [
        ..._loginAckToken('Microsoft SQL Server'),
        ..._envChangeDatabase('master', 'master'),
        ..._doneToken(),
      ];
      final fed = await _openWithBody(body);
      addTearDown(fed.pair.close);

      final result = await TokenStream(fed.buf).processLoginResponse();
      expect(result.serverVersion, equals('Microsoft SQL Server'));
      expect(result.database, equals('master'));
    });

    test('ERROR during login throws MssqlException', () async {
      final body = [
        ..._errorToken(number: 18456, message: 'Login failed'),
        ..._doneToken(flags: doneFlagError),
      ];
      final fed = await _openWithBody(body);
      addTearDown(fed.pair.close);

      await expectLater(
        TokenStream(fed.buf).processLoginResponse(),
        throwsA(isA<MssqlException>()
            .having((e) => e.errorCode, 'errorCode', 18456)
            .having((e) => e.message, 'message', contains('Login failed'))),
      );
    });

    // go-mssqldb FEATUREEXTACK skip + ENVCHANGE packet size
    test('FeatureExtAck is skipped; packet-size ENVCHANGE applied', () async {
      final body = [
        ..._loginAckToken('SQL Server'),
        ..._featureExtAck(),
        ..._envChangePacketSize('8192'),
        ..._doneToken(),
      ];
      final fed = await _openWithBody(body);
      addTearDown(fed.pair.close);

      final result = await TokenStream(fed.buf).processLoginResponse();
      expect(result.serverVersion, equals('SQL Server'));
      expect(result.packetSize, equals(8192));
    });
  });

  group('TokenStream query response', () {
    // Tedious row-token-parser / go-mssqldb COLMETADATA+ROW
    test('COLMETADATA + ROW + DONE returns one row', () async {
      final body = [
        ..._colMetaInt('n'),
        ..._rowInt(42),
        ..._doneToken(flags: doneFlagCount, rowCount: 1),
      ];
      final fed = await _openWithBody(body);
      addTearDown(fed.pair.close);

      final result = await TokenStream(fed.buf).processQueryResponse();
      expect(result.columns.single.name, equals('n'));
      expect(result.rows, equals([
        [42]
      ]));
      expect(result.rowsAffected, equals(1));
    });

    // Tedious nbcrow-token-parser-test / go-mssqldb NBCROW bitmap
    test('COLMETADATA + NBCROW null bitmap', () async {
      final body = [
        ..._colMetaTwoNullableInts('a', 'b'),
        ..._nbcRowSecondInt(99),
        ..._doneToken(flags: doneFlagCount, rowCount: 1),
      ];
      final fed = await _openWithBody(body);
      addTearDown(fed.pair.close);

      final result = await TokenStream(fed.buf).processQueryResponse();
      expect(result.rows.single, equals([null, 99]));
    });

    test('INFO then ERROR then DONE surfaces error', () async {
      final body = [
        ..._infoToken('ignored info'),
        ..._errorToken(number: 208, message: 'Invalid object name'),
        ..._doneToken(flags: doneFlagError),
      ];
      final fed = await _openWithBody(body);
      addTearDown(fed.pair.close);

      await expectLater(
        TokenStream(fed.buf).processQueryResponse(),
        throwsA(isA<MssqlException>()
            .having((e) => e.errorCode, 'errorCode', 208)
            .having((e) => e.message, 'message', contains('Invalid object'))),
      );
    });

    // go-mssqldb doneStruct multi-error aggregation pattern
    test('two ERROR tokens populate precedingErrors', () async {
      final body = [
        ..._errorToken(number: 1, message: 'error 1'),
        ..._errorToken(number: 2, message: 'error 2'),
        ..._doneToken(flags: doneFlagError),
      ];
      final fed = await _openWithBody(body);
      addTearDown(fed.pair.close);

      try {
        await TokenStream(fed.buf).processQueryResponse();
        fail('expected MssqlException');
      } on MssqlException catch (e) {
        expect(e.message, contains('error 2'));
        expect(e.errorCode, equals(2));
        expect(e.precedingErrors.length, equals(2));
        expect(e.precedingErrors[0].message, contains('error 1'));
        expect(e.precedingErrors[1].message, contains('error 2'));
      }
    });

    // ms-tds DONE.status DONE_MORE; multi-result batches (node-mssql / go-mssqldb)
    test('multiple result sets via DONE MORE', () async {
      final body = [
        ..._colMetaInt('a'),
        ..._rowInt(1),
        ..._doneToken(flags: doneFlagMore | doneFlagCount, rowCount: 1),
        ..._colMetaInt('b'),
        ..._rowInt(2),
        ..._doneToken(flags: doneFlagCount, rowCount: 1),
      ];
      final fed = await _openWithBody(body);
      addTearDown(fed.pair.close);

      final sets = await TokenStream(fed.buf).processAllQueryResponses();
      expect(sets.length, equals(2));
      expect(sets[0].columns.single.name, equals('a'));
      expect(sets[0].rows.single, equals([1]));
      expect(sets[1].columns.single.name, equals('b'));
      expect(sets[1].rows.single, equals([2]));
    });

    // Tedious order-token-parser — must not desync stream
    test('ORDER token is skipped between COLMETADATA and ROW', () async {
      final body = [
        ..._colMetaInt('n'),
        ..._orderToken(),
        ..._rowInt(5),
        ..._doneToken(flags: doneFlagCount, rowCount: 1),
      ];
      final fed = await _openWithBody(body);
      addTearDown(fed.pair.close);

      final result = await TokenStream(fed.buf).processQueryResponse();
      expect(result.rows.single, equals([5]));
    });

    // ms-tds §2.2.7.15 RETURNVALUE; go-mssqldb / tedious OUTPUT params
    test('RETURNVALUE token is skipped without corrupting stream', () async {
      final body = [
        ..._colMetaInt('n'),
        ..._rowInt(1),
        ..._returnValueInt(name: '@out', value: 99),
        ..._doneToken(flags: doneFlagCount, rowCount: 1),
      ];
      final fed = await _openWithBody(body);
      addTearDown(fed.pair.close);

      final result = await TokenStream(fed.buf).processQueryResponse();
      expect(result.rows.single, equals([1]));
    });

    // ms-tds ENVCHANGE type 8/9; go-mssqldb transaction descriptor
    test('ENVCHANGE begin/commit updates transactionDescriptor', () async {
      const descriptor = 0x0102030405060708;
      final body = [
        ..._envChangeBeginTran(descriptor),
        ..._doneToken(flags: doneFlagMore),
        ..._envChangeCommitTran(),
        ..._doneToken(),
      ];
      final fed = await _openWithBody(body);
      addTearDown(fed.pair.close);

      // Drive login-style loop isn't right — use processAllQueryResponses which
      // still parses ENVCHANGE. No COLMETADATA → empty results.
      final sets = await TokenStream(fed.buf).processAllQueryResponses();
      expect(sets, isEmpty);
      // After commit, descriptor cleared.
      expect(fed.buf.transactionDescriptor, equals(0));
    });

    // ms-tds ENVCHANGE type 8 mid-query
    test('ENVCHANGE begin sets transactionDescriptor mid-stream', () async {
      const descriptor = 0x1122334455667788;
      // Query path: begin-tran envchange then a result set.
      final body = [
        ..._envChangeBeginTran(descriptor),
        ..._colMetaInt('n'),
        ..._rowInt(1),
        ..._doneToken(flags: doneFlagCount, rowCount: 1),
      ];
      final fed = await _openWithBody(body);
      addTearDown(fed.pair.close);

      await TokenStream(fed.buf).processQueryResponse();
      expect(fed.buf.transactionDescriptor, equals(descriptor));
    });

    // go-mssqldb / node-mssql: INSERT/UPDATE DONE with COUNT, no COLMETADATA
    test('DML-only DONE emits rowsAffected without columns', () async {
      final body = [
        ..._doneToken(flags: doneFlagCount, rowCount: 3),
      ];
      final fed = await _openWithBody(body);
      addTearDown(fed.pair.close);

      final result = await TokenStream(fed.buf).processQueryResponse();
      expect(result.columns, isEmpty);
      expect(result.rows, isEmpty);
      expect(result.rowsAffected, equals(3));
    });

    // ms-tds COLMETADATA count 0xFFFF = no columns (empty result metadata)
    test('empty COLMETADATA (0xFFFF) yields empty columns', () async {
      final out = BytesBuilder(copy: false);
      out.addByte(tokenColMetadata);
      writeUint16LE(out, 0xFFFF);
      final body = [
        ...out.toBytes(),
        ..._doneToken(),
      ];
      final fed = await _openWithBody(body);
      addTearDown(fed.pair.close);

      final result = await TokenStream(fed.buf).processQueryResponse();
      expect(result.columns, isEmpty);
      expect(result.rows, isEmpty);
    });

    // TokenStream.streamQueryResponse — streaming analogue of Tedious row events
    test('streamQueryResponse yields rows then completes', () async {
      final body = [
        ..._colMetaInt('n'),
        ..._rowInt(10),
        ..._rowInt(20),
        ..._doneToken(flags: doneFlagCount, rowCount: 2),
      ];
      final fed = await _openWithBody(body);
      addTearDown(fed.pair.close);

      final rows = <int>[];
      await for (final (cols, row) in TokenStream(fed.buf).streamQueryResponse()) {
        expect(cols.single.name, equals('n'));
        rows.add(row.single as int);
      }
      expect(rows, equals([10, 20]));
    });

    // streamQueryResponse must still throw on ERROR like buffered path
    test('streamQueryResponse throws on ERROR token', () async {
      final body = [
        ..._errorToken(number: 50000, message: 'boom'),
        ..._doneToken(flags: doneFlagError),
      ];
      final fed = await _openWithBody(body);
      addTearDown(fed.pair.close);

      await expectLater(
        () async {
          await for (final _ in TokenStream(fed.buf).streamQueryResponse()) {}
        },
        throwsA(isA<MssqlException>()
            .having((e) => e.errorCode, 'errorCode', 50000)),
      );
    });

    // go-mssqldb / tedious: DONE_PROC (0xFE) ends RPC response like DONE
    test('DONE_PROC ends result set like DONE', () async {
      final out = BytesBuilder(copy: false);
      out.addByte(tokenDoneProc);
      writeUint16LE(out, doneFlagCount);
      writeUint16LE(out, 0);
      writeUint64LE(out, 1);
      final body = [
        ..._colMetaInt('n'),
        ..._rowInt(7),
        ...out.toBytes(),
      ];
      final fed = await _openWithBody(body);
      addTearDown(fed.pair.close);

      final result = await TokenStream(fed.buf).processQueryResponse();
      expect(result.rows.single, equals([7]));
      expect(result.rowsAffected, equals(1));
    });

    // ms-tds §2.2.7.16 RETURNSTATUS — 4-byte status, skipped in query path
    test('RETURNSTATUS is skipped before DONE', () async {
      final out = BytesBuilder(copy: false);
      out.addByte(tokenReturnStatus);
      writeUint32LE(out, 0); // status OK
      final body = [
        ..._colMetaInt('n'),
        ..._rowInt(1),
        ...out.toBytes(),
        ..._doneToken(flags: doneFlagCount, rowCount: 1),
      ];
      final fed = await _openWithBody(body);
      addTearDown(fed.pair.close);

      final result = await TokenStream(fed.buf).processQueryResponse();
      expect(result.rows.single, equals([1]));
    });

    // processQueryResponse keeps first set rows, sums rowsAffected (node-mssql)
    test('processQueryResponse sums rowsAffected across result sets', () async {
      final body = [
        ..._colMetaInt('a'),
        ..._rowInt(1),
        ..._doneToken(flags: doneFlagMore | doneFlagCount, rowCount: 2),
        ..._colMetaInt('b'),
        ..._rowInt(9),
        ..._doneToken(flags: doneFlagCount, rowCount: 5),
      ];
      final fed = await _openWithBody(body);
      addTearDown(fed.pair.close);

      final result = await TokenStream(fed.buf).processQueryResponse();
      expect(result.columns.single.name, equals('a'));
      expect(result.rows.single, equals([1]));
      expect(result.rowsAffected, equals(7));
    });

    // go-mssqldb / tedious: unexpected token → hard error
    test('unknown token throws StateError', () async {
      final body = [
        0x00, // invalid
        ..._doneToken(),
      ];
      final fed = await _openWithBody(body);
      addTearDown(fed.pair.close);

      await expectLater(
        TokenStream(fed.buf).processQueryResponse(),
        throwsA(isA<StateError>()),
      );
    });

    // types_test 9-column NBCROW; Tedious nbcrow bitmap byte boundary
    test('NBCROW 9-column null bitmap spans byte boundary', () async {
      final body = [
        ..._colMetaNullableInts(9),
        ..._nbcRowNineColBoundary(),
        ..._doneToken(flags: doneFlagCount, rowCount: 1),
      ];
      final fed = await _openWithBody(body);
      addTearDown(fed.pair.close);

      final result = await TokenStream(fed.buf).processQueryResponse();
      expect(
        result.rows.single,
        equals([null, 1, null, 2, null, 3, null, 4, null]),
      );
    });

    // ms-tds §2.2.7.7 DONE_IN_PROC — same layout as DONE inside RPC
    test('DONE_IN_PROC ends result set like DONE', () async {
      final out = BytesBuilder(copy: false);
      out.addByte(tokenDoneInProc);
      writeUint16LE(out, doneFlagCount);
      writeUint16LE(out, 0);
      writeUint64LE(out, 1);
      final body = [
        ..._colMetaInt('n'),
        ..._rowInt(3),
        ...out.toBytes(),
      ];
      final fed = await _openWithBody(body);
      addTearDown(fed.pair.close);

      final result = await TokenStream(fed.buf).processQueryResponse();
      expect(result.rows.single, equals([3]));
      expect(result.rowsAffected, equals(1));
    });
  });
}
