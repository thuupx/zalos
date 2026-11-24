// Phase D composer utilities: send options, bank cards and quick messages.
import 'package:material_ui/material_ui.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../domain/models.dart';
import '../../domain/services.dart';
import '../components/avatar.dart';
import '../components/basics.dart';
import '../components/fields.dart';
import '../components/overlays.dart';
import '../components/pressable.dart';
import '../l10n/strings.dart';
import '../platform/services.dart';
import '../theme/tokens.dart';
import '../theme/z_icons.dart';
import '../util/format.dart';

typedef SendOptions = ({MessageUrgency urgency, int ttl});

Future<SendOptions?> showSendOptionsSheet(
  BuildContext context, {
  required MessageUrgency urgency,
  required int ttl,
  required bool canUrgency,
  required bool canTtl,
}) =>
    showZModal<SendOptions>(
      context,
      builder: (_) => SendOptionsSheet(urgency: urgency, ttl: ttl, canUrgency: canUrgency, canTtl: canTtl),
    );

class SendOptionsSheet extends StatelessWidget {
  const SendOptionsSheet({super.key, required this.urgency, required this.ttl, required this.canUrgency, required this.canTtl});

  final MessageUrgency urgency;
  final int ttl;
  final bool canUrgency;
  final bool canTtl;

  @override
  Widget build(BuildContext context) {
    final z = context.z;
    return ZDialogScaffold(
      key: const Key('sendOptionsSheet'),
      title: context.tr('sendOptionsTitle'),
      showClose: true,
      child: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Text(context.tr('sendOptionsHint'), style: z.text.caption),
          if (canUrgency) ...[
            const SizedBox(height: ZSpace.s12),
            Semantics(header: true, child: Text(context.tr('sendOptionsUrgency'), style: z.text.labelStrong)),
            for (final value in MessageUrgency.values)
              ZRow(
                key: Key('urgency-${value.name}'),
                icon: switch (value) {
                  MessageUrgency.normal => ZIcons.flag,
                  MessageUrgency.important => ZIcons.priorityHigh,
                  MessageUrgency.urgent => ZIcons.bolt,
                },
                title: messageUrgencyLabel(value, context.s),
                selected: value == urgency,
                trailing: value == urgency ? Icon(ZIcons.check, size: 20, color: z.brandText) : null,
                onTap: () => Navigator.of(context).pop((urgency: value, ttl: ttl)),
              ),
          ],
          if (canTtl) ...[
            const SizedBox(height: ZSpace.s12),
            Semantics(header: true, child: Text(context.tr('sendOptionsTtl'), style: z.text.labelStrong)),
            for (final value in messageTtls)
              ZRow(
                key: Key('ttl-$value'),
                icon: value == 0 ? ZIcons.timerOff : ZIcons.timer,
                title: messageTtlLabel(value, context.s),
                selected: value == ttl,
                trailing: value == ttl ? Icon(ZIcons.check, size: 20, color: z.brandText) : null,
                onTap: () => Navigator.of(context).pop((urgency: urgency, ttl: value)),
              ),
          ],
        ],
      ),
    );
  }
}

Future<void> showBankCardSheet(
  BuildContext context, {
  required AccountSession session,
  required String threadId,
  required ThreadType type,
}) =>
    showZModal<void>(context, builder: (_) => BankCardSheet(session: session, threadId: threadId, type: type));

class BankCardSheet extends StatefulWidget {
  const BankCardSheet({super.key, required this.session, required this.threadId, required this.type});

  final AccountSession session;
  final String threadId;
  final ThreadType type;

  @override
  State<BankCardSheet> createState() => _BankCardSheetState();
}

class _BankCardSheetState extends State<BankCardSheet> {
  List<BankInfo> _banks = const [];
  List<BankAccount> _accounts = const [];
  bool _loading = true;
  bool _failed = false;
  bool _busy = false;

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    setState(() {
      _loading = true;
      _failed = false;
    });
    try {
      final banks = await widget.session.banks();
      // Walk every page; stop on an empty or duplicate page so a server that
      // keeps saying hasMore cannot loop forever.
      final accounts = <BankAccount>[];
      final seen = <String>{};
      var page = 0;
      var hasMore = true;
      while (hasMore) {
        final result = await widget.session.bankAccounts(page: page, limit: 20);
        final added = [
          for (final account in result.accounts)
            if (seen.add(account.id)) account,
        ];
        accounts.addAll(added);
        hasMore = result.hasMore &&
            result.accounts.isNotEmpty &&
            added.isNotEmpty &&
            (result.total <= 0 || accounts.length < result.total);
        page++;
        if (page >= 100) break;
      }
      if (!mounted) return;
      setState(() {
        _banks = banks;
        _accounts = accounts;
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

  BankInfo? _bankFor(int bin) {
    for (final bank in _banks) {
      if (bank.bin == bin) return bank;
    }
    return null;
  }

  Future<void> _send(BankAccount account) async {
    if (_busy) return;
    setState(() => _busy = true);
    final bank = _bankFor(account.bin);
    try {
      await widget.session.sendBankCard(
        widget.threadId,
        widget.type,
        BankCard(
          bin: account.bin,
          accountNumber: account.accountNumber,
          holderName: account.holderName,
          bankName: account.bankName ?? bank?.name,
          bankLogo: account.bankLogo ?? bank?.logo,
        ),
      );
      if (!mounted) return;
      zToast(context, context.tr('bankCardSent'));
      Navigator.of(context).pop();
    } catch (_) {
      if (!mounted) return;
      setState(() => _busy = false);
      zToast(context, context.tr('bankCardSendFailed'));
    }
  }

  Widget _logo(BankAccount account) {
    final z = context.z;
    final logo = account.bankLogo ?? _bankFor(account.bin)?.logo ?? '';
    if (logo.isEmpty) return Icon(ZIcons.bank, size: 24, color: z.textSecondary);
    return ClipRRect(
      borderRadius: BorderRadius.circular(ZRadius.row),
      child: MediaImage(
        session: widget.session,
        url: logo,
        width: 32,
        height: 32,
        errorBuilder: (_) => Icon(ZIcons.bank, size: 24, color: z.textSecondary),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    return ZDialogScaffold(
      key: const Key('bankCardSheet'),
      title: context.tr('bankCardTitle'),
      showClose: true,
      child: _loading
          ? Semantics(
              label: context.tr('bankCardLoading'),
              child: const Column(
                key: Key('bankCardLoading'),
                children: [ZSkeletonRow(avatar: 0, height: 56), ZSkeletonRow(avatar: 0, height: 56), ZSkeletonRow(avatar: 0, height: 56)],
              ),
            )
          : _failed
              ? ZErrorState(
                  key: const Key('bankCardFailed'),
                  title: context.tr('bankCardFailed'),
                  retryLabel: context.tr('retry'),
                  onRetry: _load,
                )
              : _accounts.isEmpty
                  ? ZEmptyState(
                      key: const Key('bankCardEmpty'),
                      icon: ZIcons.bank,
                      title: context.tr('bankCardEmpty'),
                      subtitle: context.tr('bankCardEmptyHint'),
                    )
                  : Column(
                      mainAxisSize: MainAxisSize.min,
                      crossAxisAlignment: CrossAxisAlignment.stretch,
                      children: [
                        for (final account in _accounts)
                          ZRow(
                            key: Key('bankAccount-${account.id}'),
                            leading: _logo(account),
                            title: account.accountNumber,
                            subtitle: [
                              if (account.holderName.trim().isNotEmpty) account.holderName,
                              if ((account.bankName ?? _bankFor(account.bin)?.name ?? '').isNotEmpty) account.bankName ?? _bankFor(account.bin)!.name,
                            ].join(' \u00b7 '),
                            trailing: account.isDefault ? ZChip(label: context.tr('bankCardDefault'), tone: ZTone.info) : null,
                            onTap: _busy ? null : () => _send(account),
                          ),
                      ],
                    ),
    );
  }
}

Future<QuickMessage?> showQuickMessageSheet(BuildContext context, {required AccountSession session}) =>
    showZModal<QuickMessage>(context, builder: (_) => QuickMessageSheet(session: session));

class QuickMessageSheet extends ConsumerStatefulWidget {
  const QuickMessageSheet({super.key, required this.session});

  final AccountSession session;

  @override
  ConsumerState<QuickMessageSheet> createState() => _QuickMessageSheetState();
}

class _QuickMessageSheetState extends ConsumerState<QuickMessageSheet> {
  final TextEditingController _search = TextEditingController();
  List<QuickMessage> _items = const [];
  int _version = 0;
  int _cursor = 0;
  bool _loading = true;
  bool _failed = false;
  bool _busy = false;

  @override
  void initState() {
    super.initState();
    _load();
  }

  @override
  void dispose() {
    _search.dispose();
    super.dispose();
  }

  Future<void> _load() async {
    setState(() {
      _loading = true;
      _failed = false;
    });
    try {
      final state = await widget.session.quickMessages();
      if (!mounted) return;
      setState(() {
        _items = List.of(state.items);
        _version = state.version;
        _cursor = state.cursor;
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

  List<QuickMessage> get _visible {
    final query = _search.text.trim();
    if (query.isEmpty) return _items;
    return [
      for (final item in _items)
        if (foldContains(item.keyword, query) || foldContains(item.title, query)) item,
    ];
  }

  Future<void> _add() async {
    final draft = await showZModal<QuickMessageDraft>(
      context,
      builder: (_) => QuickMessageForm(session: widget.session),
    );
    if (draft == null || !mounted) return;
    setState(() => _busy = true);
    try {
      final result = await widget.session.addQuickMessage(draft);
      if (!mounted) return;
      setState(() {
        _items = [..._items, result.item];
        _version = result.version;
        _busy = false;
      });
      zToast(context, context.tr('quickSaved'));
    } catch (_) {
      if (!mounted) return;
      setState(() => _busy = false);
      zToast(context, context.tr('actionFailed'));
    }
  }

  Future<void> _edit(QuickMessage item) async {
    final draft = await showZModal<QuickMessageDraft>(
      context,
      builder: (_) => QuickMessageForm(session: widget.session, initial: item),
    );
    if (draft == null || !mounted) return;
    setState(() => _busy = true);
    try {
      final result = await widget.session.updateQuickMessage(item.id, draft);
      if (!mounted) return;
      setState(() {
        _items = [for (final current in _items) current.id == item.id ? result.item : current];
        _version = result.version;
        _busy = false;
      });
      zToast(context, context.tr('quickSaved'));
    } catch (_) {
      if (!mounted) return;
      setState(() => _busy = false);
      zToast(context, context.tr('actionFailed'));
    }
  }

  Future<void> _delete(QuickMessage item) async {
    final ok = await zConfirm(
      context,
      title: context.tr('quickDeleteTitle', [item.title]),
      message: context.tr('quickDeleteBody'),
      confirmLabel: context.tr('delete'),
    );
    if (!ok || !mounted) return;
    setState(() => _busy = true);
    try {
      final result = await widget.session.removeQuickMessages([item.id]);
      if (!mounted) return;
      final removed = result.itemIds.toSet();
      setState(() {
        _items = [for (final current in _items) if (!removed.contains(current.id)) current];
        _version = result.version;
        _busy = false;
      });
      zToast(context, context.tr('quickDeleted'));
    } catch (_) {
      if (!mounted) return;
      setState(() => _busy = false);
      zToast(context, context.tr('actionFailed'));
    }
  }

  Widget _thumb(QuickMessage item) {
    final z = context.z;
    if (item.media.isEmpty) return Icon(ZIcons.bolt, size: 24, color: z.textSecondary);
    final media = item.media.first;
    final url = media.thumbUrl.isNotEmpty ? media.thumbUrl : media.normalUrl;
    return ClipRRect(
      borderRadius: BorderRadius.circular(ZRadius.row),
      child: MediaImage(
        session: widget.session,
        url: url,
        width: 40,
        height: 40,
        errorBuilder: (_) => Icon(ZIcons.bolt, size: 24, color: z.textSecondary),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final z = context.z;
    final visible = _visible;
    return ZDialogScaffold(
      key: const Key('quickSheet'),
      title: context.tr('quickMessagesTitle'),
      showClose: true,
      actions: [
        ZButton(
          key: const Key('quickAdd'),
          label: context.tr('quickAdd'),
          icon: ZIcons.plus,
          small: true,
          onPressed: _busy ? null : _add,
        ),
      ],
      child: Column(
        key: ValueKey('quickList-$_version-$_cursor'),
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          ZSearchField(
            key: const Key('quickSearch'),
            controller: _search,
            hint: context.tr('quickSearch'),
            clearLabel: context.tr('clear'),
            onChanged: (_) => setState(() {}),
          ),
          const SizedBox(height: ZSpace.s8),
          if (_loading)
            Semantics(
              label: context.tr('quickLoading'),
              child: const Column(
                key: Key('quickLoading'),
                children: [ZSkeletonRow(avatar: 0, height: 56), ZSkeletonRow(avatar: 0, height: 56), ZSkeletonRow(avatar: 0, height: 56)],
              ),
            )
          else if (_failed)
            ZErrorState(
              key: const Key('quickFailed'),
              title: context.tr('quickFailed'),
              retryLabel: context.tr('retry'),
              onRetry: _load,
            )
          else if (visible.isEmpty)
            ZEmptyState(
              key: const Key('quickEmpty'),
              icon: ZIcons.bolt,
              title: context.tr('quickEmpty'),
              subtitle: context.tr('quickEmptyHint'),
            )
          else
            for (final item in visible)
              ZRow(
                key: Key('quickItem-${item.id}'),
                leading: _thumb(item),
                title: item.title,
                subtitle: item.keyword,
                trailing: Row(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    ZIconButton(
                      key: Key('quickInsert-${item.id}'),
                      icon: ZIcons.download,
                      label: context.tr('quickInsert'),
                      size: 32,
                      iconSize: 18,
                      onPressed: _busy ? null : () => Navigator.of(context).pop(item),
                    ),
                    ZIconButton(
                      key: Key('quickEdit-${item.id}'),
                      icon: ZIcons.edit,
                      label: context.tr('quickEdit'),
                      size: 32,
                      iconSize: 18,
                      onPressed: _busy ? null : () => _edit(item),
                    ),
                    ZIconButton(
                      key: Key('quickDelete-${item.id}'),
                      icon: ZIcons.delete,
                      label: context.tr('delete'),
                      size: 32,
                      iconSize: 18,
                      onPressed: _busy ? null : () => _delete(item),
                    ),
                  ],
                ),
              ),
          if (!_loading && !_failed && visible.isNotEmpty) ...[
            const SizedBox(height: ZSpace.s8),
            Text(
              context.tr('quickKeywordHint'),
              style: z.text.caption.copyWith(color: z.textTertiary),
            ),
          ],
        ],
      ),
    );
  }
}

class QuickMessageForm extends ConsumerStatefulWidget {
  const QuickMessageForm({super.key, required this.session, this.initial});

  final AccountSession session;
  final QuickMessage? initial;

  @override
  ConsumerState<QuickMessageForm> createState() => _QuickMessageFormState();
}

class _QuickMessageFormState extends ConsumerState<QuickMessageForm> {
  late final TextEditingController _keyword = TextEditingController(text: widget.initial?.keyword ?? '');
  late final TextEditingController _title = TextEditingController(text: widget.initial?.title ?? '');
  OutgoingFile? _media;
  String? _error;

  @override
  void dispose() {
    _keyword.dispose();
    _title.dispose();
    super.dispose();
  }

  Future<void> _pickMedia() async {
    try {
      final files = await ref.read(platformProvider).pickImages();
      if (files.isEmpty || !mounted) return;
      final file = files.first;
      setState(() => _media = OutgoingFile(name: file.name, bytes: file.bytes, kind: kindForFileName(file.name)));
    } catch (_) {
      if (mounted) zToast(context, context.tr('pickFailed'));
    }
  }

  void _save() {
    final keyword = _keyword.text.trim();
    final title = _title.text.trim();
    if (keyword.isEmpty || title.isEmpty) {
      setState(() => _error = context.tr('quickRequired'));
      return;
    }
    Navigator.of(context).pop(QuickMessageDraft(keyword: keyword, title: title, media: _media));
  }

  @override
  Widget build(BuildContext context) {
    final z = context.z;
    final existing = widget.initial?.media.isNotEmpty == true ? widget.initial!.media.first : null;
    final media = _media;
    return ZDialogScaffold(
      key: const Key('quickForm'),
      title: context.tr(widget.initial == null ? 'quickAddTitle' : 'quickEditTitle'),
      actions: [
        ZButton(
          key: const Key('quickFormCancel'),
          label: context.tr('cancel'),
          variant: ZButtonVariant.text,
          onPressed: () => Navigator.of(context).pop(),
        ),
        ZButton(key: const Key('quickSave'), label: context.tr('save'), onPressed: _save),
      ],
      child: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          ZTextField(
            key: const Key('quickKeywordField'),
            controller: _keyword,
            label: context.tr('quickKeyword'),
            hint: context.tr('quickKeywordHint'),
            errorText: _error,
            onChanged: (_) {
              if (_error != null) setState(() => _error = null);
            },
            onSubmitted: (_) => _save(),
          ),
          const SizedBox(height: ZSpace.s12),
          ZTextField(
            key: const Key('quickTitleField'),
            controller: _title,
            label: context.tr('quickTitle'),
            minLines: 2,
            maxLines: 4,
            onChanged: (_) {
              if (_error != null) setState(() => _error = null);
            },
          ),
          const SizedBox(height: ZSpace.s12),
          Row(
            children: [
              ZButton(
                key: const Key('quickMediaPick'),
                label: context.tr('quickMediaPick'),
                icon: ZIcons.image,
                variant: ZButtonVariant.secondary,
                small: true,
                onPressed: _pickMedia,
              ),
              if (media != null) ...[
                const SizedBox(width: ZSpace.s8),
                Expanded(
                  child: Text(middleEllipsis(media.name, 28), maxLines: 1, overflow: TextOverflow.ellipsis, style: z.text.caption),
                ),
                ZIconButton(
                  key: const Key('quickMediaClear'),
                  icon: ZIcons.close,
                  label: context.tr('quickMediaClear'),
                  size: 28,
                  iconSize: 16,
                  onPressed: () => setState(() => _media = null),
                ),
              ],
            ],
          ),
          if (media != null) ...[
            const SizedBox(height: ZSpace.s8),
            ClipRRect(
              borderRadius: BorderRadius.circular(ZRadius.input),
              child: Image.memory(media.bytes, height: 96, fit: BoxFit.cover, errorBuilder: (_, __, ___) => const SizedBox.shrink()),
            ),
          ] else if (existing != null) ...[
            const SizedBox(height: ZSpace.s8),
            ClipRRect(
              borderRadius: BorderRadius.circular(ZRadius.input),
              child: MediaImage(
                session: widget.session,
                url: existing.thumbUrl.isNotEmpty ? existing.thumbUrl : existing.normalUrl,
                height: 96,
                fit: BoxFit.cover,
                errorBuilder: (_) => const SizedBox.shrink(),
              ),
            ),
          ],
        ],
      ),
    );
  }
}

/// Preview of the single link in the composer, with loading, error and
/// dismiss states.
class LinkPreviewBar extends StatelessWidget {
  const LinkPreviewBar({
    super.key,
    required this.session,
    required this.preview,
    required this.loading,
    required this.failed,
    required this.onRetry,
    required this.onDismiss,
  });

  final AccountSession session;
  final LinkPreview? preview;
  final bool loading;
  final bool failed;
  final VoidCallback onRetry;
  final VoidCallback onDismiss;

  Widget _glyph(ZalosTokens z) => Container(
        width: 48,
        height: 48,
        decoration: BoxDecoration(color: z.layerPressed, borderRadius: BorderRadius.circular(ZRadius.row)),
        child: Icon(ZIcons.link, size: 22, color: z.textTertiary),
      );

  @override
  Widget build(BuildContext context) {
    final z = context.z;
    final value = preview;
    final thumb = value?.thumbUrl;
    final host = value == null ? '' : (Uri.tryParse(value.href.isNotEmpty ? value.href : value.srcUrl)?.host ?? '');
    return Padding(
      padding: const EdgeInsets.fromLTRB(ZSpace.s12, ZSpace.s8, ZSpace.s12, 0),
      child: Container(
        constraints: const BoxConstraints(maxWidth: 420),
        decoration: BoxDecoration(
          color: z.layerSubtle,
          borderRadius: BorderRadius.circular(ZRadius.input),
          border: Border.all(color: z.divider),
        ),
        child: loading
            ? Padding(
                key: const Key('linkPreviewLoading'),
                padding: const EdgeInsets.all(ZSpace.s8),
                child: Semantics(
                  label: context.tr('linkPreviewLoading'),
                  child: const Row(
                    children: [
                      ZSkeleton(width: 40, height: 40, radius: ZRadius.row),
                      SizedBox(width: ZSpace.s8),
                      Expanded(
                        child: Column(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          mainAxisSize: MainAxisSize.min,
                          children: [ZSkeleton(height: 12), SizedBox(height: 6), ZSkeleton(width: 120, height: 10)],
                        ),
                      ),
                    ],
                  ),
                ),
              )
            : failed
                ? Padding(
                    key: const Key('linkPreviewFailed'),
                    padding: const EdgeInsets.all(ZSpace.s8),
                    child: Row(
                      children: [
                        Icon(ZIcons.linkOff, size: 18, color: z.danger),
                        const SizedBox(width: ZSpace.s8),
                        Expanded(
                          child: Text(context.tr('linkPreviewFailed'), style: z.text.caption.copyWith(color: z.danger)),
                        ),
                        ZButton(
                          key: const Key('linkPreviewRetry'),
                          label: context.tr('retry'),
                          variant: ZButtonVariant.text,
                          small: true,
                          onPressed: onRetry,
                        ),
                        ZIconButton(
                          key: const Key('linkPreviewDismiss'),
                          icon: ZIcons.close,
                          label: context.tr('linkPreviewDismiss'),
                          size: 28,
                          iconSize: 16,
                          onPressed: onDismiss,
                        ),
                      ],
                    ),
                  )
                : Row(
                    children: [
                      if (thumb != null && thumb.isNotEmpty)
                        ClipRRect(
                          borderRadius: BorderRadius.circular(ZRadius.row),
                          child: MediaImage(
                            session: session,
                            url: thumb,
                            width: 48,
                            height: 48,
                            errorBuilder: (_) => _glyph(z),
                          ),
                        )
                      else
                        _glyph(z),
                      const SizedBox(width: ZSpace.s8),
                      Expanded(
                        child: Column(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          mainAxisSize: MainAxisSize.min,
                          children: [
                            Text(value?.title ?? '', maxLines: 1, overflow: TextOverflow.ellipsis, style: z.text.labelStrong),
                            if (value != null && value.description.isNotEmpty)
                              Text(value.description, maxLines: 1, overflow: TextOverflow.ellipsis, style: z.text.caption.copyWith(color: z.textSecondary)),
                            if (host.isNotEmpty) Text(host, maxLines: 1, overflow: TextOverflow.ellipsis, style: z.text.meta.copyWith(color: z.textTertiary)),
                          ],
                        ),
                      ),
                      ZIconButton(
                        key: const Key('linkPreviewDismiss'),
                        icon: ZIcons.close,
                        label: context.tr('linkPreviewDismiss'),
                        size: 28,
                        iconSize: 16,
                        onPressed: onDismiss,
                      ),
                    ],
                  ),
      ),
    );
  }
}
