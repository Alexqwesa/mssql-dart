import 'dart:async';
import 'dart:typed_data';

import '../auth/azure_ad_auth.dart';
import '../exception.dart';
import 'buf.dart';
import 'constants.dart';
import 'type_info.dart';

/// A fully parsed column descriptor.
class ColumnMeta {
  final String name;
  final TypeInfo typeInfo;
  final int userType;
  final int flags;

  const ColumnMeta({
    required this.name,
    required this.typeInfo,
    required this.userType,
    required this.flags,
  });

  bool get nullable => (flags & 0x01) != 0;
}

/// Result of processing the server token stream after LOGIN7.
class LoginResult {
  final String database;
  final String serverVersion;
  final int packetSize;

  const LoginResult({
    required this.database,
    required this.serverVersion,
    required this.packetSize,
  });
}

/// Result of processing a query's token stream.
class QueryResult {
  final List<ColumnMeta> columns;
  final List<List<Object?>> rows;
  final int rowsAffected;

  const QueryResult({
    required this.columns,
    required this.rows,
    required this.rowsAffected,
  });
}

/// Processes the TDS response token stream from the server.
class TokenStream {
  final TdsBuffer _buf;

  /// Invoked when ENVCHANGE type 1 (database) is seen — new database name.
  final void Function(String database)? onDatabaseChanged;

  /// Last `RETURN` status (`tokenReturnStatus` 0x79) from the most recent
  /// response parse. Cleared at the start of each query response method.
  int? lastReturnStatus;

  /// OUTPUT parameter values from `tokenReturnValue` (0xAC), keyed without `@`.
  final Map<String, Object?> lastReturnValues = {};

  TokenStream(this._buf, {this.onDatabaseChanged});

  void _clearReturnState() {
    lastReturnStatus = null;
    lastReturnValues.clear();
  }

  /// Process the server response after LOGIN7. Returns basic session metadata.
  ///
  /// [onSspi] is invoked when the server sends a [tokenSSPI] challenge (NTLM
  /// Type 2). The returned bytes are sent as [packSSPIMessage] (Type 3).
  ///
  /// [onFedAuthInfo] is invoked when the server sends [tokenFedAuthInfo]
  /// (ADAL). The returned bearer token is sent as [packFedAuthToken]. If null,
  /// the FEDAUTHINFO payload is skipped (SecurityToken / pre-acquired token
  /// path does not need it).
  Future<LoginResult> processLoginResponse({
    Future<List<int>> Function(Uint8List challenge)? onSspi,
    Future<String> Function(FedAuthInfo info)? onFedAuthInfo,
  }) async {
    String database = '';
    String serverVersion = '';
    int packetSize = defaultPacketSize;

    await _buf.beginRead();

    while (true) {
      final tok = await _buf.readUint8();
      switch (tok) {
        case tokenEnvChange:
          final env = await _readEnvChange();
          if (env.$1 == envDatabase) {
            database = env.$2;
            onDatabaseChanged?.call(env.$2);
          }
          if (env.$1 == envPacketSize) {
            packetSize = int.tryParse(env.$2) ?? defaultPacketSize;
          }
        case tokenLoginAck:
          serverVersion = await _readLoginAck();
        case tokenFeatureExtAck:
          await _skipFeatureExtAck();
        case tokenInfo:
          await _skipInfoOrError();
        case tokenError:
          final err = await _readError();
          // Login errors are always fatal and always single; throw immediately.
          throw MssqlException(err.$1, errorCode: err.$2);
        case tokenSSPI:
          // USHORT length + SSPI blob (go-mssqldb parseSSPIMsg / ms-tds §2.2.7.22)
          final sspiLen = await _buf.readUint16LE();
          final challenge = Uint8List.fromList(await _buf.readBytes(sspiLen));
          if (onSspi == null) {
            throw StateError(
              'Server sent SSPI challenge but no NTLM/SSPI handler was provided',
            );
          }
          final response = await onSspi(challenge);
          if (response.isNotEmpty) {
            _buf.beginPacket(packSSPIMessage);
            _buf.writeBytes(response);
            await _buf.finishPacket(packSSPIMessage);
          }
          // SSPI reply continues in the next server message.
          await _buf.beginRead();
        case tokenFedAuthInfo:
          // ULONG size + options (go-mssqldb parseFedAuthInfo / ms-tds §2.2.7.12)
          final info = await _readFedAuthInfo();
          if (onFedAuthInfo != null) {
            final token = await onFedAuthInfo(info);
            await _sendFedAuthToken(token);
            await _buf.beginRead();
          }
        case tokenDone:
        case tokenDoneProc:
        case tokenDoneInProc:
          final flags = await _buf.readUint16LE();
          await _buf.readUint16LE(); // curCmd
          await _buf.readUint64LE(); // rowCount
          if ((flags & doneFlagMore) == 0) {
            return LoginResult(
              database: database,
              serverVersion: serverVersion,
              packetSize: packetSize,
            );
          }
        default:
          throw StateError(
              'Unexpected token 0x${tok.toRadixString(16)} during login');
      }
    }
  }

  /// Process the server response and return the first result set.
  ///
  /// Drains all result sets from the stream but discards extras beyond the first.
  /// Use [processAllQueryResponses] when multiple result sets are needed.
  Future<QueryResult> processQueryResponse() async {
    final sets = await processAllQueryResponses();
    if (sets.isEmpty) {
      return QueryResult(columns: [], rows: [], rowsAffected: 0);
    }
    // Sum rowsAffected across all sets (matches node-mssql behaviour for DML).
    final totalAffected = sets.fold(0, (s, r) => s + r.rowsAffected);
    final first = sets.first;
    if (sets.length == 1) return first;
    return QueryResult(
      columns: first.columns,
      rows: first.rows,
      rowsAffected: totalAffected,
    );
  }

  /// Process the server response and return every result set.
  ///
  /// Stored procedures that execute multiple SELECT statements produce one
  /// [QueryResult] per SELECT, each with its own column schema and rows.
  Future<List<QueryResult>> processAllQueryResponses() async {
    _clearReturnState();
    final results = <QueryResult>[];
    List<ColumnMeta>? columns;
    List<List<Object?>> rows = [];
    int rowsAffected = 0;
    final errors = <MssqlException>[];

    await _buf.beginRead();

    while (true) {
      final tok = await _buf.readUint8();
      switch (tok) {
        case tokenColMetadata:
          // A new COLMETADATA token starts a new result set.
          if (columns != null && columns.isNotEmpty) {
            results.add(QueryResult(
                columns: columns, rows: rows, rowsAffected: rowsAffected));
            rows = [];
            rowsAffected = 0;
          }
          columns = await _readColMetadata();
        case tokenRow:
          if (columns == null) throw StateError('ROW token before COLMETADATA');
          rows.add(await _readRow(columns));
        case tokenNbcRow:
          if (columns == null) {
            throw StateError('NBCROW token before COLMETADATA');
          }
          rows.add(await _readNbcRow(columns));
        case tokenOrder:
          await _skipOrder();
        case tokenEnvChange:
          await _applyEnvChange();
        case tokenReturnStatus:
          lastReturnStatus = await _buf.readInt32LE();
        case tokenReturnValue:
          final rv = await _readReturnValue();
          lastReturnValues[rv.$1] = rv.$2;
        case tokenInfo:
          await _skipInfoOrError();
        case tokenError:
          final err = await _readError();
          errors.add(MssqlException(err.$1, errorCode: err.$2));
        case tokenDone:
        case tokenDoneProc:
        case tokenDoneInProc:
          final flags = await _buf.readUint16LE();
          await _buf.readUint16LE(); // curCmd
          final count = await _buf.readUint64LE();
          if ((flags & doneFlagCount) != 0) rowsAffected += count;
          if ((flags & doneFlagMore) == 0) {
            final attnAck = (flags & doneFlagAttn) != 0;
            if (attnAck) _buf.attentionSent = false;

            // Flush the last (or only) result set.
            if (columns != null && columns.isNotEmpty) {
              results.add(QueryResult(
                  columns: columns, rows: rows, rowsAffected: rowsAffected));
            } else if (rowsAffected > 0) {
              // DML with no SELECT (INSERT/UPDATE/DELETE) — emit a rowsAffected-only result.
              results.add(QueryResult(
                  columns: [], rows: [], rowsAffected: rowsAffected));
            }
            if (errors.isNotEmpty) throw _buildError(errors);

            // Cancel path: server may send a normal DONE for the aborted batch
            // then a separate Attention ACK message — keep draining until ATTN.
            if (_buf.attentionSent && !attnAck) {
              results.clear();
              columns = null;
              rows = [];
              rowsAffected = 0;
              await _buf.beginRead();
              continue;
            }

            // Attention ACK alone — cancelled query yields no result sets.
            if (attnAck) return <QueryResult>[];

            return results;
          }
        default:
          throw StateError(
              'Unexpected token 0x${tok.toRadixString(16)} in query response');
      }
    }
  }

  /// Streams rows from the server response one at a time.
  ///
  /// Yields rows as they arrive from the network — useful for large result sets
  /// where buffering all rows would be expensive. Only the first result set is
  /// streamed; subsequent sets (from stored procedures) are drained and discarded.
  ///
  /// The stream emits `(columns, row)` pairs so callers always have schema info.
  Stream<(List<ColumnMeta>, List<Object?>)> streamQueryResponse() async* {
    _clearReturnState();
    List<ColumnMeta>? columns;
    // inFirstSet: true only while reading the first COLMETADATA group's rows.
    // Rows from subsequent result sets are read and discarded (not yielded).
    bool inFirstSet = false;
    bool seenFirstSet = false;
    final errors = <MssqlException>[];

    await _buf.beginRead();

    while (true) {
      final tok = await _buf.readUint8();
      switch (tok) {
        case tokenColMetadata:
          columns = await _readColMetadata();
          if (!seenFirstSet) {
            seenFirstSet = true;
            inFirstSet = true;
          } else {
            inFirstSet = false; // second+ result set — drain without yielding
          }
        case tokenRow:
          if (columns == null) throw StateError('ROW token before COLMETADATA');
          final row = await _readRow(columns);
          if (inFirstSet) yield (columns, row);
        case tokenNbcRow:
          if (columns == null) {
            throw StateError('NBCROW token before COLMETADATA');
          }
          final row = await _readNbcRow(columns);
          if (inFirstSet) yield (columns, row);
        case tokenOrder:
          await _skipOrder();
        case tokenEnvChange:
          await _applyEnvChange();
        case tokenReturnStatus:
          lastReturnStatus = await _buf.readInt32LE();
        case tokenReturnValue:
          final rv = await _readReturnValue();
          lastReturnValues[rv.$1] = rv.$2;
        case tokenInfo:
          await _skipInfoOrError();
        case tokenError:
          final err = await _readError();
          errors.add(MssqlException(err.$1, errorCode: err.$2));
        case tokenDone:
        case tokenDoneProc:
        case tokenDoneInProc:
          final flags = await _buf.readUint16LE();
          await _buf.readUint16LE(); // curCmd
          await _buf.readUint64LE(); // rowCount
          if ((flags & doneFlagMore) == 0) {
            final attnAck = (flags & doneFlagAttn) != 0;
            if (attnAck) _buf.attentionSent = false;
            if (errors.isNotEmpty) throw _buildError(errors);
            if (_buf.attentionSent && !attnAck) {
              await _buf.beginRead();
              continue;
            }
            return;
          }
        default:
          throw StateError(
              'Unexpected token 0x${tok.toRadixString(16)} in query response');
      }
    }
  }

  /// Drains tokens from the current (or next) response until Attention is ACKed
  /// or a final DONE arrives with [attentionSent] already clear.
  ///
  /// Does not call [TdsBuffer.beginRead] first — caller must already be inside a
  /// message (e.g. after a cancelled [streamQueryResponse]), or must beginRead
  /// themselves before invoking this.
  Future<void> drainUntilAttentionAck() async {
    List<ColumnMeta>? columns;
    while (true) {
      final tok = await _buf.readUint8();
      switch (tok) {
        case tokenColMetadata:
          columns = await _readColMetadata();
        case tokenRow:
          if (columns == null) {
            throw StateError('ROW token before COLMETADATA while draining');
          }
          await _readRow(columns);
        case tokenNbcRow:
          if (columns == null) {
            throw StateError('NBCROW token before COLMETADATA while draining');
          }
          await _readNbcRow(columns);
        case tokenOrder:
          await _skipOrder();
        case tokenEnvChange:
          await _applyEnvChange();
        case tokenReturnStatus:
          lastReturnStatus = await _buf.readInt32LE();
        case tokenReturnValue:
          final rv = await _readReturnValue();
          lastReturnValues[rv.$1] = rv.$2;
        case tokenInfo:
          await _skipInfoOrError();
        case tokenError:
          await _skipInfoOrError();
        case tokenDone:
        case tokenDoneProc:
        case tokenDoneInProc:
          final flags = await _buf.readUint16LE();
          await _buf.readUint16LE();
          await _buf.readUint64LE();
          if ((flags & doneFlagMore) == 0) {
            final attnAck = (flags & doneFlagAttn) != 0;
            if (attnAck) _buf.attentionSent = false;
            if (_buf.attentionSent && !attnAck) {
              columns = null;
              await _buf.beginRead();
              continue;
            }
            return;
          }
        default:
          throw StateError(
              'Unexpected token 0x${tok.toRadixString(16)} while draining');
      }
    }
  }

  // ── Token readers ──────────────────────────────────────────────────────────

  /// Applies ENVCHANGE side effects (txn descriptor, database callback).
  Future<void> _applyEnvChange() async {
    final env = await _readEnvChange();
    if (env.$1 == envDatabase) {
      onDatabaseChanged?.call(env.$2);
    }
  }

  /// Builds the exception to throw when a response contains one or more errors.
  ///
  /// SQL Server convention: the last error in the list is the "primary" one
  /// (e.g. "Could not create constraint — see previous errors"), and earlier
  /// errors give context. We surface the last as the main exception and attach
  /// the full ordered list as [MssqlException.precedingErrors].
  static MssqlException _buildError(List<MssqlException> errors) {
    final last = errors.last;
    if (errors.length == 1) return last;
    return MssqlException(
      last.message,
      errorCode: last.errorCode,
      severity: last.severity,
      precedingErrors: errors,
    );
  }

  Future<String> _readLoginAck() async {
    final length = await _buf.readUint16LE();
    final data = await _buf.readBytes(length);
    final nameLen = data[5];
    final nameBytes = data.sublist(6, 6 + nameLen * 2);
    final name = String.fromCharCodes(
      [
        for (int i = 0; i < nameBytes.length; i += 2)
          nameBytes[i] | (nameBytes[i + 1] << 8)
      ],
    );
    return name;
  }

  Future<void> _skipFeatureExtAck() async {
    while (true) {
      final featureId = await _buf.readUint8();
      if (featureId == featExtTerminator) break;
      final len = await _buf.readUint32LE();
      await _buf.readBytes(len);
    }
  }

  /// Parses [tokenFedAuthInfo] body (size already unread — reads ULONG size).
  Future<FedAuthInfo> _readFedAuthInfo() async {
    final size = await _buf.readUint32LE();
    if (size < 4) {
      if (size > 0) await _buf.readBytes(size);
      return const FedAuthInfo();
    }
    final count = await _buf.readUint32LE();
    var offset = 4; // bytes consumed within [size] after reading count
    final opts = <({int id, int dataLength, int dataOffset})>[];
    for (var i = 0; i < count; i++) {
      final id = await _buf.readUint8();
      final dataLength = await _buf.readUint32LE();
      final dataOffset = await _buf.readUint32LE();
      offset += 1 + 4 + 4;
      opts.add((id: id, dataLength: dataLength, dataOffset: dataOffset));
    }
    final remaining = size - offset;
    final data = remaining > 0
        ? await _buf.readBytes(remaining)
        : <int>[];

    var stsUrl = '';
    var spn = '';
    for (final opt in opts) {
      if (opt.dataOffset < offset) {
        throw FormatException(
          'FEDAUTHINFO dataOffset ${opt.dataOffset} < header end $offset',
        );
      }
      final start = opt.dataOffset - offset;
      final end = start + opt.dataLength;
      if (end > data.length) {
        throw FormatException('FEDAUTHINFO option exceeds token size');
      }
      final raw = data.sublist(start, end);
      final text = _ucs2String(raw);
      switch (opt.id) {
        case fedAuthInfoStsUrl:
          stsUrl = text;
        case fedAuthInfoSpn:
          spn = text;
        default:
          // Unknown option — ignore (forward compatible).
          break;
      }
    }
    return FedAuthInfo(stsUrl: stsUrl, serverSpn: spn);
  }

  Future<void> _sendFedAuthToken(String token, {List<int> nonce = const []}) async {
    // go-mssqldb sendFedAuthToken / ms-tds packFedAuthToken (type 8)
    final tokenBytes = _ucs2Bytes(token);
    final dataLen = 4 + tokenBytes.length + nonce.length;
    _buf.beginPacket(packFedAuthToken);
    _buf.writeUint32LE(dataLen);
    _buf.writeUint32LE(tokenBytes.length);
    _buf.writeBytes(tokenBytes);
    if (nonce.isNotEmpty) _buf.writeBytes(nonce);
    await _buf.finishPacket(packFedAuthToken);
  }

  static String _ucs2String(List<int> bytes) {
    final codes = <int>[];
    for (var i = 0; i + 1 < bytes.length; i += 2) {
      codes.add(bytes[i] | (bytes[i + 1] << 8));
    }
    return String.fromCharCodes(codes);
  }

  static Uint8List _ucs2Bytes(String s) {
    final out = Uint8List(s.length * 2);
    for (var i = 0; i < s.length; i++) {
      final c = s.codeUnitAt(i);
      out[i * 2] = c & 0xFF;
      out[i * 2 + 1] = (c >> 8) & 0xFF;
    }
    return out;
  }

  Future<(int, String, String)> _readEnvChange() async {
    final length = await _buf.readUint16LE();
    final data = await _buf.readBytes(length);
    final type = data[0];
    int i = 1;

    if (type == envSqlCollation || type == envRouting) {
      return (type, '', '');
    }

    if (type == envBeginTran) {
      final newLen = data.length > 1 ? data[1] : 0;
      if (newLen == 8 && data.length >= 10) {
        _buf.transactionDescriptor = data[2] |
            (data[3] << 8) |
            (data[4] << 16) |
            (data[5] << 24) |
            (data[6] << 32) |
            (data[7] << 40) |
            (data[8] << 48) |
            (data[9] << 56);
      }
      return (type, '', '');
    }
    if (type == envCommitTran || type == envRollbackTran) {
      _buf.transactionDescriptor = 0;
      return (type, '', '');
    }

    String readBVarChar() {
      final len = data[i++];
      final chars = <int>[];
      for (int j = 0; j < len; j++) {
        chars.add(data[i] | (data[i + 1] << 8));
        i += 2;
      }
      return String.fromCharCodes(chars);
    }

    final newVal = readBVarChar();
    final oldVal = readBVarChar();
    return (type, newVal, oldVal);
  }

  Future<(String, int)> _readError() async => _readInfoOrError();

  Future<void> _skipInfoOrError() async {
    await _readInfoOrError();
  }

  Future<(String, int)> _readInfoOrError() async {
    final length = await _buf.readUint16LE();
    final data = await _buf.readBytes(length);
    int i = 0;
    final number = data[i] |
        (data[i + 1] << 8) |
        (data[i + 2] << 16) |
        (data[i + 3] << 24);
    i += 4;
    i++; // state
    i++; // class
    final msgLen = data[i] | (data[i + 1] << 8);
    i += 2;
    final chars = <int>[];
    for (int j = 0; j < msgLen; j++) {
      chars.add(data[i] | (data[i + 1] << 8));
      i += 2;
    }
    final message = String.fromCharCodes(chars);
    return (message, number);
  }

  Future<void> _skipOrder() async {
    final length = await _buf.readUint16LE();
    await _buf.readBytes(length);
  }

  /// Reads a RETURNVALUE token (0xAC) — OUTPUT / return parameter.
  ///
  /// Layout matches go-mssqldb `parseReturnValue` / ms-tds §2.2.7.15:
  /// ParamOrdinal, ParamName, Status, UserType, Flags, TypeInfo, Value.
  Future<(String, Object?)> _readReturnValue() async {
    await _buf.readUint16LE(); // OrdinalNum
    final nameLen = await _buf.readUint8();
    var name = '';
    if (nameLen > 0) {
      final nameBytes = await _buf.readBytes(nameLen * 2);
      name = String.fromCharCodes([
        for (int j = 0; j < nameBytes.length; j += 2)
          nameBytes[j] | (nameBytes[j + 1] << 8)
      ]);
    }
    if (name.startsWith('@')) name = name.substring(1);
    await _buf.readUint8(); // Status
    await _buf.readUint32LE(); // UserType
    await _buf.readUint16LE(); // Flags
    final ti = await TypeInfo.read(_buf);
    final value = await ti.readValue(_buf);
    return (name, value);
  }

  Future<List<ColumnMeta>> _readColMetadata() async {
    final count = await _buf.readUint16LE();
    if (count == 0xFFFF) return [];

    final cols = <ColumnMeta>[];
    for (int i = 0; i < count; i++) {
      final userType = await _buf.readUint32LE();
      final flags = await _buf.readUint16LE();
      final ti = await TypeInfo.read(_buf);
      // TEXT/NTEXT/IMAGE columns carry a multi-part TableName in COLMETADATA (TDS 7.2+):
      // 1 byte numParts, then for each part: UINT16 char count + UTF-16LE chars.
      // Computed (CAST) columns send numParts = 0. ms-tds §2.2.7.4; confirmed by
      // tedious colmetadata-token-parser.js and go-mssqldb types.go.
      if (ti.typeId == typeText ||
          ti.typeId == typeNText ||
          ti.typeId == typeImage) {
        final numParts = await _buf.readUint8();
        for (int p = 0; p < numParts; p++) {
          final partLen = await _buf.readUint16LE();
          if (partLen > 0) await _buf.readBytes(partLen * 2);
        }
      }
      final nameLen = await _buf.readUint8();
      final nameBytes = await _buf.readBytes(nameLen * 2);
      final name = String.fromCharCodes(
        [
          for (int j = 0; j < nameBytes.length; j += 2)
            nameBytes[j] | (nameBytes[j + 1] << 8)
        ],
      );
      cols.add(ColumnMeta(
          name: name, typeInfo: ti, userType: userType, flags: flags));
    }
    return cols;
  }

  Future<List<Object?>> _readRow(List<ColumnMeta> cols) async {
    final row = <Object?>[];
    for (final col in cols) {
      row.add(await col.typeInfo.readValue(_buf));
    }
    return row;
  }

  Future<List<Object?>> _readNbcRow(List<ColumnMeta> cols) async {
    final bitmapBytes = (cols.length + 7) >> 3;
    final bitmap = await _buf.readBytes(bitmapBytes);

    bool isNull(int i) => (bitmap[i >> 3] & (1 << (i & 7))) != 0;

    final row = <Object?>[];
    for (int i = 0; i < cols.length; i++) {
      if (isNull(i)) {
        row.add(null);
      } else {
        row.add(await cols[i].typeInfo.readValue(_buf));
      }
    }
    return row;
  }
}
