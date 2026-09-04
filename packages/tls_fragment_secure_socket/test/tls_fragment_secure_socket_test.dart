import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:test/test.dart';
import 'package:tls_fragment_secure_socket/tls_fragment_secure_socket.dart';

String fixture(String path) =>
    '${Directory.current.path}${Platform.pathSeparator}test'
    '${Platform.pathSeparator}certificates${Platform.pathSeparator}$path';

final SecurityContext serverContext = SecurityContext()
  ..useCertificateChain(fixture('server.pem'))
  ..usePrivateKey(fixture('server.key'));

final SecurityContext clientContext = SecurityContext()
  ..setTrustedCertificates(fixture('ca.pem'));

void main() {
  test('serializes explicit fragments with inherited IOSink writes', () async {
    final server = await SecureServerSocket.bind('localhost', 0, serverContext);
    addTearDown(server.close);
    final peerFuture = server.first;

    final client = await TlsFragmentSecureSocket.connect(
      'localhost',
      server.port,
      context: clientContext,
    );
    addTearDown(client.destroy);
    final peer = await peerFuture;
    addTearDown(peer.destroy);

    expect(client, isA<SecureSocket>());
    expect(client.maximumTlsFragmentLength, 8191);
    await expectLater(
      client.writeTlsFragment(
        List<int>.filled(client.maximumTlsFragmentLength + 1, 0),
      ),
      throwsArgumentError,
    );

    final received = <int>[];
    final done = Completer<void>();
    final expected = <int>[];
    int? expectedLength;
    peer.listen((data) {
      received.addAll(data);
      if (received.length == expectedLength && !done.isCompleted) {
        done.complete();
      }
    });

    await client.writeTlsFragment(<int>[0x10]);
    expected.add(0x10);
    final prefix = List<int>.filled(client.maximumTlsFragmentLength - 1, 0x20);
    client.add(prefix);
    await client.flush();
    expected.addAll(prefix);

    final maximumFragment = List<int>.filled(
      client.maximumTlsFragmentLength,
      0x30,
    );
    final explicit = client.writeTlsFragment(maximumFragment);
    client.write('A');
    client.add(<int>[0x42]);
    await explicit;
    await client.flush();
    expected.addAll(maximumFragment);
    expected.addAll(ascii.encode('A'));
    expected.add(0x42);

    final mutable = <int>[0x50, 0x51];
    final queuedFirst = client.writeTlsFragment(<int>[0x40]);
    final queuedSecond = client.writeTlsFragment(mutable);
    mutable[0] = 0x7f;
    client.add(<int>[0x52]);
    await Future.wait(<Future<void>>[queuedFirst, queuedSecond]);
    await client.flush();
    expected.addAll(<int>[0x40, 0x50, 0x51, 0x52]);

    final oversizedOrdinary = List<int>.filled(
      client.maximumTlsFragmentLength + 2,
      0x60,
    );
    client.add(oversizedOrdinary);
    await client.flush();
    expected.addAll(oversizedOrdinary);

    await client.writeTlsFragment(const <int>[]);
    expectedLength = expected.length;
    if (received.length == expectedLength && !done.isCompleted) {
      done.complete();
    }
    await done.future.timeout(const Duration(seconds: 10));
    expect(received, expected);
  });

  test('startConnect retains the fragment socket type', () async {
    final server = await SecureServerSocket.bind('localhost', 0, serverContext);
    addTearDown(server.close);
    final peerFuture = server.first;

    final task = await TlsFragmentSecureSocket.startConnect(
      'localhost',
      server.port,
      context: clientContext,
    );
    final Future<TlsFragmentSecureSocket> typedFuture = task.socket;
    final client = await typedFuture;
    addTearDown(client.destroy);
    final peer = await peerFuture;
    addTearDown(peer.destroy);

    final received = peer.first;
    await client.writeTlsFragment(<int>[0x80, 0x81]);
    expect(await received, <int>[0x80, 0x81]);
  });

  test('secure and secureServer upgrade raw sockets', () async {
    final server = await RawServerSocket.bind('localhost', 0);
    addTearDown(server.close);
    final accepted = server.first;
    final rawClient = await RawSocket.connect('localhost', server.port);

    final serverSocket = accepted.then(
      (raw) => TlsFragmentSecureSocket.secureServer(raw, serverContext),
    );
    final clientSocket = TlsFragmentSecureSocket.secure(
      rawClient,
      host: 'localhost',
      context: clientContext,
    );
    final tlsServer = await serverSocket;
    final tlsClient = await clientSocket;
    addTearDown(tlsServer.destroy);
    addTearDown(tlsClient.destroy);

    final received = tlsClient.first;
    await tlsServer.writeTlsFragment(<int>[0x90, 0x91]);
    expect(await received, <int>[0x90, 0x91]);
  });
}
