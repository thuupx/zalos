import 'dart:async';

import 'package:material_ui/material_ui.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter/services.dart';

import '../l10n/strings.dart';
import '../theme/tokens.dart';
import '../theme/z_icons.dart';
import 'pressable.dart';

/// Opens [builder] as a centered dialog on wide layouts and as a bottom sheet
/// with a grab handle on phones.
Future<T?> showZModal<T>(BuildContext context, {required WidgetBuilder builder, bool dismissible = true, double maxWidth = ZSizes.dialogMax}) {
  final layout = LayoutScope.of(context);
  final z = context.z;
  if (layout == LayoutClass.compact) {
    final reduced = ZMotion.reduced(context);
    return showModalBottomSheet<T>(
      context: context,
      sheetAnimationStyle: AnimationStyle(
        duration: reduced ? Duration.zero : ZMotion.medium,
        reverseDuration: reduced ? Duration.zero : ZMotion.exit,
      ),
      isScrollControlled: true,
      isDismissible: dismissible,
      enableDrag: dismissible,
      backgroundColor: z.layer,
      barrierColor: z.scrim,
      elevation: 0,
      shape: const RoundedRectangleBorder(borderRadius: BorderRadius.vertical(top: Radius.circular(ZRadius.sheet))),
      clipBehavior: Clip.antiAlias,
      builder: (sheetContext) => LayoutScope(
        layout: layout,
        child: Padding(
          padding: EdgeInsets.only(bottom: MediaQuery.viewInsetsOf(sheetContext).bottom),
          child: SafeArea(
            child: ConstrainedBox(
              constraints: BoxConstraints(maxHeight: MediaQuery.sizeOf(sheetContext).height * 0.9),
              child: Column(
                mainAxisSize: MainAxisSize.min,
                children: [
                  Container(
                    margin: const EdgeInsets.only(top: ZSpace.s8, bottom: ZSpace.s4),
                    width: 38,
                    height: 4,
                    decoration: BoxDecoration(color: z.textDisabled.withValues(alpha: 0.6), borderRadius: BorderRadius.circular(2)),
                  ),
                  Flexible(child: builder(sheetContext)),
                ],
              ),
            ),
          ),
        ),
      ),
    );
  }
  return Navigator.of(context, rootNavigator: true).push<T>(_ZDialogRoute<T>(
    barrierDismissible: dismissible,
    barrierLabel: MaterialLocalizations.of(context).modalBarrierDismissLabel,
    barrierColor: z.scrim,
    transitionDuration: ZMotion.medium,
    pageBuilder: (dialogContext, _, __) => LayoutScope(
      layout: layout,
      child: SafeArea(
        child: Padding(
          padding: EdgeInsets.only(bottom: MediaQuery.viewInsetsOf(dialogContext).bottom),
          child: Center(
            child: Padding(
              padding: const EdgeInsets.all(ZSpace.s24),
              child: ConstrainedBox(
                constraints: BoxConstraints(maxWidth: maxWidth),
                child: Material(
                  color: z.layer,
                  elevation: 0,
                  borderRadius: BorderRadius.circular(ZRadius.card),
                  clipBehavior: Clip.antiAlias,
                  child: DecoratedBox(
                    position: DecorationPosition.foreground,
                    decoration: BoxDecoration(borderRadius: BorderRadius.circular(ZRadius.card), border: Border.all(color: z.divider)),
                    child: builder(dialogContext),
                  ),
                ),
              ),
            ),
          ),
        ),
      ),
    ),
    transitionBuilder: (context, animation, _, child) {
      final curved = CurvedAnimation(parent: animation, curve: ZMotion.enterCurve, reverseCurve: ZMotion.exitCurve);
      if (ZMotion.reduced(context)) return FadeTransition(opacity: curved, child: child);
      return FadeTransition(opacity: curved, child: ScaleTransition(scale: Tween(begin: 0.96, end: 1.0).animate(curved), child: child));
    },
  ));
}

/// Dialog route that leaves faster than it enters.
class _ZDialogRoute<T> extends RawDialogRoute<T> {
  _ZDialogRoute({
    required super.pageBuilder,
    required super.barrierDismissible,
    required super.barrierLabel,
    required super.barrierColor,
    required super.transitionDuration,
    required super.transitionBuilder,
  });

  @override
  Duration get reverseTransitionDuration => ZMotion.exit;
}

/// Popup entrance: a fade with a slight zoom from [anchor] (global), which
/// stays the visual fixed point; a plain fade when motion is reduced. Exits
/// ease in.
Widget zPopupTransition(BuildContext context, Animation<double> animation, {required Offset anchor, required Widget child, double from = 0.92}) {
  final curved = CurvedAnimation(parent: animation, curve: ZMotion.springCurve, reverseCurve: ZMotion.exitCurve);
  final faded = FadeTransition(opacity: curved, child: child);
  if (ZMotion.reduced(context)) return faded;
  return ZPopupScale(anchor: anchor, animation: curved, from: from, child: faded);
}

/// Alignment of [anchor] within [rect] as a scale origin in -1..1 units.
/// Values beyond that range mean the anchor sits outside the popup after a
/// flip or an edge clamp; they are kept so the anchor stays the fixed point.
Alignment popupScaleOrigin(Offset anchor, Rect rect) {
  double axis(double value, double start, double extent) => extent <= 0 ? 0 : (value - start) / extent * 2 - 1;
  return Alignment(axis(anchor.dx, rect.left, rect.width), axis(anchor.dy, rect.top, rect.height));
}

/// Scales [child] about [anchor] (global) using its real laid-out rect, so the
/// anchor stays the visual fixed point however the popup was flipped or
/// clamped. Paint only, so layout never moves.
class ZPopupScale extends SingleChildRenderObjectWidget {
  const ZPopupScale({super.key, required this.anchor, required this.animation, required this.from, required super.child});

  final Offset anchor;
  final Animation<double> animation;
  final double from;

  @override
  RenderBox createRenderObject(BuildContext context) => _RenderPopupScale(anchor: anchor, animation: animation, from: from);

  @override
  void updateRenderObject(BuildContext context, RenderObject renderObject) {
    (renderObject as _RenderPopupScale)
      ..anchor = anchor
      ..animation = animation
      ..from = from;
  }
}

class _RenderPopupScale extends RenderProxyBox {
  _RenderPopupScale({required Offset anchor, required Animation<double> animation, required double from})
      : _anchor = anchor,
        _animation = animation,
        _from = from;

  Offset _anchor;
  set anchor(Offset value) {
    if (value == _anchor) return;
    _anchor = value;
    markNeedsPaint();
  }

  Animation<double> _animation;
  set animation(Animation<double> value) {
    if (value == _animation) return;
    if (attached) _animation.removeListener(markNeedsPaint);
    _animation = value;
    if (attached) _animation.addListener(markNeedsPaint);
    markNeedsPaint();
  }

  double _from;
  set from(double value) {
    if (value == _from) return;
    _from = value;
    markNeedsPaint();
  }

  @override
  void attach(PipelineOwner owner) {
    super.attach(owner);
    _animation.addListener(markNeedsPaint);
  }

  @override
  void detach() {
    _animation.removeListener(markNeedsPaint);
    super.detach();
  }

  Matrix4? _transform() {
    final scale = _from + (1 - _from) * _animation.value;
    if (scale == 1) return null;
    final origin = popupScaleOrigin(_anchor, localToGlobal(Offset.zero) & size).alongSize(size);
    return Matrix4.identity()
      ..translateByDouble(origin.dx, origin.dy, 0.0, 1.0)
      ..scaleByDouble(scale, scale, scale, 1.0)
      ..translateByDouble(-origin.dx, -origin.dy, 0.0, 1.0);
  }

  @override
  void paint(PaintingContext context, Offset offset) {
    final child = this.child;
    if (child == null) return;
    final transform = _transform();
    if (transform == null) {
      context.paintChild(child, offset);
    } else {
      context.pushTransform(needsCompositing, offset, transform, (context, offset) => context.paintChild(child, offset));
    }
  }

  @override
  bool hitTest(BoxHitTestResult result, {required Offset position}) {
    final transform = _transform();
    if (transform == null) return super.hitTest(result, position: position);
    return result.addWithPaintTransform(
      transform: transform,
      position: position,
      hitTest: (result, position) => super.hitTest(result, position: position),
    );
  }
}

/// Pops the route on Escape without taking focus, so arrow keys and Enter keep
/// working inside the popup.
class ZDismissOnEscape extends StatefulWidget {
  const ZDismissOnEscape({super.key, required this.child});

  final Widget child;

  @override
  State<ZDismissOnEscape> createState() => _ZDismissOnEscapeState();
}

class _ZDismissOnEscapeState extends State<ZDismissOnEscape> {
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

  bool _onKey(KeyEvent event) {
    if (event is! KeyDownEvent || !mounted || event.logicalKey != LogicalKeyboardKey.escape) return false;
    if (!(ModalRoute.of(context)?.isCurrent ?? false)) return false;
    Navigator.of(context).maybePop();
    return true;
  }

  @override
  Widget build(BuildContext context) => widget.child;
}

class ZDialogScaffold extends StatelessWidget {
  const ZDialogScaffold({super.key, required this.title, required this.child, this.actions = const [], this.showClose = false, this.padBody = true});

  final String title;
  final Widget child;
  final List<Widget> actions;
  final bool showClose;
  final bool padBody;

  @override
  Widget build(BuildContext context) {
    final z = context.z;
    return Semantics(
      scopesRoute: true,
      namesRoute: true,
      label: title,
      explicitChildNodes: true,
      child: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Padding(
            padding: EdgeInsets.fromLTRB(ZSpace.s20, ZSpace.s16, showClose ? ZSpace.s8 : ZSpace.s20, ZSpace.s8),
            child: Row(
              children: [
                Expanded(child: Semantics(header: true, child: Text(title, style: z.text.title))),
                if (showClose)
                  ZIconButton(icon: ZIcons.close, label: context.tr('close'), onPressed: () => Navigator.of(context).maybePop()),
              ],
            ),
          ),
          Flexible(
            child: SingleChildScrollView(
              padding: padBody ? const EdgeInsets.fromLTRB(ZSpace.s20, ZSpace.s4, ZSpace.s20, ZSpace.s16) : EdgeInsets.zero,
              child: child,
            ),
          ),
          if (actions.isNotEmpty)
            Padding(
              padding: const EdgeInsets.fromLTRB(ZSpace.s16, 0, ZSpace.s16, ZSpace.s16),
              child: Wrap(alignment: WrapAlignment.end, spacing: ZSpace.s8, runSpacing: ZSpace.s8, children: actions),
            ),
        ],
      ),
    );
  }
}

/// Confirmation that names its object; the confirming action sits at the
/// right, in danger color when destructive.
Future<bool> zConfirm(
  BuildContext context, {
  required String title,
  required String message,
  required String confirmLabel,
  bool danger = true,
}) async {
  final result = await showZModal<bool>(
    context,
    builder: (context) => ZDialogScaffold(
      title: title,
      actions: [
        ZButton(key: const Key('confirmCancel'), label: context.tr('cancel'), variant: ZButtonVariant.text, onPressed: () => Navigator.pop(context, false)),
        ZButton(
          key: const Key('confirmOk'),
          label: confirmLabel,
          variant: danger ? ZButtonVariant.destructive : ZButtonVariant.primary,
          onPressed: () => Navigator.pop(context, true),
        ),
      ],
      child: Text(message, style: context.z.text.body.copyWith(color: context.z.textSecondary)),
    ),
  );
  return result ?? false;
}

@immutable
class ZMenuItem<T> {
  const ZMenuItem({required this.value, required this.label, this.icon, this.danger = false, this.enabled = true, this.dividerBefore = false});

  final T value;
  final String label;
  final IconData? icon;
  final bool danger;
  final bool enabled;
  final bool dividerBefore;
}

/// Context menu at [position] (global). Arrow keys move, Enter selects, Esc
/// closes. [header] is placed above the items (the reaction row).
Future<T?> showZMenu<T>(
  BuildContext context, {
  required Offset position,
  required List<ZMenuItem<T>> items,
  Widget Function(BuildContext context)? header,
  Widget Function(BuildContext context, Animation<double> animation)? animatedHeader,
}) {
  final navigator = Navigator.of(context, rootNavigator: true);
  return navigator.push<T>(_ZMenuRoute<T>(
    position: position,
    items: items,
    header: header,
    animatedHeader: animatedHeader,
    tokens: context.z,
    layout: LayoutScope.of(context),
    strings: context.s,
    barrierLabel: MaterialLocalizations.of(context).modalBarrierDismissLabel,
  ));
}

class _ZMenuRoute<T> extends PopupRoute<T> {
  _ZMenuRoute({
    required this.position,
    required this.items,
    required this.header,
    required this.animatedHeader,
    required this.tokens,
    required this.layout,
    required this.strings,
    required this.barrierLabel,
  });

  final Offset position;
  final List<ZMenuItem<T>> items;
  final Widget Function(BuildContext context)? header;
  final Widget Function(BuildContext context, Animation<double> animation)? animatedHeader;
  final ZalosTokens tokens;
  final LayoutClass layout;
  final S strings;

  @override
  final String barrierLabel;

  @override
  Color? get barrierColor =>
      tokens.scrim.withValues(alpha: tokens.dark ? 0.35 : 0.16);

  @override
  bool get barrierDismissible => true;

  @override
  Duration get transitionDuration => ZMotion.enter;

  @override
  Duration get reverseTransitionDuration => ZMotion.exit;

  @override
  Widget buildPage(BuildContext context, Animation<double> animation, Animation<double> secondaryAnimation) {
    final z = tokens;
    final padding = MediaQuery.paddingOf(context);
    final hasHeader = header != null || animatedHeader != null;
    return StringsScope(
      strings: strings,
      child: LayoutScope(
        layout: layout,
        child: ZDismissOnEscape(
          child: CustomSingleChildLayout(
            delegate: _MenuLayout(position, padding),
            child: zPopupTransition(
              context,
              animation,
              anchor: position,
              from: 0.90,
              child: Semantics(
                scopesRoute: true,
                explicitChildNodes: true,
                child: Material(
                  type: MaterialType.transparency,
                  child: Container(
                    constraints: const BoxConstraints(minWidth: 180, maxWidth: 304),
                    padding: const EdgeInsets.symmetric(horizontal: 6, vertical: ZSpace.s4),
                    decoration: BoxDecoration(
                      color: z.layer,
                      borderRadius: BorderRadius.circular(ZRadius.menu),
                      border: Border.all(color: z.border),
                      boxShadow: z.shadowOverlay,
                    ),
                    child: Shortcuts(
                      shortcuts: const {
                        SingleActivator(LogicalKeyboardKey.arrowDown): NextFocusIntent(),
                        SingleActivator(LogicalKeyboardKey.arrowUp): PreviousFocusIntent(),
                      },
                      child: FocusTraversalGroup(
                        child: IntrinsicWidth(
                          child: SingleChildScrollView(
                            child: Column(
                              mainAxisSize: MainAxisSize.min,
                              crossAxisAlignment: CrossAxisAlignment.stretch,
                              children: [
                                if (animatedHeader != null)
                                  animatedHeader!(context, animation)
                                else if (header != null)
                                  header!(context),
                                for (var i = 0; i < items.length; i++) ...[
                                  if (items[i].dividerBefore)
                                    Container(height: 1, margin: const EdgeInsets.all(ZSpace.s4), color: z.divider),
                                  _MenuRow<T>(item: items[i], autofocus: i == 0 && !hasHeader),
                                ],
                              ],
                            ),
                          ),
                        ),
                      ),
                    ),
                  ),
                ),
              ),
            ),
          ),
        ),
      ),
    );
  }
}

class _MenuRow<T> extends StatelessWidget {
  const _MenuRow({required this.item, required this.autofocus});

  final ZMenuItem<T> item;
  final bool autofocus;

  @override
  Widget build(BuildContext context) {
    final z = context.z;
    final color = !item.enabled ? z.textDisabled : (item.danger ? z.danger : z.textPrimary);
    final wide = LayoutScope.wideOf(context);
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 2),
      child: ZPressable(
        key: Key('menu-${item.value}'),
        autofocus: autofocus,
        radius: ZRadius.menuItem,
        onTap: item.enabled ? () => Navigator.of(context).pop(item.value) : null,
        child: Container(
          constraints: BoxConstraints(minHeight: wide ? 36 : ZSizes.touchTarget),
          padding: const EdgeInsets.symmetric(horizontal: 10),
          child: Row(
            children: [
              if (item.icon != null) ...[
                Icon(item.icon, size: 20, color: item.danger || !item.enabled ? color : z.textSecondary),
                const SizedBox(width: ZSpace.s12),
              ],
              Flexible(child: Text(item.label, maxLines: 1, overflow: TextOverflow.ellipsis, style: z.text.labelRegular.copyWith(color: color))),
            ],
          ),
        ),
      ),
    );
  }
}

class _MenuLayout extends SingleChildLayoutDelegate {
  _MenuLayout(this.position, this.padding);

  final Offset position;
  final EdgeInsets padding;

  @override
  BoxConstraints getConstraintsForChild(BoxConstraints constraints) =>
      BoxConstraints.loose(Size(constraints.maxWidth - 16, constraints.maxHeight - padding.vertical - 16));

  @override
  Offset getPositionForChild(Size size, Size childSize) {
    var x = position.dx;
    var y = position.dy;
    if (x + childSize.width > size.width - 8) x = position.dx - childSize.width;
    if (y + childSize.height > size.height - padding.bottom - 8) y = position.dy - childSize.height;
    final maxX = size.width - childSize.width - 8;
    final maxY = size.height - padding.bottom - childSize.height - 8;
    return Offset(x.clamp(8.0, maxX < 8 ? 8.0 : maxX), y.clamp(padding.top + 8, maxY < padding.top + 8 ? padding.top + 8 : maxY));
  }

  @override
  bool shouldRelayout(_MenuLayout oldDelegate) => position != oldDelegate.position || padding != oldDelegate.padding;
}

/// Hosts the single toast of the app. Placed above the navigator.
class ZToastHost extends StatefulWidget {
  const ZToastHost({super.key, required this.child});

  final Widget child;

  static ZToastHostState? _current;

  static void show(BuildContext context, String message) {
    final state = context.findAncestorStateOfType<ZToastHostState>() ?? _current;
    state?._show(message);
  }

  @override
  State<ZToastHost> createState() => ZToastHostState();
}

class ZToastHostState extends State<ZToastHost> {
  String? _message;
  Timer? _timer;

  @override
  void initState() {
    super.initState();
    ZToastHost._current = this;
  }

  @override
  void dispose() {
    _timer?.cancel();
    if (ZToastHost._current == this) ZToastHost._current = null;
    super.dispose();
  }

  void _show(String message) {
    _timer?.cancel();
    setState(() => _message = message);
    _timer = Timer(ZDurations.toast, () {
      if (mounted) setState(() => _message = null);
    });
  }

  @override
  Widget build(BuildContext context) {
    final z = context.z;
    final size = MediaQuery.sizeOf(context);
    final layout = layoutClassFor(size.width);
    final message = _message;
    final double left = switch (layout) {
      LayoutClass.compact => ZSpace.s16,
      LayoutClass.medium => ZSizes.rail + ZSizes.listMedium + ZSpace.s16,
      LayoutClass.expanded => ZSizes.rail + ZSizes.listExpanded + ZSpace.s16,
    };
    final double bottom = (layout == LayoutClass.compact ? ZSizes.bottomNav + ZSpace.s16 : ZSpace.s16) +
        MediaQuery.paddingOf(context).bottom +
        MediaQuery.viewInsetsOf(context).bottom;
    return Stack(
      children: [
        widget.child,
        Positioned(
          left: left,
          right: ZSpace.s16,
          bottom: bottom,
          child: IgnorePointer(
            child: AnimatedSwitcher(
              duration: ZMotion.medium,
              reverseDuration: ZMotion.exit,
              switchInCurve: ZMotion.enterCurve,
              switchOutCurve: ZMotion.exitCurve,
              child: message == null
                  ? const SizedBox.shrink()
                  : Align(
                      key: ValueKey(message),
                      alignment: layout == LayoutClass.compact ? Alignment.bottomCenter : Alignment.bottomLeft,
                      child: Semantics(
                        liveRegion: true,
                        container: true,
                        child: Container(
                          key: const Key('toast'),
                          constraints: const BoxConstraints(maxWidth: 420),
                          padding: const EdgeInsets.symmetric(horizontal: ZSpace.s16, vertical: ZSpace.s12),
                          decoration: BoxDecoration(
                            color: z.dark ? z.layerPressed : z.textPrimary,
                            borderRadius: BorderRadius.circular(ZRadius.input),
                            boxShadow: z.shadowOverlay,
                          ),
                          child: Text(message, style: z.text.labelRegular.copyWith(color: z.dark ? z.textPrimary : z.layer)),
                        ),
                      ),
                    ),
            ),
          ),
        ),
      ],
    );
  }
}

void zToast(BuildContext context, String message) => ZToastHost.show(context, message);
