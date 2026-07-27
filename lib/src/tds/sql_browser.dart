import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import '../exception.dart';

/// SQL Server Browser (SSRP) client — resolves named-instance TCP ports.
///
/// Speaks UDP on port 1434 ([CLNT_UCAST_INST] / [SVR_RESP]), per
/// [MS-SSRP] / go-mssqldb instance lookup. Used when connecting to
/// `HOST\INSTANCE` without an explicit port.
class SqlBrowser {
  static const int defaultBrowserPort = 1434;

  /// Asks the Browser on [host] for the TCP port of [instanceName].
  static Future<int> resolveTcpPort(
    String host,
    String instanceName, {
    Duration timeout = const Duration(seconds: 3),
    int browserPort = defaultBrowserPort,
  }) async {
    if (instanceName.isEmpty) {
      throw ArgumentError('instanceName must not be empty');
    }

    final addresses = await InternetAddress.lookup(host);
    if (addresses.isEmpty) {
      throw MssqlException('SQL Browser: could not resolve host "$host"');
    }

    final sock = await RawDatagramSocket.bind(InternetAddress.anyIPv4, 0);
    try {
      final request = buildClntUcastInst(instanceName);
      final browserAddress = addresses.first;
      sock.send(request, browserAddress, browserPort);

      final dg = await _receive(
        sock,
        expectedAddress: browserAddress,
        expectedPort: browserPort,
      ).timeout(
        timeout,
        onTimeout: () => throw MssqlException(
          'SQL Browser timed out after ${timeout.inMilliseconds}ms '
          '($host\\$instanceName via UDP $browserPort)',
        ),
      );
      return parseTcpPort(dg.data, expectedInstance: instanceName);
    } finally {
      sock.close();
    }
  }

  /// CLNT_UCAST_INST: `0x04` + instance name + NUL.
  static Uint8List buildClntUcastInst(String instanceName) {
    final name = utf8.encode(instanceName);
    return Uint8List.fromList([0x04, ...name, 0x00]);
  }

  /// Parses SVR_RESP (`0x05` + LE length + semicolon key/value pairs).
  static int parseTcpPort(
    Uint8List data, {
    String? expectedInstance,
  }) {
    if (data.length < 3 || data[0] != 0x05) {
      throw FormatException(
        'SQL Browser: expected SVR_RESP (0x05), got '
        '${data.isEmpty ? "empty" : "0x${data[0].toRadixString(16)}"}',
      );
    }
    final len = data[1] | (data[2] << 8);
    final start = 3;
    final end = (start + len <= data.length) ? start + len : data.length;
    final text = utf8.decode(data.sublist(start, end), allowMalformed: true);
    final fields = parseResponseFields(text);

    if (expectedInstance != null) {
      final got = fields['InstanceName'];
      if (got != null && got.toLowerCase() != expectedInstance.toLowerCase()) {
        throw MssqlException(
          'SQL Browser: expected instance "$expectedInstance", got "$got"',
        );
      }
    }

    final tcp = fields['tcp'];
    if (tcp == null || tcp.isEmpty) {
      throw MssqlException(
        'SQL Browser: no tcp port in response'
        '${expectedInstance == null ? "" : " for $expectedInstance"}',
      );
    }
    final port = int.tryParse(tcp);
    if (port == null || port <= 0 || port > 65535) {
      throw MssqlException('SQL Browser: invalid tcp port "$tcp"');
    }
    return port;
  }

  /// Splits `Key;Value;Key;Value;...` (and `;;`-separated instances) into a map.
  static Map<String, String> parseResponseFields(String text) {
    // CLNT_UCAST_INST returns a single instance block.
    final block = text.split(';;').first;
    final parts = block.split(';');
    final map = <String, String>{};
    for (var i = 0; i + 1 < parts.length; i += 2) {
      final k = parts[i].trim();
      final v = parts[i + 1].trim();
      if (k.isNotEmpty) map[k] = v;
    }
    return map;
  }

  static Future<Datagram> _receive(
    RawDatagramSocket sock, {
    required InternetAddress expectedAddress,
    required int expectedPort,
  }) {
    final completer = Completer<Datagram>();
    late StreamSubscription<RawSocketEvent> sub;
    sub = sock.listen((event) {
      if (event == RawSocketEvent.read) {
        final dg = sock.receive();
        if (dg != null && !completer.isCompleted) {
          if (dg.port != expectedPort ||
              dg.address.address != expectedAddress.address) {
            return;
          }
          completer.complete(dg);
          unawaited(sub.cancel());
        }
      }
    }, onError: (Object e, StackTrace st) {
      if (!completer.isCompleted) completer.completeError(e, st);
    });
    return completer.future;
  }
}
