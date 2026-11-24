import 'dart:async';
import 'dart:ui';

import 'package:flutter/scheduler.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../domain/models.dart';
import '../../domain/services.dart';
import '../l10n/strings.dart';
import '../platform/services.dart';
import '../util/format.dart';
import 'app_state.dart';

final stringsProvider = Provider<S>((ref) {
  final language = ref.watch(languageProvider) ?? (PlatformDispatcher.instance.locale.languageCode == 'en' ? 'en' : 'vi');
  return S(language);
});

/// Whether the chat of the visible thread is actually on screen. The compact
/// shell clears it while another page covers the chat.
final chatOnScreenProvider = StateProvider<bool>((ref) => true);

/// Raises system notifications for new incoming messages and keeps the unread
/// badge and title in sync. Only runs while the app runs.
class NotificationCoordinator {
  NotificationCoordinator(this._ref) {
    _startedAt = ZClock.nowMs();
    _linkSub = _ref.listen<ServerLink?>(linkProvider, (_, link) => _attachLink(link), fireImmediately: true);
    _manifestSub = _ref.listen<Manifest?>(manifestProvider, (_, manifest) => _onManifest(manifest), fireImmediately: true);
    _activationSub = _ref.read(platformProvider).notifications.activations.listen(_onActivated);
  }

  final Ref _ref;
  late final int _startedAt;
  late final ProviderSubscription<ServerLink?> _linkSub;
  late final ProviderSubscription<Manifest?> _manifestSub;
  StreamSubscription<String>? _activationSub;
  final Map<String, VoidCallback> _detach = {};
  final Map<String, Map<String, String>> _lastIds = {};
  ServerLink? _link;
  int _lastUnread = -1;

  void _attachLink(ServerLink? link) {
    _link = link;
    for (final d in _detach.values) {
      d();
    }
    _detach.clear();
    _lastIds.clear();
    _onManifest(link?.manifest.value);
  }

  void _onManifest(Manifest? manifest) {
    final link = _link;
    final accounts = manifest?.accounts ?? const <AccountSummary>[];
    final total = accounts.fold<int>(0, (n, a) => n + a.unread);
    if (total != _lastUnread) {
      _lastUnread = total;
      _ref.read(platformProvider).notifications.setUnread(total);
    }
    if (link == null) return;
    final slots = {for (final a in accounts) a.slot};
    for (final slot in _detach.keys.toList()) {
      if (!slots.contains(slot)) _detach.remove(slot)!();
    }
    for (final a in accounts) {
      if (_detach.containsKey(a.slot)) continue;
      final session = link.account(a.slot);
      final known = _lastIds.putIfAbsent(a.slot, () => {});
      for (final t in session.threads.value) {
        final id = t.lastMessage?.id;
        if (id != null) known[t.id] = id;
      }
      void listener() => _onThreads(a.slot, session);
      session.threads.addListener(listener);
      _detach[a.slot] = () => session.threads.removeListener(listener);
    }
  }

  bool get _appFocused {
    final state = SchedulerBinding.instance.lifecycleState;
    return state == null || state == AppLifecycleState.resumed;
  }

  void _onThreads(String slot, AccountSession session) {
    final known = _lastIds.putIfAbsent(slot, () => {});
    for (final t in session.threads.value) {
      final m = t.lastMessage;
      if (m == null) continue;
      final previous = known[t.id];
      if (previous == m.id) continue;
      known[t.id] = m.id;
      if (m.isSelf || m.kind == MessageKind.system || m.ts < _startedAt || t.muted || t.unread <= 0) continue;
      final visible = _ref.read(visibleThreadProvider);
      final watching = visible != null && visible.slot == slot && visible.id == t.id && _appFocused && _ref.read(chatOnScreenProvider);
      if (watching) continue;
      _notify(slot, t, m);
    }
  }

  Future<void> _notify(String slot, Thread t, Message m) async {
    if (!_ref.read(notifyEnabledProvider)) return;
    final gateway = _ref.read(platformProvider).notifications;
    final s = _ref.read(stringsProvider);
    final preview = _ref.read(notifyPreviewProvider);
    var body = s.t('notifyNewMessage');
    if (preview) {
      final summary = messageSummary(m, s);
      body = t.type == ThreadType.group && m.senderName.isNotEmpty ? '${shortName(m.senderName)}: $summary' : summary;
    }
    final payload = '$slot|${t.type.name}|${t.id}';
    await gateway.show(id: payload.hashCode & 0x7fffffff, title: t.name, body: body, payload: payload);
  }

  void _onActivated(String payload) {
    final parts = payload.split('|');
    if (parts.length < 3) return;
    final link = _link;
    if (link == null) return;
    final slot = parts[0];
    final type = parts[1] == ThreadType.group.name ? ThreadType.group : ThreadType.user;
    final id = parts.sublist(2).join('|');
    final manifest = link.manifest.value;
    if (manifest == null || !manifest.accounts.any((a) => a.slot == slot)) return;
    Thread? thread;
    for (final t in link.account(slot).threads.value) {
      if (t.id == id && t.type == type) thread = t;
    }
    _ref.read(preferredSlotProvider.notifier).set(slot);
    _ref.read(homeTabProvider.notifier).state = HomeTab.messages;
    _ref.read(openThreadProvider.notifier).state =
        OpenThread(slot: slot, id: id, type: type, name: thread?.name ?? '', avatarUrl: thread?.avatarUrl ?? '');
  }

  void dispose() {
    _linkSub.close();
    _manifestSub.close();
    _activationSub?.cancel();
    for (final d in _detach.values) {
      d();
    }
    _detach.clear();
  }
}

final notificationCoordinatorProvider = Provider<NotificationCoordinator>((ref) {
  final c = NotificationCoordinator(ref);
  ref.onDispose(c.dispose);
  return c;
});
