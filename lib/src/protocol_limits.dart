/// Configurable safety limits for server-controlled TDS response sizes.
///
/// All limits default to `null` (unlimited) to preserve existing behaviour.
/// Set limits when connecting to untrusted endpoints or when queries may return
/// unexpectedly large values.
class MssqlProtocolLimits {
  /// Maximum byte length for one token body or token-owned payload.
  final int? maximumTokenBytes;

  /// Maximum byte length for one decoded column / output value.
  final int? maximumValueBytes;

  /// Maximum byte length for a single PLP chunk.
  final int? maximumPlpChunkBytes;

  /// Maximum number of columns in one result set.
  final int? maximumColumns;

  /// Maximum number of result sets buffered by `queryMultiple` / drained by
  /// response parsers.
  final int? maximumResultSets;

  const MssqlProtocolLimits({
    this.maximumTokenBytes,
    this.maximumValueBytes,
    this.maximumPlpChunkBytes,
    this.maximumColumns,
    this.maximumResultSets,
  })  : assert(maximumTokenBytes == null || maximumTokenBytes >= 0),
        assert(maximumValueBytes == null || maximumValueBytes >= 0),
        assert(maximumPlpChunkBytes == null || maximumPlpChunkBytes >= 0),
        assert(maximumColumns == null || maximumColumns >= 0),
        assert(maximumResultSets == null || maximumResultSets >= 0);

  /// Compatibility default: no configured protocol size limits.
  static const unlimited = MssqlProtocolLimits();

  void checkTokenBytes(int length, String context) {
    _checkNonNegative(length, context);
    _checkMaximum(length, maximumTokenBytes, context);
  }

  void checkValueBytes(int length, String context) {
    _checkNonNegative(length, context);
    _checkMaximum(length, maximumValueBytes, context);
  }

  void checkPlpChunkBytes(int length, String context) {
    _checkNonNegative(length, context);
    _checkMaximum(length, maximumPlpChunkBytes, context);
    _checkMaximum(length, maximumValueBytes, context);
  }

  void checkColumns(int count, String context) {
    _checkNonNegative(count, context);
    _checkMaximum(count, maximumColumns, context);
  }

  void checkResultSets(int count, String context) {
    _checkNonNegative(count, context);
    _checkMaximum(count, maximumResultSets, context);
  }

  static void _checkNonNegative(int value, String context) {
    if (value < 0) {
      throw FormatException('$context length is negative: $value');
    }
  }

  static void _checkMaximum(int value, int? maximum, String context) {
    if (maximum != null && value > maximum) {
      throw FormatException(
        '$context length $value exceeds configured maximum $maximum',
      );
    }
  }
}
