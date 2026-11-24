import 'package:material_ui/material_ui.dart';

import '../theme/tokens.dart';

/// Scales its child 1 to [ZMotion.bumpScale] and back whenever [trigger]
/// changes: badge counts, the heart button. Paint only, so the layout never
/// moves.
class ZBump extends StatefulWidget {
  const ZBump({super.key, required this.trigger, required this.child});

  final Object? trigger;
  final Widget child;

  @override
  State<ZBump> createState() => _ZBumpState();
}

class _ZBumpState extends State<ZBump> with SingleTickerProviderStateMixin {
  static final Animatable<double> _curve = TweenSequence<double>([
    TweenSequenceItem(tween: Tween(begin: 1.0, end: ZMotion.bumpScale).chain(CurveTween(curve: ZMotion.enterCurve)), weight: 40),
    TweenSequenceItem(tween: Tween(begin: ZMotion.bumpScale, end: 1.0).chain(CurveTween(curve: Curves.easeInOut)), weight: 60),
  ]);

  AnimationController? _controller;
  Animation<double> _scale = kAlwaysCompleteAnimation;

  @override
  void didUpdateWidget(ZBump old) {
    super.didUpdateWidget(old);
    if (old.trigger == widget.trigger || ZMotion.reduced(context)) return;
    final controller = _controller ??= AnimationController(vsync: this, duration: ZMotion.bump);
    _scale = _curve.animate(controller);
    controller.forward(from: 0);
  }

  @override
  void dispose() {
    _controller?.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => ScaleTransition(scale: _scale, child: widget.child);
}

/// Fades and scales its child in from [alignment] when it is first built and
/// [enabled]; otherwise shows it as is. For popovers and items that appear
/// while the user watches.
class ZPopIn extends StatefulWidget {
  const ZPopIn({super.key, required this.child, this.enabled = true, this.alignment = Alignment.center, this.from = 0.9, this.duration = ZMotion.enter});

  final Widget child;
  final bool enabled;
  final Alignment alignment;
  final double from;
  final Duration duration;

  @override
  State<ZPopIn> createState() => _ZPopInState();
}

class _ZPopInState extends State<ZPopIn> with SingleTickerProviderStateMixin {
  AnimationController? _controller;
  Animation<double> _progress = kAlwaysCompleteAnimation;
  bool _started = false;

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    if (_started) return;
    _started = true;
    if (!widget.enabled || ZMotion.reduced(context)) return;
    final controller = _controller = AnimationController(vsync: this, duration: widget.duration)..forward();
    _progress = CurvedAnimation(parent: controller, curve: ZMotion.enterCurve);
  }

  @override
  void dispose() {
    _controller?.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => FadeTransition(
        opacity: _progress,
        child: ScaleTransition(scale: Tween(begin: widget.from, end: 1.0).animate(_progress), alignment: widget.alignment, child: widget.child),
      );
}

/// Keeps [child] on screen while it animates out after it becomes null.
/// [builder] wraps it in the transition; the animation eases out on enter and
/// eases in, faster, on exit. Panes and layers that come and go.
class ZPresence extends StatefulWidget {
  const ZPresence({super.key, required this.child, required this.builder, this.duration = ZMotion.medium, this.reverseDuration = ZMotion.exit});

  final Widget? child;
  final Widget Function(BuildContext context, Animation<double> animation, Widget child) builder;
  final Duration duration;
  final Duration reverseDuration;

  @override
  State<ZPresence> createState() => _ZPresenceState();
}

class _ZPresenceState extends State<ZPresence> with SingleTickerProviderStateMixin {
  late final AnimationController _controller;
  late final Animation<double> _curved;
  Widget? _last;

  @override
  void initState() {
    super.initState();
    _last = widget.child;
    _controller = AnimationController(
      vsync: this,
      duration: widget.duration,
      reverseDuration: widget.reverseDuration,
      value: widget.child == null ? 0 : 1,
    )..addStatusListener((status) {
        if (status == AnimationStatus.dismissed && mounted) setState(() => _last = null);
      });
    _curved = CurvedAnimation(parent: _controller, curve: ZMotion.enterCurve, reverseCurve: ZMotion.exitCurve);
  }

  @override
  void didUpdateWidget(ZPresence old) {
    super.didUpdateWidget(old);
    if (widget.child != null) {
      _last = widget.child;
      if (old.child == null) _controller.forward();
    } else if (old.child != null) {
      _controller.reverse();
    }
  }

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final child = widget.child ?? _last;
    if (child == null) return const SizedBox.shrink();
    // Leaving content stays painted through the exit but is no longer part of
    // the page: Tab skips it and screen readers do not announce it.
    final exiting = widget.child == null;
    return widget.builder(
      context,
      _curved,
      IgnorePointer(
        ignoring: exiting,
        child: ExcludeFocus(
          excluding: exiting,
          child: ExcludeSemantics(excluding: exiting, child: child),
        ),
      ),
    );
  }
}

/// Reveals and hides [child] by growing its height with a fade, so content
/// below or above moves smoothly. With [axisAlignment] 1 the content slides
/// down from the edge above it (banners under a header); with -1 it slides
/// up from the edge below it (bars above the composer). [scaleAlignment]
/// adds a slight zoom from that point (popovers).
class ZReveal extends StatelessWidget {
  const ZReveal({super.key, required this.child, this.axisAlignment = 1, this.scaleAlignment});

  final Widget? child;
  final double axisAlignment;
  final Alignment? scaleAlignment;

  @override
  Widget build(BuildContext context) {
    final reduced = ZMotion.reduced(context);
    return AnimatedSwitcher(
      duration: reduced ? Duration.zero : ZMotion.medium,
      reverseDuration: reduced ? Duration.zero : ZMotion.exit,
      switchInCurve: ZMotion.enterCurve,
      switchOutCurve: ZMotion.exitCurve,
      layoutBuilder: (current, previous) => Stack(
        fit: StackFit.passthrough,
        alignment: Alignment(0, axisAlignment),
        children: [...previous, if (current != null) current],
      ),
      transitionBuilder: (child, animation) {
        Widget faded = FadeTransition(opacity: animation, child: child);
        final scaleFrom = scaleAlignment;
        if (scaleFrom != null) faded = ScaleTransition(scale: Tween(begin: 0.95, end: 1.0).animate(animation), alignment: scaleFrom, child: faded);
        return _HeightReveal(animation: animation, axisAlignment: axisAlignment, child: faded);
      },
      child: child ?? const SizedBox.shrink(),
    );
  }
}

/// Height factor clip that stops clipping once fully open, so shadows of the
/// revealed content are not cut off.
class _HeightReveal extends AnimatedWidget {
  const _HeightReveal({required Animation<double> animation, required this.axisAlignment, required this.child}) : super(listenable: animation);

  final double axisAlignment;
  final Widget child;

  @override
  Widget build(BuildContext context) {
    final value = (listenable as Animation<double>).value.clamp(0.0, 1.0);
    return ClipRect(
      clipBehavior: value < 1 ? Clip.hardEdge : Clip.none,
      child: Align(alignment: Alignment(0, axisAlignment), heightFactor: value, child: child),
    );
  }
}

/// Cross-fades between children with different keys: rail and bottom
/// navigation tabs.
class ZCrossFade extends StatelessWidget {
  const ZCrossFade({super.key, required this.child});

  final Widget child;

  @override
  Widget build(BuildContext context) => AnimatedSwitcher(
        duration: ZMotion.fast,
        switchInCurve: ZMotion.enterCurve,
        switchOutCurve: ZMotion.exitCurve,
        layoutBuilder: (current, previous) => Stack(fit: StackFit.expand, children: [...previous, if (current != null) current]),
        child: child,
      );
}
