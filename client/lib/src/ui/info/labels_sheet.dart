// Phase D: conversation labels. The whole label set is versioned, so every
// write replaces the set at the version the user last saw.
import 'package:material_ui/material_ui.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../domain/models.dart';
import '../../domain/services.dart';
import '../components/basics.dart';
import '../components/fields.dart';
import '../components/motion.dart';
import '../components/overlays.dart';
import '../components/pressable.dart';
import '../l10n/strings.dart';
import '../theme/tokens.dart';
import '../theme/z_icons.dart';
import '../util/format.dart';

final labelsProvider = FutureProvider.family<LabelsState, AccountSession>((ref, session) => session.labels());

/// Labels assigned to [threadId], in the order Zalo keeps them.
List<ConversationLabel> labelsForThread(LabelsState? state, String threadId) =>
    [for (final label in state?.labels ?? const <ConversationLabel>[]) if (label.conversations.contains(threadId)) label];

ConversationLabel _copyLabel(ConversationLabel label, {String? text, List<String>? conversations}) => ConversationLabel(
      id: label.id,
      text: text ?? label.text,
      textKey: label.textKey,
      conversations: conversations ?? label.conversations,
      color: label.color,
      offset: label.offset,
      emoji: label.emoji,
      createTime: label.createTime,
    );

Future<void> showLabelsSheet(BuildContext context, {required AccountSession session, required String threadId}) =>
    showZModal<void>(context, builder: (_) => LabelsSheet(session: session, threadId: threadId));

class LabelsSheet extends ConsumerStatefulWidget {
  const LabelsSheet({super.key, required this.session, required this.threadId});

  final AccountSession session;
  final String threadId;

  @override
  ConsumerState<LabelsSheet> createState() => _LabelsSheetState();
}

class _LabelsSheetState extends ConsumerState<LabelsSheet> {
  final TextEditingController _newLabel = TextEditingController();

  LabelsState? _state;
  bool _loading = true;
  bool _failed = false;
  bool _busy = false;
  bool _conflict = false;
  String? _createError;

  @override
  void initState() {
    super.initState();
    _load();
  }

  @override
  void dispose() {
    _newLabel.dispose();
    super.dispose();
  }

  Future<void> _load() async {
    setState(() {
      _loading = true;
      _failed = false;
    });
    try {
      final state = await widget.session.labels();
      if (!mounted) return;
      setState(() {
        _state = state;
        _loading = false;
      });
    } catch (_) {
      if (!mounted) return;
      setState(() {
        _failed = true;
        _loading = false;
      });
    }
  }

  /// Writes [next] at the loaded version. A stale version reloads the set and
  /// asks the user to retry; the labels just loaded are never replaced by the
  /// rejected draft.
  Future<bool> _apply(List<ConversationLabel> next) async {
    final current = _state;
    if (current == null || _busy) return false;
    setState(() {
      _busy = true;
      _conflict = false;
    });
    try {
      final updated = await widget.session.updateLabels(next, current.version);
      if (!mounted) return false;
      setState(() {
        _state = updated;
        _busy = false;
      });
      ref.invalidate(labelsProvider(widget.session));
      zToast(context, context.tr('labelsSaved'));
      return true;
    } catch (_) {
      LabelsState? fresh;
      try {
        fresh = await widget.session.labels();
      } catch (_) {
        // Keep the set the user was looking at; nothing is lost.
      }
      if (!mounted) return false;
      final conflict = fresh != null && fresh.version != current.version;
      setState(() {
        if (fresh != null) _state = fresh;
        _busy = false;
        _conflict = conflict;
      });
      ref.invalidate(labelsProvider(widget.session));
      if (!conflict) zToast(context, context.tr('actionFailed'));
      return false;
    }
  }

  Future<void> _toggle(ConversationLabel label, bool assigned) async {
    final current = _state;
    if (current == null) return;
    final conversations = assigned
        ? {...label.conversations, widget.threadId}.toList()
        : [for (final id in label.conversations) if (id != widget.threadId) id];
    await _apply([for (final item in current.labels) item.id == label.id ? _copyLabel(item, conversations: conversations) : item]);
  }

  Future<void> _create() async {
    final current = _state;
    final text = _newLabel.text.trim();
    if (current == null) return;
    if (text.isEmpty) {
      setState(() => _createError = context.tr('labelsNameRequired'));
      return;
    }
    var id = 1;
    for (final label in current.labels) {
      if (label.id >= id) id = label.id + 1;
    }
    final created = await _apply([
      ...current.labels,
      ConversationLabel(id: id, text: text, conversations: [widget.threadId], createTime: ZClock.nowMs()),
    ]);
    if (!mounted) return;
    if (created) {
      _newLabel.clear();
      setState(() => _createError = null);
    }
  }

  Future<void> _rename(ConversationLabel label) async {
    final current = _state;
    if (current == null) return;
    final text = await showZModal<String>(
      context,
      builder: (_) => _RenameLabelDialog(initial: label.text),
    );
    if (text == null || !mounted) return;
    await _apply([for (final item in current.labels) item.id == label.id ? _copyLabel(item, text: text) : item]);
  }

  Future<void> _delete(ConversationLabel label) async {
    final current = _state;
    if (current == null) return;
    final ok = await zConfirm(
      context,
      title: context.tr('labelsDeleteTitle', [label.text]),
      message: context.tr('labelsDeleteBody'),
      confirmLabel: context.tr('delete'),
    );
    if (!ok || !mounted) return;
    await _apply([for (final item in current.labels) if (item.id != label.id) item]);
  }

  Widget _labelRow(ConversationLabel label) {
    final assigned = label.conversations.contains(widget.threadId);
    return Row(
      key: Key('labelRow-${label.id}'),
      children: [
        Expanded(
          child: ZCheckRow(
            key: Key('labelAssign-${label.id}'),
            label: label.text,
            value: assigned,
            onChanged: _busy ? null : (value) => _toggle(label, value),
          ),
        ),
        ZIconButton(
          key: Key('labelRename-${label.id}'),
          icon: ZIcons.edit,
          label: context.tr('labelsRenameTitle'),
          size: 32,
          iconSize: 18,
          onPressed: _busy ? null : () => _rename(label),
        ),
        ZIconButton(
          key: Key('labelDelete-${label.id}'),
          icon: ZIcons.delete,
          label: context.tr('delete'),
          size: 32,
          iconSize: 18,
          onPressed: _busy ? null : () => _delete(label),
        ),
      ],
    );
  }

  @override
  Widget build(BuildContext context) {
    final z = context.z;
    final state = _state;
    return ZDialogScaffold(
      key: const Key('labelsSheet'),
      title: context.tr('labelsTitle'),
      showClose: true,
      child: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Text(context.tr('labelsAssignHint'), style: z.text.caption),
          const SizedBox(height: ZSpace.s8),
          ZReveal(
            child: _conflict
                ? ZBanner(
                    key: const Key('labelsConflict'),
                    tone: ZTone.warning,
                    icon: ZIcons.warning,
                    text: context.tr('labelsConflict'),
                  )
                : null,
          ),
          if (_loading)
            const Column(
              key: Key('labelsLoading'),
              children: [ZSkeletonRow(avatar: 0, height: 52), ZSkeletonRow(avatar: 0, height: 52), ZSkeletonRow(avatar: 0, height: 52)],
            )
          else if (_failed)
            ZErrorState(
              key: const Key('labelsError'),
              title: context.tr('labelsLoadFailed'),
              retryLabel: context.tr('retry'),
              onRetry: _load,
            )
          else if (state != null && state.labels.isEmpty)
            ZEmptyState(
              key: const Key('labelsEmpty'),
              icon: ZIcons.label,
              title: context.tr('labelsEmpty'),
              subtitle: context.tr('labelsEmptyHint'),
            )
          else if (state != null)
            for (final label in state.labels) _labelRow(label),
          Container(height: 1, margin: const EdgeInsets.symmetric(vertical: ZSpace.s12), color: z.divider),
          Text(context.tr('labelsCreateTitle'), style: z.text.label),
          const SizedBox(height: ZSpace.s8),
          Row(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Expanded(
                child: ZTextField(
                  key: const Key('labelCreateField'),
                  controller: _newLabel,
                  hint: context.tr('labelsName'),
                  errorText: _createError,
                  enabled: state != null && !_busy,
                  onChanged: (_) {
                    if (_createError != null) setState(() => _createError = null);
                  },
                  onSubmitted: (_) => _create(),
                ),
              ),
              const SizedBox(width: ZSpace.s8),
              ZButton(
                key: const Key('labelCreateButton'),
                label: context.tr('labelsCreate'),
                small: true,
                loading: _busy,
                onPressed: state == null || _busy ? null : _create,
              ),
            ],
          ),
        ],
      ),
    );
  }
}

class _RenameLabelDialog extends StatefulWidget {
  const _RenameLabelDialog({required this.initial});

  final String initial;

  @override
  State<_RenameLabelDialog> createState() => _RenameLabelDialogState();
}

class _RenameLabelDialogState extends State<_RenameLabelDialog> {
  late final TextEditingController _text = TextEditingController(text: widget.initial)..addListener(() => setState(() {}));

  @override
  void dispose() {
    _text.dispose();
    super.dispose();
  }

  void _save() {
    final text = _text.text.trim();
    if (text.isNotEmpty) Navigator.pop(context, text);
  }

  @override
  Widget build(BuildContext context) {
    return ZDialogScaffold(
      key: const Key('labelRenameDialog'),
      title: context.tr('labelsRenameTitle'),
      actions: [
        ZButton(label: context.tr('cancel'), variant: ZButtonVariant.text, onPressed: () => Navigator.pop(context)),
        ZButton(
          key: const Key('labelRenameSave'),
          label: context.tr('save'),
          onPressed: _text.text.trim().isEmpty ? null : _save,
        ),
      ],
      child: ZTextField(
        key: const Key('labelRenameField'),
        controller: _text,
        label: context.tr('labelsName'),
        autofocus: true,
        onSubmitted: (_) => _save(),
      ),
    );
  }
}
