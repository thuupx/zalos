import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:material_ui/material_ui.dart';

import '../../domain/models.dart';
import '../../domain/services.dart';
import '../theme/tokens.dart';
import '../util/style_runs.dart';

@immutable
class PendingAttachment {
  const PendingAttachment({required this.name, required this.bytes, required this.kind});
  final String name;
  final Uint8List bytes;
  final MessageKind kind;
}

/// A mention the user picked, kept with its position so duplicate display
/// names keep their own uid and edits cannot revive a stale token.
@immutable
class MentionPick {
  const MentionPick({required this.name, required this.uid, required this.start});
  final String name;
  final String uid;
  final int start;

  MentionPick shifted(int start) => MentionPick(name: name, uid: uid, start: start);
}

final RegExp _nameChar = RegExp(r'[\p{L}\p{M}\p{N}_]', unicode: true);

bool _isSpace(int codeUnit) => codeUnit == 0x20 || codeUnit == 0x09 || codeUnit == 0x0a || codeUnit == 0x0d;

/// True when [pick] still names a whole token at its recorded position: the
/// `@` starts the text or follows whitespace, and the name is not a prefix
/// of a longer word.
bool _mentionTokenAt(String text, MentionPick pick) {
  final token = '@${pick.name}';
  final start = pick.start;
  if (start < 0 || start + token.length > text.length) return false;
  if (!text.startsWith(token, start)) return false;
  if (start > 0 && !_isSpace(text.codeUnitAt(start - 1))) return false;
  final after = start + token.length;
  return after >= text.length || !_nameChar.hasMatch(text[after]);
}

/// Mentions for the picked occurrences still present in [text]. A shorter
/// pick that overlaps a longer one is dropped, so `@Al` never matches inside
/// a picked `@Alice`.
List<Mention> resolveMentionPicks(String text, Iterable<MentionPick> picks) {
  final candidates = <Mention>[
    for (final pick in picks)
      if (_mentionTokenAt(text, pick)) Mention(uid: pick.uid, pos: pick.start, len: pick.name.length + 1),
  ];
  if (candidates.length < 2) return candidates;
  candidates.sort((a, b) {
    final byPos = a.pos.compareTo(b.pos);
    return byPos != 0 ? byPos : b.len.compareTo(a.len);
  });
  final out = <Mention>[];
  var end = 0;
  for (final candidate in candidates) {
    if (candidate.pos < end) continue;
    out.add(candidate);
    end = candidate.pos + candidate.len;
  }
  return out;
}

/// Composer text that keeps the style runs of the draft in step with edits,
/// and paints them while typing.
class DraftTextController extends TextEditingController {
  List<StyleRun> _runs = const [];

  /// Style runs of the current draft, oldest first.
  List<StyleRun> get runs => _runs;

  void setRuns(List<StyleRun> runs) {
    if (listEquals(_runs, runs)) return;
    _runs = List.unmodifiable(runs);
    notifyListeners();
  }

  @override
  set value(TextEditingValue newValue) {
    if (newValue.text != text) _runs = shiftStyleRuns(_runs, text, newValue.text);
    super.value = newValue;
  }

  @override
  TextSpan buildTextSpan({required BuildContext context, TextStyle? style, required bool withComposing}) {
    if (withComposing && value.composing.isValid && !value.composing.isCollapsed) {
      return super.buildTextSpan(context: context, style: style, withComposing: withComposing);
    }
    final text = this.text;
    if (text.isEmpty || _runs.isEmpty) return TextSpan(style: style, text: text);
    final z = Theme.of(context).extension<ZalosTokens>();
    if (z == null) return TextSpan(style: style, text: text);
    final cuts = <int>{0, text.length};
    for (final run in _runs) {
      if (run.len <= 0) continue;
      cuts.add(run.start.clamp(0, text.length));
      cuts.add((run.start + run.len).clamp(0, text.length));
    }
    final points = cuts.toList()..sort();
    final spans = <InlineSpan>[];
    for (var i = 0; i < points.length - 1; i++) {
      final start = points[i];
      final end = points[i + 1];
      if (end <= start) continue;
      final codes = <String>[
        for (final run in _runs)
          if (run.len > 0 && run.start <= start && run.start + run.len >= end) run.st,
      ];
      spans.add(TextSpan(text: text.substring(start, end), style: applyStyleRuns(style ?? const TextStyle(), codes, z)));
    }
    return TextSpan(style: style, children: spans);
  }
}

/// Per-thread UI state that survives navigation while the app runs: draft
/// text, reply target, pending attachments and the scroll anchor.
class ThreadUi extends ChangeNotifier {
  ThreadUi() {
    input.addListener(_onInput);
  }

  final DraftTextController input = DraftTextController();
  final List<PendingAttachment> _attachments = [];
  final List<MentionPick> _mentionPicks = [];
  String _inputText = '';
  Message? _replyTo;
  String _draft = '';
  MessageUrgency _urgency = MessageUrgency.normal;
  int _ttl = 0;

  /// Mentions picked for the current draft, in the order they were inserted.
  List<MentionPick> get mentionPicks => List.unmodifiable(_mentionPicks);

  void addMentionPick({required String name, required String uid, required int start}) {
    _mentionPicks.add(MentionPick(name: name, uid: uid, start: start));
    notifyListeners();
  }

  /// Saved scroll state: the newest message of the anchored part and the
  /// pixel offset from it.
  String? anchorKey;
  double? scrollOffset;

  String get draft => _draft;
  Message? get replyTo => _replyTo;
  List<PendingAttachment> get attachments => List.unmodifiable(_attachments);

  /// Style runs of the draft text.
  List<StyleRun> get styles => input.runs;
  void setStyles(List<StyleRun> styles) => input.setRuns(styles);

  /// Send options of the draft; both reset with the draft after a send.
  MessageUrgency get urgency => _urgency;
  set urgency(MessageUrgency value) {
    if (_urgency == value) return;
    _urgency = value;
    notifyListeners();
  }

  int get ttl => _ttl;
  set ttl(int value) {
    final next = value < 0 ? 0 : value;
    if (_ttl == next) return;
    _ttl = next;
    notifyListeners();
  }

  void clearDraftOptions() {
    input.setRuns(const []);
    _mentionPicks.clear();
    _urgency = MessageUrgency.normal;
    _ttl = 0;
    notifyListeners();
  }

  set replyTo(Message? value) {
    if (identical(_replyTo, value)) return;
    _replyTo = value;
    notifyListeners();
  }

  void addAttachment(PendingAttachment a) {
    _attachments.add(a);
    notifyListeners();
  }

  void removeAttachmentAt(int index) {
    _attachments.removeAt(index);
    notifyListeners();
  }

  void clearAttachments() {
    if (_attachments.isEmpty) return;
    _attachments.clear();
    notifyListeners();
  }

  void _onInput() {
    final text = input.text;
    if (text != _inputText) {
      if (_mentionPicks.isNotEmpty) {
        for (var i = 0; i < _mentionPicks.length; i++) {
          _mentionPicks[i] = _mentionPicks[i].shifted(shiftTextOffset(_mentionPicks[i].start, _inputText, text));
        }
      }
      _inputText = text;
    }
    final next = text.trim();
    if (next == _draft) return;
    _draft = next;
    notifyListeners();
  }

  @override
  void dispose() {
    input.dispose();
    super.dispose();
  }
}

typedef ThreadUiKey = ({String slot, String id});

final threadUiProvider = Provider.family<ThreadUi, ThreadUiKey>((ref, key) {
  final ui = ThreadUi();
  ref.onDispose(ui.dispose);
  return ui;
});

/// Who is typing in each thread of one account, expiring after a few seconds.
class TypingTracker {
  TypingTracker(AccountSession session) {
    _sub = session.typing.listen(_onEvent, onError: (Object _) {});
  }

  static const Duration ttl = Duration(seconds: 6);

  StreamSubscription<TypingEvent>? _sub;
  final Map<String, ValueNotifier<Set<String>>> _threads = {};
  final Map<String, Timer> _timers = {};

  ValueListenable<Set<String>> of(String threadId) => _threads.putIfAbsent(threadId, () => ValueNotifier(const {}));

  void _onEvent(TypingEvent e) {
    final notifier = _threads.putIfAbsent(e.threadId, () => ValueNotifier(const {}));
    if (!notifier.value.contains(e.userId)) notifier.value = {...notifier.value, e.userId};
    final key = '${e.threadId}/${e.userId}';
    _timers[key]?.cancel();
    _timers[key] = Timer(ttl, () => clear(e.threadId, e.userId));
  }

  void clear(String threadId, String userId) {
    _timers.remove('$threadId/$userId')?.cancel();
    final notifier = _threads[threadId];
    if (notifier == null || !notifier.value.contains(userId)) return;
    notifier.value = {...notifier.value}..remove(userId);
  }

  void dispose() {
    _sub?.cancel();
    for (final t in _timers.values) {
      t.cancel();
    }
    _timers.clear();
  }
}

final typingProvider = Provider.family<TypingTracker, AccountSession>((ref, session) {
  final tracker = TypingTracker(session);
  ref.onDispose(tracker.dispose);
  return tracker;
});

/// Profiles looked up through [AccountSession.users] and [contacts], shared
/// by the chat, the info pane and the mention picker.
class Directory extends ChangeNotifier {
  Directory(this._session);

  final AccountSession _session;
  final Map<String, Contact> _known = {};
  final Set<String> _pending = {};
  bool _contactsLoaded = false;
  bool _disposed = false;

  Contact? operator [](String uid) => _known[uid];

  String nameOf(String uid, [String fallback = '']) {
    final c = _known[uid];
    if (c == null) return fallback;
    final alias = c.alias;
    if (alias != null && alias.isNotEmpty) return alias;
    return c.displayName.isEmpty ? fallback : c.displayName;
  }

  String avatarOf(String uid) => _known[uid]?.avatarUrl ?? '';

  void seed(Iterable<Contact> contacts) {
    var changed = false;
    for (final c in contacts) {
      if (c.displayName.isEmpty && _known.containsKey(c.uid)) continue;
      _known[c.uid] = c;
      changed = true;
    }
    if (changed && !_disposed) notifyListeners();
  }

  Future<void> ensureContacts() async {
    if (_contactsLoaded) return;
    _contactsLoaded = true;
    try {
      seed(await _session.contacts());
    } catch (_) {
      _contactsLoaded = false;
    }
  }

  /// Requests profiles that are not known yet; listeners fire when they land.
  void need(Iterable<String> uids) {
    final missing = [
      for (final u in uids)
        if (u.isNotEmpty && !_known.containsKey(u) && _pending.add(u)) u,
    ];
    if (missing.isEmpty) return;
    Future<List<Contact>>.sync(() => _session.users(missing)).then((list) {
      if (_disposed) return;
      seed(list.where((c) => c.displayName.isNotEmpty));
    }, onError: (Object _) {}).whenComplete(() => _pending.removeAll(missing));
  }

  @override
  void dispose() {
    _disposed = true;
    super.dispose();
  }
}

final directoryProvider = Provider.family<Directory, AccountSession>((ref, session) {
  final d = Directory(session);
  ref.onDispose(d.dispose);
  return d;
});
