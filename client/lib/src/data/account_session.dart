import 'dart:async';
import 'dart:math';

import 'package:flutter/foundation.dart';

import '../domain/models.dart';
import '../domain/services.dart';
import 'mapping.dart';
import 'media_cache.dart';
import 'protocol/managed_channel.dart';
import 'protocol/noise_channel.dart';
import 'vault.dart';

const int _pageSize = 50;
const int _maxSyncPages = 10000;
const int _maxLocked = 5000;
const int _maxConcurrentMedia = 6;
const String _localScheme = 'local://';
const Duration _mediaTimeout = Duration(seconds: 120);

String _threadKey(String id, ThreadType type) => '${type.name}:$id';

int _intOf(Object? value) => value is num ? value.toInt() : 0;

class _MessageList {
  _MessageList(this.threadId, this.type);

  final String threadId;
  final ThreadType type;
  final ValueNotifier<List<Message>> notifier = ValueNotifier(const []);
  final ValueNotifier<LoadState> load = ValueNotifier(LoadState.loading);
  final List<Message> items = [];
  bool loaded = false;
  bool hasOlder = true;
  bool dirty = false;
  Future<void>? loading;
  Future<bool>? loadingOlder;

  void flush() {
    if (!dirty) return;
    dirty = false;
    notifier.value = List.unmodifiable(items);
  }

  void _insertByTs(Message message) {
    var index = items.length;
    while (index > 0 && items[index - 1].ts > message.ts) {
      index--;
    }
    items.insert(index, message);
  }

  void insertLocal(Message message) {
    items.add(message);
    dirty = true;
  }

  int _indexOf(Message server) {
    final byId = items.indexWhere((m) => m.id == server.id);
    if (byId >= 0) return byId;
    final cliId = server.cliId;
    if (cliId == null || cliId.isEmpty) return -1;
    return items.indexWhere((m) => m.sendState != SendState.sent && m.cliId == cliId);
  }

  /// Inserts or replaces a server message. With [onlyKnownRange] a message
  /// older than the loaded window is ignored, it belongs to an unloaded page.
  void upsert(Message server, {bool onlyKnownRange = false}) {
    final index = _indexOf(server);
    if (index >= 0) {
      items[index] = _keepLocalParts(items[index], server);
      dirty = true;
      return;
    }
    if (onlyKnownRange && hasOlder && (items.isEmpty || server.ts < items.first.ts)) return;
    _insertByTs(server);
    dirty = true;
  }

  // The echo of an own send is thinner than what the sender already shows:
  // an upload has no url until Zalo echoes it, and a quote comes back as the
  // raw payload only. The sender keeps its local version of those parts.
  Message _keepLocalParts(Message local, Message server) {
    var result = server;
    if (local.sendState != SendState.sent && local.quote != null && server.quote != null) {
      result = copyMessage(result, quote: local.quote);
    }
    // Never let an echo without a sticker URL wipe out the sender's known URL.
    if (local.sticker != null &&
        server.sticker != null &&
        (server.sticker!.url == null || server.sticker!.url!.isEmpty) &&
        local.sticker!.url != null &&
        local.sticker!.url!.isNotEmpty) {
      result = copyMessage(result, sticker: local.sticker);
    }
    final hasLocalMedia = local.attachments.any((a) => a.url.startsWith(_localScheme));
    if (!hasLocalMedia || local.attachments.length != server.attachments.length) return result;
    var changed = false;
    final merged = <Attachment>[];
    for (var i = 0; i < server.attachments.length; i++) {
      final theirs = server.attachments[i];
      final ours = local.attachments[i];
      if (theirs.url.isEmpty && ours.url.startsWith(_localScheme)) {
        changed = true;
        merged.add(Attachment(
          kind: theirs.kind,
          url: ours.url,
          thumbUrl: theirs.thumbUrl,
          name: theirs.name ?? ours.name,
          size: theirs.size ?? ours.size,
          width: theirs.width,
          height: theirs.height,
          durationMs: theirs.durationMs,
        ));
      } else {
        merged.add(theirs);
      }
    }
    return changed ? copyMessage(result, attachments: merged) : result;
  }

  void confirm(String cliId, String? msgId) {
    final index = items.indexWhere((m) => m.sendState != SendState.sent && m.cliId == cliId);
    if (index < 0) return;
    items[index] = copyMessage(
      items[index],
      id: msgId == null || msgId.isEmpty ? null : msgId,
      sendState: SendState.sent,
      sendErrorCode: null,
    );
    dirty = true;
  }

  void markFailed(String cliId, [String? code]) {
    final index = items.indexWhere((m) => m.sendState == SendState.sending && m.cliId == cliId);
    if (index < 0) return;
    items[index] = copyMessage(items[index], sendState: SendState.failed, sendErrorCode: code);
    dirty = true;
  }

  void remove(String msgId) {
    final before = items.length;
    items.removeWhere((m) => m.id == msgId);
    if (items.length != before) dirty = true;
  }

  Message? get oldestServer {
    for (final message in items) {
      if (message.sendState == SendState.sent) return message;
    }
    return null;
  }

  /// Replaces a message that is already listed; never inserts.
  bool replaceExisting(Message server) {
    final index = items.indexWhere((m) => m.id == server.id);
    if (index < 0) return false;
    items[index] = server;
    dirty = true;
    return true;
  }

  Message? pending(String cliId) {
    for (final message in items) {
      if (message.cliId == cliId && message.sendState != SendState.sent) return message;
    }
    return null;
  }

  void markSending(String cliId) {
    final index = items.indexWhere((m) => m.sendState == SendState.failed && m.cliId == cliId);
    if (index < 0) return;
    items[index] = copyMessage(items[index], sendState: SendState.sending, sendErrorCode: null);
    dirty = true;
  }
}

class _Outgoing {
  _Outgoing(this.list, this.cliId, this.action);
  final _MessageList list;
  final String cliId;
  final Future<dynamic> Function(NoiseChannel channel) action;
  bool running = false;
}

class RealAccountSession implements AccountSession {
  RealAccountSession(this.slot, ChannelKeys keys, this._vault) {
    _vault.root.addListener(_reopenLocked);
    _channel = ManagedChannel(
      keys: keys,
      path: '/v1/account/$slot',
      prologue: 'zalos/1/account/$slot',
      onConnected: _sync,
      onEvent: _onEvent,
    );
    _channel.start();
    _channel.state.addListener(_onLinkState);
  }

  @override
  final String slot;

  final VaultController _vault;
  late final ManagedChannel _channel;
  // Sealed records that did not open, by message id, kept to be mapped again
  // once the vault is ready.
  final Map<String, Json> _locked = {};
  final Map<String, _Outgoing> _outgoing = {};
  final ValueNotifier<List<Thread>> _threads = ValueNotifier(const []);
  final ValueNotifier<LoadState> _threadsLoad = ValueNotifier(LoadState.loading);
  Future<void>? _threadsReload;
  final Map<String, Thread> _threadMap = {};
  final Map<String, _MessageList> _lists = {};
  final StreamController<TypingEvent> _typing = StreamController<TypingEvent>.broadcast();
  final StreamController<BoardUpdateEvent> _boardUpdates = StreamController<BoardUpdateEvent>.broadcast();
  final MediaCache _media = MediaCache();
  final Map<String, Future<Uint8List>> _mediaInFlight = {};
  final List<Completer<void>> _mediaQueue = [];
  int _mediaActive = 0;
  final List<ChannelEvent> _buffered = [];
  final Random _random = Random.secure();
  int _lastSeq = 0;
  bool _syncing = false;
  bool _threadsDirty = false;
  bool _resetPending = false;
  bool _reloading = false;
  bool _reloadAgain = false;
  bool _disposed = false;

  @override
  ValueListenable<LinkState> get state => _channel.state;

  @override
  ValueListenable<List<Thread>> get threads => _threads;

  @override
  ValueListenable<LoadState> get threadsLoad => _threadsLoad;

  @override
  Stream<TypingEvent> get typing => _typing.stream;

  @override
  Stream<BoardUpdateEvent> get boardUpdates => _boardUpdates.stream;

  int get lastSeq => _lastSeq;

  void wake() {
    if (_disposed) return;
    unawaited(_channel.wake(probe: _sync));
  }

  // ---- sync and events ----

  Future<void> _sync(NoiseChannel channel) async {
    _syncing = true;
    _buffered.clear();
    var reset = false;
    final savedSeq = _lastSeq;
    if (_threadsLoad.value == LoadState.failed) _setThreadsLoad(LoadState.loading);
    try {
      for (var page = 0; page < _maxSyncPages; page++) {
        final result = asJson(await channel.request('sync', {'sinceSeq': _lastSeq}));
        final latestSeq = result['latestSeq'];
        final latest = latestSeq is num ? latestSeq.toInt() : _lastSeq;
        if (result['reset'] == true || latest < _lastSeq) {
          reset = true;
          _lastSeq = 0;
        }
        final events = asJsonList(result['events']);
        for (final item in events) {
          final seq = item['seq'];
          _receive(ChannelEvent('${item['event']}', seq is num ? seq.toInt() : null, asJson(item['data'])));
        }
        if (result['more'] != true || events.isEmpty) {
          if (latest > _lastSeq) _lastSeq = latest;
          break;
        }
      }
      if (reset || _resetPending || _threadsLoad.value != LoadState.ready) {
        _resetPending = false;
        try {
          await _loadThreads(channel.request);
        } catch (_) {
          // Roll the seq back so the next sync replays the reset instead
          // of sitting past events whose thread list never loaded.
          if (reset) _lastSeq = savedSeq;
          _resetPending = true;
          rethrow;
        }
      }
    } catch (_) {
      if (_threadsLoad.value != LoadState.ready) _setThreadsLoad(LoadState.failed);
      rethrow;
    } finally {
      _syncing = false;
    }
    final buffered = List.of(_buffered);
    _buffered.clear();
    for (final event in buffered) {
      _receive(event);
    }
    _flush();
    for (final list in _lists.values) {
      if (reset || !list.loaded) _ensureLoaded(list, force: true);
    }
  }

  // A connect attempt that never reached the sync still ends the first load.
  void _onLinkState() {
    final link = _channel.state.value;
    if (_threadsLoad.value != LoadState.loading || _threadsReload != null) return;
    if (link == LinkState.disconnected || link == LinkState.unauthorized) _setThreadsLoad(LoadState.failed);
  }

  void _setThreadsLoad(LoadState value) {
    if (!_disposed) _threadsLoad.value = value;
  }

  void _onEvent(ChannelEvent event) {
    if (_syncing) {
      _buffered.add(event);
      return;
    }
    final seq = event.seq;
    if (seq != null && seq > _lastSeq + 1) {
      // Live events must be contiguous; a gap means something was lost, so
      // resync rather than apply events out of order.
      unawaited(_syncNow());
      return;
    }
    _receive(event);
    _flush();
    if (_resetPending) {
      _resetPending = false;
      unawaited(_reloadAll());
    }
  }

  Future<void> _syncNow() async {
    if (_syncing || _disposed) return;
    try {
      await _channel.use(_sync);
    } catch (_) {
      // The next event or reconnect retries.
    }
  }

  void _receive(ChannelEvent event) {
    final seq = event.seq;
    if (seq != null) {
      if (seq <= _lastSeq) return;
      _lastSeq = seq;
    }
    try {
      _apply(event);
    } catch (e, st) {
      // A malformed event must not break the channel.
      assert(false, 'event apply failed: $e\n$st');
    }
  }

  void _apply(ChannelEvent event) {
    switch (event.name) {
      case 'message.new':
        final message = _message(asJson(event.data['message']));
        _lists[_threadKey(message.threadId, message.threadType)]?.upsert(message);
      case 'message.updated':
        final message = _message(asJson(event.data['message']));
        final key = _threadKey(message.threadId, message.threadType);
        _lists[key]?.upsert(message, onlyKnownRange: true);
        final thread = _threadMap[key];
        if (thread != null && thread.lastMessage?.id == message.id) {
          _threadMap[key] = copyThread(thread, lastMessage: message);
          _threadsDirty = true;
        }
      case 'message.deleted':
        final threadId = '${event.data['threadId']}';
        final msgId = '${event.data['msgId']}';
        for (final type in ThreadType.values) {
          _lists[_threadKey(threadId, type)]?.remove(msgId);
        }
      case 'thread.updated':
        final thread = _thread(asJson(event.data['thread']));
        if (thread.id.isEmpty) return;
        _threadMap[_threadKey(thread.id, thread.type)] = thread;
        _threadsDirty = true;
      case 'threads.reset':
        _resetPending = true;
      case 'thread.deleted':
        final threadId = '${event.data['threadId']}';
        final type = threadTypeFromWire(event.data['threadType']);
        _purgeThread(threadId, type);
      case 'contacts.changed':
        _contactsDirty = true;
      case 'typing':
        if (!_typing.isClosed) _typing.add(typingEventFromJson(event.data));
      case 'board.updated':
        if (!_boardUpdates.isClosed) _boardUpdates.add(boardUpdateEventFromJson(event.data));
    }
  }

  void _purgeThread(String threadId, ThreadType type) {
    _threadMap.remove(_threadKey(threadId, type));
    _lists.remove(_threadKey(threadId, type));
    _threadsDirty = true;
    _flush();
  }

  void _flush() {
    if (_disposed) return;
    if (_threadsDirty) {
      _threadsDirty = false;
      final sorted = _threadMap.values.toList()
        ..sort((a, b) {
          if (a.pinned != b.pinned) return a.pinned ? -1 : 1;
          final byTs = b.lastTs.compareTo(a.lastTs);
          return byTs != 0 ? byTs : a.id.compareTo(b.id);
        });
      _threads.value = List.unmodifiable(sorted);
    }
    for (final list in _lists.values) {
      list.flush();
    }
  }

  Future<void> _loadThreads(Future<dynamic> Function(String method, [Map<String, dynamic> params]) request) async {
    final result = asJson(await request('threads.list'));
    final loaded = <String, Thread>{};
    for (final row in asJsonList(result['threads'])) {
      final thread = _thread(row);
      if (thread.id.isNotEmpty) loaded[_threadKey(thread.id, thread.type)] = thread;
    }
    _threadMap
      ..clear()
      ..addAll(loaded);
    _threadsDirty = true;
    _flush();
    _setThreadsLoad(LoadState.ready);
  }

  @override
  Future<void> reloadThreads() => _threadsReload ??= _reloadThreads().whenComplete(() {
        _threadsReload = null;
      });

  Future<void> _reloadThreads() async {
    if (_disposed) return;
    _setThreadsLoad(LoadState.loading);
    try {
      await _loadThreads(_channel.request);
    } catch (_) {
      _setThreadsLoad(LoadState.failed);
    }
  }

  // ---- sealed records ----

  Json? _open(String msgId, String sealed) => _vault.openRecord(slot, msgId, sealed);

  Message _message(Json record) {
    var locked = false;
    final message = messageFromJson(record, open: _open, onLocked: (_) => locked = true);
    if (locked) {
      _locked.remove(message.id);
      _locked[message.id] = record;
      while (_locked.length > _maxLocked) {
        _locked.remove(_locked.keys.first);
      }
    } else {
      _locked.remove(message.id);
    }
    return message;
  }

  Thread _thread(Json json) => threadFromJson(json, open: _open, onLocked: _rememberLocked);

  void _rememberLocked(Json record) {
    final id = '${record['id']}';
    _locked.remove(id);
    _locked[id] = record;
  }

  void _reopenLocked() {
    if (_disposed || !_vault.isReady || _locked.isEmpty) return;
    for (final record in _locked.values.toList()) {
      final message = _message(record);
      if (_locked.containsKey(message.id)) continue;
      final key = _threadKey(message.threadId, message.threadType);
      _lists[key]?.replaceExisting(message);
      final thread = _threadMap[key];
      if (thread != null && thread.lastMessage?.id == message.id) {
        _threadMap[key] = copyThread(thread, lastMessage: message);
        _threadsDirty = true;
      }
    }
    _flush();
  }

  Future<void> _reloadAll() async {
    if (_reloading) {
      _reloadAgain = true;
      return;
    }
    _reloading = true;
    try {
      do {
        _reloadAgain = false;
        await _loadThreads(_channel.request);
        for (final list in _lists.values) {
          _ensureLoaded(list, force: true);
        }
      } while (_reloadAgain && !_disposed);
    } catch (_) {
      // The next sync reloads.
      _resetPending = true;
    } finally {
      _reloading = false;
    }
  }

  // ---- messages ----

  _MessageList _list(String threadId, ThreadType type) {
    final list = _lists.putIfAbsent(_threadKey(threadId, type), () => _MessageList(threadId, type));
    _ensureLoaded(list);
    return list;
  }

  void _ensureLoaded(_MessageList list, {bool force = false}) {
    if (_disposed || list.loading != null || (list.loaded && !force)) return;
    // A refresh of a loaded page keeps showing it as ready.
    if (!list.loaded) list.load.value = LoadState.loading;
    list.loading = _loadLatest(list).then<void>((_) {}, onError: (Object _) {
      if (!_disposed && !list.loaded) list.load.value = LoadState.failed;
    }).whenComplete(() {
      list.loading = null;
    });
  }

  Future<void> _loadLatest(_MessageList list) async {
    final page = await _fetchPage(list, null);
    final first = !list.loaded;
    for (final message in page.messages) {
      list.upsert(message);
    }
    list.loaded = true;
    if (first) list.hasOlder = page.hasMore;
    list.dirty = true;
    list.flush();
    if (!_disposed) list.load.value = LoadState.ready;
  }

  Future<({List<Message> messages, bool hasMore})> _fetchPage(_MessageList list, Message? before) async {
    final result = asJson(await _channel.request('messages.list', {
      'threadId': list.threadId,
      'threadType': threadTypeToWire(list.type),
      'limit': _pageSize,
      if (before != null) 'before': {'ts': before.ts, 'id': before.id},
    }));
    return (
      messages: [for (final item in asJsonList(result['messages'])) _message(item)],
      hasMore: result['hasMore'] == true,
    );
  }

  @override
  ValueListenable<List<Message>> messages(String threadId, ThreadType type) => _list(threadId, type).notifier;

  @override
  ValueListenable<LoadState> messagesLoad(String threadId, ThreadType type) => _list(threadId, type).load;

  @override
  Future<void> reloadMessages(String threadId, ThreadType type) {
    final list = _list(threadId, type);
    _ensureLoaded(list, force: true);
    return list.loading ?? Future.value();
  }

  @override
  Future<bool> loadOlder(String threadId, ThreadType type) {
    final list = _list(threadId, type);
    return list.loadingOlder ??= _loadOlder(list).whenComplete(() {
      list.loadingOlder = null;
    });
  }

  Future<bool> _loadOlder(_MessageList list) async {
    final loading = list.loading;
    if (loading != null) await loading;
    if (!list.loaded) await _loadLatest(list);
    if (!list.hasOlder) return false;
    final oldest = list.oldestServer;
    if (oldest == null) return false;
    final page = await _fetchPage(list, oldest);
    for (final message in page.messages) {
      list.upsert(message);
    }
    list.hasOlder = page.hasMore && page.messages.isNotEmpty;
    list.flush();
    return page.messages.isNotEmpty;
  }

  // ---- sending ----

  String _newCliId() {
    final buffer = StringBuffer('z');
    for (var i = 0; i < 12; i++) {
      buffer.write(_random.nextInt(256).toRadixString(16).padLeft(2, '0'));
    }
    return buffer.toString();
  }

  Message _localMessage(
    String cliId,
    String threadId,
    ThreadType type,
    MessageKind kind, {
    String? text,
    List<Attachment> attachments = const [],
    StickerRef? sticker,
    ContactCard? card,
    Quote? quote,
    List<Mention> mentions = const [],
    List<StyleRun> styles = const [],
    MessageUrgency? urgency,
    int? ttl,
  }) =>
      Message(
        id: cliId,
        cliId: cliId,
        threadId: threadId,
        threadType: type,
        senderId: '',
        senderName: '',
        ts: DateTime.now().millisecondsSinceEpoch,
        isSelf: true,
        kind: kind,
        text: text,
        attachments: attachments,
        sticker: sticker,
        card: card,
        quote: quote,
        mentions: mentions,
        styles: styles,
        urgency: urgency,
        ttl: ttl,
        sendState: SendState.sending,
      );

  /// Shows [local] at once, then resolves it from the RPC outcome. A failure
  /// is reported through [SendState.failed], not thrown, and the send stays
  /// available to [resend].
  Future<void> _send(Message local, Future<dynamic> Function(NoiseChannel channel) action) {
    final list = _list(local.threadId, local.threadType);
    final outgoing = _Outgoing(list, local.cliId!, action);
    _outgoing[outgoing.cliId] = outgoing;
    list.insertLocal(local);
    list.flush();
    return _attempt(outgoing);
  }

  Future<void> _attempt(_Outgoing outgoing) async {
    if (outgoing.running) return;
    outgoing.running = true;
    final list = outgoing.list;
    try {
      final result = asJson(await _channel.use(outgoing.action));
      final msgId = result['msgId'];
      list.confirm(outgoing.cliId, msgId == null ? null : '$msgId');
      _outgoing.remove(outgoing.cliId);
    } catch (error) {
      // The server rejects a send with a code (`window_expired`, ...); a
      // transport failure has none and stays a generic retry.
      list.markFailed(outgoing.cliId, error is RpcException && error.code.isNotEmpty ? error.code : null);
    } finally {
      outgoing.running = false;
    }
    if (!_disposed) list.flush();
  }

  @override
  Future<void> resend(Message message) async {
    final cliId = message.cliId;
    final outgoing = cliId == null ? null : _outgoing[cliId];
    if (outgoing == null || outgoing.running) return;
    if (outgoing.list.pending(outgoing.cliId) == null) {
      // Already delivered (the echo arrived after the failure) or removed.
      _outgoing.remove(outgoing.cliId);
      return;
    }
    outgoing.list.markSending(outgoing.cliId);
    outgoing.list.flush();
    await _attempt(outgoing);
  }

  @override
  Future<void> sendText(
    String threadId,
    ThreadType type,
    String text, {
    Message? quote,
    List<Mention> mentions = const [],
    List<StyleRun> styles = const [],
    MessageUrgency? urgency,
    int? ttl,
  }) {
    final cliId = _newCliId();
    // The server no longer holds message content, so quoting needs the
    // opened original payload. A message without it is sent unquoted.
    final raw = quote?.raw;
    final quoted = quote == null || raw == null
        ? null
        : Quote(msgId: quote.id, senderId: quote.senderId, senderName: quote.senderName, text: quote.text ?? '');
    final expires = ttl != null && ttl > 0 ? ttl : null;
    final local = _localMessage(
      cliId,
      threadId,
      type,
      MessageKind.text,
      text: text,
      quote: quoted,
      mentions: mentions,
      styles: styles,
      urgency: urgency,
      ttl: expires,
    );
    return _send(
      local,
      (channel) => channel.request('messages.sendText', {
        'threadId': threadId,
        'threadType': threadTypeToWire(type),
        'cliId': cliId,
        'text': text,
        if (quoted != null) 'quote': {'raw': raw},
        if (mentions.isNotEmpty) 'mentions': [for (final mention in mentions) mentionToJson(mention)],
        if (styles.isNotEmpty) 'styles': [for (final run in styles) styleRunToJson(run)],
        if (urgency != null) 'urgency': messageUrgencyToWire(urgency),
        if (expires != null) 'ttl': expires,
      }),
    );
  }

  @override
  Future<void> sendFile(
    String threadId,
    ThreadType type,
    OutgoingFile file, {
    String? caption,
    MessageUrgency? urgency,
    int? ttl,
  }) {
    const uploadable = {MessageKind.image, MessageKind.video, MessageKind.file, MessageKind.voice, MessageKind.gif};
    // An animated image is sent as a gif even when the caller only knows
    // the file name, so the receiver renders it inline.
    final kind = file.kind == MessageKind.gif || file.name.toLowerCase().endsWith('.gif')
        ? MessageKind.gif
        : uploadable.contains(file.kind)
            ? file.kind
            : MessageKind.file;
    final cliId = _newCliId();
    final localUrl = '$_localScheme$cliId';
    final expires = ttl != null && ttl > 0 ? ttl : null;
    _media.put(localUrl, file.bytes);
    final local = _localMessage(
      cliId,
      threadId,
      type,
      kind,
      text: caption,
      attachments: [Attachment(kind: kind, url: localUrl, name: file.name, size: file.bytes.length)],
      urgency: urgency,
      ttl: expires,
    );
    return _send(local, (channel) {
      final stream = channel.sendBlob(file.bytes);
      return channel.request(
        'messages.sendMedia',
        {
          'threadId': threadId,
          'threadType': threadTypeToWire(type),
          'cliId': cliId,
          'kind': messageKindToWire(kind),
          'name': file.name,
          'stream': stream,
          if (caption != null && caption.isNotEmpty) 'caption': caption,
          if (urgency != null) 'urgency': messageUrgencyToWire(urgency),
          if (expires != null) 'ttl': expires,
        },
        _mediaTimeout,
      );
    });
  }

  @override
  Future<void> sendSticker(String threadId, ThreadType type, StickerRef sticker) {
    final cliId = _newCliId();
    final local = _localMessage(cliId, threadId, type, MessageKind.sticker, sticker: sticker);
    return _send(
      local,
      (channel) => channel.request('messages.sendSticker', {
        'threadId': threadId,
        'threadType': threadTypeToWire(type),
        'cliId': cliId,
        'sticker': stickerToJson(sticker),
      }),
    );
  }

  @override
  Future<void> sendCard(String threadId, ThreadType type, ContactCard card) {
    final cliId = _newCliId();
    final local = _localMessage(cliId, threadId, type, MessageKind.card, text: card.displayName, card: card);
    return _send(
      local,
      (channel) => channel.request('messages.sendCard', {
        'threadId': threadId,
        'threadType': threadTypeToWire(type),
        'cliId': cliId,
        'userId': card.uid,
        if (card.phone != null && card.phone!.isNotEmpty) 'phoneNumber': card.phone,
      }),
    );
  }

  @override
  Future<LinkPreview> parseLink(String link) async {
    final result = asJson(await _channel.request('messages.parseLink', {'link': link}));
    return linkPreviewFromJson(asJson(result['preview']));
  }

  @override
  Future<void> sendLink(String threadId, ThreadType type, String link, {String? msg, int? ttl}) {
    final cliId = _newCliId();
    final note = msg != null && msg.isNotEmpty ? msg : null;
    final expires = ttl != null && ttl > 0 ? ttl : null;
    final local = _localMessage(
      cliId,
      threadId,
      type,
      MessageKind.link,
      text: note ?? link,
      attachments: [Attachment(kind: MessageKind.link, url: link)],
      ttl: expires,
    );
    return _send(
      local,
      (channel) => channel.request('messages.sendLink', {
        'threadId': threadId,
        'threadType': threadTypeToWire(type),
        'cliId': cliId,
        'link': link,
        if (note != null) 'msg': note,
        if (expires != null) 'ttl': expires,
      }),
    );
  }

  @override
  Future<void> sendBankCard(String threadId, ThreadType type, BankCard card) async {
    // No optimistic record: the real API answers without a msgId and the
    // echo cannot be correlated to the cliId, so the bubble is left to the
    // sequenced message.new. The cliId only guards against a double send.
    await _channel.request('messages.sendBankCard', {
      'threadId': threadId,
      'threadType': threadTypeToWire(type),
      'cliId': _newCliId(),
      'bin': card.bin,
      'accountNumber': card.accountNumber,
      if (card.holderName != null && card.holderName!.isNotEmpty) 'holderName': card.holderName,
    });
  }

  @override
  Future<List<BankInfo>> banks() async {
    final result = asJson(await _channel.request('banks.list'));
    return [for (final item in asJsonList(result['banks'])) bankInfoFromJson(item)];
  }

  @override
  Future<BankAccounts> bankAccounts({int page = 0, int limit = 20}) async =>
      bankAccountsFromJson(asJson(await _channel.request('banks.accounts', {'page': page, 'limit': limit})));

  @override
  Future<QuickMessages> quickMessages() async =>
      quickMessagesFromJson(asJson(await _channel.request('quickMessages.list')));

  /// Sends a quick-message draft, uploading its media first when present.
  Future<({QuickMessage item, int version})> _quickMessage(
    String method,
    Map<String, dynamic> params,
    OutgoingFile? media,
  ) async {
    final result = asJson(await _channel.use((channel) {
      final body = {...params};
      if (media == null) return channel.request(method, body);
      body['mediaStream'] = channel.sendBlob(media.bytes);
      body['mediaName'] = media.name;
      return channel.request(method, body, _mediaTimeout);
    }));
    return (item: quickMessageFromJson(asJson(result['item'])), version: _intOf(result['version']));
  }

  @override
  Future<({QuickMessage item, int version})> addQuickMessage(QuickMessageDraft draft) => _quickMessage(
        'quickMessages.add',
        {'keyword': draft.keyword, 'title': draft.title},
        draft.media,
      );

  @override
  Future<({QuickMessage item, int version})> updateQuickMessage(int id, QuickMessageDraft draft) => _quickMessage(
        'quickMessages.update',
        {'id': id, 'keyword': draft.keyword, 'title': draft.title},
        draft.media,
      );

  @override
  Future<({List<int> itemIds, int version})> removeQuickMessages(List<int> ids) async {
    final result = asJson(await _channel.request('quickMessages.remove', {'ids': ids}));
    final rawIds = result['itemIds'];
    final list = rawIds is List ? rawIds : const <Object?>[];
    return (
      itemIds: [for (final id in list) if (id is num) id.toInt()],
      version: _intOf(result['version']),
    );
  }

  // ---- plain RPCs ----

  Map<String, dynamic> _messageRef(Message message) => {
        'msgId': message.id,
        'threadId': message.threadId,
        'threadType': threadTypeToWire(message.threadType),
      };

  @override
  Future<List<StickerRef>> searchStickers(String query) async {
    final result = asJson(await _channel.request('stickers.search', {'query': query}));
    return [for (final item in asJsonList(result['stickers'])) stickerFromJson(item)];
  }

  @override
  Future<List<StickerRef>> stickerCategory(int cateId) async {
    final result = asJson(await _channel.request('stickers.category', {'cateId': cateId}));
    return [for (final item in asJsonList(result['stickers'])) stickerFromJson(item)];
  }

  // ---- Pins, Group Board, Polls, Notes & Reminders ----

  @override
  Future<PinBoardState> listPins(String threadId, ThreadType type) async {
    final result = asJson(await _channel.request('pins.list', {
      'threadId': threadId,
      'threadType': threadTypeToWire(type),
    }));
    return pinBoardStateFromJson(result);
  }

  @override
  Future<List<PinnedTopic>> listBoard(String groupId, {int page = 1, int count = 20}) async {
    final result = asJson(await _channel.request('board.list', {
      'groupId': groupId,
      'page': page,
      'count': count,
    }));
    return [for (final item in asJsonList(result['items'])) pinnedTopicFromJson(item)];
  }

  @override
  Future<PinBoardState> pinMessage(Message message, {required String title}) async {
    final thumb = message.attachments.isNotEmpty
        ? (message.attachments.first.thumbUrl ?? message.attachments.first.url)
        : null;
    final href = message.kind == MessageKind.link && message.attachments.isNotEmpty
        ? message.attachments.first.url
        : null;
    final result = asJson(await _channel.request('pins.pinMessage', {
      'threadId': message.threadId,
      'threadType': threadTypeToWire(message.threadType),
      'msgId': message.id,
      if (message.cliId != null && message.cliId!.isNotEmpty) 'cliMsgId': message.cliId,
      'senderId': message.senderId,
      'senderName': message.senderName,
      'title': title,
      'kind': messageKindToWire(message.kind),
      if (thumb != null && thumb.isNotEmpty) 'thumbUrl': thumb,
      if (href != null && href.isNotEmpty) 'href': href,
    }));
    return pinBoardStateFromJson(result);
  }

  @override
  Future<void> pinBoardItem(String groupId, String topicId, int topicType) async {
    await _channel.request('pins.pinItem', {
      'groupId': groupId,
      'topicId': topicId,
      'topicType': topicType,
    });
  }

  @override
  Future<PinBoardState> unpinTopic(String threadId, ThreadType type, String topicId, int topicType) async {
    final result = asJson(await _channel.request('pins.unpin', {
      'threadId': threadId,
      'threadType': threadTypeToWire(type),
      'topicId': topicId,
      'topicType': topicType,
    }));
    return pinBoardStateFromJson(result);
  }

  @override
  Future<PollDetail> createPoll(
    String groupId, {
    required String question,
    required List<String> options,
    int expiredTime = 0,
    bool allowMultiChoices = true,
    bool allowAddNewOption = true,
    bool hideVotePreview = false,
    bool isAnonymous = false,
    bool pin = false,
  }) async {
    final result = asJson(await _channel.request('polls.create', {
      'groupId': groupId,
      'question': question,
      'options': options,
      'expiredTime': expiredTime,
      'allowMultiChoices': allowMultiChoices,
      'allowAddNewOption': allowAddNewOption,
      'hideVotePreview': hideVotePreview,
      'isAnonymous': isAnonymous,
      'pin': pin,
    }));
    return pollDetailFromJson(asJson(result['poll']));
  }

  @override
  Future<PollDetail> pollDetail(int pollId, {String? groupId}) async {
    final result = asJson(await _channel.request('polls.detail', {
      'pollId': pollId,
      if (groupId != null && groupId.isNotEmpty) 'groupId': groupId,
    }));
    return pollDetailFromJson(asJson(result['poll']));
  }

  @override
  Future<PollDetail> votePoll(int pollId, List<int> optionIds, {String? groupId}) async {
    final result = asJson(await _channel.request('polls.vote', {
      'pollId': pollId,
      'optionIds': optionIds,
      if (groupId != null && groupId.isNotEmpty) 'groupId': groupId,
    }));
    return pollDetailFromJson(asJson(result['poll']));
  }

  @override
  Future<PollDetail> addPollOption(
    int pollId,
    String content, {
    List<int> votedOptionIds = const [],
    bool voteNew = true,
    String? groupId,
  }) async {
    final result = asJson(await _channel.request('polls.addOption', {
      'pollId': pollId,
      'content': content,
      'votedOptionIds': votedOptionIds,
      'voteNew': voteNew,
      if (groupId != null && groupId.isNotEmpty) 'groupId': groupId,
    }));
    return pollDetailFromJson(asJson(result['poll']));
  }

  @override
  Future<PollDetail> lockPoll(int pollId, {String? groupId}) async {
    final result = asJson(await _channel.request('polls.lock', {
      'pollId': pollId,
      if (groupId != null && groupId.isNotEmpty) 'groupId': groupId,
    }));
    return pollDetailFromJson(asJson(result['poll']));
  }

  @override
  Future<void> sharePoll(int pollId) async {
    await _channel.request('polls.share', {'pollId': pollId});
  }

  @override
  Future<PinnedTopic> createNote(String groupId, String title, {bool pin = false}) async {
    final result = asJson(await _channel.request('notes.create', {
      'groupId': groupId,
      'title': title,
      'pin': pin,
    }));
    return pinnedTopicFromJson(asJson(result['note']));
  }

  @override
  Future<PinnedTopic> editNote(String groupId, String topicId, String title, {bool pin = false}) async {
    final result = asJson(await _channel.request('notes.edit', {
      'groupId': groupId,
      'topicId': topicId,
      'title': title,
      'pin': pin,
    }));
    return pinnedTopicFromJson(asJson(result['note']));
  }

  @override
  Future<List<ReminderItem>> listReminders(String threadId, ThreadType type, {int page = 1, int count = 20}) async {
    final result = asJson(await _channel.request('reminders.list', {
      'threadId': threadId,
      'threadType': threadTypeToWire(type),
      'page': page,
      'count': count,
    }));
    return [for (final item in asJsonList(result['reminders'])) reminderItemFromJson(item)];
  }

  @override
  Future<ReminderItem> createReminder(
    String threadId,
    ThreadType type, {
    required String title,
    String emoji = '⏰',
    required int startTime,
    int repeat = 0,
  }) async {
    final result = asJson(await _channel.request('reminders.create', {
      'threadId': threadId,
      'threadType': threadTypeToWire(type),
      'title': title,
      'emoji': emoji,
      'startTime': startTime,
      'repeat': repeat,
    }));
    return reminderItemFromJson(asJson(result['reminder']));
  }

  @override
  Future<ReminderItem> editReminder(
    String threadId,
    ThreadType type, {
    required String id,
    required String title,
    String emoji = '⏰',
    required int startTime,
    int repeat = 0,
  }) async {
    final result = asJson(await _channel.request('reminders.edit', {
      'threadId': threadId,
      'threadType': threadTypeToWire(type),
      'id': id,
      'title': title,
      'emoji': emoji,
      'startTime': startTime,
      'repeat': repeat,
    }));
    return reminderItemFromJson(asJson(result['reminder']));
  }

  @override
  Future<void> removeReminder(String threadId, ThreadType type, String id) async {
    await _channel.request('reminders.remove', {
      'threadId': threadId,
      'threadType': threadTypeToWire(type),
      'id': id,
    });
  }

  @override
  Future<void> react(Message message, String icon) async {
    await _channel.request('messages.react', {..._messageRef(message), 'icon': icon});
  }

  @override
  Future<void> recall(Message message) async {
    await _channel.request('messages.recall', _messageRef(message));
  }

  @override
  Future<void> deleteForMe(Message message) async {
    if (message.sendState != SendState.sent) {
      final list = _lists[_threadKey(message.threadId, message.threadType)];
      list?.remove(message.id);
      list?.flush();
      _outgoing.remove(message.cliId);
      return;
    }
    await _channel.request('messages.delete', _messageRef(message));
  }

  @override
  Future<void> deleteForAll(Message message) async {
    await _channel.request('messages.deleteForAll', _messageRef(message));
  }

  @override
  Future<String> report(String threadId, ThreadType type, ReportReason reason, {String? content}) async {
    final result = asJson(await _channel.request('threads.report', {
      'threadId': threadId,
      'threadType': threadTypeToWire(type),
      'reason': reportReasonToWire(reason),
      if (content != null && content.isNotEmpty) 'content': content,
    }));
    return '${result['reportId'] ?? ''}';
  }

  @override
  Future<void> markSeen(String threadId, ThreadType type) async {
    await _channel.request('threads.markSeen', {'threadId': threadId, 'threadType': threadTypeToWire(type)});
    // Applied at once; the sequenced thread.updated that follows agrees.
    final key = _threadKey(threadId, type);
    final thread = _threadMap[key];
    if (thread != null && thread.unread != 0) {
      _threadMap[key] = copyThread(thread, unread: 0);
      _threadsDirty = true;
      _flush();
    }
  }

  @override
  Future<void> setPinned(String threadId, ThreadType type, bool pinned) async {
    await _channel.request('threads.setPinned', {
      'threadId': threadId,
      'threadType': threadTypeToWire(type),
      'pinned': pinned,
    });
    // Optimistic; the sequenced thread.updated that follows agrees.
    final key = _threadKey(threadId, type);
    final thread = _threadMap[key];
    if (thread != null && thread.pinned != pinned) {
      _threadMap[key] = copyThread(thread, pinned: pinned);
      _threadsDirty = true;
      _flush();
    }
  }

  @override
  Future<void> setMuted(String threadId, ThreadType type, bool muted) async {
    await _channel.request('threads.setMuted', {
      'threadId': threadId,
      'threadType': threadTypeToWire(type),
      'muted': muted,
    });
    final key = _threadKey(threadId, type);
    final thread = _threadMap[key];
    if (thread != null && thread.muted != muted) {
      _threadMap[key] = copyThread(thread, muted: muted);
      _threadsDirty = true;
      _flush();
    }
  }

  @override
  Future<void> markUnread(String threadId, ThreadType type) async {
    await _channel.request('threads.markUnread', {
      'threadId': threadId,
      'threadType': threadTypeToWire(type),
    });
    final key = _threadKey(threadId, type);
    final thread = _threadMap[key];
    if (thread != null && thread.unread == 0) {
      _threadMap[key] = copyThread(thread, unread: 1);
      _threadsDirty = true;
      _flush();
    }
  }

  @override
  Future<void> deleteThread(String threadId, ThreadType type) async {
    await _channel.request('threads.delete', {
      'threadId': threadId,
      'threadType': threadTypeToWire(type),
    });
    _purgeThread(threadId, type);
  }

  // ---- hidden, archive, labels, auto-delete, linked devices ----

  @override
  Future<HiddenConversations> hiddenConversations() async =>
      hiddenConversationsFromJson(asJson(await _channel.request('hidden.list')));

  @override
  Future<void> setHidden(String threadId, ThreadType type, bool hidden) async {
    await _channel.request('threads.setHidden', {
      'threadId': threadId,
      'threadType': threadTypeToWire(type),
      'hidden': hidden,
    });
    // Optimistic; the sequenced thread.updated that follows agrees.
    final key = _threadKey(threadId, type);
    final thread = _threadMap[key];
    if (thread != null && thread.hidden != hidden) {
      _threadMap[key] = copyThread(thread, hidden: hidden);
      _threadsDirty = true;
      _flush();
    }
  }

  @override
  Future<void> setHiddenPin(String pin) async {
    // The PIN is write-only: forwarded once and never stored or logged.
    await _channel.request('hidden.setPin', {'pin': pin});
  }

  @override
  Future<void> resetHiddenPin() async {
    await _channel.request('hidden.resetPin');
  }

  @override
  Future<ArchivedChatList> archivedChats() async =>
      archivedChatListFromJson(asJson(await _channel.request('archive.list')));

  @override
  Future<void> setArchived(String threadId, ThreadType type, bool archived) async {
    await _channel.request('threads.setArchived', {
      'threadId': threadId,
      'threadType': threadTypeToWire(type),
      'archived': archived,
    });
    final key = _threadKey(threadId, type);
    final thread = _threadMap[key];
    if (thread != null && thread.archived != archived) {
      _threadMap[key] = copyThread(thread, archived: archived);
      _threadsDirty = true;
      _flush();
    }
  }

  @override
  Future<LabelsState> labels() async => labelsStateFromJson(asJson(await _channel.request('labels.list')));

  @override
  Future<LabelsState> updateLabels(List<ConversationLabel> labels, int version) async =>
      labelsStateFromJson(asJson(await _channel.request('labels.update', {
        'labels': [for (final label in labels) conversationLabelToJson(label)],
        'version': version,
      })));

  @override
  Future<AutoDeleteChat> autoDeleteChats() async =>
      autoDeleteChatFromJson(asJson(await _channel.request('threads.autoDelete')));

  @override
  Future<void> setAutoDelete(String threadId, ThreadType type, int ttl) async {
    if (!supportsAutoDeleteTtl(ttl)) throw ArgumentError.value(ttl, 'ttl', 'unsupported auto-delete ttl');
    await _channel.request('threads.setAutoDelete', {
      'threadId': threadId,
      'threadType': threadTypeToWire(type),
      'ttl': ttl,
    });
    final key = _threadKey(threadId, type);
    final thread = _threadMap[key];
    if (thread != null && thread.autoDeleteTtl != ttl) {
      _threadMap[key] = copyThread(thread, autoDeleteTtl: ttl);
      _threadsDirty = true;
      _flush();
    }
  }

  @override
  Future<LinkedDevices> linkedDevices() async {
    final result = asJson(await _channel.request('account.linkedDevices'));
    return linkedDevicesFromJson(result['devices']) ?? const LinkedDevices();
  }

  @override
  Future<void> forward(Message message, List<ThreadRef> to) async {
    await _channel.request('messages.forward', {
      'msgId': message.id,
      'threadId': message.threadId,
      'threadType': threadTypeToWire(message.threadType),
      'to': [
        for (final t in to)
          {'threadId': t.id, 'threadType': threadTypeToWire(t.type)},
      ],
      if (message.text != null) 'raw': message.text,
    });
  }

  @override
  Future<List<Contact>> users(List<String> uids) async {
    final result = asJson(await _channel.request('users.info', {'uids': uids}));
    return [for (final item in asJsonList(result['users'])) contactFromJson(item)];
  }

  @override
  Future<String> fullAvatar(String uid) async {
    final result = asJson(await _channel.request('users.avatar', {'uid': uid}));
    return '${result['url'] ?? ''}';
  }

  @override
  void sendTyping(String threadId, ThreadType type) {
    if (!_channel.isConnected) return;
    _channel.request('threads.typing', {'threadId': threadId, 'threadType': threadTypeToWire(type)}).ignore();
  }

  bool _contactsDirty = true;
  List<Contact>? _contacts;

  @override
  Future<List<Contact>> contacts() async {
    if (!_contactsDirty && _contacts != null) return _contacts!;
    final result = asJson(await _channel.request('contacts.list'));
    final list = [
      for (final item in asJsonList(result['contacts'])) contactFromJson(item),
    ];
    _contacts = list;
    _contactsDirty = false;
    return list;
  }

  // A friend mutation is applied at Zalo; the cached list is stale until the
  // next contacts() call.
  void _invalidateContacts() => _contactsDirty = true;

  // An alias is known locally, so an already-loaded list is patched in place
  // and the next contacts() serves it without a round trip.
  void _patchAlias(String uid, String? alias) {
    final list = _contacts;
    if (list == null) return;
    final index = list.indexWhere((c) => c.uid == uid);
    if (index < 0) return;
    final old = list[index];
    list[index] = Contact(
      uid: old.uid,
      displayName: old.displayName,
      avatarUrl: old.avatarUrl,
      alias: alias,
      closeFriend: old.closeFriend,
    );
  }

  @override
  Future<UserProfile?> findUserByPhone(String phone) async {
    final result = asJson(await _channel.request('contacts.findPhone', {'phone': phone}));
    return userProfileFromJson(result['user']);
  }

  @override
  Future<UserProfile?> findUserByUsername(String username) async {
    final result = asJson(await _channel.request('contacts.findUsername', {'username': username}));
    return userProfileFromJson(result['user']);
  }

  @override
  Future<void> sendFriendRequest(String uid, {String message = ''}) async {
    await _channel.request('contacts.request.send', {'uid': uid, 'message': message});
    _invalidateContacts();
  }

  @override
  Future<FriendRequestStatus> friendRequestStatus(String uid) async {
    final result = asJson(await _channel.request('contacts.request.status', {'uid': uid}));
    return friendRequestStatusFromJson(asJson(result['status']));
  }

  @override
  Future<void> acceptFriendRequest(String uid) async {
    await _channel.request('contacts.request.accept', {'uid': uid});
    _invalidateContacts();
  }

  @override
  Future<void> rejectFriendRequest(String uid) async {
    await _channel.request('contacts.request.reject', {'uid': uid});
    _invalidateContacts();
  }

  @override
  Future<void> cancelFriendRequest(String uid) async {
    await _channel.request('contacts.request.cancel', {'uid': uid});
    _invalidateContacts();
  }

  @override
  Future<FriendRequests> friendRequests() async =>
      friendRequestsFromJson(asJson(await _channel.request('contacts.requests')));

  @override
  Future<List<FriendRecommendation>> friendRecommendations() async {
    final result = asJson(await _channel.request('contacts.recommendations'));
    return [for (final item in asJsonList(result['users'])) friendRecommendationFromJson(item)];
  }

  @override
  Future<void> setAlias(String uid, String alias) async {
    await _channel.request('contacts.setAlias', {'uid': uid, 'alias': alias});
    _patchAlias(uid, alias);
  }

  @override
  Future<void> removeAlias(String uid) async {
    await _channel.request('contacts.removeAlias', {'uid': uid});
    _patchAlias(uid, null);
  }

  @override
  Future<void> removeFriend(String uid) async {
    await _channel.request('contacts.remove', {'uid': uid});
    _invalidateContacts();
  }

  @override
  Future<void> blockUser(String uid) async {
    await _channel.request('contacts.block', {'uid': uid});
    _invalidateContacts();
  }

  @override
  Future<void> unblockUser(String uid) async {
    await _channel.request('contacts.unblock', {'uid': uid});
    _invalidateContacts();
  }

  @override
  Future<List<FriendPresence>> presence() async {
    final result = asJson(await _channel.request('contacts.online'));
    return [for (final item in asJsonList(result['presence'])) friendPresenceFromJson(item)];
  }

  @override
  Future<LastSeen> lastSeen(String uid) async =>
      lastSeenFromJson(asJson(await _channel.request('contacts.lastOnline', {'uid': uid})));

  @override
  Future<List<GroupInfo>> groups() async {
    final result = asJson(await _channel.request('groups.list'));
    return [for (final item in asJsonList(result['groups'])) groupInfoFromJson(item)];
  }

  @override
  Future<GroupInfo> groupInfo(String groupId) async {
    final result = asJson(await _channel.request('groups.info', {'groupId': groupId}));
    return groupInfoFromJson(asJson(result['group']));
  }

  // ---- media ----

  @override
  Future<Uint8List> media(String url) {
    final hit = _media.get(url);
    if (hit != null) return Future.value(hit);
    final running = _mediaInFlight[url];
    if (running != null) return running;
    final fetch = _fetchMedia(url).whenComplete(() {
      _mediaInFlight.remove(url);
    });
    _mediaInFlight[url] = fetch;
    return fetch;
  }

  Future<Uint8List> _fetchMedia(String url) async {
    if (url.isEmpty || url.startsWith(_localScheme)) {
      throw const RpcException('not_found', 'media is not available');
    }
    // Bound concurrent blob streams so opening a 30-cell sticker grid never
    // overflows the channel's unclaimed-blob buffer or starves RPCs.
    if (_mediaActive >= _maxConcurrentMedia) {
      final slot = Completer<void>();
      _mediaQueue.add(slot);
      await slot.future;
      if (_disposed) throw const RpcException('closed', 'session closed');
      final hit = _media.get(url);
      if (hit != null) return hit;
    }
    _mediaActive++;
    try {
      final bytes = await _channel.use((channel) async {
        final result = asJson(await channel.request('media.fetch', {'url': url}, _mediaTimeout));
        final stream = result['stream'];
        if (stream is! num) throw const RpcException('error', 'media.fetch returned no stream');
        final blob = await channel.receiveBlob(stream.toInt(), timeout: _mediaTimeout);
        if (result['sealed'] != true) return blob;
        final root = _vault.root.value;
        if (root == null) throw const VaultNotReadyException();
        final size = result['size'];
        if (size is! num) throw const VaultOpenException('media.fetch returned no size');
        return openSealedMedia(root: root, slot: slot, url: url, size: size.toInt(), blob: blob);
      });
      _media.put(url, bytes);
      return bytes;
    } finally {
      _mediaActive--;
      if (_mediaQueue.isNotEmpty) {
        _mediaQueue.removeAt(0).complete();
      }
    }
  }

  void dispose({bool unauthorized = false}) {
    _channel.state.removeListener(_onLinkState);
    _channel.dispose(end: unauthorized ? LinkState.unauthorized : LinkState.disconnected);
    if (_disposed) return;
    _disposed = true;
    _vault.root.removeListener(_reopenLocked);
    _outgoing.clear();
    for (final waiter in _mediaQueue) {
      if (!waiter.isCompleted) waiter.complete();
    }
    _mediaQueue.clear();
    unawaited(_typing.close());
    unawaited(_boardUpdates.close());
    _media.clear();
    _threadsLoad.dispose();
    for (final list in _lists.values) {
      list.load.dispose();
    }
  }
}
