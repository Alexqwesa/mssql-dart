import 'dart:typed_data';

import 'buf.dart';
import 'constants.dart';

/// Column type for [BulkLoad] COLMETADATA / `INSERT BULK` declarations.
enum BulkColumnType {
  bigInt,
  nVarChar,
  bit,
  float64,
  dateTime2,
}

/// One destination column for a bulk insert.
class BulkColumn {
  final String name;
  final BulkColumnType type;

  /// Maximum UTF-16 code units for nvarchar (1–4000).
  final int nVarCharLength;

  /// Whether the destination column accepts nulls.
  ///
  /// When omitted, [MssqlConnection.bulkInsert] reads the destination metadata
  /// before starting Bulk Load. Specify this for every column to avoid that
  /// metadata round trip.
  final bool? nullable;

  const BulkColumn(
    this.name,
    this.type, {
    this.nVarCharLength = 4000,
    this.nullable,
  });

  BulkColumn withResolvedNullable(bool value) => BulkColumn(
        name,
        type,
        nVarCharLength: nVarCharLength,
        nullable: nullable ?? value,
      );

  String get sqlDecl {
    switch (type) {
      case BulkColumnType.bigInt:
        return 'bigint';
      case BulkColumnType.nVarChar:
        return 'nvarchar($nVarCharLength)';
      case BulkColumnType.bit:
        return 'bit';
      case BulkColumnType.float64:
        return 'float';
      case BulkColumnType.dateTime2:
        return 'datetime2(7)';
    }
  }

  static BulkColumnType infer(Object? sample) {
    if (sample == null) return BulkColumnType.nVarChar;
    if (sample is int) return BulkColumnType.bigInt;
    if (sample is double) return BulkColumnType.float64;
    if (sample is bool) return BulkColumnType.bit;
    if (sample is DateTime) return BulkColumnType.dateTime2;
    if (sample is String) return BulkColumnType.nVarChar;
    return BulkColumnType.nVarChar;
  }
}

/// TDS bulk copy (BCP) — `INSERT BULK` + [packBulkLoadBCP] stream.
///
/// Protocol: go-mssqldb `bulkcopy.go` / ms-tds Bulk Load BCP (§2.2.6.1.1).
class BulkLoad {
  static const _collation = [0x09, 0x04, 0xD0, 0x00, 0x34];

  /// Infers [BulkColumn]s from [columnNames] + first non-null value per column.
  static List<BulkColumn> inferColumns(
    List<String> columnNames,
    List<List<Object?>> rows,
  ) {
    if (columnNames.isEmpty) {
      throw ArgumentError('columns must not be empty');
    }
    return [
      for (var i = 0; i < columnNames.length; i++)
        BulkColumn(
          columnNames[i],
          BulkColumn.infer(_firstNonNull(rows, i)),
        ),
    ];
  }

  static Object? _firstNonNull(List<List<Object?>> rows, int col) {
    for (final row in rows) {
      if (col < row.length && row[col] != null) return row[col];
    }
    return null;
  }

  /// Builds `INSERT BULK [table] ( [c] type, … )`.
  static String insertBulkSql(String table, List<BulkColumn> columns) {
    final defs = columns
        .map((c) => '${_quoteIdentifier(c.name)} ${c.sqlDecl}')
        .join(', ');
    return 'INSERT BULK ${_quoteMultipartIdentifier(table)} ($defs)';
  }

  /// Builds a zero-row query used to read destination column metadata.
  static String selectMetadataSql(String table, List<String> columns) {
    if (columns.isEmpty) {
      throw ArgumentError('columns must not be empty');
    }
    final names = columns.map(_quoteIdentifier).join(', ');
    return 'SELECT TOP (0) $names FROM ${_quoteMultipartIdentifier(table)}';
  }

  /// Writes COLMETADATA + ROW* + DONE into an open [packBulkLoadBCP] packet.
  static void writePayload(
    TdsBuffer buf,
    List<BulkColumn> columns,
    List<List<Object?>> rows,
  ) {
    _writeColMetadata(buf, columns);
    for (final row in rows) {
      if (row.length != columns.length) {
        throw ArgumentError(
          'Row has ${row.length} values, expected ${columns.length}',
        );
      }
      _writeRow(buf, columns, row);
    }
    // DONE final (go-mssqldb Bulk.Done) — rowcount 0; server returns real count.
    buf.writeByte(tokenDone);
    buf.writeUint16LE(doneFlagFinal);
    buf.writeUint16LE(0); // curCmd
    buf.writeUint64LE(0);
  }

  static Future<void> send(
    TdsBuffer buf,
    List<BulkColumn> columns,
    List<List<Object?>> rows,
  ) async {
    buf.beginPacket(packBulkLoadBCP);
    writePayload(buf, columns, rows);
    await buf.finishPacket(packBulkLoadBCP);
  }

  /// Validates values before `INSERT BULK` puts the server in BCP mode.
  static void validateRows(
    List<BulkColumn> columns,
    List<List<Object?>> rows,
  ) {
    for (var rowIndex = 0; rowIndex < rows.length; rowIndex++) {
      final row = rows[rowIndex];
      for (var columnIndex = 0; columnIndex < columns.length; columnIndex++) {
        final column = columns[columnIndex];
        final value = row[columnIndex];
        if (value == null) {
          if (column.nullable == false) {
            throw ArgumentError(
              'Row $rowIndex column "${column.name}" is NOT NULL.',
            );
          }
          continue;
        }
        try {
          switch (column.type) {
            case BulkColumnType.bigInt:
              _asInt(value);
            case BulkColumnType.bit:
              break;
            case BulkColumnType.float64:
              _asDouble(value);
            case BulkColumnType.dateTime2:
              _asDateTime(value);
            case BulkColumnType.nVarChar:
              _stringBytes(column, value);
          }
        } on Object catch (error) {
          if (error is ArgumentError &&
              error.message.toString().contains('exceeds nvarchar')) {
            rethrow;
          }
          throw ArgumentError(
            'Invalid value for row $rowIndex column "${column.name}": '
            '$error',
          );
        }
      }
    }
  }

  static void _writeColMetadata(TdsBuffer buf, List<BulkColumn> columns) {
    buf.writeByte(tokenColMetadata);
    buf.writeUint16LE(columns.length);
    for (final col in columns) {
      buf.writeUint32LE(0); // userType
      // SQL Server validates fNullable against the destination column during
      // BCP and reports error 4816 when it does not match.
      final nullable = col.nullable ?? true;
      buf.writeUint16LE(0x08 | (nullable ? 0x01 : 0x00));
      writeTypeInfo(buf, col);
      final name = _ucs2(col.name);
      buf.writeByte(name.length >> 1);
      buf.writeBytes(name);
    }
  }

  /// TYPE_INFO for bulk / TVP columns (ms-tds §2.2.5.4).
  static void writeTypeInfo(TdsBuffer buf, BulkColumn col) {
    switch (col.type) {
      case BulkColumnType.bigInt:
        buf.writeByte(typeIntN);
        buf.writeByte(8);
      case BulkColumnType.bit:
        buf.writeByte(typeBitN);
        buf.writeByte(1);
      case BulkColumnType.float64:
        buf.writeByte(typeFltN);
        buf.writeByte(8);
      case BulkColumnType.dateTime2:
        buf.writeByte(typeDateTime2N);
        buf.writeByte(7); // scale
      case BulkColumnType.nVarChar:
        buf.writeByte(typeNVarChar);
        final maxChars = col.nVarCharLength.clamp(1, 4000);
        buf.writeUint16LE(maxChars * 2); // byte max length
        buf.writeBytes(_collation);
    }
  }

  static void _writeRow(
    TdsBuffer buf,
    List<BulkColumn> columns,
    List<Object?> values,
  ) {
    buf.writeByte(tokenRow);
    for (var i = 0; i < columns.length; i++) {
      writeCell(buf, columns[i], values[i]);
    }
  }

  /// One cell value (null / INTN / NVARCHAR / …) for bulk or TVP rows.
  static void writeCell(TdsBuffer buf, BulkColumn col, Object? value) {
    if (value == null) {
      switch (col.type) {
        case BulkColumnType.bigInt:
        case BulkColumnType.bit:
        case BulkColumnType.float64:
        case BulkColumnType.dateTime2:
          buf.writeByte(0); // BYTELEN null
        case BulkColumnType.nVarChar:
          buf.writeUint16LE(0xFFFF); // USHORTLEN null
      }
      return;
    }

    switch (col.type) {
      case BulkColumnType.bigInt:
        final v = _asInt(value);
        buf.writeByte(8);
        buf.writeUint32LE(v & 0xFFFFFFFF);
        buf.writeUint32LE((v >> 32) & 0xFFFFFFFF);
      case BulkColumnType.bit:
        final v = value is bool
            ? value
            : (value.toString().toLowerCase() == 'true' || value == 1);
        buf.writeByte(1);
        buf.writeByte(v ? 1 : 0);
      case BulkColumnType.float64:
        final v = _asDouble(value);
        buf.writeByte(8);
        final bytes = Uint8List(8);
        ByteData.sublistView(bytes).setFloat64(0, v, Endian.little);
        buf.writeBytes(bytes);
      case BulkColumnType.dateTime2:
        final dt = _asDateTime(value);
        _writeDateTime2(buf, dt);
      case BulkColumnType.nVarChar:
        final bytes = _stringBytes(col, value);
        buf.writeUint16LE(bytes.length);
        buf.writeBytes(bytes);
    }
  }

  static int _asInt(Object value) => value is int
      ? value
      : (value is num ? value.toInt() : int.parse(value.toString()));

  static double _asDouble(Object value) => value is double
      ? value
      : (value is num ? value.toDouble() : double.parse(value.toString()));

  static DateTime _asDateTime(Object value) =>
      value is DateTime ? value : DateTime.parse(value.toString());

  static Uint8List _stringBytes(BulkColumn column, Object value) {
    final string = value is String ? value : value.toString();
    final bytes = _ucs2(string);
    final maxBytes = column.nVarCharLength.clamp(1, 4000) * 2;
    if (bytes.length > maxBytes) {
      throw ArgumentError(
        'String for column "${column.name}" exceeds '
        'nvarchar(${column.nVarCharLength})',
      );
    }
    return bytes;
  }

  /// Same encoding as [RpcRequest] DATETIME2 scale 7.
  static void _writeDateTime2(TdsBuffer buf, DateTime dt) {
    final micros = dt.hour * 3600000000 +
        dt.minute * 60000000 +
        dt.second * 1000000 +
        dt.millisecond * 1000 +
        dt.microsecond;
    final ticks = micros * 10;
    final days = DateTime.utc(dt.year, dt.month, dt.day)
        .difference(DateTime.utc(1, 1, 1))
        .inDays;
    buf.writeByte(8);
    buf.writeByte(ticks & 0xFF);
    buf.writeByte((ticks >> 8) & 0xFF);
    buf.writeByte((ticks >> 16) & 0xFF);
    buf.writeByte((ticks >> 24) & 0xFF);
    buf.writeByte((ticks >> 32) & 0xFF);
    buf.writeByte(days & 0xFF);
    buf.writeByte((days >> 8) & 0xFF);
    buf.writeByte((days >> 16) & 0xFF);
  }

  static String _quoteMultipartIdentifier(String name) {
    final parts = _splitIdentifierParts(name);
    if (parts.length > 4) {
      throw ArgumentError('SQL identifier has too many parts: "$name"');
    }
    return parts.map(_quoteIdentifier).join('.');
  }

  static List<String> _splitIdentifierParts(String name) {
    final parts = <String>[];
    final part = StringBuffer();
    var inBrackets = false;

    for (var i = 0; i < name.length; i++) {
      final code = name.codeUnitAt(i);
      if (inBrackets) {
        part.writeCharCode(code);
        if (code == 0x5D) {
          if (i + 1 < name.length && name.codeUnitAt(i + 1) == 0x5D) {
            i++;
            part.writeCharCode(0x5D);
          } else {
            inBrackets = false;
          }
        }
        continue;
      }

      if (code == 0x2E) {
        parts.add(part.toString());
        part.clear();
      } else {
        if (code == 0x5B) inBrackets = true;
        part.writeCharCode(code);
      }
    }
    parts.add(part.toString());
    return parts;
  }

  static String _quoteIdentifier(String name) {
    _validateNoControlCharacters(name);
    final decoded = _decodeOptionalBrackets(name.trim());
    _validateIdentifierPart(decoded, name);
    return '[${decoded.replaceAll(']', ']]')}]';
  }

  static String _decodeOptionalBrackets(String name) {
    if (!_isBracketedIdentifier(name)) return name;
    return name.substring(1, name.length - 1).replaceAll(']]', ']');
  }

  static bool _isBracketedIdentifier(String name) {
    if (name.length < 2 || !name.startsWith('[') || !name.endsWith(']')) {
      return false;
    }
    for (var i = 1; i < name.length - 1; i++) {
      if (name.codeUnitAt(i) == 0x5D) {
        if (i + 1 >= name.length - 1 || name.codeUnitAt(i + 1) != 0x5D) {
          return false;
        }
        i++;
      }
    }
    return true;
  }

  static void _validateIdentifierPart(String decoded, String original) {
    if (decoded.isEmpty) {
      throw ArgumentError('SQL identifier part must not be empty: "$original"');
    }
    if (decoded.length > 128) {
      throw ArgumentError(
          'SQL identifier part exceeds 128 characters: "$original"');
    }
    _validateNoControlCharacters(decoded, original: original);
  }

  static void _validateNoControlCharacters(String value, {String? original}) {
    for (var i = 0; i < value.length; i++) {
      final code = value.codeUnitAt(i);
      if (code < 0x20 || code == 0x7F) {
        throw ArgumentError(
          'SQL identifier part contains a control character: '
          '"${original ?? value}"',
        );
      }
    }
  }

  static Uint8List _ucs2(String s) {
    final out = Uint8List(s.length * 2);
    for (var i = 0; i < s.length; i++) {
      out[i * 2] = s.codeUnitAt(i) & 0xFF;
      out[i * 2 + 1] = (s.codeUnitAt(i) >> 8) & 0xFF;
    }
    return out;
  }
}
