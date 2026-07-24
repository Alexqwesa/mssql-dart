import 'dart:typed_data';

/// SQL `uniqueidentifier` parameter / value helper.
///
/// Wire format uses SQL Server mixed-endian GUID bytes (go-mssqldb
/// `UniqueIdentifier.Value`). Decode already returns the canonical
/// `xxxxxxxx-xxxx-xxxx-xxxx-xxxxxxxxxxxx` string.
class MssqlGuid {
  /// Canonical GUID string (with or without braces / dashes).
  final String value;

  const MssqlGuid(this.value);

  /// Parses [value] into 16 wire bytes (mixed endian).
  Uint8List toWireBytes() {
    final hex = value.replaceAll(RegExp(r'[{}\-]'), '');
    if (hex.length != 32) {
      throw ArgumentError.value(
        value,
        'value',
        'GUID must be 32 hex digits (dashes optional)',
      );
    }
    final d = Uint8List(16);
    for (var i = 0; i < 16; i++) {
      d[i] = int.parse(hex.substring(i * 2, i * 2 + 2), radix: 16);
    }
    void rev(int a, int b) {
      for (var i = a, j = b; i < j; i++, j--) {
        final t = d[i];
        d[i] = d[j];
        d[j] = t;
      }
    }

    rev(0, 3);
    rev(4, 5);
    rev(6, 7);
    return d;
  }

  @override
  String toString() => value;
}

/// SQL `money` parameter (8-byte, 4 decimal places).
///
/// Prefer this over bare [double] when the column / SP param is `money`.
class MssqlMoney {
  final double value;

  const MssqlMoney(this.value);

  /// Scaled integer (`value * 10000`, rounded).
  int get scaled => (value * 10000).round();

  @override
  String toString() => value.toString();
}

/// SQL `smallmoney` parameter (4-byte, 4 decimal places).
class MssqlSmallMoney {
  final double value;

  const MssqlSmallMoney(this.value);

  int get scaled => (value * 10000).round();

  @override
  String toString() => value.toString();
}

/// SQL `datetimeoffset` parameter — preserves timezone offset on write.
///
/// On read, the driver returns a UTC [DateTime] (offset is stripped after
/// decode). Use this wrapper when writing so the offset is sent.
///
/// [offset] overrides [DateTime.timeZoneOffset] when the host timezone cannot
/// express the desired zone (common in tests). The instant is always taken
/// from [value.toUtc](); [offset] is only the wire offset field.
class MssqlDateTimeOffset {
  final DateTime value;

  /// Scale 0–7 (default 7).
  final int scale;

  /// Optional wire offset; defaults to [value.timeZoneOffset].
  final Duration? offset;

  const MssqlDateTimeOffset(this.value, {this.scale = 7, this.offset});

  Duration get wireOffset => offset ?? value.timeZoneOffset;

  @override
  String toString() => value.toIso8601String();
}
