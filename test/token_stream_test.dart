import 'dart:typed_data';

import 'package:mssql/mssql.dart';
import 'package:mssql/src/tds/buf.dart';
import 'package:mssql/src/tds/constants.dart';
import 'package:mssql/src/tds/token_stream.dart';
import 'package:test/test.dart';

import 'helpers/tds_socket.dart';

/// Crafted token-stream packets — inspired by go-mssqldb / Tedious token tests.

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

typedef _Fed = ({TdsBuffer buf, TdsSocketPair pair});

Future<_Fed> _openWithBody(List<int> body) async {
  final pair = await TdsSocketPair.open();
  await tdsSend(pair.server, tdsPacket(type: packReply, body: body));
  return (buf: TdsBuffer(pair.client), pair: pair);
}

void main() {
  group('TokenStream login response', () {
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
  });

  group('TokenStream query response', () {
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
  });
}
