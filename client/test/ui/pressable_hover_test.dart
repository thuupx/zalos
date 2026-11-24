import 'package:flutter/gestures.dart';
import 'package:flutter/rendering.dart';
import 'package:material_ui/material_ui.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:zalos/src/ui/components/pressable.dart';

import '../support/harness.dart';

double _lum(Color c) => c.computeLuminance();

Color _composite(WidgetTester tester, Finder pressable) {
  final boxes = tester
      .widgetList<DecoratedBox>(
          find.descendant(of: pressable, matching: find.byType(DecoratedBox)))
      .toList();
  var result = Colors.white;
  final base = (boxes.first.decoration as BoxDecoration).color;
  if (base != null) result = Color.alphaBlend(base, result);
  final overlays =
      find.descendant(of: pressable, matching: find.byType(AnimatedOpacity));
  for (final element in overlays.evaluate()) {
    final fade = element.widget as AnimatedOpacity;
    final alpha =
        tester.renderObject<RenderAnimatedOpacity>(find.byWidget(fade)).opacity.value;
    if (alpha <= 0) continue;
    final box = tester.widget<DecoratedBox>(find
        .descendant(of: find.byWidget(fade), matching: find.byType(DecoratedBox))
        .first);
    final overlay = (box.decoration as BoxDecoration).color;
    if (overlay != null) {
      result = Color.alphaBlend(
          overlay.withValues(alpha: overlay.a * alpha), result);
    }
  }
  return result;
}

Future<void> _expectNoDarkFlash(WidgetTester tester, Finder target) async {
  final pressable =
      find.descendant(of: target, matching: find.byType(ZPressable), matchRoot: true).first;
  final start = _composite(tester, pressable);
  final mouse = await tester.createGesture(kind: PointerDeviceKind.mouse);
  await mouse.addPointer(location: Offset.zero);
  await mouse.moveTo(tester.getCenter(pressable));
  final samples = <Color>[];
  for (var i = 0; i < 8; i++) {
    await tester.pump(const Duration(milliseconds: 25));
    samples.add(_composite(tester, pressable));
  }
  final floor = [_lum(start), _lum(samples.last)].reduce((a, b) => a < b ? a : b) - 0.005;
  for (final c in samples) {
    expect(_lum(c), greaterThanOrEqualTo(floor), reason: 'mid-fade $c is darker than both $start and ${samples.last}');
  }
  await mouse.removePointer();
}

void main() {
  testWidgets('hover fades never pass through a dark color (thread row, chat header name)', (tester) async {
    await pumpZalos(tester, size: expanded);
    await _expectNoDarkFlash(tester, byKey('thread-g01'));
    await openThreadByKey(tester, 'g01');
    await _expectNoDarkFlash(tester, byKey('chatHeaderInfo'));
    await drain(tester);
  });
}
