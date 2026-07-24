import 'dart:typed_data';

import 'package:mssql/src/tds/buf.dart';
import 'package:mssql/src/tds/constants.dart';
import 'package:mssql/src/tds/type_info.dart';
import 'package:test/test.dart';

import 'helpers/tds_socket.dart';

/// Offline TypeInfo decode tests inspired by go-mssqldb types_unit_test.go.

Future<(TdsBuffer, TdsSocketPair)> _bufWith(List<int> body) async {
  final pair = await TdsSocketPair.open();
  await tdsSend(pair.server, tdsPacket(type: packReply, body: body));
  return (TdsBuffer(pair.client), pair);
}

/// Default collation (5 zero bytes) for string TYPE_INFO.
List<int> get _collation => [0, 0, 0, 0, 0];

Future<Object?> _decode({
  required List<int> typeInfoBytes,
  required List<int> valueBytes,
}) async {
  final (buf, pair) = await _bufWith([...typeInfoBytes, ...valueBytes]);
  addTearDown(pair.close);
  await buf.beginRead();
  final ti = await TypeInfo.read(buf);
  return ti.readValue(buf);
}

void main() {
  group('TypeInfo fixed-length decode', () {
    test('INT4', () async {
      final v = await _decode(
        typeInfoBytes: [typeInt4],
        valueBytes: [0x2A, 0x00, 0x00, 0x00],
      );
      expect(v, equals(42));
    });

    test('BIGINT', () async {
      final v = await _decode(
        typeInfoBytes: [typeInt8],
        valueBytes: [0x01, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00],
      );
      expect(v, equals(1));
    });

    test('BIT true/false', () async {
      expect(
        await _decode(typeInfoBytes: [typeBit], valueBytes: [1]),
        isTrue,
      );
      expect(
        await _decode(typeInfoBytes: [typeBit], valueBytes: [0]),
        isFalse,
      );
    });

    test('FLOAT (flt8)', () async {
      final bd = ByteData(8)..setFloat64(0, 3.5, Endian.little);
      final v = await _decode(
        typeInfoBytes: [typeFlt8],
        valueBytes: bd.buffer.asUint8List(),
      );
      expect(v, equals(3.5));
    });

    test('REAL (flt4)', () async {
      final bd = ByteData(4)..setFloat32(0, 1.5, Endian.little);
      final v = await _decode(
        typeInfoBytes: [typeFlt4],
        valueBytes: bd.buffer.asUint8List(),
      );
      expect(v as double, closeTo(1.5, 1e-6));
    });
  });

  group('TypeInfo byte-len decode', () {
    test('INTN null', () async {
      final v = await _decode(
        typeInfoBytes: [typeIntN, 4],
        valueBytes: [0], // len 0 = null
      );
      expect(v, isNull);
    });

    test('INTN int32', () async {
      final v = await _decode(
        typeInfoBytes: [typeIntN, 4],
        valueBytes: [4, 0x64, 0x00, 0x00, 0x00],
      );
      expect(v, equals(100));
    });

    test('MONEYN smallmoney', () async {
      // 123.4500 → 1234500 / 10000
      final raw = 1234500;
      final v = await _decode(
        typeInfoBytes: [typeMoneyN, 4],
        valueBytes: [
          4,
          raw & 0xFF,
          (raw >> 8) & 0xFF,
          (raw >> 16) & 0xFF,
          (raw >> 24) & 0xFF,
        ],
      );
      expect(v as double, closeTo(123.45, 0.0001));
    });

    test('DATE', () async {
      // days since 0001-01-01 for 2024-03-15
      final target = DateTime.utc(2024, 3, 15);
      final days = target.difference(DateTime.utc(1, 1, 1)).inDays;
      final v = await _decode(
        typeInfoBytes: [typeDateN], // no MaxLen in metadata
        valueBytes: [
          3,
          days & 0xFF,
          (days >> 8) & 0xFF,
          (days >> 16) & 0xFF,
        ],
      );
      final d = v as DateTime;
      expect(d.year, equals(2024));
      expect(d.month, equals(3));
      expect(d.day, equals(15));
    });

    test('TIME scale 0', () async {
      // 14:30:45 → 52245 seconds since midnight
      const seconds = 14 * 3600 + 30 * 60 + 45;
      final v = await _decode(
        typeInfoBytes: [typeTimeN, 0], // scale byte only
        valueBytes: [
          3,
          seconds & 0xFF,
          (seconds >> 8) & 0xFF,
          (seconds >> 16) & 0xFF,
        ],
      );
      final t = v as DateTime;
      expect(t.hour, equals(14));
      expect(t.minute, equals(30));
      expect(t.second, equals(45));
    });

    test('GUID mixed endian', () async {
      // Wire bytes for 6F9619FF-8B86-D011-B42D-00C04FC964FF
      final wire = [
        0xFF, 0x19, 0x96, 0x6F, // LE dword
        0x86, 0x8B, // LE word
        0x11, 0xD0, // LE word
        0xB4, 0x2D, 0x00, 0xC0, 0x4F, 0xC9, 0x64, 0xFF,
      ];
      final v = await _decode(
        typeInfoBytes: [typeGuid, 16],
        valueBytes: [16, ...wire],
      );
      expect(
        (v as String).toLowerCase(),
        equals('6f9619ff-8b86-d011-b42d-00c04fc964ff'),
      );
    });
  });

  group('TypeInfo short-len / PLP decode', () {
    test('NVARCHAR', () async {
      final text = ucs2('hi');
      final v = await _decode(
        typeInfoBytes: [typeNVarChar, 0x64, 0x00, ..._collation], // size 100
        valueBytes: [text.length & 0xFF, (text.length >> 8) & 0xFF, ...text],
      );
      expect(v, equals('hi'));
    });

    test('NVARCHAR null marker', () async {
      final v = await _decode(
        typeInfoBytes: [typeNVarChar, 0x64, 0x00, ..._collation],
        valueBytes: [0xFF, 0xFF],
      );
      expect(v, isNull);
    });

    test('VARCHAR', () async {
      final v = await _decode(
        typeInfoBytes: [typeBigVarChar, 0x32, 0x00, ..._collation],
        valueBytes: [3, 0, 0x61, 0x62, 0x63],
      );
      expect(v, equals('abc'));
    });

    test('NVARCHAR(MAX) PLP chunked', () async {
      final chunk = ucs2('ab');
      final v = await _decode(
        typeInfoBytes: [
          typeNVarChar,
          0xFF, 0xFF, // MAX
          ..._collation,
        ],
        valueBytes: [
          // PLP total length unknown
          0xFE, 0xFF, 0xFF, 0xFF, 0xFF, 0xFF, 0xFF, 0xFF,
          // chunk len 4
          4, 0, 0, 0,
          ...chunk,
          // terminator
          0, 0, 0, 0,
        ],
      );
      expect(v, equals('ab'));
    });

    test('VARBINARY(MAX) PLP null', () async {
      final v = await _decode(
        typeInfoBytes: [typeBigVarBin, 0xFF, 0xFF],
        valueBytes: [
          // plpNull
          0xFF, 0xFF, 0xFF, 0xFF, 0xFF, 0xFF, 0xFF, 0xFF,
        ],
      );
      expect(v, isNull);
    });

    test('VARBINARY short', () async {
      final v = await _decode(
        typeInfoBytes: [typeBigVarBin, 0x0A, 0x00],
        valueBytes: [3, 0, 0xDE, 0xAD, 0xBE],
      );
      expect(v, equals([0xDE, 0xAD, 0xBE]));
    });
  });
}
