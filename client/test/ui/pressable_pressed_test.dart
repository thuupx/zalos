import 'dart:math' as math;

import 'package:flutter/gestures.dart';
import 'package:flutter/rendering.dart';
import 'package:material_ui/material_ui.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:zalos/src/ui/components/pressable.dart';
import 'package:zalos/src/ui/theme/theme.dart';
import 'package:zalos/src/ui/theme/tokens.dart';

/// Milliseconds after the pointer change at which the composite fill is sampled.
const _stops = [0, 20, 40, 60, 85, 115, 150];

Widget _host(Widget child, Brightness brightness) => MaterialApp(
      theme: buildZalosTheme(brightness),
      home: Scaffold(body: Center(child: child)),
    );

/// Composites the resting surface plus any active hover/press overlays of the
/// first [ZPressable] over [backdrop].
Color _compositeFill(WidgetTester tester, Color backdrop) {
  final pressable = find.byType(ZPressable).first;
  final boxes = tester
      .widgetList<DecoratedBox>(
          find.descendant(of: pressable, matching: find.byType(DecoratedBox)))
      .toList();
  var result = backdrop;
  // Base background box is the first DecoratedBox.
  final baseColor = (boxes.first.decoration as BoxDecoration).color;
  if (baseColor != null) result = Color.alphaBlend(baseColor, result);
  // Overlay boxes live inside AnimatedOpacity -> DecoratedBox.
  final overlays = find.descendant(
      of: pressable, matching: find.byType(AnimatedOpacity));
  for (final element in overlays.evaluate()) {
    final fade = element.widget as AnimatedOpacity;
    final renderOpacity = tester.renderObject<RenderAnimatedOpacity>(
        find.byWidget(fade));
    final alpha = renderOpacity.opacity.value;
    if (alpha <= 0) continue;
    final box = tester.widget<DecoratedBox>(find
        .descendant(of: find.byWidget(fade), matching: find.byType(DecoratedBox))
        .first);
    final overlayColor = (box.decoration as BoxDecoration).color;
    if (overlayColor != null) {
      result = Color.alphaBlend(
          overlayColor.withValues(alpha: overlayColor.a * alpha), result);
    }
  }
  return result;
}

double _lum(Color c) => c.computeLuminance();

Future<List<Color>> _sample(WidgetTester tester, Color backdrop) async {
  final samples = <Color>[_compositeFill(tester, backdrop)];
  var elapsed = 0;
  for (final stop in _stops.skip(1)) {
    await tester.pump(Duration(milliseconds: stop - elapsed));
    elapsed = stop;
    samples.add(_compositeFill(tester, backdrop));
  }
  return samples;
}

Future<void> _expectCleanPress(
  WidgetTester tester, {
  required Color rest,
  required Color pressed,
  required Color backdrop,
}) async {
  final restComposite = Color.alphaBlend(rest, backdrop);
  final pressedComposite = Color.alphaBlend(pressed, restComposite);
  final floor = math.min(_lum(restComposite), _lum(pressedComposite)) - 0.005;

  final gesture =
      await tester.startGesture(tester.getCenter(find.byType(ZPressable)));
  await tester.pump();
  final press = await _sample(tester, backdrop);
  await gesture.up();
  await tester.pump();
  final release = await _sample(tester, backdrop);

  expect(press.first.toARGB32(), pressedComposite.toARGB32(),
      reason: 'press must land on pressed fill without dark flash');
  for (final (i, color) in press.indexed) {
    expect(_lum(color), greaterThanOrEqualTo(floor),
        reason: 'press at ${_stops[i]} ms flashed darker ($color)');
  }
  for (final (i, color) in release.indexed) {
    expect(_lum(color), greaterThanOrEqualTo(floor),
        reason: 'release at ${_stops[i]} ms flashed darker ($color)');
  }
  expect(release.last.toARGB32(), restComposite.toARGB32(),
      reason: 'release must settle cleanly back to rest fill');
}

void main() {
  testWidgets(
      'transparent rest color presses and releases without a dark flash',
      (tester) async {
    const z = ZalosTokens.light;
    await tester.pumpWidget(_host(
      ZPressable(
          hoverColor: ZalosTokens.clear,
          onTap: () {},
          child: const SizedBox(width: 120, height: 44)),
      Brightness.light,
    ));
    await _expectCleanPress(tester,
        rest: ZalosTokens.clear, pressed: z.layerPressed, backdrop: z.layer);
  });

  testWidgets('opaque primary button presses without a dark flash',
      (tester) async {
    const z = ZalosTokens.light;
    await tester.pumpWidget(
        _host(ZButton(label: 'Send', onPressed: () {}), Brightness.light));
    await _expectCleanPress(tester,
        rest: z.brand, pressed: z.brandPressed, backdrop: z.layer);
  });

  testWidgets('dark theme press never flashes black', (tester) async {
    const z = ZalosTokens.darkTokens;
    await tester.pumpWidget(_host(
      ZPressable(
          hoverColor: ZalosTokens.clear,
          onTap: () {},
          child: const SizedBox(width: 120, height: 44)),
      Brightness.dark,
    ));
    await _expectCleanPress(tester,
        rest: ZalosTokens.clear, pressed: z.layerPressed, backdrop: z.layer);
  });

  testWidgets('pressHighlight: false never paints a gray press slab',
      (tester) async {
    const z = ZalosTokens.light;
    await tester.pumpWidget(_host(
      ZPressable(
        pressHighlight: false,
        hoverColor: ZalosTokens.clear,
        onTap: () {},
        child: const SizedBox(width: 120, height: 44),
      ),
      Brightness.light,
    ));
    final gesture =
        await tester.startGesture(tester.getCenter(find.byType(ZPressable)));
    await tester.pump();
    expect(_compositeFill(tester, z.layer).toARGB32(), z.layer.toARGB32());
    await gesture.up();
    await tester.pumpAndSettle();
    expect(_compositeFill(tester, z.layer).toARGB32(), z.layer.toARGB32());
  });

  testWidgets('rebuilding parent on tap never triggers a dark flash',
      (tester) async {
    const z = ZalosTokens.light;
    var active = false;
    await tester.pumpWidget(StatefulBuilder(
      builder: (context, setState) => _host(
        ZPressable(
          color: active ? z.brandSubtle : null,
          onTap: () => setState(() => active = !active),
          child: const SizedBox(width: 120, height: 44),
        ),
        Brightness.light,
      ),
    ));
    final floor = _lum(z.layerPressed) - 0.005;
    final gesture =
        await tester.startGesture(tester.getCenter(find.byType(ZPressable)));
    await tester.pump();
    await gesture.up();
    await tester.pump();
    for (var ms = 0; ms <= 160; ms += 20) {
      await tester.pump(const Duration(milliseconds: 20));
      final painted = _compositeFill(tester, z.layer);
      expect(_lum(painted), greaterThanOrEqualTo(floor),
          reason: 'rebuild at $ms ms flashed dark ($painted)');
    }
    expect(active, isTrue);
  });

  testWidgets('hover keeps its smooth opacity fade', (tester) async {
    const z = ZalosTokens.light;
    await tester.pumpWidget(_host(
        ZPressable(onTap: () {}, child: const SizedBox(width: 120, height: 44)),
        Brightness.light));
    final rest = _compositeFill(tester, z.layer);
    final mouse = await tester.createGesture(kind: PointerDeviceKind.mouse);
    await mouse.addPointer(location: Offset.zero);
    await mouse.moveTo(tester.getCenter(find.byType(ZPressable)));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 75));
    final mid = _compositeFill(tester, z.layer);
    expect(mid.toARGB32(), isNot(rest.toARGB32()),
        reason: 'hover jumped instead of fading');
    expect(mid.toARGB32(), isNot(z.layerHover.toARGB32()),
        reason: 'hover jumped instead of fading');
    await tester.pump(const Duration(milliseconds: 75));
    expect(_compositeFill(tester, z.layer).toARGB32(), z.layerHover.toARGB32());
    await mouse.removePointer();
  });
}
