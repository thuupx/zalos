import 'package:flutter/gestures.dart';
import 'package:material_ui/material_ui.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:zalos/src/domain/models.dart';
import 'package:zalos/src/ui/components/overlays.dart';

import '../support/harness.dart';

/// Puts a mouse pointer on [at], as a real pointer move would.
Future<TestGesture> _mouseAt(WidgetTester tester, Offset at) async {
  final mouse = await tester.createGesture(kind: PointerDeviceKind.mouse);
  await mouse.addPointer(location: Offset.zero);
  await tester.pump();
  await mouse.moveTo(at);
  await tester.pump();
  await tester.pump(const Duration(milliseconds: 200));
  return mouse;
}

Future<void> _moveTo(WidgetTester tester, TestGesture mouse, Offset at) async {
  await mouse.moveTo(at);
  await tester.pump();
  await tester.pump(const Duration(milliseconds: 100));
}

/// Opens the wide picker over the last group message and returns the pointer
/// plus the anchor (hover react button) rect, captured while the bar is shown.
Future<(TestGesture, Rect)> _openPicker(WidgetTester tester, Harness h) async {
  final m = h.main.messages('g01', ThreadType.group).value.last;
  final mouse = await _mouseAt(tester, tester.getCenter(byKey('bubble-${m.id}')));
  addTearDown(mouse.removePointer);
  expect(byKey('hoverReact-${m.id}'), findsOneWidget);
  final anchor = tester.getRect(byKey('hoverReact-${m.id}'));
  await tester.tap(byKey('hoverReact-${m.id}'));
  await settle(tester);
  expect(byKey('reactionPicker'), findsOneWidget);
  return (mouse, anchor);
}

void main() {
  testWidgets('the picker survives the gap above the anchor and still closes outside it', (tester) async {
    final h = await pumpZalos(tester, size: expanded);
    await openThreadByKey(tester, 'g01');
    final (mouse, anchor) = await _openPicker(tester, h);
    final pill = tester.getRect(byKey('reactionPicker'));
    expect(pill.bottom, lessThan(anchor.top), reason: 'the pill floats above the anchor');
    expect(anchor.top - pill.bottom, lessThanOrEqualTo(4), reason: 'the gap is a few pixels');

    await _moveTo(tester, mouse, pill.center);
    expect(byKey('reactionPicker'), findsOneWidget);

    // Down through the gap above the anchor, and a small jitter, keeps it open.
    final gap = Offset(pill.center.dx, pill.bottom + 1);
    expect(gap.dy, lessThan(anchor.top));
    await _moveTo(tester, mouse, gap);
    expect(byKey('reactionPicker'), findsOneWidget);
    await _moveTo(tester, mouse, gap + const Offset(3, 0));
    expect(byKey('reactionPicker'), findsOneWidget);
    await _moveTo(tester, mouse, pill.center);
    expect(byKey('reactionPicker'), findsOneWidget);

    // Truly outside the picker it dismisses.
    await _moveTo(tester, mouse, const Offset(2, 2));
    await settle(tester);
    expect(byKey('reactionPicker'), findsNothing);
    await drain(tester);
  });

  testWidgets('Escape closes the picker immediately', (tester) async {
    final h = await pumpZalos(tester, size: expanded);
    await openThreadByKey(tester, 'g01');
    final (mouse, _) = await _openPicker(tester, h);
    await _moveTo(tester, mouse, tester.getCenter(byKey('reactionPicker')));
    await sendKey(tester, LogicalKeyboardKey.escape);
    expect(byKey('reactionPicker'), findsNothing);
    await drain(tester);
  });

  testWidgets('reduced motion still bridges the gap and leaves the picker fade only', (tester) async {
    final h = await pumpZalos(tester, size: expanded, reduceMotion: true);
    await openThreadByKey(tester, 'g01');
    final (mouse, anchor) = await _openPicker(tester, h);
    expect(find.byType(ZPopupScale), findsNothing);
    final pill = tester.getRect(byKey('reactionPicker'));

    await _moveTo(tester, mouse, pill.center);
    final gap = Offset(pill.center.dx, pill.bottom + 1);
    expect(gap.dy, lessThan(anchor.top));
    await _moveTo(tester, mouse, gap);
    expect(byKey('reactionPicker'), findsOneWidget);

    await _moveTo(tester, mouse, const Offset(2, 2));
    await settle(tester);
    expect(byKey('reactionPicker'), findsNothing);
    await drain(tester);
  });

  testWidgets('disposing while the pointer is in the gap leaves no ticker or timer behind', (tester) async {
    final h = await pumpZalos(tester, size: expanded);
    await openThreadByKey(tester, 'g01');
    final (mouse, _) = await _openPicker(tester, h);
    final pill = tester.getRect(byKey('reactionPicker'));
    await _moveTo(tester, mouse, Offset(pill.center.dx, pill.bottom + 1));
    await tester.pump(const Duration(milliseconds: 30));
    await tester.pumpWidget(const SizedBox());
    expect(tester.takeException(), isNull);
    expect(tester.binding.transientCallbackCount, 0);
    await drain(tester);
  });
}
