import 'package:material_ui/material_ui.dart';

import '../../domain/models.dart';
import '../../domain/services.dart';
import '../components/avatar.dart';
import '../components/basics.dart';
import '../components/motion.dart';
import '../components/overlays.dart';
import '../components/pressable.dart';
import '../l10n/strings.dart';
import '../theme/tokens.dart';
import '../theme/z_icons.dart';
import '../util/format.dart';

enum _InboxTab { received, sent }

/// Received and sent friend requests with accept, reject and cancel actions.
Future<void> showFriendRequests(BuildContext context,
    {required AccountSession session, required VoidCallback onChanged}) {
  return showZModal<void>(
    context,
    builder: (_) =>
        _FriendRequestsSheet(session: session, onChanged: onChanged),
  );
}

class _FriendRequestsSheet extends StatefulWidget {
  const _FriendRequestsSheet({required this.session, required this.onChanged});

  final AccountSession session;
  final VoidCallback onChanged;

  @override
  State<_FriendRequestsSheet> createState() => _FriendRequestsSheetState();
}

class _FriendRequestsSheetState extends State<_FriendRequestsSheet> {
  late Future<FriendRequests> _future = widget.session.friendRequests();
  _InboxTab _tab = _InboxTab.received;
  final Set<String> _busy = {};

  AccountSession get _session => widget.session;

  void _reload() => setState(() => _future = _session.friendRequests());

  Future<void> _run(
      String uid, Future<void> Function() action, String successKey) async {
    if (_busy.contains(uid)) return;
    setState(() => _busy.add(uid));
    try {
      await action();
      if (!mounted) return;
      zToast(context, context.tr(successKey));
      widget.onChanged();
      _reload();
    } catch (_) {
      if (mounted) zToast(context, context.tr('friendRequestFailed'));
    } finally {
      if (mounted) setState(() => _busy.remove(uid));
    }
  }

  Widget _row(FriendRequest request) {
    final z = context.z;
    final busy = _busy.contains(request.uid);
    final received = _tab == _InboxTab.received;
    final message = request.message?.trim() ?? '';
    return SizedBox(
      key: Key('friendRequest-${request.uid}'),
      height: 88,
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: ZSpace.s16),
        child: Row(
          children: [
            ZAvatar(
                session: _session,
                id: request.uid,
                name: request.displayName,
                url: request.avatarUrl,
                size: 44),
            const SizedBox(width: ZSpace.s12),
            Expanded(
              child: Column(
                mainAxisAlignment: MainAxisAlignment.center,
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(request.displayName,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: z.text.rowTitleUnread),
                  if (message.isNotEmpty)
                    Text(message,
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: z.text.rowSub),
                  if (request.ts != null)
                    Text(formatRelative(request.ts, context.s),
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: z.text.caption),
                ],
              ),
            ),
            const SizedBox(width: ZSpace.s8),
            if (received) ...[
              ZIconButton(
                key: Key('friendRequestAccept-${request.uid}'),
                icon: ZIcons.check,
                label: context.tr('acceptRequest'),
                color: z.success,
                onPressed: busy
                    ? null
                    : () => _run(
                        request.uid,
                        () => _session.acceptFriendRequest(request.uid),
                        'friendRequestAccepted'),
              ),
              ZIconButton(
                key: Key('friendRequestReject-${request.uid}'),
                icon: ZIcons.close,
                label: context.tr('reject'),
                onPressed: busy
                    ? null
                    : () => _run(
                        request.uid,
                        () => _session.rejectFriendRequest(request.uid),
                        'friendRequestRejected'),
              ),
            ] else
              ZIconButton(
                key: Key('friendRequestCancel-${request.uid}'),
                icon: ZIcons.close,
                label: context.tr('cancelRequest'),
                onPressed: busy
                    ? null
                    : () => _run(
                        request.uid,
                        () => _session.cancelFriendRequest(request.uid),
                        'friendRequestCancelled'),
              ),
          ],
        ),
      ),
    );
  }

  Widget _list(FriendRequests requests) {
    final received = _tab == _InboxTab.received;
    final items = received ? requests.received : requests.sent;
    if (items.isEmpty) {
      return ZEmptyState(
        key: Key('friendRequestsEmpty-${_tab.name}'),
        icon: received
            ? ZIcons.markUnread
            : ZIcons.upload,
        title: context.tr(received ? 'noReceivedRequests' : 'noSentRequests'),
        subtitle: context
            .tr(received ? 'noReceivedRequestsHint' : 'noSentRequestsHint'),
      );
    }
    return ListView.builder(
      key: const Key('friendRequestsList'),
      padding: EdgeInsets.zero,
      itemCount: items.length,
      itemBuilder: (context, i) => _row(items[i]),
    );
  }

  @override
  Widget build(BuildContext context) {
    return ZDismissOnEscape(
      child: ZDialogScaffold(
        key: const Key('friendRequestsSheet'),
        title: context.tr('friendRequestsTitle'),
        showClose: true,
        padBody: false,
        child: SizedBox(
          height: 420,
          child: Column(
            children: [
              Padding(
                padding: const EdgeInsets.fromLTRB(
                    ZSpace.s16, 0, ZSpace.s16, ZSpace.s8),
                child: ZSegmented<_InboxTab>(
                  key: const Key('friendRequestsTabs'),
                  segments: [
                    (_InboxTab.received, context.tr('receivedRequests')),
                    (_InboxTab.sent, context.tr('sentRequests'))
                  ],
                  selected: _tab,
                  onChanged: (tab) => setState(() => _tab = tab),
                ),
              ),
              Expanded(
                child: FutureBuilder<FriendRequests>(
                  future: _future,
                  builder: (context, snap) {
                    if (snap.hasError) {
                      return ZErrorState(
                        key: const Key('friendRequestsError'),
                        title: context.tr('friendRequestsFailed'),
                        retryLabel: context.tr('retry'),
                        onRetry: _reload,
                      );
                    }
                    if (!snap.hasData) {
                      return ZSkeletonList(
                          key: const Key('friendRequestsLoading'),
                          count: 5,
                          avatar: 44,
                          rowHeight: 88,
                          label: context.tr('loading'));
                    }
                    return ZPopIn(
                        key: ValueKey('inbox-${_tab.name}'),
                        child: _list(snap.data!));
                  },
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}
