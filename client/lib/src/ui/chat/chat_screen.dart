import 'dart:async';
import 'dart:math' as math;

import 'package:flutter/foundation.dart';
import 'package:material_ui/material_ui.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../domain/models.dart';
import '../../domain/services.dart';
import '../components/avatar.dart';
import '../components/basics.dart';
import '../components/connection_banner.dart';
import '../components/fields.dart';
import '../components/motion.dart';
import '../components/overlays.dart';
import '../components/pressable.dart';
import '../contacts/destination_picker.dart';
import '../l10n/strings.dart';
import '../platform/services.dart';
import '../state/app_state.dart';
import '../state/media.dart';
import '../state/thread_ui.dart';
import '../theme/tokens.dart';
import '../theme/z_icons.dart';
import '../threads/thread_tile.dart';
import '../util/format.dart';
import 'board_sheets.dart';
import 'composer.dart';
import 'media_viewer.dart';
import 'message_actions.dart';
import 'message_content.dart' show mediaHeroTag;
import 'message_row.dart';
import 'report_dialog.dart';

class ChatScreen extends ConsumerStatefulWidget {
  const ChatScreen({super.key, required this.session, required this.thread, required this.account});

  final AccountSession session;
  final OpenThread thread;
  final AccountSummary account;

  @override
  ConsumerState<ChatScreen> createState() => ChatScreenState();
}

class ChatScreenState extends ConsumerState<ChatScreen> with WidgetsBindingObserver implements ChatActions {
  static const int _groupGapMs = 2 * 60 * 1000;

  late final ValueListenable<List<Message>> _messages;
  late final ValueListenable<LoadState> _load;
  late final ValueListenable<List<Thread>> _threads;
  late final ScrollController _scroll;
  late final ThreadUi _ui;
  late final TypingTracker _typing;
  final GlobalKey _centerKey = GlobalKey(debugLabel: 'chatCenter');
  final GlobalKey<ComposerState> _composerKey = GlobalKey();
  final Map<String, (Message, RowFlags, Widget)> _rowCache = {};
  final Map<String, GlobalKey> _rowKeys = {};
  final Map<Key, String> _rowIds = {};
  final Set<String> _entered = {};
  final TextEditingController _searchField = TextEditingController();

  @override
  late final Directory directory;

  String? _pivotKey;
  bool _seeking = false;
  int? _stickyTs;
  Timer? _stickyTimer;
  String? _unreadKey;
  int _unreadPending = 0;
  String? _lastKey;

  /// Newest message the user has seen here; a thread update that raises
  /// the unread count past it (the count can land after the message) is
  /// marked seen, a manual "mark unread" of what was already seen is not.
  String? _seenKey;
  int _awayCount = 0;
  bool _showLatest = false;
  bool _hasMore = true;
  bool _loadingOlder = false;
  String? _highlightKey;
  Timer? _highlightTimer;
  bool _searchOpen = false;
  List<String> _hits = const [];
  int _hitIndex = 0;
  bool _dropHover = false;
  bool _disposed = false;
  int _openedAt = 0;
  int _jumpToken = 0;
  String? _peerPresence;
  bool _peerOnline = false;
  List<PinnedTopic> _pins = const [];
  StreamSubscription<BoardUpdateEvent>? _boardSub;

  @override
  AccountSession get session => widget.session;
  OpenThread get _thread => widget.thread;

  @override
  bool get isGroup => _thread.isGroup;

  @override
  String get selfUid => widget.account.uid;

  @override
  Set<AccountCapability> get caps => capsOf(widget.account);

  @override
  String get peerAvatarUrl => _currentThread?.avatarUrl ?? _thread.avatarUrl;

  Thread? get _currentThread {
    for (final t in session.threads.value) {
      if (t.id == _thread.id && t.type == _thread.type) return t;
    }
    return null;
  }

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    _openedAt = ZClock.nowMs();
    _ui = ref.read(threadUiProvider((slot: session.slot, id: _thread.id)));
    directory = ref.read(directoryProvider(session));
    _typing = ref.read(typingProvider(session));
    _pivotKey = _ui.anchorKey;
    _scroll = ScrollController(initialScrollOffset: _ui.scrollOffset ?? 0)..addListener(_onScroll);
    _messages = session.messages(_thread.id, _thread.type);
    _messages.addListener(_onMessages);
    _load = session.messagesLoad(_thread.id, _thread.type);
    _load.addListener(_onLoad);
    _threads = session.threads;
    _threads.addListener(_onThreads);
    final initial = _messages.value;
    _lastKey = initial.isEmpty ? null : messageKeyOf(initial.last);
    _seenKey = _lastKey;
    final unread = _currentThread?.unread ?? 0;
    if (_ui.scrollOffset == null && unread > 0) {
      _unreadPending = unread;
      _placeUnreadAnchor(initial);
    }
    directory.ensureContacts();
    _needSenders(initial);
    _loadPresence();
    _loadPins();
    _boardSub = session.boardUpdates.listen((ev) {
      if (ev.threadId == _thread.id && ev.threadType == _thread.type) {
        _loadPins();
      }
    });
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (_disposed) return;
      _markSeen();
      _maybeLoadOlder();
      final anchor = _unreadKey;
      if (anchor != null) _reveal(anchor, alignment: 0.7, highlight: false);
    });
  }

  @override
  void dispose() {
    _disposed = true;
    WidgetsBinding.instance.removeObserver(this);
    _messages.removeListener(_onMessages);
    _load.removeListener(_onLoad);
    _threads.removeListener(_onThreads);
    _highlightTimer?.cancel();
    _stickyTimer?.cancel();
    _boardSub?.cancel();
    _scroll.dispose();
    _searchField.dispose();
    super.dispose();
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state == AppLifecycleState.resumed) _markSeen();
  }

  void _placeUnreadAnchor(List<Message> msgs) {
    if (_unreadPending <= 0 || msgs.isEmpty) return;
    final index = msgs.length - _unreadPending;
    if (index > 0 &&
        index < msgs.length &&
        !msgs[index].isSelf &&
        !msgs.last.isSelf) {
      _unreadKey = messageKeyOf(msgs[index]);
    }
    _unreadPending = 0;
  }

  void _needSenders(List<Message> msgs) {
    if (!isGroup) return;
    final ids = <String>{};
    for (var i = msgs.length - 1; i >= 0 && i >= msgs.length - 60; i--) {
      if (!msgs[i].isSelf) ids.add(msgs[i].senderId);
    }
    directory.need(ids);
  }

  /// Presence of the peer is read once when the chat opens, never polled.
  Future<void> _loadPresence() async {
    if (isGroup || !caps.contains(AccountCapability.presence)) return;
    try {
      final list = await session.presence();
      if (_disposed) return;
      FriendPresence? match;
      for (final presence in list) {
        if (presence.uid == _thread.id) {
          match = presence;
          break;
        }
      }
      if (match?.online == true) {
        if (mounted) {
          setState(() {
            _peerOnline = true;
            _peerPresence = context.tr('presenceOnline');
          });
        }
        return;
      }
      final seen = await session.lastSeen(_thread.id);
      if (_disposed || !mounted) return;
      if (seen.showOnlineStatus && seen.lastOnline > 0) {
        setState(() => _peerPresence = context.tr('lastSeen', [formatRelative(seen.lastOnline, context.s)]));
      }
    } catch (_) {
      // Presence is best effort; the chat works without it.
    }
  }

  void _markSeen() {
    if (_disposed) return;
    final lifecycle = WidgetsBinding.instance.lifecycleState;
    if (lifecycle != null && lifecycle != AppLifecycleState.resumed) return;
    if ((_currentThread?.unread ?? 0) <= 0) return;
    _seenKey = _lastKey;
    session.markSeen(_thread.id, _thread.type).catchError((Object _) {});
  }

  void _onThreads() {
    if (_seenKey != _lastKey) _markSeen();
  }

  bool get _scrolledUp {
    if (!_scroll.hasClients) return false;
    final pos = _scroll.position;
    return pos.hasContentDimensions && pos.pixels - pos.minScrollExtent > 40;
  }

  void _onMessages() {
    if (_disposed) return;
    final msgs = _messages.value;
    final newLast = msgs.isEmpty ? null : messageKeyOf(msgs.last);
    final wasEmpty = _lastKey == null;
    if (wasEmpty) _placeUnreadAnchor(msgs);
    if (newLast != null && newLast != _lastKey && !wasEmpty) {
      final last = msgs.last;
      _typing.clear(_thread.id, last.senderId);
      if (last.isSelf) {
        _unreadKey = null;
        _pivotKey = null;
        _awayCount = 0;
        WidgetsBinding.instance.addPostFrameCallback((_) {
          if (!_disposed && _scroll.hasClients) _scroll.jumpTo(0);
        });
      } else if (_scrolledUp) {
        _pivotKey ??= _lastKey;
        _awayCount++;
      }
    }
    _lastKey = newLast;
    _needSenders(msgs);
    if (_searchOpen) _runSearch(_searchField.text, keepIndex: true);
    setState(() {});
    _markSeen();
    WidgetsBinding.instance.addPostFrameCallback((_) => _maybeLoadOlder());
  }

  void _reloadMessages() => session.reloadMessages(_thread.id, _thread.type).catchError((Object _) {});

  void _onLoad() {
    if (_disposed) return;
    setState(() {});
    WidgetsBinding.instance.addPostFrameCallback((_) => _maybeLoadOlder());
  }

  void _onScroll() {
    if (_disposed || !_scroll.hasClients) return;
    final pos = _scroll.position;
    if (!pos.hasContentDimensions) return;
    final fromBottom = pos.pixels - pos.minScrollExtent;
    if (_pivotKey != null && fromBottom <= 1) {
      setState(() {
        _pivotKey = null;
        _awayCount = 0;
      });
      _scroll.jumpTo(0);
    }
    _updateSticky(fromBottom);
    final showLatest = fromBottom > pos.viewportDimension;
    if (showLatest != _showLatest) setState(() => _showLatest = showLatest);
    _ui.scrollOffset = pos.pixels;
    _ui.anchorKey = _pivotKey ?? (fromBottom > 40 ? _lastKey : null);
    _maybeLoadOlder();
    WidgetsBinding.instance.addPostFrameCallback((_) => _maybeLoadOlder());
  }

  /// Shows the day of the topmost visible message while scrolling.
  void _updateSticky(double fromBottom) {
    final listBox = context.findRenderObject();
    if (listBox is! RenderBox || fromBottom < 80) {
      if (_stickyTs != null) setState(() => _stickyTs = null);
      return;
    }
    final top = listBox.localToGlobal(Offset.zero).dy + ZSizes.wideChatHeader;
    int? ts;
    var best = double.infinity;
    _rowKeys.forEach((key, g) {
      final box = g.currentContext?.findRenderObject();
      if (box is! RenderBox || !box.attached) return;
      final dy = box.localToGlobal(Offset.zero).dy + box.size.height;
      if (dy > top && dy < best) {
        best = dy;
        ts = _rowCache[key]?.$1.ts;
      }
    });
    if (ts != null && ts != _stickyTs) setState(() => _stickyTs = ts);
    _stickyTimer?.cancel();
    _stickyTimer = Timer(const Duration(milliseconds: 1500), () {
      if (!_disposed && _stickyTs != null) setState(() => _stickyTs = null);
    });
  }

  Future<void> _maybeLoadOlder() async {
    if (_disposed || _loadingOlder || !_hasMore || !_scroll.hasClients) return;
    final pos = _scroll.position;
    if (!pos.hasContentDimensions || pos.maxScrollExtent - pos.pixels > 400) {
      return;
    }
    if (_messages.value.isEmpty && _load.value != LoadState.ready) return;
    setState(() => _loadingOlder = true);
    var more = false;
    try {
      more = await session.loadOlder(_thread.id, _thread.type);
    } catch (_) {
      more = false;
    }
    if (_disposed) return;
    setState(() {
      _loadingOlder = false;
      _hasMore = more;
    });
    WidgetsBinding.instance.addPostFrameCallback((_) => _maybeLoadOlder());
  }

  void _scrollToLatest() {
    if (!_scroll.hasClients) return;
    final pos = _scroll.position;
    final below = -pos.minScrollExtent;
    final target = pos.pixels + (_pivotKey == null ? 0 : below);
    setState(() {
      _pivotKey = null;
      _awayCount = 0;
    });
    _scroll.jumpTo(math.max(0, target));
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (_disposed || !_scroll.hasClients) return;
      if (ZMotion.reduced(context) || _scroll.position.pixels > 3000) {
        _scroll.jumpTo(0);
      } else {
        _scroll.animateTo(0, duration: ZMotion.medium, curve: ZMotion.enterCurve);
      }
    });
  }

  int _indexOfKey(List<Message> msgs, String key) {
    for (var i = msgs.length - 1; i >= 0; i--) {
      if (messageKeyOf(msgs[i]) == key) return i;
    }
    return -1;
  }

  /// Scrolls until the row of [key] is built, then brings it into view.
  Future<void> _reveal(String key, {double alignment = 0.4, bool highlight = true}) async {
    final token = ++_jumpToken;
    final revealDuration = ZMotion.of(context, ZMotion.medium);
    final msgs = _messages.value;
    final target = _indexOfKey(msgs, key);
    if (target < 0 || !_scroll.hasClients) return;
    for (var step = 0; step < 300; step++) {
      if (_disposed || token != _jumpToken) return;
      final ctx = _rowKeys[key]?.currentContext;
      if (ctx != null) {
        // ignore: use_build_context_synchronously
        await Scrollable.ensureVisible(ctx, alignment: alignment, duration: step == 0 ? revealDuration : Duration.zero, curve: ZMotion.enterCurve);
        break;
      }
      var lo = msgs.length, hi = -1;
      _rowKeys.forEach((k, g) {
        if (g.currentContext == null) return;
        final i = _indexOfKey(msgs, k);
        if (i < 0) return;
        lo = math.min(lo, i);
        hi = math.max(hi, i);
      });
      final pos = _scroll.position;
      final distance = hi < 0 ? 20 : (target < lo ? lo - target : target - hi);
      // Index based: the mounted rows give an average height, so one jump
      // lands next to the target and the loop only refines.
      final average = hi < 0 ? 72.0 : (pos.viewportDimension / (hi - lo + 1)).clamp(40.0, 400.0);
      final delta = (average * distance + pos.viewportDimension * 0.3) * (hi >= 0 && target > hi ? -1 : 1);
      final next = (pos.pixels + delta).clamp(pos.minScrollExtent, pos.maxScrollExtent);
      if (next == pos.pixels) break;
      _scroll.jumpTo(next);
      await WidgetsBinding.instance.endOfFrame;
    }
    if (_disposed || !highlight) return;
    _highlightTimer?.cancel();
    setState(() => _highlightKey = key);
    _highlightTimer = Timer(const Duration(milliseconds: 1400), () {
      if (!_disposed) setState(() => _highlightKey = null);
    });
  }

  void _toast(String key) {
    if (mounted) zToast(context, context.tr(key));
  }

  Future<void> _guard(Future<void> Function() action, {String failKey = 'actionFailed'}) async {
    try {
      await action();
    } catch (_) {
      _toast(failKey);
    }
  }

  Set<String> _ownReactions(Message m) => {
        for (final e in m.reactions.entries)
          if (e.value.contains(selfUid)) e.key,
      };

  @override
  void react(Message m, String icon) {
    _guard(() => session.react(m, icon));
  }

  @override
  Future<void> openReactionPicker(Message m, Rect anchor) async {
    final icon = await showReactionPicker(context, anchor: anchor, own: _ownReactions(m));
    if (icon != null) react(m, icon);
  }

  @override
  void showReactions(Message m) {
    directory.need(m.reactions.values.expand((v) => v));
    showWhoReacted(context, this, m);
  }

  @override
  void reply(Message m) {
    ref.read(platformProvider).hapticTick();
    _ui.replyTo = m;
    _composerKey.currentState?.focusInput();
  }

  @override
  void retry(Message m) {
    _guard(() => session.resend(m), failKey: 'sendFailed');
  }

  @override
  Future<void> deleteFailed(Message m, Offset globalPosition) async {
    final action = await showZMenu<MessageAction>(context, position: globalPosition, items: [
      ZMenuItem(value: MessageAction.retry, label: context.tr('retry'), icon: ZIcons.refresh),
      ZMenuItem(value: MessageAction.delete, label: context.tr('delete'), icon: ZIcons.delete, danger: true),
    ]);
    if (action == MessageAction.retry) retry(m);
    if (action == MessageAction.delete) {
      await _guard(() => session.deleteForMe(m));
    }
  }

  @override
  bool claimEntrance(Message m) => _entered.add(messageKeyOf(m));

  @override
  void openMedia(Message m, int index) {
    final items = <ViewerItem>[];
    var initial = 0;
    for (final msg in _messages.value) {
      if (msg.recalled ||
          (msg.kind != MessageKind.image && msg.kind != MessageKind.gif && msg.kind != MessageKind.video)) {
        continue;
      }
      for (var i = 0; i < msg.attachments.length; i++) {
        if (identical(msg, m) || msg.id == m.id) {
          if (i == index) initial = items.length;
        }
        items.add(ViewerItem(
          attachment: msg.attachments[i],
          senderName: msg.isSelf ? widget.account.displayName : directory.nameOf(msg.senderId, msg.senderName),
          ts: msg.ts,
          heroTag: msg.kind == MessageKind.image || msg.kind == MessageKind.gif ? mediaHeroTag(msg, i) : null,
        ));
      }
    }
    if (items.isEmpty) return;
    showMediaViewer(context, session, items, initial);
  }

  @override
  void openDoodle(Message m) {
    final doodle = m.doodle;
    if (doodle == null || doodle.url.isEmpty) return;
    showMediaViewer(context, session, [
      ViewerItem(
        attachment: Attachment(
          kind: MessageKind.image,
          url: doodle.url,
          thumbUrl: doodle.thumbUrl,
          width: doodle.width,
          height: doodle.height,
        ),
        senderName: m.isSelf ? widget.account.displayName : directory.nameOf(m.senderId, m.senderName),
        ts: m.ts,
      ),
    ], 0);
  }

  Future<void> _loadPins() async {
    if (!caps.contains(AccountCapability.pinMessage)) return;
    try {
      final state = await session.listPins(_thread.id, _thread.type);
      if (_disposed || !mounted) return;
      setState(() => _pins = state.items);
    } catch (_) {
      // Pin bar is best effort; chat works without it.
    }
  }

  Future<void> _openPinnedTopic(PinnedTopic topic) async {
    if (topic.kind == BoardItemKind.poll && topic.pollId != null && isGroup) {
      final admin = await _isGroupAdmin();
      if (!mounted) return;
      await showPollDetailSheet(
        context,
        session: session,
        directory: directory,
        pollId: topic.pollId!,
        groupId: _thread.id,
        selfUid: selfUid,
        isAdmin: admin,
      );
      return;
    }
    if (topic.kind == BoardItemKind.reminder) {
      await showRemindersSheet(
        context,
        session: session,
        threadId: _thread.id,
        threadType: _thread.type,
      );
      return;
    }
    final targetId = topic.msgId ?? topic.cliMsgId;
    if (targetId != null && targetId.isNotEmpty) {
      await jumpToQuote(Quote(
        msgId: targetId,
        senderId: topic.senderId ?? '',
        senderName: topic.senderName ?? '',
        text: topic.title,
      ));
      return;
    }
    await _openPinnedBoard();
  }

  Future<void> _openPinnedBoard() async {
    await showPinnedBoardSheet(
      context,
      session: session,
      threadId: _thread.id,
      threadType: _thread.type,
      initialPins: _pins,
      canPin: caps.contains(AccountCapability.pinMessage),
      canNotes: caps.contains(AccountCapability.notes),
      onOpenItem: _openPinnedTopic,
      onChanged: _loadPins,
    );
  }

  @override
  Future<void> openPoll(Message m) async {
    final poll = m.poll;
    if (poll == null || poll.id == null) return;
    final admin = await _isGroupAdmin();
    if (!mounted) return;
    await showPollDetailSheet(
      context,
      session: session,
      directory: directory,
      pollId: poll.id!,
      groupId: isGroup ? _thread.id : '',
      selfUid: selfUid,
      isAdmin: admin,
      fallbackPoll: poll,
    );
  }

  @override
  void openAlbum(Message m, int index) {
    final album = m.album;
    if (album == null || album.items.isEmpty) return;
    final items = [
      for (final attachment in album.items)
        ViewerItem(
          attachment: attachment,
          senderName: m.isSelf ? widget.account.displayName : directory.nameOf(m.senderId, m.senderName),
          ts: m.ts,
        ),
    ];
    showMediaViewer(context, session, items, index.clamp(0, items.length - 1));
  }

  @override
  Future<void> openLink(String url) async {
    final opened = await ref.read(platformProvider).openUrl(url);
    if (!opened) {
      await Clipboard.setData(ClipboardData(text: url));
      _toast('linkCopied');
    }
  }

  @override
  void openUser(String uid, String name, String avatarUrl) {
    if (uid.isEmpty) return;
    openThread(
        ref,
        OpenThread(
            slot: session.slot,
            id: uid,
            type: ThreadType.user,
            name: name,
            avatarUrl: avatarUrl));
    if (!LayoutScope.wideOf(context)) {
      ref.read(infoPaneOpenProvider.notifier).state = false;
    }
  }

  /// The server stays the authority; this only decides whether to offer the
  /// admin action, from the group owner and deputy lists.
  Future<bool> _isGroupAdmin() async {
    if (!isGroup) return false;
    var info = ref.read(groupInfoProvider((session, _thread.id))).valueOrNull;
    if (info == null) {
      try {
        info = await session.groupInfo(_thread.id);
      } catch (_) {
        return false;
      }
    }
    return info.ownerId == selfUid || info.adminIds.contains(selfUid);
  }

  @override
  Message? loadedMessage(String id) {
    final msgs = _messages.value;
    for (var i = msgs.length - 1; i >= 0; i--) {
      if (msgs[i].id == id || msgs[i].cliId == id) return msgs[i];
    }
    return null;
  }

  @override
  Future<void> jumpToQuote(Quote quote) async {
    for (var page = 0; page < 40; page++) {
      final msgs = _messages.value;
      for (var i = msgs.length - 1; i >= 0; i--) {
        if (msgs[i].id == quote.msgId || msgs[i].cliId == quote.msgId) {
          if (_seeking) setState(() => _seeking = false);
          await _reveal(messageKeyOf(msgs[i]));
          return;
        }
      }
      if (!_hasMore || _disposed) break;
      setState(() => _seeking = true);
      var more = false;
      try {
        more = await session.loadOlder(_thread.id, _thread.type);
      } catch (_) {}
      if (_disposed) return;
      if (!more) setState(() => _hasMore = false);
    }
    if (!_disposed && _seeking) setState(() => _seeking = false);
    _toast('quoteNotLoaded');
  }

  @override
  Future<void> openMenu(Message m, Offset globalPosition) async {
    final admin = await _isGroupAdmin();
    if (!mounted) return;
    final action = await showMessageMenu(
      context,
      position: globalPosition,
      m: m,
      own: _ownReactions(m),
      onReact: (icon) => react(m, icon),
      caps: caps,
      isGroup: isGroup,
      admin: admin,
    );
    if (action == null || !mounted) return;
    switch (action) {
      case MessageAction.reply:
        reply(m);
      case MessageAction.copy:
        final link = m.kind == MessageKind.link && m.attachments.isNotEmpty ? m.attachments.first.url : '';
        final text = (m.text ?? '').trim();
        await Clipboard.setData(ClipboardData(text: text.isEmpty ? link : text));
        _toast('copied');
      case MessageAction.forward:
        await _forward(m);
      case MessageAction.pin:
        await _guard(() async {
          final summary = messageSummary(m, context.s);
          final next = await session.pinMessage(m, title: summary);
          if (!mounted) return;
          setState(() => _pins = next.items);
          _toast('messagePinned');
        });
      case MessageAction.save:
        final downloads = ref.read(downloadsProvider);
        var ok = true;
        for (var i = 0; i < m.attachments.length; i++) {
          final a = m.attachments[i];
          final name = a.name ?? '${m.kind.name}-${m.ts}-$i.${switch (m.kind) { MessageKind.image => 'jpg', MessageKind.gif => 'gif', MessageKind.video => 'mp4', MessageKind.voice => 'm4a', _ => 'bin' }}';
          ok = await downloads.fetch(session, a.url, name) && ok;
        }
        _toast(ok ? 'fileSaved' : 'downloadFailed');
      case MessageAction.recall:
        final ok = await zConfirm(context, title: context.tr('recallTitle'), message: context.tr('recallBody'), confirmLabel: context.tr('recall'));
        if (ok) await _guard(() => session.recall(m));
      case MessageAction.delete:
        final ok = await zConfirm(context, title: context.tr('deleteMessageTitle'), message: context.tr('deleteMessageBody'), confirmLabel: context.tr('delete'));
        if (ok) await _guard(() => session.deleteForMe(m));
      case MessageAction.deleteForAll:
        final ok = await zConfirm(context,
            title: context.tr('deleteForAllTitle'),
            message: context.tr('deleteForAllBody'),
            confirmLabel: context.tr('deleteForAll'));
        if (!ok) return;
        await _guard(() async {
          await session.deleteForAll(m);
          if (mounted) _toast('deletedForAll');
        }, failKey: 'deleteForAllFailed');
      case MessageAction.report:
        await showReportDialog(context,
            session: session, threadId: _thread.id, type: _thread.type);
      case MessageAction.details:
        directory.need(m.reactions.values.expand((v) => v));
        await showMessageDetails(context, this, m);
      case MessageAction.retry:
        retry(m);
    }
  }

  Future<void> _forward(Message m) async {
    final picked = await showDestinationPicker(context, session: session, title: context.tr('forwardTitle'), multi: true, confirmLabel: context.tr('forward'));
    if (picked == null || picked.isEmpty) return;
    try {
      await session.forward(m, [for (final d in picked) ThreadRef(d.id, d.type)]);
      _toast('forwarded');
    } catch (_) {
      _toast('forwardFailed');
    }
  }

  void _openSearch() {
    setState(() {
      _searchOpen = true;
      _hits = const [];
      _hitIndex = 0;
    });
  }

  void _closeSearch() {
    _searchField.clear();
    setState(() {
      _searchOpen = false;
      _hits = const [];
    });
  }

  void _runSearch(String query, {bool keepIndex = false}) {
    final q = query.trim();
    final hits = <String>[];
    if (q.isNotEmpty) {
      for (final m in _messages.value) {
        if (m.recalled) continue;
        final text = m.text ?? '';
        final name =
            m.attachments.isEmpty ? '' : (m.attachments.first.name ?? '');
        if (foldContains(text, q) ||
            (name.isNotEmpty && foldContains(name, q))) {
          hits.add(messageKeyOf(m));
        }
      }
    }
    setState(() {
      _hits = hits;
      _hitIndex = keepIndex ? _hitIndex.clamp(0, math.max(0, hits.length - 1)) : math.max(0, hits.length - 1);
    });
    if (!keepIndex && hits.isNotEmpty) _reveal(hits[_hitIndex]);
  }

  void _stepHit(int delta) {
    if (_hits.isEmpty) return;
    setState(() => _hitIndex = (_hitIndex + delta).clamp(0, _hits.length - 1));
    _reveal(_hits[_hitIndex]);
  }

  bool _grouped(Message a, Message b) =>
      a.senderId == b.senderId &&
      a.kind != MessageKind.system &&
      b.kind != MessageKind.system &&
      (b.ts - a.ts).abs() <= _groupGapMs &&
      sameDay(a.ts, b.ts);

  Widget _row(List<Message> msgs, int index, String? newestOwn) {
    final m = msgs[index];
    final key = messageKeyOf(m);
    final older = index > 0 ? msgs[index - 1] : null;
    final newer = index < msgs.length - 1 ? msgs[index + 1] : null;
    final divider = key == _unreadKey;
    final entrance = m.ts >= _openedAt;
    final flags = RowFlags(
      first: older == null || divider || !_grouped(older, m),
      last: newer == null || !_grouped(m, newer) || messageKeyOf(newer) == _unreadKey,
      showDay: older == null || !sameDay(older.ts, m.ts),
      unreadDivider: divider,
      newestOwn: key == newestOwn,
      highlight: key == _highlightKey,
      query: _searchOpen ? _searchField.text.trim() : '',
      entrance: entrance,
    );
    final hit = _rowCache[key];
    if (hit != null && identical(hit.$1, m) && hit.$2 == flags) return hit.$3;
    final rowKey = _rowKeys.putIfAbsent(key, () => GlobalKey(debugLabel: key));
    _rowIds[rowKey] = key;
    final widget = KeyedSubtree(
      key: rowKey,
      child: MessageRow(message: m, flags: flags, actions: this),
    );
    _rowCache[key] = (m, flags, widget);
    return widget;
  }

  List<AvatarMember> _members() {
    if (!isGroup) return const [];
    final info = ref.watch(groupInfoProvider((session, _thread.id))).valueOrNull;
    if (info == null) return const [];
    directory.need(info.memberIds);
    return [
      for (final id in info.memberIds)
        if (directory.nameOf(id).isNotEmpty) AvatarMember(id, directory.nameOf(id), directory.avatarOf(id)),
    ];
  }

  @override
  Widget build(BuildContext context) {
    final z = context.z;
    final wide = LayoutScope.wideOf(context);
    ref.watchNotifier(directory);
    ref.watchNotifier(_ui);
    ref.listen<int>(chatSearchRequestProvider, (_, __) => _openSearch());
    final typing = ref.watchL(_typing.of(_thread.id));
    final platform = ref.watch(platformProvider);
    final msgs = _messages.value;
    final n = msgs.length;
    if (_rowCache.length > n + 512) {
      _rowCache.clear();
      _rowKeys.removeWhere((_, g) => g.currentContext == null);
      _rowIds.removeWhere((k, _) => !_rowKeys.containsValue(k));
    }

    var pivot = n;
    final pivotKey = _pivotKey;
    if (pivotKey != null) {
      final i = _indexOfKey(msgs, pivotKey);
      if (i < 0) {
        _pivotKey = null;
      } else {
        pivot = i + 1;
      }
    }
    String? newestOwn;
    for (var i = n - 1; i >= 0; i--) {
      final m = msgs[i];
      if (m.isSelf && m.sendState == SendState.sent && !m.recalled) {
        newestOwn = messageKeyOf(m);
        break;
      }
    }

    final groupInfo = isGroup ? ref.watch(groupInfoProvider((session, _thread.id))).valueOrNull : null;
    final bottom = _BottomSlot(session: session, isGroup: isGroup, typing: typing, directory: directory, peerName: _thread.name, peerAvatarUrl: peerAvatarUrl);
    final Widget top = !_hasMore
            ? Padding(
                key: const Key('historyStart'),
                padding: const EdgeInsets.symmetric(vertical: ZSpace.s16),
                child: Center(child: Text(context.tr('historyStart'), style: z.text.caption)),
              )
            : const SizedBox(height: 40);

    final load = _load.value;
    final Widget list;
    if (n == 0 && load == LoadState.loading) {
      list = _BubbleSkeletons(key: const Key('messagesLoading'), label: context.tr('loading'));
    } else if (n == 0 && load == LoadState.failed) {
      list = ZErrorState(key: const Key('messagesError'), title: context.tr('messagesLoadFailed'), retryLabel: context.tr('retry'), onRetry: _reloadMessages);
    } else if (n == 0) {
      list = Center(
        key: const Key('messagesEmpty'),
        child: Padding(
          padding: const EdgeInsets.all(ZSpace.s24),
          child: Text(context.tr('noMessages'), textAlign: TextAlign.center, style: z.text.rowSub),
        ),
      );
    } else {
      list = Scrollbar(
        controller: _scroll,
        // One traversal group for the list, so Tab visits the messages before
        // leaving for the composer, whatever the scroll position.
        child: FocusTraversalGroup(
          policy: ZReadingOrderPolicy(),
          child: CustomScrollView(
            key: const Key('messageList'),
            controller: _scroll,
            keyboardDismissBehavior: ScrollViewKeyboardDismissBehavior.onDrag,
            // Rows are built as they come on screen, so Tab only stops on
            // messages that are actually in view.
            scrollCacheExtent: const ScrollCacheExtent.pixels(0),
            reverse: true,
            center: _centerKey,
            slivers: [
              SliverToBoxAdapter(child: pivot == n ? const SizedBox.shrink() : bottom),
              SliverList(
                delegate: SliverChildBuilderDelegate(
                  (context, j) => _row(msgs, pivot + j, newestOwn),
                  childCount: n - pivot,
                  findChildIndexCallback: (key) {
                    final id = _rowIds[key];
                    final i = id == null ? -1 : _indexOfKey(msgs, id);
                    return i < pivot ? null : i - pivot;
                  },
                ),
              ),
              SliverList(
                key: _centerKey,
                delegate: SliverChildBuilderDelegate(
                  (context, i) {
                    if (i == 0) {
                      return pivot == n ? bottom : const SizedBox.shrink();
                    }
                    if (i == pivot + 1) return top;
                    return _row(msgs, pivot - i, newestOwn);
                  },
                  childCount: pivot + 2,
                  findChildIndexCallback: (key) {
                    final id = _rowIds[key];
                    final i = id == null ? -1 : _indexOfKey(msgs, id);
                    return i < 0 || i >= pivot ? null : pivot - i;
                  },
                ),
              ),
            ],
          ),
        ),
      );
    }

    final members = _members();
    final body = Stack(
      fit: StackFit.expand,
      children: [
        ColoredBox(color: z.surface, child: list),
        Positioned(
          right: ZSpace.s16,
          bottom: ZSpace.s16,
          child: AnimatedOpacity(
            opacity: _showLatest || _awayCount > 0 ? 1 : 0,
            duration: ZMotion.of(context, ZMotion.fast),
            curve: ZMotion.standard,
            child: AnimatedScale(
              scale: _showLatest || _awayCount > 0 ? 1 : 0.75,
              duration: ZMotion.of(context, ZMotion.fast),
              curve: _showLatest || _awayCount > 0 ? ZMotion.springCurve : ZMotion.exitCurve,
              child: IgnorePointer(
                ignoring: !(_showLatest || _awayCount > 0),
                child: Stack(
                  clipBehavior: Clip.none,
                  children: [
                    ZIconButton(
                      key: const Key('scrollToLatest'),
                      icon: ZIcons.chevronDown,
                      label: context.tr('scrollToLatest'),
                      size: 40,
                      iconSize: 28,
                      circle: true,
                      fill: z.layer,
                      shadow: z.shadowOverflow,
                      onPressed: _showLatest || _awayCount > 0 ? _scrollToLatest : null,
                    ),
                    if (_awayCount > 0) Positioned(top: -6, right: -2, child: ZBadge(key: const Key('awayBadge'), count: _awayCount)),
                  ],
                ),
              ),
            ),
          ),
        ),
        if (_seeking)
          Positioned(
            top: ZSpace.s8,
            left: 0,
            right: 0,
            child: Center(
              child: Container(
                key: const Key('seekingOlder'),
                padding: const EdgeInsets.symmetric(horizontal: ZSpace.s12, vertical: 6),
                decoration: BoxDecoration(color: z.layer, borderRadius: BorderRadius.circular(ZRadius.pill), boxShadow: z.shadowOverflow),
                child: Row(mainAxisSize: MainAxisSize.min, children: [
                  const SizedBox(width: 14, height: 14, child: CircularProgressIndicator(strokeWidth: 2)),
                  const SizedBox(width: ZSpace.s8),
                  Text(context.tr('seekingOlder'), style: z.text.caption.copyWith(color: z.textSecondary)),
                ]),
              ),
            ),
          )
        else if (_stickyTs != null && !_loadingOlder)
          Positioned(top: ZSpace.s8, left: 0, right: 0, child: IgnorePointer(child: DayPill(key: const Key('stickyDay'), text: formatDay(_stickyTs!, context.s)))),
        if (_loadingOlder && n > 0 && !_seeking)
          Positioned(
            top: ZSpace.s8,
            left: 0,
            right: 0,
            child: Center(
              child: Container(
                key: const Key('olderSpinner'),
                padding: const EdgeInsets.all(6),
                decoration: BoxDecoration(color: z.layer, shape: BoxShape.circle, boxShadow: z.shadowOverflow),
                child: SizedBox(width: 18, height: 18, child: CircularProgressIndicator(strokeWidth: 2, semanticsLabel: context.tr('loadingOlder'))),
              ),
            ),
          ),
        if (_dropHover)
          Positioned.fill(
            child: IgnorePointer(
              child: Container(
                key: const Key('dropOverlay'),
                color: z.brandSubtle.withValues(alpha: 0.95),
                padding: const EdgeInsets.all(ZSpace.s8),
                child: Container(
                  decoration: BoxDecoration(borderRadius: BorderRadius.circular(ZRadius.input), border: Border.all(color: z.brandText, width: 2)),
                  alignment: Alignment.center,
                  child: Column(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      Icon(ZIcons.upload, size: 48, color: z.brandText),
                      const SizedBox(height: ZSpace.s8),
                      Text(context.tr('dropToSend'), style: z.text.title.copyWith(color: z.brandText)),
                    ],
                  ),
                ),
              ),
            ),
          ),
      ],
    );

    return Material(
      color: z.layer,
      child: platform.dropTarget(
        onHover: (v) {
          if (mounted && v != _dropHover) setState(() => _dropHover = v);
        },
        onDrop: (files) => _composerKey.currentState?.addFiles(files),
        child: Column(
          children: [
            if (_searchOpen)
              _SearchBar(
                controller: _searchField,
                count: _hits.length,
                index: _hits.isEmpty ? 0 : _hitIndex + 1,
                onChanged: _runSearch,
                onPrevious: () => _stepHit(-1),
                onNext: () => _stepHit(1),
                onClose: _closeSearch,
              )
            else
              _ChatHeader(
                session: session,
                thread: _thread,
                current: _currentThread,
                typing: typing.isNotEmpty,
                presence: _peerPresence,
                online: _peerOnline,
                memberCount: groupInfo?.memberCount ?? groupInfo?.memberIds.length,
                isGroup: isGroup,
                onBack: wide ? null : () => closeThread(ref),
                onSearch: _openSearch,
                onInfo: () => ref.read(infoPaneOpenProvider.notifier).state = !ref.read(infoPaneOpenProvider),
                infoOpen: ref.watch(infoPaneOpenProvider),
              ),
            if (!wide) ConnectionBanner(session: session),
            if (_pins.isNotEmpty)
              PinnedBar(
                items: _pins,
                onTapItem: _openPinnedTopic,
                onOpenAll: _openPinnedBoard,
                onUnpin: (topic) async {
                  await _guard(() async {
                    final next = await session.unpinTopic(
                      _thread.id,
                      _thread.type,
                      topic.id,
                      topic.topicType,
                    );
                    if (!mounted) return;
                    setState(() => _pins = next.items);
                    _toast('unpinned');
                  });
                },
              ),
            ZReveal(
              child: n > 0 && load == LoadState.failed
                  ? ZBanner(
                      key: const Key('messagesStaleBanner'),
                      tone: ZTone.warning,
                      icon: ZIcons.warning,
                      text: context.tr('messagesStale'),
                      actionLabel: context.tr('retry'),
                      onAction: _reloadMessages,
                    )
                  : null,
            ),
            Expanded(child: body),
            Composer(key: _composerKey, session: session, thread: _thread, account: widget.account, members: members, onSent: _scrollToLatest),
          ],
        ),
      ),
    );
  }
}

class _BottomSlot extends StatelessWidget {
  const _BottomSlot({required this.session, required this.isGroup, required this.typing, required this.directory, required this.peerName, required this.peerAvatarUrl});

  final AccountSession session;
  final bool isGroup;
  final Set<String> typing;
  final Directory directory;
  final String peerName;
  final String peerAvatarUrl;

  @override
  Widget build(BuildContext context) {
    final wide = LayoutScope.wideOf(context);
    final metrics = wide ? ChatMetrics.wideMetrics : ChatMetrics.compact;
    if (typing.isEmpty) return const SizedBox(height: ZSpace.s12);
    final uid = typing.first;
    final name = isGroup ? directory.nameOf(uid, context.tr('someone')) : peerName;
    final label = typing.length > 1 ? context.tr('typingMany', [typing.length]) : context.tr('typingOne', [name]);
    return Align(
      alignment: Alignment.centerLeft,
      child: SizedBox(
        child: Padding(
          key: const Key('typingIndicator'),
          padding: EdgeInsets.fromLTRB(metrics.sidePadding, metrics.gapBetweenGroups, metrics.sidePadding, ZSpace.s12),
          child: Semantics(
            liveRegion: true,
            label: label,
            child: Row(
              crossAxisAlignment: CrossAxisAlignment.end,
              children: [
                if (isGroup || wide)
                  SizedBox(
                    width: metrics.avatarGutter,
                    child: Align(
                      alignment: Alignment.centerLeft,
                      child: ZAvatar(session: session, id: uid, name: name, url: isGroup ? directory.avatarOf(uid) : peerAvatarUrl, size: metrics.avatar),
                    ),
                  ),
                const _TypingDots(),
              ],
            ),
          ),
        ),
      ),
    );
  }
}

class _TypingDots extends StatefulWidget {
  const _TypingDots();

  @override
  State<_TypingDots> createState() => _TypingDotsState();
}

class _TypingDotsState extends State<_TypingDots> with SingleTickerProviderStateMixin {
  late final AnimationController _controller = AnimationController(vsync: this, duration: const Duration(milliseconds: 1200));

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    if (ZMotion.reduced(context)) {
      _controller.stop();
    } else if (!_controller.isAnimating) {
      _controller.repeat();
    }
  }

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final z = context.z;
    final wide = LayoutScope.wideOf(context);
    return ExcludeSemantics(
      child: Container(
        padding: const EdgeInsets.symmetric(horizontal: ZSpace.s12, vertical: 10),
        decoration: BoxDecoration(
          color: z.bubbleIn,
          borderRadius: BorderRadius.circular(wide ? ZRadius.bubbleWide : ZRadius.bubbleCompact),
          border: wide ? null : Border.all(color: z.bubbleInBorder),
          boxShadow: wide ? z.shadowBubble : null,
        ),
        child: AnimatedBuilder(
          animation: _controller,
          builder: (context, _) => Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              for (var i = 0; i < 3; i++)
                Container(
                  width: 6,
                  height: 6,
                  margin: const EdgeInsets.symmetric(horizontal: 2),
                  decoration: BoxDecoration(
                    shape: BoxShape.circle,
                    color: z.textTertiary.withValues(alpha: 0.35 + 0.65 * (1 - ((_controller.value * 3 - i) % 3).abs().clamp(0.0, 1.0))),
                  ),
                ),
            ],
          ),
        ),
      ),
    );
  }
}

class _BubbleSkeletons extends StatelessWidget {
  const _BubbleSkeletons({super.key, required this.label});

  final String label;

  @override
  Widget build(BuildContext context) {
    const widths = [180.0, 240.0, 120.0, 200.0, 160.0, 220.0];
    return Semantics(
      label: label,
      child: Align(
        alignment: Alignment.bottomCenter,
        child: ConstrainedBox(
          constraints: const BoxConstraints(maxWidth: ZSizes.chatMaxContent),
          child: SingleChildScrollView(
            reverse: true,
            physics: const NeverScrollableScrollPhysics(),
            padding: const EdgeInsets.all(ZSpace.s16),
            child: Column(
              children: [
                for (var i = 0; i < widths.length; i++)
                  Padding(
                    padding: const EdgeInsets.only(top: ZSpace.s12),
                    child: Align(
                      alignment: i.isEven ? Alignment.centerLeft : Alignment.centerRight,
                      child: ZSkeleton(width: widths[i], height: i % 3 == 0 ? 56 : 38, radius: ZRadius.bubbleCompact),
                    ),
                  ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}

class _ChatHeader extends StatelessWidget {
  const _ChatHeader({
    required this.session,
    required this.thread,
    required this.current,
    required this.typing,
    required this.presence,
    required this.online,
    required this.memberCount,
    required this.isGroup,
    required this.onBack,
    required this.onSearch,
    required this.onInfo,
    required this.infoOpen,
  });

  final AccountSession session;
  final OpenThread thread;
  final Thread? current;
  final bool typing;
  final String? presence;
  final bool online;
  final int? memberCount;
  final bool isGroup;
  final VoidCallback? onBack;
  final VoidCallback onSearch;
  final VoidCallback onInfo;
  final bool infoOpen;

  @override
  Widget build(BuildContext context) {
    final z = context.z;
    final wide = LayoutScope.wideOf(context);
    final name = current?.name.trim().isNotEmpty == true ? current!.name : thread.name;
    final avatarUrl = current?.avatarUrl ?? thread.avatarUrl;
    final fg = wide ? z.textPrimary : z.textOnBrand;
    final subColor = wide ? z.textTertiary : z.textOnBrand.withValues(alpha: 0.9);
    final subtitle = isGroup ? (memberCount == null ? null : context.tr('members', [memberCount])) : (typing ? context.tr('typingShort') : presence);
    final row = Row(
      children: [
        if (onBack != null)
          ZIconButton(key: const Key('chatBack'), icon: ZIcons.back, label: context.tr('back'), color: fg, hoverColor: z.headerField, iconSize: 24, onPressed: onBack)
        else
          const SizedBox(width: ZSpace.s16),
        Expanded(
          child: ZPressable(
            key: const Key('chatHeaderInfo'),
            onTap: onInfo,
            radius: ZRadius.row,
            hoverColor: wide ? null : z.headerField,
            pressedColor: wide ? null : z.headerField,
            semanticLabel: context.tr('openInfoLabel', [name]),
            minSize: wide ? null : ZSizes.touchTarget,
            child: Row(
              children: [
                ZAvatar(session: session, id: thread.id, name: name, url: avatarUrl, size: wide ? 48 : 40, group: isGroup, status: !isGroup && online ? AvatarStatus.online : AvatarStatus.none),
                SizedBox(width: wide ? ZSpace.s12 : ZSpace.s8),
                Expanded(
                  child: Column(
                    mainAxisAlignment: MainAxisAlignment.center,
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(name, key: const Key('chatTitle'), maxLines: 1, overflow: TextOverflow.ellipsis, style: z.text.title.copyWith(color: fg)),
                      if (subtitle != null)
                        Text(subtitle, key: const Key('chatSubtitle'), maxLines: 1, overflow: TextOverflow.ellipsis, style: (wide ? z.text.rowSub : z.text.caption).copyWith(color: subColor)),
                    ],
                  ),
                ),
              ],
            ),
          ),
        ),
        ZIconButton(key: const Key('chatSearch'), icon: ZIcons.search, label: context.tr('searchInChat'), color: wide ? null : fg, hoverColor: wide ? null : z.headerField, onPressed: onSearch),
        ZIconButton(
          key: const Key('chatInfo'),
          icon: ZIcons.info,
          label: context.tr('conversationInfo'),
          color: wide ? null : fg,
          hoverColor: wide ? null : z.headerField,
          selected: wide && infoOpen,
          onPressed: onInfo,
        ),
        SizedBox(width: wide ? ZSpace.s12 : ZSpace.s4),
      ],
    );
    if (!wide) return ZPhoneHeader(child: row);
    return Container(
      height: ZSizes.wideChatHeader,
      decoration: BoxDecoration(color: z.layer, border: Border(bottom: BorderSide(color: z.divider))),
      child: row,
    );
  }
}

class _SearchBar extends StatelessWidget {
  const _SearchBar({required this.controller, required this.count, required this.index, required this.onChanged, required this.onPrevious, required this.onNext, required this.onClose});

  final TextEditingController controller;
  final int count;
  final int index;
  final ValueChanged<String> onChanged;
  final VoidCallback onPrevious;
  final VoidCallback onNext;
  final VoidCallback onClose;

  @override
  Widget build(BuildContext context) {
    final z = context.z;
    final wide = LayoutScope.wideOf(context);
    final fg = wide ? z.textSecondary : z.textOnBrand;
    final content = Column(
      mainAxisSize: MainAxisSize.min,
      children: [
        SizedBox(
          height: wide ? 44 : ZSizes.phoneHeader - 16,
          child: Row(
            children: [
              ZIconButton(key: const Key('chatSearchClose'), icon: ZIcons.back, label: context.tr('closeSearch'), color: fg, hoverColor: wide ? null : z.headerField, onPressed: onClose),
              Expanded(
                child: CallbackShortcuts(
                  bindings: {const SingleActivator(LogicalKeyboardKey.escape): onClose},
                  child: ZSearchField(
                    key: const Key('chatSearchField'),
                    controller: controller,
                    hint: context.tr('searchInChat'),
                    clearLabel: context.tr('clear'),
                    onHeader: !wide,
                    autofocus: true,
                    onChanged: onChanged,
                    onSubmitted: (_) => onPrevious(),
                  ),
                ),
              ),
              const SizedBox(width: ZSpace.s8),
              Text(
                count == 0 ? context.tr('searchNoHits') : '$index/$count',
                key: const Key('chatSearchCounter'),
                style: z.text.caption.copyWith(color: wide ? z.textTertiary : z.textOnBrand),
              ),
              ZIconButton(key: const Key('chatSearchPrev'), icon: ZIcons.chevronUp, label: context.tr('previousResult'), color: fg, hoverColor: wide ? null : z.headerField, onPressed: count == 0 ? null : onPrevious),
              ZIconButton(key: const Key('chatSearchNext'), icon: ZIcons.chevronDown, label: context.tr('nextResult'), color: fg, hoverColor: wide ? null : z.headerField, onPressed: count == 0 ? null : onNext),
              const SizedBox(width: ZSpace.s4),
            ],
          ),
        ),
        Padding(
          padding: const EdgeInsets.only(bottom: ZSpace.s4),
          child: Text(context.tr('searchLoadedOnly'), style: z.text.caption.copyWith(color: wide ? z.textTertiary : z.textOnBrand.withValues(alpha: 0.9))),
        ),
      ],
    );
    if (!wide) return ZPhoneHeader(child: content);
    return Container(
      constraints: const BoxConstraints(minHeight: ZSizes.wideChatHeader),
      decoration: BoxDecoration(color: z.layer, border: Border(bottom: BorderSide(color: z.divider))),
      alignment: Alignment.center,
      child: content,
    );
  }
}
