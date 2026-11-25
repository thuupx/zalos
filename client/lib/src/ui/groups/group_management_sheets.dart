import 'package:material_ui/material_ui.dart';
import 'package:flutter/services.dart';

import '../../domain/models.dart';
import '../../domain/services.dart';
import '../components/basics.dart';
import '../components/fields.dart';
import '../components/overlays.dart';
import '../components/pressable.dart';
import '../l10n/strings.dart';
import '../theme/tokens.dart';
import '../theme/z_icons.dart';

Future<String?> showCreateGroupSheet(
  BuildContext context, {
  required AccountSession session,
}) =>
    showZModal<String>(
      context,
      builder: (_) => _CreateGroupSheet(session: session),
    );

class _CreateGroupSheet extends StatefulWidget {
  const _CreateGroupSheet({required this.session});
  final AccountSession session;

  @override
  State<_CreateGroupSheet> createState() => _CreateGroupSheetState();
}

class _CreateGroupSheetState extends State<_CreateGroupSheet> {
  final TextEditingController _name = TextEditingController();
  final Set<String> _selected = {};
  late final Future<List<Contact>> _contacts = widget.session.contacts();
  bool _busy = false;

  @override
  void dispose() {
    _name.dispose();
    super.dispose();
  }

  Future<void> _submit() async {
    if (_busy || _selected.isEmpty) return;
    setState(() => _busy = true);
    try {
      final gid = await widget.session.createGroup(
        name: _name.text.trim(),
        members: _selected.toList(),
      );
      if (mounted) {
        zToast(context, context.tr('groupCreated'));
        Navigator.of(context).pop(gid);
      }
    } catch (_) {
      if (mounted) zToast(context, context.tr('actionFailed'));
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final z = context.z;
    return ZDialogScaffold(
      key: const Key('createGroupSheet'),
      title: context.tr('createGroup'),
      showClose: true,
      actions: [
        ZButton(
          key: const Key('createGroupSubmit'),
          label: context.tr('createGroup'),
          onPressed: _busy || _selected.isEmpty ? null : _submit,
        ),
      ],
      child: SizedBox(
        height: 340,
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            ZTextField(
              key: const Key('createGroupName'),
              controller: _name,
              label: context.tr('groupNameLabel'),
              hint: context.tr('groupNameHint'),
            ),
            const SizedBox(height: ZSpace.s12),
            Text(context.tr('selectMembers'), style: z.text.labelStrong),
            const SizedBox(height: ZSpace.s8),
            Expanded(
              child: FutureBuilder<List<Contact>>(
                future: _contacts,
                builder: (context, snap) {
                  if (!snap.hasData) return const ZSkeletonRow(avatar: 36, height: 48);
                  final list = snap.data!;
                  return ListView.builder(
                    shrinkWrap: true,
                    itemCount: list.length,
                    itemBuilder: (context, i) {
                      final c = list[i];
                      final picked = _selected.contains(c.uid);
                      return ZSwitchRow(
                        key: Key('pickMember-${c.uid}'),
                        icon: ZIcons.user,
                        title: c.displayName,
                        value: picked,
                        onChanged: (v) => setState(() {
                          if (v) {
                            _selected.add(c.uid);
                          } else {
                            _selected.remove(c.uid);
                          }
                        }),
                      );
                    },
                  );
                },
              ),
            ),
          ],
        ),
      ),
    );
  }
}

Future<void> showJoinGroupLinkSheet(
  BuildContext context, {
  required AccountSession session,
}) =>
    showZModal<void>(
      context,
      builder: (_) => _JoinGroupLinkSheet(session: session),
    );

class _JoinGroupLinkSheet extends StatefulWidget {
  const _JoinGroupLinkSheet({required this.session});
  final AccountSession session;

  @override
  State<_JoinGroupLinkSheet> createState() => _JoinGroupLinkSheetState();
}

class _JoinGroupLinkSheetState extends State<_JoinGroupLinkSheet> {
  final TextEditingController _link = TextEditingController();
  bool _busy = false;
  Map<String, dynamic>? _preview;

  @override
  void dispose() {
    _link.dispose();
    super.dispose();
  }

  Future<void> _lookup() async {
    final link = _link.text.trim();
    if (link.isEmpty || _busy) return;
    setState(() => _busy = true);
    try {
      final info = await widget.session.groupLinkInfo(link);
      if (mounted) setState(() => _preview = info);
    } catch (_) {
      if (mounted) zToast(context, context.tr('actionFailed'));
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  Future<void> _join() async {
    final link = _link.text.trim();
    if (link.isEmpty || _busy) return;
    setState(() => _busy = true);
    try {
      await widget.session.joinGroupLink(link);
      if (mounted) {
        zToast(context, context.tr('groupJoined'));
        Navigator.of(context).pop();
      }
    } catch (_) {
      if (mounted) zToast(context, context.tr('actionFailed'));
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final z = context.z;
    return ZDialogScaffold(
      key: const Key('joinGroupLinkSheet'),
      title: context.tr('joinGroupLink'),
      showClose: true,
      actions: [
        ZButton(
          key: const Key('joinGroupLookup'),
          label: context.tr('search'),
          variant: ZButtonVariant.secondary,
          onPressed: _busy ? null : _lookup,
        ),
        ZButton(
          key: const Key('joinGroupSubmit'),
          label: context.tr('joinGroupAction'),
          onPressed: _busy ? null : _join,
        ),
      ],
      child: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          ZTextField(
            key: const Key('joinGroupLinkField'),
            controller: _link,
            label: context.tr('groupLinkLabel'),
            hint: context.tr('groupLinkHint'),
          ),
          if (_preview != null) ...[
            const SizedBox(height: ZSpace.s12),
            Text(
              '${_preview!['name'] ?? ''} (${_preview!['totalMember'] ?? 0})',
              style: z.text.labelStrong,
            ),
          ],
        ],
      ),
    );
  }
}

Future<void> showGroupInviteBoxSheet(
  BuildContext context, {
  required AccountSession session,
}) =>
    showZModal<void>(
      context,
      builder: (_) => _GroupInviteBoxSheet(session: session),
    );

class _GroupInviteBoxSheet extends StatefulWidget {
  const _GroupInviteBoxSheet({required this.session});
  final AccountSession session;

  @override
  State<_GroupInviteBoxSheet> createState() => _GroupInviteBoxSheetState();
}

class _GroupInviteBoxSheetState extends State<_GroupInviteBoxSheet> {
  List<GroupInviteBoxItem> _items = const [];
  bool _loading = true;

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    setState(() => _loading = true);
    try {
      final list = await widget.session.groupInviteBoxList();
      if (mounted) setState(() => _items = list);
    } finally {
      if (mounted) setState(() => _loading = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final z = context.z;
    return ZDialogScaffold(
      key: const Key('groupInviteBoxSheet'),
      title: context.tr('groupInvites'),
      showClose: true,
      child: ConstrainedBox(
        constraints: const BoxConstraints(maxHeight: 360),
        child: _loading
            ? const ZSkeletonRow(avatar: 36, height: 52)
            : _items.isEmpty
                ? Padding(
                    padding: const EdgeInsets.all(ZSpace.s16),
                    child: Text(context.tr('groupInvitesEmpty'), style: z.text.rowSub),
                  )
                : ListView.builder(
                    shrinkWrap: true,
                    itemCount: _items.length,
                    itemBuilder: (context, i) {
                      final item = _items[i];
                      return ZRow(
                        key: Key('inviteBox-${item.groupId}'),
                        icon: ZIcons.groups,
                        title: item.name.isEmpty ? item.groupId : item.name,
                        subtitle: context.tr('members', [item.memberCount]),
                        trailing: Row(
                          mainAxisSize: MainAxisSize.min,
                          children: [
                            ZButton(
                              label: context.tr('decline'),
                              variant: ZButtonVariant.text,
                              small: true,
                              onPressed: () async {
                                await widget.session.deleteGroupInviteBox([item.groupId]);
                                await _load();
                              },
                            ),
                            ZButton(
                              label: context.tr('joinGroupAction'),
                              small: true,
                              onPressed: () async {
                                await widget.session.joinGroupInviteBox(item.groupId);
                                if (context.mounted) zToast(context, context.tr('groupJoined'));
                                await _load();
                              },
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

Future<void> showGroupManageSheet(
  BuildContext context, {
  required AccountSession session,
  required GroupInfo group,
  required String selfUid,
  VoidCallback? onChanged,
}) =>
    showZModal<void>(
      context,
      builder: (_) => _GroupManageSheet(
        session: session,
        group: group,
        selfUid: selfUid,
        onChanged: onChanged,
      ),
    );

class _GroupManageSheet extends StatefulWidget {
  const _GroupManageSheet({
    required this.session,
    required this.group,
    required this.selfUid,
    this.onChanged,
  });

  final AccountSession session;
  final GroupInfo group;
  final String selfUid;
  final VoidCallback? onChanged;

  @override
  State<_GroupManageSheet> createState() => _GroupManageSheetState();
}

class _GroupManageSheetState extends State<_GroupManageSheet> {
  late final TextEditingController _name = TextEditingController(text: widget.group.name);
  GroupLinkDetail? _linkDetail;
  List<Contact> _pending = const [];
  List<Contact> _blocked = const [];
  bool _lockSend = false;
  bool _joinAppr = false;
  bool _lockPoll = false;
  bool _lockPost = false;
  bool _msgHistory = true;
  bool _blockName = false;
  bool _busy = false;

  @override
  void initState() {
    super.initState();
    _loadExtras();
  }

  @override
  void dispose() {
    _name.dispose();
    super.dispose();
  }

  Future<void> _loadExtras() async {
    try {
      final res = await Future.wait([
        widget.session.groupLinkDetail(widget.group.id),
        widget.session.pendingGroupMembers(widget.group.id),
        widget.session.blockedGroupMembers(widget.group.id),
      ]);
      if (!mounted) return;
      setState(() {
        _linkDetail = res[0] as GroupLinkDetail;
        _pending = res[1] as List<Contact>;
        _blocked = res[2] as List<Contact>;
      });
    } catch (_) {}
  }

  Future<void> _updateSetting(String key, bool value, VoidCallback apply) async {
    setState(apply);
    try {
      await widget.session.updateGroupSettings(widget.group.id, {key: value});
      if (mounted) zToast(context, context.tr('actionSaved'));
    } catch (_) {
      if (mounted) zToast(context, context.tr('actionFailed'));
    }
  }

  @override
  Widget build(BuildContext context) {
    final z = context.z;
    final isOwner = widget.group.ownerId == widget.selfUid;
    return ZDialogScaffold(
      key: const Key('groupManageSheet'),
      title: context.tr('manageGroup'),
      showClose: true,
      child: ConstrainedBox(
        constraints: const BoxConstraints(maxHeight: 520),
        child: ListView(
          shrinkWrap: true,
          children: [
            Row(
              children: [
                Expanded(
                  child: ZTextField(
                    key: const Key('manageGroupNameField'),
                    controller: _name,
                    label: context.tr('groupNameLabel'),
                  ),
                ),
                const SizedBox(width: ZSpace.s8),
                ZButton(
                  key: const Key('manageGroupRenameButton'),
                  label: context.tr('renameGroupAction'),
                  small: true,
                  onPressed: _busy
                      ? null
                      : () async {
                          final next = _name.text.trim();
                          if (next.isEmpty) return;
                          setState(() => _busy = true);
                          try {
                            await widget.session.renameGroup(widget.group.id, next);
                            widget.onChanged?.call();
                            if (context.mounted) zToast(context, context.tr('actionSaved'));
                          } finally {
                            if (mounted) setState(() => _busy = false);
                          }
                        },
                ),
              ],
            ),
            const SizedBox(height: ZSpace.s12),
            Text(context.tr('groupInviteLinkTitle'), style: z.text.labelStrong),
            ZRow(
              key: const Key('groupInviteLinkRow'),
              icon: ZIcons.link,
              title: _linkDetail?.enabled == true
                  ? (_linkDetail?.link ?? context.tr('groupInviteLinkTitle'))
                  : context.tr('disableInviteLink'),
              trailing: Row(
                mainAxisSize: MainAxisSize.min,
                children: [
                  if (_linkDetail?.link != null && _linkDetail!.link!.isNotEmpty)
                    ZIconButton(
                      icon: ZIcons.copy,
                      label: context.tr('copied'),
                      onPressed: () {
                        Clipboard.setData(ClipboardData(text: _linkDetail!.link!));
                        zToast(context, context.tr('copied'));
                      },
                    ),
                  ZButton(
                    key: const Key('toggleGroupLinkButton'),
                    label: context.tr(_linkDetail?.enabled == true ? 'disableInviteLink' : 'enableInviteLink'),
                    small: true,
                    variant: ZButtonVariant.secondary,
                    onPressed: () async {
                      if (_linkDetail?.enabled == true) {
                        await widget.session.disableGroupLink(widget.group.id);
                      } else {
                        await widget.session.enableGroupLink(widget.group.id);
                      }
                      await _loadExtras();
                    },
                  ),
                ],
              ),
            ),
            const SizedBox(height: ZSpace.s8),
            Text(context.tr('groupSettingsTitle'), style: z.text.labelStrong),
            ZSwitchRow(
              key: const Key('settingLockSend'),
              icon: ZIcons.lock,
              title: context.tr('settingLockSend'),
              value: _lockSend,
              onChanged: (v) => _updateSetting('lockSendMsg', v, () => _lockSend = v),
            ),
            ZSwitchRow(
              key: const Key('settingJoinAppr'),
              icon: ZIcons.personCheck,
              title: context.tr('settingJoinAppr'),
              value: _joinAppr,
              onChanged: (v) => _updateSetting('joinAppr', v, () => _joinAppr = v),
            ),
            ZSwitchRow(
              icon: ZIcons.poll,
              title: context.tr('settingLockPoll'),
              value: _lockPoll,
              onChanged: (v) => _updateSetting('lockCreatePoll', v, () => _lockPoll = v),
            ),
            ZSwitchRow(
              icon: ZIcons.pin,
              title: context.tr('settingLockPost'),
              value: _lockPost,
              onChanged: (v) => _updateSetting('lockCreatePost', v, () => _lockPost = v),
            ),
            ZSwitchRow(
              icon: ZIcons.chat,
              title: context.tr('settingMsgHistory'),
              value: _msgHistory,
              onChanged: (v) => _updateSetting('enableMsgHistory', v, () => _msgHistory = v),
            ),
            ZSwitchRow(
              icon: ZIcons.edit,
              title: context.tr('settingBlockName'),
              value: _blockName,
              onChanged: (v) => _updateSetting('blockName', v, () => _blockName = v),
            ),
            if (_pending.isNotEmpty) ...[
              const SizedBox(height: ZSpace.s8),
              Text(context.tr('pendingMembersTitle'), style: z.text.labelStrong),
              for (final u in _pending)
                ZRow(
                  icon: ZIcons.personAdd,
                  title: u.displayName.isEmpty ? u.uid : u.displayName,
                  trailing: ZButton(
                    label: context.tr('approve'),
                    small: true,
                    onPressed: () async {
                      await widget.session.reviewPendingGroupMembers(widget.group.id, [u.uid], true);
                      await _loadExtras();
                    },
                  ),
                ),
            ],
            if (_blocked.isNotEmpty) ...[
              const SizedBox(height: ZSpace.s8),
              Text(context.tr('blockedGroupMembersTitle'), style: z.text.labelStrong),
              for (final u in _blocked)
                ZRow(
                  icon: ZIcons.block,
                  title: u.displayName.isEmpty ? u.uid : u.displayName,
                  trailing: ZButton(
                    label: context.tr('unblockAction'),
                    small: true,
                    variant: ZButtonVariant.secondary,
                    onPressed: () async {
                      await widget.session.removeBlockedGroupMembers(widget.group.id, [u.uid]);
                      await _loadExtras();
                    },
                  ),
                ),
            ],
            const SizedBox(height: ZSpace.s8),
            if (isOwner)
              ZRow(
                key: const Key('upgradeCommunityRow'),
                icon: ZIcons.groups,
                title: context.tr('upgradeCommunity'),
                onTap: () async {
                  await widget.session.upgradeGroupToCommunity(widget.group.id);
                  if (context.mounted) zToast(context, context.tr('actionSaved'));
                },
              ),
            ZRow(
              key: const Key('leaveGroupRow'),
              icon: ZIcons.personRemove,
              title: context.tr('leaveGroup'),
              danger: true,
              onTap: () async {
                final ok = await zConfirm(
                  context,
                  title: context.tr('leaveGroup'),
                  message: widget.group.name,
                  confirmLabel: context.tr('leaveGroup'),
                );
                if (!ok || !context.mounted) return;
                await widget.session.leaveGroup(widget.group.id);
                widget.onChanged?.call();
                if (context.mounted) Navigator.of(context).pop();
              },
            ),
            if (isOwner)
              ZRow(
                key: const Key('disperseGroupRow'),
                icon: ZIcons.delete,
                title: context.tr('disperseGroup'),
                danger: true,
                onTap: () async {
                  final ok = await zConfirm(
                    context,
                    title: context.tr('disperseGroup'),
                    message: widget.group.name,
                    confirmLabel: context.tr('disperseGroup'),
                  );
                  if (!ok || !context.mounted) return;
                  await widget.session.disperseGroup(widget.group.id);
                  widget.onChanged?.call();
                  if (context.mounted) Navigator.of(context).pop();
                },
              ),
          ],
        ),
      ),
    );
  }
}

Future<void> showGroupMemberActionsSheet(
  BuildContext context, {
  required AccountSession session,
  required String groupId,
  required Contact member,
  required bool isTargetDeputy,
  VoidCallback? onChanged,
}) =>
    showZModal<void>(
      context,
      builder: (_) => ZDialogScaffold(
        key: Key('memberActions-${member.uid}'),
        title: member.displayName.isEmpty ? member.uid : member.displayName,
        showClose: true,
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            ZRow(
              icon: ZIcons.user,
              title: context.tr('memberActions'),
              subtitle: member.uid,
            ),
            ZRow(
              icon: ZIcons.key,
              title: context.tr(isTargetDeputy ? 'removeDeputy' : 'makeDeputy'),
              onTap: () async {
                if (isTargetDeputy) {
                  await session.removeGroupDeputy(groupId, [member.uid]);
                } else {
                  await session.addGroupDeputy(groupId, [member.uid]);
                }
                onChanged?.call();
                if (context.mounted) Navigator.of(context).pop();
              },
            ),
            ZRow(
              icon: ZIcons.manageAccounts,
              title: context.tr('transferOwner'),
              onTap: () async {
                await session.changeGroupOwner(groupId, member.uid);
                onChanged?.call();
                if (context.mounted) Navigator.of(context).pop();
              },
            ),
            ZRow(
              icon: ZIcons.block,
              title: context.tr('blockInGroup'),
              danger: true,
              onTap: () async {
                await session.addBlockedGroupMembers(groupId, [member.uid]);
                onChanged?.call();
                if (context.mounted) Navigator.of(context).pop();
              },
            ),
            ZRow(
              icon: ZIcons.personRemove,
              title: context.tr('removeFromGroup'),
              danger: true,
              onTap: () async {
                await session.removeGroupMembers(groupId, [member.uid]);
                onChanged?.call();
                if (context.mounted) Navigator.of(context).pop();
              },
            ),
          ],
        ),
      ),
    );
