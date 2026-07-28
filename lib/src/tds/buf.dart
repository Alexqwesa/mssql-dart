import 'dart:io';
import 'dart:typed_data';

import 'package:async/async.dart';

import '../protocol_limits.dart';
import 'constants.dart';

/// Protocol boundary of a TDS write. Only independent user requests may run a
/// synthetic TLS alignment request before their first packet.
enum TdsWriteContext {
  topLevelRequest,
  messageContinuation,
  login,
  sspi,
  bulkLoad,
  attention,
  transactionManager,
}

enum TlsAlignmentEventType {
  requested,
  sqlBatchSent,
  rpcSent,
  responseStarted,
  responseCompleted,
  failed
}

class TlsAlignmentEvent {
  final TlsAlignmentEventType type;
  final int position;
  final int? packetSize;

  const TlsAlignmentEvent(this.type, this.position, {this.packetSize});
}

/// Wraps a socket and provides TDS packet framing for reads and writes.
///
/// TDS packets have an 8-byte header:
///   [0]   packet type
///   [1]   status (`statusEOM` marks the final packet of a message)
///   [2-3] total packet size, big-endian, including the header
///   [4-5] server process ID; zero in client packets
///   [6]   packet sequence number, starting at 1 for each message
///   [7]   window; always zero
///
/// ## TLS plaintext-ring alignment workaround
///
/// This class contains a workaround for an implementation detail of the
/// current Dart VM `SecureSocket`.
///
/// The VM currently copies outgoing application plaintext into an 8 KiB
/// circular buffer. The buffer starts with both cursors at its midpoint,
/// offset 4096. When a write crosses the end of that ring, the VM processes
/// the tail and head as separate linear regions and passes them to TLS in
/// separate `SSL_write` calls.
///
/// Live SQL Server testing showed that when one TDS packet is divided between
/// those TLS writes, SQL Server closes the connection. This class therefore
/// attempts to ensure that each complete TDS packet fits inside one contiguous
/// region of the SecureSocket plaintext ring.
///
/// This behavior is not part of the public `dart:io` API. The constants and
/// cursor model below mirror the current Dart VM implementation and may need
/// review whenever the minimum supported Dart SDK changes.
///
/// ### Mirrored cursor
///
/// [_tlsWritePos] mirrors the end cursor of SecureSocket's outgoing plaintext
/// ring:
///
/// - it is initialized to [tlsPlainBufferStart] after the TLS upgrade;
/// - TLS handshake bytes do not advance this application-plaintext cursor;
/// - after writing a TDS packet, its complete packet length is added modulo
///   [tlsPlainBufferSize];
/// - when the cursor is zero, one byte remains reserved by the circular-buffer
///   implementation, so [tlsLinearFree] returns 8191 rather than 8192.
///
/// This mirror is valid only while all of the following invariants hold:
///
/// 1. Every post-handshake plaintext write goes through this [TdsBuffer].
/// 2. TDS packet writes are serialized; no two writes run concurrently.
/// 3. `await _socket.flush()` drains the plaintext supplied by the preceding
///    write before the mirrored cursor is updated.
/// 4. No library or caller writes directly to the underlying [SecureSocket].
/// 5. Dart retains the mirrored ring size, initial position, and processing
///    behavior.
///
/// If any invariant is broken, [_tlsWritePos] can diverge from SecureSocket's
/// real cursor. Alignment based on a stale cursor can split a packet rather
/// than prevent a split, so the affected connection must be treated as dead.
///
/// ### Packet alignment
///
/// Before writing a packet, [_ensureTlsLinearRoom] checks whether its complete
/// TDS packet length fits in the current contiguous ring region.
///
/// If it fits, the packet is written normally. The method may still align
/// first when writing the packet would leave a tail that cannot later hold a
/// complete alignment request.
///
/// If it does not fit, the implementation sends a separate, complete TDS
/// request whose encoded packet length exactly consumes the remaining ring
/// tail. After its response has been consumed, the mirrored cursor is at zero
/// and the original packet can be written at the start of the ring.
///
/// Even alignment lengths use a SQLBatch request. SQLBatch text is UTF-16LE,
/// so its packet length has even parity. Odd alignment lengths use a specially
/// encoded RPC request with a one-byte `varchar` value to produce an odd wire
/// length.
///
/// Alignment requests are real SQL Server requests, not TLS padding and not
/// continuation packets. They add a network round trip and can affect
/// observable session state such as `@@ROWCOUNT`, server auditing, statistics,
/// transaction diagnostics, and error handling.
///
/// ### TDS restrictions
///
/// Normal multi-packet TDS messages retain standard packetization:
///
/// - every non-final packet uses the negotiated [packetSize];
/// - only the final `statusEOM` packet may be shorter;
/// - an alignment request is always a separate `statusEOM` message;
/// - empty or short non-final packets must never be used as filler.
///
/// An alignment request may be inserted only while SQL Server is ready to
/// accept a new independent request. It must never be inserted:
///
/// - during PRELOGIN, LOGIN7, or an SSPI authentication continuation;
/// - between `INSERT BULK` setup and its Bulk Load payload;
/// - before or instead of an Attention packet for an active command;
/// - between packets belonging to the same TDS message;
/// - while another request or response is active without MARS.
///
/// The exact alignment packet must also fit within the negotiated [packetSize].
/// If the ring tail cannot be consumed by one valid independent request, the
/// driver must fail and close the connection rather than emit invalid TDS.
///
/// ### Response handling
///
/// The alignment response must be completely consumed before the caller's
/// request is sent. It should be processed through the normal token parser so
/// SQL Server ERROR, INFO, ENVCHANGE, DONE, transaction, and connection-state
/// tokens are handled consistently. Blindly discarding response bytes can hide
/// a failed alignment request and leave local session state stale.
///
/// ### Scope
///
/// This mechanism is a Dart-VM compatibility workaround, not a general TDS or
/// TLS requirement and not a replacement for record-oriented TLS control.
/// A TLS implementation that accepts one complete TDS packet in one controlled
/// encryption operation would remove the need for mirrored ring tracking and
/// synthetic alignment requests.
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

  /// Mirrored end cursor of SecureSocket's outgoing plaintext circular buffer.
  ///
  /// Non-null only while [_socket] is a [SecureSocket]. The value is initialized
  /// to [tlsPlainBufferStart] after the handshake and advanced by every complete
  /// plaintext TDS packet written through this class.
  ///
  /// This is not obtained from `dart:io`; it is inferred from the current Dart VM
  /// implementation. It remains valid only when writes are serialized, every TLS
  /// plaintext write passes through this buffer, and each awaited flush fully
  /// drains the preceding plaintext.
  int? _tlsWritePos;

  /// True after LOGINACK — wrap-alignment no-ops are safe only then.
  bool _tlsNopAlignEnabled = false;

  /// Test-only observation hook for synthetic TLS alignment traffic.
  void Function(TlsAlignmentEvent event)? onTlsAlignment;

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

  /// Enables the TLS cursor model without requiring a platform [SecureSocket].
  void enableTlsAlignmentForTesting(
      {int initialPosition = tlsPlainBufferStart}) {
    setTlsWritePositionForTesting(initialPosition);
    _tlsNopAlignEnabled = true;
  }

  /// Sets the mirrored TLS plaintext cursor for deterministic unit tests.
  void setTlsWritePositionForTesting(int position) {
    RangeError.checkValueInInterval(
      position,
      0,
      tlsPlainBufferSize - 1,
      'position',
    );
    _tlsWritePos = position;
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
  Future<void> finishPacket(
    int packetType, {
    TdsWriteContext? context,
  }) async {
    final payload = _wbuf.toBytes();
    // Body = everything after the 8-byte header placeholder.
    final body = payload.sublist(headerSize);

    // RESETCONNECTION only on first packet of Batch / RPC / TM request.
    final applyReset = resetConnectionPending &&
        (packetType == packSQLBatch ||
            packetType == packRPCRequest ||
            packetType == packTransMgrReq);
    final maxBody = packetSize - headerSize;
    final packetSizes = <int>[];
    for (var remaining = body.length;;) {
      final chunkLen = remaining <= maxBody ? remaining : maxBody;
      packetSizes.add(headerSize + chunkLen);
      if (remaining <= maxBody) break;
      remaining -= chunkLen;
    }
    await _prepareTlsMessage(
      packetSizes,
      context ?? _contextForPacket(packetType),
    );

    int offset = 0;
    int seq = 1;
    while (true) {
      final remaining = body.length - offset;
      final isLast = remaining <= maxBody;
      final chunkLen = isLast ? remaining : maxBody;
      final totalSize = headerSize + chunkLen;

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

      _socket.add(pkt);
      await _socket.flush();
      if (applyReset && seq == 1) {
        resetConnectionPending = false;
        transactionDescriptor = 0;
      }
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

  static TdsWriteContext _contextForPacket(int packetType) {
    switch (packetType) {
      case packSQLBatch:
      case packRPCRequest:
        return TdsWriteContext.topLevelRequest;
      case packBulkLoadBCP:
        return TdsWriteContext.bulkLoad;
      case packAttention:
        return TdsWriteContext.attention;
      case packLogin7:
      case packPrelogin:
        return TdsWriteContext.login;
      case packSSPIMessage:
        return TdsWriteContext.sspi;
      case packTransMgrReq:
        return TdsWriteContext.transactionManager;
      default:
        return TdsWriteContext.messageContinuation;
    }
  }

  Future<void> _prepareTlsMessage(
    List<int> packetSizes,
    TdsWriteContext context,
  ) async {
    final pos = _tlsWritePos;
    if (pos == null) return;
    if (_packetsFitFrom(pos, packetSizes)) {
      final after = _positionAfter(pos, packetSizes);
      if (!_hasUnalignableTail(after)) return;
      if (!_tlsNopAlignEnabled || context != TdsWriteContext.topLevelRequest) {
        throw StateError(
          'TLS packet alignment is unsafe for $context; no bytes were written.',
        );
      }
      try {
        await _tlsNopFillToWrap();
        if (_packetsFitFrom(_tlsWritePos!, packetSizes)) return;
        throw StateError('TDS message cannot fit TLS plaintext boundaries.');
      } catch (_) {
        onTlsAlignment?.call(
          TlsAlignmentEvent(TlsAlignmentEventType.failed, pos),
        );
        rethrow;
      }
    }
    if (!_tlsNopAlignEnabled || context != TdsWriteContext.topLevelRequest) {
      throw StateError(
        'TLS packet alignment is unsafe for $context; no bytes were written.',
      );
    }
    try {
      await _tlsNopFillToWrap();
      if (!_packetsFitFrom(_tlsWritePos!, packetSizes)) {
        throw StateError('TDS message cannot fit TLS plaintext boundaries.');
      }
    } catch (_) {
      onTlsAlignment
          ?.call(TlsAlignmentEvent(TlsAlignmentEventType.failed, pos));
      rethrow;
    }
  }

  bool _packetsFitFrom(int start, List<int> packetSizes) {
    var pos = start;
    for (final size in packetSizes) {
      if (size > tlsLinearFree(pos)) return false;
      pos = (pos + size) % tlsPlainBufferSize;
    }
    return true;
  }

  int _positionAfter(int start, List<int> packetSizes) {
    var pos = start;
    for (final size in packetSizes) {
      pos = (pos + size) % tlsPlainBufferSize;
    }
    return pos;
  }

  bool _hasUnalignableTail(int position) {
    if (position == 0) return false;
    final tail = tlsLinearFree(position);
    return tail < _tlsMinNopPacket || (tail.isOdd && tail < _tlsMinOddRpcNop);
  }

  /// Ensures that a complete TDS packet of [needed] bytes can be supplied to the
  /// current SecureSocket plaintext ring without crossing its physical wrap.
  ///
  /// When necessary, this may send and consume an additional independent
  /// alignment request before the caller's packet. It must therefore be invoked
  /// only at a protocol boundary where SQL Server is ready for a new request.
  ///
  /// This method must not align by sending another request while handling LOGIN7,
  /// SSPI, Bulk Load continuation, Attention, or another active request.
  ///
  /// Throws rather than writing when alignment cannot be represented as a valid
  /// TDS request within the negotiated [packetSize]. A failure here makes the
  /// mirrored TLS cursor unreliable, so the connection should be closed.
  // ignore: unused_element
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

  /// Sends one independent request whose complete TDS packet consumes exactly
  /// the remaining contiguous SecureSocket plaintext-ring tail.
  ///
  /// Despite the historical "nop" name, this is not padding. SQL Server executes
  /// and responds to the request. Even lengths are represented by SQLBatch;
  /// odd lengths require an RPC request because UTF-16LE SQLBatch bodies cannot
  /// change packet parity.
  ///
  /// Preconditions:
  /// - login has completed;
  /// - no request is currently active;
  /// - SQL Server is ready for a new request;
  /// - the exact tail length is a valid packet size not exceeding [packetSize].
  ///
  /// The response must be fully token-parsed before another request is written.
  /// Any alignment error or unexpected response should poison the connection.
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
    onTlsAlignment?.call(TlsAlignmentEvent(
      TlsAlignmentEventType.requested,
      pos,
      packetSize: linear,
    ));
    onTlsAlignment?.call(TlsAlignmentEvent(
      pkt[0] == packSQLBatch
          ? TlsAlignmentEventType.sqlBatchSent
          : TlsAlignmentEventType.rpcSent,
      pos,
      packetSize: linear,
    ));
    _socket.add(pkt);
    await _socket.flush();
    _tlsWritePos = 0;
    // The alignment request is a real SQL Server request. Its complete response
    // must be consumed before the caller's request is sent.
    //
    // TODO: process this through TokenStream rather than discarding the raw TDS
    // message. readAll() preserves byte synchronization, but it hides ERROR/INFO
    // tokens and does not apply ENVCHANGE or transaction-state updates.
    onTlsAlignment
        ?.call(TlsAlignmentEvent(TlsAlignmentEventType.responseStarted, 0));
    await beginRead();
    await readAll();
    onTlsAlignment
        ?.call(TlsAlignmentEvent(TlsAlignmentEventType.responseCompleted, 0));
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
