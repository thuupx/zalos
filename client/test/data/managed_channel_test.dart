import 'dart:async';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:zalos/src/data/protocol/managed_channel.dart';
import 'package:zalos/src/data/protocol/noise_channel.dart';
import 'package:zalos/src/domain/models.dart';

import 'support.dart';

class FakeNoiseChannel implements NoiseChannel {
  final _done = Completer<int?>();
  bool closed = false;

  void die(int? code) {
    if (!closed) {
      closed = true;
      _done.complete(code);
    }
  }

  @override
  Future<int?> get done => _done.future;
  @override
  bool get isClosed => closed;
  @override
  int? get closeCode => closed ? 0 : null;
  @override
  void close() => die(1000);
  @override
  Future<dynamic> request(String method, [Map<String, dynamic> params = const {}, Duration? timeout]) =>
      Future.value({});
  @override
  int sendBlob(Uint8List data) => 1;
  @override
  Future<Uint8List> receiveBlob(int stream, {Duration timeout = const Duration(seconds: 60)}) =>
      Future.value(Uint8List(0));
}

ChannelKeys keys() => ChannelKeys(
      host: '127.0.0.1',
      port: 1,
      serverPublicKey: List.filled(32, 1),
      devicePrivateKey: List.filled(32, 2),
      devicePsk: List.filled(32, 3),
    );

ManagedChannel channel({
  required List<FakeNoiseChannel> made,
  Future<void> Function(NoiseChannel)? onConnected,
}) {
  return ManagedChannel(
    keys: keys(),
    path: '/v1/control',
    prologue: 'p',
    onConnected: onConnected ?? (_) async {},
    onEvent: (_) {},
    initialBackoff: const Duration(milliseconds: 5),
    maxBackoff: const Duration(milliseconds: 20),
    connector: (onEvent) async {
      final fake = FakeNoiseChannel();
      made.add(fake);
      return fake;
    },
  );
}

void main() {
  setUpAll(initRust);

  test('4001 ends unauthorized and does not reconnect', () async {
    final made = <FakeNoiseChannel>[];
    final ch = channel(made: made);
    ch.start();
    await waitFor(() => made.isNotEmpty);
    made.single.die(4001);
    await waitFor(() => ch.state.value == LinkState.unauthorized);
    await Future<void>.delayed(const Duration(milliseconds: 60));
    expect(made.length, 1);
    expect(ch.isStopped, isTrue);
  });

  test('4004 stops without reconnecting', () async {
    final made = <FakeNoiseChannel>[];
    final ch = channel(made: made);
    ch.start();
    await waitFor(() => made.isNotEmpty);
    made.single.die(4004);
    await waitFor(() => ch.state.value == LinkState.disconnected);
    await Future<void>.delayed(const Duration(milliseconds: 60));
    expect(made.length, 1);
    expect(ch.isStopped, isTrue);
  });

  for (final code in [4002, 1013]) {
    test('$code reconnects with backoff', () async {
      final made = <FakeNoiseChannel>[];
      var connects = 0;
      final ch = channel(
        made: made,
        onConnected: (_) async => connects++,
      );
      ch.start();
      await waitFor(() => made.isNotEmpty);
      made.single.die(code);
      await waitFor(() => made.length >= 2);
      expect(connects, greaterThanOrEqualTo(2));
      ch.dispose();
    });
  }
}
