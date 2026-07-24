import 'dart:async';
import 'dart:typed_data';

import 'package:mssql/mssql.dart';
import 'package:mssql/src/tds/buf.dart';
import 'package:mssql/src/tds/constants.dart';
import 'package:mssql/src/tds/rpc.dart';
import 'package:test/test.dart';

import 'helpers/tds_socket.dart';

/// Offline encode tests for typed SQL binders.
///
/// Sources: go-mssqldb UniqueIdentifier.Value, makeMoneyParam,
/// encodeDateTimeOffset, VarChar / civil.Date / civil.Time; ms-tds TYPE_INFO.

Future<Uint8List> _capture(Future<void> Function(TdsBuffer buf) send) async {
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
  group('MssqlGuid', () {
    test('toWireBytes uses mixed endian (go-mssqldb UniqueIdentifier)', () {
      // Display: 6F9619FF-8B86-D011-B42D-00C04FC964FF
      final wire = const MssqlGuid('6F9619FF-8B86-D011-B42D-00C04FC964FF')
          .toWireBytes();
      expect(wire.length, equals(16));
      // First group LE on wire: FF 19 96 6F
      expect(wire[0], equals(0xFF));
      expect(wire[1], equals(0x19));
      expect(wire[2], equals(0x96));
      expect(wire[3], equals(0x6F));
      // Second group LE: 86 8B
      expect(wire[4], equals(0x86));
      expect(wire[5], equals(0x8B));
      // Third group LE: 11 D0
      expect(wire[6], equals(0x11));
      expect(wire[7], equals(0xD0));
      // Rest unchanged
      expect(wire.sublist(8), equals([0xB4, 0x2D, 0x00, 0xC0, 0x4F, 0xC9, 0x64, 0xFF]));
    });

    test('rejects invalid length', () {
      expect(() => const MssqlGuid('not-a-guid').toWireBytes(), throwsArgumentError);
    });
  });

  group('typed param encode', () {
    test('GUID param decl + typeGuid on wire', () async {
      final pkt = await _capture(
        (buf) => RpcRequest.sendExecuteSql(
          buf,
          'SELECT @g',
          {'g': const MssqlGuid('6F9619FF-8B86-D011-B42D-00C04FC964FF')},
        ),
      );
      final body = _body(pkt);
      expect(_containsUcs2(body, '@g uniqueidentifier'), isTrue);
      expect(body.contains(typeGuid), isTrue);
    });

    test('money + smallmoney decls', () async {
      final pkt = await _capture(
        (buf) => RpcRequest.sendExecuteSql(
          buf,
          'SELECT @m, @s',
          {
            'm': const MssqlMoney(12.34),
            's': const MssqlSmallMoney(1.5),
          },
        ),
      );
      final body = _body(pkt);
      expect(_containsUcs2(body, '@m money'), isTrue);
      expect(_containsUcs2(body, '@s smallmoney'), isTrue);
      expect(body.contains(typeMoneyN), isTrue);
    });

    test('datetimeoffset decl + type on wire', () async {
      final dt = DateTime.utc(2024, 3, 15, 10);
      final pkt = await _capture(
        (buf) => RpcRequest.sendExecuteSql(
          buf,
          'SELECT @d',
          {'d': MssqlDateTimeOffset(dt)},
        ),
      );
      final body = _body(pkt);
      expect(_containsUcs2(body, '@d datetimeoffset'), isTrue);
      expect(body.contains(typeDateTimeOffsetN), isTrue);
    });

    test('decimal decl + typeDecimalN on wire', () async {
      final pkt = await _capture(
        (buf) => RpcRequest.sendExecuteSql(
          buf,
          'SELECT @d',
          {'d': MssqlDecimal(12.34, precision: 10, scale: 2)},
        ),
      );
      final body = _body(pkt);
      expect(_containsUcs2(body, '@d decimal(10,2)'), isTrue);
      expect(body.contains(typeDecimalN), isTrue);
    });

    test('varchar / date / time decls + wire types', () async {
      final pkt = await _capture(
        (buf) => RpcRequest.sendExecuteSql(
          buf,
          'SELECT @v, @d, @t',
          {
            'v': const MssqlVarchar('hi'),
            'd': MssqlDate(2024, 3, 15),
            't': MssqlTime(hour: 14, minute: 30, second: 45, scale: 7),
          },
        ),
      );
      final body = _body(pkt);
      expect(_containsUcs2(body, '@v varchar(8000)'), isTrue);
      expect(_containsUcs2(body, '@d date'), isTrue);
      expect(_containsUcs2(body, '@t time(7)'), isTrue);
      expect(body.contains(typeBigVarChar), isTrue);
      expect(body.contains(typeDateN), isTrue);
      expect(body.contains(typeTimeN), isTrue);
      // Latin-1 'hi' appears as raw bytes, not UCS-2
      expect(body.contains(0x68) && body.contains(0x69), isTrue);
    });
  });

  group('MssqlVarchar / MssqlDate / MssqlTime', () {
    test('varchar rejects non-Latin-1', () {
      expect(
        () => const MssqlVarchar('café€').toWireBytes(),
        throwsArgumentError,
      );
    });

    test('date daysSinceYear1 for 0001-01-01 is 0', () {
      expect(MssqlDate(1, 1, 1).daysSinceYear1, equals(0));
    });

    test('time fromDuration midnight + 1h', () {
      final t = MssqlTime.fromDuration(const Duration(hours: 1, minutes: 2));
      expect(t.hour, equals(1));
      expect(t.minute, equals(2));
    });

    test('invalid date throws', () {
      expect(() => MssqlDate(2024, 2, 30), throwsArgumentError);
    });
  });

  group('MssqlDecimal', () {
    test('parse and toWireBytes match DECIMAL(5,2) golden', () {
      final d = MssqlDecimal.parse('123.45', precision: 5, scale: 2);
      expect(d.unscaled, equals(BigInt.from(12345)));
      final w = d.toWireBytes();
      expect(w.length, equals(5));
      expect(w[0], equals(1)); // positive
      expect(w[1] | (w[2] << 8) | (w[3] << 16) | (w[4] << 24), equals(12345));
    });

    test('negative numeric wire sign byte 0', () {
      final d = MssqlDecimal.parse(
        '-5.00',
        precision: 5,
        scale: 2,
        asNumeric: true,
      );
      expect(d.sqlDecl, equals('numeric(5,2)'));
      expect(d.toWireBytes()[0], equals(0));
      expect(d.unscaled, equals(BigInt.from(-500)));
    });

    test('rejects precision overflow', () {
      expect(
        () => MssqlDecimal.parse('123456', precision: 5, scale: 0),
        throwsArgumentError,
      );
    });
  });
}
