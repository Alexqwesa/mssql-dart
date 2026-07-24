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

/// SQL `decimal(p,s)` / `numeric(p,s)` parameter binder.
///
/// Prefer this over [double] when the column requires exact scale (prices,
/// quantities). Decode still returns [double] today.
///
/// ```dart
/// await conn.query('SELECT @d', {
///   'd': MssqlDecimal(1234.5, precision: 10, scale: 2),
/// });
/// // or: MssqlDecimal.parse('1234.50', precision: 10, scale: 2)
/// ```
class MssqlDecimal {
  /// Signed unscaled integer (`value * 10^scale`).
  final BigInt unscaled;

  /// Total significant digits (1–38).
  final int precision;

  /// Digits after the decimal point (0–[precision]).
  final int scale;

  /// When true, declare/encode as `numeric` (`typeNumericN`); else `decimal`.
  final bool asNumeric;

  MssqlDecimal._({
    required this.unscaled,
    required this.precision,
    required this.scale,
    this.asNumeric = false,
  }) {
    if (precision < 1 || precision > 38) {
      throw ArgumentError.value(precision, 'precision', 'must be 1–38');
    }
    if (scale < 0 || scale > precision) {
      throw ArgumentError.value(scale, 'scale', 'must be 0–precision');
    }
    final digits = unscaled.abs().toString().length;
    // BigInt.zero → "0" has length 1; allow zero always.
    if (unscaled != BigInt.zero && digits > precision) {
      throw ArgumentError(
        'Value $unscaled exceeds decimal($precision,$scale) precision',
      );
    }
  }

  /// Builds from a [num], fixing [scale] with half-up rounding via string form.
  factory MssqlDecimal(
    num value, {
    int precision = 18,
    int scale = 4,
    bool asNumeric = false,
  }) {
    if (value is int) {
      return MssqlDecimal.parse(
        value.toString(),
        precision: precision,
        scale: scale,
        asNumeric: asNumeric,
      );
    }
    return MssqlDecimal.parse(
      value.toStringAsFixed(scale),
      precision: precision,
      scale: scale,
      asNumeric: asNumeric,
    );
  }

  /// Parses a decimal literal (`-1234.56`). [scale] pads/truncates the fraction.
  factory MssqlDecimal.parse(
    String text, {
    int precision = 18,
    int scale = 4,
    bool asNumeric = false,
  }) {
    var t = text.trim().replaceAll(',', '');
    if (t.isEmpty) {
      throw ArgumentError.value(text, 'text', 'empty decimal');
    }
    var negative = false;
    if (t.startsWith('-')) {
      negative = true;
      t = t.substring(1);
    } else if (t.startsWith('+')) {
      t = t.substring(1);
    }
    final parts = t.split('.');
    if (parts.length > 2) {
      throw ArgumentError.value(text, 'text', 'invalid decimal');
    }
    final intPart = parts[0].isEmpty ? '0' : parts[0];
    var frac = parts.length > 1 ? parts[1] : '';
    if (frac.length > scale) {
      // Truncate toward zero for determinism (matches many drivers' default).
      frac = frac.substring(0, scale);
    }
    while (frac.length < scale) {
      frac = '${frac}0';
    }
    final digitsRaw = '$intPart$frac';
    var digits = digitsRaw.replaceFirst(RegExp(r'^0+'), '');
    if (digits.isEmpty) digits = '0';
    var coeff = BigInt.parse(digits);
    if (negative && coeff != BigInt.zero) coeff = -coeff;
    return MssqlDecimal._(
      unscaled: coeff,
      precision: precision,
      scale: scale,
      asNumeric: asNumeric,
    );
  }

  /// MaxLen byte for DECIMALN/NUMERICN TYPE_INFO (ms-tds / go-mssqldb).
  static int maxLenForPrecision(int precision) {
    if (precision <= 9) return 5;
    if (precision <= 19) return 9;
    if (precision <= 28) return 13;
    return 17;
  }

  /// TDS value bytes: sign + LE limbs (length = [maxLenForPrecision]).
  Uint8List toWireBytes() {
    final maxLen = maxLenForPrecision(precision);
    final out = Uint8List(maxLen);
    out[0] = unscaled >= BigInt.zero ? 1 : 0;
    var remaining = unscaled.abs();
    for (var i = 1; i < maxLen; i += 4) {
      final limb = (remaining & BigInt.from(0xFFFFFFFF)).toInt();
      remaining >>= 32;
      out[i] = limb & 0xFF;
      if (i + 1 < maxLen) out[i + 1] = (limb >> 8) & 0xFF;
      if (i + 2 < maxLen) out[i + 2] = (limb >> 16) & 0xFF;
      if (i + 3 < maxLen) out[i + 3] = (limb >> 24) & 0xFF;
    }
    return out;
  }

  String get sqlDecl =>
      '${asNumeric ? 'numeric' : 'decimal'}($precision,$scale)';

  @override
  String toString() {
    final abs = unscaled.abs().toString().padLeft(scale + 1, '0');
    final neg = unscaled < BigInt.zero ? '-' : '';
    if (scale == 0) return '$neg$abs';
    final split = abs.length - scale;
    return '$neg${abs.substring(0, split)}.${abs.substring(split)}';
  }
}

/// SQL `varchar` parameter (8-bit / collation bytes) — not `nvarchar`.
///
/// Bare [String] params are sent as `nvarchar`. Use this when the column or
/// SP parameter is `varchar` / `char` so the server avoids implicit conversions
/// (go-mssqldb `mssql.VarChar`).
///
/// Values are encoded as Latin-1 (`0x00`–`0xFF` code units). Non-Latin-1
/// characters throw [ArgumentError].
class MssqlVarchar {
  final String value;

  /// Force `varchar(max)` / PLP (also used automatically when length > 8000).
  final bool max;

  const MssqlVarchar(this.value, {this.max = false});

  /// Latin-1 wire bytes (same decode path as [typeBigVarChar] reads).
  List<int> toWireBytes() {
    final out = <int>[];
    for (final c in value.codeUnits) {
      if (c > 0xFF) {
        throw ArgumentError.value(
          value,
          'value',
          'MssqlVarchar requires Latin-1 (code unit ≤ 0xFF); got U+${c.toRadixString(16)}',
        );
      }
      out.add(c);
    }
    return out;
  }

  String get sqlDecl {
    if (max || value.length > 8000) return 'varchar(max)';
    return 'varchar(8000)';
  }

  @override
  String toString() => value;
}

/// SQL `date` parameter (date-only, no time) — go-mssqldb / civil.Date.
///
/// Prefer this over bare [DateTime] when the column is `date` (bare [DateTime]
/// is sent as `datetime2`).
class MssqlDate {
  final int year;
  final int month;
  final int day;

  MssqlDate(this.year, this.month, this.day) {
    if (month < 1 || month > 12) {
      throw ArgumentError.value(month, 'month', 'must be 1–12');
    }
    if (day < 1 || day > 31) {
      throw ArgumentError.value(day, 'day', 'must be 1–31');
    }
    // Dart DateTime overflows invalid days (Feb 30 → Mar); reject those.
    final dt = DateTime.utc(year, month, day);
    if (dt.year != year || dt.month != month || dt.day != day) {
      throw ArgumentError('Invalid calendar date $year-$month-$day');
    }
  }

  factory MssqlDate.fromDateTime(DateTime dt) =>
      MssqlDate(dt.year, dt.month, dt.day);

  /// Days since 0001-01-01 (ms-tds DATE).
  int get daysSinceYear1 =>
      DateTime.utc(year, month, day).difference(DateTime.utc(1, 1, 1)).inDays;

  @override
  String toString() =>
      '${year.toString().padLeft(4, '0')}-'
      '${month.toString().padLeft(2, '0')}-'
      '${day.toString().padLeft(2, '0')}';
}

/// SQL `time` parameter (time-of-day, no date) — go-mssqldb / civil.Time.
///
/// Prefer this over bare [DateTime] when the column is `time`.
class MssqlTime {
  final int hour;
  final int minute;
  final int second;

  /// Fractional seconds as microseconds (0–999999); truncated to [scale].
  final int microsecond;

  /// Scale 0–7 (default 7).
  final int scale;

  MssqlTime({
    required this.hour,
    required this.minute,
    this.second = 0,
    this.microsecond = 0,
    this.scale = 7,
  }) {
    if (hour < 0 || hour > 23) {
      throw ArgumentError.value(hour, 'hour', 'must be 0–23');
    }
    if (minute < 0 || minute > 59) {
      throw ArgumentError.value(minute, 'minute', 'must be 0–59');
    }
    if (second < 0 || second > 59) {
      throw ArgumentError.value(second, 'second', 'must be 0–59');
    }
    if (microsecond < 0 || microsecond > 999999) {
      throw ArgumentError.value(microsecond, 'microsecond', 'must be 0–999999');
    }
    if (scale < 0 || scale > 7) {
      throw ArgumentError.value(scale, 'scale', 'must be 0–7');
    }
  }

  factory MssqlTime.fromDateTime(DateTime dt, {int scale = 7}) => MssqlTime(
        hour: dt.hour,
        minute: dt.minute,
        second: dt.second,
        microsecond: dt.millisecond * 1000 + dt.microsecond,
        scale: scale,
      );

  factory MssqlTime.fromDuration(Duration d, {int scale = 7}) {
    final us = d.inMicroseconds;
    if (us < 0 || us >= Duration.microsecondsPerDay) {
      throw ArgumentError.value(d, 'd', 'must be within 00:00:00–23:59:59.999999');
    }
    final h = us ~/ Duration.microsecondsPerHour;
    final rem = us % Duration.microsecondsPerHour;
    final m = rem ~/ Duration.microsecondsPerMinute;
    final rem2 = rem % Duration.microsecondsPerMinute;
    final s = rem2 ~/ Duration.microsecondsPerSecond;
    final micros = rem2 % Duration.microsecondsPerSecond;
    return MssqlTime(
      hour: h,
      minute: m,
      second: s,
      microsecond: micros,
      scale: scale,
    );
  }

  String get sqlDecl => 'time($scale)';

  @override
  String toString() {
    final frac = microsecond.toString().padLeft(6, '0');
    return '${hour.toString().padLeft(2, '0')}:'
        '${minute.toString().padLeft(2, '0')}:'
        '${second.toString().padLeft(2, '0')}.$frac';
  }
}
