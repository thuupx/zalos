// Data-layer tests against the WireMock Zalo mock stack: the real zca-js
// adapter path end to end. Needs Docker (mock/compose.yaml) and `bun` on
// PATH; skips cleanly without either.
//
// Run: flutter test test/data/mock_stack_test.dart
import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'dart:typed_data';

import 'package:zalos/src/domain/models.dart';

import 'support.dart';

const mockUrl = 'http://127.0.0.1:7355';
const friend = '777000222';
const user = ThreadType.user;

Future<bool> dockerOk() async {
  try {
    final r = await Process.run('docker', ['compose', 'version']);
    return r.exitCode == 0;
  } catch (_) {
    return false;
  }
}

Future<List<String>> journalUrls() async {
  final res = await Process.run('curl', ['-s', '$mockUrl/__journal']);
  final json = jsonDecode('${res.stdout}') as Map<String, dynamic>;
  return [
    for (final r in (json['requests'] as List))
      '${(r as Map<String, dynamic>)['request']['url']}',
  ];
}

Future<void> mockCtl(String path, [Map<String, Object>? body]) async {
  // flutter_test replaces HttpClient with a fake; curl avoids that.
  final res = await Process.run('curl', [
    '-s', '-o', '/dev/null', '-w', '%{http_code}',
    '-X', 'POST', '-H', 'content-type: application/json',
    '-d', jsonEncode(body ?? {}),
    '$mockUrl/__mock$path',
  ]);
  if ('${res.stdout}' != '200') {
    throw StateError('mock $path: ${res.stdout} ${res.stderr}');
  }
}

class MockServer {
  MockServer._(this.dataDir, this.port, this.process, this.env);
  final Directory dataDir;
  final int port;
  final Process process;
  final Map<String, String> env;

  static Future<MockServer> create() async {
    final serverDir = Directory('../server').absolute.path;
    final dir = await Directory.systemTemp.createTemp('zalos-mocktest-');
    final port = await freePort();
    final env = Map<String, String>.from(Platform.environment)
      ..['ZALOS_ZALO_MOCK_URL'] = mockUrl
      ..['ZALOS_DATA_DIR'] = dir.path;
    final process = await Process.start(
      'bun',
      ['src/cli.ts', 'serve', '--dev', '--port', '$port'],
      workingDirectory: serverDir,
      environment: env,
    );
    process.stdout.drain<void>();
    process.stderr.drain<void>();
    final deadline = DateTime.now().add(const Duration(seconds: 30));
    while (true) {
      try {
        final s = await Socket.connect('127.0.0.1', port);
        await s.close();
        break;
      } catch (_) {
        if (DateTime.now().isAfter(deadline)) {
          throw StateError('server did not come up');
        }
        await Future<void>.delayed(const Duration(milliseconds: 100));
      }
    }
    return MockServer._(dir, port, process, env);
  }

  Future<String> pairUri() async {
    final result = await Process.run(
      'bun',
      ['src/cli.ts', 'pair', '--port', '$port', '--role', 'admin'],
      workingDirectory: '../server',
      environment: env,
    );
    final uri = (result.stdout as String).split('\n').firstWhere(
          (line) => line.startsWith('zalos://pair?'),
          orElse: () => throw StateError('no pairing uri: ${result.stdout}${result.stderr}'),
        );
    return uri.trim();
  }

  Future<void> dispose() async {
    process.kill(ProcessSignal.sigkill);
    await process.exitCode;
    try {
      await dataDir.delete(recursive: true);
    } catch (_) {}
  }
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  late bool skip;
  MockServer? server;

  setUpAll(() async {
    initRust();
    skip = !await dockerOk();
    if (skip) return;
    await Process.run(
      'docker',
      ['compose', '-f', 'compose.yaml', 'up', '-d'],
      workingDirectory: '../mock',
    );
    await mockCtl('/reset');
    server = await MockServer.create();
  });

  tearDownAll(() async {
    if (!skip) await server?.dispose();
  });

  test('qr login through the real zca path, then the data layer works', () async {
    if (skip) {
      markTestSkipped('Docker unavailable');
      return;
    }
    final device = await pairDevice(await server!.pairUri(), 'Admin');
    final login = StreamIterator(device.link.startLoginQr());
    var gotImage = false;
    var gotDone = false;
    // Drive the mock scan/confirm while consuming the login event stream.
    while (await login.moveNext().timeout(const Duration(seconds: 30))) {
      final ev = login.current;
      if (ev is LoginQrImage) {
        gotImage = true;
        expect(ev.png, isNotEmpty);
        await mockCtl('/qr/scan');
        await mockCtl('/qr/confirm');
      }
      if (ev is LoginQrDone) gotDone = true;
    }
    login.cancel();
    expect(gotImage, isTrue);
    expect(gotDone, isTrue);
    await waitFor(() {
      final accounts = device.link.manifest.value?.accounts ?? [];
      return accounts.any((a) => a.status == AccountStatus.online);
    }, what: 'account online');
    final slot = device.link.manifest.value!.accounts
        .firstWhere((a) => a.status == AccountStatus.online)
        .slot;
    final session = await openAccount(device, slot);

    // incoming message through the real adapter
    await mockCtl('/events/message', {
      'threadId': friend,
      'uidFrom': friend,
      'dName': 'Trần Thị Hoa',
      'content': 'mock xin chào',
    });
    final list = session.messages(friend, user);
    await waitFor(() => list.value.any((m) => m.text == 'mock xin chào'), what: 'incoming');

    // send text through the real adapter
    await session.sendText(friend, user, 'từ client dart');
    await waitFor(() => list.value.any((m) => m.text == 'từ client dart'), what: 'sent');

    // image send stages the original filename
    await session.sendFile(
      friend,
      user,
      OutgoingFile(
        name: 'hinh.png',
        bytes: Uint8List.fromList(const [137, 80, 78, 71, 13, 10, 26, 10, 0, 0, 0, 0]),
        kind: MessageKind.image,
      ),
    );

    // pin, forward, delivery state from the Dart side
    await session.setPinned(friend, user, true);
    await waitFor(() => session.threads.value.singleWhere((t) => t.id == friend).pinned, what: 'pinned');

    final sent = list.value.firstWhere((m) => m.text == 'từ client dart');
    await session.forward(sent, [const ThreadRef('777000333', user)]);
    // The real adapter does not echo forwarded copies locally; Zalo would
    // deliver them as normal messages. Assert the forward went out via the
    // mock journal instead.
    final deadline = DateTime.now().add(const Duration(seconds: 10));
    var saw = false;
    while (DateTime.now().isBefore(deadline) && !saw) {
      saw = (await journalUrls()).any((u) => u.contains('mforward'));
      if (!saw) await Future<void>.delayed(const Duration(milliseconds: 200));
    }
    expect(saw, isTrue, reason: 'mforward in journal');

    await mockCtl('/events/delivered', {
      'threadId': friend,
      'msgId': sent.id,
      'userIds': [friend],
    });
    await mockCtl('/events/seen', {
      'threadId': friend,
      'msgId': sent.id,
      'uidFrom': friend,
    });
    await waitFor(
      () => list.value.firstWhere((m) => m.id == sent.id).deliveryState == DeliveryState.seen,
      what: 'seen state',
    );
  }, timeout: const Timeout(Duration(seconds: 120)));
}
