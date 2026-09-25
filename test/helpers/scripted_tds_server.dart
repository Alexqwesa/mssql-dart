import 'dart:async';
import 'dart:io';
import 'dart:typed_data';

import 'package:async/async.dart';
import 'package:mssql/src/tds/constants.dart';

import 'tds_socket.dart';

/// Where a scripted server fails the session after, or instead of, a reply.
enum ScriptedFault {
  none,
  loginDrop,
  loginStall,
  afterFirstRowDrop,
  afterFirstRowStall,
  bulkDrop,
  bulkStall,
  attentionDrop,
  attentionStall,
  commitDrop,
  commitStall,
}

/// Local TDS peer that completes a cleartext login, then drops or stalls.
///
/// Used by offline fault injection. It is not a SQL Server: SQL batches other
/// than the faulted one are answered with an empty DONE token.
class ScriptedTdsServer {
  ScriptedTdsServer._(this.listener, this.fault, this.replyBuilder);

  final ServerSocket listener;
  final ScriptedFault fault;

  /// Builds the reply to every post-login SQL batch, replacing the empty DONE.
  ///
  /// Used by connection-level fuzzing to feed hostile bytes through the whole
  /// driver rather than through [TokenStream] alone.
  final List<int> Function(int callIndex)? replyBuilder;

  int _replies = 0;

  final List<String> sqlTexts = <String>[];
  final List<Socket> _sockets = <Socket>[];
  int commitPackets = 0;
  int attentionPackets = 0;
  int bulkPackets = 0;

  int get port => listener.port;

  late final Future<void> _session = _serve();

  static Future<ScriptedTdsServer> bind(
    ScriptedFault fault, {
    List<int> Function(int callIndex)? replyBuilder,
  }) async {
    final listener = await ServerSocket.bind(InternetAddress.loopbackIPv4, 0);
    final server = ScriptedTdsServer._(listener, fault, replyBuilder);
    unawaited(server._session);
    return server;
  }

  Future<void> close() async {
    for (final socket in _sockets) {
      try {
        socket.destroy();
      } catch (_) {}
    }
    try {
      await listener.close();
    } catch (_) {}
    try {
      await _session.timeout(const Duration(seconds: 2));
    } catch (_) {}
  }

  Future<void> _serve() async {
    Socket? client;
    try {
      client = await listener.first;
      _sockets.add(client);
      if (fault == ScriptedFault.loginDrop) {
        client.destroy();
        return;
      }
      final reader = ChunkedStreamReader<int>(client);
      final prelogin = await _readPacket(reader);
      if (prelogin == null) return;
      if (fault == ScriptedFault.loginStall) return;
      client.add(tdsPacket(type: packReply, body: _preloginReply()));
      await client.flush();

      final login = await _readPacket(reader);
      if (login == null || login.type != packLogin7) return;
      client.add(tdsPacket(
        type: packReply,
        body: _loginAckDone(database: 'master'),
      ));
      await client.flush();

      while (true) {
        final packet = await _readPacket(reader);
        if (packet == null) return;
        if (packet.type == packAttention) attentionPackets++;
        if (packet.type == packBulkLoadBCP) bulkPackets++;
        final sql = _sqlText(packet);
        if (sql != null) {
          sqlTexts.add(sql);
          if (sql.toUpperCase().contains('COMMIT TRANSACTION')) {
            commitPackets++;
          }
        }
        if (_faultOn(packet, sql)) {
          if (_drops) client.destroy();
          return;
        }
        if (fault == ScriptedFault.attentionDrop ||
            fault == ScriptedFault.attentionStall) {
          if (packet.type == packAttention) {
            if (fault == ScriptedFault.attentionDrop) client.destroy();
            return;
          }
          continue;
        }
        if (fault == ScriptedFault.afterFirstRowDrop ||
            fault == ScriptedFault.afterFirstRowStall) {
          client.add(tdsPacket(
            type: packReply,
            body: _oneIntRow(),
            eom: fault == ScriptedFault.afterFirstRowDrop,
          ));
          await client.flush();
          if (fault == ScriptedFault.afterFirstRowDrop) client.destroy();
          return;
        }
        final builder = replyBuilder;
        client.add(tdsPacket(
          type: packReply,
          body: builder == null ? _doneToken() : builder(_replies++),
        ));
        await client.flush();
      }
    } catch (_) {
      try {
        client?.destroy();
      } catch (_) {}
    }
  }

  bool get _drops =>
      fault == ScriptedFault.bulkDrop ||
      fault == ScriptedFault.attentionDrop ||
      fault == ScriptedFault.commitDrop;

  bool _faultOn(_Packet packet, String? sql) {
    switch (fault) {
      case ScriptedFault.bulkDrop:
      case ScriptedFault.bulkStall:
        return packet.type == packBulkLoadBCP;
      case ScriptedFault.attentionDrop:
      case ScriptedFault.attentionStall:
        return packet.type == packAttention;
      case ScriptedFault.commitDrop:
      case ScriptedFault.commitStall:
        return sql != null && sql.toUpperCase().contains('COMMIT TRANSACTION');
      default:
        return false;
    }
  }
}

class _Packet {
  _Packet(this.type, this.body);
  final int type;
  final Uint8List body;
}

Future<_Packet?> _readPacket(ChunkedStreamReader<int> reader) async {
  final header = await reader.readChunk(headerSize);
  if (header.length < headerSize) return null;
  final size = (header[2] << 8) | header[3];
  final bodyLen = size - headerSize;
  final body = bodyLen > 0
      ? Uint8List.fromList(await reader.readChunk(bodyLen))
      : Uint8List(0);
  return _Packet(header[0], body);
}

String? _sqlText(_Packet packet) {
  if (packet.type != packSQLBatch || packet.body.length < 22) return null;
  final chars = StringBuffer();
  for (var i = 22; i + 1 < packet.body.length; i += 2) {
    chars.writeCharCode(packet.body[i] | (packet.body[i + 1] << 8));
  }
  return chars.toString();
}

Uint8List _preloginReply() {
  const value = [encryptNotSupported];
  final out = BytesBuilder(copy: false);
  out.addByte(preloginEncryption);
  out.addByte(0);
  out.addByte(6);
  out.addByte(0);
  out.addByte(value.length);
  out.addByte(preloginTerminator);
  out.add(value);
  return Uint8List.fromList(out.toBytes());
}

Uint8List _loginAckDone({required String database}) {
  const progName = 'Microsoft SQL Server';
  final name = ucs2(progName);
  final ack = BytesBuilder(copy: false);
  ack.addByte(1);
  ack.add([0x74, 0x00, 0x00, 0x04]);
  ack.addByte(progName.length);
  ack.add(name);
  writeUint32LE(ack, 0x01000000);
  final ackBytes = ack.toBytes();

  final env = BytesBuilder(copy: false);
  env.addByte(envDatabase);
  env.addByte(database.length);
  env.add(ucs2(database));
  env.addByte(database.length);
  env.add(ucs2(database));
  final envBytes = env.toBytes();

  final out = BytesBuilder(copy: false);
  out.addByte(tokenLoginAck);
  writeUint16LE(out, ackBytes.length);
  out.add(ackBytes);
  out.addByte(tokenEnvChange);
  writeUint16LE(out, envBytes.length);
  out.add(envBytes);
  out.add(_doneToken());
  return Uint8List.fromList(out.toBytes());
}

List<int> _doneToken({int flags = doneFlagFinal, int rowCount = 0}) {
  final out = BytesBuilder(copy: false);
  out.addByte(tokenDone);
  writeUint16LE(out, flags);
  writeUint16LE(out, 0);
  writeUint64LE(out, rowCount);
  return out.toBytes();
}

Uint8List _oneIntRow() {
  final name = ucs2('n');
  final out = BytesBuilder(copy: false);
  out.addByte(tokenColMetadata);
  writeUint16LE(out, 1);
  writeUint32LE(out, 0);
  writeUint16LE(out, 0);
  out.addByte(typeInt4);
  out.addByte(1);
  out.add(name);
  out.addByte(tokenRow);
  writeUint32LE(out, 1);
  return Uint8List.fromList(out.toBytes());
}
