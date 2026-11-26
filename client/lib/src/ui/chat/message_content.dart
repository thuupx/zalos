import 'package:flutter/gestures.dart';
import 'dart:ui' as ui;

import 'package:flutter/services.dart';
import 'package:material_ui/material_ui.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../domain/models.dart';
import '../../domain/services.dart';
import '../components/avatar.dart';
import '../components/basics.dart';
import '../components/overlays.dart';
import '../components/pressable.dart';
import '../l10n/strings.dart';
import '../platform/services.dart';
import '../state/app_state.dart';
import '../state/media.dart';
import '../theme/tokens.dart';
import '../theme/z_icons.dart';
import '../util/format.dart';
import '../util/style_runs.dart';

/// Message text with links, mentions and search matches. Selectable with a
/// pointer.
class MessageText extends StatefulWidget {
  const MessageText({
    super.key,
    required this.text,
    required this.mentions,
    required this.style,
    required this.selectable,
    required this.onOpenLink,
    this.onOpenMention,
    this.styles = const [],
    this.query = '',
  });

  final String text;
  final List<Mention> mentions;

  /// Inline style runs of the message body.
  final List<StyleRun> styles;
  final TextStyle style;
  final bool selectable;
  final ValueChanged<String> onOpenLink;
  final ValueChanged<Mention>? onOpenMention;
  final String query;

  @override
  State<MessageText> createState() => _MessageTextState();
}

class _MessageTextState extends State<MessageText> {
  final List<TapGestureRecognizer> _recognizers = [];

  @override
  void dispose() {
    for (final r in _recognizers) {
      r.dispose();
    }
    super.dispose();
  }

  List<InlineSpan> _spans(ZalosTokens z) {
    for (final r in _recognizers) {
      r.dispose();
    }
    _recognizers.clear();
    final text = widget.text;
    if (text.isEmpty) return const <InlineSpan>[];
    final marks =
        <({int start, int end, int kind, String? url, Mention? mention})>[];
    for (final m in widget.mentions) {
      final start = m.pos.clamp(0, text.length);
      final end = (m.pos + m.len).clamp(start, text.length);
      if (end > start) {
        marks.add((start: start, end: end, kind: 0, url: null, mention: m));
      }
    }
    for (final m in urlMatches(text)) {
      if (marks.any((k) => m.start < k.end && m.end > k.start)) continue;
      marks.add((start: m.start, end: m.end, kind: 1, url: m.group(0), mention: null));
    }
    final hit = widget.query.isEmpty ? null : foldMatch(text, widget.query);
    if (hit != null &&
        hit.end > hit.start &&
        !marks.any((k) => hit.start < k.end && hit.end > k.start)) {
      marks.add((start: hit.start, end: hit.end, kind: 2, url: null, mention: null));
    }
    marks.sort((a, b) => a.start.compareTo(b.start));

    final cuts = <int>{0, text.length};
    for (final mark in marks) {
      cuts.add(mark.start);
      cuts.add(mark.end);
    }
    for (final run in widget.styles) {
      if (run.len <= 0) continue;
      cuts.add(run.start.clamp(0, text.length));
      cuts.add((run.start + run.len).clamp(0, text.length));
    }
    final points = cuts.toList()..sort();
    final spans = <InlineSpan>[];
    final recognizers = <int, TapGestureRecognizer>{};
    for (var i = 0; i < points.length - 1; i++) {
      final start = points[i];
      final end = points[i + 1];
      if (end <= start) continue;
      final part = text.substring(start, end);
      var markIndex = -1;
      for (var j = 0; j < marks.length; j++) {
        final mark = marks[j];
        if (mark.start <= start && mark.end >= end) {
          markIndex = j;
          break;
        }
      }
      final mark = markIndex < 0 ? null : marks[markIndex];
      final codes = <String>[
        for (final run in widget.styles)
          if (run.len > 0 && run.start <= start && run.start + run.len >= end)
            run.st,
      ];
      var base = const TextStyle();
      switch (mark?.kind) {
        case 0:
          base = TextStyle(color: z.brandText, fontWeight: FontWeight.w600);
        case 1:
          base = TextStyle(
              color: z.brandText,
              decoration: TextDecoration.underline,
              decorationColor: z.brandText);
        case 2:
          base = TextStyle(backgroundColor: z.accent, color: z.onAccent);
      }
      final style = applyStyleRuns(base, codes, z);
      if (mark?.kind == 0 && widget.onOpenMention != null) {
        final tagged = mark!;
        final recognizer = recognizers.putIfAbsent(
            markIndex,
            () => TapGestureRecognizer()
              ..onTap = () => widget.onOpenMention!(tagged.mention!));
        spans.add(TextSpan(
          text: part,
          recognizer: recognizer,
          mouseCursor: SystemMouseCursors.click,
          semanticsLabel: part,
          style: style,
        ));
      } else if (mark?.kind == 1) {
        final link = mark!;
        final recognizer = recognizers.putIfAbsent(
            markIndex,
            () => TapGestureRecognizer()
              ..onTap = () => widget.onOpenLink(link.url!));
        spans.add(TextSpan(
          text: part,
          recognizer: recognizer,
          mouseCursor: SystemMouseCursors.click,
          semanticsLabel: part,
          style: style,
        ));
      } else {
        spans.add(TextSpan(text: part, style: style));
      }
    }
    _recognizers.addAll(recognizers.values);
    return spans;
  }

  @override
  Widget build(BuildContext context) {
    final span = TextSpan(children: _spans(context.z));
    if (widget.selectable) {
      return SelectableText.rich(
        span,
        style: widget.style,
        contextMenuBuilder: (_, state) =>
            AdaptiveTextSelectionToolbar.buttonItems(
          anchors: state.contextMenuAnchors,
          buttonItems: state.contextMenuButtonItems,
        ),
      );
    }
    return Text.rich(span, style: widget.style);
  }
}

class QuoteBlock extends StatelessWidget {
  const QuoteBlock(
      {super.key,
      required this.quote,
      required this.text,
      required this.outgoing,
      required this.onTap,
      this.name});

  final Quote quote;

  /// Preview line under the sender; empty hides it.
  final String text;
  final bool outgoing;
  final VoidCallback onTap;
  final String? name;

  @override
  Widget build(BuildContext context) {
    final z = context.z;
    return ZPressable(
      onTap: onTap,
      radius: ZRadius.tight,
      color: outgoing ? z.bubbleOutPressed : z.layerSubtle,
      hoverColor: outgoing ? z.bubbleOutPressed : z.layerHover,
      pressedColor: z.layerPressed,
      semanticLabel: context.tr('quoteLabel', [name ?? quote.senderName, text]),
      child: IntrinsicHeight(
        child: Row(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Container(width: 3, decoration: BoxDecoration(color: z.quoteBar, borderRadius: const BorderRadius.horizontal(left: Radius.circular(ZRadius.tight)))),
            Flexible(
              child: Padding(
                padding: const EdgeInsets.fromLTRB(ZSpace.s8, 6, ZSpace.s8, 6),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    Text(name ?? quote.senderName, maxLines: 1, overflow: TextOverflow.ellipsis, style: z.text.captionStrong),
                    if (text.isNotEmpty) Text(text, maxLines: 1, overflow: TextOverflow.ellipsis, style: z.text.caption.copyWith(color: z.textSecondary)),
                  ],
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }
}

Size fitMedia(Attachment a, double maxWidth, double maxHeight) {
  final w = (a.width ?? 4).toDouble(), h = (a.height ?? 3).toDouble();
  final aspect = (w <= 0 || h <= 0) ? 4 / 3 : (w / h).clamp(0.4, 2.5);
  var width = maxWidth;
  var height = width / aspect;
  if (height > maxHeight) {
    height = maxHeight;
    width = height * aspect;
  }
  return Size(width, height);
}

class MediaGrid extends StatelessWidget {
  const MediaGrid({super.key, required this.session, required this.message, required this.maxWidth, required this.onOpen});

  final AccountSession session;
  final Message message;
  final double maxWidth;
  final void Function(int index) onOpen;

  @override
  Widget build(BuildContext context) {
    final items = message.attachments;
    final width = maxWidth.clamp(120.0, 280.0);
    if (items.length == 1) {
      final size = fitMedia(items.first, width, 360);
      return MediaThumb(session: session, attachment: items.first, width: size.width, height: size.height, radius: ZRadius.image, heroTag: mediaHeroTag(message, 0), onTap: () => onOpen(0));
    }
    final columns = items.length == 2 || items.length == 4 ? 2 : 3;
    const gap = 2.0;
    final cell = (width - gap * (columns - 1)) / columns;
    return ClipRRect(
      borderRadius: BorderRadius.circular(ZRadius.image),
      child: SizedBox(
        width: width,
        child: Wrap(
          spacing: gap,
          runSpacing: gap,
          children: [
            for (var i = 0; i < items.length; i++)
              MediaThumb(session: session, attachment: items[i], width: cell, height: cell, radius: 0, heroTag: mediaHeroTag(message, i), onTap: () => onOpen(i)),
          ],
        ),
      ),
    );
  }
}

/// Hero tag shared by a picture in a bubble and the same picture in the media
/// viewer; unique per message and position.
String mediaHeroTag(Message m, int index) => 'media-${m.id}-$index';

/// Shuttle for that Hero: the whole flight keeps a cover crop, clipped to the
/// flying rect. The default shuttle paints the destination's contain child, so
/// the picture re-crops the moment it leaves the bubble. The destination child
/// cannot be reused as is, its fit is what has to change, so this shows the
/// same url from the media cache instead of decoding the picture again.
HeroFlightShuttleBuilder mediaHeroShuttle(
    AccountSession session, Attachment attachment) {
  final url =
      attachment.url.isNotEmpty ? attachment.url : (attachment.thumbUrl ?? '');
  final thumb = attachment.thumbUrl;
  // The bubble's thumbnail stands in until the full picture is ready, so the
  // flight never flashes an empty rect.
  final fallback =
      thumb == null || thumb.isEmpty || thumb == url ? null : thumb;
  Widget cover(String src) =>
      MediaImage(session: session, url: src, fit: BoxFit.cover);
  return (flightContext, animation, direction, fromHeroContext,
          toHeroContext) =>
      ClipRect(
        key: const Key('mediaHeroShuttle'),
        child: MediaImage(
          session: session,
          url: url,
          fit: BoxFit.cover,
          placeholder: fallback == null ? null : cover(fallback),
          errorBuilder: fallback == null ? null : (_) => cover(fallback),
        ),
      );
}

class MediaThumb extends StatelessWidget {
  const MediaThumb(
      {super.key,
      required this.session,
      required this.attachment,
      required this.width,
      required this.height,
      required this.radius,
      required this.onTap,
      this.heroTag});

  final AccountSession session;
  final Attachment attachment;
  final double width;
  final double height;
  final double radius;
  final VoidCallback onTap;

  /// Pictures fly into the media viewer under this tag; videos do not.
  final String? heroTag;

  Widget _hero(BuildContext context, Widget child) {
    final tag = heroTag;
    if (tag == null || ZMotion.reduced(context)) return child;
    return Hero(
        tag: tag,
        flightShuttleBuilder: mediaHeroShuttle(session, attachment),
        child: child);
  }

  @override
  Widget build(BuildContext context) {
    final z = context.z;
    final video = attachment.kind == MessageKind.video;
    final url = attachment.thumbUrl ?? (video ? '' : attachment.url);
    return ClipRRect(
      borderRadius: BorderRadius.circular(radius),
      child: ZPressable(
        onTap: onTap,
        radius: 0,
        color: z.layerPressed,
        hoverColor: z.layerPressed,
        pressedColor: z.layerPressed,
        semanticLabel: context.tr(video ? 'openVideo' : 'openImage'),
        child: SizedBox(
          width: width,
          height: height,
          child: Stack(
            fit: StackFit.expand,
            children: [
              if (!video && attachment.thumbUrl != null && attachment.thumbUrl!.isNotEmpty && attachment.url.isNotEmpty)
                _hero(
                  context,
                  MediaImage(
                    session: session,
                    url: attachment.url,
                    width: width,
                    height: height,
                    placeholder: ImageFiltered(
                      imageFilter: ui.ImageFilter.blur(sigmaX: 8, sigmaY: 8),
                      child: MediaImage(session: session, url: attachment.thumbUrl!, width: width, height: height),
                    ),
                    errorBuilder: (_) => MediaImage(session: session, url: attachment.thumbUrl!, width: width, height: height),
                  ),
                )
              else if (url.isNotEmpty)
                video ? MediaImage(session: session, url: url, width: width, height: height) : _hero(context, MediaImage(session: session, url: url, width: width, height: height)),
              if (video) ...[
                const ColoredBox(color: ZalosTokens.mediaScrim),
                Center(
                  child: Container(
                    width: 48,
                    height: 48,
                    decoration: const BoxDecoration(color: ZalosTokens.mediaChip, shape: BoxShape.circle),
                    child: const Icon(ZIcons.play, color: ZalosTokens.white, size: 32, fill: 1),
                  ),
                ),
                if (attachment.durationMs != null)
                  Positioned(
                    left: ZSpace.s4,
                    top: ZSpace.s4,
                    child: Container(
                      padding: const EdgeInsets.symmetric(horizontal: ZSpace.s4, vertical: 1),
                      decoration: BoxDecoration(color: ZalosTokens.mediaChip, borderRadius: BorderRadius.circular(3)),
                      child: Text(formatDuration(attachment.durationMs), style: z.text.captionStrong.copyWith(color: ZalosTokens.white)),
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

class VoiceBubble extends ConsumerWidget {
  const VoiceBubble({super.key, required this.session, required this.message});

  final AccountSession session;
  final Message message;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final z = context.z;
    final a = message.attachments.isEmpty ? null : message.attachments.first;
    final deck = ref.watch(voiceDeckProvider);
    ref.watchNotifier(deck);
    final key = '${session.slot}/${message.id}';
    final current = deck.currentKey == key;
    final status = current ? deck.status : const PlaybackStatus();
    final loading = current && deck.loading;
    final failed = current && deck.failed;
    final totalMs = status.duration.inMilliseconds > 0 ? status.duration.inMilliseconds : (a?.durationMs ?? 0);
    final progress = totalMs <= 0 ? 0.0 : (status.position.inMilliseconds / totalMs).clamp(0.0, 1.0);
    final playing = current && status.playing && !status.completed;
    return Row(
      mainAxisSize: MainAxisSize.min,
      children: [
        ZPressable(
          key: Key('voicePlay-${message.id}'),
          circle: true,
          color: z.brand,
          hoverColor: z.brandHover,
          pressedColor: z.brandPressed,
          semanticLabel: context.tr(playing ? 'pause' : 'playVoice'),
          tooltip: context.tr(playing ? 'pause' : 'playVoice'),
          minSize: LayoutScope.wideOf(context) ? null : ZSizes.touchTarget,
          onTap: a == null ? null : () => deck.toggle(key, session, a),
          child: SizedBox(
            width: 36,
            height: 36,
            child: loading
                ? Padding(padding: const EdgeInsets.all(10), child: CircularProgressIndicator(strokeWidth: 2, color: z.textOnBrand))
                : Icon(playing ? ZIcons.pause : ZIcons.play, color: z.textOnBrand, fill: 1, size: 24),
          ),
        ),
        const SizedBox(width: ZSpace.s8),
        // Shrinks in narrow chat panes so the time never overflows the bubble.
        Flexible(
          child: SizedBox(
            width: 132,
            height: 32,
            child: SliderTheme(
              data: SliderThemeData(
                trackHeight: 4,
                activeTrackColor: z.brandText,
                inactiveTrackColor: z.textTertiary.withValues(alpha: 0.35),
                thumbColor: z.brandText,
                overlayShape: SliderComponentShape.noOverlay,
                thumbShape: const RoundSliderThumbShape(enabledThumbRadius: 6),
              ),
              child: Slider(
                key: Key('voiceSeek-${message.id}'),
                value: progress,
                semanticFormatterCallback: (v) => formatDuration((v * totalMs).round()),
                onChanged: current && totalMs > 0 ? (v) => deck.seek(key, Duration(milliseconds: (v * totalMs).round())) : null,
              ),
            ),
          ),
        ),
        const SizedBox(width: ZSpace.s8),
        Text(
          failed ? context.tr('playFailed') : (current && status.position > Duration.zero ? '${formatDuration(status.position.inMilliseconds)} / ${formatDuration(totalMs)}' : formatDuration(totalMs)),
          style: z.text.caption.copyWith(color: failed ? z.danger : z.textSecondary),
        ),
      ],
    );
  }
}

IconData fileGlyph(String extension) {
  switch (extension) {
    case 'pdf':
      return ZIcons.filePdf;
    case 'xls' || 'xlsx' || 'csv':
      return ZIcons.fileSheet;
    case 'ppt' || 'pptx':
      return ZIcons.fileSlides;
    case 'zip' || 'rar' || '7z' || 'gz' || 'tar':
      return ZIcons.fileZip;
    case 'mp3' || 'm4a' || 'wav' || 'aac':
      return ZIcons.fileAudio;
    case 'mp4' || 'mov' || 'mkv':
      return ZIcons.fileVideo;
    default:
      return ZIcons.fileDoc;
  }
}

class FileCard extends ConsumerWidget {
  const FileCard({super.key, required this.session, required this.attachment});

  final AccountSession session;
  final Attachment attachment;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final z = context.z;
    final downloads = ref.watch(downloadsProvider);
    ref.watchNotifier(downloads);
    final entry = downloads.of(attachment.url);
    final name = attachment.name ?? context.tr('previewFile');
    final ext = fileExtension(name);
    final wide = LayoutScope.wideOf(context);
    Future<void> download() async {
      final failed = context.tr('downloadFailed');
      final saved = context.tr('fileSaved');
      final ok = await downloads.fetch(session, attachment.url, name);
      if (!context.mounted) return;
      if (!ok && downloads.of(attachment.url).phase != DownloadPhase.failed) {
        return;
      }
      final message = ok
          ? (downloads.of(attachment.url).path == null ? null : saved)
          : failed;
      if (message != null) zToast(context, message);
    }

    final Widget action = switch (entry.phase) {
      DownloadPhase.loading => Stack(
          alignment: Alignment.center,
          children: [
            SizedBox(width: 28, height: 28, child: CircularProgressIndicator(strokeWidth: 2, color: z.brandText, semanticsLabel: context.tr('downloading'))),
            ZIconButton(key: Key('fileCancel-${attachment.url}'), icon: ZIcons.close, iconSize: 16, label: context.tr('cancelDownload'), onPressed: () => downloads.cancel(attachment.url)),
          ],
        ),
      DownloadPhase.done => ZButton(
          key: Key('fileOpen-${attachment.url}'),
          label: context.tr('open'),
          small: true,
          variant: ZButtonVariant.secondary,
          onPressed: () => downloads.open(attachment.url),
        ),
      _ => ZIconButton(
          key: Key('fileDownload-${attachment.url}'),
          icon: entry.phase == DownloadPhase.failed ? ZIcons.refresh : ZIcons.download,
          label: context.tr(entry.phase == DownloadPhase.failed ? 'retry' : 'download'),
          onPressed: download,
        ),
    };
    return ConstrainedBox(
      constraints: BoxConstraints(minWidth: wide ? 240 : 180),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          Container(
            width: 40,
            height: 40,
            decoration: BoxDecoration(color: z.fileColor(ext), borderRadius: BorderRadius.circular(ZRadius.input)),
            child: Icon(fileGlyph(ext), color: ZalosTokens.white, size: 22),
          ),
          const SizedBox(width: ZSpace.s8),
          Flexible(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              mainAxisSize: MainAxisSize.min,
              children: [
                Text(middleEllipsis(name, 44), maxLines: 2, overflow: TextOverflow.ellipsis, semanticsLabel: name, style: z.text.label),
                Text(
                  [if (ext.isNotEmpty) ext.toUpperCase(), if (attachment.size != null) formatBytes(attachment.size)].join(' \u00b7 '),
                  style: z.text.caption.copyWith(color: z.textSecondary),
                ),
              ],
            ),
          ),
          const SizedBox(width: ZSpace.s8),
          action,
        ],
      ),
    );
  }
}

class ContactCardBubble extends StatelessWidget {
  const ContactCardBubble(
      {super.key,
      required this.session,
      required this.card,
      required this.onOpen});

  final AccountSession session;
  final ContactCard card;
  final VoidCallback onOpen;

  @override
  Widget build(BuildContext context) {
    final z = context.z;
    final name = card.displayName.trim().isEmpty
        ? context.tr('unknownUser')
        : card.displayName;
    final phone = card.phone?.trim() ?? '';
    final label = phone.isEmpty
        ? context.tr('contactCardLabel', [name])
        : '${context.tr('contactCardLabel', [name])}, $phone';
    return Semantics(
      container: true,
      label: label,
      child: Container(
        constraints: const BoxConstraints(minWidth: 200, maxWidth: 280),
        padding: const EdgeInsets.all(ZSpace.s8),
        decoration: BoxDecoration(
          color: z.layerSubtle,
          borderRadius: BorderRadius.circular(ZRadius.input),
          border: Border.all(color: z.divider),
        ),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          mainAxisSize: MainAxisSize.min,
          children: [
            Row(
              children: [
                ZAvatar(
                    session: session,
                    id: card.uid,
                    name: name,
                    url: card.avatarUrl,
                    size: 44),
                const SizedBox(width: ZSpace.s8),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      Text(name,
                          maxLines: 2,
                          overflow: TextOverflow.ellipsis,
                          style: z.text.labelStrong),
                      if (phone.isNotEmpty)
                        Text(phone,
                            maxLines: 1,
                            overflow: TextOverflow.ellipsis,
                            style: z.text.caption
                                .copyWith(color: z.textSecondary)),
                    ],
                  ),
                ),
              ],
            ),
            const SizedBox(height: ZSpace.s8),
            ZButton(
              key: Key('contactCardOpen-${card.uid}'),
              label: context.tr('sendMessage'),
              icon: ZIcons.chat,
              variant: ZButtonVariant.secondary,
              small: true,
              expand: true,
              onPressed: onOpen,
            ),
          ],
        ),
      ),
    );
  }
}

class LinkCard extends StatelessWidget {
  const LinkCard(
      {super.key,
      required this.session,
      required this.attachment,
      required this.onTap});

  final AccountSession session;
  final Attachment attachment;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final z = context.z;
    final host = Uri.tryParse(attachment.url)?.host ?? '';
    final thumb = attachment.thumbUrl;
    final title = attachment.name ?? attachment.url;
    return ZPressable(
      onTap: onTap,
      radius: ZRadius.row,
      color: z.layerSubtle.withValues(alpha: z.dark ? 0.6 : 1),
      semanticLabel: context.tr('openLinkLabel', [title]),
      child: Padding(
        padding: const EdgeInsets.all(ZSpace.s8),
        child: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            ClipRRect(
              borderRadius: BorderRadius.circular(ZRadius.row),
              child: thumb != null && thumb.isNotEmpty
                  ? MediaImage(session: session, url: thumb, width: 64, height: 64)
                  : Container(width: 64, height: 64, color: z.layerPressed, child: Icon(ZIcons.link, color: z.textTertiary)),
            ),
            const SizedBox(width: ZSpace.s8),
            Flexible(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                mainAxisSize: MainAxisSize.min,
                children: [
                  Text(title, maxLines: 2, overflow: TextOverflow.ellipsis, style: z.text.labelStrong),
                  const SizedBox(height: 2),
                  Text(host.isEmpty ? attachment.url : host, maxLines: 1, overflow: TextOverflow.ellipsis, style: z.text.meta.copyWith(color: z.textTertiary)),
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }
}

/// Shared frame of the structured message cards: a 32 px glyph, a title with
/// an optional subtitle, an optional trailing control and a body.
class _StructuredCard extends StatelessWidget {
  const _StructuredCard({
    required this.label,
    required this.icon,
    required this.title,
    this.subtitle,
    this.trailing,
    this.leading,
    this.children = const [],
  });

  final String label;
  final IconData icon;
  final String title;
  final String? subtitle;
  final Widget? trailing;
  final Widget? leading;
  final List<Widget> children;

  @override
  Widget build(BuildContext context) {
    final z = context.z;
    return Semantics(
      container: true,
      label: label,
      child: Container(
        constraints: const BoxConstraints(minWidth: 200, maxWidth: 280),
        padding: const EdgeInsets.all(ZSpace.s8),
        decoration: BoxDecoration(
          color: z.layerSubtle,
          borderRadius: BorderRadius.circular(ZRadius.input),
          border: Border.all(color: z.divider),
        ),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          mainAxisSize: MainAxisSize.min,
          children: [
            Row(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                leading ??
                    Container(
                      width: 32,
                      height: 32,
                      decoration: BoxDecoration(
                          color: z.brandSubtle,
                          borderRadius: BorderRadius.circular(ZRadius.row)),
                      child: Icon(icon, size: 18, color: z.brandText),
                    ),
                const SizedBox(width: ZSpace.s8),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      Text(title,
                          maxLines: 2,
                          overflow: TextOverflow.ellipsis,
                          style: z.text.labelStrong),
                      if (subtitle != null && subtitle!.isNotEmpty)
                        Text(subtitle!,
                            maxLines: 2,
                            overflow: TextOverflow.ellipsis,
                            style: z.text.caption
                                .copyWith(color: z.textSecondary)),
                    ],
                  ),
                ),
                if (trailing != null) ...[
                  const SizedBox(width: ZSpace.s8),
                  trailing!
                ],
              ],
            ),
            if (children.isNotEmpty) ...[
              const SizedBox(height: ZSpace.s8),
              ...children
            ],
          ],
        ),
      ),
    );
  }
}

class BankCardBubble extends StatelessWidget {
  const BankCardBubble(
      {super.key,
      required this.session,
      required this.card,
      required this.messageId});

  final AccountSession session;
  final BankCard card;
  final String messageId;

  @override
  Widget build(BuildContext context) {
    final z = context.z;
    final bank = (card.bankName ?? '').trim();
    final holder = (card.holderName ?? '').trim();
    final logo = (card.bankLogo ?? '').trim();
    return _StructuredCard(
      label: context.tr('bankCardLabel',
          [bank.isEmpty ? context.tr('bankCard') : bank, card.accountNumber]),
      icon: ZIcons.bank,
      title: bank.isEmpty ? context.tr('bankCard') : bank,
      subtitle: holder,
      leading: logo.isEmpty
          ? null
          : ClipRRect(
              borderRadius: BorderRadius.circular(ZRadius.row),
              child: MediaImage(
                session: session,
                url: logo,
                width: 32,
                height: 32,
                errorBuilder: (_) => Icon(ZIcons.bank,
                    size: 18, color: z.brandText),
              ),
            ),
      trailing: ZIconButton(
        key: Key('bankCardCopy-$messageId'),
        icon: ZIcons.copy,
        label: context.tr('bankCardCopy'),
        size: 28,
        iconSize: 16,
        onPressed: () async {
          await Clipboard.setData(ClipboardData(text: card.accountNumber));
          if (context.mounted) zToast(context, context.tr('bankCardCopied'));
        },
      ),
      children: [
        Text(card.accountNumber,
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
            style: z.text.mono(15)),
      ],
    );
  }
}

String locationMapUrl(Location location) =>
    'https://www.google.com/maps/search/?api=1&query=${location.lat},${location.lng}';

class LocationBubble extends StatelessWidget {
  const LocationBubble(
      {super.key,
      required this.location,
      required this.messageId,
      required this.onOpen});

  final Location location;
  final String messageId;
  final VoidCallback onOpen;

  @override
  Widget build(BuildContext context) {
    final z = context.z;
    final name = (location.name ?? '').trim();
    final address = (location.address ?? '').trim();
    final coords =
        '${location.lat.toStringAsFixed(5)}, ${location.lng.toStringAsFixed(5)}';
    return _StructuredCard(
      label: context.tr('locationLabel',
          [name.isEmpty ? coords : name, address.isEmpty ? coords : address]),
      icon: ZIcons.location,
      title: name.isEmpty ? context.tr('locationTitle') : name,
      subtitle: address.isEmpty ? coords : address,
      children: [
        if (address.isNotEmpty)
          Text(coords, style: z.text.caption.copyWith(color: z.textTertiary)),
        const SizedBox(height: ZSpace.s8),
        ZButton(
          key: Key('locationOpen-$messageId'),
          label: context.tr('locationOpen'),
          icon: ZIcons.map,
          variant: ZButtonVariant.secondary,
          small: true,
          expand: true,
          onPressed: onOpen,
        ),
      ],
    );
  }
}

class PollBubble extends StatelessWidget {
  const PollBubble({super.key, required this.poll, this.onOpen});

  final Poll poll;
  final VoidCallback? onOpen;

  @override
  Widget build(BuildContext context) {
    final z = context.z;
    final total = poll.totalVotes ??
        poll.options.fold<int>(0, (sum, option) => sum + (option.votes ?? 0));
    final chips = <String>[
      if (poll.closed == true) context.tr('pollClosed'),
      if (poll.multiple == true) context.tr('pollMultiple'),
      if (poll.anonymous == true) context.tr('pollAnonymous'),
      if (total > 0) context.tr('pollVotes', [total]),
    ];
    return _StructuredCard(
      label: context.tr('pollLabel', [poll.question]),
      icon: ZIcons.poll,
      title: poll.question,
      children: [
        for (final option in poll.options)
          Padding(
            padding: const EdgeInsets.only(top: ZSpace.s4),
            child: Row(
              children: [
                Icon(
                  option.voted == true
                      ? ZIcons.checkCircle
                      : ZIcons.radioUnchecked,
                  size: 18,
                  color: option.voted == true ? z.brandText : z.textTertiary,
                ),
                const SizedBox(width: ZSpace.s8),
                Expanded(
                  child: Text(
                    option.text,
                    maxLines: 2,
                    overflow: TextOverflow.ellipsis,
                    style: option.voted == true
                        ? z.text.labelStrong
                        : z.text.labelRegular,
                  ),
                ),
                if (option.votes != null)
                  Text('${option.votes}',
                      style: z.text.caption.copyWith(color: z.textSecondary)),
              ],
            ),
          ),
        if (chips.isNotEmpty) ...[
          const SizedBox(height: ZSpace.s8),
          Wrap(
              spacing: ZSpace.s4,
              runSpacing: ZSpace.s4,
              children: [for (final chip in chips) ZChip(label: chip)]),
        ],
        if (onOpen != null && poll.id != null) ...[
          const SizedBox(height: ZSpace.s8),
          ZButton(
            label: context.tr('pollOpenVote'),
            icon: ZIcons.poll,
            variant: ZButtonVariant.secondary,
            small: true,
            expand: true,
            onPressed: onOpen,
          ),
        ],
      ],
    );
  }
}

class NoteBubble extends StatelessWidget {
  const NoteBubble({super.key, required this.note});

  final Note note;

  @override
  Widget build(BuildContext context) {
    final z = context.z;
    final text = (note.text ?? '').trim();
    return _StructuredCard(
      label: context.tr('noteLabel', [note.title]),
      icon: ZIcons.note,
      title: note.title,
      trailing: note.pinned == true
          ? ZChip(label: context.tr('notePinned'), tone: ZTone.info)
          : null,
      children: [
        if (text.isNotEmpty)
          Text(text,
              maxLines: 4, overflow: TextOverflow.ellipsis, style: z.text.body),
      ],
    );
  }
}

class ReminderBubble extends StatelessWidget {
  const ReminderBubble({super.key, required this.reminder});

  final Reminder reminder;

  @override
  Widget build(BuildContext context) {
    final z = context.z;
    final start = reminder.startTime;
    final emoji = (reminder.emoji ?? '').trim();
    return _StructuredCard(
      label: context.tr('reminderLabel', [reminder.title]),
      icon: ZIcons.alarm,
      title: reminder.title,
      subtitle:
          start != null && start > 0 ? formatDateTime(start, context.s) : null,
      children: [
        if (emoji.isNotEmpty) Text(emoji, style: z.text.label),
        if (reminder.repeat != null && reminder.repeat! > 0)
          Text(context.tr('reminderRepeat'),
              style: z.text.caption.copyWith(color: z.textSecondary)),
      ],
    );
  }
}

class CallBubble extends StatelessWidget {
  const CallBubble({super.key, required this.call});

  final CallLog call;

  @override
  Widget build(BuildContext context) {
    final video = call.callType == 'video';
    final title = switch (call.callType) {
      'video' => context.tr('callVideo'),
      'voice' => context.tr('callVoice'),
      _ => context.tr('callUnknown'),
    };
    final state = call.missed == true
        ? context.tr('callMissed')
        : (call.durationMs != null && call.durationMs! > 0
            ? formatDuration(call.durationMs)
            : context.tr('callAnswered'));
    return _StructuredCard(
      label: context.tr('callLabel', ['$title, $state']),
      icon: video ? ZIcons.video : ZIcons.callVoice,
      title: title,
      subtitle: state,
    );
  }
}

class DoodleBubble extends StatelessWidget {
  const DoodleBubble(
      {super.key,
      required this.session,
      required this.doodle,
      required this.onOpen});

  final AccountSession session;
  final Doodle doodle;
  final VoidCallback onOpen;

  @override
  Widget build(BuildContext context) {
    final z = context.z;
    final attachment = Attachment(
      kind: MessageKind.image,
      url: doodle.url,
      thumbUrl: doodle.thumbUrl,
      width: doodle.width,
      height: doodle.height,
    );
    final size = fitMedia(attachment, 240, 320);
    final thumb = doodle.thumbUrl;
    return Semantics(
      container: true,
      label: context.tr('doodleLabel'),
      child: ZPressable(
        onTap: doodle.url.isEmpty ? null : onOpen,
        radius: ZRadius.image,
        color: z.layerPressed,
        semanticLabel: context.tr('openImage'),
        child: ClipRRect(
          borderRadius: BorderRadius.circular(ZRadius.image),
          child: SizedBox(
            width: size.width,
            height: size.height,
            child: doodle.url.isEmpty
                ? Icon(ZIcons.doodle, color: z.textTertiary)
                : MediaImage(
                    session: session,
                    url: doodle.url,
                    width: size.width,
                    height: size.height,
                    semanticLabel: context.tr('doodleLabel'),
                    placeholder: thumb == null || thumb.isEmpty
                        ? null
                        : MediaImage(
                            session: session,
                            url: thumb,
                            width: size.width,
                            height: size.height),
                    errorBuilder: (_) => Icon(ZIcons.brokenImage,
                        color: z.textTertiary),
                  ),
          ),
        ),
      ),
    );
  }
}

class AlbumBubble extends StatelessWidget {
  const AlbumBubble(
      {super.key,
      required this.session,
      required this.album,
      required this.messageId,
      required this.onOpen});

  final AccountSession session;
  final Album album;
  final String messageId;
  final ValueChanged<int> onOpen;

  @override
  Widget build(BuildContext context) {
    final z = context.z;
    final items = album.items;
    final caption = (album.caption ?? '').trim();
    if (items.isEmpty) {
      return Text(context.tr('albumTitle'),
          style: z.text.body.copyWith(color: z.textTertiary));
    }
    const width = 240.0;
    if (items.length == 1) {
      final size = fitMedia(items.first, width, 320);
      return Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        mainAxisSize: MainAxisSize.min,
        children: [
          MediaThumb(
            key: Key('albumItem-$messageId-0'),
            session: session,
            attachment: items.first,
            width: size.width,
            height: size.height,
            radius: ZRadius.image,
            onTap: () => onOpen(0),
          ),
          if (caption.isNotEmpty)
            Padding(
                padding: const EdgeInsets.only(top: ZSpace.s4),
                child: Text(caption, style: z.text.body)),
        ],
      );
    }
    final columns = items.length == 2 || items.length == 4 ? 2 : 3;
    const gap = 2.0;
    final cell = (width - gap * (columns - 1)) / columns;
    final shown = items.take(columns * 2).toList();
    return Semantics(
      container: true,
      label: context.tr('albumLabel', [items.length]),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        mainAxisSize: MainAxisSize.min,
        children: [
          ClipRRect(
            borderRadius: BorderRadius.circular(ZRadius.image),
            child: SizedBox(
              width: width,
              child: Wrap(
                spacing: gap,
                runSpacing: gap,
                children: [
                  for (var i = 0; i < shown.length; i++)
                    Stack(
                      children: [
                        MediaThumb(
                          key: Key('albumItem-$messageId-$i'),
                          session: session,
                          attachment: shown[i],
                          width: cell,
                          height: cell,
                          radius: 0,
                          onTap: () => onOpen(i),
                        ),
                        if (i == shown.length - 1 &&
                            items.length > shown.length)
                          Positioned.fill(
                            child: IgnorePointer(
                              child: ColoredBox(
                                color: ZalosTokens.mediaScrim,
                                child: Center(
                                  child: Text(
                                    context.tr('albumMore',
                                        [items.length - shown.length]),
                                    style: z.text.labelStrong
                                        .copyWith(color: ZalosTokens.white),
                                  ),
                                ),
                              ),
                            ),
                          ),
                      ],
                    ),
                ],
              ),
            ),
          ),
          if (caption.isNotEmpty)
            Padding(
                padding: const EdgeInsets.only(top: ZSpace.s4),
                child: Text(caption, style: z.text.body)),
        ],
      ),
    );
  }
}

class TodoBubble extends StatelessWidget {
  const TodoBubble({super.key, required this.todo});

  final Todo todo;

  @override
  Widget build(BuildContext context) {
    final z = context.z;
    final items = todo.items;
    return _StructuredCard(
      label: context.tr('todoLabel', [todo.title]),
      icon: ZIcons.checklist,
      title: todo.title,
      trailing: todo.done == true
          ? ZChip(label: context.tr('todoDone'), tone: ZTone.success)
          : null,
      children: [
        for (final item in items.take(6))
          Padding(
            padding: const EdgeInsets.only(top: 2),
            child: Row(
              children: [
                Icon(
                  item.done == true
                      ? ZIcons.checkCircle
                      : ZIcons.radioUnchecked,
                  size: 16,
                  color: item.done == true ? z.success : z.textTertiary,
                ),
                const SizedBox(width: ZSpace.s8),
                Expanded(
                  child: Text(
                    item.text,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: z.text.labelRegular.copyWith(
                      decoration:
                          item.done == true ? TextDecoration.lineThrough : null,
                      color: item.done == true ? z.textTertiary : null,
                    ),
                  ),
                ),
              ],
            ),
          ),
        if (items.length > 6)
          Padding(
            padding: const EdgeInsets.only(top: 2),
            child: Text(context.tr('todoMore', [items.length - 6]),
                style: z.text.caption),
          ),
      ],
    );
  }
}

class LinkPreviewBubble extends StatelessWidget {
  const LinkPreviewBubble(
      {super.key,
      required this.session,
      required this.preview,
      required this.onOpen});

  final AccountSession session;
  final LinkPreview preview;
  final VoidCallback onOpen;

  @override
  Widget build(BuildContext context) {
    final z = context.z;
    final href = preview.href.isNotEmpty ? preview.href : preview.srcUrl;
    final host = Uri.tryParse(href)?.host ?? '';
    final thumb = preview.thumbUrl;
    final title = preview.title.trim().isEmpty ? href : preview.title;
    return Semantics(
      container: true,
      label: context.tr('linkPreviewLabel', [title]),
      child: ZPressable(
        onTap: onOpen,
        radius: ZRadius.row,
        color: z.layerSubtle.withValues(alpha: z.dark ? 0.6 : 1),
        semanticLabel: context.tr('openLinkLabel', [title]),
        child: Container(
          constraints: const BoxConstraints(minWidth: 200, maxWidth: 280),
          padding: const EdgeInsets.all(ZSpace.s8),
          child: Row(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              ClipRRect(
                borderRadius: BorderRadius.circular(ZRadius.row),
                child: thumb != null && thumb.isNotEmpty
                    ? MediaImage(
                        session: session, url: thumb, width: 64, height: 64)
                    : Container(
                        width: 64,
                        height: 64,
                        color: z.layerPressed,
                        child:
                            Icon(ZIcons.link, color: z.textTertiary)),
              ),
              const SizedBox(width: ZSpace.s8),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    Text(title,
                        maxLines: 2,
                        overflow: TextOverflow.ellipsis,
                        style: z.text.labelStrong),
                    if (preview.description.isNotEmpty) ...[
                      const SizedBox(height: 2),
                      Text(preview.description,
                          maxLines: 2,
                          overflow: TextOverflow.ellipsis,
                          style:
                              z.text.caption.copyWith(color: z.textSecondary)),
                    ],
                    if (preview.mediaTitle != null &&
                        preview.mediaTitle!.isNotEmpty) ...[
                      const SizedBox(height: 2),
                      Text(preview.mediaTitle!,
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                          style:
                              z.text.caption.copyWith(color: z.textSecondary)),
                    ],
                    if (host.isNotEmpty) ...[
                      const SizedBox(height: 2),
                      Text(host,
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                          style: z.text.meta.copyWith(color: z.textTertiary)),
                    ],
                  ],
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}
