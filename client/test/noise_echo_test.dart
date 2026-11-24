// Interop proof: Flutter (native macOS) Noise initiator against the Bun
// WebSocket echo responder in server/test/fixtures/echo.ts.
//
// Run: flutter test test/noise_echo_test.dart
import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter_rust_bridge/flutter_rust_bridge_for_generated.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:zalos/src/rust_lib/frb_generated.dart';
import 'package:zalos/src/rust_lib/api/noise.dart';

// Same fixed test vectors as server/spike/testkeys.ts.
const serverPublic =
    '7806e52dbdda60e10e63377d1bce7fe986385af1c9a6fe14f287e50d0d087d2b';
const devicePrivate =
    '4c0f773fa26f61f528d63dbbbda8a2bf0b97d318d8a30f6483b4447bb39f540c';
const devicePsk =
    '51d5139a58c5069b6221e7300c9c4e2d48857fe1f97e39418564732a8bd905b2';
final prologue = utf8.encode('zalos/1/control');

Uint8List fromHex(String hex) {
  final out = Uint8List(hex.length ~/ 2);
  for (var i = 0; i < out.length; i++) {
    out[i] = int.parse(hex.substring(i * 2, i * 2 + 2), radix: 16);
  }
  return out;
}

String libPath() =>
    '${Directory.current.path}/rust/target/release/librust_lib_zalos.dylib';

Future<Process> startEchoServer(int port) async {
  final serverDir = '${Directory.current.parent.path}/server';
  final proc = await Process.start(
    'bun',
    ['test/fixtures/echo.ts', '$port'],
    workingDirectory: serverDir,
  );
  final ready = Completer<void>();
  proc.stdout.transform(utf8.decoder).listen((line) {
    if (line.contains('listening')) ready.complete();
  });
  proc.stderr.drain<void>();
  await ready.future.timeout(const Duration(seconds: 10));
  return proc;
}

void main() {
  setUpAll(() async {
    await RustLib.init(externalLibrary: ExternalLibrary.open(libPath()));
  });

  test('dart initiator does IKpsk2 handshake and echo over ws', () async {
    const port = 18932;
    final proc = await startEchoServer(port);
    addTearDown(proc.kill);

    final session = await Session.initiator(
      prologue: prologue,
      localPrivate: fromHex(devicePrivate),
      remotePublic: fromHex(serverPublic),
      psk: fromHex(devicePsk),
    );

    final ws = await WebSocket.connect('ws://127.0.0.1:$port/v1/control');
    addTearDown(() => ws.close());

    final echoed = Completer<String>();
    ws.listen((data) async {
      final bytes = data is Uint8List ? data : Uint8List.fromList(data as List<int>);
      if (!await session.isHandshakeFinished()) {
        await session.readHandshake(message: bytes);
        final ct = await session.encrypt(plaintext: utf8.encode('hello zalos'));
        ws.add(ct);
      } else {
        final plain = await session.decrypt(ciphertext: bytes);
        echoed.complete(utf8.decode(plain));
      }
    });

    final m1 = await session.writeHandshake(payload: Uint8List(0));
    ws.add(m1);

    expect(await echoed.future.timeout(const Duration(seconds: 10)),
        'hello zalos');
  });
}
