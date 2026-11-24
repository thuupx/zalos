import 'dart:ui' show FlutterView;

import 'package:material_ui/material_ui.dart';

import '../theme/tokens.dart';
import 'motion.dart';

/// Frame of the screens shown before the app is usable: pairing and the
/// vault waiting screen. Wide layouts center a card on the warm page
/// backdrop; compact layouts stay edge to edge and scroll.
///
/// Compact layouts also keep the end of the form, the primary action and the
/// field above it, above the software keyboard. [Scaffold] already shrinks the
/// body by the keyboard inset, so this scrolls the form into the smaller
/// viewport instead of applying the inset a second time.
class ZOnboardingFrame extends StatefulWidget {
  const ZOnboardingFrame({super.key, required this.child, this.maxWidth = 400, this.header});

  /// Content of the screen, kept at [maxWidth].
  final Widget child;

  /// Widest the content grows on wide layouts.
  final double maxWidth;

  /// Full width strip above the content, outside its scroll area: banners.
  final Widget? header;

  @override
  State<ZOnboardingFrame> createState() => _ZOnboardingFrameState();
}

class _ZOnboardingFrameState extends State<ZOnboardingFrame> with WidgetsBindingObserver {
  final GlobalKey _formKey = GlobalKey();
  FlutterView? _view;
  double _keyboardInset = 0;
  bool _revealScheduled = false;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    FocusManager.instance.addListener(_onFocusChanged);
  }

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    _view = View.of(context);
    _syncKeyboardInset();
  }

  @override
  void didChangeMetrics() => _syncKeyboardInset();

  @override
  void dispose() {
    FocusManager.instance.removeListener(_onFocusChanged);
    WidgetsBinding.instance.removeObserver(this);
    super.dispose();
  }

  /// Reads the keyboard inset from the view: while [Scaffold] resizes its body
  /// it removes the bottom view inset from the body's [MediaQuery], so the raw
  /// view value is the one that still reports the keyboard.
  void _syncKeyboardInset() {
    final view = _view;
    if (view == null) return;
    final inset = view.viewInsets.bottom / view.devicePixelRatio;
    final grew = inset > _keyboardInset;
    _keyboardInset = inset;
    if (inset > 0 && grew) _scheduleReveal();
  }

  void _onFocusChanged() {
    if (_keyboardInset <= 0) return;
    final focused = FocusManager.instance.primaryFocus?.context;
    if (focused == null || !_owns(focused)) return;
    _scheduleReveal();
  }

  bool _owns(BuildContext focused) {
    if (identical(focused, context)) return true;
    var owns = false;
    focused.visitAncestorElements((element) {
      owns = identical(element, context);
      return !owns;
    });
    return owns;
  }

  void _scheduleReveal() {
    if (_revealScheduled || LayoutScope.wideOf(context)) return;
    _revealScheduled = true;
    WidgetsBinding.instance.addPostFrameCallback((_) {
      _revealScheduled = false;
      if (!mounted) return;
      // Let the focused field reveal its caret first, then pull the end of the
      // form up so the action above the keyboard stays reachable.
      Future<void>.microtask(_revealFormEnd);
    });
  }

  void _revealFormEnd() {
    final target = _formKey.currentContext;
    if (!mounted || target == null) return;
    Scrollable.ensureVisible(
      target,
      alignmentPolicy: ScrollPositionAlignmentPolicy.keepVisibleAtEnd,
      duration: ZMotion.of(context, ZMotion.fast),
      curve: ZMotion.enterCurve,
    );
  }

  @override
  Widget build(BuildContext context) {
    final z = context.z;
    final wide = LayoutScope.wideOf(context);
    final content = ConstrainedBox(key: _formKey, constraints: BoxConstraints(maxWidth: widget.maxWidth), child: widget.child);
    return ColoredBox(
      color: wide ? z.layerSubtle : z.layer,
      child: SafeArea(
        child: Column(
          children: [
            if (widget.header != null) widget.header!,
            Expanded(
              child: Center(
                child: SingleChildScrollView(
                  padding: wide ? const EdgeInsets.all(ZSpace.s24) : const EdgeInsets.symmetric(horizontal: ZSpace.s20, vertical: ZSpace.s24),
                  child: wide
                      ? ZPopIn(
                          from: 0.98,
                          duration: ZMotion.medium,
                          child: DecoratedBox(
                            decoration: BoxDecoration(color: z.layer, borderRadius: BorderRadius.circular(ZRadius.card), border: Border.all(color: z.divider), boxShadow: z.shadowOverlay),
                            child: Padding(padding: const EdgeInsets.all(ZSpace.s32), child: SizedBox(width: widget.maxWidth, child: widget.child)),
                          ),
                        )
                      : content,
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }
}
