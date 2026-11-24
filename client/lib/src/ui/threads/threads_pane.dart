import 'dart:async';

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
import '../info/auto_delete_sheet.dart';
import '../info/labels_sheet.dart';
import '../l10n/strings.dart';
import '../me/login_qr_dialog.dart';
import '../me/oa_dialog.dart';
import '../platform/services.dart';
import '../qr/zalo_qr_scanner.dart';
import '../shell/shell.dart';
import '../state/app_state.dart';
import '../state/thread_ui.dart';
import '../theme/tokens.dart';
import '../theme/z_icons.dart';
import '../util/format.dart';
import 'hidden_gate.dart';
import 'thread_tile.dart';

enum ThreadFilter { all, unread, archived }

final archivedChatsProvider = FutureProvider.family<ArchivedChatList, AccountSession>((ref, session) => session.archivedChats());

class ThreadsPane extends ConsumerStatefulWidget {
  const ThreadsPane({super.key, required this.link});

  final ServerLink link;

  @override
  ConsumerState<ThreadsPane> createState() => _ThreadsPaneState();
}

class _ThreadsPaneState extends ConsumerState<ThreadsPane> {
  final TextEditingController _search = TextEditingController();
  final FocusNode _searchFocus = FocusNode(debugLabel: 'threadSearch');
  String _query = '';
  ThreadFilter _filter = ThreadFilter.all;

  @override
  void dispose() {
    _search.dispose();
    _searchFocus.dispose();
    super.dispose();
  }

  Future<void> _newChat(AccountSession session) async {
    final picked = await showDestinationPicker(context, session: session, title: context.tr('newChat'), multi: false);
    if (picked == null || picked.isEmpty || !mounted) return;
    final d = picked.first;
    openThread(ref, OpenThread(slot: session.slot, id: d.id, type: d.type, name: d.name, avatarUrl: d.avatarUrl));
  }

  @override
  Widget build(BuildContext context) {
    final z = context.z;
    final wide = LayoutScope.wideOf(context);
    final session = ref.watch(activeSessionProvider);
    final account = ref.watch(activeAccountProvider);
    final admin = ref.watch(isAdminProvider);
    final caps = ref.watch(activeCapsProvider);
    final manifest = ref.watch(manifestProvider);
    ref.listen<int>(searchFocusRequestProvider, (_, __) => _searchFocus.requestFocus());

    final search = ZSearchField(
      key: const Key('threadSearch'),
      controller: _search,
      focusNode: _searchFocus,
      hint: context.tr('search'),
      clearLabel: context.tr('clear'),
      onHeader: !wide,
      onChanged: (v) => setState(() => _query = v),
    );
    final newChat = ZIconButton(
      key: const Key('newChat'),
      icon: ZIcons.plus,
      label: context.tr('newChat'),
      color: wide ? null : z.textOnBrand,
      hoverColor: wide ? null : z.headerField,
      iconSize: wide ? 22 : 24,
      onPressed: session == null ? null : () => _newChat(session),
    );
    final canScanQr = !wide && ref.watch(platformProvider).cameraScanSupported;
    final scanQr = canScanQr
        ? ZIconButton(
            key: const Key('headerScanQr'),
            icon: ZIcons.qrScanner,
            label: context.tr('scanZaloQr'),
            color: z.textOnBrand,
            hoverColor: z.headerField,
            iconSize: 22,
            onPressed:
                session == null ? null : () => openZaloQrScanner(context, session),
          )
        : null;

    final Widget header;
    if (wide) {
      header = SizedBox(
        height: ZSizes.wideSearchRow,
        child: Padding(
          padding: const EdgeInsets.only(left: ZSpace.s16, right: ZSpace.s8),
          child: Row(children: [Expanded(child: search), const SizedBox(width: ZSpace.s4), newChat]),
        ),
      );
    } else {
      final others = (manifest?.accounts ?? const <AccountSummary>[])
          .where((a) => a.slot != account?.slot)
          .fold<int>(0, (n, a) => n + a.unread);
      header = ZPhoneHeader(
        child: Row(
          children: [
            const SizedBox(width: ZSpace.s8),
            ZPressable(
              key: const Key('accountAvatar'),
              circle: true,
              hoverColor: z.headerField,
              tooltip: context.tr('switchAccount'),
              semanticLabel: context.tr('switchAccount'),
              minSize: ZSizes.touchTarget,
              onTap: () => showAccountSheet(context, widget.link),
              child: Stack(
                clipBehavior: Clip.none,
                children: [
                  Container(
                    padding: const EdgeInsets.all(1.5),
                    decoration: const BoxDecoration(color: ZalosTokens.white, shape: BoxShape.circle),
                    child: ZAvatar(
                      session: session,
                      id: account == null ? 'zalos' : (account.uid.isEmpty ? account.slot : account.uid),
                      name: account?.displayName ?? 'zalos',
                      url: account?.avatarUrl ?? '',
                      size: 32,
                    ),
                  ),
                  if (others > 0) Positioned(top: -4, right: -6, child: ZBadge(count: others, outline: z.headerStart)),
                ],
              ),
            ),
            const SizedBox(width: ZSpace.s4),
            Expanded(child: search),
            if (scanQr != null) scanQr,
            newChat,
            const SizedBox(width: ZSpace.s4),
          ],
        ),
      );
    }

    final searching = _query.trim().isNotEmpty;
    return Column(
      children: [
        header,
        if (!searching)
          _FilterRow(
            filter: _filter,
            onChanged: (f) => setState(() => _filter = f),
            showHidden: session != null && caps.contains(AccountCapability.hidden),
            onHidden: session == null ? null : () => showHiddenGate(context, session),
          ),
        ConnectionBanner(session: session),
        if (account != null && account.status == AccountStatus.needsLogin)
          ZBanner(
            key: const Key('needsLoginBanner'),
            tone: ZTone.danger,
            icon: ZIcons.error,
            text: context.tr(admin ? 'needsLoginAdmin' : 'needsLoginMember'),
            actionLabel: admin ? context.tr(account.kind == AccountKind.oa ? 'oaUpdateTokens' : 'relogin') : null,
            onAction: admin ? () => account.kind == AccountKind.oa ? showOaTokens(context, widget.link, account.slot) : showLoginQrDialog(context, widget.link) : null,
          )
        else if (account != null && account.status == AccountStatus.displaced)
          ZBanner(key: const Key('displacedBanner'), tone: ZTone.warning, icon: ZIcons.warning, text: context.tr('displacedBanner')),
        Expanded(
          child: session == null
              ? NoAccountsState(link: widget.link)
              : searching
                  ? _SearchResults(key: ValueKey('search-${session.slot}'), session: session, query: _query)
                  : ThreadList(key: ValueKey('threads-${session.slot}'), session: session, filter: _filter),
        ),
      ],
    );
  }
}

class _FilterRow extends StatelessWidget {
  const _FilterRow({required this.filter, required this.onChanged, this.showHidden = false, this.onHidden});

  final ThreadFilter filter;
  final ValueChanged<ThreadFilter> onChanged;
  final bool showHidden;
  final VoidCallback? onHidden;

  @override
  Widget build(BuildContext context) {
    final z = context.z;
    final wide = LayoutScope.wideOf(context);
    final items = [(ThreadFilter.all, context.tr('filterAll')), (ThreadFilter.unread, context.tr('filterUnread'))];
    final archived = ZIconButton(
      key: const Key('filter-archived'),
      icon: ZIcons.archive,
      label: context.tr('archived'),
      size: wide ? 32 : 40,
      iconSize: 20,
      selected: filter == ThreadFilter.archived,
      onPressed: () => onChanged(ThreadFilter.archived),
    );
    final hidden = showHidden
        ? ZIconButton(
            key: const Key('hiddenEntry'),
            icon: ZIcons.eyeOff,
            label: context.tr('hiddenEntry'),
            size: wide ? 32 : 40,
            iconSize: 20,
            onPressed: onHidden,
          )
        : null;
    if (!wide) {
      return Container(
        padding: const EdgeInsets.fromLTRB(ZSpace.s12, ZSpace.s8, ZSpace.s8, ZSpace.s8),
        decoration: BoxDecoration(
          color: z.layer,
          border: Border(
            bottom: BorderSide(
              color: z.divider.withValues(alpha: z.dark ? 0.16 : 0.08),
              width: 0.5,
            ),
          ),
        ),
        child: Row(
          children: [
            for (final (value, label) in items) ...[
              ZChip(key: Key('filter-${value.name}'), label: label, selected: filter == value, onTap: () => onChanged(value)),
              const SizedBox(width: ZSpace.s8),
            ],
            const Spacer(),
            archived,
            if (hidden != null) hidden,
          ],
        ),
      );
    }
    return SizedBox(
      height: 32,
      child: Stack(
        children: [
          Positioned(left: 0, right: 0, bottom: 0, child: Container(height: 1, color: z.divider)),
          Padding(
            padding: const EdgeInsets.symmetric(horizontal: ZSpace.s16),
            child: Row(
              children: [
                for (final (value, label) in items) ...[
                  ZPressable(
                    key: Key('filter-${value.name}'),
                    onTap: () => onChanged(value),
                    radius: 0,
                    hoverColor: ZalosTokens.clear,
                    pressedColor: ZalosTokens.clear,
                    selected: filter == value,
                    child: Container(
                      height: 32,
                      alignment: Alignment.center,
                      decoration: BoxDecoration(border: Border(bottom: BorderSide(color: filter == value ? z.brandText : ZalosTokens.clear, width: 2))),
                      child: Text(label, style: z.text.label.copyWith(color: filter == value ? z.brandText : z.textTertiary)),
                    ),
                  ),
                  const SizedBox(width: ZSpace.s20),
                ],
                const Spacer(),
                archived,
                if (hidden != null) ...[const SizedBox(width: ZSpace.s4), hidden],
              ],
            ),
          ),
        ],
      ),
    );
  }
}

class NoAccountsState extends ConsumerWidget {
  const NoAccountsState({super.key, required this.link});

  final ServerLink link;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final admin = ref.watch(isAdminProvider);
    return ZEmptyState(
      key: const Key('noAccounts'),
      icon: ZIcons.personAdd,
      title: context.tr('noAccounts'),
      subtitle: context.tr(admin ? 'noAccountsAdminHint' : 'noAccountsMemberHint'),
      action: admin ? ZButton(label: context.tr('addZaloAccount'), onPressed: () => showAddAccount(context, link)) : null,
    );
  }
}

/// The conversation list of one account. Rows are cached by thread identity
/// so one changed thread rebuilds one row.
class ThreadList extends ConsumerStatefulWidget {
  const ThreadList({super.key, required this.session, required this.filter});

  final AccountSession session;
  final ThreadFilter filter;

  @override
  ConsumerState<ThreadList> createState() => _ThreadListState();
}

class _ThreadListState extends ConsumerState<ThreadList> {
  static const double _rowExtent = 72;

  /// Rows that slide when the order changes; farther moves are capped so a
  /// thread jumping from far down does not streak across the list.
  static const int _maxShiftRows = 3;

  final Map<String, (Thread, bool, Widget)> _cache = {};
  List<String> _order = const [];
  Map<String, int> _positions = const {};
  Map<String, _RowMove> _moves = const {};
  int _moveGeneration = 0;

  @override
  void didUpdateWidget(ThreadList old) {
    super.didUpdateWidget(old);
    if (old.filter != widget.filter || !identical(old.session, widget.session)) _order = const [];
  }

  /// Compares the new order with the last one: a thread that moved up (new
  /// activity) or is new fades in at its place, threads it passed slide
  /// down from where they were.
  void _trackOrder(List<Thread> threads) {
    final order = [for (final t in threads) '${t.type.name}/${t.id}'];
    if (listEquals(order, _order)) return;
    final previous = _positions;
    final animate = _order.isNotEmpty && !ZMotion.reduced(context);
    _order = order;
    _positions = {for (var i = 0; i < order.length; i++) order[i]: i};
    if (!animate) return;
    final moves = <String, _RowMove>{};
    for (var i = 0; i < order.length; i++) {
      final before = previous[order[i]];
      if (before == null || before > i) {
        moves[order[i]] = const _RowMove(rows: 0, fadeIn: true);
      } else if (before < i) {
        moves[order[i]] = _RowMove(rows: -(i - before).clamp(1, _maxShiftRows), fadeIn: false);
      }
    }
    if (moves.isEmpty) return;
    _moves = moves;
    _moveGeneration++;
    // Rows built later, e.g. by scrolling, must not replay the move.
    WidgetsBinding.instance.addPostFrameCallback((_) => _moves = const {});
  }

  void _reload() => widget.session.reloadThreads().catchError((Object _) {});

  Widget _row(Thread t, bool selected) {
    final key = '${t.type.name}/${t.id}';
    final hit = _cache[key];
    if (hit != null && identical(hit.$1, t) && hit.$2 == selected) return hit.$3;
    final widget = ThreadTile(key: ValueKey('thread-${t.id}'), session: this.widget.session, thread: t, selected: selected);
    _cache[key] = (t, selected, widget);
    return widget;
  }

  @override
  Widget build(BuildContext context) {
    final session = widget.session;
    final all = ref.watchL(session.threads);
    final load = ref.watchL(session.threadsLoad);
    final selected = ref.watch(visibleThreadProvider);
    final archivedState = widget.filter == ThreadFilter.archived ? ref.watch(archivedChatsProvider(session)) : null;
    final archivedList = archivedState?.valueOrNull;
    if (all.isEmpty && load == LoadState.loading) {
      return ZSkeletonList(key: const Key('threadsLoading'), label: context.tr('loading'));
    }
    if (all.isEmpty && load == LoadState.failed) {
      return ZErrorState(key: const Key('threadsError'), title: context.tr('threadsLoadFailed'), retryLabel: context.tr('retry'), onRetry: _reload);
    }
    if (archivedState != null && archivedState.isLoading && archivedList == null && !all.any((t) => t.archived && !t.hidden)) {
      return ZSkeletonList(key: const Key('archivedLoading'), label: context.tr('loading'));
    }
    final visible = [
      for (final t in all)
        if (!t.hidden && (widget.filter == ThreadFilter.archived ? t.archived : !t.archived)) t,
    ];
    final threads = widget.filter == ThreadFilter.unread ? [for (final t in visible) if (t.unread > 0) t] : visible;
    final Widget body;
    if (threads.isEmpty) {
      body = switch (widget.filter) {
        ThreadFilter.unread => ZEmptyState(key: const Key('threadsEmptyUnread'), icon: ZIcons.markRead, title: context.tr('noUnread')),
        ThreadFilter.archived => ZEmptyState(
            key: const Key('threadsEmptyArchived'),
            icon: ZIcons.archive,
            title: context.tr('archivedEmpty'),
            subtitle: context.tr('archivedEmptyHint'),
          ),
        ThreadFilter.all => ZEmptyState(key: const Key('threadsEmpty'), icon: ZIcons.chat, title: context.tr('noThreads'), subtitle: context.tr('noThreadsHint')),
      };
    } else {
      if (_cache.length > all.length + 256) _cache.clear();
      body = _list(threads, selected);
    }
    return Column(
      children: [
        ZReveal(
          child: load == LoadState.failed
              ? ZBanner(
                  key: const Key('threadsStaleBanner'),
                  tone: ZTone.warning,
                  icon: ZIcons.warning,
                  text: context.tr('threadsStale'),
                  actionLabel: context.tr('retry'),
                  onAction: _reload,
                )
              : null,
        ),
        ZReveal(
          child: archivedState?.hasError == true
              ? ZBanner(
                  key: const Key('archivedStaleBanner'),
                  tone: ZTone.warning,
                  icon: ZIcons.warning,
                  text: context.tr('archivedStale'),
                  actionLabel: context.tr('retry'),
                  onAction: () => ref.invalidate(archivedChatsProvider(session)),
                )
              : null,
        ),
        Expanded(child: body),
      ],
    );
  }

  Widget _list(List<Thread> threads, OpenThread? selected) {
    _trackOrder(threads);
    return Shortcuts(
      shortcuts: const {
        SingleActivator(LogicalKeyboardKey.arrowDown): NextFocusIntent(),
        SingleActivator(LogicalKeyboardKey.arrowUp): PreviousFocusIntent(),
      },
      child: FocusTraversalGroup(
        policy: ZReadingOrderPolicy(),
        child: ListView.builder(
          key: const Key('threadList'),
          padding: EdgeInsets.zero,
          itemCount: threads.length,
          itemExtent: _rowExtent,
          findChildIndexCallback: (key) => key is ValueKey<String> ? _positions[key.value] : null,
          itemBuilder: (context, i) {
            final t = threads[i];
            final id = '${t.type.name}/${t.id}';
            return _RowShift(
              key: ValueKey(id),
              move: _moves[id],
              generation: _moveGeneration,
              extent: _rowExtent,
              child: _row(t, selected != null && selected.id == t.id && selected.type == t.type),
            );
          },
        ),
      ),
    );
  }
}

class _SearchResults extends ConsumerStatefulWidget {
  const _SearchResults({super.key, required this.session, required this.query});

  final AccountSession session;
  final String query;

  @override
  ConsumerState<_SearchResults> createState() => _SearchResultsState();
}

class _SearchResultsState extends ConsumerState<_SearchResults> {
  @override
  void initState() {
    super.initState();
    ref.read(directoryProvider(widget.session)).ensureContacts();
  }

  @override
  Widget build(BuildContext context) {
    final z = context.z;
    final session = widget.session;
    final query = widget.query;
    final directory = ref.watch(directoryProvider(session));
    ref.watchNotifier(directory);
    final threads = [for (final t in ref.watchL(session.threads)) if (!t.hidden && foldContains(t.name, query)) t];
    return FutureBuilder<List<Contact>>(
      future: _contacts ??= session.contacts(),
      builder: (context, snap) {
        final contacts = [
          for (final c in snap.data ?? const <Contact>[])
            if (foldContains(c.alias?.isNotEmpty == true ? c.alias! : c.displayName, query) || foldContains(c.displayName, query)) c,
        ];
        if (threads.isEmpty && contacts.isEmpty) {
          if (!snap.hasData && !snap.hasError) return ZSkeletonList(count: 4, label: context.tr('loading'));
          return ZEmptyState(key: const Key('searchEmpty'), icon: ZIcons.searchOff, title: context.tr('noResults'));
        }
        Widget section(String title) => Padding(
              padding: const EdgeInsets.fromLTRB(ZSpace.s16, ZSpace.s12, ZSpace.s16, ZSpace.s4),
              child: Semantics(header: true, child: Text(title.toUpperCase(), style: z.text.overline)),
            );
        return ListView(
          key: const Key('searchResults'),
          padding: EdgeInsets.zero,
          children: [
            if (threads.isNotEmpty) section(context.tr('searchThreads')),
            for (final t in threads)
              _ResultRow(
                key: ValueKey('result-thread-${t.id}'),
                session: session,
                id: t.id,
                name: t.name,
                avatarUrl: t.avatarUrl,
                group: t.type == ThreadType.group,
                query: query,
                onTap: () => openThread(ref, openThreadOf(session.slot, t)),
              ),
            if (contacts.isNotEmpty) section(context.tr('searchContacts')),
            for (final c in contacts)
              _ResultRow(
                key: ValueKey('result-contact-${c.uid}'),
                session: session,
                id: c.uid,
                name: c.alias?.isNotEmpty == true ? c.alias! : c.displayName,
                avatarUrl: c.avatarUrl,
                group: false,
                query: query,
                onTap: () => openThread(
                  ref,
                  OpenThread(slot: session.slot, id: c.uid, type: ThreadType.user, name: c.alias?.isNotEmpty == true ? c.alias! : c.displayName, avatarUrl: c.avatarUrl),
                ),
              ),
          ],
        );
      },
    );
  }

  Future<List<Contact>>? _contacts;
}

class _ResultRow extends StatelessWidget {
  const _ResultRow({super.key, required this.session, required this.id, required this.name, required this.avatarUrl, required this.group, required this.query, required this.onTap});

  final AccountSession session;
  final String id;
  final String name;
  final String avatarUrl;
  final bool group;
  final String query;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final z = context.z;
    return ZPressable(
      onTap: onTap,
      radius: 0,
      semanticLabel: name,
      child: SizedBox(
        height: 64,
        child: Padding(
          padding: const EdgeInsets.symmetric(horizontal: ZSpace.s16),
          child: Row(
            children: [
              ZAvatar(session: session, id: id, name: name, url: avatarUrl, size: 40, group: group),
              const SizedBox(width: ZSpace.s12),
              Expanded(child: ZHighlightText(text: name, query: query, style: z.text.rowTitle)),
            ],
          ),
        ),
      ),
    );
  }
}

/// Runs a thread level action and reports failures with a toast.
Future<void> runThreadAction(BuildContext context, Future<void> Function() action) async {
  final failed = context.tr('actionFailed');
  try {
    await action();
  } catch (_) {
    if (context.mounted) zToast(context, failed);
  }
}

enum ThreadMenuAction { pin, mute, read, archive, hide, labels, autoDelete, delete }

Future<void> showThreadMenu(BuildContext context, WidgetRef ref, AccountSession session, Thread t, Offset position) async {
  final caps = ref.read(activeCapsProvider);
  final items = [
      if (caps.contains(AccountCapability.pin)) ZMenuItem(value: ThreadMenuAction.pin, label: context.tr(t.pinned ? 'unpin' : 'pin'), icon: ZIcons.pin),
      if (caps.contains(AccountCapability.mute)) ZMenuItem(value: ThreadMenuAction.mute, label: context.tr(t.muted ? 'unmute' : 'mute'), icon: t.muted ? ZIcons.bell : ZIcons.bellOff),
      if (caps.contains(AccountCapability.markUnread)) ZMenuItem(value: ThreadMenuAction.read, label: context.tr(t.unread > 0 ? 'markRead' : 'markUnread'), icon: t.unread > 0 ? ZIcons.markRead : ZIcons.markUnread),
      if (caps.contains(AccountCapability.archive)) ZMenuItem(value: ThreadMenuAction.archive, label: context.tr(t.archived ? 'unarchiveThread' : 'archiveThread'), icon: t.archived ? ZIcons.unarchive : ZIcons.archive),
      if (caps.contains(AccountCapability.hidden)) ZMenuItem(value: ThreadMenuAction.hide, label: context.tr(t.hidden ? 'unhideThread' : 'hideThread'), icon: t.hidden ? ZIcons.eye : ZIcons.eyeOff),
      if (caps.contains(AccountCapability.labels)) ZMenuItem(value: ThreadMenuAction.labels, label: context.tr('labelsManage'), icon: ZIcons.label),
      if (caps.contains(AccountCapability.autoDelete)) ZMenuItem(value: ThreadMenuAction.autoDelete, label: context.tr('autoDelete'), icon: ZIcons.timer),
      if (caps.contains(AccountCapability.deleteThread)) ZMenuItem(value: ThreadMenuAction.delete, label: context.tr('deleteThread'), icon: ZIcons.delete, danger: true, dividerBefore: true),
  ];
  if (items.isEmpty) return;
  final action = await showZMenu<ThreadMenuAction>(context, position: position, items: items);
  if (action == null || !context.mounted) return;
  await applyThreadAction(context, ref, session, t, action);
}

Future<void> applyThreadAction(BuildContext context, WidgetRef ref, AccountSession session, Thread t, ThreadMenuAction action) async {
  switch (action) {
    case ThreadMenuAction.pin:
      await runThreadAction(context, () => session.setPinned(t.id, t.type, !t.pinned));
    case ThreadMenuAction.mute:
      await runThreadAction(context, () => session.setMuted(t.id, t.type, !t.muted));
    case ThreadMenuAction.read:
      await runThreadAction(context, () => t.unread > 0 ? session.markSeen(t.id, t.type) : session.markUnread(t.id, t.type));
    case ThreadMenuAction.archive:
      await runThreadAction(context, () => session.setArchived(t.id, t.type, !t.archived));
      ref.invalidate(archivedChatsProvider(session));
    case ThreadMenuAction.hide:
      if (!t.hidden) {
        final ok = await zConfirm(
          context,
          title: context.tr('hideThreadTitle', [t.name]),
          message: context.tr('hideThreadBody'),
          confirmLabel: context.tr('hideThread'),
        );
        if (!ok || !context.mounted) return;
      }
      final open = ref.read(openThreadProvider);
      await runThreadAction(context, () async {
        await session.setHidden(t.id, t.type, !t.hidden);
        if (!t.hidden && open != null && open.id == t.id && open.type == t.type) closeThread(ref);
      });
    case ThreadMenuAction.labels:
      await showLabelsSheet(context, session: session, threadId: t.id);
    case ThreadMenuAction.autoDelete:
      await showAutoDeleteSheet(context, session: session, thread: t);
    case ThreadMenuAction.delete:
      final ok = await zConfirm(
        context,
        title: context.tr('deleteThreadTitle', [t.name]),
        message: context.tr('deleteThreadBody'),
        confirmLabel: context.tr('delete'),
      );
      if (!ok || !context.mounted) return;
      final open = ref.read(openThreadProvider);
      await runThreadAction(context, () async {
        await session.deleteThread(t.id, t.type);
        if (open != null && open.id == t.id && open.type == t.type) closeThread(ref);
      });
  }
}

@immutable
class _RowMove {
  const _RowMove({required this.rows, required this.fadeIn});

  /// Rows the tile starts away from its slot; negative is above.
  final int rows;
  final bool fadeIn;
}

/// Plays a [_RowMove] of a thread row once per order change: transform and
/// opacity only, so the fixed extent list never relayouts.
class _RowShift extends StatefulWidget {
  const _RowShift({super.key, required this.move, required this.generation, required this.extent, required this.child});

  final _RowMove? move;
  final int generation;
  final double extent;
  final Widget child;

  @override
  State<_RowShift> createState() => _RowShiftState();
}

class _RowShiftState extends State<_RowShift> with SingleTickerProviderStateMixin {
  /// Rise of a row that fades in at its new place.
  static const double _fadeRise = 12;

  AnimationController? _controller;
  Animation<double> _progress = kAlwaysCompleteAnimation;
  Animation<double> _opacity = kAlwaysCompleteAnimation;
  double _from = 0;

  @override
  void initState() {
    super.initState();
    _play();
  }

  @override
  void didUpdateWidget(_RowShift old) {
    super.didUpdateWidget(old);
    if (old.generation != widget.generation) _play();
  }

  void _play() {
    final move = widget.move;
    if (move == null) return;
    final controller = _controller ??= AnimationController(vsync: this, duration: ZMotion.medium);
    _progress = CurvedAnimation(parent: controller, curve: ZMotion.enterCurve);
    _opacity = move.fadeIn ? _progress : kAlwaysCompleteAnimation;
    _from = move.fadeIn ? _fadeRise : move.rows * widget.extent;
    controller.forward(from: 0);
  }

  @override
  void dispose() {
    _controller?.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => FadeTransition(
        opacity: _opacity,
        child: AnimatedBuilder(
          animation: _progress,
          builder: (context, child) => Transform.translate(offset: Offset(0, _from * (1 - _progress.value)), child: child),
          child: widget.child,
        ),
      );
}
