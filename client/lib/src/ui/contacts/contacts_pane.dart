import 'package:material_ui/material_ui.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../domain/models.dart';
import '../../domain/services.dart';
import '../components/avatar.dart';
import '../groups/group_management_sheets.dart';
import '../info/conversation_extras_sheets.dart';
import '../components/basics.dart';
import '../components/connection_banner.dart';
import '../components/fields.dart';
import '../components/motion.dart';
import '../components/overlays.dart';
import '../components/pressable.dart';
import '../l10n/strings.dart';
import '../state/app_state.dart';
import '../state/thread_ui.dart';
import '../theme/tokens.dart';
import '../theme/z_icons.dart';
import '../threads/threads_pane.dart';
import '../util/format.dart';
import 'destination_picker.dart';
import 'friend_discovery.dart';
import 'friend_requests.dart';

class ContactsPane extends ConsumerStatefulWidget {
  const ContactsPane({super.key, required this.link});

  final ServerLink link;

  @override
  ConsumerState<ContactsPane> createState() => _ContactsPaneState();
}

class _ContactsPaneState extends ConsumerState<ContactsPane> {
  final TextEditingController _search = TextEditingController();
  final ScrollController _friendsScroll = ScrollController();
  String _query = '';
  bool _groupsTab = false;
  bool _recommendationsExpanded = false;
  AccountSession? _session;
  Future<List<Contact>>? _contacts;
  Future<List<GroupInfo>>? _groups;
  Future<List<FriendRecommendation>>? _recommendations;
  final Map<String, FriendPresence> _presence = {};
  final Map<String, LastSeen> _lastSeen = {};
  final Set<String> _blocked = {};
  final Set<String> _requestedRecommendations = {};
  final Set<String> _requestingRecommendations = {};
  int? _friendCount;
  int? _groupCount;

  static const double _rowHeight = 64;
  static const double _headerHeight = 28;

  @override
  void dispose() {
    _search.dispose();
    _friendsScroll.dispose();
    super.dispose();
  }

  void _load(AccountSession? session) {
    if (!identical(session, _session)) {
      _blocked.clear();
      _requestedRecommendations.clear();
      _requestingRecommendations.clear();
      _recommendationsExpanded = false;
    }
    _session = session;
    _friendCount = null;
    _groupCount = null;
    _recommendations = null;
    _presence.clear();
    _lastSeen.clear();
    if (session == null) {
      _contacts = null;
      _groups = null;
      return;
    }
    final directory = ref.read(directoryProvider(session));
    _contacts = session.contacts().then((list) {
      if (!mounted || !identical(_session, session)) return list;
      directory.seed(list);
      setState(() => _friendCount = list.length);
      return list;
    });
    _groups = session.groups().then((list) {
      if (!mounted || !identical(_session, session)) return list;
      setState(() => _groupCount = list.length);
      return list;
    });
    final caps = ref.read(activeCapsProvider);
    if (caps.contains(AccountCapability.friends)) {
      _recommendations = session.friendRecommendations()..ignore();
    }
    _loadPresence(session);
  }

  /// Presence is read once per load and never polled; last seen is only
  /// asked for friends Zalo reports as offline.
  Future<void> _loadPresence(AccountSession session) async {
    if (!ref.read(activeCapsProvider).contains(AccountCapability.presence)) {
      return;
    }
    try {
      final list = await session.presence();
      if (!mounted || !identical(_session, session)) return;
      setState(() {
        _presence
          ..clear()
          ..addEntries([for (final p in list) MapEntry(p.uid, p)]);
      });
      final offline = [
        for (final p in list)
          if (!p.online) p.uid
      ].take(24);
      final seen = await Future.wait([
        for (final uid in offline)
          () async {
            try {
              return (uid: uid, seen: await session.lastSeen(uid));
            } catch (_) {
              return null;
            }
          }(),
      ]);
      if (!mounted || !identical(_session, session)) return;
      setState(() {
        _lastSeen.clear();
        for (final entry in seen) {
          if (entry != null) _lastSeen[entry.uid] = entry.seen;
        }
      });
    } catch (_) {
      // Presence is best effort; the list still works without it.
    }
  }

  Future<void> _refresh() async {
    setState(() => _load(_session));
    try {
      await Future.wait([if (_contacts != null) _contacts!, if (_groups != null) _groups!]);
    } catch (_) {}
  }

  void _open(String id, ThreadType type, String name, String avatarUrl) {
    final session = _session;
    if (session == null) return;
    openThread(
        ref,
        OpenThread(
            slot: session.slot,
            id: id,
            type: type,
            name: name,
            avatarUrl: avatarUrl));
    if (!LayoutScope.wideOf(context)) {
      ref.read(homeTabProvider.notifier).state = HomeTab.messages;
    }
  }

  void _onFriendsChanged() {
    if (mounted) {
      _refresh();
    }
  }

  Future<void> _addFriend() async {
    final session = _session;
    if (session == null) return;
    await showAddFriendSheet(context,
        session: session, onChanged: _onFriendsChanged);
  }

  Future<void> _showRequests() async {
    final session = _session;
    if (session == null) return;
    await showFriendRequests(context,
        session: session, onChanged: _onFriendsChanged);
  }

  Future<void> _editAlias(Contact contact, String label) async {
    final result = await showZModal<String>(
      context,
      builder: (_) => _AliasDialog(contact: contact, label: label),
    );
    if (result == null || !mounted) return;
    final session = _session;
    if (session == null) return;
    try {
      if (result.isEmpty) {
        await session.removeAlias(contact.uid);
        if (mounted) zToast(context, context.tr('aliasRemoved'));
      } else {
        await session.setAlias(contact.uid, result);
        if (mounted) zToast(context, context.tr('aliasSaved'));
      }
      if (mounted) await _refresh();
    } catch (_) {
      if (mounted) zToast(context, context.tr('aliasFailed'));
    }
  }

  Future<void> _shareContact(Contact contact, String label) async {
    final session = _session;
    if (session == null) return;
    final picked = await showDestinationPicker(context,
        session: session,
        title: context.tr('shareContactTo', [label]),
        multi: false);
    if (picked == null || picked.isEmpty || !mounted) return;
    final destination = picked.first;
    try {
      await session.sendCard(
        destination.id,
        destination.type,
        ContactCard(
            uid: contact.uid,
            displayName: contact.displayName,
            avatarUrl: contact.avatarUrl),
      );
      if (mounted) zToast(context, context.tr('contactShared'));
    } catch (_) {
      if (mounted) zToast(context, context.tr('contactShareFailed'));
    }
  }

  Future<void> _toggleBlock(Contact contact) async {
    final session = _session;
    if (session == null) return;
    final blocked = _blocked.contains(contact.uid);
    try {
      if (blocked) {
        await session.unblockUser(contact.uid);
      } else {
        await session.blockUser(contact.uid);
      }
      if (!mounted || !identical(_session, session)) return;
      setState(() =>
          blocked ? _blocked.remove(contact.uid) : _blocked.add(contact.uid));
      zToast(context, context.tr(blocked ? 'unblocked' : 'blocked'));
      // Zalo may drop the friendship on block, so reload the list.
      await _refresh();
    } catch (_) {
      if (mounted) zToast(context, context.tr('blockFailed'));
    }
  }

  Future<void> _unfriend(Contact contact, String label) async {
    final session = _session;
    if (session == null) return;
    final ok = await zConfirm(
      context,
      title: context.tr('unfriendTitle', [label]),
      message: context.tr('unfriendBody'),
      confirmLabel: context.tr('unfriend'),
    );
    if (!ok || !mounted) return;
    try {
      await session.removeFriend(contact.uid);
      if (!mounted) return;
      zToast(context, context.tr('unfriended'));
      await _refresh();
    } catch (_) {
      if (mounted) zToast(context, context.tr('unfriendFailed'));
    }
  }

  Future<void> _openFriendMenu(
      Contact contact, String label, Offset position) async {
    final blocked = _blocked.contains(contact.uid);
    final caps = ref.read(activeCapsProvider);
    final action = await showZMenu<FriendAction>(
      context,
      position: position,
      items: [
        ZMenuItem(
            value: FriendAction.alias,
            label: context.tr('editAlias'),
            icon: ZIcons.edit),
        if (contact.alias?.isNotEmpty == true)
          ZMenuItem(
              value: FriendAction.removeAlias,
              label: context.tr('removeAlias'),
              icon: ZIcons.labelOff),
        if (caps.contains(AccountCapability.contactCard))
          ZMenuItem(
              value: FriendAction.share,
              label: context.tr('shareContact'),
              icon: ZIcons.contactCard),
        ZMenuItem(
            value: FriendAction.closeFriend,
            label: context.tr('closeFriendToggle'),
            icon: contact.closeFriend ? ZIcons.starFill : ZIcons.star),
        ZMenuItem(
            value: FriendAction.blockFeed,
            label: context.tr('blockFeedToggle'),
            icon: ZIcons.eyeOff),
        ZMenuItem(
            value: FriendAction.viewQr,
            label: context.tr('viewQr'),
            icon: ZIcons.qrCode),
        ZMenuItem(
            value: FriendAction.block,
            label: context.tr(blocked ? 'unblock' : 'block'),
            icon: ZIcons.block),
        ZMenuItem(
            value: FriendAction.unfriend,
            label: context.tr('unfriend'),
            icon: ZIcons.personRemove,
            danger: true,
            dividerBefore: true),
      ],
    );
    if (action == null || !mounted) return;
    switch (action) {
      case FriendAction.alias:
        await _editAlias(contact, label);
      case FriendAction.removeAlias:
        final session = _session;
        if (session == null) return;
        try {
          await session.removeAlias(contact.uid);
          if (!mounted) return;
          zToast(context, context.tr('aliasRemoved'));
          await _refresh();
        } catch (_) {
          if (mounted) zToast(context, context.tr('aliasFailed'));
        }
      case FriendAction.share:
        await _shareContact(contact, label);
      case FriendAction.closeFriend:
        final session = _session;
        if (session == null) return;
        await session.setCloseFriend([contact.uid], !contact.closeFriend);
        await _refresh();
      case FriendAction.blockFeed:
        final session = _session;
        if (session == null) return;
        await session.blockViewFeed(contact.uid, true);
        if (mounted) zToast(context, context.tr('actionSaved'));
      case FriendAction.viewQr:
        final session = _session;
        if (session == null) return;
        await showUserQrSheet(context, session: session, uid: contact.uid, name: label);
      case FriendAction.block:
        await _toggleBlock(contact);
      case FriendAction.unfriend:
        await _unfriend(contact, label);
    }
  }

  Future<void> _sendRecommendation(FriendRecommendation recommendation) async {
    final session = _session;
    if (session == null ||
        _requestedRecommendations.contains(recommendation.uid) ||
        _requestingRecommendations.contains(recommendation.uid)) {
      return;
    }
    _requestingRecommendations.add(recommendation.uid);
    setState(() {});
    try {
      await session.sendFriendRequest(recommendation.uid);
      if (!mounted || !identical(_session, session)) return;
      setState(() => _requestedRecommendations.add(recommendation.uid));
      zToast(context, context.tr('friendRequestSent'));
    } catch (_) {
      if (mounted) zToast(context, context.tr('friendRequestSendFailed'));
    } finally {
      _requestingRecommendations.remove(recommendation.uid);
      if (mounted) setState(() {});
    }
  }

  String? _presenceLabel(Contact contact) {
    final presence = _presence[contact.uid];
    if (presence == null) return null;
    if (presence.online) return context.tr('presenceOnline');
    final seen = _lastSeen[contact.uid];
    if (seen == null || !seen.showOnlineStatus || seen.lastOnline <= 0) {
      return null;
    }
    return context.tr('lastSeen', [formatRelative(seen.lastOnline, context.s)]);
  }

  Widget _friendTrailing(Contact contact, String label, bool wide,
      {bool actions = true}) {
    final z = context.z;
    final presence = _presenceLabel(contact);
    final maxPresence = wide ? 150.0 : 88.0;
    return Row(
      mainAxisSize: MainAxisSize.min,
      children: [
        if (contact.closeFriend)
          Padding(
            padding: const EdgeInsets.only(right: ZSpace.s4),
            child: Semantics(
              label: context.tr('closeFriend'),
              child: Icon(ZIcons.starFill,
                  size: 16, color: z.accentText, fill: 1),
            ),
          ),
        if (presence != null)
          ConstrainedBox(
            constraints: BoxConstraints(maxWidth: maxPresence),
            child: Text(presence,
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: z.text.caption.copyWith(
                    color: _presence[contact.uid]?.online == true
                        ? z.success
                        : z.textTertiary)),
          ),
        if (actions) ...[
          const SizedBox(width: ZSpace.s4),
          Builder(
            builder: (buttonContext) => ZIconButton(
              key: Key('contactMenu-${contact.uid}'),
              icon: ZIcons.moreHoriz,
              label: context.tr('friendActions', [label]),
              onPressed: () {
                final box = buttonContext.findRenderObject()! as RenderBox;
                _openFriendMenu(contact, label,
                    box.localToGlobal(Offset(0, box.size.height)));
              },
            ),
          ),
        ],
      ],
    );
  }

  Widget _recommendationsSection(List<Contact> contacts) {
    final z = context.z;
    final future = _recommendations;
    if (future == null || _query.trim().isNotEmpty) {
      return const SizedBox.shrink();
    }
    final open = _recommendationsExpanded;
    final toggleLabel =
        context.tr(open ? 'hideSuggestions' : 'seeSuggestions');
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        ZPressable(
          key: const Key('recommendationsToggle'),
          onTap: () => setState(
              () => _recommendationsExpanded = !_recommendationsExpanded),
          radius: 0,
          toggled: open,
          semanticLabel: toggleLabel,
          child: Container(
            constraints:
                const BoxConstraints(minHeight: ZSizes.touchTarget),
            padding: const EdgeInsets.symmetric(horizontal: ZSpace.s16),
            child: Row(
              children: [
                Expanded(
                  child: Text(toggleLabel,
                      style: z.text.label.copyWith(color: z.brandText)),
                ),
                AnimatedRotation(
                  turns: open ? 0 : -0.25,
                  duration: ZMotion.of(context, ZMotion.fast),
                  curve: ZMotion.standard,
                  child: Icon(ZIcons.chevronDown,
                      size: 20, color: z.textTertiary),
                ),
              ],
            ),
          ),
        ),
        ZReveal(
          child: open
              ? FutureBuilder<List<FriendRecommendation>>(
                  future: future,
                  builder: (context, snap) {
                    if (snap.hasError) {
                      return Padding(
                        key: const Key('recommendationsError'),
                        padding: const EdgeInsets.fromLTRB(
                            ZSpace.s16, ZSpace.s8, ZSpace.s8, ZSpace.s8),
                        child: Row(
                          children: [
                            Expanded(
                                child: Text(
                                    context.tr('recommendationsFailed'),
                                    style: z.text.caption.copyWith(
                                        color: z.textSecondary))),
                            ZButton(
                              key: const Key('recommendationsRetry'),
                              label: context.tr('retry'),
                              variant: ZButtonVariant.text,
                              small: true,
                              onPressed: () {
                                final session = _session;
                                if (session == null) return;
                                setState(() => _recommendations =
                                    session.friendRecommendations());
                              },
                            ),
                          ],
                        ),
                      );
                    }
                    if (!snap.hasData) {
                      return const Padding(
                        key: Key('recommendationsLoading'),
                        padding: EdgeInsets.symmetric(
                            horizontal: ZSpace.s16, vertical: ZSpace.s8),
                        child: Row(
                          children: [
                            ZSkeleton(width: 40, height: 40, circle: true),
                            SizedBox(width: ZSpace.s12),
                            Expanded(child: ZSkeleton(height: 16)),
                            SizedBox(width: ZSpace.s8),
                            ZSkeleton(width: 88, height: 32),
                          ],
                        ),
                      );
                    }
                    final items = snap.data!;
                    if (items.isEmpty) return const SizedBox.shrink();
                    return Container(
                      key: const Key('recommendations'),
                      padding: const EdgeInsets.only(
                          top: ZSpace.s8, bottom: ZSpace.s4),
                      decoration: BoxDecoration(
                          border:
                              Border(bottom: BorderSide(color: z.divider))),
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.stretch,
                        children: [
                          Padding(
                            padding: const EdgeInsets.fromLTRB(
                                ZSpace.s16, 0, ZSpace.s16, ZSpace.s4),
                            child: Semantics(
                                header: true,
                                child: Text(
                                    context.tr('recommendations').toUpperCase(),
                                    style: z.text.overline)),
                          ),
                          for (final item in items.take(4))
                            _recommendationRow(item, contacts),
                        ],
                      ),
                    );
                  },
                )
              : null,
        ),
      ],
    );
  }

  Widget _recommendationRow(FriendRecommendation item, List<Contact> contacts) {
    final z = context.z;
    final requested = _requestedRecommendations.contains(item.uid);
    Contact? known;
    for (final contact in contacts) {
      if (contact.uid == item.uid) {
        known = contact;
        break;
      }
    }
    final detail = item.message?.trim().isNotEmpty == true
        ? item.message!.trim()
        : (item.phoneNumber ?? '');
    return SizedBox(
      key: Key('recommendation-${item.uid}'),
      height: 60,
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: ZSpace.s16),
        child: Row(
          children: [
            ZAvatar(
                session: _session,
                id: item.uid,
                name: item.displayName,
                url: item.avatarUrl,
                size: 40),
            const SizedBox(width: ZSpace.s12),
            Expanded(
              child: Column(
                mainAxisAlignment: MainAxisAlignment.center,
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(item.displayName,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: z.text.rowTitle),
                  if (detail.isNotEmpty)
                    Text(detail,
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: z.text.caption),
                ],
              ),
            ),
            if (known?.closeFriend == true)
              Padding(
                padding: const EdgeInsets.only(left: ZSpace.s4),
                child: Semantics(
                    label: context.tr('closeFriend'),
                    child: Icon(ZIcons.starFill,
                        size: 16, color: z.accentText, fill: 1)),
              ),
            const SizedBox(width: ZSpace.s8),
            if (known != null)
              ZChip(
                  key: Key('recommendationFriend-${item.uid}'),
                  label: context.tr('friends'),
                  tone: ZTone.success,
                  icon: ZIcons.personCheck)
            else if (requested)
              ZChip(
                  key: Key('recommendationSent-${item.uid}'),
                  label: context.tr('friendRequestPending'),
                  tone: ZTone.warning,
                  icon: ZIcons.schedule)
            else
              ZButton(
                key: Key('recommendFriend-${item.uid}'),
                label: context.tr('sendRequest'),
                variant: ZButtonVariant.secondary,
                small: true,
                loading: _requestingRecommendations.contains(item.uid),
                onPressed: () => _sendRecommendation(item),
              ),
          ],
        ),
      ),
    );
  }

  Widget _async<T>(Future<List<T>>? future, Widget Function(List<T> items) builder) {
    return FutureBuilder<List<T>>(
      future: future,
      builder: (context, snap) {
        if (snap.hasError) {
          return ZErrorState(key: const Key('contactsError'), title: context.tr('loadFailed'), retryLabel: context.tr('retry'), onRetry: _refresh);
        }
        if (snap.connectionState != ConnectionState.done || !snap.hasData) {
          return ZSkeletonList(key: const Key('contactsLoading'), avatar: 40, rowHeight: _rowHeight, label: context.tr('loading'));
        }
        return builder(snap.data!);
      },
    );
  }

  Widget _friends(List<Contact> all) {
    final z = context.z;
    final session = _session!;
    final wide = LayoutScope.wideOf(context);
    final hasFriends =
        ref.watch(activeCapsProvider).contains(AccountCapability.friends);
    String label(Contact x) =>
        x.alias != null && x.alias!.isNotEmpty ? x.alias! : x.displayName;
    final items = [
      for (final x in all)
        if (_query.trim().isEmpty || foldContains(label(x), _query) || foldContains(x.displayName, _query)) x,
    ]..sort((a, b) {
        final c = foldVi(label(a)).compareTo(foldVi(label(b)));
        return c != 0 ? c : label(a).compareTo(label(b));
      });
    if (items.isEmpty) {
      return ListView(
        padding: EdgeInsets.zero,
        children: [
          _recommendationsSection(all),
          SizedBox(
            height: 420,
            child: ZEmptyState(
              key: const Key('friendsEmpty'),
              icon: _query.trim().isEmpty
                  ? ZIcons.block
                  : ZIcons.searchOff,
              title:
                  context.tr(_query.trim().isEmpty ? 'noFriends' : 'noResults'),
              subtitle:
                  _query.trim().isEmpty ? context.tr('noFriendsHint') : null,
            ),
          ),
        ],
      );
    }
    final sections = <(String, List<Contact>)>[];
    for (final x in items) {
      final letter = sectionLetter(label(x));
      if (sections.isEmpty || sections.last.$1 != letter) {
        sections.add((letter, []));
      }
      sections.last.$2.add(x);
    }
    final offsets = <String, double>{};
    var offset = 0.0;
    for (final (letter, list) in sections) {
      offsets[letter] = offset;
      offset += _headerHeight + list.length * _rowHeight;
    }
    final list = CustomScrollView(
      key: const Key('friendsList'),
      controller: _friendsScroll,
      slivers: [
        for (final (letter, contacts) in sections)
          SliverMainAxisGroup(
            slivers: [
              SliverPersistentHeader(pinned: true, delegate: _LetterHeader(letter, z, context.tr('sectionLabel', [letter]))),
              SliverFixedExtentList(
                itemExtent: _rowHeight,
                delegate: SliverChildBuilderDelegate(
                  (context, i) {
                    final x = contacts[i];
                    final name = label(x);
                    return ZPressable(
                      key: Key('contact-${x.uid}'),
                      onTap: () => _open(x.uid, ThreadType.user, name, x.avatarUrl),
                      radius: 0,
                      semanticLabel: name == x.displayName ? name : '$name, ${x.displayName}',
                      child: Padding(
                        padding: EdgeInsets.only(left: ZSpace.s16, right: wide ? ZSpace.s16 : ZSpace.s32),
                        child: Row(
                          children: [
                            ZAvatar(
                              session: session,
                              id: x.uid,
                              name: x.displayName,
                              url: x.avatarUrl,
                              size: 40,
                              status: _presence[x.uid]?.online == true
                                  ? AvatarStatus.online
                                  : AvatarStatus.none,
                            ),
                            const SizedBox(width: ZSpace.s12),
                            Expanded(
                              child: Column(
                                mainAxisAlignment: MainAxisAlignment.center,
                                crossAxisAlignment: CrossAxisAlignment.start,
                                children: [
                                  ZHighlightText(text: name, query: _query, style: z.text.rowTitle),
                                  if (name != x.displayName) Text(x.displayName, maxLines: 1, overflow: TextOverflow.ellipsis, style: z.text.rowSub),
                                ],
                              ),
                            ),
                            _friendTrailing(x, name, wide, actions: hasFriends),
                          ],
                        ),
                      ),
                    );
                  },
                  childCount: contacts.length,
                ),
              ),
            ],
          ),
      ],
    );
    final Widget body = wide
        ? list
        : Stack(
            children: [
              RefreshIndicator(
                  onRefresh: _refresh,
                  color: z.brandText,
                  backgroundColor: z.layer,
                  child: list),
              Positioned(
                top: ZSpace.s4,
                bottom: ZSpace.s4,
                right: 0,
                child: _LetterIndex(
                  letters: [for (final (letter, _) in sections) letter],
                  onLetter: (letter) {
                    final target = offsets[letter];
                    if (target == null || !_friendsScroll.hasClients) return;
                    _friendsScroll.jumpTo(target.clamp(
                        0.0, _friendsScroll.position.maxScrollExtent));
                  },
                ),
              ),
            ],
          );
    return Column(
        children: [_recommendationsSection(all), Expanded(child: body)]);
  }

  Widget _groupList(List<GroupInfo> all) {
    final z = context.z;
    final session = _session!;
    final wide = LayoutScope.wideOf(context);
    final caps = ref.read(activeCapsProvider);
    final canManage = caps.contains(AccountCapability.groupManage);
    final directory = ref.watch(directoryProvider(session));
    final items = [
      for (final g in all)
        if (_query.trim().isEmpty || foldContains(g.name, _query)) g,
    ]..sort((a, b) => foldVi(a.name).compareTo(foldVi(b.name)));
    final actionBar = canManage
        ? Padding(
            padding: const EdgeInsets.symmetric(horizontal: ZSpace.s12, vertical: ZSpace.s8),
            child: Wrap(
              spacing: ZSpace.s8,
              runSpacing: ZSpace.s4,
              children: [
                ZButton(
                  key: const Key('createGroupButton'),
                  label: context.tr('createGroup'),
                  small: true,
                  onPressed: () async {
                    final gid = await showCreateGroupSheet(context, session: session);
                    if (gid != null) await _refresh();
                  },
                ),
                ZButton(
                  key: const Key('joinGroupLinkButton'),
                  label: context.tr('joinGroupLink'),
                  small: true,
                  variant: ZButtonVariant.secondary,
                  onPressed: () async {
                    await showJoinGroupLinkSheet(context, session: session);
                    await _refresh();
                  },
                ),
                ZButton(
                  key: const Key('groupInvitesButton'),
                  label: context.tr('groupInvites'),
                  small: true,
                  variant: ZButtonVariant.text,
                  onPressed: () async {
                    await showGroupInviteBoxSheet(context, session: session);
                    await _refresh();
                  },
                ),
              ],
            ),
          )
        : const SizedBox.shrink();
    if (items.isEmpty) {
      return Column(
        children: [
          actionBar,
          Expanded(
            child: ZEmptyState(
              key: const Key('groupsEmpty'),
              icon: _query.trim().isEmpty ? ZIcons.groups : ZIcons.searchOff,
              title: context.tr(_query.trim().isEmpty ? 'noGroups' : 'noResults'),
            ),
          ),
        ],
      );
    }
    final list = ListView.builder(
      key: const Key('groupsList'),
      padding: EdgeInsets.zero,
      itemCount: items.length,
      itemExtent: _rowHeight,
      itemBuilder: (context, i) {
        final g = items[i];
        final ids = g.memberIds.take(4).toList();
        if (g.avatarUrl.isEmpty) directory.need(ids);
        return ZPressable(
          key: Key('group-${g.id}'),
          onTap: () => _open(g.id, ThreadType.group, g.name, g.avatarUrl),
          radius: 0,
          semanticLabel: '${g.name}, ${context.tr('members', [g.memberIds.length])}',
          child: Padding(
            padding: const EdgeInsets.symmetric(horizontal: ZSpace.s16),
            child: Row(
              children: [
                ZAvatar(
                  session: session,
                  id: g.id,
                  name: g.name,
                  url: g.avatarUrl,
                  size: 40,
                  group: true,
                  members: [for (final id in ids) AvatarMember(id, directory.nameOf(id, '?'), directory.avatarOf(id))],
                ),
                const SizedBox(width: ZSpace.s12),
                Expanded(
                  child: Column(
                    mainAxisAlignment: MainAxisAlignment.center,
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      ZHighlightText(text: g.name, query: _query, style: z.text.rowTitle),
                      Text(context.tr('members', [g.memberIds.length]), maxLines: 1, overflow: TextOverflow.ellipsis, style: z.text.rowSub),
                    ],
                  ),
                ),
              ],
            ),
          ),
        );
      },
    );
    return Column(
      children: [
        actionBar,
        Expanded(
          child: wide ? list : RefreshIndicator(onRefresh: _refresh, color: z.brandText, backgroundColor: z.layer, child: list),
        ),
      ],
    );
  }

  @override
  Widget build(BuildContext context) {
    final z = context.z;
    final wide = LayoutScope.wideOf(context);
    final session = ref.watch(activeSessionProvider);
    if (!identical(session, _session)) _load(session);
    if (session != null) {
      ref.watchNotifier(ref.watch(directoryProvider(session)));
    }
    final search = ZSearchField(
      key: const Key('contactSearch'),
      controller: _search,
      hint: context.tr('searchContactsHint'),
      clearLabel: context.tr('clear'),
      onHeader: !wide,
      onChanged: (v) => setState(() => _query = v),
    );
    final refresh = ZIconButton(
        key: const Key('contactsRefresh'),
        icon: ZIcons.refresh,
        label: context.tr('refresh'),
        onPressed: session == null ? null : _refresh);
    final caps = ref.watch(activeCapsProvider);
    final hasGroups = caps.contains(AccountCapability.groups);
    final hasFriends = caps.contains(AccountCapability.friends);
    final addFriend = ZIconButton(
      key: const Key('addFriendButton'),
      icon: ZIcons.personAdd,
      label: context.tr('addFriend'),
      color: wide ? null : z.textOnBrand,
      hoverColor: wide ? null : z.headerField,
      onPressed: session == null || !hasFriends ? null : _addFriend,
    );
    final requests = ZIconButton(
      key: const Key('friendRequestsButton'),
      icon: ZIcons.groupAdd,
      label: context.tr('friendRequestsTitle'),
      color: wide ? null : z.textOnBrand,
      hoverColor: wide ? null : z.headerField,
      onPressed: session == null || !hasFriends ? null : _showRequests,
    );
    if (!hasGroups && _groupsTab) _groupsTab = false;
    String counted(String label, int? count) => count == null ? label : '$label ($count)';
    return Column(
      children: [
        if (wide)
          SizedBox(
            height: ZSizes.wideSearchRow,
            child: Padding(
              padding:
                  const EdgeInsets.only(left: ZSpace.s16, right: ZSpace.s8),
              child: Row(children: [
                Expanded(child: search),
                const SizedBox(width: ZSpace.s4),
                addFriend,
                requests,
                refresh
              ]),
            ),
          )
        else
          ZPhoneHeader(
            child: Row(
              children: [
                const SizedBox(width: ZSpace.s8),
                Expanded(child: search),
                addFriend,
                requests,
                const SizedBox(width: ZSpace.s4),
              ],
            ),
          ),
        ConnectionBanner(session: session),
        Padding(
          padding: const EdgeInsets.fromLTRB(ZSpace.s16, ZSpace.s8, ZSpace.s16, ZSpace.s8),
          child: ZSegmented<bool>(
            key: const Key('contactsSegments'),
            segments: [(false, counted(context.tr('friends'), _friendCount)), if (hasGroups) (true, counted(context.tr('groups'), _groupCount))],
            selected: _groupsTab,
            onChanged: (v) => setState(() => _groupsTab = v),
          ),
        ),
        Container(height: 1, color: z.divider),
        Expanded(
          child: session == null
              ? NoAccountsState(link: widget.link)
              : _groupsTab
                  ? _async<GroupInfo>(_groups, _groupList)
                  : _async<Contact>(_contacts, _friends),
        ),
      ],
    );
  }
}

class _LetterHeader extends SliverPersistentHeaderDelegate {
  _LetterHeader(this.letter, this.z, this.label);

  final String letter;
  final ZalosTokens z;
  final String label;

  @override
  double get minExtent => 28;

  @override
  double get maxExtent => 28;

  @override
  Widget build(BuildContext context, double shrinkOffset, bool overlapsContent) {
    return Semantics(
      header: true,
      label: label,
      child: Container(
        color: z.layerSubtle,
        alignment: Alignment.centerLeft,
        padding: const EdgeInsets.symmetric(horizontal: ZSpace.s16),
        child: ExcludeSemantics(child: Text(letter, style: z.text.overline)),
      ),
    );
  }

  @override
  bool shouldRebuild(_LetterHeader oldDelegate) => oldDelegate.letter != letter || oldDelegate.z != z;
}

/// Fast scroll letter index on touch layouts.
class _LetterIndex extends StatelessWidget {
  const _LetterIndex({required this.letters, required this.onLetter});

  final List<String> letters;
  final ValueChanged<String> onLetter;

  @override
  Widget build(BuildContext context) {
    final z = context.z;
    if (letters.length < 2) return const SizedBox.shrink();
    return LayoutBuilder(
      builder: (context, constraints) {
        void pick(double dy) {
          final i = (dy / constraints.maxHeight * letters.length).floor().clamp(0, letters.length - 1);
          onLetter(letters[i]);
        }

        return Semantics(
          label: context.tr('letterIndex'),
          container: true,
          child: GestureDetector(
            key: const Key('letterIndex'),
            behavior: HitTestBehavior.opaque,
            onTapDown: (d) => pick(d.localPosition.dy),
            onVerticalDragUpdate: (d) => pick(d.localPosition.dy),
            child: SizedBox(
              width: 24,
              child: ExcludeSemantics(
                child: Column(
                  mainAxisAlignment: MainAxisAlignment.spaceEvenly,
                  children: [
                    for (final l in letters)
                      Flexible(child: FittedBox(fit: BoxFit.scaleDown, child: Text(l, textScaler: TextScaler.noScaling, style: z.text.captionStrong.copyWith(color: z.brandText)))),
                  ],
                ),
              ),
            ),
          ),
        );
      },
    );
  }
}

enum FriendAction { alias, removeAlias, share, closeFriend, blockFeed, viewQr, block, unfriend }

class _AliasDialog extends StatefulWidget {
  const _AliasDialog({required this.contact, required this.label});

  final Contact contact;
  final String label;

  @override
  State<_AliasDialog> createState() => _AliasDialogState();
}

class _AliasDialogState extends State<_AliasDialog> {
  late final TextEditingController _controller = TextEditingController(text: widget.contact.alias ?? '');

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return ZDismissOnEscape(
      child: ZDialogScaffold(
        key: const Key('aliasDialog'),
        title: context.tr('aliasTitle', [widget.label]),
        showClose: true,
        actions: [
          if (widget.contact.alias?.isNotEmpty == true)
            ZButton(
              key: const Key('aliasRemove'),
              label: context.tr('removeAlias'),
              variant: ZButtonVariant.text,
              onPressed: () => Navigator.of(context).pop(''),
            ),
          ZButton(
            key: const Key('aliasSave'),
            label: context.tr('save'),
            onPressed: () => Navigator.of(context).pop(_controller.text.trim()),
          ),
        ],
        child: ZTextField(
          key: const Key('aliasField'),
          controller: _controller,
          label: context.tr('aliasHint'),
          hint: widget.contact.displayName,
          autofocus: true,
          maxLength: 64,
        ),
      ),
    );
  }
}
