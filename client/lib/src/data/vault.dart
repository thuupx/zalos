import 'dart:convert';
import 'dart:typed_data';

import 'package:flutter/foundation.dart';

import '../rust_lib/api/vault.dart' as rust;
import 'key_store.dart';
import 'mapping.dart';

const int vaultRootLength = 32;
const int _mediaChunk = 1024 * 1024;
const int _mediaTag = 16;
const int _mediaHeader = 32;
const String _base32 = 'ABCDEFGHIJKLMNOPQRSTUVWXYZ234567';

/// Thrown when sealed data is requested before this device holds the root.
class VaultNotReadyException implements Exception {
  const VaultNotReadyException();
  @override
  String toString() => 'The vault is not ready on this device, so stored data cannot be opened yet.';
}

/// Thrown when sealed data does not open with this device's root.
class VaultOpenException implements Exception {
  const VaultOpenException(this.message);
  final String message;
  @override
  String toString() => 'Could not open sealed data: $message';
}

/// The root as base32 in dash separated groups of four.
String encodeRecoveryCode(List<int> root) {
  final out = StringBuffer();
  var buffer = 0;
  var bits = 0;
  var count = 0;
  void emit(int index) {
    if (count > 0 && count % 4 == 0) out.write('-');
    out.write(_base32[index]);
    count++;
  }

  for (final byte in root) {
    buffer = (buffer << 8) | byte;
    bits += 8;
    while (bits >= 5) {
      bits -= 5;
      emit((buffer >> bits) & 31);
    }
    buffer &= (1 << bits) - 1;
  }
  if (bits > 0) emit((buffer << (5 - bits)) & 31);
  return out.toString();
}

/// Inverse of [encodeRecoveryCode]. Ignores case, spaces and dashes.
Uint8List decodeRecoveryCode(String code) {
  final out = BytesBuilder();
  var buffer = 0;
  var bits = 0;
  var symbols = 0;
  for (final rune in code.toUpperCase().runes) {
    final char = String.fromCharCode(rune);
    if (char == '-' || char.trim().isEmpty) continue;
    final index = _base32.indexOf(char);
    if (index < 0) throw const FormatException('The recovery code contains an invalid character.');
    symbols++;
    buffer = (buffer << 5) | index;
    bits += 5;
    if (bits >= 8) {
      bits -= 8;
      out.addByte((buffer >> bits) & 0xff);
      buffer &= (1 << bits) - 1;
    }
  }
  final bytes = out.takeBytes();
  if (bytes.length != vaultRootLength || symbols != 52 || buffer != 0) {
    throw const FormatException('The recovery code has the wrong length.');
  }
  return bytes;
}

/// Opens a sealed media blob: `header(32) || chunks`, each chunk up to 1 MiB
/// of plaintext plus a 16 byte tag. [size] is the plaintext size announced by
/// the server; it is bound into the aad and checked against the result.
Future<Uint8List> openSealedMedia({
  required List<int> root,
  required String slot,
  required String url,
  required int size,
  required Uint8List blob,
}) async {
  if (blob.length < _mediaHeader) throw const VaultOpenException('media is truncated');
  final hash = rust.sha256Hex(data: utf8.encode(url));
  final aad = utf8.encode('zalos/1/media/$slot/$hash/$size');
  final out = BytesBuilder(copy: false);
  try {
    final opener = await rust.FileOpener.withRoot(
      root: root,
      slot: slot,
      aad: aad,
      header: Uint8List.sublistView(blob, 0, _mediaHeader),
    );
    const step = _mediaChunk + _mediaTag;
    for (var offset = _mediaHeader; offset < blob.length; offset += step) {
      final end = offset + step < blob.length ? offset + step : blob.length;
      out.add(await opener.openChunk(chunk: Uint8List.sublistView(blob, offset, end)));
    }
  } catch (e) {
    throw VaultOpenException('$e');
  }
  if (out.length != size) throw const VaultOpenException('media size does not match');
  return out.takeBytes();
}

/// Holds the vault root of one pairing and persists it with the credentials.
class VaultController {
  VaultController(this._credentials, this._keyStore) : root = ValueNotifier(_credentials.vaultRoot);

  Credentials _credentials;
  final KeyStore _keyStore;

  /// Null until this device holds the root. Notifies when it arrives.
  final ValueNotifier<Uint8List?> root;

  Credentials get credentials => _credentials;
  bool get isReady => root.value != null;

  String get boxFingerprint =>
      _credentials.boxPublicKey.isEmpty ? '' : rust.fingerprint(publicKey: _credentials.boxPublicKey);

  Future<void> setRoot(Uint8List value) async {
    if (value.length != vaultRootLength) throw const FormatException('The vault root has the wrong length.');
    _credentials = _credentials.withVaultRoot(value);
    await _credentials.save(_keyStore);
    root.value = value;
  }

  /// Drops [expected] when it is the current root: a lost vault.claim race
  /// or a mismatched root must not stay usable.
  Future<void> clearRoot(Uint8List expected) async {
    if (root.value == null || !listEquals(root.value, expected)) return;
    _credentials = _credentials.withoutVaultRoot();
    await _credentials.save(_keyStore);
    root.value = null;
  }

  /// A persisted candidate that was never adopted: present in the stored
  /// credentials but not yet live as [root].
  Uint8List? get pendingRoot => root.value == null ? _credentials.vaultRoot : null;

  /// Saves [value] as the vault.claim candidate without marking the vault
  /// ready: the claim must not resolve before the root is on disk.
  Future<void> persistRoot(Uint8List value) async {
    if (value.length != vaultRootLength) throw const FormatException('The vault root has the wrong length.');
    _credentials = _credentials.withVaultRoot(value);
    await _credentials.save(_keyStore);
  }

  /// Drops a persisted candidate that lost the claim or was rejected,
  /// regardless of whether it was adopted yet.
  Future<void> discardRoot(Uint8List expected) async {
    if (!listEquals(_credentials.vaultRoot, expected)) return;
    _credentials = _credentials.withoutVaultRoot();
    await _credentials.save(_keyStore);
    if (listEquals(root.value, expected)) root.value = null;
  }

  String publicKeyFor(String slot) {
    final value = root.value;
    if (value == null) throw const VaultNotReadyException();
    return base64Encode(rust.derivePublicKey(root: value, slot: slot));
  }

  /// Body of a sealed message record, or null when it cannot be opened.
  Json? openRecord(String slot, String msgId, String sealed) {
    final value = root.value;
    if (value == null) return null;
    try {
      final plain = rust.openWithRoot(
        root: value,
        slot: slot,
        aad: utf8.encode('zalos/1/msg/$slot/$msgId'),
        sealed: base64Decode(base64.normalize(sealed)),
      );
      final decoded = jsonDecode(utf8.decode(plain));
      return decoded is Map ? asJson(decoded) : null;
    } catch (_) {
      return null;
    }
  }

  /// Wraps the root for another device's box key.
  String wrapRootFor(String deviceId, List<int> boxPublicKey) {
    final value = root.value;
    if (value == null) throw const VaultNotReadyException();
    return base64Encode(rust.seal(
      publicKey: boxPublicKey,
      aad: utf8.encode('zalos/1/root/$deviceId'),
      plaintext: value,
    ));
  }

  /// Opens a root wrapped for this device. Null when it does not open.
  Uint8List? unwrapRoot(String wrapped) {
    try {
      final plain = rust.openWithPrivate(
        privateKey: _credentials.boxPrivateKey,
        aad: utf8.encode('zalos/1/root/${_credentials.deviceId}'),
        sealed: base64Decode(base64.normalize(wrapped)),
      );
      return plain.length == vaultRootLength ? plain : null;
    } catch (_) {
      return null;
    }
  }
}
