import 'dart:async';
import 'dart:io';
import 'dart:typed_data';

Future<void> main() async {
  await peerReset();
  await clientCloseThenDrain();
}

Future<void> peerReset() async {
  print('--- peer reset ---');
  final pair = await connect();
  final stalled = await stall(pair.client);
  final streamError = Completer<Object>();
  pair.client.listen(
    (_) {},
    onError: (Object error) {
      if (!streamError.isCompleted) streamError.complete(error);
    },
  );
  final closeFuture = pair.peer.close();
  try {
    await stalled.future.timeout(const Duration(seconds: 3));
    print('fragment completed');
  } catch (error) {
    print('fragment ${error.runtimeType}: $error');
  }
  try {
    final error = await streamError.future.timeout(const Duration(seconds: 3));
    print('stream ${error.runtimeType}: $error');
  } catch (error) {
    print('no stream error: $error');
  }
  try {
    await closeFuture.timeout(const Duration(seconds: 3));
    print('peer close completed');
  } catch (error) {
    print('peer close ${error.runtimeType}: $error');
  }
  try {
    await pair.client
        .writeTlsFragment(<int>[1])
        .timeout(const Duration(seconds: 2));
    print('follow-up succeeded');
  } catch (error) {
    print('follow-up ${error.runtimeType}: $error');
  }
  await pair.server.close();
}

Future<void> clientCloseThenDrain() async {
  print('--- client close then drain ---');
  final pair = await connect();
  final stalled = await stall(pair.client);
  final closeFuture = pair.client.close();
  var fragmentDone = false;
  var closeDone = false;
  unawaited(stalled.future.then((_) => fragmentDone = true));
  unawaited(
    closeFuture.then((_) => closeDone = true, onError: (_) => closeDone = true),
  );
  await Future<void>.delayed(const Duration(milliseconds: 300));
  print('before read fragmentDone=$fragmentDone closeDone=$closeDone');
  pair.subscription.resume();
  final received = <int>[];
  for (var n = 0; n < 100 && received.length < stalled.sent; n++) {
    while (true) {
      final data = pair.peer.read();
      if (data == null) break;
      received.addAll(data);
    }
    if (received.length >= stalled.sent) break;
    await Future<void>.delayed(const Duration(milliseconds: 20));
  }
  print('received ${received.length} of ${stalled.sent}');
  try {
    await stalled.future.timeout(const Duration(seconds: 3));
    print('fragment completed');
  } catch (error) {
    print('fragment ${error.runtimeType}: $error');
  }
  try {
    await closeFuture.timeout(const Duration(seconds: 3));
    print('client close completed');
  } catch (error) {
    print('client close ${error.runtimeType}: $error');
  }
  final matches = received.length == stalled.sent &&
      received.every((byte) => byte == 0xcd);
  print('bytes match=$matches');
  await pair.peer.close();
  await pair.server.close();
}

class _Pair {
  _Pair(this.server, this.client, this.peer, this.subscription);
  final RawSecureServerSocket server;
  final RawSecureSocket client;
  final RawSecureSocket peer;
  final StreamSubscription<RawSocketEvent> subscription;
}

class _Stalled {
  _Stalled(this.future, this.sent);
  final Future<void> future;
  final int sent;
}

Future<_Pair> connect() async {
  final certDir =
      r'C:\Users\user\StudioProjects\dart-sdk-tls-patched\sdk\tests\standalone\io\certificates';
  final serverContext = SecurityContext()
    ..useCertificateChain('$certDir\\server_chain.pem')
    ..usePrivateKey('$certDir\\server_key.pem', password: 'dartdart');
  final clientContext = SecurityContext()
    ..setTrustedCertificates('$certDir\\trusted_certs.pem');
  final host = (await InternetAddress.lookup('localhost')).first;
  final server = await RawSecureServerSocket.bind(host, 0, serverContext);
  final accepted = Completer<RawSecureSocket>();
  server.listen(accepted.complete, onError: accepted.completeError);
  final client = await RawSecureSocket.connect(
    host,
    server.port,
    context: clientContext,
  );
  final peer = await accepted.future;
  for (final socket in <RawSecureSocket>[client, peer]) {
    for (final option in <int>[0x1001, 0x1002]) {
      socket.setRawOption(
        RawSocketOption.fromInt(RawSocketOption.levelSocket, option, 1024),
      );
    }
  }
  final subscription = peer.listen((_) {});
  subscription.pause();
  return _Pair(server, client, peer, subscription);
}

Future<_Stalled> stall(RawSecureSocket client) async {
  final limit = client.maximumTlsFragmentLength;
  final chunk = Uint8List(limit)..fillRange(0, limit, 0xcd);
  var sent = 0;
  for (var i = 0; i < 100; i++) {
    var completed = false;
    final future = client.writeTlsFragment(chunk);
    unawaited(
      future.then((_) => completed = true, onError: (_) => completed = true),
    );
    await Future<void>.delayed(const Duration(milliseconds: 40));
    sent += chunk.length;
    if (!completed) {
      print('stalled after $sent bytes');
      return _Stalled(future, sent);
    }
  }
  throw StateError('failed to stall');
}
