import 'package:material_ui/material_ui.dart';

import '../theme/tokens.dart';
import '../util/haptics.dart';

/// Base of every interactive element: hover, pressed and focus states, a
/// 2 px focus ring, keyboard activation, tooltip and a semantic label.
///
/// Hover and press highlights are painted as separate opacity-animated layers
/// over the resting surface so the RGB channels never interpolate from
/// transparent black, eliminating dark/gray mid-transition flashes on touch
/// devices.
class ZPressable extends StatefulWidget {
  const ZPressable({
    super.key,
    required this.child,
    this.onTap,
    this.onLongPress,
    this.onSecondaryTapUp,
    this.onLongPressStart,
    this.onHover,
    this.semanticLabel,
    this.tooltip,
    this.radius = ZRadius.input,
    this.circle = false,
    this.color,
    this.hoverColor,
    this.pressedColor,
    this.focusRingColor,
    this.minSize,
    this.focusNode,
    this.autofocus = false,
    this.selected,
    this.toggled,
    this.padding = EdgeInsets.zero,
    this.cursor,
    this.canRequestFocus = true,
    this.border,
    this.shadow,
    this.pressScale = 1.0,
    this.pressHighlight = true,
  });

  final Widget child;
  final VoidCallback? onTap;
  final VoidCallback? onLongPress;
  final void Function(Offset globalPosition)? onSecondaryTapUp;
  final void Function(Offset globalPosition)? onLongPressStart;
  final ValueChanged<bool>? onHover;
  final String? semanticLabel;
  final String? tooltip;
  final double radius;
  final bool circle;
  final Color? color;
  final Color? hoverColor;
  final Color? pressedColor;
  final Color? focusRingColor;
  final double? minSize;
  final FocusNode? focusNode;
  final bool autofocus;
  final bool? selected;
  final bool? toggled;
  final EdgeInsets padding;
  final MouseCursor? cursor;
  final bool canRequestFocus;
  final BoxBorder? border;
  final List<BoxShadow>? shadow;

  /// Subtle tactile scale applied while pressed (1.0 disables scaling).
  final double pressScale;

  /// Whether pressing paints the pressed fill highlight.
  final bool pressHighlight;

  @override
  State<ZPressable> createState() => _ZPressableState();
}

class _ZPressableState extends State<ZPressable> {
  bool _hover = false;
  bool _pressed = false;
  bool _focus = false;

  bool get _enabled =>
      widget.onTap != null ||
      widget.onLongPress != null ||
      widget.onLongPressStart != null;

  void _setHover(bool v) {
    if (_hover == v) return;
    setState(() => _hover = v);
    widget.onHover?.call(v);
  }

  void _setPressed(bool v) {
    if (_pressed == v) return;
    setState(() => _pressed = v);
  }

  bool _visible(Color? c) => c != null && (c.a * 255.0).round().clamp(0, 255) > 0;

  @override
  Widget build(BuildContext context) {
    final z = context.z;
    final reduced = ZMotion.reduced(context);
    final hoverColor = widget.hoverColor ?? z.layerHover;
    // Header fields are translucent white over the brand header, so pressing
    // them deepens that white instead of falling back to the warm neutral layer.
    final pressedColor = widget.pressedColor ??
        (widget.hoverColor == z.headerField
            ? z.headerFieldPressed
            : z.layerPressed);
    final restColor = _visible(widget.color) ? widget.color : null;
    final shape = widget.circle ? BoxShape.circle : BoxShape.rectangle;
    final borderRadius =
        widget.circle ? null : BorderRadius.circular(widget.radius);
    final showHover = _enabled && _hover && !_pressed && _visible(hoverColor);
    final showPress =
        _enabled && _pressed && widget.pressHighlight && _visible(pressedColor);

    Widget content = widget.padding == EdgeInsets.zero
        ? widget.child
        : Padding(padding: widget.padding, child: widget.child);

    // Base surface plus separate fixed-color hover and press opacity overlays.
    // Because each overlay animates opacity only, RGB never interpolates
    // through transparent black.
    Widget surface = Stack(
      fit: StackFit.passthrough,
      children: [
        if (_visible(hoverColor))
          Positioned.fill(
            child: IgnorePointer(
              child: AnimatedOpacity(
                opacity: showHover ? 1 : 0,
                duration: reduced ? Duration.zero : ZMotion.fast,
                curve: ZMotion.standard,
                child: DecoratedBox(
                  decoration: BoxDecoration(
                    color: hoverColor,
                    shape: shape,
                    borderRadius: borderRadius,
                  ),
                ),
              ),
            ),
          ),
        if (widget.pressHighlight && _visible(pressedColor))
          Positioned.fill(
            child: IgnorePointer(
              child: AnimatedOpacity(
                opacity: showPress ? 1 : 0,
                duration: showPress || reduced ? Duration.zero : ZMotion.press,
                curve: ZMotion.standard,
                child: DecoratedBox(
                  decoration: BoxDecoration(
                    color: pressedColor,
                    shape: shape,
                    borderRadius: borderRadius,
                  ),
                ),
              ),
            ),
          ),
        content,
      ],
    );

    Widget result = DecoratedBox(
      decoration: BoxDecoration(
        color: restColor,
        shape: shape,
        borderRadius: borderRadius,
        border: widget.border,
        boxShadow: widget.shadow,
      ),
      child: DecoratedBox(
        position: DecorationPosition.foreground,
        decoration: _focus
            ? BoxDecoration(
                shape: shape,
                borderRadius: borderRadius,
                border: Border.all(
                  color: widget.focusRingColor ?? z.focusRing,
                  width: 2,
                ),
              )
            : const BoxDecoration(),
        child: surface,
      ),
    );

    if (widget.pressScale != 1.0 && !reduced) {
      result = AnimatedScale(
        scale: _enabled && _pressed ? widget.pressScale : 1.0,
        duration: _pressed
            ? const Duration(milliseconds: 60)
            : const Duration(milliseconds: 160),
        curve: ZMotion.springCurve,
        child: result,
      );
    }

    final min = widget.minSize;
    if (min != null) {
      result = ConstrainedBox(
        constraints: BoxConstraints(minWidth: min, minHeight: min),
        child: Center(widthFactor: 1, heightFactor: 1, child: result),
      );
    }
    result = GestureDetector(
      behavior: HitTestBehavior.opaque,
      onTap: widget.onTap,
      onTapDown: _enabled ? (_) => _setPressed(true) : null,
      onTapUp: _enabled ? (_) => _setPressed(false) : null,
      onTapCancel: _enabled ? () => _setPressed(false) : null,
      onLongPress: widget.onLongPress,
      onLongPressStart: widget.onLongPressStart == null
          ? null
          : (d) => widget.onLongPressStart!(d.globalPosition),
      onSecondaryTapUp: widget.onSecondaryTapUp == null
          ? null
          : (d) => widget.onSecondaryTapUp!(d.globalPosition),
      child: result,
    );
    result = FocusableActionDetector(
      enabled: _enabled && widget.canRequestFocus,
      focusNode: widget.focusNode,
      autofocus: widget.autofocus,
      mouseCursor: widget.cursor ??
          (_enabled ? SystemMouseCursors.click : MouseCursor.defer),
      onShowFocusHighlight: (v) {
        if (_focus != v) setState(() => _focus = v);
      },
      actions: {
        ActivateIntent: CallbackAction<ActivateIntent>(onInvoke: (_) {
          widget.onTap?.call();
          return null;
        }),
        ButtonActivateIntent: CallbackAction<ButtonActivateIntent>(onInvoke: (_) {
          widget.onTap?.call();
          return null;
        }),
      },
      child: result,
    );
    result = MouseRegion(
      onEnter: _enabled || widget.onHover != null ? (_) => _setHover(true) : null,
      onExit: _enabled || widget.onHover != null ? (_) => _setHover(false) : null,
      child: result,
    );
    result = MergeSemantics(
      child: Semantics(
        button: true,
        enabled: _enabled,
        selected: widget.selected,
        toggled: widget.toggled,
        label: widget.semanticLabel,
        excludeSemantics: widget.semanticLabel != null,
        onTap: widget.onTap,
        onLongPress: widget.onLongPress,
        child: result,
      ),
    );
    final tooltip = widget.tooltip;
    if (tooltip != null && tooltip.isNotEmpty) {
      result = Tooltip(message: tooltip, excludeFromSemantics: true, child: result);
    }
    return result;
  }
}

enum ZButtonVariant { primary, secondary, text, destructive, destructiveText }

class ZButton extends StatelessWidget {
  const ZButton({
    super.key,
    required this.label,
    required this.onPressed,
    this.variant = ZButtonVariant.primary,
    this.loading = false,
    this.icon,
    this.expand = false,
    this.small = false,
    this.autofocus = false,
  });

  final String label;
  final VoidCallback? onPressed;
  final ZButtonVariant variant;
  final bool loading;
  final IconData? icon;
  final bool expand;
  final bool small;
  final bool autofocus;

  @override
  Widget build(BuildContext context) {
    final z = context.z;
    final enabled = onPressed != null && !loading;
    final wide = LayoutScope.wideOf(context);
    final height = small ? (wide ? 32.0 : 36.0) : (wide ? 40.0 : 44.0);
    late final Color fill, hover, pressed, fg;
    switch (variant) {
      case ZButtonVariant.primary:
        fill = z.brand;
        hover = z.brandHover;
        pressed = z.brandPressed;
        fg = z.textOnBrand;
      case ZButtonVariant.secondary:
        fill = z.brandSubtle;
        hover = z.layerSelected;
        pressed = z.layerSelected;
        fg = z.brandText;
      case ZButtonVariant.text:
        fill = ZalosTokens.clear;
        hover = z.layerHover;
        pressed = z.layerPressed;
        fg = z.brandText;
      case ZButtonVariant.destructive:
        fill = z.danger;
        hover = z.danger.withValues(alpha: 0.9);
        pressed = z.danger.withValues(alpha: 0.8);
        fg = z.dark ? z.dangerBg : z.textOnBrand;
      case ZButtonVariant.destructiveText:
        fill = ZalosTokens.clear;
        hover = z.dangerBg;
        pressed = z.dangerBg;
        fg = z.danger;
    }
    final filled = variant == ZButtonVariant.primary ||
        variant == ZButtonVariant.destructive;
    final disabledFill = filled ? z.layerPressed : fill;
    final color = enabled || loading ? fg : z.textDisabled;
    final content = Row(
      mainAxisSize: expand ? MainAxisSize.max : MainAxisSize.min,
      mainAxisAlignment: MainAxisAlignment.center,
      children: [
        if (icon != null) ...[
          Icon(icon, size: 20, color: color),
          const SizedBox(width: ZSpace.s8)
        ],
        Flexible(
            child: Text(label,
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: z.text.labelStrong.copyWith(color: color))),
      ],
    );
    return ZPressable(
      onTap: enabled
          ? () {
              if (variant == ZButtonVariant.destructive) {
                ZHaptics.medium();
              } else if (variant == ZButtonVariant.primary ||
                  variant == ZButtonVariant.secondary) {
                ZHaptics.light();
              }
              onPressed!();
            }
          : null,
      autofocus: autofocus,
      radius: ZRadius.button,
      pressScale: 0.98,
      color: enabled || loading ? fill : disabledFill,
      hoverColor: hover,
      pressedColor: pressed,
      focusRingColor: filled ? z.focusRingOnBrand : null,
      border: variant == ZButtonVariant.secondary
          ? Border.all(color: z.secondaryButtonBorder)
          : null,
      semanticLabel: label,
      minSize: wide ? null : ZSizes.touchTarget,
      child: Container(
        constraints: BoxConstraints(minHeight: height, minWidth: 64),
        padding: const EdgeInsets.symmetric(horizontal: ZSpace.s16),
        alignment: expand ? Alignment.center : null,
        child: Stack(
          alignment: Alignment.center,
          children: [
            Visibility(
                visible: !loading,
                maintainSize: true,
                maintainAnimation: true,
                maintainState: true,
                child: content),
            if (loading)
              SizedBox(
                  width: 16,
                  height: 16,
                  child: CircularProgressIndicator(strokeWidth: 2, color: color)),
          ],
        ),
      ),
    );
  }
}

class ZIconButton extends StatelessWidget {
  const ZIconButton({
    super.key,
    required this.icon,
    required this.label,
    required this.onPressed,
    this.size = 32,
    this.iconSize = 20,
    this.color,
    this.fill,
    this.hoverColor,
    this.selected = false,
    this.circle = false,
    this.filledIcon = false,
    this.shadow,
    this.focusNode,
  });

  final IconData icon;
  final String label;
  final VoidCallback? onPressed;
  final double size;
  final double iconSize;
  final Color? color;
  final Color? fill;
  final Color? hoverColor;
  final bool selected;
  final bool circle;
  final bool filledIcon;
  final List<BoxShadow>? shadow;
  final FocusNode? focusNode;

  @override
  Widget build(BuildContext context) {
    final z = context.z;
    final wide = LayoutScope.wideOf(context);
    final fg = onPressed == null
        ? z.textDisabled
        : (color ?? (selected ? z.brandText : z.textSecondary));
    return ZPressable(
      onTap: onPressed,
      focusNode: focusNode,
      tooltip: label,
      semanticLabel: label,
      selected: selected ? true : null,
      circle: circle,
      radius: ZRadius.input,
      pressScale: 0.90,
      color: fill ?? (selected ? z.brandSubtle : null),
      hoverColor: hoverColor,
      shadow: shadow,
      minSize: wide ? ZSizes.pointerTarget : ZSizes.touchTarget,
      child: SizedBox(
        width: size,
        height: size,
        child: TweenAnimationBuilder<Color?>(
          tween: ColorTween(end: fg),
          duration: ZMotion.fast,
          curve: ZMotion.standard,
          builder: (context, color, _) => Icon(icon,
              size: iconSize, color: color, fill: filledIcon || selected ? 1 : 0),
        ),
      ),
    );
  }
}

/// Reading-order tab traversal that scrolls the newly focused control fully
/// into view on whichever side of the viewport it is. The default only
/// reveals controls past the trailing edge when tabbing forwards, so tabbing
/// into a list that is scrolled down lands on an off-screen row.
class ZReadingOrderPolicy extends ReadingOrderTraversalPolicy {
  ZReadingOrderPolicy() : super(requestFocusCallback: _focusAndReveal);

  static void _focusAndReveal(FocusNode node,
      {ScrollPositionAlignmentPolicy? alignmentPolicy,
      double? alignment,
      Duration? duration,
      Curve? curve}) {
    node.requestFocus();
    final context = node.context;
    if (context == null) return;
    Scrollable.ensureVisible(context,
        alignmentPolicy: ScrollPositionAlignmentPolicy.keepVisibleAtEnd);
    Scrollable.ensureVisible(context,
        alignmentPolicy: ScrollPositionAlignmentPolicy.keepVisibleAtStart);
  }
}
