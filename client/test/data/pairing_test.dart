import 'dart:async';
import 'dart:convert';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:zalos/src/data/key_store.dart';
import 'package:zalos/src/data/pairing.dart';
import 'package:zalos/src/data/protocol/noise_channel.dart';
import 'package:zalos/src/domain/services.dart';

import 'support.dart';

/// Answers `pair.complete` with [reply], or throws it when it is an error.
class _PairChannel extends Fake implements NoiseChannel {
  _PairChannel(this.reply);
  final Object reply;

  @override
  Future<dynamic> request(String method, [Map<String, dynamic> params = const {}, Duration? timeout]) async {
    final reply = this.reply;
    if (reply is Exception) throw reply;
    return reply;
  }

  @override
  void close() {}
}

String _key(int fill) => base64Url.encode(List.filled(32, fill)).replaceAll('=', '');

final _uri = 'zalos://pair?host=10.0.0.5&port=7443&id=ab12&secret=${_key(7)}&key=${_key(9)}';

Matcher _code(PairingErrorCode code) => throwsA(isA<PairingException>().having((e) => e.code, 'code', code));

Future<Credentials> _pair(FutureOr<NoiseChannel> Function() connect) =>
    runPairing(_uri, deviceName: 'Test', connector: (_) async => connect());

void main() {
  setUpAll(initRust);

  test('a malformed uri is invalid', () async {
    await expectLater(runPairing('zalos://pair?host=x', deviceName: 'x'), _code(PairingErrorCode.invalid));
    expect(() => parsePairingUri('hello'), _code(PairingErrorCode.invalid));
  });

  test('an unauthorized reply or auth close means the code expired', () async {
    await expectLater(
      _pair(() => _PairChannel(const RpcException('unauthorized', 'pairing invalid'))),
      _code(PairingErrorCode.expired),
    );
    await expectLater(
      _pair(() => throw const ChannelException('closed', closeCode: closeAuth)),
      _code(PairingErrorCode.expired),
    );
    await expectLater(
      _pair(() => throw const ChannelException('closed', closeCode: closeNotFound)),
      _code(PairingErrorCode.expired),
    );
  });

  test('a connect failure is unreachable with host:port as detail', () async {
    await expectLater(
      _pair(() => throw const ChannelException('could not connect', unreachable: true)),
      throwsA(isA<PairingException>()
          .having((e) => e.code, 'code', PairingErrorCode.unreachable)
          .having((e) => e.detail, 'detail', '10.0.0.5:7443')),
    );
  });

  test('another channel failure is a handshake failure', () async {
    await expectLater(
      _pair(() => throw const ChannelException('handshake failed')),
      _code(PairingErrorCode.handshake),
    );
  });

  test('an rpc error is a refusal', () async {
    await expectLater(
      _pair(() => _PairChannel(const RpcException('bad_request', 'boxPublicKey required'))),
      _code(PairingErrorCode.refused),
    );
  });

  test('a reply without usable keys is a protocol error', () async {
    for (final reply in <Object>[
      const <String, dynamic>{},
      {'psk': 'not base64!', 'deviceId': 'd1'},
      {'psk': base64Encode(Uint8List(8)), 'deviceId': 'd1'},
      {'psk': base64Encode(Uint8List(32))},
    ]) {
      await expectLater(_pair(() => _PairChannel(reply)), _code(PairingErrorCode.protocol), reason: '$reply');
    }
  });

  test('anything else is unknown', () async {
    await expectLater(_pair(() => throw StateError('boom')), _code(PairingErrorCode.unknown));
  });

  test('a valid reply yields credentials', () async {
    final credentials = await _pair(() => _PairChannel({'psk': base64Encode(Uint8List(32)), 'deviceId': 'd1'}));
    expect(credentials.deviceId, 'd1');
    expect(credentials.host, '10.0.0.5');
    expect(credentials.port, 7443);
  });

  test('base64url pairing uri round-trips with and without vault root', () {
    final base = PairingParams(
      host: '100.64.0.1',
      port: 7443,
      pairingId: 'ab12ef',
      secret: Uint8List.fromList(List.filled(32, 7)),
      serverPublicKey: Uint8List.fromList(List.filled(32, 9)),
    );
    final encoded = encodePairingUri(base);
    expect(encoded, startsWith('zalos://pair?d='));
    expect(encoded.contains('&'), isFalse);

    final parsed = parsePairingUri(encoded);
    expect(parsed.host, base.host);
    expect(parsed.port, base.port);
    expect(parsed.pairingId, base.pairingId);
    expect(parsed.secret, base.secret);
    expect(parsed.serverPublicKey, base.serverPublicKey);
    expect(parsed.vaultRoot, isNull);

    final root = Uint8List.fromList(List.filled(32, 5));
    final withVault = withPairingVault(encoded, root);
    expect(withVault, startsWith('zalos://pair?d='));
    expect(withVault.contains('&'), isFalse);
    final parsedWithVault = parsePairingUri(withVault);
    expect(parsedWithVault.vaultRoot, root);

    // Path form zalos://pair/<base64url> also parses.
    final pathForm = encoded.replaceFirst('?d=', '/');
    expect(parsePairingUri(pathForm).host, base.host);

    // Malformed base64 payload fails cleanly as invalid.
    expect(() => parsePairingUri('zalos://pair?d=not-valid-json'), _code(PairingErrorCode.invalid));
  });
}
