import 'package:material_ui/material_ui.dart';

import '../../domain/models.dart';
import '../components/avatar.dart';
import '../components/overlays.dart';
import '../components/pressable.dart';
import '../l10n/strings.dart';
import '../state/thread_ui.dart';
import '../theme/tokens.dart';
import '../theme/z_icons.dart';
import '../util/format.dart';
import '../util/haptics.dart';
import 'message_row.dart';

enum MessageAction { reply, copy, forward, pin, save, recall, delete, deleteForAll, report, details, retry }

/// A reaction drawn as its emoji, or as a symbol where emoji are disabled.
class ReactionGlyph extends StatelessWidget {
  const ReactionGlyph({super.key, required this.icon, required this.size});

  final String icon;
  final double size;

  @override
  Widget build(BuildContext context) {
    final z = context.z;
    final emoji = zUseEmojiGlyphs ? reactionEmoji(icon) : null;
    if (emoji == null) {
      return SizedBox(
        width: size,
        height: size,
        child: Center(
          child: Icon(
            reactionGlyph(icon),
            size: size,
            color: reactionColor(z, icon),
          ),
        ),
      );
    }
    return SizedBox(
      width: size,
      height: size,
      child: Center(
        child: Text(
          emoji,
          textAlign: TextAlign.center,
          textScaler: TextScaler.noScaling,
          style: z.text.emojiSized(size * 0.86),
        ),
      ),
    );
  }
}

Color reactionColor(ZalosTokens z, String icon) => icon == '/-heart' || icon == ':-h' ? z.danger : z.accentText;

class ReactionRow extends StatelessWidget {
  const ReactionRow({super.key, required this.own, required this.onPick, this.entrance});

  final Set<String> own;
  final ValueChanged<String> onPick;

  /// When set, the icons zoom in one after another as it runs.
  final Animation<double>? entrance;

  /// Share of [entrance] each icon takes to zoom in; the rest staggers them.
  static const double _iconShare = 0.5;

  /// Total entrance of the picker: icons start [ZMotion.stagger] apart and
  /// each takes [_iconShare] of it.
  static final Duration entranceDuration = ZMotion.stagger * ((reactionIcons.length - 1) / (1 - _iconShare));

  Widget _staggered(int index, Widget child) {
    final entrance = this.entrance;
    if (entrance == null) return child;
    final start = index * (1 - _iconShare) / (reactionIcons.length - 1);
    final end = start + _iconShare;
    return FadeTransition(
      opacity: CurvedAnimation(parent: entrance, curve: Interval(start, end, curve: ZMotion.standard)),
      child: ScaleTransition(
        scale: Tween(begin: 0.4, end: 1.0).animate(CurvedAnimation(parent: entrance, curve: Interval(start, end, curve: Curves.easeOutBack))),
        child: child,
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final z = context.z;
    final wide = LayoutScope.wideOf(context);
    return Row(
      mainAxisSize: MainAxisSize.min,
      mainAxisAlignment: MainAxisAlignment.center,
      crossAxisAlignment: CrossAxisAlignment.center,
      children: [
        for (final (index, icon) in reactionIcons.indexed)
          _staggered(index, ZPressable(
            key: Key('react-$icon'),
            circle: true,
            pressScale: 0.86,
            color: own.contains(icon) ? z.brandSubtle : null,
            selected: own.contains(icon),
            semanticLabel: reactionLabel(icon, context.s),
            tooltip: reactionLabel(icon, context.s),
            onTap: () {
              ZHaptics.light();
              onPick(own.contains(icon) ? '' : icon);
            },
            child: SizedBox(
              width: wide ? 36 : ZSizes.touchTarget,
              height: wide ? 36 : ZSizes.touchTarget,
              child: Center(child: ReactionGlyph(icon: icon, size: 22)),
            ),
          )),
      ],
    );
  }
}

/// The six reaction picker as a floating pill above [anchor].
Future<String?> showReactionPicker(BuildContext context, {required Rect anchor, required Set<String> own}) {
  return Navigator.of(context, rootNavigator: true).push<String>(_ReactionPickerRoute(
    anchor: anchor,
    own: own,
    tokens: context.z,
    strings: context.s,
    layout: LayoutScope.of(context),
    barrierLabel: MaterialLocalizations.of(context).modalBarrierDismissLabel,
  ));
}

class _ReactionPickerRoute extends PopupRoute<String> {
  _ReactionPickerRoute({required this.anchor, required this.own, required this.tokens, required this.strings, required this.layout, required this.barrierLabel});

  final Rect anchor;
  final Set<String> own;
  final ZalosTokens tokens;
  final S strings;
  final LayoutClass layout;

  @override
  final String barrierLabel;

  /// Space reserved between the pill and [anchor], also bridged below the
  /// pill so the pointer stays inside the picker while crossing it.
  static const double _gap = 4;

  @override
  Color? get barrierColor => null;

  @override
  bool get barrierDismissible => true;

  @override
  Duration get transitionDuration => ReactionRow.entranceDuration;

  @override
  Duration get reverseTransitionDuration => ZMotion.exit;

  @override
  Widget buildPage(BuildContext context, Animation<double> animation, Animation<double> secondaryAnimation) {
    final z = tokens;
    final wide = layout != LayoutClass.compact;
    final reduced = ZMotion.reduced(context);
    final width = (wide ? 36.0 : ZSizes.touchTarget) * reactionIcons.length + 16;
    final size = MediaQuery.sizeOf(context);
    final left = (anchor.center.dx - width / 2).clamp(8.0, size.width - width - 8);
    final height = (wide ? 36.0 : ZSizes.touchTarget) + 8;
    final top = (anchor.top - height - _gap).clamp(8.0, size.height - height - 8);
    return StringsScope(
      strings: strings,
      child: LayoutScope(
        layout: layout,
        child: ZDismissOnEscape(
          child: Stack(
            children: [
              Positioned(
                left: left,
                top: top,
                child: MouseRegion(
                  onExit: (_) {
                    if (wide && isCurrent) navigator?.pop();
                  },
                  child: Padding(
                    padding: EdgeInsets.only(bottom: wide ? _gap : 0),
                    child: zPopupTransition(
                      context,
                      animation,
                      anchor: anchor.center,
                      from: 0.9,
                      child: Material(
                        type: MaterialType.transparency,
                        child: Container(
                          key: const Key('reactionPicker'),
                          padding: const EdgeInsets.symmetric(horizontal: ZSpace.s8, vertical: ZSpace.s4),
                          decoration: BoxDecoration(color: z.layer, borderRadius: BorderRadius.circular(ZRadius.pill), border: Border.all(color: z.border), boxShadow: z.shadowOverlay),
                          child: ReactionRow(
                            own: own,
                            entrance: reduced ? null : animation,
                            onPick: (icon) => Navigator.of(context).pop(icon),
                          ),
                        ),
                      ),
                    ),
                  ),
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

Future<MessageAction?> showMessageMenu(
  BuildContext context, {
  required Offset position,
  required Message m,
  required Set<String> own,
  required ValueChanged<String> onReact,
  required Set<AccountCapability> caps,
  required bool isGroup,
  required bool admin,
}) {
  final sent = m.sendState == SendState.sent;
  final actionable = sent && !m.recalled && m.kind != MessageKind.system;
  final text = (m.text ?? '').trim();
  final copyable = !m.recalled && (text.isNotEmpty || (m.kind == MessageKind.link && m.attachments.isNotEmpty));
  final media = !m.recalled && m.attachments.isNotEmpty && const {MessageKind.image, MessageKind.gif, MessageKind.video, MessageKind.file, MessageKind.voice}.contains(m.kind);
  final pinnable = actionable &&
      caps.contains(AccountCapability.pinMessage) &&
      m.kind != MessageKind.poll &&
      m.kind != MessageKind.call;
  final canDeleteForAll = actionable && !m.isSelf && isGroup && caps.contains(AccountCapability.deleteForAll) && admin;
  return showZMenu<MessageAction>(
    context,
    position: position,
    animatedHeader: actionable && caps.contains(AccountCapability.reactions)
        ? (menuContext, animation) => Padding(
              padding: const EdgeInsets.only(bottom: ZSpace.s4),
              child: Center(
                child: ReactionRow(
                  own: own,
                  entrance: ZMotion.reduced(menuContext) ? null : animation,
                  onPick: (icon) {
                    Navigator.of(menuContext).pop();
                    onReact(icon);
                  },
                ),
              ),
            )
        : null,
    items: [
      if (actionable) ZMenuItem(value: MessageAction.reply, label: context.tr('reply'), icon: ZIcons.reply),
      if (copyable) ZMenuItem(value: MessageAction.copy, label: context.tr('copy'), icon: ZIcons.copy),
      if (actionable && caps.contains(AccountCapability.forward)) ZMenuItem(value: MessageAction.forward, label: context.tr('forward'), icon: ZIcons.forward, enabled: m.raw != null),
      if (pinnable) ZMenuItem(value: MessageAction.pin, label: context.tr('pinMessage'), icon: ZIcons.pin),
      if (media && sent) ZMenuItem(value: MessageAction.save, label: context.tr('saveToDevice'), icon: ZIcons.download),
      if (m.sendState == SendState.failed) ZMenuItem(value: MessageAction.retry, label: context.tr('retry'), icon: ZIcons.refresh),
      if (sent && m.kind != MessageKind.system) ZMenuItem(value: MessageAction.details, label: context.tr('details'), icon: ZIcons.info),
      if (!m.recalled && caps.contains(AccountCapability.report)) ZMenuItem(value: MessageAction.report, label: context.tr('report'), icon: ZIcons.flag),
      if (m.isSelf && actionable && caps.contains(AccountCapability.recall)) ZMenuItem(value: MessageAction.recall, label: context.tr('recall'), icon: ZIcons.undo, danger: true, dividerBefore: true),
      if (canDeleteForAll) ZMenuItem(value: MessageAction.deleteForAll, label: context.tr('deleteForAll'), icon: ZIcons.deleteForever, danger: true, dividerBefore: true),
      if (caps.contains(AccountCapability.deleteForMe) || m.sendState == SendState.failed) ZMenuItem(value: MessageAction.delete, label: context.tr('deleteForMe'), icon: ZIcons.delete, danger: true, dividerBefore: !(m.isSelf && actionable) && !canDeleteForAll),
    ],
  );
}

/// Sheet listing who reacted, grouped by reaction.
Future<void> showWhoReacted(BuildContext context, ChatActions actions, Message m) {
  return showZModal<void>(
    context,
    builder: (context) {
      final z = context.z;
      final entries = m.reactions.entries.where((e) => e.value.isNotEmpty).toList();
      return ZDialogScaffold(
        key: const Key('whoReacted'),
        title: context.tr('reactionsTitle'),
        showClose: true,
        padBody: false,
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            for (final e in entries)
              for (final uid in e.value)
                _ReactorRow(actions: actions, uid: uid, icon: e.key),
            if (entries.isEmpty) Padding(padding: const EdgeInsets.all(ZSpace.s16), child: Text(context.tr('noReactions'), style: z.text.rowSub)),
            const SizedBox(height: ZSpace.s8),
          ],
        ),
      );
    },
  );
}

class _ReactorRow extends StatelessWidget {
  const _ReactorRow({required this.actions, required this.uid, required this.icon});

  final ChatActions actions;
  final String uid;
  final String icon;

  @override
  Widget build(BuildContext context) {
    final z = context.z;
    final Directory d = actions.directory;
    final name = uid == actions.selfUid ? context.tr('you') : d.nameOf(uid, context.tr('unknownUser'));
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: ZSpace.s16, vertical: 6),
      child: Row(
        children: [
          ZAvatar(session: actions.session, id: uid, name: name, url: d.avatarOf(uid), size: 40),
          const SizedBox(width: ZSpace.s12),
          Expanded(child: Text(name, maxLines: 1, overflow: TextOverflow.ellipsis, style: z.text.rowTitle)),
          Semantics(label: reactionLabel(icon, context.s), child: ReactionGlyph(icon: icon, size: 22)),
        ],
      ),
    );
  }
}

Future<void> showMessageDetails(BuildContext context, ChatActions actions, Message m) {
  return showZModal<void>(
    context,
    builder: (context) {
      final z = context.z;
      final s = context.s;
      final state = !m.isSelf
          ? null
          : switch (m.sendState) {
              SendState.sending => s.t('sending'),
              SendState.failed => s.t('sendFailed'),
              SendState.sent => s.t(switch (m.deliveryState) {
                  DeliveryState.sent => 'stateSent',
                  DeliveryState.delivered => 'stateDelivered',
                  DeliveryState.seen => 'stateSeen',
                }),
            };
      final total = m.reactions.values.fold<int>(0, (n, v) => n + v.length);
      Widget line(String label, String value) => Padding(
            padding: const EdgeInsets.symmetric(vertical: ZSpace.s4),
            child: Row(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                SizedBox(width: 110, child: Text(label, style: z.text.rowSub)),
                Expanded(child: Text(value, style: z.text.body)),
              ],
            ),
          );
      return ZDialogScaffold(
        key: const Key('messageDetails'),
        title: s.t('details'),
        actions: [
          if (total > 0)
            ZButton(
              label: s.t('reactionsTitle'),
              variant: ZButtonVariant.text,
              onPressed: () {
                Navigator.of(context).pop();
                showWhoReacted(context, actions, m);
              },
            ),
          ZButton(label: s.t('close'), variant: ZButtonVariant.secondary, onPressed: () => Navigator.of(context).pop()),
        ],
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            line(s.t('detailSender'), m.isSelf ? s.t('you') : actions.directory.nameOf(m.senderId, m.senderName)),
            line(s.t('detailTime'), formatDateTime(m.ts, s)),
            if (state != null) line(s.t('detailState'), state),
            line(s.t('reactionsTitle'), total == 0 ? s.t('noReactions') : '$total'),
          ],
        ),
      );
    },
  );
}
