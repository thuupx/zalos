import 'dart:async';

import 'package:flutter/foundation.dart';

import '../domain/models.dart';
import '../domain/services.dart';
import '../noise/noise.dart';
import 'key_store.dart';
import 'pairing.dart';
import 'server_link.dart';
import 'vault.dart';

Future<ZalosApp> createZalosApp() async {
  await RustLib.init();
  return RealZalosApp.open(const SecureKeyStore());
}

class RealZalosApp implements ZalosApp {
  RealZalosApp._(this._keyStore);

  /// Restores a previously paired server from [keyStore]. The caller must
  /// have initialised the Rust library already.
  static Future<RealZalosApp> open(KeyStore keyStore) async {
    final app = RealZalosApp._(keyStore);
    Credentials? credentials;
    try {
      credentials = await Credentials.load(keyStore);
    } catch (_) {
      credentials = null;
    }
    if (credentials != null) app._attach(credentials);
    return app;
  }

  static const Duration _vaultSettleTimeout = Duration(seconds: 10);

  final KeyStore _keyStore;
  final ValueNotifier<RealServerLink?> _link = ValueNotifier(null);
  final ValueNotifier<VaultState> _vault = ValueNotifier(VaultState.needsApproval);
  VaultController? _controller;

  @override
  ValueListenable<ServerLink?> get link => _link;

  @override
  ValueListenable<VaultState> get vault => _vault;

  @override
  String get boxFingerprint => _controller?.boxFingerprint ?? '';

  RealServerLink _attach(Credentials credentials) {
    _detach();
    final controller = VaultController(credentials, _keyStore);
    _controller = controller;
    controller.root.addListener(_onRoot);
    _onRoot();
    final link = RealServerLink(controller);
    _link.value = link;
    return link;
  }

  void _detach() {
    final previous = _link.value;
    _controller?.root.removeListener(_onRoot);
    _controller = null;
    _link.value = null;
    _vault.value = VaultState.needsApproval;
    previous?.dispose();
  }

  void _onRoot() {
    _vault.value = _controller?.isReady == true ? VaultState.ready : VaultState.needsApproval;
  }

  @override
  Future<void> pair(String uri, {required String deviceName}) async {
    final credentials = await runPairing(uri, deviceName: deviceName);
    try {
      await credentials.save(_keyStore);
    } catch (_) {
      throw const PairingException(
        'Could not save the device keys on this device.',
        code: PairingErrorCode.storage,
      );
    }
    final link = _attach(credentials);
    // Lets the first device claim the vault before the caller looks at
    // [vault], so it does not briefly report needsApproval.
    try {
      await link.vaultSettled.timeout(_vaultSettleTimeout);
    } on TimeoutException {
      // The link keeps trying on every connect.
    }
  }

  @override
  Future<void> unpair() async {
    _detach();
    await _keyStore.delete(Credentials.storageKey);
  }

  @override
  Future<String> exportRecoveryCode() async {
    final root = _controller?.root.value;
    if (root == null) throw const VaultNotReadyException();
    return encodeRecoveryCode(root);
  }

  @override
  Future<void> requestVaultApproval() async {
    await _link.value?.requestVaultApproval();
  }

  @override
  Future<void> importRecoveryCode(String code) async {
    final root = decodeRecoveryCode(code);
    final controller = _controller;
    final link = _link.value;
    if (controller == null || link == null) throw StateError('No server is paired.');
    if (!link.rootMatchesAccounts(root)) {
      throw const FormatException('This recovery code belongs to a different vault.');
    }
    await controller.setRoot(root);
  }

  void dispose() => _detach();
}
