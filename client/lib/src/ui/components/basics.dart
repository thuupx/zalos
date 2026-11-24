import 'package:flutter/services.dart';
import 'package:material_ui/material_ui.dart';

import '../theme/tokens.dart';
import '../theme/z_icons.dart';
import '../util/format.dart';
import '../util/haptics.dart';
import 'motion.dart';
import 'pressable.dart';

enum ZBadgeVariant { normal, muted, mention }

class ZBadge extends StatelessWidget {
  const ZBadge({super.key, required this.count, this.variant = ZBadgeVariant.normal, this.outline, this.dot = false, this.label});

  final int count;
  final ZBadgeVariant variant;
  final Color? outline;
  final bool dot;
  final String? label;

  @override
  Widget build(BuildContext context) {
    final z = context.z;
    if (!dot && count <= 0 && label == null) return const SizedBox.shrink();
    final (Color bg, Color fg) = switch (variant) {
      ZBadgeVariant.normal => (z.badge, z.onAccent),
      ZBadgeVariant.muted => (z.badgeMuted, z.textSecondary),
      ZBadgeVariant.mention => (z.badgeMention, z.onBadgeMention),
    };
    final border = outline == null ? null : Border.all(color: outline!, width: 1.5, strokeAlign: BorderSide.strokeAlignOutside);
    if (dot) {
      return Container(width: 8, height: 8, decoration: BoxDecoration(color: bg, shape: BoxShape.circle, border: border));
    }
    final text = label ?? (count > 99 ? '99+' : '$count');
    return ZBump(
      trigger: text,
      child: Container(
        constraints: const BoxConstraints(minWidth: 18, minHeight: 18),
        padding: const EdgeInsets.symmetric(horizontal: 5),
        decoration: BoxDecoration(color: bg, borderRadius: BorderRadius.circular(9), border: border),
        alignment: Alignment.center,
        child: Text(text, textScaler: TextScaler.noScaling, style: z.text.badge.copyWith(color: fg)),
      ),
    );
  }
}

enum ZTone { info, warning, danger, success, neutral }

(Color bg, Color fg) toneColors(ZalosTokens z, ZTone tone) => switch (tone) {
      ZTone.info => (z.brandSubtle, z.brandText),
      ZTone.warning => (z.warningBg, z.warning),
      ZTone.danger => (z.dangerBg, z.danger),
      ZTone.success => (z.successBg, z.success),
      ZTone.neutral => (z.layerPressed, z.textSecondary),
    };

/// Full width strip under an app bar.
class ZBanner extends StatelessWidget {
  const ZBanner({super.key, required this.text, this.tone = ZTone.info, this.icon, this.actionLabel, this.onAction});

  final String text;
  final ZTone tone;
  final IconData? icon;
  final String? actionLabel;
  final VoidCallback? onAction;

  @override
  Widget build(BuildContext context) {
    final z = context.z;
    final (bg, fg) = toneColors(z, tone);
    final textColor = tone == ZTone.neutral ? z.textSecondary : (z.dark ? fg : z.textPrimary);
    return Semantics(
      liveRegion: true,
      container: true,
      child: Container(
        width: double.infinity,
        constraints: const BoxConstraints(minHeight: 32),
        color: bg,
        padding: const EdgeInsets.symmetric(horizontal: ZSpace.s12, vertical: ZSpace.s4),
        child: Row(
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            if (icon != null) ...[Icon(icon, size: 16, color: fg), const SizedBox(width: ZSpace.s8)],
            Flexible(child: Text(text, maxLines: 2, overflow: TextOverflow.ellipsis, style: z.text.caption.copyWith(color: textColor))),
            if (actionLabel != null) ...[
              const SizedBox(width: ZSpace.s8),
              ZPressable(
                onTap: onAction,
                radius: ZRadius.tight,
                semanticLabel: actionLabel,
                minSize: LayoutScope.wideOf(context) ? null : ZSizes.touchTarget,
                child: Padding(
                  padding: const EdgeInsets.symmetric(horizontal: ZSpace.s8, vertical: ZSpace.s4),
                  child: Text(actionLabel!, style: z.text.captionStrong.copyWith(color: textColor, decoration: TextDecoration.underline, decorationColor: textColor)),
                ),
              ),
            ],
          ],
        ),
      ),
    );
  }
}

class ZEmptyState extends StatelessWidget {
  const ZEmptyState({super.key, required this.icon, required this.title, this.subtitle, this.action});

  final IconData icon;
  final String title;
  final String? subtitle;
  final Widget? action;

  @override
  Widget build(BuildContext context) {
    final z = context.z;
    return Center(
      child: SingleChildScrollView(
        padding: const EdgeInsets.all(ZSpace.s24),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(icon, size: 48, color: z.textTertiary),
            const SizedBox(height: ZSpace.s12),
            Text(title, textAlign: TextAlign.center, style: z.text.rowTitle),
            if (subtitle != null) ...[
              const SizedBox(height: ZSpace.s4),
              ConstrainedBox(
                constraints: const BoxConstraints(maxWidth: 360),
                child: Text(subtitle!, textAlign: TextAlign.center, style: z.text.rowSub),
              ),
            ],
            if (action != null) ...[const SizedBox(height: ZSpace.s16), action!],
          ],
        ),
      ),
    );
  }
}

/// Error state of a pane: icon, message and a retry button.
class ZErrorState extends StatelessWidget {
  const ZErrorState({super.key, required this.title, this.detail, required this.retryLabel, required this.onRetry});

  final String title;
  final String? detail;
  final String retryLabel;
  final VoidCallback onRetry;

  @override
  Widget build(BuildContext context) => ZEmptyState(
        icon: ZIcons.error,
        title: title,
        subtitle: detail,
        action: ZButton(label: retryLabel, onPressed: onRetry, variant: ZButtonVariant.secondary),
      );
}

/// Shimmering block shaped like the content it replaces.
class ZSkeleton extends StatefulWidget {
  const ZSkeleton({super.key, this.width, this.height = 16, this.radius = ZRadius.tight, this.circle = false});

  final double? width;
  final double height;
  final double radius;
  final bool circle;

  @override
  State<ZSkeleton> createState() => _ZSkeletonState();
}

class _ZSkeletonState extends State<ZSkeleton> with SingleTickerProviderStateMixin {
  AnimationController? _controller;

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    final still = ZMotion.reduced(context);
    if (still) {
      _controller?.dispose();
      _controller = null;
    } else {
      // One shimmer cycle (in and out) phased on the wall clock, so every
      // skeleton on screen pulses together wherever it was created.
      final cycle = ZDurations.shimmer * 2;
      _controller ??= AnimationController(vsync: this, duration: cycle, value: (ZClock.nowMs() % cycle.inMilliseconds) / cycle.inMilliseconds)..repeat();
    }
  }

  @override
  void dispose() {
    _controller?.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final z = context.z;
    Widget box(Color color) => Container(
          width: widget.width,
          height: widget.height,
          decoration: BoxDecoration(
            color: color,
            shape: widget.circle ? BoxShape.circle : BoxShape.rectangle,
            borderRadius: widget.circle ? null : BorderRadius.circular(widget.radius),
          ),
        );
    final controller = _controller;
    if (controller == null) return ExcludeSemantics(child: box(z.skeleton));
    return ExcludeSemantics(
      child: AnimatedBuilder(
        animation: controller,
        builder: (context, _) => box(Color.lerp(z.skeleton, z.skeletonShine, Curves.easeInOut.transform(1 - (controller.value * 2 - 1).abs()))!),
      ),
    );
  }
}

class ZSkeletonRow extends StatelessWidget {
  const ZSkeletonRow({super.key, this.avatar = 48, this.height = 72});

  final double avatar;
  final double height;

  @override
  Widget build(BuildContext context) {
    return SizedBox(
      height: height,
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: ZSpace.s16),
        child: Row(
          children: [
            ZSkeleton(width: avatar, height: avatar, circle: true),
            const SizedBox(width: ZSpace.s12),
            const Expanded(
              child: Column(
                mainAxisAlignment: MainAxisAlignment.center,
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  FractionallySizedBox(widthFactor: 0.6, child: ZSkeleton(height: 16)),
                  SizedBox(height: ZSpace.s8),
                  FractionallySizedBox(widthFactor: 0.4, child: ZSkeleton(height: 14)),
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }
}

class ZSkeletonList extends StatelessWidget {
  const ZSkeletonList({super.key, this.count = 8, this.avatar = 48, this.rowHeight = 72, this.label});

  final int count;
  final double avatar;
  final double rowHeight;
  final String? label;

  @override
  Widget build(BuildContext context) {
    return Semantics(
      label: label,
      child: ListView.builder(
        physics: const NeverScrollableScrollPhysics(),
        padding: EdgeInsets.zero,
        itemCount: count,
        itemBuilder: (_, __) => ZSkeletonRow(avatar: avatar, height: rowHeight),
      ),
    );
  }
}

/// Small rounded label: status chips, role chips, filter chips.
class ZChip extends StatelessWidget {
  const ZChip({super.key, required this.label, this.tone = ZTone.neutral, this.selected, this.onTap, this.icon});

  final String label;
  final ZTone tone;
  final bool? selected;
  final VoidCallback? onTap;
  final IconData? icon;

  @override
  Widget build(BuildContext context) {
    final z = context.z;
    final filter = onTap != null;
    var (bg, fg) = toneColors(z, tone);
    if (filter) {
      bg = selected == true ? z.brandSubtle : z.layerSubtle;
      fg = selected == true ? z.brandText : z.textSecondary;
    }
    // danger on dangerBg (4.1:1) and warning on warningBg (4.48:1) miss AA
    // for small text in the light theme, so the label uses textPrimary next
    // to a tone colored glyph.
    final weakDanger = !filter && (tone == ZTone.danger || tone == ZTone.warning) && !z.dark;
    final glyph = icon ?? (weakDanger ? (tone == ZTone.danger ? ZIcons.error : ZIcons.warning) : null);
    final textColor = weakDanger ? z.textPrimary : fg;
    final body = Container(
      padding: EdgeInsets.symmetric(horizontal: filter ? 14 : ZSpace.s8, vertical: filter ? 6 : 2),
      decoration: filter
          ? null
          : BoxDecoration(color: bg, borderRadius: BorderRadius.circular(ZRadius.pill)),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          if (glyph != null) ...[Icon(glyph, size: 14, color: fg, fill: weakDanger ? 1 : 0), const SizedBox(width: ZSpace.s4)],
          Flexible(
            child: Text(label, maxLines: 1, overflow: TextOverflow.ellipsis, style: (filter ? z.text.label : z.text.captionStrong).copyWith(color: textColor)),
          ),
        ],
      ),
    );
    if (!filter) return body;
    return ZPressable(
      onTap: () {
        ZHaptics.selection();
        onTap!();
      },
      radius: ZRadius.pill,
      pressScale: 0.96,
      color: bg,
      selected: selected,
      border: Border.all(color: selected == true ? z.brandText.withValues(alpha: 0.35) : z.divider.withValues(alpha: z.dark ? 0.25 : 0.12)),
      minSize: LayoutScope.wideOf(context) ? null : ZSizes.touchTarget,
      child: body,
    );
  }
}

class ZSegmented<T> extends StatelessWidget {
  const ZSegmented({super.key, required this.segments, required this.selected, required this.onChanged});

  final List<(T value, String label)> segments;
  final T selected;
  final ValueChanged<T> onChanged;

  @override
  Widget build(BuildContext context) {
    final z = context.z;
    final wide = LayoutScope.wideOf(context);
    final reduced = ZMotion.reduced(context);
    final count = segments.length;
    final activeIndex = segments.indexWhere((s) => s.$1 == selected).clamp(0, count > 0 ? count - 1 : 0);
    final alignmentX = count <= 1 ? 0.0 : -1.0 + (2.0 * activeIndex / (count - 1));
    final height = wide ? 32.0 : ZSizes.touchTarget;
    return Container(
      padding: const EdgeInsets.all(3),
      decoration: BoxDecoration(color: z.layerSubtle, borderRadius: BorderRadius.circular(ZRadius.input)),
      child: Stack(
        children: [
          if (count > 0)
            Positioned.fill(
              child: IgnorePointer(
                child: AnimatedAlign(
                  alignment: Alignment(alignmentX, 0),
                  duration: reduced ? Duration.zero : ZMotion.enter,
                  curve: ZMotion.springCurve,
                  child: FractionallySizedBox(
                    widthFactor: 1 / count,
                    heightFactor: 1,
                    child: DecoratedBox(
                      decoration: BoxDecoration(
                        color: z.layer,
                        borderRadius: BorderRadius.circular(ZRadius.row),
                        boxShadow: z.shadowBubble,
                      ),
                    ),
                  ),
                ),
              ),
            ),
          Row(
            children: [
              for (final (value, label) in segments)
                Expanded(
                  child: ZPressable(
                    onTap: () {
                      if (value != selected) {
                        ZHaptics.selection();
                        onChanged(value);
                      }
                    },
                    radius: ZRadius.row,
                    pressHighlight: false,
                    pressScale: 0.97,
                    hoverColor: value == selected ? ZalosTokens.clear : z.layerHover,
                    selected: value == selected,
                    child: Container(
                      constraints: BoxConstraints(minHeight: height),
                      alignment: Alignment.center,
                      padding: const EdgeInsets.symmetric(horizontal: ZSpace.s8),
                      child: Text(
                        label,
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: (value == selected ? z.text.labelStrong : z.text.label).copyWith(
                          color: value == selected ? z.brandText : z.textSecondary,
                        ),
                      ),
                    ),
                  ),
                ),
            ],
          ),
        ],
      ),
    );
  }
}

/// Monospace groups for fingerprints and recovery codes.
class ZCodeGroups extends StatelessWidget {
  const ZCodeGroups({super.key, required this.value, this.size = 15, this.alignment = WrapAlignment.center});

  final String value;
  final double size;
  final WrapAlignment alignment;

  @override
  Widget build(BuildContext context) {
    final z = context.z;
    return Semantics(
      label: value,
      child: ExcludeSemantics(
        child: Wrap(
          alignment: alignment,
          spacing: size * 0.45,
          runSpacing: size * 0.35,
          children: [
            for (final g in codeGroups(value))
              Container(
                padding: EdgeInsets.symmetric(horizontal: size * 0.4, vertical: size * 0.15),
                decoration: BoxDecoration(color: z.layerSubtle, borderRadius: BorderRadius.circular(ZRadius.row), border: Border.all(color: z.border)),
                child: Text(g, style: z.text.mono(size)),
              ),
          ],
        ),
      ),
    );
  }
}

/// Card on a layerSubtle page: Me sections, devices, approval cards.
class ZCard extends StatelessWidget {
  const ZCard({super.key, required this.children, this.title, this.padding = EdgeInsets.zero, this.color, this.borderColor});

  final List<Widget> children;
  final String? title;
  final EdgeInsets padding;
  final Color? color;
  final Color? borderColor;

  @override
  Widget build(BuildContext context) {
    final z = context.z;
    final separateRows = padding == EdgeInsets.zero && children.length > 1;
    final spaced = separateRows
        ? <Widget>[
            for (var i = 0; i < children.length; i++) ...[
              if (i > 0)
                Container(
                  height: 0.5,
                  margin: const EdgeInsets.only(left: ZSpace.s16),
                  color: z.divider.withValues(alpha: z.dark ? 0.16 : 0.08),
                ),
              children[i],
            ],
          ]
        : children;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        if (title != null)
          Padding(
            padding: const EdgeInsets.fromLTRB(ZSpace.s16, ZSpace.s16, ZSpace.s16, ZSpace.s8),
            child: Semantics(header: true, child: Text(title!.toUpperCase(), style: z.text.overline)),
          ),
        Container(
          margin: const EdgeInsets.symmetric(horizontal: ZSpace.s12),
          padding: padding,
          clipBehavior: Clip.antiAlias,
          decoration: BoxDecoration(
            color: color ?? z.layer,
            borderRadius: BorderRadius.circular(ZRadius.card),
            border: Border.all(color: borderColor ?? z.divider.withValues(alpha: z.dark ? 0.2 : 0.1), width: 0.75),
          ),
          child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: spaced),
        ),
      ],
    );
  }
}

/// A list row with leading icon or widget, title, subtitle and trailing.
class ZRow extends StatelessWidget {
  const ZRow({
    super.key,
    required this.title,
    this.subtitle,
    this.leading,
    this.icon,
    this.trailing,
    this.onTap,
    this.danger = false,
    this.accent = false,
    this.minHeight = 48,
    this.subtitleWidget,
    this.selected = false,
    this.semanticLabel,
  });

  final String title;
  final String? subtitle;
  final Widget? leading;
  final IconData? icon;
  final Widget? trailing;
  final VoidCallback? onTap;
  final bool danger;
  final bool accent;
  final double minHeight;
  final Widget? subtitleWidget;
  final bool selected;
  final String? semanticLabel;

  @override
  Widget build(BuildContext context) {
    final z = context.z;
    final fg = danger ? z.danger : (accent ? z.brandText : z.textPrimary);
    final body = Container(
      constraints: BoxConstraints(minHeight: minHeight),
      padding: const EdgeInsets.symmetric(horizontal: ZSpace.s16, vertical: ZSpace.s8),
      child: Row(
        children: [
          if (leading != null) ...[leading!, const SizedBox(width: ZSpace.s12)],
          if (icon != null) ...[Icon(icon, size: 24, color: danger || accent ? fg : z.textSecondary), const SizedBox(width: ZSpace.s12)],
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              mainAxisSize: MainAxisSize.min,
              children: [
                Text(title, maxLines: 2, overflow: TextOverflow.ellipsis, style: (accent || danger ? z.text.label : z.text.body).copyWith(color: fg)),
                if (subtitle != null) Text(subtitle!, maxLines: 3, overflow: TextOverflow.ellipsis, style: z.text.meta.copyWith(color: z.textTertiary)),
                if (subtitleWidget != null) Padding(padding: const EdgeInsets.only(top: ZSpace.s4), child: subtitleWidget!),
              ],
            ),
          ),
          if (trailing != null) ...[const SizedBox(width: ZSpace.s8), trailing!],
        ],
      ),
    );
    if (onTap == null) return body;
    return ZPressable(onTap: onTap, radius: 0, color: selected ? z.layerSelected : null, semanticLabel: semanticLabel, child: body);
  }
}

class ZSwitchRow extends StatelessWidget {
  const ZSwitchRow({super.key, required this.title, this.subtitle, required this.value, required this.onChanged, this.icon});

  final String title;
  final String? subtitle;
  final bool value;
  final ValueChanged<bool>? onChanged;
  final IconData? icon;

  @override
  Widget build(BuildContext context) {
    return MergeSemantics(
      child: ZRow(
        title: title,
        subtitle: subtitle,
        icon: icon,
        onTap: onChanged == null
            ? null
            : () {
                ZHaptics.selection();
                onChanged!(!value);
              },
        trailing: ExcludeFocus(child: ExcludeSemantics(child: IgnorePointer(child: Switch(value: value, onChanged: onChanged == null ? null : (_) {})))),
      ),
    );
  }
}

class ZCheckRow extends StatelessWidget {
  const ZCheckRow({super.key, required this.label, required this.value, required this.onChanged, this.dense = false});

  final String label;
  final bool value;
  final ValueChanged<bool>? onChanged;
  final bool dense;

  @override
  Widget build(BuildContext context) {
    final z = context.z;
    return ZPressable(
      onTap: onChanged == null
          ? null
          : () {
              ZHaptics.selection();
              onChanged!(!value);
            },
      radius: ZRadius.row,
      toggled: value,
      semanticLabel: label,
      child: Container(
        constraints: BoxConstraints(minHeight: LayoutScope.wideOf(context) ? 36 : ZSizes.touchTarget),
        padding: EdgeInsets.symmetric(horizontal: dense ? ZSpace.s4 : ZSpace.s8, vertical: ZSpace.s4),
        child: Row(
          children: [
            Icon(
              value ? ZIcons.checkBox : ZIcons.checkBoxBlank,
              size: 22,
              fill: value ? 1 : 0,
              color: onChanged == null ? z.textDisabled : (value ? z.brandText : z.textTertiary),
            ),
            const SizedBox(width: ZSpace.s8),
            Expanded(child: Text(label, style: z.text.labelRegular.copyWith(color: onChanged == null ? z.textDisabled : z.textPrimary))),
          ],
        ),
      ),
    );
  }
}

/// The gradient app bar of the compact layout.
class ZPhoneHeader extends StatelessWidget {
  const ZPhoneHeader({super.key, required this.child});

  final Widget child;

  @override
  Widget build(BuildContext context) {
    final z = context.z;
    return AnnotatedRegion<SystemUiOverlayStyle>(
      value: SystemUiOverlayStyle.light,
      child: Container(
        decoration: BoxDecoration(gradient: z.headerGradient),
        child: SafeArea(
          bottom: false,
          child: IconTheme(
            data: IconThemeData(color: z.textOnBrand, size: 24),
            child: DefaultTextStyle.merge(
              style: z.text.title.copyWith(color: z.textOnBrand),
              child: ConstrainedBox(constraints: const BoxConstraints(minHeight: ZSizes.phoneHeader), child: child),
            ),
          ),
        ),
      ),
    );
  }
}

/// Text with the first match of a query highlighted, ignoring diacritics.
class ZHighlightText extends StatelessWidget {
  const ZHighlightText({super.key, required this.text, required this.query, required this.style, this.maxLines = 1});

  final String text;
  final String query;
  final TextStyle style;
  final int maxLines;

  @override
  Widget build(BuildContext context) {
    final z = context.z;
    final match = foldMatch(text, query);
    if (match == null || match.end <= match.start) {
      return Text(text, maxLines: maxLines, overflow: TextOverflow.ellipsis, style: style);
    }
    return Text.rich(
      TextSpan(children: [
        TextSpan(text: text.substring(0, match.start)),
        TextSpan(text: text.substring(match.start, match.end), style: TextStyle(color: z.brandText, fontWeight: FontWeight.w700, backgroundColor: z.brandSubtle)),
        TextSpan(text: text.substring(match.end)),
      ]),
      maxLines: maxLines,
      overflow: TextOverflow.ellipsis,
      style: style,
    );
  }
}
