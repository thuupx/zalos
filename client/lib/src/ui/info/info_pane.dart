import 'package:material_ui/material_ui.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../domain/models.dart';
import '../../domain/services.dart';
import '../chat/board_sheets.dart';
import '../chat/media_viewer.dart';
import '../chat/message_content.dart';
import '../chat/report_dialog.dart';
import '../components/avatar.dart';
import '../groups/group_management_sheets.dart';
import 'conversation_extras_sheets.dart';
import '../components/basics.dart';
import '../components/overlays.dart';
import '../components/pressable.dart';
import '../l10n/strings.dart';
import '../platform/services.dart';
import '../state/app_state.dart';
import '../state/thread_ui.dart';
import '../theme/tokens.dart';
import '../theme/z_icons.dart';
import '../threads/thread_tile.dart';
import '../threads/threads_pane.dart';
import '../util/haptics.dart';
import 'auto_delete_sheet.dart';
import 'labels_sheet.dart';

class InfoPane extends ConsumerStatefulWidget {
  const InfoPane(
      {super.key,
      required this.session,
      required this.thread,
      required this.onClose});

  final AccountSession session;
  final OpenThread thread;
  final VoidCallback onClose;

  @override
  ConsumerState<InfoPane> createState() => _InfoPaneState();
}

class _InfoPaneState extends ConsumerState<InfoPane> {
  final Set<String> _collapsed = {};
  bool _avatarOpening = false;

  AccountSession get session => widget.session;
  OpenThread get thread => widget.thread;

  Thread? _current(List<Thread> threads) {
    for (final t in threads) {
      if (t.id == thread.id && t.type == thread.type) return t;
    }
    return null;
  }

  List<ViewerItem> _media(List<Message> msgs, Directory directory) => [
        for (final m in msgs.reversed)
          if (!m.recalled &&
              (m.kind == MessageKind.image ||
                  m.kind == MessageKind.gif ||
                  m.kind == MessageKind.video))
            for (final a in m.attachments)
              ViewerItem(
                  attachment: a,
                  senderName: m.isSelf
                      ? context.tr('you')
                      : directory.nameOf(m.senderId, m.senderName),
                  ts: m.ts),
      ];

  Widget _section(String id, String title, List<Widget> children,
      {int? count}) {
    final z = context.z;
    final open = !_collapsed.contains(id);
    final label = count == null ? title : '$title ($count)';
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Container(height: ZSpace.s8, color: z.layerSubtle),
        ZPressable(
          key: Key('infoSection-$id'),
          onTap: () {
            ZHaptics.selection();
            setState(() => open ? _collapsed.add(id) : _collapsed.remove(id));
          },
          radius: 0,
          toggled: open,
          child: Container(
            constraints: const BoxConstraints(minHeight: 44),
            padding: const EdgeInsets.symmetric(horizontal: ZSpace.s16),
            child: Row(
              children: [
                Expanded(
                    child: Semantics(
                        header: true,
                        child: Text(label.toUpperCase(),
                            semanticsLabel: label, style: z.text.overline))),
                AnimatedRotation(
                    turns: open ? 0 : -0.25,
                    duration: ZMotion.of(context, ZMotion.fast),
                    curve: ZMotion.standard,
                    child: Icon(ZIcons.chevronDown,
                        size: 20, color: z.textTertiary)),
              ],
            ),
          ),
        ),
        if (open) ...children,
        if (open) const SizedBox(height: ZSpace.s8),
      ],
    );
  }

  Widget _emptyLine(String text) => Padding(
        padding: const EdgeInsets.symmetric(horizontal: ZSpace.s16, vertical: ZSpace.s8),
        child: Text(text, style: context.z.text.rowSub),
      );

  /// Full size avatar of [uid] when the account can fetch one, else null.
  Future<String>? _fullAvatar(String uid) => ref.read(activeCapsProvider).contains(AccountCapability.fullAvatar) ? session.fullAvatar(uid) : null;

  /// Shows a profile picture in the media viewer: the full size one when
  /// [full] yields a url, else the list avatar [url] it was opened from.
  Future<void> _openAvatar({required String name, required String url, Future<String>? full}) async {
    if (_avatarOpening) return;
    _avatarOpening = true;
    try {
      var target = url;
      if (full != null) {
        try {
          final fullUrl = await full;
          if (fullUrl.isNotEmpty) target = fullUrl;
        } catch (_) {
          // The list avatar is still worth showing.
        }
      }
      if (target.isEmpty || !mounted) return;
      final item = ViewerItem(
        attachment: Attachment(kind: MessageKind.image, url: target, thumbUrl: target == url || url.isEmpty ? null : url),
        senderName: name,
      );
      await showMediaViewer(context, session, [item], 0);
    } finally {
      _avatarOpening = false;
    }
  }

  Widget _avatarButton({required Key key, required String name, required String url, required Widget avatar, Future<String>? Function()? full}) {
    if (url.isEmpty && full == null) return avatar;
    return ZPressable(
      key: key,
      circle: true,
      semanticLabel: context.tr('viewAvatar'),
      tooltip: context.tr('viewAvatar'),
      onTap: () => _openAvatar(name: name, url: url, full: full?.call()),
      child: avatar,
    );
  }

  void _showProfile(Contact c, {required bool owner}) {
    // Fetched while the sheet opens so a tap on the picture shows it at once.
    final full = _fullAvatar(c.uid);
    full?.ignore();
    showZModal<void>(
      context,
      builder: (context) {
        final z = context.z;
        final name = c.alias?.isNotEmpty == true ? c.alias! : c.displayName;
        return ZDialogScaffold(
          key: const Key('profileSheet'),
          title: context.tr('profile'),
          showClose: true,
          actions: [
            ZButton(
              key: const Key('profileMessage'),
              label: context.tr('sendMessage'),
              icon: ZIcons.chat,
              onPressed: () {
                Navigator.of(context).pop();
                ref.read(infoPaneOpenProvider.notifier).state = false;
                openThread(ref, OpenThread(slot: session.slot, id: c.uid, type: ThreadType.user, name: name, avatarUrl: c.avatarUrl));
              },
            ),
          ],
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              _avatarButton(
                key: const Key('profileAvatar'),
                name: name,
                url: c.avatarUrl,
                full: full == null ? null : () => full,
                avatar: ZAvatar(session: session, id: c.uid, name: name, url: c.avatarUrl, size: 96),
              ),
              const SizedBox(height: ZSpace.s12),
              Text(name, textAlign: TextAlign.center, style: z.text.title),
              if (name != c.displayName) Text(c.displayName, textAlign: TextAlign.center, style: z.text.rowSub),
              if (owner) Padding(padding: const EdgeInsets.only(top: ZSpace.s8), child: ZChip(label: context.tr('groupOwner'), tone: ZTone.warning, icon: ZIcons.key)),
            ],
          ),
        );
      },
    );
  }

  void _showGallery(List<ViewerItem> items) {
    showZModal<void>(
      context,
      maxWidth: 560,
      builder: (context) => ZDialogScaffold(
        key: const Key('gallery'),
        title: context.tr('mediaTitle'),
        showClose: true,
        child: _MediaGridView(session: session, items: items, limit: items.length, cell: 96),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final z = context.z;
    final wide = LayoutScope.wideOf(context);
    final caps = ref.watch(activeCapsProvider);
    final directory = ref.watch(directoryProvider(session));
    ref.watchNotifier(directory);
    final current = _current(ref.watchL(session.threads));
    final labels = caps.contains(AccountCapability.labels)
        ? ref.watch(labelsProvider(session))
        : null;
    final assigned = labelsForThread(labels?.valueOrNull, thread.id);
    final labelSummary = labels == null
        ? context.tr('labelsNone')
        : labels.isLoading && !labels.hasValue
            ? context.tr('loading')
            : labels.hasError
                ? context.tr('labelsLoadFailed')
                : assigned.isEmpty
                    ? context.tr('labelsNone')
                    : [for (final label in assigned) label.text].join(', ');
    final currentTtl = current?.autoDeleteTtl ?? 0;
    final msgs = ref.watchL(session.messages(thread.id, thread.type));
    final name =
        current?.name.trim().isNotEmpty == true ? current!.name : thread.name;
    final group = thread.isGroup;
    final info =
        group ? ref.watch(groupInfoProvider((session, thread.id))) : null;
    final groupData = info?.valueOrNull;
    final activeAccount = ref.watch(activeAccountProvider);
    final embeddedMembers = <String, Contact>{
      for (final c in groupData?.members ?? const <Contact>[])
        if (c.uid.isNotEmpty) c.uid: c,
    };
    final msgSenders = <String, String>{};
    for (final m in msgs.reversed) {
      if (m.senderId.isNotEmpty && !msgSenders.containsKey(m.senderId)) {
        msgSenders[m.senderId] = m.senderName;
      }
    }
    final memberIds = <String>[];
    final seenIds = <String>{};
    void addMemberId(String? uid) {
      if (uid != null && uid.isNotEmpty && seenIds.add(uid)) {
        memberIds.add(uid);
      }
    }

    for (final id in groupData?.memberIds ?? const <String>[]) {
      addMemberId(id);
    }
    for (final c in groupData?.members ?? const <Contact>[]) {
      addMemberId(c.uid);
    }
    final rawCount = groupData?.memberCount ?? memberIds.length;
    // When Zalo reports totalMember > 0 but omits the roster (e.g. private
    // groups with invite links disabled), synthesize visible participants from
    // owner/admins, self, and loaded message senders so the section is never
    // mysteriously blank.
    if (memberIds.isEmpty && rawCount > 0) {
      addMemberId(groupData?.ownerId);
      for (final id in groupData?.adminIds ?? const <String>[]) {
        addMemberId(id);
      }
      addMemberId(activeAccount?.uid);
      for (final id in msgSenders.keys) {
        addMemberId(id);
      }
    }
    final memberCount = rawCount > memberIds.length ? rawCount : memberIds.length;
    if (memberIds.isNotEmpty) directory.need(memberIds);

    Contact resolveMember(String id) {
      final dir = directory[id];
      if (dir != null && dir.displayName.isNotEmpty) return dir;
      final emb = embeddedMembers[id];
      if (emb != null && emb.displayName.isNotEmpty) return emb;
      if (activeAccount != null && activeAccount.uid == id) {
        return Contact(
          uid: id,
          displayName: activeAccount.displayName,
          avatarUrl: activeAccount.avatarUrl,
        );
      }
      final fallbackName = msgSenders[id] ?? '';
      return Contact(
        uid: id,
        displayName: fallbackName,
        avatarUrl: dir?.avatarUrl ?? emb?.avatarUrl ?? '',
      );
    }
    final media = _media(msgs, directory);
    final files = [
      for (final m in msgs.reversed)
        if (!m.recalled && m.kind == MessageKind.file)
          for (final a in m.attachments) (m, a),
    ];
    final links = [
      for (final m in msgs.reversed)
        if (!m.recalled && m.kind == MessageKind.link)
          for (final a in m.attachments) (m, a),
    ];
    final members = [
      for (final id in memberIds.take(4))
        () {
          final c = resolveMember(id);
          return AvatarMember(id, c.displayName.isEmpty ? '?' : c.displayName, c.avatarUrl);
        }(),
    ];

    Widget quick(Key key, IconData icon, String label, VoidCallback onTap, {bool active = false}) => Expanded(
          child: ZPressable(
            key: key,
            onTap: onTap,
            radius: ZRadius.input,
            toggled: active,
            semanticLabel: label,
            child: Padding(
              padding: const EdgeInsets.symmetric(vertical: ZSpace.s8, horizontal: ZSpace.s4),
              child: Column(
                children: [
                  Container(
                    width: 36,
                    height: 36,
                    decoration: BoxDecoration(color: active ? z.brandSubtle : z.layerSubtle, shape: BoxShape.circle),
                    child: Icon(icon, size: 20, color: active ? z.brandText : z.textSecondary, fill: active ? 1 : 0),
                  ),
                  const SizedBox(height: ZSpace.s4),
                  Text(label, maxLines: 2, textAlign: TextAlign.center, overflow: TextOverflow.ellipsis, style: z.text.captionStrong.copyWith(color: z.textSecondary, fontWeight: FontWeight.w500)),
                ],
              ),
            ),
          ),
        );

    final header = Row(
      children: [
        if (!wide) ZIconButton(key: const Key('infoBack'), icon: ZIcons.back, label: context.tr('back'), color: z.textOnBrand, hoverColor: z.headerField, iconSize: 24, onPressed: widget.onClose) else const SizedBox(width: ZSpace.s16),
        Expanded(
          child: Semantics(
            header: true,
            child: Text(context.tr('conversationInfo'), maxLines: 1, overflow: TextOverflow.ellipsis, style: z.text.title.copyWith(color: wide ? z.textPrimary : z.textOnBrand)),
          ),
        ),
        if (wide) ZIconButton(key: const Key('infoClose'), icon: ZIcons.close, label: context.tr('close'), onPressed: widget.onClose),
        const SizedBox(width: ZSpace.s8),
      ],
    );

    return Material(
      key: const Key('infoPane'),
      color: z.layer,
      child: Column(
        children: [
          if (wide)
            Container(height: ZSizes.wideChatHeader, decoration: BoxDecoration(border: Border(bottom: BorderSide(color: z.divider))), child: header)
          else
            ZPhoneHeader(child: header),
          Expanded(
            child: ListView(
              padding: EdgeInsets.zero,
              children: [
                const SizedBox(height: ZSpace.s20),
                Center(
                  child: _avatarButton(
                    key: const Key('infoAvatar'),
                    name: name,
                    url: current?.avatarUrl ?? thread.avatarUrl,
                    full: group || !caps.contains(AccountCapability.fullAvatar) ? null : () => _fullAvatar(thread.id),
                    avatar: ZAvatar(session: session, id: thread.id, name: name, url: current?.avatarUrl ?? thread.avatarUrl, size: 96, group: group, members: members),
                  ),
                ),
                const SizedBox(height: ZSpace.s12),
                MergeSemantics(
                  child: Column(
                    children: [
                      Padding(
                        padding:
                            const EdgeInsets.symmetric(horizontal: ZSpace.s16),
                        child: Text(name,
                            key: const Key('infoName'),
                            textAlign: TextAlign.center,
                            maxLines: 2,
                            overflow: TextOverflow.ellipsis,
                            style: z.text.title),
                      ),
                      if (group && memberCount > 0)
                        Padding(
                          padding: const EdgeInsets.only(top: 2),
                          child: Text(context.tr('members', [memberCount]),
                              textAlign: TextAlign.center,
                              style: z.text.rowSub),
                        ),
                    ],
                  ),
                ),
                if (assigned.isNotEmpty)
                  Padding(
                    padding: const EdgeInsets.fromLTRB(
                        ZSpace.s16, ZSpace.s8, ZSpace.s16, 0),
                    child: Wrap(
                      alignment: WrapAlignment.center,
                      spacing: ZSpace.s4,
                      runSpacing: ZSpace.s4,
                      children: [
                        for (final label in assigned)
                          ZChip(
                              key: Key('infoLabel-${label.id}'),
                              label: label.text),
                      ],
                    ),
                  ),
                Padding(
                  padding: const EdgeInsets.fromLTRB(
                      ZSpace.s12, ZSpace.s12, ZSpace.s12, ZSpace.s8),
                  child: Row(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      if (caps.contains(AccountCapability.mute))
                        quick(
                          const Key('infoMute'),
                          current?.muted == true
                              ? ZIcons.bellOff
                              : ZIcons.bell,
                          context
                              .tr(current?.muted == true ? 'unmute' : 'mute'),
                          () => runThreadAction(
                              context,
                              () => session.setMuted(thread.id, thread.type,
                                  !(current?.muted ?? false))),
                          active: current?.muted == true,
                        ),
                      if (caps.contains(AccountCapability.pin))
                        quick(
                          const Key('infoPin'),
                          ZIcons.pin,
                          context.tr(current?.pinned == true
                              ? 'unpinThread'
                              : 'pinThread'),
                          () => runThreadAction(
                              context,
                              () => session.setPinned(thread.id, thread.type,
                                  !(current?.pinned ?? false))),
                          active: current?.pinned == true,
                        ),
                      quick(const Key('infoSearch'), ZIcons.search,
                          context.tr('findMessages'), () {
                        if (LayoutScope.of(context) != LayoutClass.expanded) {
                          widget.onClose();
                        }
                        ref.read(chatSearchRequestProvider.notifier).state++;
                      }),
                    ],
                  ),
                ),
                if (group)
                  _section(
                      'members',
                      context.tr('membersTitle'),
                      count: memberCount == 0 ? null : memberCount,
                      [
                        if (info!.isLoading)
                          for (var i = 0; i < 3; i++)
                            const ZSkeletonRow(avatar: 40, height: 56)
                        else if (info.hasError)
                          Padding(
                            padding: const EdgeInsets.all(ZSpace.s8),
                            child: ZErrorState(
                                title: context.tr('loadFailed'),
                                retryLabel: context.tr('retry'),
                                onRetry: () => ref.invalidate(
                                    groupInfoProvider((session, thread.id)))),
                          )
                        else if (memberIds.isEmpty)
                          _emptyLine(context.tr('membersUnavailable'))
                        else
                          for (final id in memberIds)
                            () {
                              final contact = resolveMember(id);
                              final isOwner = id == groupData?.ownerId;
                              final isDeputy = groupData?.adminIds.contains(id) ?? false;
                              final selfUid = activeAccount?.uid ?? '';
                              final selfCanManage = caps.contains(AccountCapability.groupManage) &&
                                  id != selfUid &&
                                  (groupData?.ownerId == selfUid || (groupData?.adminIds.contains(selfUid) ?? false));
                              return _MemberRow(
                                key: Key('member-$id'),
                                session: session,
                                contact: contact,
                                owner: isOwner,
                                trailing: selfCanManage
                                    ? ZIconButton(
                                        key: Key('memberManage-$id'),
                                        icon: ZIcons.moreHoriz,
                                        label: context.tr('memberActions'),
                                        onPressed: () => showGroupMemberActionsSheet(
                                          context,
                                          session: session,
                                          groupId: thread.id,
                                          member: contact,
                                          isTargetDeputy: isDeputy,
                                          onChanged: () => ref.invalidate(groupInfoProvider((session, thread.id))),
                                        ),
                                      )
                                    : null,
                                onTap: contact.displayName.isEmpty
                                    ? null
                                    : () => _showProfile(contact, owner: isOwner),
                              );
                            }(),
                      ]),
                _section('media', context.tr('mediaTitle'), [
                  if (media.isEmpty)
                    _emptyLine(context.tr('noMedia'))
                  else ...[
                    Padding(
                      padding:
                          const EdgeInsets.symmetric(horizontal: ZSpace.s16),
                      child: _MediaGridView(
                          session: session, items: media, limit: 12, cell: 72),
                    ),
                    if (media.length > 12)
                      Padding(
                        padding: const EdgeInsets.fromLTRB(
                            ZSpace.s16, ZSpace.s8, ZSpace.s16, 0),
                        child: ZButton(
                            key: const Key('infoAllMedia'),
                            label: context.tr('viewAll'),
                            variant: ZButtonVariant.secondary,
                            small: true,
                            expand: true,
                            onPressed: () => _showGallery(media)),
                      ),
                  ],
                ]),
                _section('files', context.tr('filesTitle'), [
                  if (files.isEmpty) _emptyLine(context.tr('noFiles')),
                  for (final (m, a) in files.take(20))
                    Padding(
                      key: Key('infoFile-${m.id}'),
                      padding: const EdgeInsets.symmetric(horizontal: ZSpace.s16, vertical: 6),
                      child: FileCard(session: session, attachment: a),
                    ),
                ]),
                _section('links', context.tr('linksTitle'), [
                  if (links.isEmpty) _emptyLine(context.tr('noLinks')),
                  for (final (m, a) in links.take(20))
                    Padding(
                      key: Key('infoLink-${m.id}'),
                      padding: const EdgeInsets.symmetric(
                          horizontal: ZSpace.s16, vertical: ZSpace.s4),
                      child: LinkCard(
                          session: session,
                          attachment: a,
                          onTap: () =>
                              ref.read(platformProvider).openUrl(a.url)),
                    ),
                ]),
                Container(height: ZSpace.s8, color: z.layerSubtle),
                if (caps.contains(AccountCapability.pinMessage) ||
                    caps.contains(AccountCapability.reminders) ||
                    (group &&
                        (caps.contains(AccountCapability.polls) ||
                            caps.contains(AccountCapability.notes))))
                  _section('board', context.tr('boardSectionTitle'), [
                    if (caps.contains(AccountCapability.pinMessage))
                      ZRow(
                        key: const Key('infoPinnedBoard'),
                        icon: ZIcons.pin,
                        title: context.tr('pinnedListTitle'),
                        trailing: Icon(ZIcons.chevronRight,
                            color: z.textTertiary, size: 20),
                        onTap: () => showPinnedBoardSheet(
                          context,
                          session: session,
                          threadId: thread.id,
                          threadType: thread.type,
                          initialPins: const [],
                          canPin: true,
                          canNotes: caps.contains(AccountCapability.notes),
                          onOpenItem: (item) {
                            if (item.kind == BoardItemKind.poll &&
                                item.pollId != null &&
                                group) {
                              showPollDetailSheet(
                                context,
                                session: session,
                                directory: directory,
                                pollId: item.pollId!,
                                groupId: thread.id,
                                selfUid: activeAccount?.uid ?? '',
                                isAdmin: groupData?.ownerId == activeAccount?.uid ||
                                    (groupData?.adminIds.contains(activeAccount?.uid) ?? false),
                              );
                            }
                          },
                          onChanged: () {},
                        ),
                      ),
                    if (caps.contains(AccountCapability.reminders))
                      ZRow(
                        key: const Key('infoReminders'),
                        icon: ZIcons.alarm,
                        title: context.tr('remindersTitle'),
                        trailing: Icon(ZIcons.chevronRight,
                            color: z.textTertiary, size: 20),
                        onTap: () => showRemindersSheet(
                          context,
                          session: session,
                          threadId: thread.id,
                          threadType: thread.type,
                        ),
                      ),
                    if (group && caps.contains(AccountCapability.polls))
                      ZRow(
                        key: const Key('infoCreatePoll'),
                        icon: ZIcons.poll,
                        title: context.tr('createPollTitle'),
                        trailing: Icon(ZIcons.chevronRight,
                            color: z.textTertiary, size: 20),
                        onTap: () => showCreatePollSheet(
                          context,
                          session: session,
                          groupId: thread.id,
                        ),
                      ),
                    if (group && caps.contains(AccountCapability.notes))
                      ZRow(
                        key: const Key('infoCreateNote'),
                        icon: ZIcons.note,
                        title: context.tr('createNoteTitle'),
                        trailing: Icon(ZIcons.chevronRight,
                            color: z.textTertiary, size: 20),
                        onTap: () => showCreateNoteSheet(
                          context,
                          session: session,
                          groupId: thread.id,
                        ),
                      ),
                  ]),
                if (group && groupData != null && caps.contains(AccountCapability.groupManage))
                  ZRow(
                    key: const Key('infoManageGroup'),
                    icon: ZIcons.manageAccounts,
                    title: context.tr('manageGroup'),
                    trailing: Icon(ZIcons.chevronRight, color: z.textTertiary, size: 20),
                    onTap: () => showGroupManageSheet(
                      context,
                      session: session,
                      group: groupData,
                      selfUid: activeAccount?.uid ?? '',
                      onChanged: () => ref.invalidate(groupInfoProvider((session, thread.id))),
                    ),
                  ),
                if (!group && caps.contains(AccountCapability.friends)) ...[
                  ZRow(
                    key: const Key('infoUserQr'),
                    icon: ZIcons.qrCode,
                    title: context.tr('viewQr'),
                    trailing: Icon(ZIcons.chevronRight, color: z.textTertiary, size: 20),
                    onTap: () => showUserQrSheet(context, session: session, uid: thread.id, name: name),
                  ),
                  ZRow(
                    key: const Key('infoCloseFriend'),
                    icon: ZIcons.star,
                    title: context.tr('closeFriendToggle'),
                    onTap: () async {
                      await session.setCloseFriend([thread.id], true);
                      if (context.mounted) zToast(context, context.tr('actionSaved'));
                    },
                  ),
                ],
                if (caps.contains(AccountCapability.mediaStore))
                  ZRow(
                    key: const Key('infoMediaStore'),
                    icon: ZIcons.image,
                    title: context.tr('mediaStore'),
                    trailing: Icon(ZIcons.chevronRight, color: z.textTertiary, size: 20),
                    onTap: () => showMediaStoreSheet(
                      context,
                      session: session,
                      threadId: thread.id,
                      threadType: thread.type,
                    ),
                  ),
                if (caps.contains(AccountCapability.e2ee))
                  ZRow(
                    key: const Key('infoE2ee'),
                    icon: ZIcons.encrypted,
                    title: context.tr('e2ee'),
                    trailing: Icon(ZIcons.chevronRight, color: z.textTertiary, size: 20),
                    onTap: () => showE2eeStatusSheet(
                      context,
                      session: session,
                      threadId: thread.id,
                      threadType: thread.type,
                    ),
                  ),
                if (caps.contains(AccountCapability.labels))
                  ZRow(
                    key: const Key('infoLabels'),
                    icon: ZIcons.label,
                    title: context.tr('labelsTitle'),
                    subtitle: labelSummary,
                    trailing: Icon(ZIcons.chevronRight,
                        color: z.textTertiary, size: 20),
                    onTap: current == null
                        ? null
                        : () => showLabelsSheet(context,
                            session: session, threadId: thread.id),
                  ),
                if (caps.contains(AccountCapability.autoDelete))
                  ZRow(
                    key: const Key('infoAutoDelete'),
                    icon: ZIcons.timer,
                    title: context.tr('autoDelete'),
                    subtitle: autoDeleteTtlLabel(currentTtl, context.s),
                    trailing: Icon(ZIcons.chevronRight,
                        color: z.textTertiary, size: 20),
                    onTap: current == null
                        ? null
                        : () => showAutoDeleteSheet(context,
                            session: session, thread: current),
                  ),
                if (caps.contains(AccountCapability.archive))
                  ZRow(
                    key: const Key('infoArchive'),
                    icon: current?.archived == true
                        ? ZIcons.unarchive
                        : ZIcons.archive,
                    title: context.tr(current?.archived == true
                        ? 'unarchiveThread'
                        : 'archiveThread'),
                    onTap: current == null
                        ? null
                        : () => applyThreadAction(context, ref, session,
                            current, ThreadMenuAction.archive),
                  ),
                if (caps.contains(AccountCapability.hidden))
                  ZRow(
                    key: const Key('infoHide'),
                    icon: current?.hidden == true
                        ? ZIcons.eye
                        : ZIcons.eyeOff,
                    title: context.tr(current?.hidden == true
                        ? 'unhideThread'
                        : 'hideThread'),
                    onTap: current == null
                        ? null
                        : () => applyThreadAction(context, ref, session,
                            current, ThreadMenuAction.hide),
                  ),
                if (caps.contains(AccountCapability.report))
                  ZRow(
                    key: const Key('infoReport'),
                    icon: ZIcons.flag,
                    title: context.tr('report'),
                    subtitle: context.tr('reportTitle'),
                    onTap: () => showReportDialog(context,
                        session: session,
                        threadId: thread.id,
                        type: thread.type),
                  ),
                if (caps.contains(AccountCapability.deleteThread))
                  ZRow(
                    key: const Key('infoDelete'),
                    icon: ZIcons.delete,
                    title: context.tr('deleteHistory'),
                    danger: true,
                    onTap: current == null
                        ? null
                        : () => applyThreadAction(context, ref, session,
                            current, ThreadMenuAction.delete),
                  ),
                SizedBox(
                    height: ZSpace.s16 + MediaQuery.paddingOf(context).bottom),
              ],
            ),
          ),
        ],
      ),
    );
  }
}

class _MemberRow extends StatelessWidget {
  const _MemberRow({super.key, required this.session, required this.contact, required this.owner, this.trailing, required this.onTap});

  final AccountSession session;
  final Contact contact;
  final bool owner;
  final Widget? trailing;
  final VoidCallback? onTap;

  @override
  Widget build(BuildContext context) {
    final z = context.z;
    final unknown = contact.displayName.isEmpty;
    final name = unknown ? context.tr('unknownUser') : (contact.alias?.isNotEmpty == true ? contact.alias! : contact.displayName);
    return ZPressable(
      onTap: onTap,
      radius: 0,
      semanticLabel: owner ? '$name, ${context.tr('groupOwner')}' : name,
      child: SizedBox(
        height: 56,
        child: Padding(
          padding: const EdgeInsets.symmetric(horizontal: ZSpace.s16),
          child: Row(
            children: [
              ZAvatar(
                  session: session,
                  id: contact.uid,
                  name: name,
                  url: contact.avatarUrl,
                  size: 40),
              const SizedBox(width: ZSpace.s12),
              Expanded(
                  child: Text(name,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: z.text.labelRegular.copyWith(
                          color: unknown ? z.textTertiary : z.textPrimary))),
              if (owner)
                ZChip(
                    label: context.tr('groupOwner'),
                    tone: ZTone.warning,
                    icon: ZIcons.key),
              if (trailing != null) trailing!,
            ],
          ),
        ),
      ),
    );
  }
}

class _MediaGridView extends StatelessWidget {
  const _MediaGridView({required this.session, required this.items, required this.limit, required this.cell});

  final AccountSession session;
  final List<ViewerItem> items;
  final int limit;
  final double cell;

  @override
  Widget build(BuildContext context) {
    final shown = items.length > limit ? limit : items.length;
    return Wrap(
      spacing: ZSpace.s4,
      runSpacing: ZSpace.s4,
      children: [
        for (var i = 0; i < shown; i++)
          MediaThumb(
            key: Key('infoMedia-$i'),
            session: session,
            attachment: items[i].attachment,
            width: cell,
            height: cell,
            radius: ZRadius.tight,
            onTap: () => showMediaViewer(context, session, items, i),
          ),
      ],
    );
  }
}
