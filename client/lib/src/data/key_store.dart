import 'dart:convert';
import 'package:flutter/foundation.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';

import 'protocol/managed_channel.dart';

/// String key/value storage for secrets. The app uses the platform secure
/// storage, tests use [MemoryKeyStore].
abstract class KeyStore {
  Future<String?> read(String key);
  Future<void> write(String key, String value);
  Future<void> delete(String key);
}

class MemoryKeyStore implements KeyStore {
  final Map<String, String> values = {};

  @override
  Future<String?> read(String key) async => values[key];

  @override
  Future<void> write(String key, String value) async => values[key] = value;

  @override
  Future<void> delete(String key) async => values.remove(key);
}

class SecureKeyStore implements KeyStore {
  const SecureKeyStore([this._storage = _secureStorage]);
  // macOS: the data protection keychain is used in release builds where the
  // keychain-access-groups entitlement is signed; debug builds fall back to
  // the file-based keychain so they sign without a development profile.
  static const _secureStorage = FlutterSecureStorage(
    iOptions: IOSOptions(accessibility: KeychainAccessibility.first_unlock_this_device),
    mOptions: MacOsOptions(usesDataProtectionKeychain: kReleaseMode),
  );
  final FlutterSecureStorage _storage;

  @override
  Future<String?> read(String key) => _storage.read(key: key);

  @override
  Future<void> write(String key, String value) => _storage.write(key: key, value: value);

  @override
  Future<void> delete(String key) => _storage.delete(key: key);
}

/// Everything a paired device needs to reach its server again.
class Credentials {
  const Credentials({
    required this.host,
    required this.port,
    required this.serverPublicKey,
    required this.devicePrivateKey,
    required this.devicePublicKey,
    required this.devicePsk,
    required this.deviceId,
    required this.boxPrivateKey,
    required this.boxPublicKey,
    this.vaultRoot,
  });

  static const String storageKey = 'zalos.credentials.v1';

  final String host;
  final int port;
  final Uint8List serverPublicKey;
  final Uint8List devicePrivateKey;
  final Uint8List devicePublicKey;
  final Uint8List devicePsk;
  final String deviceId;

  /// Device box key pair: another device wraps the vault root to it.
  final Uint8List boxPrivateKey;
  final Uint8List boxPublicKey;

  /// Null until this device holds the vault root.
  final Uint8List? vaultRoot;

  Credentials withVaultRoot(Uint8List root) => Credentials(
        host: host,
        port: port,
        serverPublicKey: serverPublicKey,
        devicePrivateKey: devicePrivateKey,
        devicePublicKey: devicePublicKey,
        devicePsk: devicePsk,
        deviceId: deviceId,
        boxPrivateKey: boxPrivateKey,
        boxPublicKey: boxPublicKey,
        vaultRoot: root,
      );

  Credentials withoutVaultRoot() => Credentials(
        host: host,
        port: port,
        serverPublicKey: serverPublicKey,
        devicePrivateKey: devicePrivateKey,
        devicePublicKey: devicePublicKey,
        devicePsk: devicePsk,
        deviceId: deviceId,
        boxPrivateKey: boxPrivateKey,
        boxPublicKey: boxPublicKey,
      );

  ChannelKeys get channelKeys => ChannelKeys(
        host: host,
        port: port,
        serverPublicKey: serverPublicKey,
        devicePrivateKey: devicePrivateKey,
        devicePsk: devicePsk,
      );

  String encode() => jsonEncode({
        'host': host,
        'port': port,
        'serverPublicKey': base64Encode(serverPublicKey),
        'devicePrivateKey': base64Encode(devicePrivateKey),
        'devicePublicKey': base64Encode(devicePublicKey),
        'devicePsk': base64Encode(devicePsk),
        'deviceId': deviceId,
        'boxPrivateKey': base64Encode(boxPrivateKey),
        'boxPublicKey': base64Encode(boxPublicKey),
        if (vaultRoot != null) 'vaultRoot': base64Encode(vaultRoot!),
      });

  static Credentials? decode(String? raw) {
    if (raw == null || raw.isEmpty) return null;
    try {
      final json = jsonDecode(raw) as Map<String, dynamic>;
      final root = json['vaultRoot'];
      return Credentials(
        host: json['host'] as String,
        port: (json['port'] as num).toInt(),
        serverPublicKey: base64Decode(json['serverPublicKey'] as String),
        devicePrivateKey: base64Decode(json['devicePrivateKey'] as String),
        devicePublicKey: base64Decode(json['devicePublicKey'] as String),
        devicePsk: base64Decode(json['devicePsk'] as String),
        deviceId: json['deviceId'] as String,
        boxPrivateKey: base64Decode(json['boxPrivateKey'] as String),
        boxPublicKey: base64Decode(json['boxPublicKey'] as String),
        vaultRoot: root is String ? base64Decode(root) : null,
      );
    } catch (_) {
      return null;
    }
  }

  static Future<Credentials?> load(KeyStore store) async => decode(await store.read(storageKey));

  Future<void> save(KeyStore store) => store.write(storageKey, encode());
}
