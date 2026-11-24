// Phase D: per-conversation auto-delete TTL. Messages expire on Zalo and in
// the local zalos history, so the copy names both.
import 'package:material_ui/material_ui.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../domain/models.dart';
import '../../domain/services.dart';
import '../components/basics.dart';
import '../components/overlays.dart';
import '../l10n/strings.dart';
import '../theme/tokens.dart';
import '../theme/z_icons.dart';

final autoDeleteChatsProvider = FutureProvider.autoDispose.family<AutoDeleteChat, AccountSession>((ref, session) => session.autoDeleteChats());

String autoDeleteTtlLabel(int ttl, S s) => switch (ttl) {
      86400000 => s.t('autoDelete1d'),
      604800000 => s.t('autoDelete7d'),
      1209600000 => s.t('autoDelete14d'),
      _ => s.t('autoDeleteOff'),
    };

Future<void> showAutoDeleteSheet(BuildContext context, {required AccountSession session, required Thread thread}) =>
    showZModal<void>(context, builder: (_) => AutoDeleteSheet(session: session, thread: thread));

class AutoDeleteSheet extends ConsumerStatefulWidget {
  const AutoDeleteSheet({super.key, required this.session, required this.thread});

  final AccountSession session;
  final Thread thread;

  @override
  ConsumerState<AutoDeleteSheet> createState() => _AutoDeleteSheetState();
}

class _AutoDeleteSheetState extends ConsumerState<AutoDeleteSheet> {
  bool _busy = false;

  int? _remoteTtl(AutoDeleteChat? chat) {
    for (final conversation in chat?.conversations ?? const <AutoDeleteConversation>[]) {
      if (conversation.threadId == widget.thread.id && conversation.threadType == widget.thread.type) return conversation.ttl;
    }
    return null;
  }

  Future<void> _choose(int ttl) async {
    if (_busy) return;
    setState(() => _busy = true);
    try {
      await widget.session.setAutoDelete(widget.thread.id, widget.thread.type, ttl);
      if (!mounted) return;
      ref.invalidate(autoDeleteChatsProvider(widget.session));
      zToast(context, context.tr('autoDeleteSet'));
      Navigator.of(context).pop();
    } catch (_) {
      if (!mounted) return;
      setState(() => _busy = false);
      zToast(context, context.tr('actionFailed'));
    }
  }

  @override
  Widget build(BuildContext context) {
    final z = context.z;
    final s = context.s;
    final async = ref.watch(autoDeleteChatsProvider(widget.session));
    final currentTtl = _remoteTtl(async.valueOrNull) ?? widget.thread.autoDeleteTtl;
    return ZDialogScaffold(
      key: const Key('autoDeleteSheet'),
      title: context.tr('autoDeleteTitle'),
      showClose: true,
      child: async.isLoading && !async.hasValue
          ? const Column(
              key: Key('autoDeleteLoading'),
              children: [ZSkeletonRow(avatar: 0, height: 48), ZSkeletonRow(avatar: 0, height: 48), ZSkeletonRow(avatar: 0, height: 48)],
            )
          : Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                if (async.hasError) ...[
                  ZBanner(
                    key: const Key('autoDeleteStale'),
                    tone: ZTone.warning,
                    icon: ZIcons.warning,
                    text: context.tr('autoDeleteStale'),
                    actionLabel: context.tr('retry'),
                    onAction: () => ref.invalidate(autoDeleteChatsProvider(widget.session)),
                  ),
                  const SizedBox(height: ZSpace.s8),
                ],
                Text(context.tr('autoDeleteExplain'), style: z.text.body.copyWith(color: z.textSecondary)),
                const SizedBox(height: ZSpace.s12),
                for (final ttl in autoDeleteTtls)
                  ZRow(
                    key: Key('autoDelete-$ttl'),
                    icon: ttl == 0 ? ZIcons.timerOff : ZIcons.timer,
                    title: autoDeleteTtlLabel(ttl, s),
                    subtitle: ttl == 0 ? null : context.tr('autoDeleteValue', [autoDeleteTtlLabel(ttl, s)]),
                    selected: currentTtl == ttl,
                    trailing: currentTtl == ttl ? Icon(ZIcons.check, size: 20, color: z.brandText) : null,
                    onTap: _busy ? null : () => _choose(ttl),
                  ),
              ],
            ),
    );
  }
}
