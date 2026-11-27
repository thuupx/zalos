import 'dart:convert';

import 'package:flutter/foundation.dart';

import '../domain/services.dart';
import '../noise/noise.dart';
import '../rust_lib/api/vault.dart' as vault;
import 'key_store.dart';
import 'mapping.dart';
import 'protocol/noise_channel.dart';
import 'protocol/ws_uri.dart';

class PairingParams {
  const PairingParams({
    required this.host,
    required this.port,
    required this.pairingId,
    required this.secret,
    required this.serverPublicKey,
    this.vaultRoot,
  });
  final String host;
  final int port;
  final String pairingId;
  final Uint8List secret;
  final Uint8List serverPublicKey;

  /// Present when the uri was rendered by a device that holds the root.
  final Uint8List? vaultRoot;
}

const _invalidCode = PairingException('This is not a valid zalos pairing code.', code: PairingErrorCode.invalid);
const _expiredCode = PairingException(
  'This pairing code has expired or was already used.',
  code: PairingErrorCode.expired,
);
const _unexpectedReply = PairingException('The server sent an unexpected pairing reply.', code: PairingErrorCode.protocol);

Uint8List? _decodeKey(String? value) {
  if (value == null || value.isEmpty) return null;
  try {
    final bytes = base64Url.decode(base64Url.normalize(value.trim()));
    return bytes.length == 32 ? bytes : null;
  } catch (_) {
    return null;
  }
}

String _encodeKey(Uint8List bytes) => base64Url.encode(bytes).replaceAll('=', '');

/// Encodes [params] as a single base64url payload inside `zalos://pair?d=...`.
String encodePairingUri(PairingParams params) {
  final payload = <String, Object>{
    'host': params.host,
    'port': params.port,
    'id': params.pairingId,
    'secret': _encodeKey(params.secret),
    'key': _encodeKey(params.serverPublicKey),
    if (params.vaultRoot != null) 'vault': _encodeKey(params.vaultRoot!),
  };
  final encoded = base64Url.encode(utf8.encode(jsonEncode(payload))).replaceAll('=', '');
  return 'zalos://pair?d=$encoded';
}

/// Embeds [vaultRoot] into an existing pairing URI and returns it in the
/// canonical base64url `zalos://pair?d=...` form.
String withPairingVault(String uri, Uint8List vaultRoot) {
  final parsed = parsePairingUri(uri);
  return encodePairingUri(PairingParams(
    host: parsed.host,
    port: parsed.port,
    pairingId: parsed.pairingId,
    secret: parsed.secret,
    serverPublicKey: parsed.serverPublicKey,
    vaultRoot: vaultRoot,
  ));
}

PairingParams _validateParams({
  required String host,
  required int? port,
  required String id,
  required String? secretRaw,
  required String? keyRaw,
  required bool hasVault,
  required String? vaultRaw,
}) {
  final secret = _decodeKey(secretRaw);
  final key = _decodeKey(keyRaw);
  final vault = _decodeKey(vaultRaw);
  if (hasVault && vault == null) throw _invalidCode;
  if (host.isEmpty ||
      port == null ||
      port < 1 ||
      port > 65535 ||
      !RegExp(r'^[0-9a-f]+$').hasMatch(id) ||
      secret == null ||
      key == null) {
    throw _invalidCode;
  }
  return PairingParams(
    host: host,
    port: port,
    pairingId: id,
    secret: secret,
    serverPublicKey: key,
    vaultRoot: vault,
  );
}

PairingParams _parseEncodedPayload(String encoded, {String? fallbackVault}) {
  final Object? decoded;
  try {
    final raw = utf8.decode(base64Url.decode(base64Url.normalize(encoded.trim())));
    decoded = jsonDecode(raw);
  } catch (_) {
    throw _invalidCode;
  }
  if (decoded is! Map) throw _invalidCode;
  final map = asJson(decoded);
  final rawPort = map['port'];
  final port = rawPort is int
      ? rawPort
      : rawPort is num && rawPort == rawPort.toInt()
          ? rawPort.toInt()
          : int.tryParse('${rawPort ?? ''}');
  final hasVault = map.containsKey('vault') || fallbackVault != null;
  final vaultRaw = map.containsKey('vault') ? '${map['vault'] ?? ''}' : fallbackVault;
  return _validateParams(
    host: map['host'] is String ? map['host'] as String : '',
    port: port,
    id: map['id'] is String ? map['id'] as String : '',
    secretRaw: map['secret'] is String ? map['secret'] as String : null,
    keyRaw: map['key'] is String ? map['key'] as String : null,
    hasVault: hasVault,
    vaultRaw: vaultRaw,
  );
}

/// Parses `zalos://pair?d=<base64url>` (canonical), `zalos://pair/<base64url>`,
/// or legacy `zalos://pair?host=&port=&id=&secret=&key=[&vault=]`.
/// Throws [PairingException].
PairingParams parsePairingUri(String input) {
  final uri = Uri.tryParse(input.trim());
  if (uri == null || uri.scheme != 'zalos' || uri.host != 'pair') throw _invalidCode;
  final Map<String, String> query;
  try {
    query = uri.queryParameters;
  } catch (_) {
    throw _invalidCode;
  }
  final encodedQuery = query['d'];
  if (encodedQuery != null && encodedQuery.isNotEmpty) {
    return _parseEncodedPayload(
      encodedQuery,
      fallbackVault: query.containsKey('vault') ? (query['vault'] ?? '') : null,
    );
  }
  if (uri.pathSegments.length == 1 && uri.pathSegments.first.isNotEmpty) {
    return _parseEncodedPayload(
      uri.pathSegments.first,
      fallbackVault: query.containsKey('vault') ? (query['vault'] ?? '') : null,
    );
  }
  return _validateParams(
    host: query['host'] ?? '',
    port: int.tryParse(query['port'] ?? ''),
    id: query['id'] ?? '',
    secretRaw: query['secret'],
    keyRaw: query['key'],
    hasVault: query.containsKey('vault'),
    vaultRaw: query['vault'],
  );
}

/// Runs the one-time pair channel and returns the credentials to persist.
/// [connector] is a test hook that replaces [NoiseChannel.connect].
Future<Credentials> runPairing(
  String uri, {
  required String deviceName,
  @visibleForTesting Future<NoiseChannel> Function(Uri uri)? connector,
}) async {
  final params = parsePairingUri(uri);
  final keypair = await generateKeypair();
  final box = vault.boxKeypair();
  final channelUri = tunnelUri(params.host, params.port, '/v1/pair/${params.pairingId}');
  NoiseChannel? channel;
  try {
    channel = connector != null
        ? await connector(channelUri)
        : await NoiseChannel.connect(
            uri: channelUri,
            prologue: 'zalos/1/pair/${params.pairingId}',
            localPrivate: keypair.private,
            remotePublic: params.serverPublicKey,
            psk: params.secret,
          );
    final result = asJson(await channel.request('pair.complete', {
      'deviceName': deviceName,
      'boxPublicKey': base64Encode(box.public),
    }));
    final Uint8List psk;
    try {
      psk = base64Decode(base64.normalize('${result['psk']}'));
    } on FormatException {
      throw _unexpectedReply;
    }
    final deviceId = '${result['deviceId'] ?? ''}';
    if (psk.length != 32 || deviceId.isEmpty) throw _unexpectedReply;
    return Credentials(
      host: params.host,
      port: params.port,
      serverPublicKey: params.serverPublicKey,
      devicePrivateKey: keypair.private,
      devicePublicKey: keypair.public,
      devicePsk: psk,
      deviceId: deviceId,
      boxPrivateKey: box.private,
      boxPublicKey: box.public,
      vaultRoot: params.vaultRoot,
    );
  } on PairingException {
    rethrow;
  } on RpcException catch (e) {
    if (e.code == 'unauthorized') throw _expiredCode;
    throw PairingException('The server refused to pair: ${e.message}', code: PairingErrorCode.refused);
  } on ChannelException catch (e) {
    if (e.closeCode == closeAuth || e.closeCode == closeNotFound) throw _expiredCode;
    if (e.unreachable) {
      final address = '${params.host}:${params.port}';
      throw PairingException(
        'Could not reach the server at $address.',
        code: PairingErrorCode.unreachable,
        detail: address,
      );
    }
    throw const PairingException('Secure handshake with the server failed.', code: PairingErrorCode.handshake);
  } catch (_) {
    throw const PairingException('Pairing failed unexpectedly.');
  } finally {
    channel?.close();
  }
}
