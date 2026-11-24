import 'dart:async';

import 'package:material_ui/material_ui.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../domain/models.dart';
import '../../domain/services.dart';
import '../components/avatar.dart';
import '../components/basics.dart';
import '../components/pressable.dart';
import '../info/auto_delete_sheet.dart';
import '../l10n/strings.dart';
import '../state/app_state.dart';
import '../state/thread_ui.dart';
import '../theme/tokens.dart';
import '../theme/z_icons.dart';
import '../util/format.dart';
import '../util/haptics.dart';
import 'threads_pane.dart';

final groupInfoProvider = FutureProvider.family<GroupInfo, (AccountSession, String)>((ref, key) => key.$1.groupInfo(key.$2));

/// Up to four member initials for the collage avatar of a group.
List<AvatarMember> collageMembers(WidgetRef ref, AccountSession session, String groupId) {
  final info = ref.watch(groupInfoProvider((session, groupId))).valueOrNull;
  if (info == null) return const [];
  final directory = ref.watch(directoryProvider(session));
  ref.watchNotifier(directory);
  final ids = info.memberIds.take(4).toList();
  directory.need(ids);
  return [for (final id in ids) AvatarMember(id, directory.nameOf(id, '?'), directory.avatarOf(id))];
}

/// Name of a thread, falling back to the group info, the directory or the
/// last sender when the server has not stored a name yet.
String threadDisplayName(WidgetRef ref, AccountSession session, Thread t, S s) {
  if (t.name.trim().isNotEmpty) return t.name;
  if (t.type == ThreadType.group) {
    final info = ref.watch(groupInfoProvider((session, t.id))).valueOrNull;
    return info != null && info.name.trim().isNotEmpty ? info.name : s.t('unnamedGroup');
  }
  final directory = ref.watch(directoryProvider(session));
  ref.watchNotifier(directory);
  directory.need([t.id]);
  final known = directory.nameOf(t.id);
  if (known.isNotEmpty) return known;
  final m = t.lastMessage;
  if (m != null && !m.isSelf && m.senderName.trim().isNotEmpty) return m.senderName;
  return s.t('unknownUser');
}

/// Relative time that refreshes itself twice a minute.
class _ListTime extends StatefulWidget {
  const _ListTime({required this.ts, required this.unread});

  final int ts;
  final bool unread;

  @override
  State<_ListTime> createState() => _ListTimeState();
}

class _ListTimeState extends State<_ListTime> {
  late final Timer _timer = Timer.periodic(const Duration(seconds: 30), (_) {
    if (mounted) setState(() {});
  });

  @override
  void initState() {
    super.initState();
    _timer.isActive;
  }

  @override
  void dispose() {
    _timer.cancel();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final z = context.z;
    return Text(
      formatListTime(widget.ts, context.s),
      textScaler: TextScaler.noScaling,
      style: z.text.captionTabular.copyWith(color: widget.unread ? z.textPrimary : z.textTertiary, fontWeight: widget.unread ? FontWeight.w600 : FontWeight.w400),
    );
  }
}

class ThreadTile extends ConsumerStatefulWidget {
  const ThreadTile({super.key, required this.session, required this.thread, required this.selected});

  final AccountSession session;
  final Thread thread;
  final bool selected;

  static int debugBuilds = 0;

  @override
  ConsumerState<ThreadTile> createState() => _ThreadTileState();
}

class _ThreadTileState extends ConsumerState<ThreadTile> {
  bool _hover = false;
  bool _longPressing = false;
  double _drag = 0;
  static const double _actionsWidth = 144;

  void _open() {
    if (_drag != 0) {
      setState(() => _drag = 0);
      return;
    }
    ZHaptics.selection();
    final t = widget.thread;
    final name = threadDisplayName(ref, widget.session, t, context.s);
    openThread(ref, OpenThread(slot: widget.session.slot, id: t.id, type: t.type, name: name, avatarUrl: t.avatarUrl));
  }

  void _menu(Offset position) {
    ZHaptics.medium();
    showThreadMenu(context, ref, widget.session, widget.thread, position);
  }

  @override
  Widget build(BuildContext context) {
    ThreadTile.debugBuilds++;
    final z = context.z;
    final s = context.s;
    final wide = LayoutScope.wideOf(context);
    final raw = widget.thread;
    final session = widget.session;
    final name = threadDisplayName(ref, session, raw, s);
    final t = raw.name == name
        ? raw
        : Thread(
            id: raw.id,
            type: raw.type,
            name: name,
            avatarUrl: raw.avatarUrl,
            lastMessage: raw.lastMessage,
            lastTs: raw.lastTs,
            unread: raw.unread,
            pinned: raw.pinned,
            muted: raw.muted,
            hidden: raw.hidden,
            archived: raw.archived,
            autoDeleteTtl: raw.autoDeleteTtl,
          );
    final unread = t.unread > 0;
    final ui = ref.watch(threadUiProvider((slot: session.slot, id: t.id)));
    ref.watchNotifier(ui);
    final typing = ref.watchL(ref.watch(typingProvider(session)).of(t.id));
    final draft = widget.selected ? '' : ui.draft;
    final group = t.type == ThreadType.group;
    final members = group && t.avatarUrl.isEmpty ? collageMembers(ref, session, t.id) : const <AvatarMember>[];

    final Widget preview;
    final String previewLabel;
    final subStyle = z.text.rowSub.copyWith(color: unread ? z.textPrimary : z.textTertiary);
    if (typing.isNotEmpty) {
      previewLabel = s.t('typingPreview');
      preview = Text(previewLabel, maxLines: 1, overflow: TextOverflow.ellipsis, style: z.text.rowSub.copyWith(color: z.brandText));
    } else if (draft.isNotEmpty) {
      previewLabel = '${s.t('draftTag')} $draft';
      preview = Text.rich(
        TextSpan(children: [
          TextSpan(text: '${s.t('draftTag')} ', style: TextStyle(color: z.danger)),
          TextSpan(text: draft.replaceAll('\n', ' ')),
        ]),
        maxLines: 1,
        overflow: TextOverflow.ellipsis,
        style: subStyle,
      );
    } else {
      previewLabel = threadPreview(t, s);
      preview = Text(
        previewLabel,
        maxLines: 1,
        overflow: TextOverflow.ellipsis,
        style: subStyle.copyWith(fontStyle: t.lastMessage?.recalled == true ? FontStyle.italic : FontStyle.normal),
      );
    }
    final time = formatListTime(t.lastTs, s);
    final caps = ref.watch(activeCapsProvider);
    final hasMenu = caps.contains(AccountCapability.pin) || caps.contains(AccountCapability.mute) || caps.contains(AccountCapability.markUnread) || caps.contains(AccountCapability.deleteThread);
    final showMenuButton = wide && _hover && hasMenu;

    final content = Row(
      children: [
        ZAvatar(session: session, id: t.id, name: t.name, url: t.avatarUrl, size: 48, group: group, members: members),
        const SizedBox(width: ZSpace.s12),
        Expanded(
          child: Column(
            mainAxisAlignment: MainAxisAlignment.center,
            children: [
              SizedBox(
                height: 24,
                child: Row(
                  children: [
                    if (group) ...[Icon(ZIcons.group, size: 16, color: z.textTertiary, fill: 1), const SizedBox(width: ZSpace.s4)],
                    Expanded(
                      child: Text(t.name, maxLines: 1, overflow: TextOverflow.ellipsis, style: unread ? z.text.rowTitleUnread : z.text.rowTitle),
                    ),
                    const SizedBox(width: ZSpace.s8),
                    if (showMenuButton)
                      Builder(
                        builder: (buttonContext) => ZIconButton(
                          key: Key('threadMore-${t.id}'),
                          icon: ZIcons.moreHoriz,
                          label: s.t('more'),
                          size: 24,
                          iconSize: 18,
                          onPressed: () {
                            final box = buttonContext.findRenderObject()! as RenderBox;
                            _menu(box.localToGlobal(Offset(0, box.size.height)));
                          },
                        ),
                      )
                    else
                      _ListTime(ts: t.lastTs, unread: unread),
                  ],
                ),
              ),
              const SizedBox(height: ZSpace.s4),
              Row(
                children: [
                  Expanded(child: preview),
                  if (t.muted) ...[const SizedBox(width: ZSpace.s4), Icon(ZIcons.bellOff, size: 14, color: z.textTertiary)],
                  if (t.autoDeleteTtl > 0) ...[const SizedBox(width: ZSpace.s4), Icon(ZIcons.timer, size: 14, color: z.textTertiary)],
                  if (t.pinned) ...[const SizedBox(width: ZSpace.s4), Icon(ZIcons.pin, size: 14, color: z.accentText, fill: 1)],
                  if (unread) ...[const SizedBox(width: ZSpace.s4), ZBadge(count: t.unread, variant: t.muted ? ZBadgeVariant.muted : ZBadgeVariant.normal)],
                ],
              ),
            ],
          ),
        ),
      ],
    );

    final label = [
      t.name,
      if (unread) s.t('unreadCountLabel', [t.unread]),
      previewLabel,
      time,
      if (t.pinned) s.t('pinnedLabel'),
      if (t.muted) s.t('mutedLabel'),
      if (t.autoDeleteTtl > 0) s.t('autoDeleteValue', [autoDeleteTtlLabel(t.autoDeleteTtl, s)]),
    ].where((e) => e.isNotEmpty).join(', ');

    final reduced = ZMotion.reduced(context);
    final pressable = AnimatedScale(
      scale: _longPressing && !reduced ? 0.98 : 1.0,
      duration: reduced ? Duration.zero : const Duration(milliseconds: 120),
      curve: ZMotion.springCurve,
      child: ZPressable(
        onTap: _open,
        onLongPressStart: wide
            ? null
            : (pos) {
                setState(() => _longPressing = true);
                Future<void>.delayed(const Duration(milliseconds: 140), () {
                  if (mounted && _longPressing) {
                    setState(() => _longPressing = false);
                  }
                });
                _menu(pos);
              },
        onSecondaryTapUp: _menu,
        onHover: (v) => setState(() => _hover = v),
        radius: wide ? ZRadius.row : 0,
        color: widget.selected && wide ? z.layerSelected : z.layer,
        hoverColor: widget.selected && wide ? z.layerSelected : z.layerHover,
        selected: widget.selected,
        semanticLabel: label,
        child: wide
            ? Padding(
                padding: const EdgeInsets.symmetric(horizontal: ZSpace.s8),
                child: content,
              )
            : Stack(
                fit: StackFit.expand,
                children: [
                  Padding(
                    padding: const EdgeInsets.symmetric(horizontal: ZSpace.s16),
                    child: content,
                  ),
                  Positioned(
                    left: 76,
                    right: 0,
                    bottom: 0,
                    child: IgnorePointer(
                      child: Container(
                        height: 0.5,
                        color: z.divider.withValues(alpha: z.dark ? 0.16 : 0.08),
                      ),
                    ),
                  ),
                ],
              ),
      ),
    );

    if (wide || !(caps.contains(AccountCapability.pin) && caps.contains(AccountCapability.mute))) {
      return Padding(padding: EdgeInsets.symmetric(horizontal: wide ? ZSpace.s8 : 0, vertical: wide ? ZSpace.s4 : 0), child: pressable);
    }

    Widget swipeAction(Key key, IconData icon, String text, Color bg, Color fg, ThreadMenuAction action) => ZPressable(
          key: key,
          radius: 0,
          color: bg,
          hoverColor: bg,
          pressedColor: bg,
          semanticLabel: text,
          onTap: () {
            setState(() => _drag = 0);
            applyThreadAction(context, ref, session, t, action);
          },
          child: SizedBox(
            width: _actionsWidth / 2,
            child: Column(
              mainAxisAlignment: MainAxisAlignment.center,
              children: [
                Icon(icon, color: fg, size: 22),
                const SizedBox(height: ZSpace.s4),
                Text(text, maxLines: 1, overflow: TextOverflow.ellipsis, textAlign: TextAlign.center, style: z.text.caption.copyWith(color: fg)),
              ],
            ),
          ),
        );

    return GestureDetector(
      onHorizontalDragUpdate: (d) => setState(() => _drag = (_drag + d.delta.dx).clamp(-_actionsWidth, 0.0)),
      onHorizontalDragEnd: (_) {
        final snap = _drag < -_actionsWidth / 2 ? -_actionsWidth : 0.0;
        if (snap != 0 && _drag != snap) ZHaptics.selection();
        setState(() => _drag = snap);
      },
      child: Stack(
        fit: StackFit.expand,
        children: [
          if (_drag != 0)
            Align(
              alignment: Alignment.centerRight,
              child: Row(
                mainAxisSize: MainAxisSize.min,
                children: [
                  swipeAction(Key('swipePin-${t.id}'), ZIcons.pin, s.t(t.pinned ? 'unpin' : 'pin'), z.accent, z.onAccent, ThreadMenuAction.pin),
                  swipeAction(Key('swipeMute-${t.id}'), t.muted ? ZIcons.bell : ZIcons.bellOff, s.t(t.muted ? 'unmuteShort' : 'muteShort'), z.brand, z.textOnBrand, ThreadMenuAction.mute),
                ],
              ),
            ),
          AnimatedSlide(
            duration: ZMotion.enter,
            curve: ZMotion.springCurve,
            offset: Offset(_drag / MediaQuery.sizeOf(context).width, 0),
            child: pressable,
          ),
        ],
      ),
    );
  }
}
