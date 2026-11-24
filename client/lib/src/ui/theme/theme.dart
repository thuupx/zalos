import 'package:cupertino_ui/cupertino_ui.dart' show CupertinoPageTransitionsBuilder;
import 'package:material_ui/material_ui.dart';

import 'tokens.dart';

ThemeData buildZalosTheme(Brightness brightness) {
  final z = brightness == Brightness.dark ? ZalosTokens.darkTokens : ZalosTokens.light;
  final type = z.text;
  final scheme = ColorScheme.fromSeed(seedColor: z.brand, brightness: brightness).copyWith(
    primary: z.brandText,
    onPrimary: z.dark ? z.brandSubtle : z.textOnBrand,
    secondary: z.accentText,
    onSecondary: z.onAccent,
    tertiary: z.accentText,
    onTertiary: z.onAccent,
    surface: z.layer,
    onSurface: z.textPrimary,
    onSurfaceVariant: z.textSecondary,
    surfaceContainerLowest: z.layer,
    surfaceContainerLow: z.layerSubtle,
    surfaceContainer: z.layer,
    surfaceContainerHigh: z.layer,
    surfaceContainerHighest: z.layerPressed,
    error: z.danger,
    outline: z.border,
    outlineVariant: z.divider,
    surfaceTint: ZalosTokens.clear,
    shadow: z.shadowColor,
    scrim: z.scrim,
  );
  final base = ThemeData(useMaterial3: true, brightness: brightness, colorScheme: scheme, fontFamily: ZType.fontFamily, fontFamilyFallback: ZType.fontFallback);
  return base.copyWith(
    extensions: [z],
    scaffoldBackgroundColor: z.layer,
    canvasColor: z.layer,
    dividerColor: z.divider,
    splashFactory: NoSplash.splashFactory,
    highlightColor: ZalosTokens.clear,
    hoverColor: z.layerHover,
    focusColor: ZalosTokens.clear,
    dividerTheme: DividerThemeData(color: z.divider, thickness: 1, space: 1),
    iconTheme: IconThemeData(color: z.textSecondary, size: 24, weight: 400),
    textTheme: base.textTheme
        .copyWith(
          bodyLarge: base.textTheme.bodyLarge?.merge(type.body) ?? type.body,
          bodyMedium: base.textTheme.bodyMedium?.merge(type.body) ?? type.body,
          bodySmall: base.textTheme.bodySmall?.merge(type.caption) ?? type.caption,
          titleLarge: base.textTheme.titleLarge?.merge(type.title) ?? type.title,
          titleMedium: base.textTheme.titleMedium?.merge(type.rowTitle) ?? type.rowTitle,
          titleSmall: base.textTheme.titleSmall?.merge(type.label) ?? type.label,
          labelLarge: base.textTheme.labelLarge?.merge(type.label) ?? type.label,
          labelMedium: base.textTheme.labelMedium?.merge(type.caption) ?? type.caption,
          labelSmall: base.textTheme.labelSmall?.merge(type.caption) ?? type.caption,
        )
        .apply(bodyColor: z.textPrimary, displayColor: z.textPrimary),
    textSelectionTheme: TextSelectionThemeData(
      cursorColor: z.brandText,
      selectionColor: z.brandText.withValues(alpha: 0.28),
      selectionHandleColor: z.brandText,
    ),
    scrollbarTheme: ScrollbarThemeData(
      thickness: const WidgetStatePropertyAll(6),
      radius: const Radius.circular(ZRadius.row),
      thumbColor: WidgetStatePropertyAll(z.textTertiary.withValues(alpha: 0.5)),
    ),
    tooltipTheme: TooltipThemeData(
      waitDuration: const Duration(milliseconds: 500),
      textStyle: type.meta.copyWith(color: z.textOnBrand),
      padding: const EdgeInsets.symmetric(horizontal: ZSpace.s12, vertical: ZSpace.s8),
      decoration: BoxDecoration(color: z.dark ? z.layerPressed : z.textPrimary, borderRadius: BorderRadius.circular(ZRadius.tight)),
    ),
    progressIndicatorTheme: ProgressIndicatorThemeData(color: z.brandText),
    checkboxTheme: CheckboxThemeData(
      fillColor: WidgetStateProperty.resolveWith((s) => s.contains(WidgetState.selected) ? z.brand : null),
      checkColor: WidgetStatePropertyAll(z.textOnBrand),
      side: BorderSide(color: z.textTertiary, width: 1.5),
    ),
    switchTheme: SwitchThemeData(
      thumbColor: WidgetStateProperty.resolveWith((s) => s.contains(WidgetState.selected) ? z.textOnBrand : z.layer),
      trackColor: WidgetStateProperty.resolveWith((s) => s.contains(WidgetState.selected) ? z.brand : z.textTertiary),
      trackOutlineColor: const WidgetStatePropertyAll(ZalosTokens.clear),
    ),
    pageTransitionsTheme: const PageTransitionsTheme(builders: {
      TargetPlatform.android: CupertinoPageTransitionsBuilder(),
      TargetPlatform.iOS: CupertinoPageTransitionsBuilder(),
      TargetPlatform.macOS: FadeUpwardsPageTransitionsBuilder(),
      TargetPlatform.windows: FadeUpwardsPageTransitionsBuilder(),
      TargetPlatform.linux: FadeUpwardsPageTransitionsBuilder(),
    }),
  );
}
