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

  // iOS: device-only keychain item accessible after first unlock (no iCloud/backup migration).
  // macOS: data protection keychain in signed release builds, with automatic fallback to the
  // login keychain when built without the keychain-access-groups entitlement.
  static const _iosPrimaryOptions = IOSOptions(
    accessibility: KeychainAccessibility.first_unlock_this_device,
  );
  static const _macosPrimaryOptions = MacOsOptions(
    usesDataProtectionKeychain: kReleaseMode,
  );
  static const _macosFallbackOptions = MacOsOptions(
    usesDataProtectionKeychain: false,
  );
  static const _legacyIosAccessibilities = [
    KeychainAccessibility.unlocked,
    KeychainAccessibility.unlocked_this_device,
    KeychainAccessibility.first_unlock,
    KeychainAccessibility.passcode,
  ];

  static const _secureStorage = FlutterSecureStorage(
    iOptions: _iosPrimaryOptions,
    mOptions: _macosPrimaryOptions,
  );
  final FlutterSecureStorage _storage;

  @override
  Future<String?> read(String key) async {
    try {
      final value = await _storage.read(key: key);
      if (value != null) return value;
    } catch (_) {
      // Fall through to legacy/fallback read on Apple keychains.
      if (!kIsWeb && defaultTargetPlatform == TargetPlatform.macOS) {
        return _storage.read(key: key, mOptions: _macosFallbackOptions);
      }
      rethrow;
    }

    if (!kIsWeb && defaultTargetPlatform == TargetPlatform.iOS) {
      // Seamless migration from older installs that wrote with default `unlocked` accessibility.
      for (final acc in _legacyIosAccessibilities) {
        try {
          final legacyOpts = IOSOptions(accessibility: acc);
          final legacyValue = await _storage.read(key: key, iOptions: legacyOpts);
          if (legacyValue != null) {
            try {
              await _storage.delete(key: key, iOptions: legacyOpts);
              await _storage.write(key: key, value: legacyValue);
            } catch (_) {
              // Keep returning the value even if in-place migration cannot complete yet.
            }
            return legacyValue;
          }
        } catch (_) {
          // Ignore probe errors for non-matching legacy accessibility buckets.
        }
      }
    }
    return null;
  }

  @override
  Future<void> write(String key, String value) async {
    try {
      await _storage.write(key: key, value: value);
      return;
    } catch (_) {
      // On iOS, flutter_secure_storage queries `kSecAttrAccessible` when checking
      // existence, so updating an item previously saved under `unlocked` fails
      // SecItemAdd with errSecDuplicateItem (-25299) until the legacy item is deleted.
      if (!kIsWeb && defaultTargetPlatform == TargetPlatform.iOS) {
        await _deleteLegacyIosEntries(key);
        await _storage.write(key: key, value: value);
        return;
      }
      if (!kIsWeb && defaultTargetPlatform == TargetPlatform.macOS && kReleaseMode) {
        await _storage.write(key: key, value: value, mOptions: _macosFallbackOptions);
        return;
      }
      rethrow;
    }
  }

  @override
  Future<void> delete(String key) async {
    try {
      await _storage.delete(key: key);
    } catch (_) {
      if (!kIsWeb && defaultTargetPlatform == TargetPlatform.macOS) {
        await _storage.delete(key: key, mOptions: _macosFallbackOptions);
      }
    }
    if (!kIsWeb && defaultTargetPlatform == TargetPlatform.iOS) {
      await _deleteLegacyIosEntries(key);
    }
  }

  Future<void> _deleteLegacyIosEntries(String key) async {
    for (final acc in _legacyIosAccessibilities) {
      try {
        await _storage.delete(key: key, iOptions: IOSOptions(accessibility: acc));
      } catch (_) {
        // Best-effort cleanup of older accessibility entries.
      }
    }
  }
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
