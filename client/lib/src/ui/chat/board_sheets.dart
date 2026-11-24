// Conversation pin board, group polls, notes, and reminders UI.
import 'package:material_ui/material_ui.dart';

import '../../domain/models.dart';
import '../../domain/services.dart';
import '../components/basics.dart';
import '../components/fields.dart';
import '../components/overlays.dart';
import '../components/pressable.dart';
import '../l10n/strings.dart';
import '../state/thread_ui.dart';
import '../theme/tokens.dart';
import '../theme/z_icons.dart';
import '../util/format.dart';
import '../util/haptics.dart';

IconData _topicIcon(BoardItemKind kind) => switch (kind) {
      BoardItemKind.poll => ZIcons.poll,
      BoardItemKind.note => ZIcons.note,
      BoardItemKind.reminder => ZIcons.alarm,
      BoardItemKind.link => ZIcons.link,
      BoardItemKind.message => ZIcons.pinFill,
    };

Color _topicColor(ZalosTokens z, BoardItemKind kind) => switch (kind) {
      BoardItemKind.poll => z.success,
      BoardItemKind.note => z.warning,
      BoardItemKind.reminder => z.danger,
      BoardItemKind.link => z.brandText,
      BoardItemKind.message => z.brandText,
    };

String _topicKindLabel(BuildContext context, BoardItemKind kind) => switch (kind) {
      BoardItemKind.poll => context.tr('boardKindPoll'),
      BoardItemKind.note => context.tr('boardKindNote'),
      BoardItemKind.reminder => context.tr('boardKindReminder'),
      BoardItemKind.link => context.tr('boardKindLink'),
      BoardItemKind.message => context.tr('boardKindMessage'),
    };

/// Zalo-style pinned banner shown directly under the chat header when the
/// conversation has pinned items. Renders nothing when [items] is empty.
class PinnedBar extends StatelessWidget {
  const PinnedBar({
    super.key,
    required this.items,
    required this.onTapItem,
    required this.onOpenAll,
    required this.onUnpin,
  });

  final List<PinnedTopic> items;
  final ValueChanged<PinnedTopic> onTapItem;
  final VoidCallback onOpenAll;
  final ValueChanged<PinnedTopic> onUnpin;

  @override
  Widget build(BuildContext context) {
    if (items.isEmpty) return const SizedBox.shrink();
    final z = context.z;
    final top = items.first;
    final accent = _topicColor(z, top.kind);
    final sender = (top.senderName ?? '').trim();
    final title = top.title.trim().isEmpty
        ? _topicKindLabel(context, top.kind)
        : top.title.trim();
    final subtitle = sender.isNotEmpty
        ? '$sender: $title'
        : title;
    return Container(
      key: const Key('pinnedBar'),
      decoration: BoxDecoration(
        color: z.layer,
        border: Border(bottom: BorderSide(color: z.divider)),
      ),
      child: Row(
        children: [
          Expanded(
            child: ZPressable(
              key: const Key('pinnedBarTop'),
              onTap: () {
                ZHaptics.selection();
                onTapItem(top);
              },
              radius: 0,
              minSize: ZSizes.touchTarget,
              semanticLabel: context.tr('pinnedBarLabel', [subtitle]),
              child: Padding(
                padding: const EdgeInsets.symmetric(
                  horizontal: ZSpace.s12,
                  vertical: ZSpace.s8,
                ),
                child: Row(
                  children: [
                    Container(
                      width: 30,
                      height: 30,
                      decoration: BoxDecoration(
                        color: z.layerSubtle,
                        borderRadius: BorderRadius.circular(ZRadius.input),
                      ),
                      alignment: Alignment.center,
                      child: Icon(_topicIcon(top.kind), size: 17, color: accent),
                    ),
                    const SizedBox(width: ZSpace.s8),
                    Expanded(
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        mainAxisSize: MainAxisSize.min,
                        children: [
                          Text(
                            _topicKindLabel(context, top.kind),
                            maxLines: 1,
                            overflow: TextOverflow.ellipsis,
                            style: z.text.captionStrong.copyWith(color: accent),
                          ),
                          Text(
                            subtitle,
                            maxLines: 1,
                            overflow: TextOverflow.ellipsis,
                            style: z.text.caption.copyWith(color: z.textPrimary),
                          ),
                        ],
                      ),
                    ),
                  ],
                ),
              ),
            ),
          ),
          if (items.length > 1)
            Padding(
              padding: const EdgeInsets.only(right: ZSpace.s8),
              child: ZPressable(
                key: const Key('pinnedBarExpand'),
                onTap: () {
                  ZHaptics.selection();
                  onOpenAll();
                },
                minSize: ZSizes.touchTarget,
                radius: ZRadius.pill,
                color: z.layerSubtle,
                semanticLabel: context.tr('pinnedCountLabel', [items.length]),
                child: Padding(
                  padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 6),
                  child: Row(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      Text(
                        '+${items.length - 1}',
                        style: z.text.captionStrong.copyWith(color: z.textSecondary),
                      ),
                      const SizedBox(width: 2),
                      Icon(ZIcons.chevronDown, size: 16, color: z.textSecondary),
                    ],
                  ),
                ),
              ),
            )
          else
            ZIconButton(
              key: const Key('pinnedBarMore'),
              icon: ZIcons.moreHoriz,
              label: context.tr('pinnedListTitle'),
              onPressed: onOpenAll,
            ),
        ],
      ),
    );
  }
}

/// Full list of pinned items (and group board items for groups) with jump,
/// edit (notes), pin/unpin controls.
Future<void> showPinnedBoardSheet(
  BuildContext context, {
  required AccountSession session,
  required String threadId,
  required ThreadType threadType,
  required List<PinnedTopic> initialPins,
  required ValueChanged<PinnedTopic> onOpenItem,
  required VoidCallback onChanged,
  bool canPin = true,
  bool canNotes = false,
}) {
  return showZModal<void>(
    context,
    maxWidth: 460,
    builder: (_) => _PinnedBoardSheet(
      session: session,
      threadId: threadId,
      threadType: threadType,
      initialPins: initialPins,
      onOpenItem: onOpenItem,
      onChanged: onChanged,
      canPin: canPin,
      canNotes: canNotes,
    ),
  );
}

class _PinnedBoardSheet extends StatefulWidget {
  const _PinnedBoardSheet({
    required this.session,
    required this.threadId,
    required this.threadType,
    required this.initialPins,
    required this.onOpenItem,
    required this.onChanged,
    required this.canPin,
    required this.canNotes,
  });

  final AccountSession session;
  final String threadId;
  final ThreadType threadType;
  final List<PinnedTopic> initialPins;
  final ValueChanged<PinnedTopic> onOpenItem;
  final VoidCallback onChanged;
  final bool canPin;
  final bool canNotes;

  @override
  State<_PinnedBoardSheet> createState() => _PinnedBoardSheetState();
}

class _PinnedBoardSheetState extends State<_PinnedBoardSheet> {
  late List<PinnedTopic> _pins = List.of(widget.initialPins);
  List<PinnedTopic>? _board;
  int _tab = 0; // 0 = pinned, 1 = group board
  bool _loading = false;
  bool _busy = false;

  bool get _isGroup => widget.threadType == ThreadType.group;

  @override
  void initState() {
    super.initState();
    _refresh();
  }

  Future<void> _refresh() async {
    setState(() => _loading = true);
    try {
      final state = await widget.session.listPins(widget.threadId, widget.threadType);
      List<PinnedTopic>? board;
      if (_isGroup) {
        try {
          board = await widget.session.listBoard(widget.threadId);
        } catch (_) {}
      }
      if (!mounted) return;
      setState(() {
        _pins = state.items;
        _board = board;
        _loading = false;
      });
    } catch (_) {
      if (mounted) setState(() => _loading = false);
    }
  }

  Future<void> _unpin(PinnedTopic topic) async {
    if (_busy) return;
    setState(() => _busy = true);
    try {
      final next = await widget.session.unpinTopic(
        widget.threadId,
        widget.threadType,
        topic.id,
        topic.topicType,
      );
      if (!mounted) return;
      setState(() => _pins = next.items);
      widget.onChanged();
      zToast(context, context.tr('unpinned'));
    } catch (_) {
      if (mounted) zToast(context, context.tr('actionFailed'));
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  Future<void> _pinItem(PinnedTopic topic) async {
    if (_busy || !_isGroup) return;
    setState(() => _busy = true);
    try {
      await widget.session.pinBoardItem(widget.threadId, topic.id, topic.topicType);
      await _refresh();
      widget.onChanged();
      if (mounted) zToast(context, context.tr('messagePinned'));
    } catch (_) {
      if (mounted) zToast(context, context.tr('actionFailed'));
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final z = context.z;
    final items = _tab == 0 ? _pins : (_board ?? const <PinnedTopic>[]);
    final pinnedIds = {for (final p in _pins) p.id};
    return ZDialogScaffold(
      key: const Key('pinnedBoardSheet'),
      title: context.tr('pinnedListTitle'),
      showClose: true,
      child: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          if (_isGroup) ...[
            ZSegmented<int>(
              segments: [
                (0, context.tr('pinnedTab', [_pins.length])),
                (1, context.tr('boardTab')),
              ],
              selected: _tab,
              onChanged: (v) => setState(() => _tab = v),
            ),
            const SizedBox(height: ZSpace.s12),
          ],
          if (_loading && items.isEmpty)
            const Padding(
              padding: EdgeInsets.symmetric(vertical: ZSpace.s24),
              child: Center(child: CircularProgressIndicator(strokeWidth: 2)),
            )
          else if (items.isEmpty)
            Padding(
              padding: const EdgeInsets.symmetric(vertical: ZSpace.s24),
              child: ZEmptyState(
                icon: ZIcons.pin,
                title: context.tr(_tab == 0 ? 'pinnedEmpty' : 'boardEmpty'),
              ),
            )
          else
            ConstrainedBox(
              constraints: const BoxConstraints(maxHeight: 380),
              child: ListView.separated(
                shrinkWrap: true,
                itemCount: items.length,
                separatorBuilder: (_, __) => Divider(height: 1, color: z.divider),
                itemBuilder: (context, i) {
                  final item = items[i];
                  final accent = _topicColor(z, item.kind);
                  final isPinned = _tab == 0 || pinnedIds.contains(item.id);
                  final title = item.title.trim().isEmpty
                      ? _topicKindLabel(context, item.kind)
                      : item.title.trim();
                  final metaParts = <String>[
                    _topicKindLabel(context, item.kind),
                    if ((item.senderName ?? '').trim().isNotEmpty) item.senderName!.trim(),
                    if (item.createdAt != null && item.createdAt! > 0)
                      formatDateTime(item.createdAt!, context.s),
                  ];
                  return Padding(
                    padding: const EdgeInsets.symmetric(vertical: ZSpace.s8),
                    child: Row(
                      children: [
                        Expanded(
                          child: ZPressable(
                            key: Key('pinnedItem-${item.id}'),
                            onTap: () {
                              Navigator.of(context).pop();
                              widget.onOpenItem(item);
                            },
                            radius: ZRadius.input,
                            minSize: ZSizes.touchTarget,
                            child: Padding(
                              padding: const EdgeInsets.symmetric(
                                horizontal: ZSpace.s4,
                                vertical: ZSpace.s4,
                              ),
                              child: Row(
                                children: [
                                  Container(
                                    width: 34,
                                    height: 34,
                                    decoration: BoxDecoration(
                                      color: z.layerSubtle,
                                      borderRadius: BorderRadius.circular(ZRadius.input),
                                    ),
                                    alignment: Alignment.center,
                                    child: Icon(_topicIcon(item.kind), size: 18, color: accent),
                                  ),
                                  const SizedBox(width: ZSpace.s12),
                                  Expanded(
                                    child: Column(
                                      crossAxisAlignment: CrossAxisAlignment.start,
                                      mainAxisSize: MainAxisSize.min,
                                      children: [
                                        Text(
                                          title,
                                          maxLines: 2,
                                          overflow: TextOverflow.ellipsis,
                                          style: z.text.labelStrong,
                                        ),
                                        const SizedBox(height: 2),
                                        Text(
                                          metaParts.join(' · '),
                                          maxLines: 1,
                                          overflow: TextOverflow.ellipsis,
                                          style: z.text.caption.copyWith(color: z.textSecondary),
                                        ),
                                      ],
                                    ),
                                  ),
                                ],
                              ),
                            ),
                          ),
                        ),
                        if (widget.canNotes && _isGroup && item.kind == BoardItemKind.note)
                          ZIconButton(
                            key: Key('editNote-${item.id}'),
                            icon: ZIcons.edit,
                            label: context.tr('editNote'),
                            onPressed: _busy
                                ? null
                                : () async {
                                    final edited = await showCreateNoteSheet(
                                      context,
                                      session: widget.session,
                                      groupId: widget.threadId,
                                      existing: item,
                                    );
                                    if (edited != null && mounted) {
                                      await _refresh();
                                      widget.onChanged();
                                    }
                                  },
                          ),
                        if (widget.canPin && isPinned)
                          ZIconButton(
                            key: Key('unpinItem-${item.id}'),
                            icon: ZIcons.close,
                            label: context.tr('unpin'),
                            onPressed: _busy ? null : () => _unpin(item),
                          )
                        else if (widget.canPin && _isGroup && !isPinned)
                          ZIconButton(
                            key: Key('pinBoardItem-${item.id}'),
                            icon: ZIcons.pin,
                            label: context.tr('pinMessage'),
                            onPressed: _busy ? null : () => _pinItem(item),
                          ),
                      ],
                    ),
                  );
                },
              ),
            ),
        ],
      ),
    );
  }
}

/// Zalo-style Create Poll sheet for groups.
Future<PollDetail?> showCreatePollSheet(
  BuildContext context, {
  required AccountSession session,
  required String groupId,
}) {
  return showZModal<PollDetail>(
    context,
    maxWidth: 460,
    builder: (_) => _CreatePollSheet(session: session, groupId: groupId),
  );
}

class _CreatePollSheet extends StatefulWidget {
  const _CreatePollSheet({required this.session, required this.groupId});

  final AccountSession session;
  final String groupId;

  @override
  State<_CreatePollSheet> createState() => _CreatePollSheetState();
}

class _CreatePollSheetState extends State<_CreatePollSheet> {
  final TextEditingController _question = TextEditingController();
  final List<TextEditingController> _options = [
    TextEditingController(),
    TextEditingController(),
  ];
  bool _multi = true;
  bool _allowAdd = true;
  bool _hidePreview = false;
  bool _anonymous = false;
  bool _pin = false;
  bool _busy = false;
  String? _error;

  @override
  void dispose() {
    _question.dispose();
    for (final c in _options) {
      c.dispose();
    }
    super.dispose();
  }

  void _addOption() {
    if (_options.length >= 30) return;
    ZHaptics.selection();
    setState(() => _options.add(TextEditingController()));
  }

  void _removeOption(int index) {
    if (_options.length <= 2) return;
    ZHaptics.selection();
    final c = _options.removeAt(index);
    c.dispose();
    setState(() {});
  }

  Future<void> _submit() async {
    final question = _question.text.trim();
    final opts = <String>[];
    final seen = <String>{};
    for (final c in _options) {
      final t = c.text.trim();
      if (t.isNotEmpty && seen.add(t)) opts.add(t);
    }
    if (question.isEmpty) {
      setState(() => _error = context.tr('pollQuestionRequired'));
      return;
    }
    if (opts.length < 2) {
      setState(() => _error = context.tr('pollOptionsMin'));
      return;
    }
    setState(() {
      _busy = true;
      _error = null;
    });
    try {
      final poll = await widget.session.createPoll(
        widget.groupId,
        question: question,
        options: opts,
        allowMultiChoices: _multi,
        allowAddNewOption: _allowAdd && !_hidePreview,
        hideVotePreview: _hidePreview,
        isAnonymous: _anonymous,
        pin: _pin,
      );
      if (!mounted) return;
      ZHaptics.medium();
      zToast(context, context.tr('pollCreated'));
      Navigator.of(context).pop(poll);
    } catch (_) {
      if (mounted) {
        setState(() {
          _busy = false;
          _error = context.tr('pollCreateFailed');
        });
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    final z = context.z;
    return ZDialogScaffold(
      key: const Key('createPollSheet'),
      title: context.tr('createPollTitle'),
      showClose: true,
      actions: [
        ZButton(
          label: context.tr('cancel'),
          variant: ZButtonVariant.text,
          onPressed: _busy ? null : () => Navigator.of(context).pop(),
        ),
        ZButton(
          key: const Key('createPollSubmit'),
          label: context.tr('createPollAction'),
          loading: _busy,
          onPressed: _busy ? null : _submit,
        ),
      ],
      child: ConstrainedBox(
        constraints: const BoxConstraints(maxHeight: 460),
        child: SingleChildScrollView(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            mainAxisSize: MainAxisSize.min,
            children: [
              ZTextField(
                key: const Key('pollQuestionField'),
                controller: _question,
                label: context.tr('pollQuestion'),
                hint: context.tr('pollQuestionHint'),
                maxLength: 200,
                maxLines: 3,
                minLines: 1,
              ),
              const SizedBox(height: ZSpace.s12),
              Text(context.tr('pollOptionsHeading'), style: z.text.captionStrong),
              const SizedBox(height: ZSpace.s8),
              for (var i = 0; i < _options.length; i++)
                Padding(
                  padding: const EdgeInsets.only(bottom: ZSpace.s8),
                  child: Row(
                    children: [
                      Expanded(
                        child: ZTextField(
                          key: Key('pollOptionField-$i'),
                          controller: _options[i],
                          hint: context.tr('pollOptionHint', [i + 1]),
                          maxLength: 120,
                        ),
                      ),
                      if (_options.length > 2)
                        ZIconButton(
                          icon: ZIcons.close,
                          label: context.tr('delete'),
                          onPressed: _busy ? null : () => _removeOption(i),
                        ),
                    ],
                  ),
                ),
              if (_options.length < 30)
                Align(
                  alignment: Alignment.centerLeft,
                  child: ZButton(
                    key: const Key('pollAddOptionField'),
                    label: context.tr('pollAddOption'),
                    icon: ZIcons.plus,
                    variant: ZButtonVariant.text,
                    small: true,
                    onPressed: _busy ? null : _addOption,
                  ),
                ),
              const SizedBox(height: ZSpace.s8),
              Divider(height: 1, color: z.divider),
              _SwitchLine(
                title: context.tr('pollAllowMulti'),
                value: _multi,
                onChanged: _busy ? null : (v) => setState(() => _multi = v),
              ),
              _SwitchLine(
                title: context.tr('pollAllowAdd'),
                value: _allowAdd && !_hidePreview,
                onChanged: _busy || _hidePreview
                    ? null
                    : (v) => setState(() => _allowAdd = v),
              ),
              _SwitchLine(
                title: context.tr('pollHidePreview'),
                value: _hidePreview,
                onChanged: _busy
                    ? null
                    : (v) => setState(() {
                          _hidePreview = v;
                          if (v) _allowAdd = false;
                        }),
              ),
              _SwitchLine(
                title: context.tr('pollAnonymousOption'),
                value: _anonymous,
                onChanged: _busy ? null : (v) => setState(() => _anonymous = v),
              ),
              _SwitchLine(
                title: context.tr('pinToTop'),
                value: _pin,
                onChanged: _busy ? null : (v) => setState(() => _pin = v),
              ),
              if (_error != null) ...[
                const SizedBox(height: ZSpace.s8),
                Text(_error!, style: z.text.caption.copyWith(color: z.danger)),
              ],
            ],
          ),
        ),
      ),
    );
  }
}

/// Interactive Zalo Poll detail & voting modal sheet.
Future<void> showPollDetailSheet(
  BuildContext context, {
  required AccountSession session,
  required Directory directory,
  required int pollId,
  required String groupId,
  required String selfUid,
  bool isAdmin = false,
  Poll? fallbackPoll,
}) {
  return showZModal<void>(
    context,
    maxWidth: 460,
    builder: (_) => _PollDetailSheet(
      session: session,
      directory: directory,
      pollId: pollId,
      groupId: groupId,
      selfUid: selfUid,
      isAdmin: isAdmin,
      fallbackPoll: fallbackPoll,
    ),
  );
}

class _PollDetailSheet extends StatefulWidget {
  const _PollDetailSheet({
    required this.session,
    required this.directory,
    required this.pollId,
    required this.groupId,
    required this.selfUid,
    required this.isAdmin,
    this.fallbackPoll,
  });

  final AccountSession session;
  final Directory directory;
  final int pollId;
  final String groupId;
  final String selfUid;
  final bool isAdmin;
  final Poll? fallbackPoll;

  @override
  State<_PollDetailSheet> createState() => _PollDetailSheetState();
}

class _PollDetailSheetState extends State<_PollDetailSheet> {
  final TextEditingController _newOpt = TextEditingController();
  PollDetail? _detail;
  final Set<int> _selected = {};
  bool _loading = true;
  bool _busy = false;
  bool _failed = false;

  @override
  void initState() {
    super.initState();
    final fb = widget.fallbackPoll;
    if (fb != null) {
      for (final o in fb.options) {
        if (o.voted == true) _selected.add(o.id);
      }
    }
    _load();
  }

  @override
  void dispose() {
    _newOpt.dispose();
    super.dispose();
  }

  Future<void> _load() async {
    setState(() {
      _loading = true;
      _failed = false;
    });
    try {
      final d = await widget.session.pollDetail(widget.pollId, groupId: widget.groupId);
      if (!mounted) return;
      final voterIds = <String>{
        if (d.creatorId.isNotEmpty) d.creatorId,
        for (final o in d.options) ...o.voters,
      };
      widget.directory.need(voterIds);
      setState(() {
        _detail = d;
        _selected
          ..clear()
          ..addAll(d.options.where((o) => o.voted).map((o) => o.id));
        _loading = false;
      });
    } catch (_) {
      if (mounted) {
        setState(() {
          _loading = false;
          _failed = _detail == null && widget.fallbackPoll == null;
        });
      }
    }
  }

  void _toggleOption(int optionId, bool multi) {
    ZHaptics.selection();
    setState(() {
      if (multi) {
        if (!_selected.remove(optionId)) _selected.add(optionId);
      } else {
        if (_selected.contains(optionId)) {
          _selected.clear();
        } else {
          _selected
            ..clear()
            ..add(optionId);
        }
      }
    });
  }

  Future<void> _vote() async {
    if (_busy) return;
    setState(() => _busy = true);
    try {
      final updated = await widget.session.votePoll(
        widget.pollId,
        _selected.toList(),
        groupId: widget.groupId,
      );
      if (!mounted) return;
      ZHaptics.medium();
      setState(() {
        _detail = updated;
        _selected
          ..clear()
          ..addAll(updated.options.where((o) => o.voted).map((o) => o.id));
      });
      zToast(context, context.tr('pollVoted'));
    } catch (_) {
      if (mounted) zToast(context, context.tr('actionFailed'));
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  Future<void> _addOption() async {
    final text = _newOpt.text.trim();
    if (text.isEmpty || _busy) return;
    setState(() => _busy = true);
    try {
      final updated = await widget.session.addPollOption(
        widget.pollId,
        text,
        votedOptionIds: _selected.toList(),
        voteNew: true,
        groupId: widget.groupId,
      );
      if (!mounted) return;
      _newOpt.clear();
      ZHaptics.medium();
      setState(() {
        _detail = updated;
        _selected
          ..clear()
          ..addAll(updated.options.where((o) => o.voted).map((o) => o.id));
      });
    } catch (_) {
      if (mounted) zToast(context, context.tr('actionFailed'));
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  Future<void> _lock() async {
    final ok = await zConfirm(
      context,
      title: context.tr('pollLockTitle'),
      message: context.tr('pollLockBody'),
      confirmLabel: context.tr('pollLockAction'),
      danger: true,
    );
    if (!ok || !mounted) return;
    setState(() => _busy = true);
    try {
      final updated = await widget.session.lockPoll(widget.pollId, groupId: widget.groupId);
      if (!mounted) return;
      setState(() => _detail = updated);
      zToast(context, context.tr('pollClosed'));
    } catch (_) {
      if (mounted) zToast(context, context.tr('actionFailed'));
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  Future<void> _pin() async {
    if (_busy || widget.groupId.isEmpty) return;
    setState(() => _busy = true);
    try {
      await widget.session.pinBoardItem(widget.groupId, '${widget.pollId}', 3);
      if (mounted) zToast(context, context.tr('messagePinned'));
    } catch (_) {
      if (mounted) zToast(context, context.tr('actionFailed'));
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  Future<void> _share() async {
    if (_busy) return;
    setState(() => _busy = true);
    try {
      await widget.session.sharePoll(widget.pollId);
      if (mounted) zToast(context, context.tr('pollShared'));
    } catch (_) {
      if (mounted) zToast(context, context.tr('actionFailed'));
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final z = context.z;
    final detail = _detail;
    final fb = widget.fallbackPoll;
    final question = detail?.question.isNotEmpty == true
        ? detail!.question
        : (fb?.question ?? context.tr('pollTitle'));
    final closed = detail?.closed ?? (fb?.closed ?? false);
    final multi = detail?.multiple ?? (fb?.multiple ?? true);
    final anonymous = detail?.anonymous ?? (fb?.anonymous ?? false);
    final allowAdd = detail?.allowAdd ?? false;
    final hidePreview = (detail?.hidePreview ?? false) && !(detail?.joined ?? false) && !closed;
    final canLock = !closed &&
        (widget.isAdmin || (detail != null && detail.creatorId == widget.selfUid));
    final options = detail != null
        ? detail.options
        : [
            for (final o in fb?.options ?? const <PollOption>[])
              PollOptionDetail(
                id: o.id,
                content: o.text,
                votes: o.votes ?? 0,
                voted: o.voted ?? false,
              ),
          ];
    final maxVotes = options.fold<int>(0, (m, o) => o.votes > m ? o.votes : m);
    final total = detail?.totalVotes ??
        (fb?.totalVotes ?? options.fold<int>(0, (s, o) => s + o.votes));
    final initialSelected = {for (final o in options) if (o.voted) o.id};
    final dirty = _selected.length != initialSelected.length ||
        !_selected.containsAll(initialSelected);

    return ZDialogScaffold(
      key: const Key('pollDetailSheet'),
      title: context.tr('pollTitle'),
      showClose: true,
      actions: [
        if (!closed)
          ZButton(
            key: const Key('pollVoteSubmit'),
            label: context.tr('pollVoteAction'),
            loading: _busy,
            onPressed: _busy || !dirty ? null : _vote,
          ),
      ],
      child: _failed
          ? ZErrorState(
              title: context.tr('loadFailed'),
              retryLabel: context.tr('retry'),
              onRetry: _load,
            )
          : ConstrainedBox(
              constraints: const BoxConstraints(maxHeight: 460),
              child: SingleChildScrollView(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.stretch,
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    Text(question, style: z.text.title),
                    const SizedBox(height: ZSpace.s8),
                    Wrap(
                      spacing: ZSpace.s4,
                      runSpacing: ZSpace.s4,
                      children: [
                        if (closed) ZChip(label: context.tr('pollClosed'), tone: ZTone.danger),
                        if (multi) ZChip(label: context.tr('pollMultiple')),
                        if (anonymous) ZChip(label: context.tr('pollAnonymous')),
                        if (!hidePreview) ZChip(label: context.tr('pollVotes', [total])),
                      ],
                    ),
                    const SizedBox(height: ZSpace.s12),
                    if (_loading && options.isEmpty)
                      const Padding(
                        padding: EdgeInsets.symmetric(vertical: ZSpace.s24),
                        child: Center(child: CircularProgressIndicator(strokeWidth: 2)),
                      )
                    else
                      for (final opt in options)
                        Padding(
                          padding: const EdgeInsets.only(bottom: ZSpace.s8),
                          child: _PollOptionTile(
                            key: Key('pollOpt-${opt.id}'),
                            option: opt,
                            selected: _selected.contains(opt.id),
                            multi: multi,
                            closed: closed,
                            hideVotes: hidePreview,
                            anonymous: anonymous,
                            ratio: !hidePreview && maxVotes > 0 ? opt.votes / maxVotes : 0,
                            directory: widget.directory,
                            onTap: closed || _busy ? null : () => _toggleOption(opt.id, multi),
                          ),
                        ),
                    if (allowAdd && !closed) ...[
                      const SizedBox(height: ZSpace.s4),
                      Row(
                        children: [
                          Expanded(
                            child: ZTextField(
                              key: const Key('pollNewOptionInput'),
                              controller: _newOpt,
                              hint: context.tr('pollAddOptionHint'),
                              maxLength: 120,
                            ),
                          ),
                          const SizedBox(width: ZSpace.s8),
                          ZButton(
                            key: const Key('pollAddOptionSubmit'),
                            label: context.tr('pollAddOptionShort'),
                            small: true,
                            onPressed: _busy ? null : _addOption,
                          ),
                        ],
                      ),
                    ],
                    const SizedBox(height: ZSpace.s12),
                    Divider(height: 1, color: z.divider),
                    const SizedBox(height: ZSpace.s8),
                    Wrap(
                      spacing: ZSpace.s8,
                      runSpacing: ZSpace.s8,
                      children: [
                        if (widget.groupId.isNotEmpty)
                          ZButton(
                            key: const Key('pollPinAction'),
                            label: context.tr('pinMessage'),
                            icon: ZIcons.pin,
                            variant: ZButtonVariant.secondary,
                            small: true,
                            onPressed: _busy ? null : _pin,
                          ),
                        ZButton(
                          key: const Key('pollShareAction'),
                          label: context.tr('share'),
                          icon: ZIcons.share,
                          variant: ZButtonVariant.secondary,
                          small: true,
                          onPressed: _busy ? null : _share,
                        ),
                        if (canLock)
                          ZButton(
                            key: const Key('pollLockButton'),
                            label: context.tr('pollLockAction'),
                            icon: ZIcons.lock,
                            variant: ZButtonVariant.destructive,
                            small: true,
                            onPressed: _busy ? null : _lock,
                          ),
                      ],
                    ),
                  ],
                ),
              ),
            ),
    );
  }
}

class _PollOptionTile extends StatelessWidget {
  const _PollOptionTile({
    super.key,
    required this.option,
    required this.selected,
    required this.multi,
    required this.closed,
    required this.hideVotes,
    required this.anonymous,
    required this.ratio,
    required this.directory,
    required this.onTap,
  });

  final PollOptionDetail option;
  final bool selected;
  final bool multi;
  final bool closed;
  final bool hideVotes;
  final bool anonymous;
  final double ratio;
  final Directory directory;
  final VoidCallback? onTap;

  @override
  Widget build(BuildContext context) {
    final z = context.z;
    final voterNames = anonymous || hideVotes
        ? const <String>[]
        : [
            for (final uid in option.voters.take(3))
              directory.nameOf(uid).isEmpty ? uid : directory.nameOf(uid),
          ];
    return ClipRRect(
      borderRadius: BorderRadius.circular(ZRadius.input),
      child: Stack(
        children: [
          Positioned.fill(
            child: ColoredBox(color: z.layerSubtle),
          ),
          if (!hideVotes && ratio > 0)
            Positioned.fill(
              child: FractionallySizedBox(
                alignment: Alignment.centerLeft,
                widthFactor: ratio.clamp(0.0, 1.0),
                child: ColoredBox(
                  color: selected ? z.brandSubtle : z.layerSelected,
                ),
              ),
            ),
          ZPressable(
            onTap: onTap,
            radius: ZRadius.input,
            minSize: ZSizes.touchTarget,
            border: Border.all(color: selected ? z.brand : z.border),
            child: Padding(
              padding: const EdgeInsets.symmetric(
                horizontal: ZSpace.s12,
                vertical: ZSpace.s12,
              ),
              child: Row(
                children: [
                  Icon(
                    selected
                        ? (multi ? ZIcons.checkBox : ZIcons.radioChecked)
                        : (multi ? ZIcons.checkBoxBlank : ZIcons.radioUnchecked),
                    size: 20,
                    color: selected ? z.brand : z.textTertiary,
                  ),
                  const SizedBox(width: ZSpace.s12),
                  Expanded(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        Text(
                          option.content,
                          style: selected ? z.text.labelStrong : z.text.labelRegular,
                        ),
                        if (voterNames.isNotEmpty)
                          Padding(
                            padding: const EdgeInsets.only(top: 2),
                            child: Text(
                              voterNames.join(', ') +
                                  (option.voters.length > 3
                                      ? ' +${option.voters.length - 3}'
                                      : ''),
                              maxLines: 1,
                              overflow: TextOverflow.ellipsis,
                              style: z.text.caption.copyWith(color: z.textSecondary),
                            ),
                          ),
                      ],
                    ),
                  ),
                  if (!hideVotes)
                    Padding(
                      padding: const EdgeInsets.only(left: ZSpace.s8),
                      child: Text(
                        '${option.votes}',
                        style: z.text.labelStrong.copyWith(
                          color: selected ? z.brandText : z.textSecondary,
                        ),
                      ),
                    ),
                ],
              ),
            ),
          ),
        ],
      ),
    );
  }
}

/// Zalo-style Create / Edit Note sheet for groups.
Future<PinnedTopic?> showCreateNoteSheet(
  BuildContext context, {
  required AccountSession session,
  required String groupId,
  PinnedTopic? existing,
}) {
  return showZModal<PinnedTopic>(
    context,
    maxWidth: 440,
    builder: (_) => _CreateNoteSheet(
      session: session,
      groupId: groupId,
      existing: existing,
    ),
  );
}

class _CreateNoteSheet extends StatefulWidget {
  const _CreateNoteSheet({
    required this.session,
    required this.groupId,
    this.existing,
  });

  final AccountSession session;
  final String groupId;
  final PinnedTopic? existing;

  @override
  State<_CreateNoteSheet> createState() => _CreateNoteSheetState();
}

class _CreateNoteSheetState extends State<_CreateNoteSheet> {
  late final TextEditingController _title =
      TextEditingController(text: widget.existing?.title ?? '');
  late bool _pin = widget.existing?.pinned ?? true;
  bool _busy = false;
  String? _error;

  @override
  void dispose() {
    _title.dispose();
    super.dispose();
  }

  Future<void> _submit() async {
    final title = _title.text.trim();
    if (title.isEmpty) {
      setState(() => _error = context.tr('noteRequired'));
      return;
    }
    setState(() {
      _busy = true;
      _error = null;
    });
    try {
      final note = widget.existing == null
          ? await widget.session.createNote(widget.groupId, title, pin: _pin)
          : await widget.session.editNote(
              widget.groupId,
              widget.existing!.id,
              title,
              pin: _pin,
            );
      if (!mounted) return;
      ZHaptics.medium();
      zToast(context, context.tr('noteSaved'));
      Navigator.of(context).pop(note);
    } catch (_) {
      if (mounted) {
        setState(() {
          _busy = false;
          _error = context.tr('actionFailed');
        });
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    final z = context.z;
    return ZDialogScaffold(
      key: const Key('createNoteSheet'),
      title: context.tr(widget.existing == null ? 'createNoteTitle' : 'editNote'),
      showClose: true,
      actions: [
        ZButton(
          label: context.tr('cancel'),
          variant: ZButtonVariant.text,
          onPressed: _busy ? null : () => Navigator.of(context).pop(),
        ),
        ZButton(
          key: const Key('createNoteSubmit'),
          label: context.tr('save'),
          loading: _busy,
          onPressed: _busy ? null : _submit,
        ),
      ],
      child: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          ZTextField(
            key: const Key('noteTitleField'),
            controller: _title,
            label: context.tr('noteContentLabel'),
            hint: context.tr('noteContentHint'),
            minLines: 3,
            maxLines: 6,
            maxLength: 500,
          ),
          const SizedBox(height: ZSpace.s8),
          _SwitchLine(
            title: context.tr('pinToTop'),
            value: _pin,
            onChanged: _busy ? null : (v) => setState(() => _pin = v),
          ),
          if (_error != null) ...[
            const SizedBox(height: ZSpace.s8),
            Text(_error!, style: z.text.caption.copyWith(color: z.danger)),
          ],
        ],
      ),
    );
  }
}

/// Zalo-style Create Reminder sheet (works for both 1:1 and groups).
Future<ReminderItem?> showCreateReminderSheet(
  BuildContext context, {
  required AccountSession session,
  required String threadId,
  required ThreadType threadType,
}) {
  return showZModal<ReminderItem>(
    context,
    maxWidth: 440,
    builder: (_) => _CreateReminderSheet(
      session: session,
      threadId: threadId,
      threadType: threadType,
    ),
  );
}

class _CreateReminderSheet extends StatefulWidget {
  const _CreateReminderSheet({
    required this.session,
    required this.threadId,
    required this.threadType,
  });

  final AccountSession session;
  final String threadId;
  final ThreadType threadType;

  @override
  State<_CreateReminderSheet> createState() => _CreateReminderSheetState();
}

class _CreateReminderSheetState extends State<_CreateReminderSheet> {
  final TextEditingController _title = TextEditingController();
  int _preset = 1; // 0=+15m, 1=+1h, 2=tonight 20:00, 3=tomorrow 09:00
  int _repeat = 0; // 0=none, 1=daily, 2=weekly, 3=monthly
  bool _busy = false;
  String? _error;

  @override
  void dispose() {
    _title.dispose();
    super.dispose();
  }

  int _selectedTimeMs() {
    final now = DateTime.now();
    return switch (_preset) {
      0 => now.add(const Duration(minutes: 15)).millisecondsSinceEpoch,
      1 => now.add(const Duration(hours: 1)).millisecondsSinceEpoch,
      2 => DateTime(now.year, now.month, now.day, 20, 0).isAfter(now)
          ? DateTime(now.year, now.month, now.day, 20, 0).millisecondsSinceEpoch
          : DateTime(now.year, now.month, now.day + 1, 20, 0).millisecondsSinceEpoch,
      _ => DateTime(now.year, now.month, now.day + 1, 9, 0).millisecondsSinceEpoch,
    };
  }

  Future<void> _submit() async {
    final title = _title.text.trim();
    if (title.isEmpty) {
      setState(() => _error = context.tr('reminderRequired'));
      return;
    }
    setState(() {
      _busy = true;
      _error = null;
    });
    try {
      final item = await widget.session.createReminder(
        widget.threadId,
        widget.threadType,
        title: title,
        startTime: _selectedTimeMs(),
        repeat: _repeat,
      );
      if (!mounted) return;
      ZHaptics.medium();
      zToast(context, context.tr('reminderCreated'));
      Navigator.of(context).pop(item);
    } catch (_) {
      if (mounted) {
        setState(() {
          _busy = false;
          _error = context.tr('actionFailed');
        });
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    final z = context.z;
    return ZDialogScaffold(
      key: const Key('createReminderSheet'),
      title: context.tr('createReminderTitle'),
      showClose: true,
      actions: [
        ZButton(
          label: context.tr('cancel'),
          variant: ZButtonVariant.text,
          onPressed: _busy ? null : () => Navigator.of(context).pop(),
        ),
        ZButton(
          key: const Key('createReminderSubmit'),
          label: context.tr('createReminderAction'),
          loading: _busy,
          onPressed: _busy ? null : _submit,
        ),
      ],
      child: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          ZTextField(
            key: const Key('reminderTitleField'),
            controller: _title,
            label: context.tr('reminderContentLabel'),
            hint: context.tr('reminderContentHint'),
            maxLength: 200,
          ),
          const SizedBox(height: ZSpace.s12),
          Text(context.tr('reminderTimeLabel'), style: z.text.captionStrong),
          const SizedBox(height: ZSpace.s8),
          Wrap(
            spacing: ZSpace.s8,
            runSpacing: ZSpace.s8,
            children: [
              ZChip(
                label: context.tr('reminderIn15m'),
                selected: _preset == 0,
                onTap: _busy ? null : () => setState(() => _preset = 0),
              ),
              ZChip(
                label: context.tr('reminderIn1h'),
                selected: _preset == 1,
                onTap: _busy ? null : () => setState(() => _preset = 1),
              ),
              ZChip(
                label: context.tr('reminderTonight'),
                selected: _preset == 2,
                onTap: _busy ? null : () => setState(() => _preset = 2),
              ),
              ZChip(
                label: context.tr('reminderTomorrow'),
                selected: _preset == 3,
                onTap: _busy ? null : () => setState(() => _preset = 3),
              ),
            ],
          ),
          const SizedBox(height: ZSpace.s12),
          Text(context.tr('reminderRepeatLabel'), style: z.text.captionStrong),
          const SizedBox(height: ZSpace.s8),
          Wrap(
            spacing: ZSpace.s8,
            runSpacing: ZSpace.s8,
            children: [
              ZChip(
                label: context.tr('reminderRepeatNone'),
                selected: _repeat == 0,
                onTap: _busy ? null : () => setState(() => _repeat = 0),
              ),
              ZChip(
                label: context.tr('reminderRepeatDaily'),
                selected: _repeat == 1,
                onTap: _busy ? null : () => setState(() => _repeat = 1),
              ),
              ZChip(
                label: context.tr('reminderRepeatWeekly'),
                selected: _repeat == 2,
                onTap: _busy ? null : () => setState(() => _repeat = 2),
              ),
              ZChip(
                label: context.tr('reminderRepeatMonthly'),
                selected: _repeat == 3,
                onTap: _busy ? null : () => setState(() => _repeat = 3),
              ),
            ],
          ),
          if (_error != null) ...[
            const SizedBox(height: ZSpace.s8),
            Text(_error!, style: z.text.caption.copyWith(color: z.danger)),
          ],
        ],
      ),
    );
  }
}

/// Lists reminders of a conversation with create and remove actions.
Future<void> showRemindersSheet(
  BuildContext context, {
  required AccountSession session,
  required String threadId,
  required ThreadType threadType,
}) {
  return showZModal<void>(
    context,
    maxWidth: 460,
    builder: (_) => _RemindersSheet(
      session: session,
      threadId: threadId,
      threadType: threadType,
    ),
  );
}

class _RemindersSheet extends StatefulWidget {
  const _RemindersSheet({
    required this.session,
    required this.threadId,
    required this.threadType,
  });

  final AccountSession session;
  final String threadId;
  final ThreadType threadType;

  @override
  State<_RemindersSheet> createState() => _RemindersSheetState();
}

class _RemindersSheetState extends State<_RemindersSheet> {
  List<ReminderItem> _items = const [];
  bool _loading = true;
  bool _busy = false;

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    setState(() => _loading = true);
    try {
      final list = await widget.session.listReminders(widget.threadId, widget.threadType);
      if (mounted) {
        setState(() {
          _items = list;
          _loading = false;
        });
      }
    } catch (_) {
      if (mounted) setState(() => _loading = false);
    }
  }

  Future<void> _remove(ReminderItem item) async {
    if (_busy) return;
    setState(() => _busy = true);
    try {
      await widget.session.removeReminder(widget.threadId, widget.threadType, item.id);
      if (!mounted) return;
      setState(() => _items = _items.where((r) => r.id != item.id).toList());
      zToast(context, context.tr('reminderRemoved'));
    } catch (_) {
      if (mounted) zToast(context, context.tr('actionFailed'));
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  String _repeatLabel(BuildContext context, int repeat) => switch (repeat) {
        1 => context.tr('reminderRepeatDaily'),
        2 => context.tr('reminderRepeatWeekly'),
        3 => context.tr('reminderRepeatMonthly'),
        _ => '',
      };

  @override
  Widget build(BuildContext context) {
    final z = context.z;
    return ZDialogScaffold(
      key: const Key('remindersSheet'),
      title: context.tr('remindersTitle'),
      showClose: true,
      actions: [
        ZButton(
          key: const Key('remindersCreateButton'),
          label: context.tr('createReminderTitle'),
          icon: ZIcons.plus,
          onPressed: () async {
            final created = await showCreateReminderSheet(
              context,
              session: widget.session,
              threadId: widget.threadId,
              threadType: widget.threadType,
            );
            if (created != null && mounted) await _load();
          },
        ),
      ],
      child: _loading
          ? const Padding(
              padding: EdgeInsets.symmetric(vertical: ZSpace.s24),
              child: Center(child: CircularProgressIndicator(strokeWidth: 2)),
            )
          : _items.isEmpty
              ? Padding(
                  padding: const EdgeInsets.symmetric(vertical: ZSpace.s24),
                  child: ZEmptyState(
                    icon: ZIcons.alarm,
                    title: context.tr('remindersEmpty'),
                  ),
                )
              : ConstrainedBox(
                  constraints: const BoxConstraints(maxHeight: 360),
                  child: ListView.separated(
                    shrinkWrap: true,
                    itemCount: _items.length,
                    separatorBuilder: (_, __) => Divider(height: 1, color: z.divider),
                    itemBuilder: (context, i) {
                      final item = _items[i];
                      final repeat = _repeatLabel(context, item.repeat);
                      final when = item.startTime > 0
                          ? formatDateTime(item.startTime, context.s)
                          : '';
                      return Padding(
                        padding: const EdgeInsets.symmetric(vertical: ZSpace.s8),
                        child: Row(
                          children: [
                            Container(
                              width: 34,
                              height: 34,
                              decoration: BoxDecoration(
                                color: z.layerSubtle,
                                borderRadius: BorderRadius.circular(ZRadius.input),
                              ),
                              alignment: Alignment.center,
                              child: Icon(ZIcons.alarm, size: 18, color: z.danger),
                            ),
                            const SizedBox(width: ZSpace.s12),
                            Expanded(
                              child: Column(
                                crossAxisAlignment: CrossAxisAlignment.start,
                                mainAxisSize: MainAxisSize.min,
                                children: [
                                  Text(
                                    item.title,
                                    maxLines: 2,
                                    overflow: TextOverflow.ellipsis,
                                    style: z.text.labelStrong,
                                  ),
                                  if (when.isNotEmpty || repeat.isNotEmpty)
                                    Text(
                                      [
                                        if (when.isNotEmpty) when,
                                        if (repeat.isNotEmpty) repeat,
                                      ].join(' · '),
                                      style: z.text.caption.copyWith(color: z.textSecondary),
                                    ),
                                ],
                              ),
                            ),
                            ZIconButton(
                              key: Key('removeReminder-${item.id}'),
                              icon: ZIcons.delete,
                              label: context.tr('delete'),
                              onPressed: _busy ? null : () => _remove(item),
                            ),
                          ],
                        ),
                      );
                    },
                  ),
                ),
    );
  }
}

class _SwitchLine extends StatelessWidget {
  const _SwitchLine({
    required this.title,
    required this.value,
    required this.onChanged,
  });

  final String title;
  final bool value;
  final ValueChanged<bool>? onChanged;

  @override
  Widget build(BuildContext context) {
    return ZSwitchRow(
      title: title,
      value: value,
      onChanged: onChanged,
    );
  }
}
