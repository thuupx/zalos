import 'dart:async';
import 'dart:convert';

import 'package:flutter/foundation.dart';

import '../domain/models.dart';
import '../domain/services.dart';
import '../rust_lib/api/vault.dart' as rust;
import 'account_session.dart';
import 'key_store.dart';
import 'mapping.dart';
import 'pairing.dart';
import 'protocol/managed_channel.dart';
import 'protocol/noise_channel.dart';
import 'vault.dart';

class RealServerLink implements ServerLink, WakeableLink {
  RealServerLink(this.vault) {
    if (vault.isReady) _vaultSettled.complete();
    vault.root.addListener(_onRoot);
    _channel = ManagedChannel(
      keys: credentials.channelKeys,
      path: '/v1/control',
      prologue: 'zalos/1/control',
      onConnected: _onConnected,
      onEvent: _onEvent,
      onDisconnected: _onDisconnected,
    );
    _channel.state.addListener(_onState);
    _channel.start();
  }

  final VaultController vault;
  late final ManagedChannel _channel;
  final ValueNotifier<Manifest?> _manifest = ValueNotifier(null);
  final ValueNotifier<List<VaultRequest>> _vaultRequests = ValueNotifier(const []);
  final ValueNotifier<bool> _vaultRejected = ValueNotifier(false);
  final Map<String, RealAccountSession> _sessions = {};
  final Map<String, String?> _vaultKeys = {};
  final Map<String, Uint8List> _requestKeys = {};
  final Completer<void> _vaultSettled = Completer<void>();
  NoiseChannel? _live;
  _LoginQr? _login;
  Future<void> _vaultWork = Future<void>.value();
  bool _claimLost = false;
  bool _requested = false;
  bool _manifestLoading = false;
  bool _manifestStale = false;
  bool _disposed = false;

  /// Test seam: invoked inside the vault.setKey call window so tests can
  /// race another key into the slot deterministically.
  static Future<void> Function(RealServerLink link, String slot)? debugBeforeSetKey;

  Credentials get credentials => vault.credentials;

  /// Completes once this device either holds the root or has asked for it.
  Future<void> get vaultSettled => _vaultSettled.future;

  @override
  ValueListenable<LinkState> get state => _channel.state;

  @override
  ValueListenable<Manifest?> get manifest => _manifest;

  @override
  ValueListenable<List<VaultRequest>> get vaultRequests => _vaultRequests;

  Future<void> _onConnected(NoiseChannel channel) async {
    _live = channel;
    _requested = false;
    _applyManifest(await channel.request('manifest.get'));
  }

  void _applyManifest(Object? result) {
    if (_disposed) return;
    final json = asJson(result);
    final manifest = manifestFromJson(json);
    _vaultKeys
      ..clear()
      ..addEntries([
        for (final account in asJsonList(json['accounts'])) MapEntry('${account['slot']}', vaultKeyFromJson(account)),
      ]);
    _manifest.value = manifest;
    final visible = {for (final account in manifest.accounts) account.slot};
    for (final slot in _sessions.keys.toList()) {
      if (!visible.contains(slot)) _sessions.remove(slot)?.dispose();
    }
    _scheduleVault();
  }

  Future<void> _reloadManifest() async {
    if (_manifestLoading) {
      _manifestStale = true;
      return;
    }
    _manifestLoading = true;
    try {
      do {
        _manifestStale = false;
        _applyManifest(await _channel.request('manifest.get'));
      } while (_manifestStale && !_disposed);
    } catch (_) {
      // The next connect loads the manifest again.
    } finally {
      _manifestLoading = false;
    }
  }

  void _onEvent(ChannelEvent event) {
    switch (event.name) {
      case 'manifest.changed':
        unawaited(_reloadManifest());
      case 'vault.granted':
      case 'vault.requested':
        _scheduleVault();
      case 'vault.rejected':
        _vaultRejected.value = true;
      case 'loginQr.image':
      case 'loginQr.scanned':
      case 'loginQr.done':
      case 'loginQr.failed':
        _login?.handle(event, _live);
    }
  }

  void _onDisconnected() {
    _live = null;
    _login?.fail('Connection to the server was lost.');
    _login = null;
  }

  void _onState() {
    if (_channel.state.value == LinkState.unauthorized) {
      for (final session in _sessions.values) {
        session.dispose(unauthorized: true);
      }
    }
  }

  void _onRoot() {
    if (vault.isReady) {
      _vaultRejected.value = false;
      if (!_vaultSettled.isCompleted) _vaultSettled.complete();
    }
    _scheduleVault();
  }

  // ---- vault ----

  // Vault steps run one at a time; each run looks at the current state, so
  // coalescing triggers is safe.
  void _scheduleVault() {
    _vaultWork = _vaultWork.then((_) async {
      if (_disposed) return;
      try {
        // A held root that contradicts a visible account key (a stale
        // pairing-uri root or a wrong recovery code) is discarded; the
        // device falls back to the approval request.
        final held = vault.root.value;
        if (held != null && !rootMatchesAccounts(held)) {
          await vault.clearRoot(held);
          _claimLost = true;
        }
        if (!vault.isReady) await _obtainRoot();
        if (vault.isReady) await _uploadKeys();
      } catch (_) {
        // Retried on the next manifest change or connect.
      } finally {
        try {
          await _loadVaultRequests();
        } catch (_) {
          // The next manifest change or connect retries the request list.
        }
      }
    });
  }

  Future<void> _obtainRoot() async {
    if (credentials.boxPublicKey.isEmpty) return;
    if (!_claimLost && _manifest.value?.role == DeviceRole.admin) {
      // The candidate root is persisted BEFORE claiming so a crash cannot
      // burn the vault flag while leaving nothing stored. It only becomes
      // live (and the vault "ready") once the claim succeeds.
      var candidate = vault.root.value ?? vault.pendingRoot;
      candidate ??= Uint8List.fromList(rust.generateRoot());
      await vault.persistRoot(candidate);
      final claim = asJson(await _channel.request('vault.claim'));
      if (claim['claimed'] == true) {
        await vault.setRoot(candidate);
        return;
      }
      // Lost the race: the candidate cannot open this vault, discard it.
      await vault.discardRoot(candidate);
      _claimLost = true;
    }
    final fetched = asJson(await _channel.request('vault.fetch'));
    final wrapped = fetched['wrapped'];
    if (wrapped is String && wrapped.isNotEmpty) {
      final root = vault.unwrapRoot(wrapped);
      if (root != null && rootMatchesAccounts(root)) {
        await vault.setRoot(root);
        return;
      }
      _requested = false;
    }
    // Asked once per connection; later runs only poll for the grant.
    if (!_requested) {
      await _channel.request('vault.request');
      _requested = true;
    }
    if (!_vaultSettled.isCompleted) _vaultSettled.complete();
  }

  Future<void> _uploadKeys() async {
    for (final entry in _vaultKeys.entries.toList()) {
      if (entry.value != null) continue;
      final publicKey = vault.publicKeyFor(entry.key);
      try {
        final hook = RealServerLink.debugBeforeSetKey;
        if (hook != null) await hook(this, entry.key);
        await _channel.request('vault.setKey', {'slot': entry.key, 'publicKey': publicKey});
        _vaultKeys[entry.key] = publicKey;
      } on RpcException catch (e) {
        // conflict: another device set a different key first. If our root
        // cannot produce it the device is not "ready" for this vault, so
        // drop the root and fall back to the approval request.
        if (e.code == 'conflict') {
          // Refresh the manifest first so the account's stored key is
          // visible for the comparison.
          await _reloadManifest();
          final held = vault.root.value;
          if (held != null && !rootMatchesAccounts(held)) {
            await vault.clearRoot(held);
            _claimLost = true;
          }
        }
      }
    }
  }

  Future<void> refreshVaultRequests() => _loadVaultRequests();

  Future<void> _loadVaultRequests() async {
    if (_manifest.value?.role != DeviceRole.admin) {
      if (_vaultRequests.value.isNotEmpty) _vaultRequests.value = const [];
      return;
    }
    final result = asJson(await _channel.request('vault.requests.list'));
    final requests = <VaultRequest>[];
    _requestKeys.clear();
    for (final item in asJsonList(result['requests'])) {
      final Uint8List boxKey;
      try {
        boxKey = base64Decode(base64.normalize('${item['boxPublicKey']}'));
      } catch (_) {
        continue;
      }
      if (boxKey.length != 32) continue;
      final deviceId = '${item['deviceId']}';
      final requestedAt = item['requestedAt'];
      _requestKeys[deviceId] = boxKey;
      requests.add(VaultRequest(
        deviceId: deviceId,
        name: '${item['name'] ?? ''}',
        // Computed here, not taken from the server: this is what the user
        // compares before approving.
        fingerprint: rust.fingerprint(publicKey: boxKey),
        requestedAt: requestedAt is num ? requestedAt.toInt() : 0,
      ));
    }
    if (!_disposed) _vaultRequests.value = List.unmodifiable(requests);
  }

  /// False when an account already has a vault key that [root] does not
  /// derive. True when nothing contradicts it.
  bool rootMatchesAccounts(List<int> root) {
    for (final entry in _vaultKeys.entries) {
      final expected = entry.value;
      if (expected == null) continue;
      final Uint8List derived;
      try {
        derived = rust.derivePublicKey(root: root, slot: entry.key);
      } catch (_) {
        return false;
      }
      if (base64Encode(derived) != base64.normalize(expected)) return false;
    }
    return true;
  }

  @override
  Future<void> approveVaultRequest(VaultRequest request) async {
    final boxKey = _requestKeys[request.deviceId];
    if (boxKey == null || rust.fingerprint(publicKey: boxKey) != request.fingerprint) {
      throw StateError('This vault request is no longer pending.');
    }
    final wrapped = vault.wrapRootFor(request.deviceId, boxKey);
    await _channel.request('vault.grant', {'deviceId': request.deviceId, 'wrapped': wrapped});
    _scheduleVault();
  }

  @override
  ValueListenable<bool> get vaultRejected => _vaultRejected;

  @override
  Future<void> rejectVaultRequest(VaultRequest request) async {
    await _channel.request('vault.reject', {'deviceId': request.deviceId});
    _requestKeys.remove(request.deviceId);
    _vaultRequests.value = [
      for (final r in _vaultRequests.value)
        if (r.deviceId != request.deviceId) r,
    ];
  }

  /// Clears the rejected flag and sends a fresh request on the next vault
  /// pass. Kept pending (`_requested` stays true after a rejection) so the
  /// request only goes out when the user asks for it.
  Future<void> requestVaultApproval() async {
    _vaultRejected.value = false;
    _requested = true;
    await _channel.request('vault.request');
    _scheduleVault();
  }

  // ---- accounts and devices ----

  @override
  AccountSession account(String slot) =>
      _sessions.putIfAbsent(slot, () => RealAccountSession(slot, credentials.channelKeys, vault));

  @override
  Future<List<DeviceInfo>> listDevices() async {
    final result = asJson(await _channel.request('devices.list'));
    return [for (final item in asJsonList(result['devices'])) deviceInfoFromJson(item)];
  }

  @override
  Future<void> revokeDevice(String deviceId) async {
    await _channel.request('devices.revoke', {'deviceId': deviceId});
  }

  @override
  Future<void> setDeviceAcl(String deviceId, List<String> slots) async {
    await _channel.request('devices.setAcl', {'deviceId': deviceId, 'slots': slots});
  }

  @override
  Future<PairingOffer> createPairing({required DeviceRole role}) async {
    final result = asJson(await _channel.request('pairing.create', {'role': deviceRoleToWire(role)}));
    final offer = pairingOfferFromJson(result);
    final root = vault.root.value;
    if (root == null) return offer;
    // Added locally: the root goes from this screen to the other camera and
    // never through the server. Re-encode cleanly into the base64 pairing URI.
    return PairingOffer(uri: withPairingVault(offer.uri, root), expiresAt: offer.expiresAt);
  }

  @override
  Stream<LoginQrEvent> startLoginQr() {
    _login?.fail('Another login was started.');
    final login = _LoginQr();
    _login = login;
    login.controller.onCancel = () {
      if (identical(_login, login)) _login = null;
    };
    // The request only returns once the whole login has finished.
    _channel.request('accounts.loginQr.start', const {}, null).then((_) {
      login.finish();
    }, onError: (Object error) {
      login.fail(error is RpcException ? error.message : 'Could not start the login.');
    }).whenComplete(() {
      if (identical(_login, login)) _login = null;
    });
    return login.controller.stream;
  }

  @override
  Future<void> removeAccount(String slot) async {
    await _channel.request('accounts.remove', {'slot': slot});
  }

  @override
  Future<String> addOaAccount(OaCredentials credentials) async {
    final result = asJson(await _channel.request('accounts.addOa', {
      'appId': credentials.appId,
      'appSecret': credentials.appSecret,
      'accessToken': credentials.accessToken,
      'refreshToken': credentials.refreshToken,
    }));
    return '${result['slot']}';
  }

  @override
  Future<void> updateOaTokens(String slot, {required String accessToken, required String refreshToken}) async {
    await _channel.request('accounts.updateOaTokens', {
      'slot': slot,
      'accessToken': accessToken,
      'refreshToken': refreshToken,
    });
  }

  @override
  void wake() {
    if (_disposed) return;
    unawaited(_channel.wake(probe: (ch) async {
      final result = await ch.request('manifest.get');
      _applyManifest(result);
    }));
    for (final session in _sessions.values) {
      session.wake();
    }
  }

  void dispose() {
    if (_disposed) return;
    _disposed = true;
    vault.root.removeListener(_onRoot);
    _channel.state.removeListener(_onState);
    _login?.fail('Disconnected.');
    _login = null;
    for (final session in _sessions.values) {
      session.dispose();
    }
    _sessions.clear();
    _channel.dispose();
  }
}

class _LoginQr {
  final StreamController<LoginQrEvent> controller = StreamController<LoginQrEvent>();
  Future<void> _queue = Future<void>.value();
  bool _ended = false;

  void handle(ChannelEvent event, NoiseChannel? channel) {
    _queue = _queue.then((_) async {
      if (_ended) return;
      switch (event.name) {
        case 'loginQr.image':
          final stream = event.data['stream'];
          if (stream is! num || channel == null) return;
          try {
            final png = await channel.receiveBlob(stream.toInt());
            if (!_ended) controller.add(LoginQrImage(png));
          } catch (_) {
            _end(const LoginQrFailed('Could not load the QR image.'));
          }
        case 'loginQr.scanned':
          controller.add(LoginQrScanned('${event.data['displayName'] ?? ''}'));
        case 'loginQr.done':
          _end(LoginQrDone('${event.data['slot'] ?? ''}'));
        case 'loginQr.failed':
          _end(LoginQrFailed('${event.data['reason'] ?? 'failed'}'));
      }
    });
  }

  void _end(LoginQrEvent? last) {
    if (_ended) return;
    _ended = true;
    if (last != null) controller.add(last);
    unawaited(controller.close());
  }

  void finish() => _queue = _queue.then((_) => _end(null));

  void fail(String reason) => _queue = _queue.then((_) => _end(LoginQrFailed(reason)));
}
