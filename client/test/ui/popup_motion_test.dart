import 'package:flutter/gestures.dart';
import 'package:material_ui/material_ui.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:zalos/src/domain/models.dart';
import 'package:zalos/src/ui/components/overlays.dart';

import '../support/harness.dart';

Future<void> _openMenu(WidgetTester tester, Offset at) async {
  await tester.tapAt(at, buttons: kSecondaryButton);
  await settle(tester);
}

Future<void> _openPicker(WidgetTester tester, String messageId) async {
  await hover(tester, byKey('bubble-$messageId'));
  await tester.tap(byKey('hoverReact-$messageId'));
  await settle(tester);
}

void main() {
  group('popupScaleOrigin', () {
    test('an anchor on a corner or at the center maps to that alignment', () {
      const rect = Rect.fromLTWH(100, 200, 240, 120);
      expect(popupScaleOrigin(const Offset(100, 200), rect), const Alignment(-1, -1));
      expect(popupScaleOrigin(const Offset(220, 260), rect), Alignment.center);
      expect(popupScaleOrigin(const Offset(340, 320), rect), const Alignment(1, 1));
    });

    test('a menu that flips near the far edges anchors on its far corner', () {
      const rect = Rect.fromLTWH(700, 300, 200, 100);
      expect(popupScaleOrigin(const Offset(900, 300), rect), const Alignment(1, -1));
      expect(popupScaleOrigin(const Offset(700, 400), rect), const Alignment(-1, 1));
    });

    test('an anchor clamped outside the popup stays the fixed point beyond the corner', () {
      const rect = Rect.fromLTWH(8, 8, 240, 120);
      final origin = popupScaleOrigin(const Offset(-40, -30), rect);
      expect(origin.x, lessThan(-1));
      expect(origin.y, lessThan(-1));
    });

    test('a zero-size popup falls back to the center', () {
      expect(popupScaleOrigin(const Offset(10, 10), Rect.zero), Alignment.center);
    });
  });

  testWidgets('showZMenu scales from the real anchor and Escape closes it', (tester) async {
    final h = await pumpZalos(tester, size: expanded);
    await openThreadByKey(tester, 'g01');
    final m = h.main.messages('g01', ThreadType.group).value.last;
    final at = tester.getCenter(byKey('bubble-${m.id}'));
    await _openMenu(tester, at);
    expect(byKey('menu-MessageAction.copy'), findsOneWidget);
    expect(tester.widget<ZPopupScale>(find.byType(ZPopupScale)).anchor, at);
    await sendKey(tester, LogicalKeyboardKey.escape);
    expect(byKey('menu-MessageAction.copy'), findsNothing);
    await drain(tester);
  });

  testWidgets('the reaction picker scales from the anchor and Escape closes it', (tester) async {
    final h = await pumpZalos(tester, size: expanded);
    await openThreadByKey(tester, 'g01');
    final m = h.main.messages('g01', ThreadType.group).value.last;
    await _openPicker(tester, m.id);
    expect(byKey('reactionPicker'), findsOneWidget);
    expect(find.byType(ZPopupScale), findsOneWidget);
    await sendKey(tester, LogicalKeyboardKey.escape);
    expect(byKey('reactionPicker'), findsNothing);
    await drain(tester);
  });

  testWidgets('reduced motion keeps both popups fade only and Escape still closes them', (tester) async {
    final h = await pumpZalos(tester, size: expanded, reduceMotion: true);
    await openThreadByKey(tester, 'g01');
    final m = h.main.messages('g01', ThreadType.group).value.last;

    await _openMenu(tester, tester.getCenter(byKey('bubble-${m.id}')));
    expect(byKey('menu-MessageAction.copy'), findsOneWidget);
    expect(find.byType(ZPopupScale), findsNothing);
    await sendKey(tester, LogicalKeyboardKey.escape);
    expect(byKey('menu-MessageAction.copy'), findsNothing);

    await _openPicker(tester, m.id);
    expect(byKey('reactionPicker'), findsOneWidget);
    expect(find.byType(ZPopupScale), findsNothing);
    await sendKey(tester, LogicalKeyboardKey.escape);
    expect(byKey('reactionPicker'), findsNothing);
    await drain(tester);
  });
}
