import 'dart:async';
import 'dart:typed_data';

import 'package:mssql/src/tds/buf.dart';
import 'package:mssql/src/tds/constants.dart';
import 'package:mssql/src/tds/rpc.dart';
import 'package:test/test.dart';

import 'helpers/tds_socket.dart';

/// Offline RPC / SQL-batch encoding tests for [RpcRequest].

Future<Uint8List> _capturePacket({
  required Future<void> Function(TdsBuffer buf) send,
}) async {
  final pair = await TdsSocketPair.open();
  final completer = Completer<Uint8List>();
  final chunks = BytesBuilder(copy: false);

  pair.server.listen((data) {
    chunks.add(data);
    final all = chunks.toBytes();
    if (all.length >= headerSize) {
      final size = (all[2] << 8) | all[3];
      if (all.length >= size && !completer.isCompleted) {
        completer.complete(Uint8List.fromList(all));
      }
    }
  });

  await send(TdsBuffer(pair.client));
  final pkt = await completer.future.timeout(const Duration(seconds: 2));
  await pair.close();
  return pkt;
}

Uint8List _body(Uint8List pkt) =>
    Uint8List.fromList(pkt.sublist(headerSize, (pkt[2] << 8) | pkt[3]));

bool _containsUcs2(List<int> haystack, String needle) {
  final n = ucs2(needle);
  for (var i = 0; i <= haystack.length - n.length; i++) {
    var ok = true;
    for (var j = 0; j < n.length; j++) {
      if (haystack[i + j] != n[j]) {
        ok = false;
        break;
      }
    }
    if (ok) return true;
  }
  return false;
}

void main() {
  group('RpcRequest.sendBatch', () {
    test('packet type is SQLBatch with ALL_HEADERS + UCS-2 SQL', () async {
      const sql = 'SELECT 1';
      final pkt = await _capturePacket(
        send: (buf) => RpcRequest.sendBatch(buf, sql),
      );

      expect(pkt[0], equals(packSQLBatch));
      expect(pkt[1] & statusEOM, equals(statusEOM));

      final body = _body(pkt);
      // ALL_HEADERS: totalLen=22, headerDataLen=18, type=2
      expect(readUint32LE(body, 0), equals(22));
      expect(readUint32LE(body, 4), equals(18));
      expect(readUint16LE(body, 8), equals(0x0002));
      expect(readUint64LE(body, 10), equals(0)); // txn descriptor
      expect(readUint32LE(body, 18), equals(1)); // outstanding requests

      final sqlBytes = body.sublist(22);
      expect(sqlBytes, equals(ucs2(sql)));
    });
  });

  group('RpcRequest.sendExecuteSql', () {
    test('uses RPC packet, sp_executesql proc id 10, empty params', () async {
      const sql = 'SELECT 1 AS n';
      final pkt = await _capturePacket(
        send: (buf) => RpcRequest.sendExecuteSql(buf, sql, const {}),
      );

      expect(pkt[0], equals(packRPCRequest));
      final body = _body(pkt);

      expect(readUint32LE(body, 0), equals(22)); // ALL_HEADERS total
      var i = 22;
      expect(readUint16LE(body, i), equals(0xFFFF)); // ProcIDSwitch
      i += 2;
      expect(readUint16LE(body, i), equals(10)); // sp_executesql
      i += 2;
      expect(readUint16LE(body, i), equals(0)); // OptionFlags
      i += 2;

      // First param: empty name + status + NVARCHAR statement
      expect(body[i], equals(0)); // name length 0
      i += 1;
      expect(body[i], equals(0)); // status input
      i += 1;
      expect(body[i], equals(typeNVarChar));
      expect(_containsUcs2(body, sql), isTrue);
    });

    test('parameter declaration and typed values', () async {
      final pkt = await _capturePacket(
        send: (buf) => RpcRequest.sendExecuteSql(
          buf,
          'SELECT @i, @s, @b, @n',
          {
            'i': 7,
            's': 'hi',
            'b': true,
            'n': null,
          },
        ),
      );

      final body = _body(pkt);
      expect(
        _containsUcs2(body, '@i bigint, @s nvarchar(4000), @b bit, @n nvarchar(max)'),
        isTrue,
      );
      expect(_containsUcs2(body, '@i'), isTrue);
      expect(_containsUcs2(body, '@s'), isTrue);
      expect(_containsUcs2(body, 'hi'), isTrue);

      // INTN bigint value 7 as 8-byte LE somewhere after typeIntN marker.
      var foundInt = false;
      for (var i = 0; i < body.length - 10; i++) {
        if (body[i] == typeIntN &&
            body[i + 1] == 8 &&
            body[i + 2] == 8 &&
            body[i + 3] == 7 &&
            body[i + 4] == 0) {
          foundInt = true;
          break;
        }
      }
      expect(foundInt, isTrue);

      // BITN true
      var foundBit = false;
      for (var i = 0; i < body.length - 4; i++) {
        if (body[i] == typeBitN &&
            body[i + 1] == 1 &&
            body[i + 2] == 1 &&
            body[i + 3] == 1) {
          foundBit = true;
          break;
        }
      }
      expect(foundBit, isTrue);

      // NULL nvarchar marker 0xFFFF after a typeNVarChar
      var foundNull = false;
      for (var i = 0; i < body.length - 3; i++) {
        if (body[i] == typeNVarChar &&
            body[i + 1] == 2 &&
            body[i + 2] == 0) {
          // collation 5 bytes then 0xFFFF
          if (i + 8 < body.length &&
              body[i + 8] == 0xFF &&
              body[i + 9] == 0xFF) {
            foundNull = true;
            break;
          }
        }
      }
      expect(foundNull, isTrue);
    });

    test('DateTime param uses DATETIME2 scale 7', () async {
      final dt = DateTime.utc(2024, 6, 1, 12, 0, 0);
      final pkt = await _capturePacket(
        send: (buf) => RpcRequest.sendExecuteSql(
          buf,
          'SELECT @d',
          {'d': dt},
        ),
      );
      final body = _body(pkt);
      expect(_containsUcs2(body, '@d datetime2'), isTrue);

      var found = false;
      for (var i = 0; i < body.length - 2; i++) {
        if (body[i] == typeDateTime2N && body[i + 1] == 7) {
          found = true;
          break;
        }
      }
      expect(found, isTrue);
    });

    test('binary param uses VARBINARY(MAX) PLP', () async {
      final pkt = await _capturePacket(
        send: (buf) => RpcRequest.sendExecuteSql(
          buf,
          'SELECT @bin',
          {
            'bin': [0xDE, 0xAD],
          },
        ),
      );
      final body = _body(pkt);
      expect(_containsUcs2(body, '@bin varbinary(max)'), isTrue);

      var found = false;
      for (var i = 0; i < body.length - 3; i++) {
        if (body[i] == typeBigVarBin &&
            body[i + 1] == 0xFF &&
            body[i + 2] == 0xFF) {
          found = true;
          break;
        }
      }
      expect(found, isTrue);
      expect(body.contains(0xDE) && body.contains(0xAD), isTrue);
    });

    test('transactionDescriptor is written into ALL_HEADERS', () async {
      final pkt = await _capturePacket(
        send: (buf) {
          buf.transactionDescriptor = 0x1122334455667788;
          return RpcRequest.sendBatch(buf, 'SELECT 1');
        },
      );
      final body = _body(pkt);
      expect(readUint64LE(body, 10), equals(0x1122334455667788));
    });
  });
}
