import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter_rust_bridge/flutter_rust_bridge_for_generated.dart';
import 'package:zalos/src/data/key_store.dart';
import 'package:zalos/src/data/protocol/noise_channel.dart';
import 'package:zalos/src/data/real_app.dart';
import 'package:zalos/src/domain/models.dart';
import 'package:zalos/src/domain/services.dart';
import 'package:zalos/src/noise/noise.dart';

bool _rustReady = false;

Future<void> initRust() async {
  if (_rustReady) return;
  final path = '${Directory.current.path}/rust/target/release/librust_lib_zalos.dylib';
  await RustLib.init(externalLibrary: ExternalLibrary.open(path));
  _rustReady = true;
}

Future<int> freePort() async {
  final socket = await ServerSocket.bind(InternetAddress.loopbackIPv4, 0);
  final port = socket.port;
  await socket.close();
  return port;
}

Future<void> waitFor(
  bool Function() condition, {
  Duration timeout = const Duration(seconds: 15),
  String what = 'condition',
}) async {
  final deadline = DateTime.now().add(timeout);
  while (!condition()) {
    if (DateTime.now().isAfter(deadline)) {
      throw TimeoutException('timed out waiting for $what');
    }
    await Future<void>.delayed(const Duration(milliseconds: 20));
  }
}

/// The real server in fake gateway mode, as a child process.
class TestServer {
  TestServer._(this.dataDir, this.port);

  final Directory dataDir;
  final int port;
  Process? _process;

  static String get _serverDir => '${Directory.current.parent.path}/server';

  static Future<TestServer> create() async {
    final dir = await Directory.systemTemp.createTemp('zalos-client-test-');
    final server = TestServer._(dir, await freePort());
    await server.start();
    return server;
  }

  Map<String, String> get _env => {'ZALOS_DATA_DIR': dataDir.path};

  Future<void> start() async {
    Object? lastError;
    // The server sources may be mid-edit by someone else; retry a few times.
    for (var attempt = 0; attempt < 4; attempt++) {
      try {
        await _startOnce();
        return;
      } catch (e) {
        lastError = e;
        await stop();
        await Future<void>.delayed(const Duration(seconds: 5));
      }
    }
    throw StateError('server did not start: $lastError');
  }

  Future<void> _startOnce() async {
    final process = await Process.start(
      'bun',
      ['src/cli.ts', 'serve', '--dev', '--fake', '--port', '$port'],
      workingDirectory: _serverDir,
      environment: _env,
    );
    _process = process;
    final ready = Completer<void>();
    final errors = StringBuffer();
    process.stdout.transform(utf8.decoder).listen((chunk) {
      if (chunk.contains('listening') && !ready.isCompleted) ready.complete();
    });
    process.stderr.transform(utf8.decoder).listen(errors.write);
    unawaited(process.exitCode.then((code) {
      if (!ready.isCompleted) ready.completeError(StateError('server exited with $code: $errors'));
    }));
    await ready.future.timeout(const Duration(seconds: 20));
  }

  Future<void> stop() async {
    final process = _process;
    _process = null;
    if (process == null) return;
    process.kill(ProcessSignal.sigkill);
    await process.exitCode;
  }

  Future<String> pairUri({String role = 'member'}) async {
    final result = await Process.run(
      'bun',
      ['src/cli.ts', 'pair', '--port', '$port', '--role', role],
      workingDirectory: _serverDir,
      environment: _env,
    );
    final uri = (result.stdout as String).split('\n').firstWhere(
          (line) => line.startsWith('zalos://pair?'),
          orElse: () => throw StateError('no pairing uri: ${result.stdout}${result.stderr}'),
        );
    return uri.trim();
  }

  /// Posts an arbitrary event payload to the fake admin hook.
  Future<void> emit(String slot, Map<String, Object> payload) async {
    final result = await Process.run(
      'bun',
      ['src/cli.ts', 'fake', 'emit', slot, jsonEncode(payload)],
      workingDirectory: _serverDir,
      environment: _env,
    );
    if (result.exitCode != 0) throw StateError('fake emit failed: ${result.stdout}${result.stderr}');
  }

  /// Makes the fake gateway deliver an incoming text message.
  Future<void> incoming(String slot, String threadId, String text) async {
    final result = await Process.run(
      'bun',
      ['src/cli.ts', 'fake', 'incoming', slot, threadId, text],
      workingDirectory: _serverDir,
      environment: _env,
    );
    if (result.exitCode != 0) throw StateError('fake incoming failed: ${result.stdout}${result.stderr}');
  }

  Future<void> dispose() async {
    await stop();
    try {
      await dataDir.delete(recursive: true);
    } catch (_) {}
  }
}

/// Loopback TCP forwarder that can be switched off to take one client offline
/// while the server keeps running.
class TcpProxy {
  TcpProxy._(this._listener, this.targetPort);

  final ServerSocket _listener;
  final int targetPort;
  final Set<Socket> _sockets = {};
  bool enabled = true;

  int get port => _listener.port;

  static Future<TcpProxy> start(int targetPort) async {
    final proxy = TcpProxy._(await ServerSocket.bind(InternetAddress.loopbackIPv4, 0), targetPort);
    proxy._listener.listen(proxy._accept);
    return proxy;
  }

  Future<void> _accept(Socket client) async {
    if (!enabled) {
      client.destroy();
      return;
    }
    Socket upstream;
    try {
      upstream = await Socket.connect(InternetAddress.loopbackIPv4, targetPort);
    } catch (_) {
      client.destroy();
      return;
    }
    _sockets..add(client)..add(upstream);
    void closeBoth() {
      _sockets..remove(client)..remove(upstream);
      client.destroy();
      upstream.destroy();
    }

    client.listen(upstream.add, onDone: closeBoth, onError: (_) => closeBoth());
    upstream.listen(client.add, onDone: closeBoth, onError: (_) => closeBoth());
    client.done.catchError((_) {});
    upstream.done.catchError((_) {});
  }

  void disable() {
    enabled = false;
    for (final socket in _sockets.toList()) {
      socket.destroy();
    }
    _sockets.clear();
  }

  void enable() => enabled = true;

  Future<void> close() async {
    disable();
    await _listener.close();
  }
}

class Device {
  Device(this.app, this.keyStore);
  final RealZalosApp app;
  final MemoryKeyStore keyStore;

  ServerLink get link => app.link.value!;

  Future<void> connected() =>
      waitFor(() => link.state.value == LinkState.connected && link.manifest.value != null, what: 'control link');
}

Future<Device> pairDevice(String uri, String name) async {
  final keyStore = MemoryKeyStore();
  final app = await RealZalosApp.open(keyStore);
  await app.pair(uri, deviceName: name);
  final device = Device(app, keyStore);
  await device.connected();
  return device;
}

/// A bare protocol channel with the device's keys, to look at what the
/// server really sends.
Future<NoiseChannel> rawChannel(Device device, {String? slot}) async {
  final credentials = (await Credentials.load(device.keyStore))!;
  final path = slot == null ? '/v1/control' : '/v1/account/$slot';
  final prologue = slot == null ? 'zalos/1/control' : 'zalos/1/account/$slot';
  final channel = await NoiseChannel.connect(
    uri: credentials.channelKeys.uri(path),
    prologue: prologue,
    localPrivate: credentials.devicePrivateKey,
    remotePublic: credentials.serverPublicKey,
    psk: credentials.devicePsk,
  );
  await channel.request(slot == null ? 'manifest.get' : 'sync', slot == null ? const {} : {'sinceSeq': 0});
  return channel;
}

/// Waits until the server has a vault key for [slot], so that everything
/// stored afterwards is sealed.
Future<void> vaultKeySet(Device device, String slot) async {
  final channel = await rawChannel(device);
  try {
    final deadline = DateTime.now().add(const Duration(seconds: 15));
    while (true) {
      final manifest = await channel.request('manifest.get') as Map<String, dynamic>;
      final accounts = (manifest['accounts'] as List).cast<Map<String, dynamic>>();
      if (accounts.any((a) => a['slot'] == slot && a['vaultKey'] != null)) return;
      if (DateTime.now().isAfter(deadline)) throw TimeoutException('vault key was never set for $slot');
      await Future<void>.delayed(const Duration(milliseconds: 30));
    }
  } finally {
    channel.close();
  }
}

/// Logs a fake account in and waits until the admin device has uploaded the
/// vault key for it.
Future<String> loginFakeAccount(Device admin) async {
  final events = await admin.link.startLoginQr().toList().timeout(const Duration(seconds: 15));
  final done = events.whereType<LoginQrDone>().single;
  await waitFor(
    () => admin.link.manifest.value!.accounts.any((a) => a.slot == done.slot),
    what: 'account in manifest',
  );
  await vaultKeySet(admin, done.slot);
  return done.slot;
}

Future<AccountSession> openAccount(Device device, String slot) async {
  await waitFor(
    () => device.link.manifest.value!.accounts.any((a) => a.slot == slot),
    what: 'account visible to device',
  );
  final session = device.link.account(slot);
  await waitFor(() => session.state.value == LinkState.connected, what: 'account link');
  return session;
}

String withPort(String uri, int port) => uri.replaceFirst(RegExp(r'port=\d+'), 'port=$port');

Uint8List patternBytes(int length) {
  final out = Uint8List(length);
  for (var i = 0; i < length; i++) {
    out[i] = (i * 31 + (i >> 8)) & 0xff;
  }
  return out;
}
