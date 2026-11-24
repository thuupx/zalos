import 'package:material_ui/material_ui.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:zalos/src/ui/components/basics.dart';
import 'package:zalos/src/ui/components/onboarding.dart';
import 'package:zalos/src/ui/components/pressable.dart';
import 'package:zalos/src/ui/theme/theme.dart';
import 'package:zalos/src/ui/theme/tokens.dart';

Widget _host(Widget child, {Brightness brightness = Brightness.light}) =>
    MaterialApp(
      theme: buildZalosTheme(brightness),
      home: Scaffold(body: Center(child: child)),
    );

Color _pressableFill(WidgetTester tester) {
  final pressable = find.byType(ZPressable).first;
  final overlays =
      find.descendant(of: pressable, matching: find.byType(AnimatedOpacity));
  for (final element in overlays.evaluate()) {
    final fade = element.widget as AnimatedOpacity;
    if (fade.opacity > 0) {
      final box = tester.widget<DecoratedBox>(find
          .descendant(of: find.byWidget(fade), matching: find.byType(DecoratedBox))
          .first);
      return (box.decoration as BoxDecoration).color!;
    }
  }
  final box = tester.widget<DecoratedBox>(find
      .descendant(of: pressable, matching: find.byType(DecoratedBox))
      .first);
  return (box.decoration as BoxDecoration).color!;
}

void main() {
  test('semantic tokens carry the enterprise values', () {
    for (final z in [ZalosTokens.light, ZalosTokens.darkTokens]) {
      expect(z.focusRingOnBrand, const Color(0xFFFFFFFF));
      expect(z.secondaryButtonBorder, z.brandText.withValues(alpha: 0.32));
    }
    expect(ZalosTokens.light.headerField, const Color(0x33FFFFFF));
    expect(ZalosTokens.light.headerFieldPressed, const Color(0x40FFFFFF));
    expect(ZalosTokens.light.border, const Color(0x24000000));
    expect(ZalosTokens.darkTokens.headerField, const Color(0x24FFFFFF));
    expect(ZalosTokens.darkTokens.headerFieldPressed, const Color(0x33FFFFFF));
    expect(ZalosTokens.darkTokens.layerHover, const Color(0xFF25211F));
    expect(ZalosTokens.darkTokens.bubbleInBorder, const Color(0xFF3A3431));
    expect(ZRadius.button, 10);
  });

  test('small type roles have clean readable sizes and tracking', () {
    final t = ZalosTokens.light.text;
    expect(t.label.fontSize, 14);
    expect(t.meta.fontSize, 13);
    expect(t.caption.fontSize, 12);
    expect(t.navLabel.fontSize, 11);
  });

  test('overlay shadow softens the broad pass and keeps the hairline', () {
    for (final z in [ZalosTokens.light, ZalosTokens.darkTokens]) {
      final shadow = z.shadowOverlay;
      expect(shadow, hasLength(2));
      expect(shadow.first.blurRadius, 1);
      expect(shadow.first.offset, Offset.zero);
      expect(shadow.last.blurRadius, 20);
      expect(shadow.last.offset, const Offset(0, 10));
      expect(shadow.last.color.a, closeTo(z.dark ? 0.30 : 0.12, 0.005));
    }
  });

  test('theme maps surfaces and accent tones to the semantic tokens', () {
    for (final brightness in Brightness.values) {
      final theme = buildZalosTheme(brightness);
      final z = theme.extension<ZalosTokens>()!;
      final scheme = theme.colorScheme;
      expect(scheme.surfaceContainerLow, z.layerSubtle);
      expect(scheme.surfaceContainer, z.layer);
      expect(scheme.tertiary, z.accentText);
      expect(scheme.onTertiary, z.onAccent);
      expect(scheme.secondary, z.accentText);
      expect(scheme.onSecondary, z.onAccent);
    }
  });

  testWidgets('filled buttons take the white on-brand focus ring',
      (tester) async {
    for (final variant in [
      ZButtonVariant.primary,
      ZButtonVariant.destructive
    ]) {
      await tester.pumpWidget(_host(
          ZButton(label: 'Continue', onPressed: () {}, variant: variant)));
      expect(tester.widget<ZPressable>(find.byType(ZPressable)).focusRingColor,
          ZalosTokens.light.focusRingOnBrand);
    }
    for (final variant in [
      ZButtonVariant.secondary,
      ZButtonVariant.text,
      ZButtonVariant.destructiveText
    ]) {
      await tester.pumpWidget(_host(
          ZButton(label: 'Continue', onPressed: () {}, variant: variant)));
      expect(tester.widget<ZPressable>(find.byType(ZPressable)).focusRingColor,
          isNull);
    }
    await tester.pumpWidget(_host(ZButton(label: 'Continue', onPressed: () {}),
        brightness: Brightness.dark));
    expect(tester.widget<ZPressable>(find.byType(ZPressable)).focusRingColor,
        ZalosTokens.darkTokens.focusRingOnBrand);
  });

  testWidgets('focus ring paints the override color', (tester) async {
    FocusManager.instance.highlightStrategy =
        FocusHighlightStrategy.alwaysTraditional;
    addTearDown(() => FocusManager.instance.highlightStrategy =
        FocusHighlightStrategy.automatic);
    final node = FocusNode();
    addTearDown(node.dispose);
    await tester.pumpWidget(_host(ZPressable(
        focusNode: node,
        onTap: () {},
        focusRingColor: ZalosTokens.white,
        child: const SizedBox(width: 80, height: 40))));
    node.requestFocus();
    await tester.pump();
    final box = tester
        .widgetList<DecoratedBox>(find.descendant(
            of: find.byType(ZPressable), matching: find.byType(DecoratedBox)))
        .firstWhere((d) => d.position == DecorationPosition.foreground);
    final ring = (box.decoration as BoxDecoration).border! as Border;
    expect(ring.top.color, ZalosTokens.white);
  });

  testWidgets(
      'every button variant shares the radius and only secondary has a hairline',
      (tester) async {
    for (final variant in ZButtonVariant.values) {
      await tester.pumpWidget(_host(
          ZButton(label: 'Continue', onPressed: () {}, variant: variant)));
      final pressable = tester.widget<ZPressable>(find.byType(ZPressable));
      expect(pressable.radius, ZRadius.button, reason: '$variant');
      if (variant == ZButtonVariant.secondary) {
        final border = pressable.border! as Border;
        expect(border.top.color, ZalosTokens.light.secondaryButtonBorder);
        expect(border.top.width, 1);
      } else {
        expect(pressable.border, isNull, reason: '$variant');
      }
    }
  });

  testWidgets('header field controls press to the white pressed tint',
      (tester) async {
    const z = ZalosTokens.light;
    await tester.pumpWidget(_host(ZPressable(
        hoverColor: z.headerField,
        onTap: () {},
        child: const SizedBox(width: 80, height: 40))));
    final gesture =
        await tester.startGesture(tester.getCenter(find.byType(ZPressable)));
    await tester.pump();
    await tester.pump(ZMotion.fast);
    expect(_pressableFill(tester), z.headerFieldPressed);
    await gesture.up();
    await tester.pump();

    await tester.pumpWidget(_host(ZPressable(
        onTap: () {}, child: const SizedBox(width: 80, height: 40))));
    final plain =
        await tester.startGesture(tester.getCenter(find.byType(ZPressable)));
    await tester.pump();
    await tester.pump(ZMotion.fast);
    expect(_pressableFill(tester), z.layerPressed);
    await plain.up();
    await tester.pump();
  });

  testWidgets('segmented control sits on a subtle inset track', (tester) async {
    await tester.pumpWidget(_host(ZSegmented<int>(
        segments: const [(0, 'All'), (1, 'Unread')],
        selected: 0,
        onChanged: (_) {})));
    final track =
        tester.widgetList<Container>(find.byType(Container)).firstWhere((c) {
      final decoration = c.decoration;
      return decoration is BoxDecoration &&
          decoration.borderRadius == BorderRadius.circular(ZRadius.input);
    });
    expect((track.decoration! as BoxDecoration).color,
        ZalosTokens.light.layerSubtle);
  });

  testWidgets('wide onboarding card carries the softened overlay shadow',
      (tester) async {
    tester.view.physicalSize = const Size(1440, 900);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    await tester.pumpWidget(MaterialApp(
      theme: buildZalosTheme(Brightness.light),
      home: const LayoutScope(
          layout: LayoutClass.expanded,
          child: ZOnboardingFrame(child: Text('Pair'))),
    ));
    final card = tester
        .widgetList<DecoratedBox>(find.byType(DecoratedBox))
        .firstWhere((box) {
      final decoration = box.decoration;
      return decoration is BoxDecoration &&
          decoration.borderRadius == BorderRadius.circular(ZRadius.card);
    });
    final decoration = card.decoration as BoxDecoration;
    expect(decoration.boxShadow, ZalosTokens.light.shadowOverlay);
    expect(decoration.border, isNotNull);
  });
}
