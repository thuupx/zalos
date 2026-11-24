// Zalo sticker renderer: supports still 130x130 PNG/WebP, animated WebP,
// and Zalo horizontal sprite-sheet frame animation.
import 'dart:async';
import 'dart:typed_data';
import 'dart:ui' as ui;

import 'package:material_ui/material_ui.dart';

import '../../domain/models.dart';
import '../../domain/services.dart';
import '../components/avatar.dart';
import '../components/basics.dart';
import '../theme/tokens.dart';
import '../theme/z_icons.dart';

/// Renders a Zalo [StickerRef] reliably in both the sticker picker and chat
/// bubbles.
///
/// Always resolves a fallback CDN URL when [StickerRef.url] is missing, retries
/// once on transient media fetch errors, and optionally plays Zalo sprite-sheet
/// or animated WebP stickers when [animate] is true and reduced motion is off.
class ZStickerView extends StatefulWidget {
  const ZStickerView({
    super.key,
    required this.session,
    required this.sticker,
    this.size,
    this.animate = false,
    this.semanticLabel,
    this.placeholder,
    this.errorBuilder,
  });

  final AccountSession session;
  final StickerRef sticker;
  final double? size;
  final bool animate;
  final String? semanticLabel;
  final Widget? placeholder;
  final WidgetBuilder? errorBuilder;

  @override
  State<ZStickerView> createState() => _ZStickerViewState();
}

class _ZStickerViewState extends State<ZStickerView> {
  Uint8List? _stillBytes;
  bool _failed = false;
  bool _sync = false;
  Uint8List? _animatedWebpBytes;
  ui.Image? _spriteSheet;
  int _frameIndex = 0;
  Timer? _frameTimer;
  Timer? _retryTimer;
  int _generation = 0;

  @override
  void initState() {
    super.initState();
    _load();
  }

  @override
  void didUpdateWidget(ZStickerView old) {
    super.didUpdateWidget(old);
    if (old.sticker.id != widget.sticker.id ||
        old.sticker.url != widget.sticker.url ||
        old.sticker.spriteUrl != widget.sticker.spriteUrl ||
        old.animate != widget.animate ||
        !identical(old.session, widget.session)) {
      _load();
    }
  }

  @override
  void dispose() {
    _generation++;
    _stopTimers();
    _spriteSheet?.dispose();
    _spriteSheet = null;
    super.dispose();
  }

  void _stopTimers() {
    _frameTimer?.cancel();
    _frameTimer = null;
    _retryTimer?.cancel();
    _retryTimer = null;
  }

  void _load() {
    final generation = ++_generation;
    _stopTimers();
    _spriteSheet?.dispose();
    _spriteSheet = null;
    _animatedWebpBytes = null;
    _frameIndex = 0;

    final url = widget.sticker.resolvedUrl ?? '';
    _failed = url.isEmpty;
    _stillBytes = url.isEmpty ? null : cachedMedia(widget.session, url);
    _sync = _stillBytes != null;

    if (_stillBytes == null && url.isNotEmpty) {
      _fetchStill(url, generation, allowRetry: true);
    }

    if (widget.animate && widget.sticker.hasAnimation) {
      _fetchAnimation(generation);
    }
  }

  void _fetchStill(String url, int generation, {required bool allowRetry}) {
    loadMedia(widget.session, url).then((bytes) {
      if (!mounted || generation != _generation) return;
      setState(() {
        _stillBytes = bytes;
        _failed = false;
      });
    }, onError: (Object _) {
      if (!mounted || generation != _generation) return;
      if (allowRetry) {
        _retryTimer = Timer(const Duration(milliseconds: 450), () {
          if (!mounted || generation != _generation) return;
          _fetchStill(url, generation, allowRetry: false);
        });
      } else {
        setState(() => _failed = true);
      }
    });
  }

  Future<void> _fetchAnimation(int generation) async {
    final spriteUrl = widget.sticker.spriteUrl;
    if (spriteUrl == null || spriteUrl.isEmpty) return;
    try {
      final bytes = await loadMedia(widget.session, spriteUrl);
      if (!mounted || generation != _generation) return;
      if (widget.sticker.animatedWebp) {
        setState(() => _animatedWebpBytes = bytes);
        return;
      }
      final frames = widget.sticker.frames ?? 0;
      if (frames < 2) return;
      final codec = await ui.instantiateImageCodec(bytes);
      final frameInfo = await codec.getNextFrame();
      codec.dispose();
      final sheet = frameInfo.image;
      if (!mounted || generation != _generation) {
        sheet.dispose();
        return;
      }
      final frameW = sheet.width / frames;
      // Only animate valid horizontal strips of square-ish frames.
      if (frameW <= 0 || (frameW - sheet.height).abs() > 6) {
        sheet.dispose();
        return;
      }
      _spriteSheet?.dispose();
      _spriteSheet = sheet;
      final ms = (widget.sticker.durationMs ?? 180).clamp(40, 600);
      _frameTimer = Timer.periodic(Duration(milliseconds: ms), (_) {
        if (!mounted || generation != _generation) return;
        setState(() => _frameIndex = (_frameIndex + 1) % frames);
      });
      setState(() {});
    } catch (_) {
      // Keep rendering the crisp still sticker underneath.
    }
  }

  Widget _placeholder(BuildContext context) {
    if (widget.placeholder != null) return widget.placeholder!;
    final s = widget.size;
    if (s != null) {
      return ZSkeleton(
        width: s,
        height: s,
        radius: ZRadius.input,
      );
    }
    return Container(
      decoration: BoxDecoration(
        color: context.z.skeleton,
        borderRadius: BorderRadius.circular(ZRadius.input),
      ),
    );
  }

  Widget _error(BuildContext context) {
    if (widget.errorBuilder != null) return widget.errorBuilder!(context);
    final z = context.z;
    return Container(
      width: widget.size,
      height: widget.size,
      decoration: BoxDecoration(
        color: z.layerSubtle,
        borderRadius: BorderRadius.circular(ZRadius.input),
      ),
      alignment: Alignment.center,
      child: Icon(ZIcons.sticker, color: z.textTertiary, size: 26),
    );
  }

  @override
  Widget build(BuildContext context) {
    final reduced = ZMotion.reduced(context);
    final s = widget.size;

    // 1. Animated WebP sprite
    final animWebp = _animatedWebpBytes;
    if (widget.animate && !reduced && animWebp != null) {
      return SizedBox(
        width: s,
        height: s,
        child: Image.memory(
          animWebp,
          width: s,
          height: s,
          fit: BoxFit.contain,
          gaplessPlayback: true,
          semanticLabel: widget.semanticLabel,
          excludeFromSemantics: widget.semanticLabel == null,
          errorBuilder: (_, __, ___) => _buildStill(context),
        ),
      );
    }

    // 2. Horizontal sprite-sheet frame animation
    final sheet = _spriteSheet;
    final frames = widget.sticker.frames ?? 0;
    if (widget.animate && !reduced && sheet != null && frames >= 2) {
      final paint = CustomPaint(
        size: s != null ? Size.square(s) : Size.zero,
        painter: _SpriteFramePainter(
          sheet: sheet,
          frames: frames,
          index: _frameIndex % frames,
        ),
      );
      final box = SizedBox(width: s, height: s, child: paint);
      return widget.semanticLabel == null
          ? ExcludeSemantics(child: box)
          : Semantics(label: widget.semanticLabel, image: true, child: box);
    }

    // 3. Crisp still PNG/WebP sticker
    return _buildStill(context);
  }

  Widget _buildStill(BuildContext context) {
    final bytes = _stillBytes;
    if (_failed) return _error(context);
    if (bytes == null) return _placeholder(context);
    final s = widget.size;
    return Image.memory(
      bytes,
      width: s,
      height: s,
      fit: BoxFit.contain,
      gaplessPlayback: true,
      semanticLabel: widget.semanticLabel,
      excludeFromSemantics: widget.semanticLabel == null,
      frameBuilder: (context, child, frame, wasSync) {
        if (wasSync || _sync) return child;
        return Stack(
          fit: StackFit.passthrough,
          children: [
            if (frame == null) Positioned.fill(child: _placeholder(context)),
            AnimatedOpacity(
              opacity: frame == null ? 0 : 1,
              duration: ZMotion.enter,
              curve: ZMotion.standard,
              child: child,
            ),
          ],
        );
      },
      errorBuilder: (context, _, __) => _error(context),
    );
  }
}

class _SpriteFramePainter extends CustomPainter {
  const _SpriteFramePainter({
    required this.sheet,
    required this.frames,
    required this.index,
  });

  final ui.Image sheet;
  final int frames;
  final int index;

  @override
  void paint(Canvas canvas, Size size) {
    final frameW = sheet.width / frames;
    final frameH = sheet.height.toDouble();
    final src = Rect.fromLTWH(index * frameW, 0, frameW, frameH);
    final fitted = applyBoxFit(BoxFit.contain, Size(frameW, frameH), size);
    final dst = Alignment.center.inscribe(fitted.destination, Offset.zero & size);
    canvas.drawImageRect(
      sheet,
      src,
      dst,
      Paint()..filterQuality = FilterQuality.medium,
    );
  }

  @override
  bool shouldRepaint(_SpriteFramePainter old) =>
      old.sheet != sheet || old.index != index || old.frames != frames;
}
