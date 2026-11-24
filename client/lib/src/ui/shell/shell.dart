import 'package:material_ui/material_ui.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../domain/models.dart';
import '../../domain/services.dart';
import '../chat/chat_screen.dart';
import '../components/avatar.dart';
import '../components/basics.dart';
import '../components/connection_banner.dart';
import '../components/motion.dart';
import '../components/overlays.dart';
import '../components/pressable.dart';
import '../contacts/contacts_pane.dart';
import '../info/info_pane.dart';
import '../l10n/strings.dart';
import '../me/oa_dialog.dart';
import '../me/me_pane.dart';
import '../state/app_state.dart';
import '../theme/tokens.dart';
import '../theme/z_icons.dart';
import '../threads/threads_pane.dart';
import '../util/format.dart';
import '../util/haptics.dart';

class HomeShell extends ConsumerStatefulWidget {
  const HomeShell({super.key, required this.link});

  final ServerLink link;

  @override
  ConsumerState<HomeShell> createState() => _HomeShellState();
}

class _HomeShellState extends ConsumerState<HomeShell> {
  final Map<String, GlobalKey> _chatKeys = {};

  @override
  void initState() {
    super.initState();
    HardwareKeyboard.instance.addHandler(_onKey);
  }

  @override
  void dispose() {
    HardwareKeyboard.instance.removeHandler(_onKey);
    super.dispose();
  }

  GlobalKey _chatKey(OpenThread thread) {
    final existing = _chatKeys[thread.key];
    if (existing != null) return existing;
    _chatKeys.clear();
    return _chatKeys[thread.key] = GlobalKey(debugLabel: 'chat ${thread.key}');
  }

  bool _onKey(KeyEvent event) {
    if (event is! KeyDownEvent || !mounted) return false;
    if (!(ModalRoute.of(context)?.isCurrent ?? true)) return false;
    final keyboard = HardwareKeyboard.instance;
    final command = keyboard.isControlPressed || keyboard.isMetaPressed;
    final key = event.logicalKey;
    if (command && key == LogicalKeyboardKey.keyK) {
      ref.read(homeTabProvider.notifier).state = HomeTab.messages;
      if (LayoutScope.of(context) == LayoutClass.compact) ref.read(openThreadProvider.notifier).state = null;
      ref.read(searchFocusRequestProvider.notifier).state++;
      return true;
    }
    const digits = [
      LogicalKeyboardKey.digit1,
      LogicalKeyboardKey.digit2,
      LogicalKeyboardKey.digit3,
      LogicalKeyboardKey.digit4,
      LogicalKeyboardKey.digit5,
      LogicalKeyboardKey.digit6,
      LogicalKeyboardKey.digit7,
      LogicalKeyboardKey.digit8,
      LogicalKeyboardKey.digit9,
    ];
    final index = digits.indexOf(key);
    if (command && index >= 0) {
      final accounts = ref.read(manifestProvider)?.accounts ?? const <AccountSummary>[];
      if (index < accounts.length) switchAccount(ref, accounts[index].slot);
      return true;
    }
    if (key == LogicalKeyboardKey.escape) {
      final focus = FocusManager.instance.primaryFocus;
      if (focus?.context?.findAncestorWidgetOfExactType<EditableText>() != null) return false;
      if (ref.read(infoPaneOpenProvider)) {
        ref.read(infoPaneOpenProvider.notifier).state = false;
        return true;
      }
      if (ref.read(openThreadProvider) != null) {
        ref.read(openThreadProvider.notifier).state = null;
        return true;
      }
    }
    return false;
  }

  @override
  Widget build(BuildContext context) {
    final z = context.z;
    final manifest = ref.watch(manifestProvider);
    final layout = LayoutScope.of(context);
    if (manifest == null) {
      return Scaffold(
        key: const Key('shellLoading'),
        backgroundColor: z.layer,
        body: SafeArea(
          child: Column(
            children: [
              const ConnectionBanner(),
              Expanded(child: ZSkeletonList(label: context.tr('loadingServer'))),
              Padding(
                padding: const EdgeInsets.all(ZSpace.s16),
                child: ZButton(
                  label: context.tr('unpair'),
                  variant: ZButtonVariant.destructiveText,
                  onPressed: () => ref.read(zalosAppProvider).unpair(),
                ),
              ),
            ],
          ),
        ),
      );
    }
    final thread = ref.watch(visibleThreadProvider);
    final session = ref.watch(activeSessionProvider);
    final account = ref.watch(activeAccountProvider);
    final chat = thread == null || session == null || account == null
        ? null
        : ChatScreen(key: _chatKey(thread), session: session, thread: thread, account: account);
    return layout == LayoutClass.compact
        ? _CompactShell(link: widget.link, chat: chat, thread: thread, session: session)
        : _WideShell(link: widget.link, chat: chat, thread: thread, session: session, layout: layout);
  }
}

Widget _tabBody(HomeTab tab, ServerLink link) => ZCrossFade(
      child: KeyedSubtree(
        key: ValueKey(tab),
        child: switch (tab) {
          HomeTab.messages => ThreadsPane(link: link),
          HomeTab.contacts => ContactsPane(link: link),
          HomeTab.me => MePane(link: link),
        },
      ),
    );

class _CompactShell extends ConsumerWidget {
  const _CompactShell({required this.link, required this.chat, required this.thread, required this.session});

  final ServerLink link;
  final Widget? chat;
  final OpenThread? thread;
  final AccountSession? session;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final z = context.z;
    final tab = ref.watch(homeTabProvider);
    final infoOpen = ref.watch(infoPaneOpenProvider) && thread != null && session != null;
    return PopScope(
      canPop: thread == null,
      onPopInvokedWithResult: (didPop, _) {
        if (didPop) return;
        if (ref.read(infoPaneOpenProvider)) {
          ref.read(infoPaneOpenProvider.notifier).state = false;
        } else {
          closeThread(ref);
        }
      },
      child: Scaffold(
        key: const Key('compactShell'),
        backgroundColor: z.layer,
        resizeToAvoidBottomInset: true,
        body: Stack(
          fit: StackFit.expand,
          children: [
            ExcludeFocus(
              excluding: thread != null,
              child: Column(
                children: [
                  Expanded(child: _tabBody(tab, link)),
                  _BottomNav(tab: tab),
                ],
              ),
            ),
            _SlideLayer(
              onPop: thread == null ? null : () => closeThread(ref),
              child: chat,
            ),
            _SlideLayer(
              onPop: infoOpen
                  ? () => ref.read(infoPaneOpenProvider.notifier).state = false
                  : null,
              child: infoOpen
                  ? InfoPane(
                      key: ValueKey('info-${thread!.key}'),
                      session: session!,
                      thread: thread!,
                      onClose: () =>
                          ref.read(infoPaneOpenProvider.notifier).state = false,
                    )
                  : null,
            ),
          ],
        ),
      ),
    );
  }
}

/// Slides its child in from the right with a soft edge shadow, supports
/// continuous 1:1 interactive left-edge swipe-back without ever snapping or
/// flashing on release, and falls back to a plain fade when motion is reduced.
class _SlideLayer extends StatefulWidget {
  const _SlideLayer({required this.child, this.onPop});

  final Widget? child;
  final VoidCallback? onPop;

  @override
  State<_SlideLayer> createState() => _SlideLayerState();
}

class _SlideLayerState extends State<_SlideLayer>
    with SingleTickerProviderStateMixin {
  late final AnimationController _controller;
  Widget? _last;
  bool _dragging = false;
  bool _closing = false;
  bool _crossedThreshold = false;

  @override
  void initState() {
    super.initState();
    _last = widget.child;
    _controller = AnimationController(
      vsync: this,
      duration: ZMotion.medium,
      reverseDuration: ZMotion.exit,
      value: widget.child == null ? 0.0 : 1.0,
    )..addStatusListener((status) {
        if ((status == AnimationStatus.dismissed ||
                (status == AnimationStatus.completed &&
                    _controller.value == 0.0)) &&
            !_dragging &&
            widget.child == null &&
            mounted) {
          setState(() {
            _last = null;
            _closing = false;
          });
        }
      });
  }

  @override
  void didUpdateWidget(_SlideLayer old) {
    super.didUpdateWidget(old);
    final reduced = ZMotion.reduced(context);
    if (widget.child != null) {
      _last = widget.child;
      if (old.child == null || _closing) {
        _closing = false;
        _dragging = false;
        if (reduced) {
          _controller.value = 1.0;
        } else {
          _controller.animateTo(
            1.0,
            duration: ZMotion.medium,
            curve: ZMotion.springCurve,
          );
        }
      }
    } else if (old.child != null) {
      if (_closing) {
        // Already animating smoothly out from the swipe release position.
        return;
      }
      _closing = true;
      if (reduced) {
        _controller.value = 0.0;
        _last = null;
        _closing = false;
      } else {
        _controller.animateBack(
          0.0,
          duration: ZMotion.exit,
          curve: ZMotion.exitCurve,
        );
      }
    }
  }

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  void _onDragStart(DragStartDetails _) {
    _controller.stop();
    _dragging = true;
    _crossedThreshold = false;
  }

  void _onDragUpdate(DragUpdateDetails d, double width) {
    if (!_dragging || width <= 0) return;
    final next = (_controller.value - d.delta.dx / width).clamp(0.0, 1.0);
    _controller.value = next;
    if (next < 0.70 && !_crossedThreshold) {
      _crossedThreshold = true;
      ZHaptics.selection();
    } else if (next > 0.72 && _crossedThreshold) {
      _crossedThreshold = false;
    }
  }

  void _onDragEnd(DragEndDetails d) {
    if (!_dragging) return;
    _dragging = false;
    final velocity = d.primaryVelocity ?? 0;
    final shouldPop = _controller.value < 0.70 || velocity > 650;
    if (shouldPop) {
      if (!_crossedThreshold) ZHaptics.light();
      _closing = true;
      final remainingMs = (170 * _controller.value).round().clamp(50, 170);
      _controller.animateBack(
        0.0,
        duration: Duration(milliseconds: remainingMs),
        curve: Curves.easeOutCubic,
      );
      widget.onPop?.call();
    } else {
      final remainingMs =
          (170 * (1.0 - _controller.value)).round().clamp(50, 170);
      _controller.animateTo(
        1.0,
        duration: Duration(milliseconds: remainingMs),
        curve: ZMotion.springCurve,
      );
    }
  }

  void _onDragCancel() {
    if (!_dragging) return;
    _dragging = false;
    final remainingMs = (170 * (1.0 - _controller.value)).round().clamp(50, 170);
    _controller.animateTo(
      1.0,
      duration: Duration(milliseconds: remainingMs),
      curve: ZMotion.springCurve,
    );
  }

  @override
  Widget build(BuildContext context) {
    final child = widget.child ?? _last;
    if (child == null) return const SizedBox.shrink();
    final z = context.z;
    final reduced = ZMotion.reduced(context);
    final exiting = widget.child == null;
    final guarded = IgnorePointer(
      ignoring: exiting,
      child: ExcludeFocus(
        excluding: exiting,
        child: ExcludeSemantics(excluding: exiting, child: child),
      ),
    );
    if (reduced) {
      return FadeTransition(
        opacity: _controller,
        child: Material(color: z.layer, child: guarded),
      );
    }
    final width = MediaQuery.sizeOf(context).width;
    return AnimatedBuilder(
      animation: _controller,
      child: Material(color: z.layer, child: guarded),
      builder: (context, body) {
        final v = _controller.value.clamp(0.0, 1.0);
        final slide = FractionalTranslation(
          translation: Offset(1.0 - v, 0),
          child: DecoratedBox(
            decoration: BoxDecoration(
              color: z.layer,
              boxShadow: v > 0.01 ? z.shadowEdge : null,
            ),
            child: body,
          ),
        );
        return Stack(
          fit: StackFit.expand,
          children: [
            if (v > 0.005)
              IgnorePointer(
                child: ColoredBox(
                  color: z.scrim.withValues(alpha: (z.dark ? 0.28 : 0.14) * v),
                ),
              ),
            slide,
            if (widget.onPop != null && !exiting)
              Positioned(
                left: 0,
                top: 0,
                bottom: 0,
                width: 28,
                child: GestureDetector(
                  behavior: HitTestBehavior.translucent,
                  onHorizontalDragStart: _onDragStart,
                  onHorizontalDragUpdate: (d) => _onDragUpdate(d, width),
                  onHorizontalDragEnd: _onDragEnd,
                  onHorizontalDragCancel: _onDragCancel,
                ),
              ),
          ],
        );
      },
    );
  }
}

class _BottomNav extends ConsumerWidget {
  const _BottomNav({required this.tab});

  final HomeTab tab;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final z = context.z;
    final unread =
        ref.watch(activeAccountProvider.select((a) => a?.unread ?? 0));
    final pending =
        ref.watch(isAdminProvider) && ref.watch(vaultRequestsProvider).isNotEmpty;
    final bottomInset = MediaQuery.paddingOf(context).bottom;
    final bottomPad =
        bottomInset > 0 ? (bottomInset - 14).clamp(10.0, 22.0) : 8.0;

    void select(HomeTab value) {
      if (tab == value) return;
      ZHaptics.selection();
      ref.read(homeTabProvider.notifier).state = value;
    }

    return ColoredBox(
      color: tab == HomeTab.me ? z.layerSubtle : z.layer,
      child: Padding(
        padding: EdgeInsets.fromLTRB(ZSpace.s16, ZSpace.s4, ZSpace.s16, bottomPad),
        child: Container(
          key: const Key('bottomNav'),
          height: ZSizes.bottomNav,
          padding: const EdgeInsets.symmetric(horizontal: ZSpace.s8),
          decoration: BoxDecoration(
            color: z.navBarBg,
            borderRadius: BorderRadius.circular(ZRadius.navCapsule),
            border: Border.all(color: z.navBarBorder, width: 1),
            boxShadow: z.shadowNav,
          ),
          child: Row(
            children: [
              _BottomNavItem(
                key: const Key('tab-messages'),
                icon: ZIcons.chat,
                activeIcon: ZIcons.chatFill,
                label: context.tr('tabMessages'),
                selected: tab == HomeTab.messages,
                onTap: () => select(HomeTab.messages),
                badge: unread > 0
                    ? ZBadge(count: unread, outline: z.navBarBg)
                    : null,
              ),
              _BottomNavItem(
                key: const Key('tab-contacts'),
                icon: ZIcons.contacts,
                activeIcon: ZIcons.contactsFill,
                label: context.tr('tabContacts'),
                selected: tab == HomeTab.contacts,
                onTap: () => select(HomeTab.contacts),
              ),
              _BottomNavItem(
                key: const Key('tab-me'),
                icon: ZIcons.user,
                activeIcon: ZIcons.userFill,
                label: context.tr('tabMe'),
                selected: tab == HomeTab.me,
                onTap: () => select(HomeTab.me),
                badge: pending
                    ? ZBadge(
                        key: const Key('vaultDot'),
                        count: 0,
                        dot: true,
                        outline: z.navBarBg,
                      )
                    : null,
                badgeIsDot: true,
              ),
            ],
          ),
        ),
      ),
    );
  }
}

class _BottomNavItem extends StatelessWidget {
  const _BottomNavItem({
    super.key,
    required this.icon,
    required this.activeIcon,
    required this.label,
    required this.selected,
    required this.onTap,
    this.badge,
    this.badgeIsDot = false,
  });

  final IconData icon;
  final IconData activeIcon;
  final String label;
  final bool selected;
  final VoidCallback onTap;
  final Widget? badge;
  final bool badgeIsDot;

  @override
  Widget build(BuildContext context) {
    final z = context.z;
    final reduced = ZMotion.reduced(context);
    final color = selected ? z.brandText : z.textTertiary;
    final labelStyle = (selected ? z.text.navLabelSelected : z.text.navLabel)
        .copyWith(color: color);

    return Expanded(
      child: ZPressable(
        onTap: onTap,
        radius: ZRadius.navCapsule,
        pressHighlight: false,
        pressScale: 0.90,
        hoverColor: ZalosTokens.clear,
        selected: selected,
        semanticLabel: label,
        child: SizedBox(
          height: ZSizes.bottomNav,
          child: Column(
            mainAxisAlignment: MainAxisAlignment.center,
            children: [
              Stack(
                clipBehavior: Clip.none,
                children: [
                  ZBump(
                    trigger: selected ? 1 : 0,
                    child: TweenAnimationBuilder<Color?>(
                      tween: ColorTween(end: color),
                      duration: reduced ? Duration.zero : ZMotion.fast,
                      curve: ZMotion.standard,
                      builder: (context, tint, _) => Icon(
                        selected ? activeIcon : icon,
                        size: 21,
                        color: tint,
                      ),
                    ),
                  ),
                  if (badge != null)
                    Positioned(
                      top: badgeIsDot ? -2 : -5,
                      right: badgeIsDot ? -4 : -11,
                      child: badge!,
                    ),
                ],
              ),
              const SizedBox(height: 2),
              Text(
                label,
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                textScaler: TextScaler.noScaling,
                style: labelStyle,
              ),
            ],
          ),
        ),
      ),
    );
  }
}

class _WideShell extends ConsumerWidget {
  const _WideShell({required this.link, required this.chat, required this.thread, required this.session, required this.layout});

  final ServerLink link;
  final Widget? chat;
  final OpenThread? thread;
  final AccountSession? session;
  final LayoutClass layout;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final z = context.z;
    final tab = ref.watch(homeTabProvider);
    final infoOpen = ref.watch(infoPaneOpenProvider) && thread != null && session != null;
    final expanded = layout == LayoutClass.expanded;
    void closeInfo() => ref.read(infoPaneOpenProvider.notifier).state = false;
    final info = infoOpen ? InfoPane(key: ValueKey('info-${thread!.key}'), session: session!, thread: thread!, onClose: closeInfo) : null;
    final chatArea = chat ??
        ColoredBox(
          key: const Key('chatEmpty'),
          color: z.layerSubtle,
          child: ZEmptyState(icon: ZIcons.forum, title: context.tr('chatEmptyTitle'), subtitle: context.tr('chatEmptyHint')),
        );
    // Tab order: panes left to right, reading order inside each pane.
    Widget pane(double order, Widget child) => FocusTraversalOrder(order: NumericFocusOrder(order), child: FocusTraversalGroup(policy: ZReadingOrderPolicy(), child: child));
    return Scaffold(
      key: const Key('wideShell'),
      backgroundColor: z.layer,
      body: FocusTraversalGroup(
        policy: OrderedTraversalPolicy(),
        child: Row(
          children: [
            pane(0, AccountRail(link: link)),
            Container(
              width: expanded ? ZSizes.listExpanded : ZSizes.listMedium,
              decoration: BoxDecoration(color: z.layer, border: Border(right: BorderSide(color: z.divider))),
              child: SafeArea(right: false, child: pane(1, _tabBody(tab, link))),
            ),
            Expanded(
              child: Stack(
                fit: StackFit.expand,
                children: [
                  pane(2, chatArea),
                  ZPresence(
                    child: expanded ? null : info,
                    builder: (context, animation, info) => Stack(
                      fit: StackFit.expand,
                      children: [
                        FadeTransition(
                          opacity: animation,
                          child: Semantics(
                            label: context.tr('close'),
                            button: true,
                            onTap: closeInfo,
                            child: GestureDetector(onTap: closeInfo, child: ColoredBox(color: z.scrim.withValues(alpha: 0.3))),
                          ),
                        ),
                        Positioned(
                          top: 0,
                          bottom: 0,
                          right: 0,
                          width: ZSizes.infoOverlay,
                          child: _paneSlide(
                            context,
                            animation,
                            Container(
                              key: const Key('infoOverlay'),
                              decoration: BoxDecoration(color: z.layer, boxShadow: z.shadowOverlay),
                              child: pane(3, info),
                            ),
                          ),
                        ),
                      ],
                    ),
                  ),
                ],
              ),
            ),
            ZPresence(
              child: expanded ? info : null,
              builder: (context, animation, info) => SizedBox(
                width: ZSizes.infoDocked,
                child: Container(
                  key: const Key('infoDocked'),
                  decoration: BoxDecoration(color: z.layer, border: Border(left: BorderSide(color: z.divider))),
                  child: ClipRect(child: _paneSlide(context, animation, pane(3, info))),
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }
}

/// Side pane entrance: a short slide from the right with a fade; only the
/// fade when motion is reduced.
Widget _paneSlide(BuildContext context, Animation<double> animation, Widget child) {
  final faded = FadeTransition(opacity: animation, child: child);
  if (ZMotion.reduced(context)) return faded;
  return SlideTransition(position: Tween(begin: const Offset(0.15, 0), end: Offset.zero).animate(animation), child: faded);
}

AvatarStatus avatarStatusFor(AccountStatus status) => switch (status) {
      AccountStatus.online => AvatarStatus.none,
      AccountStatus.starting || AccountStatus.reconnecting => AvatarStatus.syncing,
      _ => AvatarStatus.warning,
    };

class AccountRail extends ConsumerWidget {
  const AccountRail({super.key, required this.link});

  final ServerLink link;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final z = context.z;
    final tab = ref.watch(homeTabProvider);
    final manifest = ref.watch(manifestProvider);
    final active = ref.watch(activeAccountProvider.select((a) => a?.slot));
    final pending = ref.watch(isAdminProvider) && ref.watch(vaultRequestsProvider).isNotEmpty;
    void go(HomeTab t) => ref.read(homeTabProvider.notifier).state = t;
    final accounts = manifest?.accounts ?? const <AccountSummary>[];
    return Semantics(
      container: true,
      label: context.tr('railLabel'),
      child: Container(
        key: const Key('accountRail'),
        width: ZSizes.rail,
        color: z.brand,
        child: SafeArea(
          right: false,
          child: Column(
            children: [
              const SizedBox(height: ZSpace.s12),
              Expanded(
                child: Column(
                  children: [
                    Flexible(
                      child: SingleChildScrollView(
                        child: Column(
                          children: [
                            for (var i = 0; i < accounts.length; i++)
                              _RailAccount(
                                key: Key('railAccount-${accounts[i].slot}'),
                                account: accounts[i],
                                session: link.account(accounts[i].slot),
                                active: accounts[i].slot == active,
                                shortcut: i < 9 ? i + 1 : null,
                                onTap: () => switchAccount(ref, accounts[i].slot),
                              ),
                          ],
                        ),
                      ),
                    ),
                    Container(margin: const EdgeInsets.symmetric(vertical: ZSpace.s4), width: 32, height: 1, color: z.railDivider),
                    _RailTab(key: const Key('railTab-messages'), icon: ZIcons.chat, activeIcon: ZIcons.chatFill, label: context.tr('tabMessages'), selected: tab == HomeTab.messages, onTap: () { ZHaptics.selection(); go(HomeTab.messages); }),
                    _RailTab(
                        key: const Key('railTab-contacts'), icon: ZIcons.contacts, activeIcon: ZIcons.contactsFill, label: context.tr('tabContacts'), selected: tab == HomeTab.contacts, onTap: () { ZHaptics.selection(); go(HomeTab.contacts); }),
                  ],
                ),
              ),
              _RailTab(
                key: const Key('railTab-me'),
                icon: ZIcons.settings,
                activeIcon: ZIcons.settingsFill,
                label: context.tr('tabMe'),
                selected: tab == HomeTab.me,
                onTap: () { ZHaptics.selection(); go(HomeTab.me); },
                dot: pending,
              ),
              const SizedBox(height: ZSpace.s12),
            ],
          ),
        ),
      ),
    );
  }
}

class _RailAccount extends StatelessWidget {
  const _RailAccount({super.key, required this.account, required this.session, required this.active, required this.onTap, this.shortcut});

  final AccountSummary account;
  final AccountSession session;
  final bool active;
  final VoidCallback onTap;
  final int? shortcut;

  @override
  Widget build(BuildContext context) {
    final z = context.z;
    final online = account.status == AccountStatus.online;
    final label = online ? account.displayName : '${account.displayName} (${statusLabel(account.status, context.s)})';
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 2),
      child: ZPressable(
        onTap: onTap,
        circle: true,
        hoverColor: z.railPlateHover,
        pressedColor: z.railPlateSelected,
        tooltip: shortcut == null ? label : context.tr('railAccountTooltip', [label, shortcut]),
        semanticLabel: account.unread > 0 ? context.tr('accountUnreadLabel', [label, account.unread]) : label,
        selected: active,
        child: SizedBox(
          width: 52,
          height: 52,
          child: Stack(
            alignment: Alignment.center,
            children: [
              Container(
                width: 50,
                height: 50,
                decoration: BoxDecoration(
                  shape: BoxShape.circle,
                  border: Border.all(color: active ? ZalosTokens.white : ZalosTokens.clear, width: 2),
                ),
                alignment: Alignment.center,
                child: Container(
                  decoration: BoxDecoration(shape: BoxShape.circle, border: Border.all(color: z.railDivider, width: 1)),
                  child: Opacity(
                    opacity: online ? 1 : 0.75,
                    child: ZAvatar(session: session, id: account.uid.isEmpty ? account.slot : account.uid, name: account.displayName, url: account.avatarUrl, size: 40),
                  ),
                ),
              ),
              if (account.unread > 0) Positioned(top: 0, right: 0, child: ZBadge(count: account.unread, outline: z.brand)),
              if (account.kind == AccountKind.oa) Positioned(bottom: 0, left: 0, child: OaTag(key: Key('oaTag-${account.slot}'))),
              if (!online)
                Positioned(
                  bottom: 2,
                  right: 2,
                  child: Container(
                    width: 16,
                    height: 16,
                    decoration: BoxDecoration(color: z.layer, shape: BoxShape.circle, border: Border.all(color: z.brand, width: 1)),
                    child: Icon(
                      avatarStatusFor(account.status) == AvatarStatus.syncing ? ZIcons.sync : ZIcons.warning,
                      size: 11,
                      color: avatarStatusFor(account.status) == AvatarStatus.syncing ? z.warning : z.danger,
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

class _RailTab extends StatelessWidget {
  const _RailTab({super.key, required this.icon, required this.activeIcon, required this.label, required this.selected, required this.onTap, this.dot = false});

  final IconData icon;
  final IconData activeIcon;
  final String label;
  final bool selected;
  final VoidCallback onTap;
  final bool dot;

  @override
  Widget build(BuildContext context) {
    final z = context.z;
    return SizedBox(
      height: 56,
      child: Center(
        child: ZPressable(
          onTap: onTap,
          radius: ZRadius.railPlate,
          pressScale: 0.92,
          color: selected ? z.railPlateSelected : null,
          hoverColor: selected ? z.railPlateSelected : z.railPlateHover,
          pressedColor: z.railPlateSelected,
          tooltip: label,
          semanticLabel: label,
          selected: selected,
          child: SizedBox(
            width: 48,
            height: 48,
            child: Stack(
              alignment: Alignment.center,
              clipBehavior: Clip.none,
              children: [
                Icon(selected ? activeIcon : icon, size: 24, color: selected ? ZalosTokens.white : z.railIcon),
                if (dot) Positioned(top: 8, right: 8, child: ZBadge(key: const Key('vaultDot'), count: 0, dot: true, outline: z.brand)),
              ],
            ),
          ),
        ),
      ),
    );
  }
}

/// Account switcher sheet of the phone header.
Future<void> showAccountSheet(BuildContext context, ServerLink link) {
  return showZModal<void>(context, builder: (_) => _AccountSheet(link: link));
}

class _AccountSheet extends ConsumerWidget {
  const _AccountSheet({required this.link});

  final ServerLink link;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final manifest = ref.watch(manifestProvider);
    final active = ref.watch(activeAccountProvider.select((a) => a?.slot));
    final admin = ref.watch(isAdminProvider);
    return ZDialogScaffold(
      key: const Key('accountSheet'),
      title: context.tr('accounts'),
      padBody: false,
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          for (final a in manifest?.accounts ?? const <AccountSummary>[])
            AccountRow(
              key: Key('sheetAccount-${a.slot}'),
              account: a,
              session: link.account(a.slot),
              active: a.slot == active,
              onTap: () {
                switchAccount(ref, a.slot);
                Navigator.of(context).pop();
              },
            ),
          if (admin)
            ZRow(
              key: const Key('sheetAddAccount'),
              icon: ZIcons.personAdd,
              title: context.tr('addZaloAccount'),
              accent: true,
              onTap: () {
                Navigator.of(context).pop();
                showAddAccount(context, link);
              },
            ),
          const SizedBox(height: ZSpace.s8),
        ],
      ),
    );
  }
}

ZTone statusTone(AccountStatus status) => switch (status) {
      AccountStatus.online => ZTone.success,
      AccountStatus.starting || AccountStatus.reconnecting => ZTone.info,
      AccountStatus.needsLogin || AccountStatus.error => ZTone.danger,
      AccountStatus.displaced => ZTone.warning,
      AccountStatus.offline => ZTone.neutral,
    };

class AccountRow extends StatelessWidget {
  const AccountRow({super.key, required this.account, required this.session, required this.active, this.onTap, this.trailing});

  final AccountSummary account;
  final AccountSession session;
  final bool active;
  final VoidCallback? onTap;
  final Widget? trailing;

  @override
  Widget build(BuildContext context) {
    final z = context.z;
    return ZPressable(
      onTap: onTap,
      radius: 0,
      selected: active,
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: ZSpace.s16, vertical: ZSpace.s8),
        child: Row(
          children: [
            ZAvatar(session: session, id: account.uid.isEmpty ? account.slot : account.uid, name: account.displayName, url: account.avatarUrl, size: 48),
            const SizedBox(width: ZSpace.s12),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Row(children: [
                    Flexible(child: Text(account.displayName, maxLines: 1, overflow: TextOverflow.ellipsis, style: active ? z.text.rowTitleUnread : z.text.rowTitle)),
                    if (account.kind == AccountKind.oa) const Padding(padding: EdgeInsets.only(left: ZSpace.s4), child: OaTag()),
                  ]),
                  const SizedBox(height: ZSpace.s4),
                  ZChip(label: statusLabel(account.status, context.s), tone: statusTone(account.status)),
                ],
              ),
            ),
            if (account.unread > 0) ...[const SizedBox(width: ZSpace.s8), ZBadge(count: account.unread)],
            if (active) ...[
              const SizedBox(width: ZSpace.s8),
              Icon(ZIcons.checkCircle, color: z.brandText, fill: 1, size: 22, semanticLabel: context.tr('activeAccount')),
            ],
            if (trailing != null) trailing!,
          ],
        ),
      ),
    );
  }
}
