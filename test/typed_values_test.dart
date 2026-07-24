import 'dart:async';
import 'dart:typed_data';

import 'package:mssql/mssql.dart';
import 'package:mssql/src/tds/buf.dart';
import 'package:mssql/src/tds/constants.dart';
import 'package:mssql/src/tds/rpc.dart';
import 'package:test/test.dart';

import 'helpers/tds_socket.dart';

/// Offline encode tests for [MssqlGuid] / [MssqlMoney] / [MssqlDateTimeOffset].
///
/// Sources: go-mssqldb UniqueIdentifier.Value, makeMoneyParam,
/// encodeDateTimeOffset; ms-tds TYPE_INFO for GUID / MONEYN / DATETIMEOFFSETN.

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
  });
}
