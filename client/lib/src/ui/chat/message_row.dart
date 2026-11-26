import 'dart:math' as math;

import 'package:flutter/gestures.dart' show kSecondaryMouseButton;
import 'package:material_ui/material_ui.dart';

import '../../domain/models.dart';
import '../../domain/services.dart';
import '../components/avatar.dart';
import '../components/basics.dart';
import '../components/motion.dart';
import '../components/pressable.dart';
import '../l10n/strings.dart';
import '../state/thread_ui.dart';
import '../theme/tokens.dart';
import '../theme/z_icons.dart';
import '../util/format.dart';
import '../util/haptics.dart';
import 'message_actions.dart';
import 'message_content.dart';
import 'sticker_view.dart';

/// Callbacks of a message row. One stable instance per chat so cached rows
/// stay valid.
abstract class ChatActions {
  AccountSession get session;
  Directory get directory;
  String get selfUid;
  bool get isGroup;
  String get peerAvatarUrl;
  Set<AccountCapability> get caps;

  void openMenu(Message m, Offset globalPosition);
  void react(Message m, String icon);
  void openReactionPicker(Message m, Rect anchor);
  void showReactions(Message m);
  void reply(Message m);
  void retry(Message m);
  void deleteFailed(Message m, Offset globalPosition);
  void openMedia(Message m, int index);
  void openDoodle(Message m);
  void openAlbum(Message m, int index);
  void openPoll(Message m);
  void openLink(String url);
  void openUser(String uid, String name, String avatarUrl);
  void showUser(String uid, String name, String avatarUrl);
  void mentionUser(String uid, String name, String avatarUrl);
  Future<void> jumpToQuote(Quote quote);

  /// A message of this chat that is already loaded, by id or client id.
  Message? loadedMessage(String id);

  /// True once per message: the first row built for a message that arrived
  /// while the chat was open plays the entrance, rebuilt rows do not.
  bool claimEntrance(Message m);
}

@immutable
class RowFlags {
  const RowFlags({
    required this.first,
    required this.last,
    required this.showDay,
    required this.unreadDivider,
    required this.newestOwn,
    required this.highlight,
    required this.query,
    required this.entrance,
  });

  final bool first;
  final bool last;
  final bool showDay;
  final bool unreadDivider;
  final bool newestOwn;
  final bool highlight;
  final String query;

  /// The message arrived after the chat opened (not history or paging).
  final bool entrance;

  @override
  bool operator ==(Object other) =>
      other is RowFlags &&
      other.first == first &&
      other.last == last &&
      other.showDay == showDay &&
      other.unreadDivider == unreadDivider &&
      other.newestOwn == newestOwn &&
      other.highlight == highlight &&
      other.query == query;

  @override
  int get hashCode => Object.hash(first, last, showDay, unreadDivider, newestOwn, highlight, query);
}

String messageKeyOf(Message m) => m.cliId == null || m.cliId!.isEmpty ? m.id : m.cliId!;

class DayPill extends StatelessWidget {
  const DayPill({super.key, required this.text});

  final String text;

  @override
  Widget build(BuildContext context) {
    final z = context.z;
    return Center(
      child: Container(
        padding: const EdgeInsets.symmetric(
            horizontal: ZSpace.s12, vertical: ZSpace.s4),
        decoration: BoxDecoration(
            color: z.pillBg, borderRadius: BorderRadius.circular(ZRadius.pill)),
        child: Text(text, style: z.text.captionStrong.copyWith(color: z.onPill)),
      ),
    );
  }
}

class UnreadDivider extends StatelessWidget {
  const UnreadDivider({super.key});

  @override
  Widget build(BuildContext context) {
    final z = context.z;
    return Padding(
      key: const Key('unreadDivider'),
      padding: const EdgeInsets.symmetric(
          horizontal: ZSpace.s12, vertical: ZSpace.s8),
      child: Row(
        children: [
          Expanded(
              child: Container(
                  height: 1, color: z.brandText.withValues(alpha: 0.5))),
          Container(
            margin: const EdgeInsets.symmetric(horizontal: ZSpace.s8),
            padding:
                const EdgeInsets.symmetric(horizontal: ZSpace.s12, vertical: 2),
            decoration: BoxDecoration(
                color: z.eventPillBg,
                borderRadius: BorderRadius.circular(ZRadius.pill)),
            child: Text(context.tr('unreadDivider'),
                style: z.text.captionStrong.copyWith(color: z.brandText)),
          ),
          Expanded(
              child: Container(
                  height: 1, color: z.brandText.withValues(alpha: 0.5))),
        ],
      ),
    );
  }
}

class MessageRow extends StatefulWidget {
  const MessageRow({super.key, required this.message, required this.flags, required this.actions});

  final Message message;
  final RowFlags flags;
  final ChatActions actions;

  static int debugBuilds = 0;

  @override
  State<MessageRow> createState() => _MessageRowState();
}

class _MessageRowState extends State<MessageRow>
    with SingleTickerProviderStateMixin {
  bool _hover = false;

  /// True while keyboard focus is on the row or any of its actions.
  bool _focusWithin = false;
  late final FocusNode _rowFocus;
  double _swipe = 0;
  bool _replyThresholdHit = false;
  bool _longPressing = false;
  AnimationController? _entrance;
  final GlobalKey _reactKey = GlobalKey();

  /// Taps on the heart button, so each tap bumps it right away.
  int _heartTaps = 0;

  /// Built at least once without reactions, so a first reaction pops in.
  bool _hadNoReactions = false;

  Message get m => widget.message;
  ChatActions get a => widget.actions;

  @override
  void initState() {
    super.initState();
    _rowFocus = FocusNode(debugLabel: 'messageRow-${widget.message.id}');
    if (widget.flags.entrance && a.claimEntrance(m)) {
      _entrance = AnimationController(vsync: this, duration: ZMotion.enter)
        ..forward();
    }
  }

  @override
  void dispose() {
    _rowFocus.dispose();
    _entrance?.dispose();
    super.dispose();
  }

  void _onFocusChange(bool hasFocus) {
    if (_focusWithin != hasFocus) setState(() => _focusWithin = hasFocus);
  }

  bool get _actionable =>
      !m.recalled &&
      m.kind != MessageKind.system &&
      m.sendState == SendState.sent;

  Rect? _reactRect() {
    final box = _reactKey.currentContext?.findRenderObject();
    if (box is! RenderBox || !box.attached) return null;
    return box.localToGlobal(Offset.zero) & box.size;
  }

  @override
  Widget build(BuildContext context) {
    MessageRow.debugBuilds++;
    final z = context.z;
    final flags = widget.flags;
    final wide = LayoutScope.wideOf(context);
    final metrics = wide ? ChatMetrics.wideMetrics : ChatMetrics.compact;
    final children = <Widget>[
      if (flags.showDay)
        Padding(
          padding: EdgeInsets.symmetric(vertical: metrics.gapAroundSeparators / 2 + 2),
          child: DayPill(text: formatDay(m.ts, context.s)),
        ),
      if (flags.unreadDivider) const UnreadDivider(),
    ];
    if (m.kind == MessageKind.system && !m.recalled) {
      children.add(Padding(
        padding: EdgeInsets.symmetric(horizontal: ZSpace.s24, vertical: metrics.gapAroundSeparators / 2),
        child: Center(
          child: Container(
            constraints: const BoxConstraints(maxWidth: 520),
            padding: const EdgeInsets.symmetric(horizontal: ZSpace.s12, vertical: ZSpace.s4),
            decoration: BoxDecoration(color: z.eventPillBg, borderRadius: BorderRadius.circular(ZRadius.pill)),
            child: Text(m.text ?? '', textAlign: TextAlign.center, style: z.text.caption.copyWith(color: z.textSecondary)),
          ),
        ),
      ));
    } else {
      children.add(_bubbleRow(context, metrics));
    }
    Widget body = Column(mainAxisSize: MainAxisSize.min, crossAxisAlignment: CrossAxisAlignment.stretch, children: children);
    if (flags.highlight) {
      body = DecoratedBox(key: Key('highlight-${m.id}'), decoration: BoxDecoration(color: z.brandSubtle), child: body);
    }
    final entrance = _entrance;
    if (entrance != null) {
      final curved = CurvedAnimation(parent: entrance, curve: ZMotion.springCurve);
      body = FadeTransition(
        opacity: curved,
        child: ZMotion.reduced(context)
            ? body
            : AnimatedBuilder(
                animation: curved,
                builder: (context, child) => Transform.translate(
                  offset: Offset(0, ZMotion.rise * (1 - curved.value)),
                  child: Transform.scale(
                    scale: 0.97 + 0.03 * curved.value,
                    alignment: m.isSelf ? Alignment.bottomRight : Alignment.bottomLeft,
                    child: child,
                  ),
                ),
                child: body,
              ),
      );
    }
    return body;
  }

  Widget _bubbleRow(BuildContext context, ChatMetrics metrics) {
    final z = context.z;
    final flags = widget.flags;
    final self = m.isSelf;
    final wide = metrics.wide;
    final incomingAvatar = !self && (a.isGroup || wide);
    final senderName = a.isGroup && !self ? a.directory.nameOf(m.senderId, m.senderName) : m.senderName;
    final avatarUrl = a.isGroup ? a.directory.avatarOf(m.senderId) : a.peerAvatarUrl;
    final showAvatar = incomingAvatar && (wide ? flags.first : flags.last);
    final senderAvatarTarget = wide ? metrics.avatar : ZSizes.touchTarget;
    final senderAvatarHalo = (senderAvatarTarget - metrics.avatar) / 2;
    void openSender() => a.showUser(m.senderId, senderName, avatarUrl);
    void mentionSender() {
      ZHaptics.selection();
      a.mentionUser(m.senderId, senderName, avatarUrl);
    }

    return LayoutBuilder(
      builder: (context, constraints) {
        final available = constraints.maxWidth - metrics.sidePadding * 2 - (incomingAvatar ? metrics.avatarGutter : 0);
        final maxBubble = wide
            ? (available - metrics.outgoingReserve).clamp(160.0, 720.0)
            : (constraints.maxWidth * 0.72).clamp(140.0, ZSizes.bubbleMax);

        // A recall cross-fades the bubble content; long-pressing compresses
        // the bubble smoothly before the context menu springs open.
        final reduced = ZMotion.reduced(context);
        final bubble = AnimatedScale(
          scale: _longPressing && !reduced ? 0.96 : 1.0,
          duration: reduced ? Duration.zero : const Duration(milliseconds: 120),
          curve: ZMotion.springCurve,
          alignment: self ? Alignment.centerRight : Alignment.centerLeft,
          child: AnimatedSwitcher(
            duration: ZMotion.fast,
            layoutBuilder: (current, previous) => Stack(
              alignment: self ? Alignment.topRight : Alignment.topLeft,
              children: [...previous, if (current != null) current],
            ),
            child: _MessageBubble(
              key: ValueKey(m.recalled),
              message: m,
              flags: flags,
              actions: a,
              metrics: metrics,
              maxWidth: maxBubble,
              senderName: senderName,
            ),
          ),
        );

        final reactions = m.reactions.entries
            .where((e) => e.value.isNotEmpty)
            .toList()
          ..sort((x, y) => y.value.length.compareTo(x.value.length));
        final hasReactions = reactions.isNotEmpty && !m.recalled;
        final popReactions = hasReactions && _hadNoReactions;
        if (!hasReactions) _hadNoReactions = true;
        final reactionTotal =
            reactions.fold<int>(0, (n, e) => n + e.value.length);
        final own = [
          for (final e in m.reactions.entries)
            if (e.value.contains(a.selfUid)) e.key
        ];
        final canReact = a.caps.contains(AccountCapability.reactions);

        // On wide the heart stays mounted whenever the row could ever show
        // it, so the chips beside it never slide as it fades in and out on
        // hover; compact only mounts it for the last incoming row of a
        // group, where it is always visible.
        final heartRevealed =
            canReact && _actionable && (wide ? _hover : (!self && flags.last));
        final heartMounted = heartRevealed ||
            (wide && canReact && !m.recalled && m.kind != MessageKind.system);

        // The reaction slot under the bubble is reserved for every
        // non-system row whenever the account can react, on compact and
        // wide alike, so a first reaction, losing the last one, a recall or
        // a send finishing never changes the row height.
        final reserveReactionSlot =
            (canReact && m.kind != MessageKind.system) || hasReactions;
        Widget stacked = bubble;
        if (reserveReactionSlot) {
          final reactionPill = hasReactions
              ? ZPopIn(
                  enabled: popReactions,
                  alignment: self ? Alignment.centerRight : Alignment.centerLeft,
                  from: 0.6,
                  child: ZBump(
                    trigger: reactionTotal,
                    child: ZPressable(
                      key: Key('reactions-${m.id}'),
                      onTap: () {
                        ZHaptics.selection();
                        a.showReactions(m);
                      },
                      radius: ZRadius.pill,
                      pressScale: 0.92,
                      color: z.layer,
                      border: Border.all(color: z.border),
                      semanticLabel:
                          context.tr('reactionsLabel', [reactionTotal]),
                      child: Container(
                        constraints: const BoxConstraints(minHeight: 24),
                        padding: const EdgeInsets.symmetric(
                            horizontal: 7, vertical: 2),
                        child: Row(
                          mainAxisSize: MainAxisSize.min,
                          crossAxisAlignment: CrossAxisAlignment.center,
                          children: [
                            for (final e in reactions.take(3))
                              Padding(
                                padding: const EdgeInsets.only(right: 2),
                                child: ReactionGlyph(icon: e.key, size: 14),
                              ),
                            const SizedBox(width: 1),
                            Text(
                              '$reactionTotal',
                              textScaler: TextScaler.noScaling,
                              style: z.text.captionTabular.copyWith(
                                color: z.textSecondary,
                                height: 1.0,
                                leadingDistribution:
                                    TextLeadingDistribution.even,
                              ),
                            ),
                          ],
                        ),
                      ),
                    ),
                  ),
                )
              : null;

          final heartWidget = heartMounted
              ? ExcludeSemantics(
                  excluding: !heartRevealed,
                  child: ExcludeFocus(
                    excluding: !heartRevealed,
                    child: _HoverDrift(
                      visible: heartRevealed,
                      fromRight: self,
                      child: AnimatedOpacity(
                        duration: ZMotion.fast,
                        curve: heartRevealed
                            ? ZMotion.enterCurve
                            : ZMotion.exitCurve,
                        opacity: heartRevealed ? 1 : 0,
                        child: IgnorePointer(
                          ignoring: !heartRevealed,
                          child: ZPressable(
                            key: Key('reactButton-${m.id}'),
                            circle: true,
                            pressScale: 0.88,
                            color: z.layer,
                            border: Border.all(color: z.border),
                            semanticLabel: heartRevealed
                                ? context.tr('reactHeart')
                                : null,
                            tooltip: wide && heartRevealed
                                ? context.tr('react')
                                : null,
                            minSize: wide ? null : ZSizes.touchTarget,
                            onTap: () {
                              ZHaptics.light();
                              setState(() => _heartTaps++);
                              a.react(
                                  m,
                                  own.contains('/-heart') ? '' : '/-heart');
                            },
                            onLongPress: () {
                              ZHaptics.medium();
                              final rect = _reactRect();
                              if (rect != null) {
                                a.openReactionPicker(m, rect);
                              }
                            },
                            child: SizedBox(
                              key: _reactKey,
                              width: 24,
                              height: 24,
                              child: Center(
                                child: ZBump(
                                  trigger: _heartTaps,
                                  child: Icon(
                                    own.contains('/-heart')
                                        ? ZIcons.heartFill
                                        : ZIcons.heart,
                                    size: 13,
                                    color: own.contains('/-heart')
                                        ? z.danger
                                        : z.textTertiary,
                                  ),
                                ),
                              ),
                            ),
                          ),
                        ),
                      ),
                    ),
                  ),
                )
              : null;

          // On compact the 24x24 heart sits inside a 44x44 touch target
          // (+10 px invisible halo on every side). Offsetting its Positioned
          // box by -10 bottom / -6 right places the visible 24x24 circle dead
          // on bottom: 0, right: 4 -- aligned pixel-for-pixel with the
          // reaction pill beside it while keeping the full 44x44 iOS target.
          stacked = Stack(
            clipBehavior: Clip.none,
            children: [
              Padding(
                  padding: const EdgeInsets.only(bottom: 12), child: bubble),
              if (wide)
                Positioned(
                  right: ZSpace.s4,
                  bottom: 0,
                  child: Row(
                    mainAxisSize: MainAxisSize.min,
                    crossAxisAlignment: CrossAxisAlignment.center,
                    children: [
                      if (reactionPill != null) reactionPill,
                      if (heartWidget != null) ...[
                        const SizedBox(width: ZSpace.s4),
                        heartWidget,
                      ],
                    ],
                  ),
                )
              else ...[
                if (reactionPill != null)
                  Positioned(
                    right: heartMounted ? 32 : ZSpace.s4,
                    bottom: 0,
                    child: reactionPill,
                  ),
                if (heartWidget != null)
                  Positioned(
                    right: -6,
                    bottom: -10,
                    child: heartWidget,
                  ),
              ],
            ],
          );
        }

        final revealed = _hover || _focusWithin;
        // Tab reaches a row's actions right after the row itself, before the
        // bubble content, whichever side of the bubble the bar sits on.
        final hoverBar = wide && _actionable
            ? FocusTraversalOrder(
                order: const NumericFocusOrder(1),
                child: ExcludeFocus(
                  excluding: !revealed,
                  child: _HoverDrift(
                    visible: revealed,
                    fromRight: self,
                    child: AnimatedOpacity(
                      duration: ZMotion.fast,
                      curve: revealed ? ZMotion.enterCurve : ZMotion.exitCurve,
                      opacity: revealed ? 1 : 0,
                      child: IgnorePointer(
                        ignoring: !revealed,
                        child: Padding(
                          padding:
                              const EdgeInsets.symmetric(horizontal: ZSpace.s8),
                          child: Row(
                            key: Key('hoverBar-${m.id}'),
                            mainAxisSize: MainAxisSize.min,
                            children: [
                              if (a.caps
                                  .contains(AccountCapability.reactions)) ...[
                                Builder(
                                  builder: (buttonContext) => _HoverButton(
                                    key: Key('hoverReact-${m.id}'),
                                    icon: ZIcons.addReaction,
                                    label: context.tr('react'),
                                    onTap: () {
                                      final box = buttonContext
                                          .findRenderObject()! as RenderBox;
                                      a.openReactionPicker(
                                          m,
                                          box.localToGlobal(Offset.zero) &
                                              box.size);
                                    },
                                  ),
                                ),
                                const SizedBox(width: ZSpace.s4),
                              ],
                              _HoverButton(
                                  key: Key('hoverReply-${m.id}'),
                                  icon: ZIcons.reply,
                                  label: context.tr('reply'),
                                  onTap: () => a.reply(m)),
                              const SizedBox(width: ZSpace.s4),
                              Builder(
                                builder: (buttonContext) => _HoverButton(
                                  key: Key('hoverMore-${m.id}'),
                                  icon: ZIcons.moreHoriz,
                                  label: context.tr('more'),
                                  onTap: () {
                                    final box = buttonContext
                                        .findRenderObject()! as RenderBox;
                                    a.openMenu(
                                        m,
                                        box.localToGlobal(
                                            Offset(0, box.size.height)));
                                  },
                                ),
                              ),
                            ],
                          ),
                        ),
                      ),
                    ),
                  ),
                ),
              )
            : null;

        Widget column = Column(
          crossAxisAlignment:
              self ? CrossAxisAlignment.end : CrossAxisAlignment.start,
          mainAxisSize: MainAxisSize.min,
          children: [
            if (!wide && a.isGroup && !self && flags.first)
              Padding(
                padding: const EdgeInsets.only(left: ZSpace.s4, bottom: 2),
                child: Text(senderName,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: z.text.senderName.copyWith(color: z.textTertiary)),
              ),
            stacked,
            if (m.sendState == SendState.failed)
              _FailedRow(message: m, actions: a, wide: wide),
          ],
        );

        if (!wide && _actionable) {
          final direction = self ? -1.0 : 1.0;
          final reveal = (_swipe / 56).clamp(0.0, 1.0);
          column = GestureDetector(
            onHorizontalDragUpdate: (d) {
              final next = (_swipe + d.delta.dx * direction).clamp(0.0, 72.0);
              if (next >= 56 && !_replyThresholdHit) {
                _replyThresholdHit = true;
                ZHaptics.selection();
              } else if (next < 50 && _replyThresholdHit) {
                _replyThresholdHit = false;
              }
              setState(() => _swipe = next);
            },
            onHorizontalDragEnd: (_) {
              if (_swipe >= 56) a.reply(m);
              _replyThresholdHit = false;
              setState(() => _swipe = 0);
            },
            onHorizontalDragCancel: () {
              _replyThresholdHit = false;
              setState(() => _swipe = 0);
            },
            child: Stack(
              clipBehavior: Clip.none,
              children: [
                // The glyph sits in the gap the bubble uncovers, so it stays
                // hidden behind the bubble until the drag starts.
                Positioned.fill(
                  child: Align(
                    alignment:
                        self ? Alignment.centerRight : Alignment.centerLeft,
                    child: Padding(
                      padding: EdgeInsets.only(
                          left: self ? 0 : ZSpace.s16,
                          right: self ? ZSpace.s16 : 0),
                      child: Opacity(
                        key: Key('swipeReply-${m.id}'),
                        opacity: reveal,
                        child: Transform.translate(
                          offset:
                              Offset(direction * ZSpace.s8 * (1 - reveal), 0),
                          child: Container(
                            width: 30,
                            height: 30,
                            decoration: BoxDecoration(
                              color: z.layer.withValues(alpha: 0.9),
                              shape: BoxShape.circle,
                              boxShadow: z.shadowBubble,
                            ),
                            child: Icon(ZIcons.reply,
                                size: 17, color: z.brandText),
                          ),
                        ),
                      ),
                    ),
                  ),
                ),
                Transform.translate(
                    offset: Offset(_swipe * direction, 0), child: column),
              ],
            ),
          );
        }

        final focusable = wide && _actionable;
        final row = Row(
          mainAxisAlignment:
              self ? MainAxisAlignment.end : MainAxisAlignment.start,
          crossAxisAlignment:
              wide ? CrossAxisAlignment.start : CrossAxisAlignment.end,
          children: [
            // The row's focus stop is a slim marker at its leading corner, so
            // Tab enters a row before its hover actions, and the actions keep
            // their place beside the bubble on either side.
            if (focusable)
              FocusTraversalOrder(
                order: const NumericFocusOrder(0),
                child: Focus(
                  key: Key('messageFocus-${m.id}'),
                  focusNode: _rowFocus,
                  includeSemantics: false,
                  child: const SizedBox(width: 0, height: 28),
                ),
              ),
            if (incomingAvatar)
              SizedBox(
                width: metrics.avatarGutter,
                child: showAvatar
                    ? Align(
                        alignment: Alignment.centerLeft,
                        child: Padding(
                          padding: EdgeInsets.only(
                              bottom: !wide && reserveReactionSlot ? 12 : 0),
                          child: SizedBox(
                            width: metrics.avatar,
                            height: metrics.avatar,
                            child: OverflowBox(
                              minWidth: senderAvatarTarget,
                              maxWidth: senderAvatarTarget,
                              minHeight: senderAvatarTarget,
                              maxHeight: senderAvatarTarget,
                              child: ZPressable(
                                key: Key('senderAvatar-${m.id}'),
                                onTap: openSender,
                                onLongPress: a.isGroup ? mentionSender : null,
                                circle: true,
                                padding: EdgeInsets.all(senderAvatarHalo),
                                semanticLabel: senderName,
                                tooltip: senderName,
                                canRequestFocus: false,
                                child: ZAvatar(
                                    session: a.session,
                                    id: m.senderId,
                                    name: senderName,
                                    url: avatarUrl,
                                    size: metrics.avatar),
                              ),
                            ),
                          ),
                        ),
                      )
                    : null,
              ),
            if (self && hoverBar != null) hoverBar,
            Flexible(child: column),
            if (!self && hoverBar != null) hoverBar,
          ],
        );

        final summary =
            '${self ? context.tr('you') : senderName}: ${messageSummary(m, context.s)}, ${formatClock(m.ts)}';
        return Focus(
          canRequestFocus: false,
          skipTraversal: true,
          includeSemantics: false,
          onFocusChange: _onFocusChange,
          child: Semantics(
            container: true,
            label: summary,
            child: Listener(
              onPointerDown: (event) {
                if (event.buttons == kSecondaryMouseButton) {
                  a.openMenu(m, event.position);
                }
              },
              child: MouseRegion(
                onEnter: (_) => setState(() => _hover = true),
                onExit: (_) => setState(() => _hover = false),
                child: GestureDetector(
                  behavior: HitTestBehavior.translucent,
                  onLongPressStart: wide
                      ? null
                      : (d) {
                          ZHaptics.medium();
                          setState(() => _longPressing = true);
                          Future<void>.delayed(
                              const Duration(milliseconds: 140), () {
                            if (mounted && _longPressing) {
                              setState(() => _longPressing = false);
                            }
                          });
                          a.openMenu(m, d.globalPosition);
                        },
                  child: Padding(
                    padding: EdgeInsets.fromLTRB(
                      metrics.sidePadding,
                      flags.first
                          ? metrics.gapBetweenGroups
                          : metrics.gapInGroup,
                      metrics.sidePadding,
                      0,
                    ),
                    child: FocusTraversalGroup(
                        policy: OrderedTraversalPolicy(), child: row),
                  ),
                ),
              ),
            ),
          ),
        );
      },
    );
  }
}

/// Drifts the hover bar a few pixels in from the bubble side as it fades in.
/// Paint only, so hovering never changes the row layout; no drift when
/// motion is reduced.
class _HoverDrift extends StatelessWidget {
  const _HoverDrift({required this.visible, required this.fromRight, required this.child});

  static const double _distance = 6;

  final bool visible;
  final bool fromRight;
  final Widget child;

  @override
  Widget build(BuildContext context) {
    if (ZMotion.reduced(context)) return child;
    return TweenAnimationBuilder<double>(
      tween: Tween(end: visible ? 0 : _distance * (fromRight ? 1 : -1)),
      duration: ZMotion.fast,
      curve: visible ? ZMotion.enterCurve : ZMotion.exitCurve,
      builder: (context, dx, child) => Transform.translate(offset: Offset(dx, 0), child: child),
      child: child,
    );
  }
}

class _HoverButton extends StatelessWidget {
  const _HoverButton({super.key, required this.icon, required this.label, required this.onTap});

  final IconData icon;
  final String label;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final z = context.z;
    return ZPressable(
      onTap: onTap,
      circle: true,
      color: z.layer.withValues(alpha: z.dark ? 0.6 : 0.85),
      shadow: z.shadowBubble,
      tooltip: label,
      semanticLabel: label,
      child: SizedBox(
          width: 28,
          height: 28,
          child: Icon(icon, size: 16, color: z.textSecondary)),
    );
  }
}

class _MessageBubble extends StatelessWidget {
  const _MessageBubble(
      {super.key,
      required this.message,
      required this.flags,
      required this.actions,
      required this.metrics,
      required this.maxWidth,
      required this.senderName});

  final Message message;
  final RowFlags flags;
  final ChatActions actions;
  final ChatMetrics metrics;
  final double maxWidth;
  final String senderName;

  @override
  Widget build(BuildContext context) {
    final z = context.z;
    final m = message;
    final a = actions;
    final self = m.isSelf;
    final wide = metrics.wide;
    final text = (m.text ?? '').trim();
    final bodyStyle = wide ? z.text.bodyWide : z.text.body;
    final showName = wide && a.isGroup && !self && flags.first;
    final meta = _meta(context);

    Widget framed(Widget child, {bool showMeta = true}) {
      final r = Radius.circular(metrics.bubbleRadius);
      final tight = Radius.circular(metrics.groupedRadius);
      final radius = BorderRadius.only(
        topLeft: !self && !flags.first ? tight : r,
        bottomLeft: !self && !flags.last ? tight : r,
        topRight: self && !flags.first ? tight : r,
        bottomRight: self && !flags.last ? tight : r,
      );
      final quote = m.recalled ? null : m.quote;
      // Quotes of media carry no text; summarize the original when it is loaded.
      final quoted = quote == null || quote.text.isNotEmpty ? null : a.loadedMessage(quote.msgId);
      final quoteText = quoted == null ? quote?.text ?? '' : messageSummary(quoted, context.s);
      return Container(
        key: Key('bubble-${m.id}'),
        constraints: BoxConstraints(maxWidth: maxWidth, minWidth: 40),
        padding: metrics.bubblePadding,
        decoration: BoxDecoration(
          color: self ? z.bubbleOut : z.bubbleIn,
          borderRadius: radius,
          border: wide ? null : Border.all(color: self ? z.bubbleOutBorder : z.bubbleInBorder),
          boxShadow: wide ? z.shadowBubble : null,
        ),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          mainAxisSize: MainAxisSize.min,
          children: [
            if (showName)
              Padding(
                padding: const EdgeInsets.only(bottom: ZSpace.s4),
                child: ZPressable(
                  key: Key('senderName-${m.id}'),
                  onTap: () => a.showUser(m.senderId, senderName, a.directory.avatarOf(m.senderId)),
                  onLongPress: () {
                    ZHaptics.selection();
                    a.mentionUser(m.senderId, senderName, a.directory.avatarOf(m.senderId));
                  },
                  radius: ZRadius.tight,
                  padding: const EdgeInsets.symmetric(horizontal: ZSpace.s4, vertical: 1),
                  semanticLabel: senderName,
                  tooltip: senderName,
                  canRequestFocus: false,
                  child: Text(senderName, maxLines: 1, overflow: TextOverflow.ellipsis, style: z.text.senderName.copyWith(color: z.textTertiary)),
                ),
              ),
            if (quote != null)
              Padding(
                padding: const EdgeInsets.only(bottom: 6),
                child: QuoteBlock(
                  key: Key('quote-${m.id}'),
                  quote: quote,
                  text: quoteText,
                  outgoing: self,
                  name: quote.senderId == a.selfUid ? context.tr('you') : a.directory.nameOf(quote.senderId, quote.senderName),
                  onTap: () => a.jumpToQuote(quote),
                ),
              ),
            child,
            if (showMeta && meta != null) Padding(padding: const EdgeInsets.only(top: ZSpace.s4), child: meta),
          ],
        ),
      );
    }

    Widget bare(Widget child) {
      final pill = meta == null
          ? null
          : Container(
              margin: const EdgeInsets.only(top: ZSpace.s4),
              padding: const EdgeInsets.symmetric(horizontal: ZSpace.s8, vertical: 2),
              decoration: BoxDecoration(color: z.pillBg, borderRadius: BorderRadius.circular(ZRadius.card)),
              child: _meta(context, onPill: true),
            );
      return Column(
        key: Key('bubble-${m.id}'),
        crossAxisAlignment: self ? CrossAxisAlignment.end : CrossAxisAlignment.start,
        mainAxisSize: MainAxisSize.min,
        children: [
          if (showName)
            Container(
              margin: const EdgeInsets.only(bottom: ZSpace.s4),
              padding: const EdgeInsets.symmetric(horizontal: ZSpace.s8, vertical: 1),
              decoration: BoxDecoration(color: z.eventPillBg, borderRadius: BorderRadius.circular(ZRadius.pill)),
              child: ZPressable(
                key: Key('senderName-${m.id}'),
                onTap: () => a.showUser(m.senderId, senderName, a.directory.avatarOf(m.senderId)),
                onLongPress: () {
                  ZHaptics.selection();
                  a.mentionUser(m.senderId, senderName, a.directory.avatarOf(m.senderId));
                },
                radius: ZRadius.tight,
                padding: const EdgeInsets.symmetric(horizontal: ZSpace.s4, vertical: 1),
                semanticLabel: senderName,
                tooltip: senderName,
                canRequestFocus: false,
                child: Text(senderName, maxLines: 1, overflow: TextOverflow.ellipsis, style: z.text.senderName.copyWith(color: z.textSecondary)),
              ),
            ),
          child,
          if (pill != null) pill,
        ],
      );
    }

    Widget textBody(String value) => MessageText(
          text: value,
          mentions: m.mentions,
          styles: m.styles,
          style: bodyStyle,
          selectable: wide,
          onOpenLink: a.openLink,
          onOpenMention: (mention) {
            if (mention.uid == '-1') return;
            final name = a.directory.nameOf(mention.uid);
            a.showUser(mention.uid, name, a.directory.avatarOf(mention.uid));
          },
          query: flags.query,
        );

    if (m.recalled) {
      return framed(Text(context.tr('recalled'), style: bodyStyle.copyWith(fontStyle: FontStyle.italic, color: z.textTertiary)));
    }
    if (isUndecryptable(m)) {
      return framed(Row(
        key: Key('undecryptable-${m.id}'),
        mainAxisSize: MainAxisSize.min,
        children: [
          Icon(ZIcons.lock, size: 18, color: z.textTertiary),
          const SizedBox(width: 6),
          Flexible(child: Text(context.tr('undecryptable'), style: bodyStyle.copyWith(color: z.textTertiary))),
        ],
      ));
    }

    switch (m.kind) {
      case MessageKind.sticker:
        final sticker = m.sticker;
        final resolvedUrl = sticker?.resolvedUrl;
        return bare(
          sticker == null || resolvedUrl == null || resolvedUrl.isEmpty
              ? Text(context.tr('previewSticker'), style: bodyStyle.copyWith(color: z.textTertiary))
              : ClipRRect(
                  borderRadius: BorderRadius.circular(ZRadius.tight),
                  child: ZStickerView(
                    session: a.session,
                    sticker: sticker,
                    size: 130,
                    animate: true,
                    semanticLabel: context.tr('previewSticker'),
                    placeholder: const ZSkeleton(width: 130, height: 130, radius: ZRadius.tight),
                    errorBuilder: (_) => SizedBox(
                      width: 130,
                      height: 130,
                      child: Center(
                          child: Text(context.tr('previewSticker'),
                              style: z.text.caption)),
                    ),
                  ),
                ),
        );
      case MessageKind.image:
      case MessageKind.gif:
      case MessageKind.video:
        if (m.attachments.isEmpty) {
          return framed(Text(
              context.tr(m.kind == MessageKind.video
                  ? 'previewVideo'
                  : 'previewImage'),
              style: bodyStyle));
        }
        final grid = MediaGrid(
            session: a.session,
            message: m,
            maxWidth: maxWidth,
            onOpen: (i) => a.openMedia(m, i));
        if (text.isEmpty) return bare(grid);
        return Column(
          key: Key('media-${m.id}'),
          crossAxisAlignment:
              self ? CrossAxisAlignment.end : CrossAxisAlignment.start,
          mainAxisSize: MainAxisSize.min,
          children: [
            grid,
            const SizedBox(height: 2),
            framed(textBody(text)),
          ],
        );
      case MessageKind.file:
        return framed(Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          mainAxisSize: MainAxisSize.min,
          children: [
            for (final att in m.attachments)
              FileCard(session: a.session, attachment: att),
            if (m.attachments.isEmpty)
              Text(context.tr('previewFile'), style: bodyStyle),
            if (text.isNotEmpty)
              Padding(
                  padding: const EdgeInsets.only(top: 6),
                  child: textBody(text)),
          ],
        ));
      case MessageKind.voice:
        return framed(VoiceBubble(session: a.session, message: m));
      case MessageKind.link:
        final preview = m.linkPreview;
        return framed(Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          mainAxisSize: MainAxisSize.min,
          children: [
            if (text.isNotEmpty)
              Padding(
                  padding: const EdgeInsets.only(bottom: ZSpace.s8),
                  child: textBody(text)),
            for (final att in m.attachments)
              LinkCard(
                  session: a.session,
                  attachment: att,
                  onTap: () => a.openLink(att.url)),
            if (m.attachments.isEmpty && preview != null)
              LinkPreviewBubble(
                key: Key('linkPreview-${m.id}'),
                session: a.session,
                preview: preview,
                onOpen: () => a.openLink(
                    preview.href.isNotEmpty ? preview.href : preview.srcUrl),
              ),
          ],
        ));
      case MessageKind.card:
        final card = m.card;
        if (card == null) {
          return framed(Text(context.tr('unsupportedMessage'),
              style: bodyStyle.copyWith(color: z.textTertiary)));
        }
        return framed(ContactCardBubble(
          key: Key('contactCard-${m.id}'),
          session: a.session,
          card: card,
          onOpen: () => a.openUser(card.uid, card.displayName, card.avatarUrl),
        ));
      case MessageKind.bankCard:
        final card = m.bankCard;
        if (card == null) {
          return framed(Text(context.tr('unsupportedMessage'),
              style: bodyStyle.copyWith(color: z.textTertiary)));
        }
        return framed(BankCardBubble(
            key: Key('bankCard-${m.id}'),
            session: a.session,
            card: card,
            messageId: m.id));
      case MessageKind.location:
        final location = m.location;
        if (location == null) {
          return framed(Text(context.tr('unsupportedMessage'),
              style: bodyStyle.copyWith(color: z.textTertiary)));
        }
        return framed(LocationBubble(
          key: Key('location-${m.id}'),
          location: location,
          messageId: m.id,
          onOpen: () => a.openLink(locationMapUrl(location)),
        ));
      case MessageKind.poll:
        final poll = m.poll;
        if (poll == null) {
          return framed(Text(context.tr('unsupportedMessage'),
              style: bodyStyle.copyWith(color: z.textTertiary)));
        }
        return framed(PollBubble(
          key: Key('poll-${m.id}'),
          poll: poll,
          onOpen: poll.id != null && a.caps.contains(AccountCapability.polls)
              ? () => a.openPoll(m)
              : null,
        ));
      case MessageKind.note:
        final note = m.note;
        if (note == null) {
          return framed(Text(context.tr('unsupportedMessage'),
              style: bodyStyle.copyWith(color: z.textTertiary)));
        }
        return framed(NoteBubble(key: Key('note-${m.id}'), note: note));
      case MessageKind.reminder:
        final reminder = m.reminder;
        if (reminder == null) {
          return framed(Text(context.tr('unsupportedMessage'),
              style: bodyStyle.copyWith(color: z.textTertiary)));
        }
        return framed(
            ReminderBubble(key: Key('reminder-${m.id}'), reminder: reminder));
      case MessageKind.call:
        final call = m.callLog;
        if (call == null) {
          return framed(Text(context.tr('unsupportedMessage'),
              style: bodyStyle.copyWith(color: z.textTertiary)));
        }
        return framed(CallBubble(key: Key('call-${m.id}'), call: call));
      case MessageKind.doodle:
        final doodle = m.doodle;
        if (doodle == null) {
          return framed(Text(context.tr('unsupportedMessage'),
              style: bodyStyle.copyWith(color: z.textTertiary)));
        }
        return bare(DoodleBubble(
          key: Key('doodle-${m.id}'),
          session: a.session,
          doodle: doodle,
          onOpen: () => a.openDoodle(m),
        ));
      case MessageKind.album:
        final album = m.album;
        if (album == null) {
          return framed(Text(context.tr('unsupportedMessage'),
              style: bodyStyle.copyWith(color: z.textTertiary)));
        }
        return bare(AlbumBubble(
          key: Key('album-${m.id}'),
          session: a.session,
          album: album,
          messageId: m.id,
          onOpen: (index) => a.openAlbum(m, index),
        ));
      case MessageKind.todo:
        final todo = m.todo;
        if (todo == null) {
          return framed(Text(context.tr('unsupportedMessage'),
              style: bodyStyle.copyWith(color: z.textTertiary)));
        }
        return framed(TodoBubble(key: Key('todo-${m.id}'), todo: todo));
      case MessageKind.other:
        return framed(Text(
            text.isEmpty ? context.tr('unsupportedMessage') : text,
            style: bodyStyle.copyWith(
                color: text.isEmpty ? z.textTertiary : null)));
      case MessageKind.text:
      case MessageKind.system:
        if (m.quote == null && isEmojiOnly(text)) {
          return bare(Text(text,
              key: Key('emojiOnly-${m.id}'), style: z.text.emojiLarge));
        }
        return framed(textBody(text));
    }
  }

  /// Time, and for own messages the state, shown in the last bubble of a group.
  Widget? _meta(BuildContext context, {bool onPill = false}) {
    final z = context.z;
    final m = message;
    if (!flags.last && m.sendState == SendState.sent) return null;
    final color =
        onPill ? z.onPill : (m.isSelf ? z.bubbleMetaOut : z.bubbleMetaIn);
    final style = z.text.caption.copyWith(color: color);
    String? state;
    IconData? glyph;
    if (m.isSelf && !m.recalled) {
      if (m.sendState == SendState.sending) {
        glyph = ZIcons.schedule;
        state = context.tr('sending');
      } else if (m.sendState == SendState.sent && flags.newestOwn && actions.caps.contains(AccountCapability.deliveryState)) {
        state = context.tr(switch (m.deliveryState) {
          DeliveryState.sent => 'stateSent',
          DeliveryState.delivered => 'stateDelivered',
          DeliveryState.seen => 'stateSeen',
        });
      }
    }
    final Widget? status = glyph != null
        ? Padding(
            key: const ValueKey('sending'),
            padding: const EdgeInsets.only(left: ZSpace.s4),
            child: Icon(glyph, size: 12, color: color, semanticLabel: state),
          )
        : state != null
            ? Padding(
                key: ValueKey(state),
                padding: const EdgeInsets.only(left: 6),
                child: Text(state, key: Key('state-${m.id}'), style: style),
              )
            : null;
    final urgency = m.urgency;
    final urgencyGlyph = switch (urgency) {
      MessageUrgency.important => ZIcons.priorityHigh,
      MessageUrgency.urgent => ZIcons.bolt,
      _ => null,
    };
    final urgencyLabel = switch (urgency) {
      MessageUrgency.important => context.tr('urgencyImportant'),
      MessageUrgency.urgent => context.tr('urgencyUrgent'),
      _ => null,
    };
    final ttl = m.ttl ?? 0;
    final ttlLabel = ttl > 0
        ? context.tr('messageTtlIndicator', [messageTtlLabel(ttl, context.s)])
        : null;
    final indicatorColor = onPill ? z.onPill : color;
    // Own messages move from sending to sent to seen. The status keeps a slot
    // as wide as the longest label in either language, so the meta, and with
    // it a short bubble, never resizes; only the status cross-fades inside it.
    final reserveStatus = m.isSelf &&
        !m.recalled &&
        (m.sendState == SendState.sending ||
            (m.sendState == SendState.sent && flags.newestOwn));
    var statusWidth = 12.0 + ZSpace.s4;
    if (reserveStatus &&
        actions.caps.contains(AccountCapability.deliveryState)) {
      for (final key in const ['stateSent', 'stateDelivered', 'stateSeen']) {
        for (final table in const [S.vi, S.en]) {
          statusWidth = math.max(
              statusWidth, _labelWidth(context, style, table[key]!) + 6);
        }
      }
    }
    return Row(
      key: Key('meta-${m.id}'),
      mainAxisSize: MainAxisSize.min,
      children: [
        if (urgencyGlyph != null && urgencyLabel != null)
          Padding(
            key: Key('urgency-${m.id}'),
            padding: const EdgeInsets.only(right: ZSpace.s4),
            child: Icon(
              urgencyGlyph,
              size: 12,
              color: onPill
                  ? z.onPill
                  : (urgency == MessageUrgency.urgent ? z.danger : z.warning),
              semanticLabel: urgencyLabel,
            ),
          ),
        if (ttlLabel != null)
          Padding(
            key: Key('ttl-${m.id}'),
            padding: const EdgeInsets.only(right: ZSpace.s4),
            child: Icon(ZIcons.timer,
                size: 12, color: indicatorColor, semanticLabel: ttlLabel),
          ),
        Text(formatClock(m.ts), textScaler: TextScaler.noScaling, style: style),
        if (reserveStatus)
          _StatusSlot(
              key: Key('status-${m.id}'), width: statusWidth, current: status)
        else if (status != null)
          status,
      ],
    );
  }

  /// Width of [text] laid out in the meta [style], matching what [Text] would
  /// measure with the ambient default style and text scale.
  double _labelWidth(BuildContext context, TextStyle style, String text) {
    final base =
        style.inherit ? DefaultTextStyle.of(context).style.merge(style) : style;
    final painter = TextPainter(
      text: TextSpan(text: text, style: base),
      textDirection: Directionality.of(context),
      textScaler: MediaQuery.textScalerOf(context),
      maxLines: 1,
    )..layout();
    final width = painter.width;
    painter.dispose();
    return width;
  }
}

/// Fixed room for the sending/delivery status. Its width is the longest label
/// the meta can show, so a state change only cross-fades the icon or label and
/// never resizes the meta or a short bubble.
class _StatusSlot extends StatelessWidget {
  const _StatusSlot({super.key, required this.width, required this.current});

  final double width;
  final Widget? current;

  @override
  Widget build(BuildContext context) {
    return SizedBox(
      width: width,
      child: AnimatedSwitcher(
        duration: ZMotion.fast,
        layoutBuilder: (current, previous) => Stack(
          alignment: Alignment.centerLeft,
          children: [...previous, if (current != null) current],
        ),
        child: current ?? const SizedBox.shrink(),
      ),
    );
  }
}

class _FailedRow extends StatelessWidget {
  const _FailedRow(
      {required this.message, required this.actions, required this.wide});

  final Message message;
  final ChatActions actions;
  final bool wide;

  @override
  Widget build(BuildContext context) {
    final z = context.z;
    final m = message;
    final code = m.sendErrorCode;
    final noRetry = code == 'window_expired' || code == 'not_supported';
    final known = code == 'window_expired' ||
        code == 'quota_exceeded' ||
        code == 'rate_limited' ||
        code == 'not_supported';
    final text = switch (code) {
      'window_expired' => context.tr('sendErrWindow'),
      'quota_exceeded' => context.tr('sendErrQuota'),
      'rate_limited' => context.tr('sendErrRate'),
      'not_supported' => context.tr('sendErrUnsupported'),
      _ => context.tr('sendFailedRetry'),
    };
    final shown = !known || noRetry ? text : '$text ${context.tr('retry')}';
    return ZPressable(
      key: Key('retry-${m.id}'),
      onTap: noRetry ? null : () => actions.retry(m),
      onLongPressStart: (pos) => actions.deleteFailed(m, pos),
      radius: ZRadius.tight,
      semanticLabel: shown,
      minSize: wide ? null : ZSizes.touchTarget,
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: ZSpace.s4, vertical: 2),
        child: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(ZIcons.error, size: 14, color: z.danger, fill: 1),
            const SizedBox(width: ZSpace.s4),
            Flexible(child: Text(shown, style: z.text.caption.copyWith(color: z.danger))),
          ],
        ),
      ),
    );
  }
}
