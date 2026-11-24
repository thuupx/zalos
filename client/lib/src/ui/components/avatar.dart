import 'dart:typed_data';

import 'package:material_ui/material_ui.dart';

import '../../domain/services.dart';
import '../theme/tokens.dart';
import '../theme/z_icons.dart';
import '../util/format.dart';
import 'basics.dart';

final Expando<Map<String, Uint8List>> _resolved = Expando('mediaBytes');

Uint8List? cachedMedia(AccountSession session, String url) => _resolved[session]?[url];

/// Resolves media bytes through the account tunnel, remembering them for
/// synchronous reuse by later builds.
Future<Uint8List> loadMedia(AccountSession session, String url) async {
  final hit = _resolved[session]?[url];
  if (hit != null) return hit;
  final bytes = await session.media(url);
  (_resolved[session] ??= {})[url] = bytes;
  return bytes;
}

/// Shows a Zalo media url. Bytes come from [AccountSession.media]; the image
/// is decoded at display size and fades in over the placeholder.
class MediaImage extends StatefulWidget {
  const MediaImage({
    super.key,
    required this.session,
    required this.url,
    this.fit = BoxFit.cover,
    this.width,
    this.height,
    this.placeholder,
    this.errorBuilder,
    this.semanticLabel,
    this.decodeWidth,
  });

  final AccountSession session;
  final String url;
  final BoxFit fit;
  final double? width;
  final double? height;
  final Widget? placeholder;
  final WidgetBuilder? errorBuilder;
  final String? semanticLabel;
  final double? decodeWidth;

  @override
  State<MediaImage> createState() => _MediaImageState();
}

class _MediaImageState extends State<MediaImage> {
  Uint8List? _bytes;
  bool _failed = false;
  bool _sync = false;
  int _generation = 0;

  @override
  void initState() {
    super.initState();
    _resolve();
  }

  @override
  void didUpdateWidget(MediaImage old) {
    super.didUpdateWidget(old);
    if (old.url != widget.url || !identical(old.session, widget.session)) _resolve();
  }

  @override
  void dispose() {
    _generation++;
    super.dispose();
  }

  void _resolve() {
    final generation = ++_generation;
    final url = widget.url;
    _failed = url.isEmpty;
    _bytes = url.isEmpty ? null : cachedMedia(widget.session, url);
    _sync = _bytes != null;
    if (_bytes != null || url.isEmpty) return;
    loadMedia(widget.session, url).then((bytes) {
      if (!mounted || generation != _generation) return;
      setState(() => _bytes = bytes);
    }, onError: (Object _) {
      if (!mounted || generation != _generation) return;
      setState(() => _failed = true);
    });
  }

  Widget _placeholder(BuildContext context) {
    final placeholder = widget.placeholder;
    if (placeholder != null) return placeholder;
    final height = widget.height;
    // The loading shimmer shared with list and chat skeletons.
    if (height != null) return ZSkeleton(width: widget.width, height: height, radius: 0);
    return Container(width: widget.width, height: height, color: context.z.skeleton);
  }

  Widget _error(BuildContext context) {
    if (widget.errorBuilder != null) return widget.errorBuilder!(context);
    final z = context.z;
    return Container(
      width: widget.width,
      height: widget.height,
      color: z.layerPressed,
      alignment: Alignment.center,
      child: Icon(ZIcons.brokenImage, color: z.textTertiary, size: 22),
    );
  }

  @override
  Widget build(BuildContext context) {
    final bytes = _bytes;
    if (_failed) return _error(context);
    if (bytes == null) return _placeholder(context);
    final dpr = MediaQuery.devicePixelRatioOf(context);
    final logical = widget.decodeWidth ?? widget.width ?? widget.height;
    final cacheWidth = logical == null || !logical.isFinite ? null : (logical * dpr * 1.5).ceil();
    return Image.memory(
      bytes,
      width: widget.width,
      height: widget.height,
      fit: widget.fit,
      cacheWidth: cacheWidth,
      gaplessPlayback: true,
      semanticLabel: widget.semanticLabel,
      excludeFromSemantics: widget.semanticLabel == null,
      frameBuilder: (context, child, frame, wasSync) {
        if (wasSync || _sync) return child;
        return Stack(
          fit: StackFit.passthrough,
          children: [
            if (frame == null) Positioned.fill(child: _placeholder(context)),
            AnimatedOpacity(opacity: frame == null ? 0 : 1, duration: ZMotion.enter, curve: ZMotion.standard, child: child),
          ],
        );
      },
      errorBuilder: (context, _, __) => _error(context),
    );
  }
}

@immutable
class AvatarMember {
  const AvatarMember(this.id, this.name, [this.url = '']);
  final String id;
  final String name;
  final String url;
}

enum AvatarStatus { none, online, warning, syncing }

class ZAvatar extends StatelessWidget {
  const ZAvatar({
    super.key,
    required this.session,
    required this.id,
    required this.name,
    this.url = '',
    this.size = 48,
    this.members = const [],
    this.group = false,
    this.status = AvatarStatus.none,
  });

  final AccountSession? session;
  final String id;
  final String name;
  final String url;
  final double size;
  final List<AvatarMember> members;
  final bool group;
  final AvatarStatus status;

  @override
  Widget build(BuildContext context) {
    final z = context.z;
    final s = session;
    Widget fallback(BuildContext context) => group
        ? _Collage(session: s, id: id, name: name, size: size, members: members)
        : _Initials(id: id, name: name, size: size);
    Widget core = ClipOval(
      child: SizedBox(
        width: size,
        height: size,
        child: s == null || url.isEmpty
            ? fallback(context)
            : MediaImage(session: s, url: url, width: size, height: size, placeholder: fallback(context), errorBuilder: fallback),
      ),
    );
    if (status != AvatarStatus.none) {
      final dot = size >= 40 ? 12.0 : 10.0;
      final (Color color, IconData? glyph) = switch (status) {
        AvatarStatus.online => (z.success, null),
        AvatarStatus.warning => (z.danger, ZIcons.priorityHigh),
        AvatarStatus.syncing => (z.warning, ZIcons.sync),
        AvatarStatus.none => (z.success, null),
      };
      final glyphSize = glyph == null ? dot : 14.0;
      core = Stack(
        clipBehavior: Clip.none,
        children: [
          core,
          Positioned(
            right: -1,
            bottom: -1,
            child: Container(
              width: glyphSize,
              height: glyphSize,
              decoration: BoxDecoration(color: color, shape: BoxShape.circle, border: Border.all(color: z.layer, width: 2)),
              child: glyph == null ? null : Icon(glyph, size: 8, color: z.layer),
            ),
          ),
        ],
      );
    }
    return ExcludeSemantics(child: core);
  }
}

class _Initials extends StatelessWidget {
  const _Initials({required this.id, required this.name, required this.size});

  final String id;
  final String name;
  final double size;

  @override
  Widget build(BuildContext context) {
    final z = context.z;
    return Container(
      width: size,
      height: size,
      color: z.avatarColor(id.isEmpty ? name : id),
      alignment: Alignment.center,
      child: Text(
        initialsOf(name),
        maxLines: 1,
        overflow: TextOverflow.clip,
        textScaler: TextScaler.noScaling,
        style: z.text.initials(size, ZalosTokens.white),
      ),
    );
  }
}

class _Collage extends StatelessWidget {
  const _Collage({required this.session, required this.id, required this.name, required this.size, required this.members});

  final AccountSession? session;
  final String id;
  final String name;
  final double size;
  final List<AvatarMember> members;

  @override
  Widget build(BuildContext context) {
    final z = context.z;
    final shown = members.take(4).toList();
    if (shown.length < 2) {
      return Container(
        width: size,
        height: size,
        color: z.avatarColor(id),
        alignment: Alignment.center,
        child: Icon(ZIcons.group, size: size * 0.55, color: ZalosTokens.white, fill: 1),
      );
    }
    final cell = shown.length == 2 ? size * 0.62 : size * 0.54;
    final positions = switch (shown.length) {
      2 => const [Alignment.bottomLeft, Alignment.topRight],
      3 => const [Alignment.topCenter, Alignment.bottomLeft, Alignment.bottomRight],
      _ => const [Alignment.topLeft, Alignment.topRight, Alignment.bottomLeft, Alignment.bottomRight],
    };
    return Container(
      width: size,
      height: size,
      color: z.layerPressed,
      child: Stack(
        children: [
          for (var i = 0; i < shown.length; i++)
            Align(
              alignment: positions[i],
              child: Container(
                decoration: BoxDecoration(shape: BoxShape.circle, border: Border.all(color: z.layer, width: 1)),
                child: ClipOval(
                  child: session != null && shown[i].url.isNotEmpty
                      ? MediaImage(
                          session: session!,
                          url: shown[i].url,
                          width: cell,
                          height: cell,
                          placeholder: _Initials(id: shown[i].id, name: shown[i].name, size: cell),
                          errorBuilder: (_) => _Initials(id: shown[i].id, name: shown[i].name, size: cell),
                        )
                      : _Initials(id: shown[i].id, name: shown[i].name, size: cell),
                ),
              ),
            ),
        ],
      ),
    );
  }
}
