import 'dart:io';
import 'dart:typed_data';

import 'package:async/async.dart';

import 'constants.dart';
import '../protocol_limits.dart';

/// Wraps a [Socket] and provides TDS packet framing for reads and writes.
///
/// TDS packets have an 8-byte header:
///   [0]   packet type
///   [1]   status (0x01 = last packet in message)
///   [2-3] total packet size (big-endian, including header)
///   [4-5] server process ID (SPID) – zero from client
///   [6]   packet sequence number (1-based, resets per message)
///   [7]   window (always 0)
///
/// ## TLS / SecureSocket plaintext ring
///
/// `dart:io` SecureSocket copies application writes into an 8 KiB circular
/// plaintext buffer that starts at offset 4 KiB. Each linear region is fed to
/// a separate `SSL_write`, so a single [Socket.add] that straddles the wrap
/// becomes **two TLS application-data records**. SQL Server's TDS-over-TLS
/// path expects each TDS packet to arrive in one TLS record; a split packet
/// closes the connection.
///
/// When talking through a [SecureSocket] we therefore:
/// - never emit short non-final TDS packets (TDS 7.3+ requires full
///   [packetSize] for non-EOM packets after login);
/// - if the next packet would not fit in the current linear region, send a
///   complete no-op SQLBatch that ends exactly on the wrap, drain its
///   response, then continue (see [_ensureTlsLinearRoom]).
class TdsBuffer {
  /// Matches `_ExternalBuffer.SIZE` in `dart:io` SecureSocket.
  static const int tlsPlainBufferSize = 8 * 1024;

  /// Matches `_ExternalBuffer` initial `start` / `end` (`size ~/ 2`).
  static const int tlsPlainBufferStart = tlsPlainBufferSize ~/ 2;

  /// ALL_HEADERS (ms-tds §2.2.5.3) length as written by [RpcRequest].
  static const int _allHeadersLen = 22;

  /// Smallest no-op SQLBatch (header + ALL_HEADERS only; SQL may be empty/spaces).
  static const int _tlsMinNopPacket = headerSize + _allHeadersLen;

  /// Smallest odd-length RPC alignment nop we can currently synthesize.
  static const int _tlsMinOddRpcNop = 139;

  Socket _socket;
  int packetSize;
  final MssqlProtocolLimits limits;

  // Single subscription to the socket stream – do not call _socket.listen again.
  ChunkedStreamReader<int> _reader;

  // Write state
  final _wbuf = BytesBuilder(copy: false);

  /// Set by [sendAttention]; cleared when a DONE with [doneFlagAttn] is parsed.
  /// While true, response readers keep draining messages until the Attention ACK.
  bool attentionSent = false;

  // Read state – filled one TDS packet at a time
  Uint8List _rbuf = Uint8List(0);
  int _rpos = 0;
  bool _rFinal = false;
  int _rPacketType = 0;

  /// Current transaction descriptor from server ENVCHANGE type 8.
  /// Sent in ALL_HEADERS; 0 = autocommit (no active transaction).
  int transactionDescriptor = 0;

  /// When true, the next SQLBatch / RPC / TransMgr request sets TDS
  /// [statusResetConn] (0x08) on its first packet (ms-tds / go-mssqldb
  /// `ResetSession`). Cleared after that packet is written.
  bool resetConnectionPending = false;

  /// Mirrored write offset in SecureSocket's plaintext ring; null when cleartext.
  int? _tlsWritePos;

  /// True after LOGINACK — wrap-alignment no-ops are safe only then.
  bool _tlsNopAlignEnabled = false;

  TdsBuffer(
    Socket socket, {
    this.packetSize = defaultPacketSize,
    this.limits = const MssqlProtocolLimits(),
  })  : _socket = socket,
        _reader = ChunkedStreamReader(socket);

  /// The current stream reader. Used by the TLS bridge to keep a stable
  /// reference to the raw TCP reader before [replaceSocket] swaps it out.
  ChunkedStreamReader<int> get rawReader => _reader;

  /// Replace the underlying socket (called after TLS upgrade).
  void replaceSocket(Socket newSocket) {
    _socket = newSocket;
    _reader = ChunkedStreamReader(newSocket);
    // Handshake bytes do not advance the SecureSocket plaintext ring; the
    // first application write still starts at the initial midpoint.
    _tlsWritePos = newSocket is SecureSocket ? tlsPlainBufferStart : null;
    _tlsNopAlignEnabled = false;
  }

  /// Enables TLS wrap-alignment no-ops after a successful login.
  void enableTlsNopAlign() {
    if (_tlsWritePos != null) _tlsNopAlignEnabled = true;
  }

  // ── Write API ──────────────────────────────────────────────────────────────

  void beginPacket(int type) {
    _wbuf.clear();
    // Reserve 8-byte header placeholder; filled in finishPacket.
    _wbuf.add(Uint8List(headerSize));
  }

  void writeByte(int b) => _wbuf.addByte(b & 0xFF);

  void writeBytes(List<int> bytes) => _wbuf.add(bytes);

  void writeUint8(int v) => _wbuf.addByte(v & 0xFF);

  void writeUint16LE(int v) {
    _wbuf.addByte(v & 0xFF);
    _wbuf.addByte((v >> 8) & 0xFF);
  }

  void writeUint16BE(int v) {
    _wbuf.addByte((v >> 8) & 0xFF);
    _wbuf.addByte(v & 0xFF);
  }

  void writeUint32LE(int v) {
    _wbuf.addByte(v & 0xFF);
    _wbuf.addByte((v >> 8) & 0xFF);
    _wbuf.addByte((v >> 16) & 0xFF);
    _wbuf.addByte((v >> 24) & 0xFF);
  }

  void writeUint32BE(int v) {
    _wbuf.addByte((v >> 24) & 0xFF);
    _wbuf.addByte((v >> 16) & 0xFF);
    _wbuf.addByte((v >> 8) & 0xFF);
    _wbuf.addByte(v & 0xFF);
  }

  void writeUint64LE(int v) {
    writeUint32LE(v & 0xFFFFFFFF);
    writeUint32LE((v >> 32) & 0xFFFFFFFF);
  }

  void writeInt16LE(int v) => writeUint16LE(v & 0xFFFF);
  void writeInt32LE(int v) => writeUint32LE(v & 0xFFFFFFFF);

  /// Flush the accumulated write buffer as one or more TDS packets.
  Future<void> finishPacket(int packetType) async {
    final payload = _wbuf.toBytes();
    // Body = everything after the 8-byte header placeholder.
    final body = payload.sublist(headerSize);

    // RESETCONNECTION only on first packet of Batch / RPC / TM request.
    final applyReset = resetConnectionPending &&
        (packetType == packSQLBatch ||
            packetType == packRPCRequest ||
            packetType == packTransMgrReq);
    if (applyReset) {
      resetConnectionPending = false;
      // Server will clear session state; drop local txn descriptor too.
      transactionDescriptor = 0;
    }

    final maxBody = packetSize - headerSize;
    int offset = 0;
    int seq = 1;
    while (true) {
      final remaining = body.length - offset;
      final isLast = remaining <= maxBody;
      // Non-final packets must be full negotiated size (TDS 7.3+).
      final chunkLen = isLast ? remaining : maxBody;
      var totalSize = headerSize + chunkLen;

      final pkt = Uint8List(totalSize);
      pkt[0] = packetType;
      var status = isLast ? statusEOM : statusNormal;
      // ms-tds: RESETCONNECTION must be on the first packet of the message.
      if (applyReset && seq == 1) {
        status |= statusResetConn;
      }
      pkt[1] = status;
      pkt[2] = (totalSize >> 8) & 0xFF;
      pkt[3] = totalSize & 0xFF;
      pkt[4] = 0; // SPID hi
      pkt[5] = 0; // SPID lo
      pkt[6] = seq & 0xFF;
      pkt[7] = 0; // window

      if (chunkLen > 0) {
        pkt.setRange(headerSize, totalSize, body, offset);
      }

      await _ensureTlsLinearRoom(totalSize);

      _socket.add(pkt);
      await _socket.flush();
      final pos = _tlsWritePos;
      if (pos != null) {
        _tlsWritePos = (pos + totalSize) % tlsPlainBufferSize;
      }

      offset += chunkLen;
      seq++;
      if (isLast) break;
    }
    _wbuf.clear();
  }

  /// Matches `_ExternalBuffer.linearFree` when the plaintext ring is empty at
  /// [pos] (`start == end == pos`).
  static int tlsLinearFree(int pos) {
    if (pos == 0) return tlsPlainBufferSize - 1;
    return tlsPlainBufferSize - pos;
  }

  /// Ensures the next [needed] plaintext bytes fit in one SecureSocket linear
  /// region (so one [Socket.add] → one `SSL_write` → one TLS record).
  Future<void> _ensureTlsLinearRoom(int needed) async {
    final pos = _tlsWritePos;
    if (pos == null) return;

    var linear = tlsLinearFree(pos);
    if (needed <= linear) {
      final leftover = linear - needed;
      // Don't leave a tail that cannot host a valid wrap-fill packet.
      // Odd tails need an RPC nop (SQLBatch UCS-2 bodies are always even).
      final badTail = leftover > 0 &&
          (leftover < _tlsMinNopPacket ||
              (leftover.isOdd && leftover < _tlsMinOddRpcNop));
      if (badTail && _tlsNopAlignEnabled) {
        await _tlsNopFillToWrap();
      }
      return;
    }

    if (!_tlsNopAlignEnabled) {
      throw StateError(
        'SecureSocket plaintext buffer would split a TDS packet '
        '(need $needed bytes, $linear free before wrap).',
      );
    }

    // Fill exactly to the wrap with a complete EOM SQLBatch, drain, repeat
    // until the real packet fits (normally once → position 0 with 8 KiB free).
    while (needed > tlsLinearFree(_tlsWritePos!)) {
      await _tlsNopFillToWrap();
    }
  }

  Future<void> _tlsNopFillToWrap() async {
    final pos = _tlsWritePos!;
    if (pos == 0) return;
    final linear = tlsLinearFree(pos);
    if (linear < _tlsMinNopPacket) {
      throw StateError(
        'TLS plaintext tail ($linear bytes) is too small for an alignment '
        'SQLBatch (need ≥ $_tlsMinNopPacket).',
      );
    }
    final pkt = buildTlsAlignNopPacket(
      totalSize: linear,
      transactionDescriptor: transactionDescriptor,
    );
    _socket.add(pkt);
    await _socket.flush();
    _tlsWritePos = 0;
    // Discard the no-op response so the caller’s next read sees their reply.
    await beginRead();
    await readAll();
  }

  /// Builds a no-op packet of exactly [totalSize] bytes (EOM) for TLS wrap
  /// alignment. Even sizes use SQLBatch; odd sizes use a tiny RPC (SQLBatch
  /// bodies are UCS-2 and must be even, so odd SQLBatch lengths are invalid).
  static Uint8List buildTlsAlignNopPacket({
    required int totalSize,
    int transactionDescriptor = 0,
  }) {
    if (totalSize < _tlsMinNopPacket || totalSize > 0xFFFF) {
      throw ArgumentError.value(totalSize, 'totalSize');
    }
    if (totalSize.isOdd) {
      return _buildTlsAlignRpcNop(
        totalSize: totalSize,
        transactionDescriptor: transactionDescriptor,
      );
    }
    return _buildTlsAlignSqlNop(
      totalSize: totalSize,
      transactionDescriptor: transactionDescriptor,
    );
  }

  static void _writeAllHeadersBytes(BytesBuilder b, int transactionDescriptor) {
    const headerDataLen = 18;
    const totalLen = 4 + headerDataLen;
    final bd = ByteData(4 + headerDataLen);
    var o = 0;
    bd.setUint32(o, totalLen, Endian.little);
    o += 4;
    bd.setUint32(o, headerDataLen, Endian.little);
    o += 4;
    bd.setUint16(o, 0x0002, Endian.little);
    o += 2;
    bd.setUint64(o, transactionDescriptor, Endian.little);
    o += 8;
    bd.setUint32(o, 1, Endian.little);
    b.add(bd.buffer.asUint8List());
  }

  static Uint8List _buildTlsAlignSqlNop({
    required int totalSize,
    required int transactionDescriptor,
  }) {
    final pkt = Uint8List(totalSize);
    pkt[0] = packSQLBatch;
    pkt[1] = statusEOM;
    pkt[2] = (totalSize >> 8) & 0xFF;
    pkt[3] = totalSize & 0xFF;
    pkt[6] = 1;

    var o = headerSize;
    const headerDataLen = 18;
    const totalLen = 4 + headerDataLen;
    ByteData.sublistView(pkt).setUint32(o, totalLen, Endian.little);
    o += 4;
    ByteData.sublistView(pkt).setUint32(o, headerDataLen, Endian.little);
    o += 4;
    ByteData.sublistView(pkt).setUint16(o, 0x0002, Endian.little);
    o += 2;
    ByteData.sublistView(pkt)
        .setUint64(o, transactionDescriptor, Endian.little);
    o += 8;
    ByteData.sublistView(pkt).setUint32(o, 1, Endian.little);
    o += 4;

    const sql = 'SELECT 1 WHERE 0=1';
    if (totalSize >= headerSize + _allHeadersLen + sql.length * 2) {
      for (var i = 0; i < sql.length && o + 1 < totalSize; i++) {
        pkt[o++] = sql.codeUnitAt(i) & 0xFF;
        pkt[o++] = 0;
      }
    }
    while (o + 1 < totalSize) {
      pkt[o++] = 0x20;
      pkt[o++] = 0x00;
    }
    return pkt;
  }

  /// Odd-length wrap fill: sp_executesql N'SELECT 1 WHERE 0=1' with optional
  /// 1-byte varchar padding param so the wire size can be odd (UCS-2 SQL alone
  /// always yields an even body).
  static Uint8List _buildTlsAlignRpcNop({
    required int totalSize,
    required int transactionDescriptor,
  }) {
    const sqlCore = 'SELECT 1 WHERE 0=1';
    for (final withPad in [false, true]) {
      for (var spaces = 0; spaces < 4000; spaces++) {
        final sql = sqlCore + (' ' * spaces);
        final body = BytesBuilder(copy: false);
        _writeAllHeadersBytes(body, transactionDescriptor);
        body.addByte(0xFF);
        body.addByte(0xFF);
        body.addByte(10); // sp_executesql
        body.addByte(0);
        body.addByte(0); // OptionFlags
        body.addByte(0);
        // @statement
        body.addByte(0); // name length
        body.addByte(0); // status
        final sqlBytes = Uint8List(sql.length * 2);
        for (var i = 0; i < sql.length; i++) {
          sqlBytes[i * 2] = sql.codeUnitAt(i) & 0xFF;
        }
        body.addByte(typeNVarChar);
        body.addByte(0x40); // max 8000 LE
        body.addByte(0x1F);
        body.add([0x09, 0x04, 0xD0, 0x00, 0x34]);
        body.addByte(sqlBytes.length & 0xFF);
        body.addByte((sqlBytes.length >> 8) & 0xFF);
        body.add(sqlBytes);

        if (withPad) {
          // Param declarations + 1-byte varchar to flip parity.
          const decl = '@p varchar(1)';
          final declBytes = Uint8List(decl.length * 2);
          for (var i = 0; i < decl.length; i++) {
            declBytes[i * 2] = decl.codeUnitAt(i) & 0xFF;
          }
          body.addByte(0); // name length
          body.addByte(0); // status
          body.addByte(typeNVarChar);
          body.addByte(0x40);
          body.addByte(0x1F);
          body.add([0x09, 0x04, 0xD0, 0x00, 0x34]);
          body.addByte(declBytes.length & 0xFF);
          body.addByte((declBytes.length >> 8) & 0xFF);
          body.add(declBytes);

          // @p value
          final pname = Uint8List.fromList([0x40, 0x00, 0x70, 0x00]); // @p
          body.addByte(2); // name char count
          body.add(pname);
          body.addByte(0); // status
          body.addByte(0xA7); // typeBigVarChar
          body.addByte(1);
          body.addByte(0); // maxlen
          body.add([0x09, 0x04, 0xD0, 0x00, 0x34]);
          body.addByte(1);
          body.addByte(0); // actual len
          body.addByte(0x20); // ' '
        }

        final bodyBytes = body.toBytes();
        final withHeader = headerSize + bodyBytes.length;
        if (withHeader == totalSize) {
          final pkt = Uint8List(totalSize);
          pkt[0] = packRPCRequest;
          pkt[1] = statusEOM;
          pkt[2] = (totalSize >> 8) & 0xFF;
          pkt[3] = totalSize & 0xFF;
          pkt[6] = 1;
          pkt.setRange(headerSize, totalSize, bodyBytes);
          return pkt;
        }
        if (withHeader > totalSize && spaces > 10) break;
      }
    }
    throw StateError(
      'Cannot build odd TLS alignment RPC nop of size $totalSize',
    );
  }

  /// Sends a TDS Attention packet (ms-tds §2.2.1.7) — empty body, type 6.
  ///
  /// Safe to call while a read is in progress (write path is independent).
  /// The server acknowledges with DONE where [doneFlagAttn] is set.
  Future<void> sendAttention() async {
    attentionSent = true;
    beginPacket(packAttention);
    await finishPacket(packAttention);
  }

  // ── Read API ───────────────────────────────────────────────────────────────

  /// Read the next TDS packet off the wire and fill [_rbuf].
  Future<void> _readNextPacket() async {
    final hdr = await _reader.readChunk(headerSize);
    if (hdr.length < headerSize) {
      throw StateError('Connection closed mid-header');
    }

    _rPacketType = hdr[0];
    final status = hdr[1];
    final size = (hdr[2] << 8) | hdr[3];
    _rFinal = (status & statusEOM) != 0;

    if (size < headerSize) {
      throw FormatException(
        'TDS packet size $size is smaller than header size $headerSize',
      );
    }
    final bodyLen = size - headerSize;
    final newBody = bodyLen > 0
        ? Uint8List.fromList(await _reader.readChunk(bodyLen))
        : Uint8List(0);
    if (newBody.length < bodyLen) {
      throw StateError('Connection closed mid-packet body');
    }

    // Preserve unread bytes when a multi-byte read straddles a packet
    // boundary (go-mssqldb / PR #3). Without this, leftover bytes in
    // `_rbuf` are discarded and length prefixes / tokens desync.
    final remaining = _rbuf.length - _rpos;
    if (remaining > 0) {
      final merged = Uint8List(remaining + newBody.length);
      merged.setRange(0, remaining, _rbuf, _rpos);
      merged.setRange(remaining, remaining + newBody.length, newBody);
      _rbuf = merged;
    } else {
      _rbuf = newBody;
    }
    _rpos = 0;
  }

  /// Begin reading a new server message; returns the packet type of the first packet.
  Future<int> beginRead() async {
    await _readNextPacket();
    return _rPacketType;
  }

  Future<int> readUint8() async {
    await _ensureBytes(1);
    return _rbuf[_rpos++];
  }

  Future<int> readUint16LE() async {
    await _ensureBytes(2);
    final v = _rbuf[_rpos] | (_rbuf[_rpos + 1] << 8);
    _rpos += 2;
    return v;
  }

  Future<int> readUint16BE() async {
    await _ensureBytes(2);
    final v = (_rbuf[_rpos] << 8) | _rbuf[_rpos + 1];
    _rpos += 2;
    return v;
  }

  Future<int> readUint32LE() async {
    await _ensureBytes(4);
    final v = _rbuf[_rpos] |
        (_rbuf[_rpos + 1] << 8) |
        (_rbuf[_rpos + 2] << 16) |
        (_rbuf[_rpos + 3] << 24);
    _rpos += 4;
    return v;
  }

  Future<int> readUint32BE() async {
    await _ensureBytes(4);
    final v = (_rbuf[_rpos] << 24) |
        (_rbuf[_rpos + 1] << 16) |
        (_rbuf[_rpos + 2] << 8) |
        _rbuf[_rpos + 3];
    _rpos += 4;
    return v;
  }

  Future<int> readUint64LE() async {
    final lo = await readUint32LE();
    final hi = await readUint32LE();
    return lo | (hi << 32);
  }

  Future<int> readInt32LE() async {
    final v = await readUint32LE();
    return v >= 0x80000000 ? v - 0x100000000 : v;
  }

  Future<Uint8List> readBytes(int n) async {
    if (n < 0) throw FormatException('TDS read length is negative: $n');
    final out = Uint8List(n);
    int written = 0;
    while (written < n) {
      await _ensureBytes(1);
      final available = _rbuf.length - _rpos;
      final take = available < (n - written) ? available : (n - written);
      out.setRange(written, written + take, _rbuf, _rpos);
      _rpos += take;
      written += take;
    }
    return out;
  }

  /// Read all remaining bytes in the current server message (across packets).
  Future<Uint8List> readAll() async {
    final parts = <Uint8List>[];
    while (true) {
      final remaining = _rbuf.length - _rpos;
      if (remaining > 0) parts.add(Uint8List.sublistView(_rbuf, _rpos));
      _rpos = _rbuf.length;
      if (_rFinal) break;
      await _readNextPacket();
    }
    if (parts.isEmpty) return Uint8List(0);
    if (parts.length == 1) {
      limits.checkTokenBytes(parts[0].length, 'TDS message');
      return parts[0];
    }
    final total = parts.fold<int>(0, (s, p) => s + p.length);
    limits.checkTokenBytes(total, 'TDS message');
    final out = Uint8List(total);
    int offset = 0;
    for (final p in parts) {
      out.setRange(offset, offset + p.length, p);
      offset += p.length;
    }
    return out;
  }

  /// Reads exactly [n] raw bytes directly from the underlying stream,
  /// bypassing TDS packet framing. Used only during the TLS handshake bridge.
  /// Returns null if the stream closes.
  Future<Uint8List?> readBytesRaw(int n) async {
    try {
      final chunk = await _reader.readChunk(n);
      if (chunk.length < n) return null;
      return Uint8List.fromList(chunk);
    } catch (_) {
      return null;
    }
  }

  Future<void> _ensureBytes(int n) async {
    while (_rbuf.length - _rpos < n) {
      if (_rFinal) throw StateError('TDS stream ended unexpectedly');
      await _readNextPacket();
    }
  }
}
