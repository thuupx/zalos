import 'package:flutter/foundation.dart';
import 'package:material_ui/material_ui.dart';
import 'package:flutter/scheduler.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../../domain/models.dart';
import '../../domain/services.dart';

/// Overridden in main() and in tests.
final sharedPrefsProvider = Provider<SharedPreferences>((ref) => throw UnimplementedError('sharedPrefsProvider'));

class _Tick extends AutoDisposeFamilyNotifier<int, Listenable> {
  bool _alive = true;

  @override
  int build(Listenable arg) {
    _alive = true;
    arg.addListener(_bump);
    ref.onDispose(() {
      _alive = false;
      arg.removeListener(_bump);
    });
    return 0;
  }

  void _bump() {
    final phase = SchedulerBinding.instance.schedulerPhase;
    if (phase == SchedulerPhase.persistentCallbacks) {
      SchedulerBinding.instance.addPostFrameCallback((_) {
        if (_alive) state = state + 1;
      });
      SchedulerBinding.instance.ensureVisualUpdate();
    } else {
      state = state + 1;
    }
  }
}

final _tickProvider = NotifierProvider.autoDispose.family<_Tick, int, Listenable>(_Tick.new);

/// Bridges the contract's listenables into Riverpod rebuilds. A notification
/// always rebuilds the watcher, whether or not the value object changed.
extension ListenableWidgetRef on WidgetRef {
  T watchL<T>(ValueListenable<T> listenable) {
    watch(_tickProvider(listenable));
    return listenable.value;
  }

  void watchNotifier(Listenable listenable) => watch(_tickProvider(listenable));
}

T _watchL<T>(Ref ref, ValueListenable<T> listenable) {
  ref.watch(_tickProvider(listenable));
  return listenable.value;
}

final linkProvider = Provider<ServerLink?>((ref) => _watchL(ref, ref.watch(zalosAppProvider).link));

final vaultStateProvider = Provider<VaultState>((ref) => _watchL(ref, ref.watch(zalosAppProvider).vault));

final manifestProvider = Provider<Manifest?>((ref) {
  final link = ref.watch(linkProvider);
  return link == null ? null : _watchL(ref, link.manifest);
});

final linkStateProvider = Provider<LinkState>((ref) {
  final link = ref.watch(linkProvider);
  return link == null ? LinkState.disconnected : _watchL(ref, link.state);
});

final vaultRequestsProvider = Provider<List<VaultRequest>>((ref) {
  final link = ref.watch(linkProvider);
  return link == null ? const [] : _watchL(ref, link.vaultRequests);
});

final vaultRejectedProvider = Provider<bool>((ref) {
  final link = ref.watch(linkProvider);
  return link == null ? false : _watchL(ref, link.vaultRejected);
});

class PrefController<T> extends StateNotifier<T> {
  PrefController(this._prefs, this._key, T initial, this._encode) : super(initial);
  final SharedPreferences _prefs;
  final String _key;
  final String? Function(T value) _encode;

  void set(T value) {
    state = value;
    final encoded = _encode(value);
    if (encoded == null) {
      _prefs.remove(_key);
    } else {
      _prefs.setString(_key, encoded);
    }
  }
}

final themeModeProvider = StateNotifierProvider<PrefController<ThemeMode>, ThemeMode>((ref) {
  final prefs = ref.watch(sharedPrefsProvider);
  final initial = switch (prefs.getString('theme_mode')) {
    'light' => ThemeMode.light,
    'dark' => ThemeMode.dark,
    _ => ThemeMode.system,
  };
  return PrefController(prefs, 'theme_mode', initial, (m) => m == ThemeMode.system ? null : m.name);
});

/// Null follows the system language.
final languageProvider = StateNotifierProvider<PrefController<String?>, String?>((ref) {
  final prefs = ref.watch(sharedPrefsProvider);
  return PrefController(prefs, 'language', prefs.getString('language'), (v) => v);
});

final preferredSlotProvider = StateNotifierProvider<PrefController<String?>, String?>((ref) {
  final prefs = ref.watch(sharedPrefsProvider);
  return PrefController(prefs, 'active_slot', prefs.getString('active_slot'), (v) => v);
});

final notifyEnabledProvider = StateNotifierProvider<PrefController<bool>, bool>((ref) {
  final prefs = ref.watch(sharedPrefsProvider);
  // Off until the user switches it on in Me, which is where the system
  // permission is requested.
  return PrefController(prefs, 'notify_enabled', prefs.getString('notify_enabled') == 'on', (v) => v ? 'on' : null);
});

final notifyPreviewProvider = StateNotifierProvider<PrefController<bool>, bool>((ref) {
  final prefs = ref.watch(sharedPrefsProvider);
  return PrefController(prefs, 'notify_preview', prefs.getString('notify_preview') != 'off', (v) => v ? null : 'off');
});

final hapticsEnabledProvider = StateNotifierProvider<PrefController<bool>, bool>((ref) {
  final prefs = ref.watch(sharedPrefsProvider);
  return PrefController(prefs, 'haptics_enabled', prefs.getString('haptics_enabled') != 'off', (v) => v ? null : 'off');
});

String? resolveActiveSlot(Manifest manifest, String? preferred) {
  final accounts = manifest.accounts;
  if (accounts.isEmpty) return null;
  if (preferred != null && accounts.any((a) => a.slot == preferred)) return preferred;
  for (final a in accounts) {
    if (a.status == AccountStatus.online) return a.slot;
  }
  return accounts.first.slot;
}

final activeAccountProvider = Provider<AccountSummary?>((ref) {
  final manifest = ref.watch(manifestProvider);
  if (manifest == null) return null;
  final slot = resolveActiveSlot(manifest, ref.watch(preferredSlotProvider));
  for (final a in manifest.accounts) {
    if (a.slot == slot) return a;
  }
  return null;
});

final activeSessionProvider = Provider<AccountSession?>((ref) {
  final link = ref.watch(linkProvider);
  final slot = ref.watch(activeAccountProvider.select((a) => a?.slot));
  return link == null || slot == null ? null : link.account(slot);
});

/// Capabilities of an account, as reported by the server manifest.
Set<AccountCapability> capsOf(AccountSummary? a) {
  if (a == null) return const {};
  final caps = a.capabilities;
  final key = (caps.map((c) => c.index).toList()..sort()).join(',');
  return _capSets.putIfAbsent(key, () => Set.unmodifiable(caps));
}

// Canonical instances so watchers do not rebuild on every manifest update.
final Map<String, Set<AccountCapability>> _capSets = {};

final activeCapsProvider = Provider<Set<AccountCapability>>((ref) => capsOf(ref.watch(activeAccountProvider)));

final isAdminProvider = Provider<bool>((ref) => ref.watch(manifestProvider.select((m) => m?.role == DeviceRole.admin)));

/// The conversation shown in the chat pane.
@immutable
class OpenThread {
  const OpenThread({required this.slot, required this.id, required this.type, required this.name, required this.avatarUrl});

  final String slot;
  final String id;
  final ThreadType type;
  final String name;
  final String avatarUrl;

  bool get isGroup => type == ThreadType.group;
  String get key => '$slot/${type.name}/$id';

  @override
  bool operator ==(Object other) => other is OpenThread && other.slot == slot && other.id == id && other.type == type;

  @override
  int get hashCode => Object.hash(slot, id, type);
}

final openThreadProvider = StateProvider<OpenThread?>((ref) => null);

/// The open thread, when it belongs to the active account.
final visibleThreadProvider = Provider<OpenThread?>((ref) {
  final open = ref.watch(openThreadProvider);
  final slot = ref.watch(activeAccountProvider.select((a) => a?.slot));
  return open != null && open.slot == slot ? open : null;
});

enum HomeTab { messages, contacts, me }

final homeTabProvider = StateProvider<HomeTab>((ref) => HomeTab.messages);

final infoPaneOpenProvider = StateProvider<bool>((ref) => false);

/// Bumped to ask the conversation list search field to take focus.
final searchFocusRequestProvider = StateProvider<int>((ref) => 0);

/// Bumped to ask the open chat to show its in-conversation search.
final chatSearchRequestProvider = StateProvider<int>((ref) => 0);

void switchAccount(WidgetRef ref, String slot) {
  ref.read(preferredSlotProvider.notifier).set(slot);
  ref.read(openThreadProvider.notifier).state = null;
  ref.read(infoPaneOpenProvider.notifier).state = false;
}

void openThread(WidgetRef ref, OpenThread thread) {
  ref.read(openThreadProvider.notifier).state = thread;
}

void closeThread(WidgetRef ref) {
  ref.read(openThreadProvider.notifier).state = null;
  ref.read(infoPaneOpenProvider.notifier).state = false;
}

OpenThread openThreadOf(String slot, Thread t) => OpenThread(slot: slot, id: t.id, type: t.type, name: t.name, avatarUrl: t.avatarUrl);
