import 'package:material_ui/material_ui.dart';

abstract final class ZSpace {
  static const double s2 = 2,
      s4 = 4,
      s8 = 8,
      s12 = 12,
      s16 = 16,
      s20 = 20,
      s24 = 24,
      s32 = 32;
}

abstract final class ZRadius {
  static const double tight = 4,
      row = 6,
      input = 8,
      button = 10,
      card = 12,
      sheet = 16,
      bubbleCompact = 14,
      bubbleWide = 6,
      navCapsule = 26,
      pill = 999;
  static const double image = 8, menu = 12, menuItem = 8, railPlate = 8;
}

abstract final class ZDurations {
  static const Duration fast = Duration(milliseconds: 150);
  static const Duration medium = Duration(milliseconds: 220);
  static const Duration toast = Duration(seconds: 3);
  static const Duration shimmer = Duration(milliseconds: 1500);
}

/// Motion tokens (UI.md 1.3). Entering motion eases out, exiting motion eases
/// in and is a little faster; only loading indicators loop. With the OS
/// "reduce motion" setting slides, scales and staggers are dropped and short
/// fades remain.
abstract final class ZMotion {
  /// Hover, press, badge and tab changes.
  static const Duration fast = ZDurations.fast;

  /// Press release fade-out, crisp and without a dark flash.
  static const Duration press = Duration(milliseconds: 110);

  /// Content entering: new messages, the reaction picker, popovers.
  static const Duration enter = Duration(milliseconds: 200);

  /// Sheets, dialogs and panes.
  static const Duration medium = ZDurations.medium;

  /// Anything leaving the screen.
  static const Duration exit = Duration(milliseconds: 150);

  /// One scale bump: 1 to [bumpScale] and back.
  static const Duration bump = Duration(milliseconds: 180);
  static const double bumpScale = 1.16;

  /// Delay between consecutive items of a staggered entrance.
  static const Duration stagger = Duration(milliseconds: 20);

  /// Distance a new message rises while it fades in.
  static const double rise = 10;

  static const Curve enterCurve = Curves.easeOutCubic;
  static const Curve springCurve = Cubic(0.22, 1.0, 0.36, 1.0);
  static const Curve exitCurve = Curves.easeInCubic;
  static const Curve standard = Curves.easeOut;

  static bool reduced(BuildContext context) =>
      (MediaQuery.maybeDisableAnimationsOf(context) ?? false) ||
      (View.maybeOf(context)
              ?.platformDispatcher
              .accessibilityFeatures
              .reduceMotion ??
          false);

  /// [duration], or zero when motion is reduced.
  static Duration of(BuildContext context, Duration duration) =>
      reduced(context) ? Duration.zero : duration;
}

abstract final class ZSizes {
  static const double rail = 64,
      listMedium = 320,
      listExpanded = 344,
      infoDocked = 344,
      infoOverlay = 360;
  static const double compactBreakpoint = 720, expandedBreakpoint = 1100;
  static const double bottomNav = 52,
      phoneHeader = 56,
      wideChatHeader = 68,
      wideSearchRow = 64;
  static const double chatMaxContent = 760, bubbleMax = 520, dialogMax = 420;
  static const double touchTarget = 44, pointerTarget = 32;
}

enum LayoutClass { compact, medium, expanded }

LayoutClass layoutClassFor(double width) => width < ZSizes.compactBreakpoint
    ? LayoutClass.compact
    : width < ZSizes.expandedBreakpoint
        ? LayoutClass.medium
        : LayoutClass.expanded;

/// Text styles of UI.md 1.2 plus the 13 px roles of the Zalo PC reference.
@immutable
class ZType {
  const ZType._(this._color, this._secondary, this._tertiary);

  final Color _color;
  final Color _secondary;
  final Color _tertiary;

  static const double _lh = 1.35;
  static const List<String> _monoFallback = [
    'Menlo',
    'Consolas',
    'Roboto Mono',
    'Courier New',
    'Courier'
  ];

  /// Bundled app font with full Vietnamese and combining-mark coverage.
  static const String fontFamily = 'GoogleSansFlex';

  /// Scripts the bundled font does not cover fall back to platform fonts;
  /// the color emoji fonts keep emoji in color.
  static const List<String> fontFallback = [
    'system-ui',
    '-apple-system',
    'Segoe UI',
    'Roboto',
    'Noto Sans',
    'Helvetica Neue',
    'Arial',
    'Apple Color Emoji',
    'Segoe UI Emoji',
    'Noto Color Emoji',
    'sans-serif',
  ];

  static const List<FontFeature> _tabular = [FontFeature.tabularFigures()];

  static double _opticalSize(double size) =>
      size < 8.0 ? 8.0 : (size > 144.0 ? 144.0 : size);

  TextStyle _s(double size, FontWeight w,
          {double height = _lh,
          Color? color,
          double? spacing,
          TextLeadingDistribution? leading,
          bool tabular = false}) =>
      TextStyle(
          fontFamily: fontFamily,
          fontFamilyFallback: fontFallback,
          fontSize: size,
          fontWeight: w,
          height: height,
          leadingDistribution: leading,
          color: color ?? _color,
          letterSpacing: spacing,
          fontFeatures: tabular ? _tabular : null,
          fontVariations: [
            FontVariation('wght', w.value.toDouble()),
            FontVariation('opsz', _opticalSize(size)),
          ]);

  TextStyle get display => _s(24, FontWeight.w700, height: 1.25, spacing: -0.4);
  TextStyle get title => _s(18, FontWeight.w600, height: 1.3, spacing: -0.25);
  TextStyle get rowTitle => _s(15.5, const FontWeight(550), spacing: -0.1);
  TextStyle get rowTitleUnread => _s(15.5, const FontWeight(650), spacing: -0.1);
  TextStyle get body => _s(15, FontWeight.w400, height: 1.45, spacing: 0);
  TextStyle get bodyWide =>
      _s(15, FontWeight.w400, height: 1.45, spacing: 0);
  TextStyle get rowSub => _s(13.5, FontWeight.w400, color: _tertiary);
  TextStyle get rowSubUnread => _s(13.5, const FontWeight(520), color: _color);
  TextStyle get labelRegular => _s(14, FontWeight.w400);
  TextStyle get label => _s(14, FontWeight.w500);
  TextStyle get labelStrong => _s(14, FontWeight.w600, spacing: -0.05);
  TextStyle get meta => _s(13, FontWeight.w400, color: _secondary);
  TextStyle get metaStrong => _s(13, FontWeight.w600);
  TextStyle get senderName => _s(13, const FontWeight(580),
      height: 1.3, color: _secondary, spacing: 0.1);
  TextStyle get caption => _s(12, FontWeight.w400, color: _tertiary);
  TextStyle get captionTabular =>
      _s(11.5, const FontWeight(420),
          height: 1.2, color: _tertiary, spacing: 0.2, tabular: true);
  TextStyle get captionStrong => _s(12, FontWeight.w600);
  TextStyle get navLabel =>
      _s(11, FontWeight.w500, height: 1.2, color: _tertiary, spacing: 0.05);
  TextStyle get navLabelSelected =>
      _s(11, FontWeight.w600, height: 1.2, spacing: 0.05);
  // Upper case Vietnamese stacks two marks over a capital (Ắ, Ễ); the taller
  // line keeps them inside the line box when the text is clipped.
  TextStyle get overline =>
      _s(11.5, FontWeight.w700, height: 1.5, color: _tertiary, spacing: 0.5);
  // Tight single line roles split the leading evenly so digits and capitals
  // sit on the optical center.
  TextStyle get badge => _s(11, FontWeight.w700,
      height: 1.05, leading: TextLeadingDistribution.even, tabular: true);
  TextStyle get emojiLarge => _s(32, FontWeight.w400, height: 1.2);
  TextStyle get emojiCell => _s(22, FontWeight.w400, height: 1.2);
  TextStyle emojiSized(double size) =>
      _s(size, FontWeight.w400, height: 1.0, leading: TextLeadingDistribution.even);
  TextStyle get emojiInline => _s(14, FontWeight.w400, height: 1.15);
  TextStyle mono(double size, {FontWeight weight = FontWeight.w600}) =>
      TextStyle(
          fontFamily: 'monospace',
          fontFamilyFallback: _monoFallback,
          fontSize: size,
          fontWeight: weight,
          height: 1.4,
          color: _color,
          letterSpacing: 1);
  TextStyle initials(double diameter, Color color) => TextStyle(
      fontFamily: fontFamily,
      fontFamilyFallback: fontFallback,
      fontSize: (diameter * 0.38).clamp(6.0, 40.0),
      fontWeight: FontWeight.w600,
      height: 1,
      leadingDistribution: TextLeadingDistribution.even,
      color: color);
}

/// Metrics of the message list. Compact follows UI.md 3.3, wide follows the
/// Zalo PC reference sections 8 and 9.
@immutable
class ChatMetrics {
  const ChatMetrics({
    required this.wide,
    required this.bubblePadding,
    required this.bubbleRadius,
    required this.groupedRadius,
    required this.gapInGroup,
    required this.gapBetweenGroups,
    required this.gapAroundSeparators,
    required this.avatar,
    required this.avatarGutter,
    required this.sidePadding,
    required this.outgoingReserve,
  });

  final bool wide;
  final EdgeInsets bubblePadding;
  final double bubbleRadius;
  final double groupedRadius;
  final double gapInGroup;
  final double gapBetweenGroups;
  final double gapAroundSeparators;
  final double avatar;
  final double avatarGutter;
  final double sidePadding;
  final double outgoingReserve;

  static const compact = ChatMetrics(
    wide: false,
    bubblePadding: EdgeInsets.symmetric(horizontal: 13, vertical: 9),
    bubbleRadius: 14,
    groupedRadius: 5,
    gapInGroup: 2,
    gapBetweenGroups: 12,
    gapAroundSeparators: 12,
    avatar: 28,
    avatarGutter: 36,
    sidePadding: 12,
    outgoingReserve: 0,
  );

  static const wideMetrics = ChatMetrics(
    wide: true,
    bubblePadding: EdgeInsets.all(12),
    bubbleRadius: 6,
    groupedRadius: 6,
    gapInGroup: 4,
    gapBetweenGroups: 8,
    gapAroundSeparators: 16,
    avatar: 40,
    avatarGutter: 50,
    sidePadding: 16,
    outgoingReserve: 88,
  );
}

@immutable
class ZalosTokens extends ThemeExtension<ZalosTokens> {
  const ZalosTokens({
    required this.dark,
    required this.brand,
    required this.brandPressed,
    required this.brandHover,
    required this.brandText,
    required this.brandSubtle,
    required this.headerStart,
    required this.headerEnd,
    required this.accent,
    required this.accentText,
    required this.onAccent,
    required this.layer,
    required this.layerSubtle,
    required this.layerHover,
    required this.layerPressed,
    required this.layerSelected,
    required this.surface,
    required this.textPrimary,
    required this.textSecondary,
    required this.textTertiary,
    required this.textDisabled,
    required this.textOnBrand,
    required this.divider,
    required this.border,
    required this.badge,
    required this.badgeMuted,
    required this.badgeMention,
    required this.onBadgeMention,
    required this.bubbleOut,
    required this.bubbleOutBorder,
    required this.bubbleOutPressed,
    required this.bubbleIn,
    required this.bubbleInBorder,
    required this.bubbleMetaOut,
    required this.bubbleMetaIn,
    required this.quoteBar,
    required this.danger,
    required this.dangerBg,
    required this.success,
    required this.successBg,
    required this.warning,
    required this.warningBg,
    required this.focusRing,
    required this.focusRingOnBrand,
    required this.pillBg,
    required this.onPill,
    required this.eventPillBg,
    required this.scrim,
    required this.skeleton,
    required this.skeletonShine,
    required this.searchHit,
    required this.railIcon,
    required this.railPlateSelected,
    required this.railPlateHover,
    required this.railDivider,
    required this.headerField,
    required this.headerFieldPressed,
    required this.navPill,
    required this.navBarBg,
    required this.navBarBorder,
    required this.shadowColor,
    required this.shadowHairline,
  });

  final bool dark;
  final Color brand,
      brandPressed,
      brandHover,
      brandText,
      brandSubtle,
      headerStart,
      headerEnd;
  final Color accent, accentText, onAccent;
  final Color layer,
      layerSubtle,
      layerHover,
      layerPressed,
      layerSelected,
      surface;
  final Color textPrimary,
      textSecondary,
      textTertiary,
      textDisabled,
      textOnBrand;
  final Color divider, border;
  final Color badge, badgeMuted, badgeMention, onBadgeMention;
  final Color bubbleOut,
      bubbleOutBorder,
      bubbleOutPressed,
      bubbleIn,
      bubbleInBorder,
      bubbleMetaOut,
      bubbleMetaIn,
      quoteBar;
  final Color danger, dangerBg, success, successBg, warning, warningBg;
  final Color focusRing,
      focusRingOnBrand,
      pillBg,
      onPill,
      eventPillBg,
      scrim,
      skeleton,
      skeletonShine,
      searchHit;
  final Color railIcon,
      railPlateSelected,
      railPlateHover,
      railDivider,
      headerField,
      headerFieldPressed,
      navPill,
      navBarBg,
      navBarBorder;
  final Color shadowColor, shadowHairline;

  static const Color clear = Color(0x00000000);
  static const Color white = Color(0xFFFFFFFF);
  static const Color black = Color(0xFF000000);
  static const Color mediaScrim = Color(0x40000000);
  static const Color mediaChip = Color(0x8C000000);
  static const Color mediaHover = Color(0x33000000);
  static const Color viewerBar = Color(0x99000000);

  static const List<Color> avatarPalette = [
    Color(0xFF8E3524),
    Color(0xFFB4533A),
    Color(0xFF8F6A00),
    Color(0xFF2A8246),
    Color(0xFF2F6F8F),
    Color(0xFF6B4FA0),
    Color(0xFFA14A76),
    Color(0xFF5E6B3A),
  ];

  static const light = ZalosTokens(
    dark: false,
    brand: Color(0xFF8E3524),
    brandPressed: Color(0xFF6E2618),
    brandHover: Color(0xFF7E2E1E),
    brandText: Color(0xFF8E3524),
    brandSubtle: Color(0xFFFBF3F0),
    headerStart: Color(0xFF8E3524),
    headerEnd: Color(0xFFB4533A),
    accent: Color(0xFFD4A017),
    accentText: Color(0xFF8F6A00),
    onAccent: Color(0xFF2A1D00),
    layer: Color(0xFFFFFFFF),
    layerSubtle: Color(0xFFF8F6F4),
    layerHover: Color(0xFFF5F1EE),
    layerPressed: Color(0xFFEDE7E3),
    layerSelected: Color(0xFFF6E2DB),
    surface: Color(0xFFEEE9E5),
    textPrimary: Color(0xFF1A1413),
    textSecondary: Color(0xFF3F3835),
    textTertiary: Color(0xFF6F6763),
    textDisabled: Color(0xFFADA5A0),
    textOnBrand: Color(0xFFFFFFFF),
    divider: Color(0x1A000000),
    border: Color(0x24000000),
    badge: Color(0xFFD4A017),
    badgeMuted: Color(0xFFCFC8C3),
    badgeMention: Color(0xFF8E3524),
    onBadgeMention: Color(0xFFFFFFFF),
    bubbleOut: Color(0xFFF8E4DC),
    bubbleOutBorder: Color(0xFFE6C3B6),
    bubbleOutPressed: Color(0xFFF0D2C6),
    bubbleIn: Color(0xFFFFFFFF),
    bubbleInBorder: Color(0xFFE2DCD8),
    bubbleMetaOut: Color(0xFF7A5F56),
    bubbleMetaIn: Color(0xFF776C67),
    quoteBar: Color(0xFF8E3524),
    danger: Color(0xFFD92D20),
    dangerBg: Color(0xFFFDE7E4),
    success: Color(0xFF2A8246),
    successBg: Color(0xFFEAF6EE),
    warning: Color(0xFF8F6A00),
    warningBg: Color(0xFFFBF3DC),
    focusRing: Color(0xFF8E3524),
    focusRingOnBrand: Color(0xFFFFFFFF),
    pillBg: Color(0xCC1A1413),
    onPill: Color(0xFFFFFFFF),
    eventPillBg: Color(0xD9FFFFFF),
    scrim: Color(0x8C000000),
    skeleton: Color(0x1A000000),
    skeletonShine: Color(0x0D000000),
    searchHit: Color(0x66D4A017),
    railIcon: Color(0xB8FFFFFF),
    railPlateSelected: Color(0x29FFFFFF),
    railPlateHover: Color(0x26000000),
    railDivider: Color(0x33FFFFFF),
    headerField: Color(0x33FFFFFF),
    headerFieldPressed: Color(0x40FFFFFF),
    navPill: Color(0xFFF6E2DB),
    navBarBg: Color(0xFFFFFFFF),
    navBarBorder: Color(0x18000000),
    shadowColor: Color(0xFF2B1A14),
    shadowHairline: Color(0x00000000),
  );

  static const darkTokens = ZalosTokens(
    dark: true,
    brand: Color(0xFF8E3524),
    brandPressed: Color(0xFF6E2618),
    brandHover: Color(0xFF9C3D2A),
    brandText: Color(0xFFE3A692),
    brandSubtle: Color(0xFF2B120C),
    headerStart: Color(0xFF211D1C),
    headerEnd: Color(0xFF211D1C),
    accent: Color(0xFFE0B341),
    accentText: Color(0xFFE0B341),
    onAccent: Color(0xFF2A1D00),
    layer: Color(0xFF1A1716),
    layerSubtle: Color(0xFF121010),
    layerHover: Color(0xFF25211F),
    layerPressed: Color(0xFF2B2624),
    layerSelected: Color(0xFF3A1810),
    surface: Color(0xFF0C0A0A),
    textPrimary: Color(0xFFF7F3F1),
    textSecondary: Color(0xFFCFC6C1),
    textTertiary: Color(0xFF9A908B),
    textDisabled: Color(0xFF5C5552),
    textOnBrand: Color(0xFFFFFFFF),
    divider: Color(0x33FFFFFF),
    border: Color(0x40FFFFFF),
    badge: Color(0xFFE0B341),
    badgeMuted: Color(0xFF4D4643),
    badgeMention: Color(0xFFE3A692),
    onBadgeMention: Color(0xFF2B120C),
    bubbleOut: Color(0xFF4A2A22),
    bubbleOutBorder: Color(0xFF5E382E),
    bubbleOutPressed: Color(0xFF3C211A),
    bubbleIn: Color(0xFF2B2725),
    bubbleInBorder: Color(0xFF3A3431),
    bubbleMetaOut: Color(0xFFB59C93),
    bubbleMetaIn: Color(0xFF9A908B),
    quoteBar: Color(0xFFE3A692),
    danger: Color(0xFFFF6B5E),
    dangerBg: Color(0xFF4A1711),
    success: Color(0xFF4CC078),
    successBg: Color(0xFF0C2415),
    warning: Color(0xFFE0B341),
    warningBg: Color(0xFF2E2406),
    focusRing: Color(0xFFE3A692),
    focusRingOnBrand: Color(0xFFFFFFFF),
    pillBg: Color(0x1FFFFFFF),
    onPill: Color(0xFFF7F3F1),
    eventPillBg: Color(0x14FFFFFF),
    scrim: Color(0x99000000),
    skeleton: Color(0x14FFFFFF),
    skeletonShine: Color(0x0AFFFFFF),
    searchHit: Color(0x66E0B341),
    railIcon: Color(0xB8FFFFFF),
    railPlateSelected: Color(0x29FFFFFF),
    railPlateHover: Color(0x1AFFFFFF),
    railDivider: Color(0x33FFFFFF),
    headerField: Color(0x24FFFFFF),
    headerFieldPressed: Color(0x33FFFFFF),
    navPill: Color(0xFF3A1D15),
    navBarBg: Color(0xFF1F1B1A),
    navBarBorder: Color(0x24FFFFFF),
    shadowColor: Color(0xFF030404),
    shadowHairline: Color(0x14F0D6BC),
  );

  ZType get text => ZType._(textPrimary, textSecondary, textTertiary);

  Gradient get headerGradient => LinearGradient(
      begin: Alignment.bottomLeft,
      end: Alignment.topRight,
      colors: [headerStart, headerEnd]);

  static const Gradient markGradient = LinearGradient(
      begin: Alignment.bottomLeft,
      end: Alignment.topRight,
      colors: [Color(0xFF8E3524), Color(0xFFB4533A)]);

  /// Menus, sheets, dialogs and the hover action bar.
  List<BoxShadow> get shadowOverlay => [
        BoxShadow(
            color: shadowColor.withValues(alpha: dark ? 0.5 : 0.3),
            blurRadius: 1),
        BoxShadow(
            color: shadowColor.withValues(alpha: dark ? 0.30 : 0.12),
            blurRadius: 20,
            offset: const Offset(0, 10)),
      ];

  /// Hairline that gives a secondary control its own edge on the brand tint.
  Color get secondaryButtonBorder => brandText.withValues(alpha: 0.32);

  /// Floating round buttons over the message list.
  List<BoxShadow> get shadowOverflow => [
        BoxShadow(
            color: shadowColor.withValues(alpha: dark ? 0.5 : 0.12),
            blurRadius: 1),
        BoxShadow(
            color: shadowColor.withValues(alpha: dark ? 0.56 : 0.15),
            blurRadius: dark ? 12 : 8),
      ];

  /// Bubbles on wide layouts.
  List<BoxShadow> get shadowBubble => [
        BoxShadow(
            color: shadowColor.withValues(alpha: dark ? 0.5 : 0.25),
            blurRadius: 1),
        BoxShadow(
            color: shadowColor.withValues(alpha: dark ? 0.5 : 0.25),
            blurRadius: 1,
            offset: const Offset(0, 1)),
      ];

  /// Soft elevation shadow under the floating compact bottom navigation capsule.
  List<BoxShadow> get shadowNav => [
        BoxShadow(
            color: shadowColor.withValues(alpha: dark ? 0.45 : 0.10),
            blurRadius: 18,
            offset: const Offset(0, 6)),
        BoxShadow(
            color: shadowColor.withValues(alpha: dark ? 0.25 : 0.04),
            blurRadius: 2,
            offset: const Offset(0, 1)),
      ];

  /// Soft left-edge drop shadow cast by a sliding compact pane.
  List<BoxShadow> get shadowEdge => [
        BoxShadow(
            color: shadowColor.withValues(alpha: dark ? 0.36 : 0.14),
            blurRadius: 18,
            offset: const Offset(-4, 0)),
      ];

  Color avatarColor(String id) {
    var h = 7;
    for (final c in id.codeUnits) {
      h = (h * 31 + c) & 0x3fffffff;
    }
    return avatarPalette[h % avatarPalette.length];
  }

  /// File type icon color by extension family, taken from the avatar palette.
  Color fileColor(String extension) {
    switch (extension.toLowerCase()) {
      case 'pdf':
        return danger;
      case 'doc' || 'docx' || 'txt' || 'rtf':
        return avatarPalette[4];
      case 'xls' || 'xlsx' || 'csv':
        return avatarPalette[3];
      case 'ppt' || 'pptx':
        return avatarPalette[1];
      case 'zip' || 'rar' || '7z' || 'gz' || 'tar':
        return avatarPalette[2];
      case 'mp3' || 'm4a' || 'wav' || 'aac' || 'mp4' || 'mov' || 'mkv':
        return avatarPalette[5];
      default:
        return avatarPalette[7];
    }
  }

  @override
  ZalosTokens copyWith() => this;

  @override
  ZalosTokens lerp(ThemeExtension<ZalosTokens>? other, double t) => other is ZalosTokens && t >= 0.5 ? other : this;
}

extension ZalosTokensContext on BuildContext {
  ZalosTokens get z => Theme.of(this).extension<ZalosTokens>()!;
}

/// Carries the adaptive layout class down the tree.
class LayoutScope extends InheritedWidget {
  const LayoutScope({super.key, required this.layout, required super.child});

  final LayoutClass layout;

  static LayoutClass of(BuildContext context) =>
      context.dependOnInheritedWidgetOfExactType<LayoutScope>()?.layout ?? LayoutClass.compact;

  static bool wideOf(BuildContext context) => of(context) != LayoutClass.compact;

  @override
  bool updateShouldNotify(LayoutScope oldWidget) => oldWidget.layout != layout;
}
