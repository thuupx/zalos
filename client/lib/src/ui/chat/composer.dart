import 'dart:async';

import 'package:material_ui/material_ui.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../domain/models.dart';
import '../../domain/services.dart';
import '../components/avatar.dart';
import '../components/basics.dart';
import '../components/fields.dart';
import '../components/motion.dart';
import '../components/overlays.dart';
import '../components/pressable.dart';
import '../contacts/contact_picker.dart';
import '../l10n/strings.dart';
import '../platform/services.dart';
import '../state/app_state.dart';
import '../state/thread_ui.dart';
import '../theme/tokens.dart';
import '../theme/z_icons.dart';
import '../util/format.dart';
import '../util/haptics.dart';
import '../util/style_runs.dart';
import 'board_sheets.dart';
import 'composer_sheets.dart';
import 'sticker_view.dart';

const int maxAttachmentBytes = 100 * 1024 * 1024;
const Duration maxRecording = Duration(minutes: 5);
const String mentionAllUid = '-1';

const String _emojiSet =
    '😀😃😄😁😆😅😂🤣😊😇🙂🙃😉😌😍🥰😘😗😙😚😋😛😝😜🤪🤨🧐🤓😎🥳😏😒😞😔😟😕🙁😣😖😫😩🥺😢😭😤😠😡🤬🤯😳🥵🥶😱😨😰😥😓🤗🤔🤭🤫🤥😶😐😑😬🙄😯😦😧😮😲🥱😴🤤😪😵🤐🥴🤢🤮🤧😷🤒🤕🤑🤠👍👎👏🙌🙏🤝💪👋🤞👌🤟🤘👀💯🔥✨🎉🎂🎁🌹💐🌸🍀☕🍻🍜🍚🏠🚗📞💼📌✅❌❓❗💤💔💖💙💚💛💜🖤';

enum _Panel { none, emoji, sticker }

/// Style runs moved from [raw] to its trimmed text. Leading whitespace is
/// dropped first so the diff seen by [shiftStyleRuns] only covers the
/// trailing side, which keeps a run over the real text instead of collapsing
/// it when both ends change.
List<StyleRun> _trimStyleRuns(List<StyleRun> runs, String raw) {
  final text = raw.trim();
  if (runs.isEmpty || raw == text) return runs;
  final lead = raw.length - raw.trimLeft().length;
  final shifted = <StyleRun>[
    for (final run in runs)
      if (run.start + run.len > lead)
        StyleRun(
          start: run.start > lead ? run.start - lead : 0,
          len: run.start + run.len - (run.start > lead ? run.start - lead : 0),
          st: run.st,
          indentSize: run.indentSize,
        ),
  ];
  return shiftStyleRuns(shifted, raw.trimLeft(), text);
}

class Composer extends ConsumerStatefulWidget {
  const Composer(
      {super.key,
      required this.session,
      required this.thread,
      required this.account,
      required this.members,
      required this.onSent});

  final AccountSession session;
  final OpenThread thread;
  final AccountSummary account;

  /// Group members for the mention picker; empty in one to one chats.
  final List<AvatarMember> members;
  final VoidCallback onSent;

  @override
  ConsumerState<Composer> createState() => ComposerState();
}

class ComposerState extends ConsumerState<Composer> {
  late final FocusNode _focus = FocusNode(debugLabel: 'composer', onKeyEvent: _onKey);
  final OverlayPortalController _portal = OverlayPortalController();
  final LayerLink _layer = LayerLink();
  late ThreadUi _ui;
  _Panel _panel = _Panel.none;
  DateTime _lastTyping = DateTime.fromMillisecondsSinceEpoch(0);

  VoiceRecorder? _recorder;
  Timer? _recordTicker;
  Duration _recorded = Duration.zero;
  bool _recording = false;

  int _mentionIndex = 0;
  int _mentionDismissedAt = -1;
  int _quickMediaPending = 0;

  Timer? _linkDebounce;
  String? _linkUrl;
  LinkPreview? _linkPreview;
  bool _linkLoading = false;
  bool _linkFailed = false;
  String? _linkDismissed;
  int _linkGeneration = 0;

  ThreadUiKey get _key => (slot: widget.session.slot, id: widget.thread.id);

  @override
  void initState() {
    super.initState();
    _ui = ref.read(threadUiProvider(_key));
    _ui.input.addListener(_onInput);
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted) _updateLinkPreview();
    });
  }

  @override
  void dispose() {
    _ui.input.removeListener(_onInput);
    _linkDebounce?.cancel();
    _recordTicker?.cancel();
    _recorder?.cancel();
    _recorder?.dispose();
    _focus.dispose();
    super.dispose();
  }

  void focusInput() => _focus.requestFocus();

  void addFiles(List<PickedFile> files) {
    var rejected = false;
    for (final f in files) {
      if (f.bytes.length > maxAttachmentBytes) {
        rejected = true;
        continue;
      }
      _ui.addAttachment(PendingAttachment(name: f.name, bytes: f.bytes, kind: kindForFileName(f.name)));
    }
    if (rejected && mounted) zToast(context, context.tr('fileTooLarge'));
  }

  void _onInput() {
    if (!mounted) return;
    setState(() {});
    _updateLinkPreview();
    if (_ui.draft.isEmpty) return;
    final now = DateTime.now();
    if (now.difference(_lastTyping) < const Duration(seconds: 3)) return;
    _lastTyping = now;
    if (_caps.contains(AccountCapability.typing)) {
      widget.session.sendTyping(widget.thread.id, widget.thread.type);
    }
  }

  Set<AccountCapability> get _caps => capsOf(widget.account);

  ({int start, String query})? get _mention {
    if (widget.members.isEmpty || !_caps.contains(AccountCapability.mentions)) {
      return null;
    }
    final value = _ui.input.value;
    final cursor = value.selection.isValid && value.selection.isCollapsed
        ? value.selection.baseOffset
        : -1;
    if (cursor < 0) return null;
    final before = value.text.substring(0, cursor);
    final at = before.lastIndexOf('@');
    if (at < 0 || at == _mentionDismissedAt) return null;
    if (at > 0 && !RegExp(r'\s').hasMatch(before[at - 1])) return null;
    final query = before.substring(at + 1);
    if (query.contains('\n') || query.length > 24) return null;
    // Only the token that was actually picked keeps the picker closed. A
    // longer query that merely starts with a picked name stays searchable.
    for (final pick in _ui.mentionPicks) {
      if (pick.start == at &&
          (query == pick.name || query.startsWith('${pick.name} '))) {
        return null;
      }
    }
    return (start: at, query: query);
  }

  List<AvatarMember> _mentionCandidates(String query) {
    final all = [
      const AvatarMember(mentionAllUid, 'All'),
      ...widget.members.where((m) => m.id != widget.account.uid)
    ];
    if (query.isEmpty) return all;
    return [
      for (final m in all)
        if (foldContains(m.name, query)) m
    ];
  }

  void _pickMention(AvatarMember member) {
    final mention = _mention;
    if (mention == null) return;
    final value = _ui.input.value;
    final cursor = value.selection.baseOffset;
    final insert = '@${member.name} ';
    final text = value.text.replaceRange(mention.start, cursor, insert);
    _ui.input.value = TextEditingValue(
        text: text,
        selection:
            TextSelection.collapsed(offset: mention.start + insert.length));
    _ui.addMentionPick(name: member.name, uid: member.id, start: mention.start);
    setState(() => _mentionIndex = 0);
  }

  /// Inserts a picked mention at the current selection, adding the separating
  /// space Zalo keeps before a tag in the middle of a sentence.
  void insertMention(AvatarMember member) {
    if (!_caps.contains(AccountCapability.mentions)) return;
    final value = _ui.input.value;
    final text = value.text;
    final start = value.selection.isValid
        ? value.selection.start.clamp(0, text.length)
        : text.length;
    final end = value.selection.isValid
        ? value.selection.end.clamp(0, text.length)
        : text.length;
    var insert = '@${member.name} ';
    var mentionStart = start;
    if (start > 0 && !RegExp(r'\s').hasMatch(text[start - 1])) {
      insert = ' $insert';
      mentionStart += 1;
    }
    final next = text.replaceRange(start, end, insert);
    final cursor = start + insert.length;
    _ui.input.value = TextEditingValue(
        text: next, selection: TextSelection.collapsed(offset: cursor));
    _ui.addMentionPick(name: member.name, uid: member.id, start: mentionStart);
    focusInput();
    setState(() => _mentionIndex = 0);
  }

  List<Mention> _resolveMentions(String rawText) {
    final text = rawText.trim();
    final lead = rawText.length - rawText.trimLeft().length;
    final picks = [
      for (final pick in _ui.mentionPicks) pick.shifted(pick.start - lead)
    ];
    return resolveMentionPicks(text, picks);
  }

  void _updateLinkPreview() {
    if (!_caps.contains(AccountCapability.linkPreview)) return;
    final matches = urlMatches(_ui.input.text.trim()).toList();
    final url = matches.length == 1 ? matches.single.group(0) : null;
    if (url == _linkUrl) return;
    _linkUrl = url;
    _linkDebounce?.cancel();
    _linkGeneration++;
    if (url == null) _linkDismissed = null;
    if (url == null || url == _linkDismissed) {
      setState(() {
        _linkPreview = null;
        _linkLoading = false;
        _linkFailed = false;
      });
      return;
    }
    setState(() {
      _linkPreview = null;
      _linkLoading = true;
      _linkFailed = false;
    });
    final generation = _linkGeneration;
    _linkDebounce = Timer(
        const Duration(milliseconds: 400), () => _parseLink(url, generation));
  }

  Future<void> _parseLink(String url, int generation) async {
    try {
      final preview = await widget.session.parseLink(url);
      if (!mounted || generation != _linkGeneration) return;
      setState(() {
        _linkPreview = preview;
        _linkLoading = false;
        _linkFailed = false;
      });
    } catch (_) {
      if (!mounted || generation != _linkGeneration) return;
      setState(() {
        _linkPreview = null;
        _linkLoading = false;
        _linkFailed = true;
      });
    }
  }

  void _retryLinkPreview() {
    final url = _linkUrl;
    if (url == null) return;
    final generation = ++_linkGeneration;
    setState(() {
      _linkPreview = null;
      _linkLoading = true;
      _linkFailed = false;
    });
    _parseLink(url, generation);
  }

  void _dismissLinkPreview() {
    _linkDebounce?.cancel();
    _linkGeneration++;
    setState(() {
      _linkDismissed = _linkUrl;
      _linkPreview = null;
      _linkLoading = false;
      _linkFailed = false;
    });
  }

  TextSelection get _selection => _ui.input.selection;
  bool get _hasSelection => _selection.isValid && !_selection.isCollapsed;
  bool get _canStyledText => _caps.contains(AccountCapability.styledText);

  bool _selectionHas(String st) =>
      _hasSelection &&
      styleRunsCover(_ui.styles, st, _selection.start, _selection.end);

  void _toggleFormat(String st) {
    if (!_canStyledText || !_hasSelection) return;
    _ui.setStyles(toggleStyleRun(
        _ui.styles, st, _selection.start, _selection.end,
        textLength: _ui.input.text.length));
    _focus.requestFocus();
    setState(() {});
  }

  bool get _canUrgency => _caps.contains(AccountCapability.urgency);
  bool get _canTtl => _caps.contains(AccountCapability.messageTtl);
  bool get _canSendOptions => _canUrgency || _canTtl;
  bool get _canBankCard =>
      _caps.contains(AccountCapability.bankCard) &&
      _caps.contains(AccountCapability.bankAccounts);
  bool get _canQuickMessages => _caps.contains(AccountCapability.quickMessages);

  Future<void> _openSendOptions() async {
    final picked = await showSendOptionsSheet(
      context,
      urgency: _ui.urgency,
      ttl: _ui.ttl,
      canUrgency: _canUrgency,
      canTtl: _canTtl,
    );
    if (picked == null || !mounted) return;
    _ui.urgency = picked.urgency;
    _ui.ttl = picked.ttl;
  }

  Future<void> _shareBankCard() async {
    await showBankCardSheet(
      context,
      session: widget.session,
      threadId: widget.thread.id,
      type: widget.thread.type,
    );
    if (mounted) widget.onSent();
  }

  Future<void> _openQuickMessages() async {
    final picked =
        await showQuickMessageSheet(context, session: widget.session);
    if (picked == null || !mounted) return;
    await _insertQuickMessage(picked);
  }

  Future<void> _insertQuickMessage(QuickMessage message) async {
    final value = _ui.input.value;
    final at =
        value.selection.isValid ? value.selection.start : value.text.length;
    final end =
        value.selection.isValid ? value.selection.end : value.text.length;
    final text = value.text.replaceRange(at, end, message.title);
    _ui.input.value = TextEditingValue(
        text: text,
        selection: TextSelection.collapsed(offset: at + message.title.length));
    if (message.media.isEmpty) return;
    final media = message.media.first;
    final url = media.normalUrl.isNotEmpty
        ? media.normalUrl
        : (media.rawUrl.isNotEmpty ? media.rawUrl : media.thumbUrl);
    if (url.isEmpty) return;
    final failed = context.tr('quickMediaFailed');
    setState(() => _quickMediaPending++);
    try {
      final bytes = await widget.session.media(url);
      if (!mounted) return;
      _ui.addAttachment(PendingAttachment(
          name: '${message.title}.jpg', bytes: bytes, kind: MessageKind.image));
    } catch (_) {
      if (mounted) zToast(context, failed);
    } finally {
      if (mounted) {
        setState(() {
          if (_quickMediaPending > 0) _quickMediaPending--;
        });
      }
    }
  }

  Future<void> _openMoreMenu(BuildContext buttonContext) async {
    final box = buttonContext.findRenderObject()! as RenderBox;
    final wide = LayoutScope.wideOf(context);
    final picked = await showZMenu<String>(
      context,
      position: box.localToGlobal(Offset(0, -box.size.height)),
      items: [
        if (!wide)
          ZMenuItem(
              value: 'file',
              label: context.tr('attachFile'),
              icon: ZIcons.attach),
        if (!wide && _caps.contains(AccountCapability.contactCard))
          ZMenuItem(
              value: 'contact',
              label: context.tr('shareContact'),
              icon: ZIcons.contactCard),
        if (_canBankCard)
          ZMenuItem(
              value: 'bankCard',
              label: context.tr('bankCard'),
              icon: ZIcons.bank),
        if (widget.thread.isGroup && _caps.contains(AccountCapability.polls))
          ZMenuItem(
              value: 'poll',
              label: context.tr('createPollTitle'),
              icon: ZIcons.poll),
        if (widget.thread.isGroup && _caps.contains(AccountCapability.notes))
          ZMenuItem(
              value: 'note',
              label: context.tr('createNoteTitle'),
              icon: ZIcons.note),
        if (_caps.contains(AccountCapability.reminders))
          ZMenuItem(
              value: 'reminder',
              label: context.tr('createReminderTitle'),
              icon: ZIcons.alarm),
        if (_canQuickMessages)
          ZMenuItem(
              value: 'quickMessages',
              label: context.tr('quickMessages'),
              icon: ZIcons.bolt),
        if (_canSendOptions)
          ZMenuItem(
              value: 'sendOptions',
              label: context.tr('sendOptions'),
              icon: ZIcons.tune),
      ],
    );
    if (!mounted) return;
    switch (picked) {
      case 'file':
        await _pick(ref.read(platformProvider).pickFiles);
      case 'contact':
        await _shareContact();
      case 'bankCard':
        await _shareBankCard();
      case 'poll':
        await showCreatePollSheet(
          context,
          session: widget.session,
          groupId: widget.thread.id,
        );
      case 'note':
        await showCreateNoteSheet(
          context,
          session: widget.session,
          groupId: widget.thread.id,
        );
      case 'reminder':
        await showCreateReminderSheet(
          context,
          session: widget.session,
          threadId: widget.thread.id,
          threadType: widget.thread.type,
        );
      case 'quickMessages':
        await _openQuickMessages();
      case 'sendOptions':
        await _openSendOptions();
    }
  }

  KeyEventResult _onKey(FocusNode node, KeyEvent event) {
    if (event is! KeyDownEvent && event is! KeyRepeatEvent) {
      return KeyEventResult.ignored;
    }
    final key = event.logicalKey;
    final keyboard = HardwareKeyboard.instance;
    final mention = _mention;
    if (mention != null) {
      final candidates = _mentionCandidates(mention.query);
      if (candidates.isNotEmpty) {
        if (key == LogicalKeyboardKey.arrowDown) {
          setState(() => _mentionIndex = (_mentionIndex + 1) % candidates.length);
          return KeyEventResult.handled;
        }
        if (key == LogicalKeyboardKey.arrowUp) {
          setState(() => _mentionIndex = (_mentionIndex - 1 + candidates.length) % candidates.length);
          return KeyEventResult.handled;
        }
        if (key == LogicalKeyboardKey.enter || key == LogicalKeyboardKey.numpadEnter || key == LogicalKeyboardKey.tab) {
          _pickMention(candidates[_mentionIndex.clamp(0, candidates.length - 1)]);
          return KeyEventResult.handled;
        }
      }
      if (key == LogicalKeyboardKey.escape) {
        setState(() => _mentionDismissedAt = mention.start);
        return KeyEventResult.handled;
      }
    }
    final modifier = keyboard.isControlPressed || keyboard.isMetaPressed;
    if (_canStyledText && modifier && _hasSelection) {
      if (!keyboard.isShiftPressed && key == LogicalKeyboardKey.keyB) {
        _toggleFormat('b');
        return KeyEventResult.handled;
      }
      if (!keyboard.isShiftPressed && key == LogicalKeyboardKey.keyI) {
        _toggleFormat('i');
        return KeyEventResult.handled;
      }
      if (!keyboard.isShiftPressed && key == LogicalKeyboardKey.keyU) {
        _toggleFormat('u');
        return KeyEventResult.handled;
      }
      if (keyboard.isShiftPressed && key == LogicalKeyboardKey.keyX) {
        _toggleFormat('s');
        return KeyEventResult.handled;
      }
    }
    if (key == LogicalKeyboardKey.escape) {
      if (_panel != _Panel.none) {
        _setPanel(_Panel.none);
        return KeyEventResult.handled;
      }
      if (_ui.replyTo != null) {
        _ui.replyTo = null;
        return KeyEventResult.handled;
      }
      _focus.unfocus();
      return KeyEventResult.handled;
    }
    if (key == LogicalKeyboardKey.keyV &&
        (keyboard.isControlPressed || keyboard.isMetaPressed)) {
      _pasteImage();
      return KeyEventResult.ignored;
    }
    final enter = key == LogicalKeyboardKey.enter ||
        key == LogicalKeyboardKey.numpadEnter;
    if (enter &&
        ref.read(platformProvider).hardwareKeyboard &&
        !keyboard.isShiftPressed &&
        !_ui.input.value.composing.isValid) {
      _send();
      return KeyEventResult.handled;
    }
    return KeyEventResult.ignored;
  }

  Future<void> _pasteImage() async {
    final image = await ref.read(platformProvider).clipboardImage();
    if (image != null && mounted) addFiles([image]);
  }

  bool get _hasContent => _ui.draft.isNotEmpty || _ui.attachments.isNotEmpty;
  bool get _canSend => _hasContent && _quickMediaPending == 0;

  void _send() {
    if (!_canSend) return;
    ZHaptics.light();
    final session = widget.session;
    final thread = widget.thread;
    final rawText = _ui.input.text;
    final text = rawText.trim();
    final quote = _ui.replyTo;
    final attachments = _ui.attachments;
    final mentions = _resolveMentions(rawText);
    final styles = _trimStyleRuns(_ui.styles, rawText);
    final urgency = _ui.urgency;
    final ttl = _ui.ttl > 0 ? _ui.ttl : null;
    final sendUrgency = urgency == MessageUrgency.normal ? null : urgency;
    final link = _linkUrl;
    final asLink = link != null &&
        text == link &&
        attachments.isEmpty &&
        quote == null &&
        mentions.isEmpty &&
        styles.isEmpty &&
        urgency == MessageUrgency.normal &&
        _caps.contains(AccountCapability.linkPreview);
    _ui.input.clear();
    _ui.replyTo = null;
    _ui.clearAttachments();
    _ui.clearDraftOptions();
    _linkDebounce?.cancel();
    _linkGeneration++;
    _linkUrl = null;
    _linkPreview = null;
    _linkLoading = false;
    _linkFailed = false;
    _lastTyping = DateTime.fromMillisecondsSinceEpoch(0);
    _mentionDismissedAt = -1;
    widget.onSent();
    final failed = context.tr('sendFailed');
    () async {
      try {
        for (final a in attachments) {
          await session.sendFile(
            thread.id,
            thread.type,
            OutgoingFile(name: a.name, bytes: a.bytes, kind: a.kind),
            urgency: sendUrgency,
            ttl: ttl,
          );
        }
        if (asLink) {
          await session.sendLink(thread.id, thread.type, link, ttl: ttl);
        } else if (text.isNotEmpty) {
          await session.sendText(
            thread.id,
            thread.type,
            text,
            quote: quote,
            mentions: mentions,
            styles: styles,
            urgency: sendUrgency,
            ttl: ttl,
          );
        }
      } catch (e) {
        final code = RegExp(
                r'\b(window_expired|quota_exceeded|rate_limited|not_supported)\b')
            .firstMatch('$e')
            ?.group(1);
        if (mounted && code == null) zToast(context, failed);
      }
    }();
  }

  Future<void> _pick(Future<List<PickedFile>> Function() pick) async {
    final failed = context.tr('pickFailed');
    try {
      final files = await pick();
      if (mounted && files.isNotEmpty) addFiles(files);
    } catch (_) {
      if (mounted) zToast(context, failed);
    }
  }

  void _setPanel(_Panel panel) {
    setState(() => _panel = _panel == panel ? _Panel.none : panel);
    final wide = LayoutScope.wideOf(context);
    if (wide) {
      _panel == _Panel.none ? _portal.hide() : _portal.show();
    } else if (_panel != _Panel.none) {
      _focus.unfocus();
    }
  }

  void _insertEmoji(String emoji) {
    final value = _ui.input.value;
    final at =
        value.selection.isValid ? value.selection.start : value.text.length;
    final end =
        value.selection.isValid ? value.selection.end : value.text.length;
    final text = value.text.replaceRange(at, end, emoji);
    _ui.input.value = TextEditingValue(
        text: text,
        selection: TextSelection.collapsed(offset: at + emoji.length));
  }

  void _sendSticker(StickerRef sticker) {
    widget.onSent();
    final failed = context.tr('sendFailed');
    widget.session
        .sendSticker(widget.thread.id, widget.thread.type, sticker)
        .catchError((Object _) {
      if (mounted) zToast(context, failed);
    });
  }

  Future<void> _shareContact() async {
    final contact = await showContactPicker(context,
        session: widget.session, title: context.tr('shareContactTitle'));
    if (contact == null || !mounted) return;
    try {
      await widget.session.sendCard(
        widget.thread.id,
        widget.thread.type,
        ContactCard(
            uid: contact.uid,
            displayName: contact.displayName,
            avatarUrl: contact.avatarUrl),
      );
      widget.onSent();
      if (mounted) zToast(context, context.tr('contactShared'));
    } catch (_) {
      if (mounted) zToast(context, context.tr('contactShareFailed'));
    }
  }

  Future<void> _startRecording() async {
    final denied = context.tr('micDenied');
    final recorder = ref.read(platformProvider).createRecorder();
    var started = false;
    try {
      started = await recorder.start();
    } catch (_) {
      started = false;
    }
    if (!mounted) {
      recorder.dispose();
      return;
    }
    if (!started) {
      recorder.dispose();
      zToast(context, denied);
      return;
    }
    _recorder = recorder;
    setState(() {
      _recording = true;
      _recorded = Duration.zero;
    });
    _recordTicker = Timer.periodic(const Duration(seconds: 1), (_) {
      if (!mounted) return;
      setState(() => _recorded += const Duration(seconds: 1));
      if (_recorded >= maxRecording) _finishRecording(send: true);
    });
  }

  Future<void> _finishRecording({required bool send}) async {
    final recorder = _recorder;
    _recorder = null;
    _recordTicker?.cancel();
    _recordTicker = null;
    if (mounted) setState(() => _recording = false);
    if (recorder == null) return;
    final failed = mounted ? context.tr('sendFailed') : '';
    try {
      if (!send) {
        await recorder.cancel();
        return;
      }
      final file = await recorder.stop();
      if (file == null) return;
      widget.onSent();
      await widget.session.sendFile(widget.thread.id, widget.thread.type, OutgoingFile(name: file.name, bytes: file.bytes, kind: MessageKind.voice));
    } catch (_) {
      if (mounted) zToast(context, failed);
    } finally {
      recorder.dispose();
    }
  }

  @override
  Widget build(BuildContext context) {
    final z = context.z;
    final wide = LayoutScope.wideOf(context);
    final account = widget.account;
    ref.watchNotifier(_ui);
    if (account.status != AccountStatus.online) {
      return Container(
        key: const Key('composerOffline'),
        decoration: BoxDecoration(color: z.layer, border: Border(top: BorderSide(color: z.divider))),
        child: SafeArea(
          top: false,
          child: ZBanner(
            tone: account.status == AccountStatus.needsLogin || account.status == AccountStatus.error ? ZTone.danger : ZTone.warning,
            icon: ZIcons.cloudOff,
            text: context.tr('composerOffline', [statusLabel(account.status, context.s)]),
          ),
        ),
      );
    }

    if (_recording) {
      return Container(
        key: const Key('recordingBar'),
        decoration: BoxDecoration(color: z.layer, border: Border(top: BorderSide(color: z.divider))),
        child: SafeArea(
          top: false,
          child: Padding(
            padding: const EdgeInsets.symmetric(horizontal: ZSpace.s12, vertical: ZSpace.s8),
            child: Row(
              children: [
                Container(width: 10, height: 10, decoration: BoxDecoration(color: z.danger, shape: BoxShape.circle)),
                const SizedBox(width: ZSpace.s8),
                Expanded(
                  child: Semantics(
                    liveRegion: true,
                    child: Text(context.tr('recordingElapsed', [formatDuration(_recorded.inMilliseconds)]), key: const Key('recordingElapsed'), style: z.text.label),
                  ),
                ),
                ZButton(key: const Key('recordCancel'), label: context.tr('cancel'), variant: ZButtonVariant.text, small: true, onPressed: () => _finishRecording(send: false)),
                const SizedBox(width: ZSpace.s8),
                ZButton(key: const Key('recordSend'), label: context.tr('send'), icon: ZIcons.send, small: true, onPressed: () => _finishRecording(send: true)),
              ],
            ),
          ),
        ),
      );
    }

    final mention = _mention;
    final candidates = mention == null
        ? const <AvatarMember>[]
        : _mentionCandidates(mention.query);
    final reply = _ui.replyTo;
    final attachments = _ui.attachments;

    final linkBar = _linkUrl != null &&
            (_linkLoading || _linkFailed || _linkPreview != null)
        ? LinkPreviewBar(
            key: const Key('linkPreview'),
            session: widget.session,
            preview: _linkPreview,
            loading: _linkLoading,
            failed: _linkFailed,
            onRetry: _retryLinkPreview,
            onDismiss: _dismissLinkPreview,
          )
        : null;

    final optionsChips = _ui.urgency != MessageUrgency.normal || _ui.ttl > 0
        ? Container(
            key: const Key('sendOptionsChips'),
            padding:
                const EdgeInsets.fromLTRB(ZSpace.s12, ZSpace.s8, ZSpace.s12, 0),
            alignment: Alignment.centerLeft,
            child: Wrap(
              spacing: ZSpace.s8,
              runSpacing: ZSpace.s4,
              children: [
                if (_ui.urgency != MessageUrgency.normal)
                  ZChip(
                    key: const Key('urgencyChip'),
                    label: messageUrgencyLabel(_ui.urgency, context.s),
                    icon: _ui.urgency == MessageUrgency.urgent
                        ? ZIcons.bolt
                        : ZIcons.priorityHigh,
                    tone: _ui.urgency == MessageUrgency.urgent
                        ? ZTone.danger
                        : ZTone.warning,
                  ),
                if (_ui.ttl > 0)
                  ZChip(
                    key: const Key('ttlChip'),
                    label: messageTtlLabel(_ui.ttl, context.s),
                    icon: ZIcons.timer,
                    tone: ZTone.info,
                  ),
              ],
            ),
          )
        : null;

    Widget formatButton(Key key, IconData icon, String label, String code) =>
        ZIconButton(
          key: key,
          icon: icon,
          label: label,
          size: 28,
          iconSize: 18,
          selected: _selectionHas(code),
          onPressed: () => _toggleFormat(code),
        );

    final formatBar = _canStyledText && _hasSelection
        ? Container(
            key: const Key('formatBar'),
            padding: const EdgeInsets.fromLTRB(ZSpace.s8, 2, ZSpace.s8, 2),
            decoration: BoxDecoration(
                color: z.layerSubtle,
                border: Border(bottom: BorderSide(color: z.divider))),
            alignment: Alignment.centerLeft,
            child: Row(
              mainAxisSize: MainAxisSize.min,
              children: [
                formatButton(const Key('formatBold'),
                    ZIcons.formatBold, context.tr('formatBold'), 'b'),
                formatButton(
                    const Key('formatItalic'),
                    ZIcons.formatItalic,
                    context.tr('formatItalic'),
                    'i'),
                formatButton(
                    const Key('formatUnderline'),
                    ZIcons.formatUnderline,
                    context.tr('formatUnderline'),
                    'u'),
                formatButton(
                    const Key('formatStrike'),
                    ZIcons.formatStrike,
                    context.tr('formatStrike'),
                    's'),
              ],
            ),
          )
        : null;

    Widget tool(Key key, IconData icon, String label, VoidCallback onTap,
            {bool active = false}) =>
        ZIconButton(
          key: key,
          icon: icon,
          label: label,
          iconSize: 24,
          selected: active,
          onPressed: onTap,
        );

    final stickerButton = TapRegion(
      groupId: _portal,
      child: tool(const Key('stickerButton'), ZIcons.note,
          context.tr('stickers'), () => _setPanel(_Panel.sticker),
          active: _panel == _Panel.sticker),
    );
    final emojiButton = TapRegion(
      groupId: _portal,
      child: tool(const Key('emojiButton'), ZIcons.mood,
          context.tr('emoji'), () => _setPanel(_Panel.emoji),
          active: _panel == _Panel.emoji),
    );
    final imageButton = tool(
        const Key('attachImageButton'),
        ZIcons.image,
        context.tr('attachImage'),
        () => _pick(ref.read(platformProvider).pickImages));
    final fileButton = tool(
        const Key('attachFileButton'),
        ZIcons.attach,
        context.tr('attachFile'),
        () => _pick(ref.read(platformProvider).pickFiles));
    final contactButton = tool(
        const Key('shareContactButton'),
        ZIcons.contactCard,
        context.tr('shareContact'),
        _shareContact);
    final voiceButton = tool(const Key('voiceButton'), ZIcons.mic,
        context.tr('recordVoice'), _startRecording);
    final moreButton = Builder(
      builder: (buttonContext) => tool(
          const Key('composerMore'),
          ZIcons.moreHoriz,
          context.tr('more'),
          () => _openMoreMenu(buttonContext)),
    );
    // The fill and icon color fade between muted and brand while the button
    // settles from slightly smaller.
    final sendButton = AnimatedScale(
      scale: _canSend ? 1 : 0.9,
      duration: ZMotion.of(context, ZMotion.fast),
      curve: ZMotion.standard,
      child: ZIconButton(
        key: const Key('sendButton'),
        icon: ZIcons.send,
        label: context.tr('send'),
        iconSize: 24,
        filledIcon: true,
        color: _canSend ? z.textOnBrand : null,
        fill: _canSend ? z.brand : null,
        hoverColor: _canSend ? z.brandHover : null,
        circle: true,
        onPressed: _canSend ? _send : null,
      ),
    );

    final canSticker = _caps.contains(AccountCapability.stickers);
    final canVoice = _caps.contains(AccountCapability.voice);
    final canContact = _caps.contains(AccountCapability.contactCard);
    final hint = wide
        ? context.tr('composerHintWide', [widget.thread.name])
        : context.tr('composerHint');
    final input = TextField(
      key: const Key('composerField'),
      controller: _ui.input,
      focusNode: _focus,
      minLines: 1,
      maxLines: wide ? 6 : 5,
      keyboardType: TextInputType.multiline,
      textInputAction: TextInputAction.newline,
      textCapitalization: TextCapitalization.sentences,
      style: z.text.body,
      cursorColor: z.brandText,
      onTap: () {
        if (!wide && _panel != _Panel.none) {
          setState(() => _panel = _Panel.none);
        }
      },
      decoration: InputDecoration(
        isDense: true,
        hintText: hint,
        hintMaxLines: 1,
        hintStyle: z.text.body.copyWith(color: z.textTertiary),
        filled: !wide,
        fillColor: z.layerSubtle,
        hoverColor: ZalosTokens.clear,
        border: wide
            ? InputBorder.none
            : OutlineInputBorder(
                borderRadius: BorderRadius.circular(ZRadius.pill),
                borderSide: BorderSide(color: z.divider)),
        enabledBorder: wide
            ? InputBorder.none
            : OutlineInputBorder(
                borderRadius: BorderRadius.circular(ZRadius.pill),
                borderSide: BorderSide(color: z.divider)),
        focusedBorder: wide
            ? InputBorder.none
            : OutlineInputBorder(
                borderRadius: BorderRadius.circular(ZRadius.pill),
                borderSide: BorderSide(color: z.focusRing, width: 1.5)),
        contentPadding: wide
            ? const EdgeInsets.symmetric(vertical: 2)
            : const EdgeInsets.symmetric(horizontal: ZSpace.s12, vertical: 12),
      ),
    );

    final panel = _panel == _Panel.none
        ? null
        : _PickerPanel(
            session: widget.session,
            panel: canSticker ? _panel : _Panel.emoji,
            stickers: canSticker,
            onTab: (p) => setState(() => _panel = p),
            onEmoji: _insertEmoji,
            onSticker: _sendSticker,
          );

    return OverlayPortal(
      controller: _portal,
      overlayChildBuilder: (context) => Positioned(
        left: 0,
        top: 0,
        child: CompositedTransformFollower(
          link: _layer,
          showWhenUnlinked: false,
          targetAnchor: Alignment.topLeft,
          followerAnchor: Alignment.bottomLeft,
          offset: const Offset(ZSpace.s8, -ZSpace.s8),
          child: TapRegion(
            groupId: _portal,
            onTapOutside: (_) {
              if (_panel != _Panel.none) _setPanel(_panel);
            },
            child: ZPopIn(
              alignment: Alignment.bottomLeft,
              from: 0.92,
              child: Container(
                width: 360,
                height: 420,
                clipBehavior: Clip.antiAlias,
                decoration: BoxDecoration(color: z.layer, borderRadius: BorderRadius.circular(ZRadius.card), border: Border.all(color: z.border), boxShadow: z.shadowOverlay),
                child: Material(type: MaterialType.transparency, child: panel ?? const SizedBox.shrink()),
              ),
            ),
          ),
        ),
      ),
      child: CompositedTransformTarget(
        link: _layer,
        child: Container(
          key: const Key('composer'),
          decoration: BoxDecoration(color: z.layer, border: Border(top: BorderSide(color: z.divider))),
          child: SafeArea(
            top: false,
            child: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                ZReveal(
                  axisAlignment: -1,
                  scaleAlignment: Alignment.bottomLeft,
                  child: candidates.isEmpty
                      ? null
                      : Align(
                          key: const ValueKey('mentions'),
                          alignment: Alignment.centerLeft,
                          child: _MentionList(
                              session: widget.session,
                              candidates: candidates,
                              index:
                                  _mentionIndex.clamp(0, candidates.length - 1),
                              onPick: _pickMention),
                        ),
                ),
                ZReveal(
                  axisAlignment: -1,
                  child: reply == null
                      ? null
                      : _ReplyBar(
                          key: ValueKey(reply.cliId ?? reply.id),
                          message: reply,
                          selfUid: account.uid,
                          onClose: () => _ui.replyTo = null),
                ),
                ZReveal(
                  axisAlignment: -1,
                  child: _quickMediaPending == 0
                      ? null
                      : Padding(
                          key: const Key('quickMediaPending'),
                          padding: const EdgeInsets.fromLTRB(
                              ZSpace.s12, ZSpace.s8, ZSpace.s12, 0),
                          child: Row(
                            children: [
                              const SizedBox(
                                  width: 14,
                                  height: 14,
                                  child: CircularProgressIndicator(
                                      strokeWidth: 2)),
                              const SizedBox(width: ZSpace.s8),
                              Text(context.tr('quickMediaLoading'),
                                  style: z.text.caption),
                            ],
                          ),
                        ),
                ),
                ZReveal(
                  axisAlignment: -1,
                  child: attachments.isEmpty
                      ? null
                      : _PendingStrip(
                          key: const ValueKey('pending'),
                          attachments: attachments,
                          onRemove: _ui.removeAttachmentAt),
                ),
                ZReveal(axisAlignment: -1, child: linkBar),
                ZReveal(axisAlignment: -1, child: optionsChips),
                ZReveal(axisAlignment: -1, child: formatBar),
                if (wide) ...[
                  Container(
                    height: 40,
                    padding: const EdgeInsets.symmetric(horizontal: ZSpace.s8),
                    decoration: BoxDecoration(
                        border: Border(bottom: BorderSide(color: z.divider))),
                    child: Row(children: [
                      if (canSticker) ...[
                        stickerButton,
                        const SizedBox(width: ZSpace.s12)
                      ],
                      imageButton,
                      const SizedBox(width: ZSpace.s12),
                      fileButton,
                      if (canContact) ...[
                        const SizedBox(width: ZSpace.s12),
                        contactButton
                      ],
                      if (canVoice) ...[
                        const SizedBox(width: ZSpace.s12),
                        voiceButton
                      ],
                      if (_canBankCard ||
                          _canQuickMessages ||
                          _canSendOptions) ...[
                        const SizedBox(width: ZSpace.s12),
                        moreButton
                      ],
                    ]),
                  ),
                  Padding(
                    padding: const EdgeInsets.fromLTRB(
                        ZSpace.s12, 10, ZSpace.s8, 10),
                    child: Row(
                      crossAxisAlignment: CrossAxisAlignment.end,
                      children: [
                        Expanded(child: input),
                        const SizedBox(width: ZSpace.s4),
                        emojiButton,
                        sendButton
                      ],
                    ),
                  ),
                ] else
                  Padding(
                    padding: const EdgeInsets.symmetric(
                        horizontal: ZSpace.s4, vertical: ZSpace.s4),
                    child: Row(
                      crossAxisAlignment: CrossAxisAlignment.end,
                      children: [
                        tool(
                            const Key('stickerButton'),
                            ZIcons.mood,
                            context.tr('emoji'),
                            () => _setPanel(
                                _panel == _Panel.none ? _Panel.emoji : _panel),
                            active: _panel != _Panel.none),
                        Expanded(
                            child: Padding(
                                padding:
                                    const EdgeInsets.symmetric(vertical: 2),
                                child: input)),
                        // Typing swaps the attach tools for the send button.
                        AnimatedSize(
                          duration: ZMotion.enter,
                          curve: ZMotion.springCurve,
                          alignment: Alignment.centerRight,
                          child: AnimatedSwitcher(
                            duration: ZMotion.fast,
                            switchInCurve: ZMotion.springCurve,
                            switchOutCurve: ZMotion.exitCurve,
                            transitionBuilder: (child, animation) =>
                                FadeTransition(
                              opacity: animation,
                              child: ScaleTransition(
                                  scale: Tween(
                                          begin: ZMotion.reduced(context)
                                              ? 1.0
                                              : 0.8,
                                          end: 1.0)
                                      .animate(animation),
                                  child: child),
                            ),
                            child: _hasContent
                                ? KeyedSubtree(
                                    key: const ValueKey('send'),
                                    child: sendButton)
                                : Row(
                                    key: const ValueKey('tools'),
                                    mainAxisSize: MainAxisSize.min,
                                    children: [
                                      moreButton,
                                      if (canVoice) voiceButton,
                                      imageButton,
                                    ],
                                  ),
                          ),
                        ),
                      ],
                    ),
                  ),
                if (!wide && panel != null) SizedBox(height: 340, child: panel),
              ],
            ),
          ),
        ),
      ),
    );
  }
}

class _ReplyBar extends StatelessWidget {
  const _ReplyBar({super.key, required this.message, required this.selfUid, required this.onClose});

  final Message message;
  final String selfUid;
  final VoidCallback onClose;

  @override
  Widget build(BuildContext context) {
    final z = context.z;
    final name = message.isSelf ? context.tr('yourself') : message.senderName;
    return Padding(
      key: const Key('replyBar'),
      padding: const EdgeInsets.fromLTRB(ZSpace.s12, ZSpace.s8, ZSpace.s4, 0),
      child: Container(
        decoration: BoxDecoration(color: z.layerSubtle, borderRadius: BorderRadius.circular(ZRadius.tight)),
        child: IntrinsicHeight(
          child: Row(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              Container(width: 3, decoration: BoxDecoration(color: z.quoteBar, borderRadius: const BorderRadius.horizontal(left: Radius.circular(ZRadius.tight)))),
              Expanded(
                child: Padding(
                  padding: const EdgeInsets.symmetric(horizontal: ZSpace.s8, vertical: 6),
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    mainAxisAlignment: MainAxisAlignment.center,
                    children: [
                      Text(context.tr('replyingTo', [name]), maxLines: 1, overflow: TextOverflow.ellipsis, style: z.text.captionStrong),
                      Text(messageSummary(message, context.s), maxLines: 1, overflow: TextOverflow.ellipsis, style: z.text.caption.copyWith(color: z.textSecondary)),
                    ],
                  ),
                ),
              ),
              ZIconButton(key: const Key('replyClose'), icon: ZIcons.close, label: context.tr('cancelReply'), onPressed: onClose),
            ],
          ),
        ),
      ),
    );
  }
}

class _PendingStrip extends StatelessWidget {
  const _PendingStrip({super.key, required this.attachments, required this.onRemove});

  final List<PendingAttachment> attachments;
  final ValueChanged<int> onRemove;

  @override
  Widget build(BuildContext context) {
    final z = context.z;
    final target =
        LayoutScope.wideOf(context) ? ZSizes.pointerTarget : ZSizes.touchTarget;
    final total = attachments.fold<int>(0, (n, a) => n + a.bytes.length);
    return Padding(
      key: const Key('pendingAttachments'),
      padding: const EdgeInsets.fromLTRB(ZSpace.s12, ZSpace.s8, ZSpace.s12, 0),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        mainAxisSize: MainAxisSize.min,
        children: [
          SizedBox(
            height: 76,
            child: ListView.separated(
              scrollDirection: Axis.horizontal,
              itemCount: attachments.length,
              separatorBuilder: (_, __) => const SizedBox(width: ZSpace.s8),
              itemBuilder: (context, i) {
                final a = attachments[i];
                final image =
                    a.kind == MessageKind.image || a.kind == MessageKind.gif;
                return Stack(
                  clipBehavior: Clip.none,
                  children: [
                    Container(
                      width: image ? 72 : 160,
                      height: 72,
                      margin: const EdgeInsets.only(
                          top: ZSpace.s4, right: ZSpace.s4),
                      clipBehavior: Clip.antiAlias,
                      decoration: BoxDecoration(
                          color: z.layerSubtle,
                          borderRadius: BorderRadius.circular(ZRadius.tight),
                          border: Border.all(color: z.divider)),
                      child: image
                          ? Image.memory(a.bytes,
                              fit: BoxFit.cover,
                              cacheWidth: 216,
                              semanticLabel: a.name,
                              errorBuilder: (_, __, ___) => Icon(
                                  ZIcons.image,
                                  color: z.textTertiary))
                          : Padding(
                              padding: const EdgeInsets.all(ZSpace.s8),
                              child: Column(
                                crossAxisAlignment: CrossAxisAlignment.start,
                                mainAxisAlignment: MainAxisAlignment.center,
                                children: [
                                  Text(middleEllipsis(a.name, 30),
                                      maxLines: 2,
                                      overflow: TextOverflow.ellipsis,
                                      style: z.text.caption
                                          .copyWith(color: z.textPrimary)),
                                  Text(formatBytes(a.bytes.length),
                                      style: z.text.caption),
                                ],
                              ),
                            ),
                    ),
                    Positioned(
                      top: 0,
                      right: 0,
                      child: ZPressable(
                        key: Key('pendingRemove-$i'),
                        circle: true,
                        color: z.textPrimary.withValues(alpha: 0.75),
                        hoverColor: z.textPrimary,
                        pressedColor: z.textPrimary,
                        semanticLabel: context.tr('removeAttachment', [a.name]),
                        minSize: target,
                        onTap: () => onRemove(i),
                        child: SizedBox(
                            width: 20,
                            height: 20,
                            child: Icon(ZIcons.close,
                                size: 12, color: z.layer)),
                      ),
                    ),
                  ],
                );
              },
            ),
          ),
          Padding(
            padding: const EdgeInsets.only(top: 2),
            child: Text(context.tr('attachmentsTotal', [attachments.length, formatBytes(total)]), key: const Key('pendingTotal'), style: z.text.caption),
          ),
        ],
      ),
    );
  }
}

class _MentionList extends StatelessWidget {
  const _MentionList({required this.session, required this.candidates, required this.index, required this.onPick});

  final AccountSession session;
  final List<AvatarMember> candidates;
  final int index;
  final ValueChanged<AvatarMember> onPick;

  @override
  Widget build(BuildContext context) {
    final z = context.z;
    final wide = LayoutScope.wideOf(context);
    final list = Container(
      key: const Key('mentionList'),
      width: wide ? 300 : null,
      constraints: const BoxConstraints(maxHeight: 240),
      clipBehavior: Clip.antiAlias,
      decoration: wide
          ? BoxDecoration(color: z.layer, borderRadius: BorderRadius.circular(ZRadius.menu), border: Border.all(color: z.border), boxShadow: z.shadowOverlay)
          : BoxDecoration(color: z.layer, border: Border(bottom: BorderSide(color: z.divider))),
      child: ListView.builder(
        shrinkWrap: true,
        padding: const EdgeInsets.symmetric(vertical: ZSpace.s4),
        itemCount: candidates.length,
        itemExtent: 48,
        itemBuilder: (context, i) {
          final m = candidates[i];
          final all = m.id == mentionAllUid;
          return ZPressable(
            key: Key('mention-${m.id}'),
            onTap: () => onPick(m),
            radius: 0,
            color: i == index ? z.layerSelected : null,
            canRequestFocus: false,
            semanticLabel: all ? context.tr('mentionAll') : m.name,
            child: Padding(
              padding: const EdgeInsets.symmetric(horizontal: ZSpace.s16),
              child: Row(
                children: [
                  if (all)
                    Container(
                      width: 32,
                      height: 32,
                      decoration:
                          BoxDecoration(color: z.brand, shape: BoxShape.circle),
                      child: Icon(ZIcons.at,
                          size: 18, color: z.textOnBrand),
                    )
                  else
                    ZAvatar(
                        session: session,
                        id: m.id,
                        name: m.name,
                        url: m.url,
                        size: 32),
                  const SizedBox(width: ZSpace.s12),
                  Expanded(
                    child: Text(all ? '@All' : m.name,
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: z.text.labelRegular),
                  ),
                  if (all)
                    Text(context.tr('mentionAll'),
                        style: z.text.caption.copyWith(color: z.textSecondary)),
                ],
              ),
            ),
          );
        },
      ),
    );
    return wide ? Padding(padding: const EdgeInsets.fromLTRB(ZSpace.s12, ZSpace.s8, 0, ZSpace.s4), child: list) : list;
  }
}

class _PickerPanel extends StatelessWidget {
  const _PickerPanel({required this.session, required this.panel, required this.stickers, required this.onTab, required this.onEmoji, required this.onSticker});

  final AccountSession session;
  final _Panel panel;
  final bool stickers;
  final ValueChanged<_Panel> onTab;
  final ValueChanged<String> onEmoji;
  final ValueChanged<StickerRef> onSticker;

  @override
  Widget build(BuildContext context) {
    final z = context.z;
    return Container(
      key: const Key('pickerPanel'),
      color: z.layer,
      child: Column(
        children: [
          Padding(
            padding: const EdgeInsets.fromLTRB(ZSpace.s12, ZSpace.s8, ZSpace.s12, ZSpace.s4),
            child: ZSegmented<_Panel>(
              segments: [(_Panel.emoji, context.tr('emoji')), if (stickers) (_Panel.sticker, context.tr('stickers'))],
              selected: panel,
              onChanged: onTab,
            ),
          ),
          Expanded(
            child: panel == _Panel.emoji ? _EmojiGrid(onPick: onEmoji) : StickerPicker(session: session, onPick: onSticker),
          ),
        ],
      ),
    );
  }
}

class _EmojiGrid extends StatelessWidget {
  const _EmojiGrid({required this.onPick});

  final ValueChanged<String> onPick;

  // Stand-ins where no emoji font exists (golden tests).
  static const List<IconData> _testGlyphs = [ZIcons.mood, ZIcons.mood, ZIcons.reactHaha, ZIcons.reactSad, ZIcons.heartFill, ZIcons.thumbUp];

  static final List<String> _emoji = [for (final r in _emojiSet.runes) String.fromCharCode(r)];

  @override
  Widget build(BuildContext context) {
    final z = context.z;
    final wide = LayoutScope.wideOf(context);
    return GridView.builder(
      key: const Key('emojiGrid'),
      padding: const EdgeInsets.all(ZSpace.s8),
      gridDelegate: SliverGridDelegateWithMaxCrossAxisExtent(maxCrossAxisExtent: wide ? 40 : 48),
      itemCount: _emoji.length,
      itemBuilder: (context, i) => ZPressable(
        key: Key('emoji-$i'),
        onTap: () => onPick(_emoji[i]),
        radius: ZRadius.row,
        semanticLabel: _emoji[i],
        child: Center(
          child: zUseEmojiGlyphs
              ? Text(_emoji[i], textScaler: TextScaler.noScaling, style: z.text.emojiCell)
              : Icon(_testGlyphs[i % _testGlyphs.length], size: 24, color: z.textSecondary),
        ),
      ),
    );
  }
}

class StickerPicker extends StatefulWidget {
  const StickerPicker({super.key, required this.session, required this.onPick});

  final AccountSession session;
  final ValueChanged<StickerRef> onPick;

  @override
  State<StickerPicker> createState() => _StickerPickerState();
}

class _StickerCategory {
  const _StickerCategory(this.id, this.labelKey, this.query, this.icon);
  final String id;
  final String labelKey;
  final String query;
  final IconData icon;
}

class _StickerPack {
  const _StickerPack({required this.cateId, required this.cover});
  final int cateId;
  final StickerRef cover;
}

const String _recentTabId = '__recent__';

const List<_StickerCategory> _stickerCategories = [
  _StickerCategory('popular', 'stickerPopular', 'hi', ZIcons.star),
  _StickerCategory('love', 'stickerLove', 'yêu', ZIcons.heart),
  _StickerCategory('haha', 'stickerHaha', 'haha', ZIcons.reactHaha),
  _StickerCategory('hi', 'stickerHi', 'chào', ZIcons.mood),
  _StickerCategory('thanks', 'stickerThanks', 'cảm ơn', ZIcons.thumbUp),
  _StickerCategory('ok', 'stickerOk', 'ok', ZIcons.checkCircle),
  _StickerCategory('sad', 'stickerSad', 'buồn', ZIcons.reactSad),
  _StickerCategory('cool', 'stickerCool', 'ngầu', ZIcons.bolt),
];

/// Session-scoped recent stickers so the Zalo "Gần đây" dock tab survives
/// opening and closing the picker across conversations.
final Expando<List<StickerRef>> _recentStickersBySession =
    Expando('recentStickers');

class _StickerPickerState extends State<StickerPicker> {
  final TextEditingController _query = TextEditingController();
  final Map<String, List<StickerRef>> _searchCache = {};
  final Map<int, List<StickerRef>> _packCache = {};
  final Map<int, StickerRef> _packCovers = {};
  final List<int> _packOrder = [];
  Timer? _debounce;
  String _selectedTab = _stickerCategories.first.id;
  int? _selectedPackId;
  List<StickerRef>? _results;
  StickerRef? _preview;
  bool _failed = false;
  int _generation = 0;

  List<StickerRef> get _recents =>
      _recentStickersBySession[widget.session] ?? const [];

  @override
  void initState() {
    super.initState();
    _loadDefault();
  }

  @override
  void dispose() {
    _generation++;
    _debounce?.cancel();
    _query.dispose();
    super.dispose();
  }

  _StickerCategory get _activeCategory => _stickerCategories.firstWhere(
        (c) => c.id == _selectedTab,
        orElse: () => _stickerCategories.first,
      );

  void _recordPacks(List<StickerRef> items) {
    for (final s in items) {
      if (s.cateId <= 0) continue;
      if (!_packCovers.containsKey(s.cateId)) {
        _packCovers[s.cateId] = s;
        _packOrder.add(s.cateId);
      }
    }
  }

  void _recordRecent(StickerRef sticker) {
    final list = _recentStickersBySession[widget.session] ??= <StickerRef>[];
    list.removeWhere((s) => s.id == sticker.id);
    list.insert(0, sticker);
    if (list.length > 24) {
      list.removeRange(24, list.length);
    }
  }

  Future<void> _loadDefault() =>
      _search(_activeCategory.query, isDefaultBrowse: true);

  void _selectRecent() {
    ZHaptics.selection();
    _debounce?.cancel();
    if (_query.text.isNotEmpty) _query.clear();
    _generation++;
    setState(() {
      _selectedTab = _recentTabId;
      _selectedPackId = null;
      _failed = false;
      _results = List<StickerRef>.unmodifiable(_recents);
    });
  }

  Future<void> _selectCategory(_StickerCategory category) async {
    if (_selectedPackId == null &&
        _selectedTab == category.id &&
        _query.text.trim().isEmpty &&
        _results != null) {
      return;
    }
    ZHaptics.selection();
    _debounce?.cancel();
    if (_query.text.isNotEmpty) _query.clear();
    setState(() {
      _selectedTab = category.id;
      _selectedPackId = null;
    });
    await _search(category.query, isDefaultBrowse: true);
  }

  Future<void> _selectPack(int cateId) async {
    if (_selectedPackId == cateId &&
        _query.text.trim().isEmpty &&
        _results != null) {
      return;
    }
    ZHaptics.selection();
    _debounce?.cancel();
    if (_query.text.isNotEmpty) _query.clear();
    final cached = _packCache[cateId];
    if (cached != null) {
      setState(() {
        _selectedPackId = cateId;
        _selectedTab = 'pack-$cateId';
        _results = cached;
        _failed = false;
      });
      return;
    }
    final generation = ++_generation;
    setState(() {
      _selectedPackId = cateId;
      _selectedTab = 'pack-$cateId';
      _results = null;
      _failed = false;
    });
    try {
      var list = await widget.session.stickerCategory(cateId);
      if (list.isEmpty) {
        // Fallback to any stickers already seen for this pack in search cache.
        final seen = <int>{};
        list = [
          for (final group in _searchCache.values)
            for (final s in group)
              if (s.cateId == cateId && seen.add(s.id)) s,
        ];
      }
      if (!mounted || generation != _generation) return;
      if (list.isNotEmpty) {
        _packCache[cateId] = list;
        _recordPacks(list);
      }
      setState(() => _results = list);
    } catch (_) {
      if (!mounted || generation != _generation) return;
      setState(() => _failed = true);
    }
  }

  Future<void> _search(String raw, {bool isDefaultBrowse = false}) async {
    final q = raw.trim();
    final effective = q.isEmpty ? _activeCategory.query : q;
    final cached = _searchCache[effective];
    if (cached != null && isDefaultBrowse) {
      if (mounted) {
        setState(() {
          _results = cached;
          _failed = false;
        });
      }
      return;
    }
    final generation = ++_generation;
    setState(() {
      _results = null;
      _failed = false;
    });
    try {
      var list = await widget.session.searchStickers(effective);
      if (list.isEmpty && isDefaultBrowse) {
        for (final fallback in const ['haha', 'love', 'ok']) {
          if (fallback == effective) continue;
          try {
            final alt = await widget.session.searchStickers(fallback);
            if (alt.isNotEmpty) {
              list = alt;
              break;
            }
          } catch (_) {}
        }
      }
      if (mounted && generation == _generation) {
        if (list.isNotEmpty) {
          _searchCache[effective] = list;
          _recordPacks(list);
        }
        setState(() => _results = list);
      }
    } catch (_) {
      if (isDefaultBrowse) {
        for (final fallback in const ['haha', 'love', 'ok']) {
          if (fallback == effective) continue;
          try {
            final alt = await widget.session.searchStickers(fallback);
            if (mounted && generation == _generation) {
              if (alt.isNotEmpty) {
                _searchCache[effective] = alt;
                _recordPacks(alt);
              }
              setState(() => _results = alt);
            }
            return;
          } catch (_) {}
        }
      }
      if (mounted && generation == _generation) setState(() => _failed = true);
    }
  }

  String _sectionTitle(BuildContext context) {
    if (_selectedTab == _recentTabId) return context.tr('stickerRecent');
    final packId = _selectedPackId;
    if (packId != null) return context.tr('stickerPack', [packId]);
    return context.tr(_activeCategory.labelKey);
  }

  void _pickSticker(StickerRef sticker) {
    ZHaptics.light();
    _recordRecent(sticker);
    widget.onPick(sticker);
  }

  @override
  Widget build(BuildContext context) {
    final z = context.z;
    final wide = LayoutScope.wideOf(context);
    final results = _results;
    final isTyping = _query.text.trim().isNotEmpty;
    final columns = wide ? 5 : 4;
    final delegate = SliverGridDelegateWithFixedCrossAxisCount(
      crossAxisCount: columns,
      mainAxisSpacing: 6,
      crossAxisSpacing: 6,
    );
    final packs = <_StickerPack>[
      for (final cid in _packOrder.take(10))
        if (_packCovers[cid] != null)
          _StickerPack(cateId: cid, cover: _packCovers[cid]!),
    ];
    final hasRecents = _recents.isNotEmpty;

    return Stack(
      children: [
        Column(
          children: [
            // Search bar (top of Zalo sticker sheet)
            Padding(
              padding: const EdgeInsets.fromLTRB(
                  ZSpace.s12, ZSpace.s4, ZSpace.s12, ZSpace.s4),
              child: ZSearchField(
                key: const Key('stickerSearch'),
                controller: _query,
                hint: context.tr('searchStickers'),
                clearLabel: context.tr('clear'),
                onChanged: (v) {
                  _debounce?.cancel();
                  _debounce = Timer(
                    const Duration(milliseconds: 300),
                    () {
                      final trimmed = v.trim();
                      if (trimmed.isEmpty && _selectedTab == _recentTabId) {
                        _selectRecent();
                      } else if (trimmed.isEmpty && _selectedPackId != null) {
                        _selectPack(_selectedPackId!);
                      } else {
                        _search(v, isDefaultBrowse: trimmed.isEmpty);
                      }
                    },
                  );
                },
              ),
            ),
            // Sticky Zalo section title row when browsing packs/categories
            if (!isTyping)
              SizedBox(
                height: 26,
                child: Padding(
                  padding: const EdgeInsets.symmetric(horizontal: ZSpace.s12),
                  child: Row(
                    children: [
                      Expanded(
                        child: Text(
                          _sectionTitle(context),
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                          style: z.text.captionStrong
                              .copyWith(color: z.textSecondary),
                        ),
                      ),
                      if (results != null && results.isNotEmpty)
                        Text(
                          '${results.length}',
                          style:
                              z.text.caption.copyWith(color: z.textTertiary),
                        ),
                    ],
                  ),
                ),
              ),
            // Sticker grid
            Expanded(
              child: _failed
                  ? ZErrorState(
                      title: context.tr('stickersFailed'),
                      retryLabel: context.tr('retry'),
                      onRetry: () {
                        final q = _query.text.trim();
                        if (q.isEmpty && _selectedPackId != null) {
                          _selectPack(_selectedPackId!);
                        } else {
                          _search(q, isDefaultBrowse: q.isEmpty);
                        }
                      },
                    )
                  : results == null
                      ? GridView.builder(
                          key: const Key('stickerSkeleton'),
                          physics: const NeverScrollableScrollPhysics(),
                          padding: const EdgeInsets.fromLTRB(
                              ZSpace.s12, ZSpace.s4, ZSpace.s12, ZSpace.s8),
                          gridDelegate: delegate,
                          itemCount: columns * 3,
                          itemBuilder: (_, __) => const ZSkeleton(
                              height: 68, radius: ZRadius.input),
                        )
                      : results.isEmpty
                          ? ZEmptyState(
                              key: const Key('stickerEmpty'),
                              icon: ZIcons.sticker,
                              title: !isTyping && _selectedTab == _recentTabId
                                  ? context.tr('stickerRecentEmpty')
                                  : context.tr('noStickers'),
                            )
                          : GridView.builder(
                              key: const Key('stickerGrid'),
                              padding: const EdgeInsets.fromLTRB(
                                  ZSpace.s12, ZSpace.s4, ZSpace.s12, ZSpace.s8),
                              gridDelegate: delegate,
                              itemCount: results.length,
                              itemBuilder: (context, i) {
                                final sticker = results[i];
                                final url = sticker.resolvedUrl;
                                return GestureDetector(
                                  onLongPressStart: (_) {
                                    ZHaptics.selection();
                                    setState(() => _preview = sticker);
                                  },
                                  onLongPressEnd: (_) {
                                    if (_preview != null) {
                                      setState(() => _preview = null);
                                    }
                                  },
                                  onLongPressCancel: () {
                                    if (_preview != null) {
                                      setState(() => _preview = null);
                                    }
                                  },
                                  child: ZPressable(
                                    key: Key('sticker-${sticker.id}'),
                                    radius: ZRadius.input,
                                    pressScale: 0.90,
                                    onTap: () => _pickSticker(sticker),
                                    semanticLabel: context
                                        .tr('stickerLabel', [sticker.id]),
                                    child: Padding(
                                      padding: const EdgeInsets.all(ZSpace.s4),
                                      child: url == null || url.isEmpty
                                          ? Center(
                                              child: Text('#${sticker.id}',
                                                  style: z.text.caption))
                                          : ZStickerView(
                                              session: widget.session,
                                              sticker: sticker,
                                              animate: false,
                                            ),
                                    ),
                                  ),
                                );
                              },
                            ),
            ),
            // Zalo bottom sticker pack & category dock (hidden while searching)
            if (!isTyping)
              Container(
                key: const Key('stickerCategories'),
                height: 48,
                decoration: BoxDecoration(
                  color: z.layerSubtle,
                  border: Border(top: BorderSide(color: z.divider)),
                ),
                child: ListView(
                  scrollDirection: Axis.horizontal,
                  padding: const EdgeInsets.symmetric(horizontal: ZSpace.s8),
                  children: [
                    if (hasRecents)
                      _StickerDockItem(
                        key: const Key('stickerCat-recent'),
                        selected: _selectedTab == _recentTabId,
                        label: context.tr('stickerRecent'),
                        onTap: _selectRecent,
                        child: Icon(
                          ZIcons.schedule,
                          size: 20,
                          color: _selectedTab == _recentTabId
                              ? z.brand
                              : z.textSecondary,
                        ),
                      ),
                    for (final cat in _stickerCategories)
                      _StickerDockItem(
                        key: Key('stickerCat-${cat.id}'),
                        selected:
                            _selectedPackId == null && _selectedTab == cat.id,
                        label: context.tr(cat.labelKey),
                        onTap: () => _selectCategory(cat),
                        child: Icon(
                          cat.icon,
                          size: 20,
                          color: _selectedPackId == null &&
                                  _selectedTab == cat.id
                              ? z.brand
                              : z.textSecondary,
                        ),
                      ),
                    if (packs.isNotEmpty)
                      Center(
                        child: Container(
                          width: 1,
                          height: 22,
                          margin: const EdgeInsets.symmetric(horizontal: 4),
                          color: z.divider,
                        ),
                      ),
                    for (final pack in packs)
                      _StickerDockItem(
                        key: Key('stickerPack-${pack.cateId}'),
                        selected: _selectedPackId == pack.cateId,
                        label: context.tr('stickerPack', [pack.cateId]),
                        onTap: () => _selectPack(pack.cateId),
                        child: ZStickerView(
                          session: widget.session,
                          sticker: pack.cover,
                          size: 28,
                          animate: false,
                        ),
                      ),
                  ],
                ),
              ),
          ],
        ),
        // Floating animated long-press sticker preview (like Zalo mobile)
        if (_preview != null)
          Positioned.fill(
            child: IgnorePointer(
              child: Center(
                child: Container(
                  width: 152,
                  height: 152,
                  padding: const EdgeInsets.all(ZSpace.s12),
                  decoration: BoxDecoration(
                    color: z.layer,
                    borderRadius: BorderRadius.circular(ZRadius.card),
                    border: Border.all(color: z.border),
                    boxShadow: z.shadowOverlay,
                  ),
                  child: ZStickerView(
                    session: widget.session,
                    sticker: _preview!,
                    size: 128,
                    animate: true,
                  ),
                ),
              ),
            ),
          ),
      ],
    );
  }
}

class _StickerDockItem extends StatelessWidget {
  const _StickerDockItem({
    super.key,
    required this.selected,
    required this.label,
    required this.onTap,
    required this.child,
  });

  final bool selected;
  final String label;
  final VoidCallback onTap;
  final Widget child;

  @override
  Widget build(BuildContext context) {
    final z = context.z;
    return ZPressable(
      onTap: onTap,
      selected: selected,
      semanticLabel: label,
      tooltip: label,
      minSize: ZSizes.touchTarget,
      radius: ZRadius.input,
      color: selected ? z.layerSelected : null,
      child: SizedBox(
        width: ZSizes.touchTarget,
        height: 44,
        child: Stack(
          alignment: Alignment.center,
          children: [
            child,
            if (selected)
              Positioned(
                left: 10,
                right: 10,
                bottom: 2,
                child: Container(
                  height: 2,
                  decoration: BoxDecoration(
                    color: z.brand,
                    borderRadius: BorderRadius.circular(ZRadius.pill),
                  ),
                ),
              ),
          ],
        ),
      ),
    );
  }
}
