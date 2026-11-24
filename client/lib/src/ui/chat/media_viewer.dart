import 'dart:ui' as ui;

import 'package:material_ui/material_ui.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../domain/models.dart';
import '../../domain/services.dart';
import '../components/avatar.dart';
import '../components/overlays.dart';
import '../components/pressable.dart';
import '../l10n/strings.dart';
import '../platform/services.dart';
import '../theme/tokens.dart';
import '../theme/z_icons.dart';
import '../util/format.dart';
import 'message_content.dart' show mediaHeroShuttle;

@immutable
class ViewerItem {
  const ViewerItem({required this.attachment, required this.senderName, this.ts, this.heroTag});
  final Attachment attachment;
  final String senderName;

  /// Tag of the bubble thumbnail the picture flies from and back to.
  final String? heroTag;

  /// Send time shown under the sender; null for pictures that are not
  /// messages, e.g. a profile picture.
  final int? ts;

  bool get isVideo => attachment.kind == MessageKind.video;
}

Future<void> showMediaViewer(BuildContext context, AccountSession session, List<ViewerItem> items, int initial) {
  final strings = context.s;
  final layout = LayoutScope.of(context);
  return Navigator.of(context, rootNavigator: true).push<void>(
    PageRouteBuilder<void>(
      opaque: false,
      barrierColor: ZalosTokens.black,
      transitionDuration: ZMotion.medium,
      reverseTransitionDuration: ZMotion.exit,
      pageBuilder: (_, __, ___) => StringsScope(strings: strings, child: LayoutScope(layout: layout, child: MediaViewer(session: session, items: items, initial: initial))),
      transitionsBuilder: (_, animation, __, child) =>
          FadeTransition(opacity: CurvedAnimation(parent: animation, curve: ZMotion.enterCurve, reverseCurve: ZMotion.exitCurve), child: child),
    ),
  );
}

class MediaViewer extends ConsumerStatefulWidget {
  const MediaViewer({super.key, required this.session, required this.items, required this.initial});

  final AccountSession session;
  final List<ViewerItem> items;
  final int initial;

  @override
  ConsumerState<MediaViewer> createState() => _MediaViewerState();
}

class _MediaViewerState extends ConsumerState<MediaViewer> {
  late final PageController _pages = PageController(initialPage: widget.initial);
  late int _index = widget.initial;
  final TransformationController _transform = TransformationController();
  final FocusNode _focus = FocusNode(debugLabel: 'mediaViewer');
  Offset _doubleTapAt = Offset.zero;
  double _dragDown = 0;
  bool _busy = false;

  bool get _zoomed => _transform.value.getMaxScaleOnAxis() > 1.01;

  @override
  void initState() {
    super.initState();
    HardwareKeyboard.instance.addHandler(_onKey);
  }

  bool _onKey(KeyEvent event) {
    if (event is! KeyDownEvent || !mounted || !(ModalRoute.of(context)?.isCurrent ?? false)) return false;
    if (event.logicalKey == LogicalKeyboardKey.escape) {
      Navigator.of(context).maybePop();
    } else if (event.logicalKey == LogicalKeyboardKey.arrowLeft) {
      _go(-1);
    } else if (event.logicalKey == LogicalKeyboardKey.arrowRight) {
      _go(1);
    } else {
      return false;
    }
    return true;
  }

  @override
  void dispose() {
    HardwareKeyboard.instance.removeHandler(_onKey);
    _pages.dispose();
    _transform.dispose();
    _focus.dispose();
    super.dispose();
  }

  void _go(int delta) {
    final next = (_index + delta).clamp(0, widget.items.length - 1);
    if (next == _index) return;
    _transform.value = Matrix4.identity();
    if (ZMotion.reduced(context)) {
      _pages.jumpToPage(next);
    } else {
      _pages.animateToPage(next, duration: ZMotion.medium, curve: ZMotion.enterCurve);
    }
  }

  Widget _hero(ViewerItem item, Widget child) {
    final tag = item.heroTag;
    if (tag == null || ZMotion.reduced(context)) return child;
    return Hero(tag: tag, flightShuttleBuilder: mediaHeroShuttle(widget.session, item.attachment), child: child);
  }

  /// Spoken summary of the current page: what it is, whose it is and where it
  /// sits in the set. It is a live region, so swiping announces the new page.
  String _viewerLabel(ViewerItem item) {
    final type = context.tr(item.isVideo ? 'previewVideo' : 'previewImage');
    final position = widget.items.length > 1 ? ' ${_index + 1}/${widget.items.length}' : '';
    return '$type, ${item.senderName}$position';
  }

  void _toggleZoom() {
    if (_zoomed) {
      _transform.value = Matrix4.identity();
    } else {
      const scale = 2.5;
      _transform.value = Matrix4.identity()
        ..translateByDouble(-_doubleTapAt.dx * (scale - 1), -_doubleTapAt.dy * (scale - 1), 0.0, 1.0)
        ..scaleByDouble(scale, scale, scale, 1.0);
    }
    setState(() {});
  }

  Future<void> _save({required bool share}) async {
    if (_busy) return;
    final item = widget.items[_index];
    final platform = ref.read(platformProvider);
    final saved = context.tr('fileSaved');
    final failed = context.tr('downloadFailed');
    setState(() => _busy = true);
    try {
      final bytes = await loadMedia(widget.session, item.attachment.url);
      final stamp = item.ts ?? DateTime.now().millisecondsSinceEpoch;
      final name = item.attachment.name ?? (item.isVideo ? 'video-$stamp.mp4' : 'image-$stamp.jpg');
      final path = share ? null : await platform.saveToDownloads(name, bytes);
      if (path == null) {
        await platform.share(name, bytes);
      } else if (mounted) {
        zToast(context, saved);
      }
    } catch (_) {
      if (mounted) zToast(context, failed);
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final z = context.z;
    final item = widget.items[_index];
    final white = z.text.label.copyWith(color: ZalosTokens.white);
    final caption = [
      if (item.ts case final ts?) formatDateTime(ts, context.s),
      if (item.ts != null || widget.items.length > 1) '${_index + 1}/${widget.items.length}',
    ].join('  ');
    return FocusScope(
      child: Focus(
        focusNode: _focus,
        autofocus: true,
        child: Scaffold(
          key: const Key('mediaViewer'),
          backgroundColor: ZalosTokens.clear,
          body: Stack(
            fit: StackFit.expand,
            children: [
              GestureDetector(
                onVerticalDragUpdate: _zoomed ? null : (d) => setState(() => _dragDown = (_dragDown + d.delta.dy).clamp(0.0, 400.0)),
                onVerticalDragCancel: _zoomed ? null : () => setState(() => _dragDown = 0),
                onVerticalDragEnd: _zoomed
                    ? null
                    : (_) {
                        if (_dragDown > 120) {
                          Navigator.of(context).maybePop().then((popped) {
                            // Nothing was dismissed: put the picture back.
                            if (!popped && mounted) setState(() => _dragDown = 0);
                          });
                        } else {
                          setState(() => _dragDown = 0);
                        }
                      },
                child: Transform.translate(
                  offset: Offset(0, _dragDown),
                  child: Opacity(
                    opacity: (1 - _dragDown / 400).clamp(0.3, 1.0),
                    child: Semantics(
                      key: const Key('viewerSemantics'),
                      container: true,
                      liveRegion: true,
                      label: _viewerLabel(item),
                      child: PageView.builder(
                        controller: _pages,
                        physics: _zoomed ? const NeverScrollableScrollPhysics() : null,
                        itemCount: widget.items.length,
                        onPageChanged: (i) {
                          _focus.requestFocus();
                          setState(() {
                            _index = i;
                            _transform.value = Matrix4.identity();
                          });
                        },
                        itemBuilder: (context, i) {
                          final it = widget.items[i];
                          if (it.isVideo) return _VideoPage(key: ValueKey('video-${it.attachment.url}'), session: widget.session, item: it, active: i == _index);
                          return GestureDetector(
                            onDoubleTapDown: (d) => _doubleTapAt = d.localPosition,
                            onDoubleTap: _toggleZoom,
                            child: InteractiveViewer(
                              transformationController: i == _index ? _transform : null,
                              minScale: 1,
                              maxScale: 6,
                              onInteractionEnd: (_) => setState(() {}),
                              child: Center(
                                child: _hero(
                                  it,
                                  MediaImage(
                                    session: widget.session,
                                    url: it.attachment.url,
                                    fit: BoxFit.contain,
                                    semanticLabel: context.tr('previewImage'),
                                    errorBuilder: (context) => Column(
                                      key: const Key('viewerImageFailed'),
                                      mainAxisSize: MainAxisSize.min,
                                      children: [
                                        const Icon(ZIcons.brokenImage, color: ZalosTokens.white, size: 48),
                                        const SizedBox(height: ZSpace.s8),
                                        Text(context.tr('imageLoadFailed'), style: z.text.label.copyWith(color: ZalosTokens.white)),
                                      ],
                                    ),
                                    placeholder: it.attachment.thumbUrl == null
                                        ? const SizedBox.shrink()
                                        : ImageFiltered(
                                            imageFilter: ui.ImageFilter.blur(sigmaX: 12, sigmaY: 12),
                                            child: MediaImage(session: widget.session, url: it.attachment.thumbUrl!, fit: BoxFit.contain),
                                          ),
                                  ),
                                ),
                              ),
                            ),
                          );
                        },
                      ),
                    ),
                  ),
                ),
              ),
              Positioned(
                top: 0,
                left: 0,
                right: 0,
                child: Container(
                  color: ZalosTokens.viewerBar,
                  child: SafeArea(
                    bottom: false,
                    child: Padding(
                      padding: const EdgeInsets.symmetric(horizontal: ZSpace.s8, vertical: ZSpace.s4),
                      child: Row(
                        children: [
                          _ViewerButton(key: const Key('viewerClose'), icon: ZIcons.close, label: context.tr('close'), onTap: () => Navigator.of(context).maybePop()),
                          const SizedBox(width: ZSpace.s8),
                          Expanded(
                            child: Column(
                              crossAxisAlignment: CrossAxisAlignment.start,
                              mainAxisSize: MainAxisSize.min,
                              children: [
                                Text(item.senderName, maxLines: 1, overflow: TextOverflow.ellipsis, style: white),
                                if (caption.isNotEmpty)
                                  Text(
                                    caption,
                                    key: const Key('viewerCounter'),
                                    maxLines: 1,
                                    overflow: TextOverflow.ellipsis,
                                    style: z.text.caption.copyWith(color: ZalosTokens.white),
                                  ),
                              ],
                            ),
                          ),
                          _ViewerButton(key: const Key('viewerDownload'), icon: ZIcons.download, label: context.tr('download'), onTap: _busy ? null : () => _save(share: false)),
                          _ViewerButton(key: const Key('viewerShare'), icon: ZIcons.share, label: context.tr('share'), onTap: _busy ? null : () => _save(share: true)),
                        ],
                      ),
                    ),
                  ),
                ),
              ),
              if (LayoutScope.wideOf(context) && widget.items.length > 1) ...[
                if (_index > 0)
                  Align(
                    alignment: Alignment.centerLeft,
                    child: Padding(
                      padding: const EdgeInsets.all(ZSpace.s16),
                      child: _ViewerButton(key: const Key('viewerPrev'), icon: ZIcons.chevronLeft, label: context.tr('previous'), onTap: () => _go(-1), plate: true),
                    ),
                  ),
                if (_index < widget.items.length - 1)
                  Align(
                    alignment: Alignment.centerRight,
                    child: Padding(
                      padding: const EdgeInsets.all(ZSpace.s16),
                      child: _ViewerButton(key: const Key('viewerNext'), icon: ZIcons.chevronRight, label: context.tr('next'), onTap: () => _go(1), plate: true),
                    ),
                  ),
              ],
            ],
          ),
        ),
      ),
    );
  }
}

class _ViewerButton extends StatelessWidget {
  const _ViewerButton({super.key, required this.icon, required this.label, required this.onTap, this.plate = false});

  final IconData icon;
  final String label;
  final VoidCallback? onTap;
  final bool plate;

  @override
  Widget build(BuildContext context) {
    return ZPressable(
      onTap: onTap,
      circle: true,
      color: plate ? ZalosTokens.viewerBar : null,
      hoverColor: ZalosTokens.mediaHover,
      pressedColor: ZalosTokens.mediaChip,
      tooltip: label,
      semanticLabel: label,
      child: SizedBox(width: 44, height: 44, child: Icon(icon, color: onTap == null ? ZalosTokens.mediaChip : ZalosTokens.white, size: 24)),
    );
  }
}

class _VideoPage extends ConsumerStatefulWidget {
  const _VideoPage({super.key, required this.session, required this.item, required this.active});

  final AccountSession session;
  final ViewerItem item;
  final bool active;

  @override
  ConsumerState<_VideoPage> createState() => _VideoPageState();
}

class _VideoPageState extends ConsumerState<_VideoPage> {
  PlaybackHandle? _handle;
  bool _failed = false;
  bool _disposed = false;

  /// Set from the first open request until it finishes, so a page that is
  /// swiped back and forth never downloads and materializes twice.
  bool _opening = false;

  @override
  void initState() {
    super.initState();
    // Neighbours stay untouched: no download, no player, until they are the
    // page on screen.
    if (widget.active) _open();
  }

  Future<void> _open() async {
    if (_opening || _handle != null || _failed) return;
    _opening = true;
    final platform = ref.read(platformProvider);
    try {
      final bytes = await loadMedia(widget.session, widget.item.attachment.url);
      final uri = await platform.materialize(widget.item.attachment.name ?? 'video.mp4', bytes);
      if (_disposed) return;
      final handle = platform.createPlayer(video: true);
      _handle = handle;
      await handle.open(uri, play: widget.active);
      if (_disposed) return;
      if (widget.active && !handle.status.value.playing) await handle.play();
      if (!_disposed) setState(() {});
    } catch (_) {
      if (!_disposed) setState(() => _failed = true);
    }
  }

  @override
  void didUpdateWidget(_VideoPage old) {
    super.didUpdateWidget(old);
    if (old.active && !widget.active) _handle?.pause();
    if (!old.active && widget.active) {
      final handle = _handle;
      if (handle == null) {
        _open();
      } else {
        handle.play();
      }
    }
  }

  @override
  void dispose() {
    _disposed = true;
    _handle?.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final z = context.z;
    final handle = _handle;
    final white = z.text.caption.copyWith(color: ZalosTokens.white);
    if (_failed) {
      return Center(child: Text(context.tr('playFailed'), key: const Key('videoFailed'), style: z.text.label.copyWith(color: ZalosTokens.white)));
    }
    final thumb = widget.item.attachment.thumbUrl;
    if (handle == null) {
      final cover = thumb == null ? const SizedBox.shrink() : Center(child: MediaImage(session: widget.session, url: thumb, fit: BoxFit.contain));
      if (!widget.active) return cover;
      return Stack(
        fit: StackFit.expand,
        children: [
          cover,
          const Center(child: SizedBox(width: 32, height: 32, child: CircularProgressIndicator(strokeWidth: 3, color: ZalosTokens.white))),
        ],
      );
    }
    return ValueListenableBuilder<PlaybackStatus>(
      valueListenable: handle.status,
      builder: (context, status, _) {
        final total = status.duration.inMilliseconds > 0 ? status.duration.inMilliseconds : (widget.item.attachment.durationMs ?? 0);
        final position = status.position.inMilliseconds.clamp(0, total <= 0 ? 0 : total);
        final playing = status.playing && !status.completed;
        return Stack(
          fit: StackFit.expand,
          children: [
            Center(child: handle.video()),
            Positioned(
              left: 0,
              right: 0,
              bottom: 0,
              child: Container(
                key: const Key('videoControls'),
                color: ZalosTokens.viewerBar,
                child: SafeArea(
                  top: false,
                  child: Padding(
                    padding: const EdgeInsets.symmetric(horizontal: ZSpace.s8, vertical: ZSpace.s4),
                    child: Row(
                      children: [
                        _ViewerButton(
                          key: const Key('videoPlayPause'),
                          icon: playing ? ZIcons.pause : ZIcons.play,
                          label: context.tr(playing ? 'pause' : 'play'),
                          onTap: () async {
                            if (playing) {
                              await handle.pause();
                            } else {
                              if (status.completed) await handle.seek(Duration.zero);
                              await handle.play();
                            }
                          },
                        ),
                        Text(formatDuration(position), style: white),
                        Expanded(
                          child: SliderTheme(
                            data: const SliderThemeData(
                              trackHeight: 3,
                              activeTrackColor: ZalosTokens.white,
                              inactiveTrackColor: ZalosTokens.mediaChip,
                              thumbColor: ZalosTokens.white,
                              overlayColor: ZalosTokens.mediaHover,
                              thumbShape: RoundSliderThumbShape(enabledThumbRadius: 6),
                            ),
                            child: Slider(
                              value: total <= 0 ? 0 : position / total,
                              semanticFormatterCallback: (v) => formatDuration((v * total).round()),
                              onChanged: total <= 0 ? null : (v) => handle.seek(Duration(milliseconds: (v * total).round())),
                            ),
                          ),
                        ),
                        Text(formatDuration(total), style: white),
                        const SizedBox(width: ZSpace.s8),
                      ],
                    ),
                  ),
                ),
              ),
            ),
          ],
        );
      },
    );
  }
}
