import 'package:flutter/gestures.dart';
import 'package:material_ui/material_ui.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:zalos/src/domain/services.dart';
import 'package:zalos/src/ui/app.dart';
import 'package:zalos/src/ui/platform/services.dart';
import 'package:zalos/src/ui/state/app_state.dart';
import 'package:zalos/src/ui/util/format.dart';

import 'fake_platform.dart';
import 'fake_zalos.dart';

const compact = Size(390, 844);
const medium = Size(900, 700);
const expanded = Size(1440, 900);
const sizes = <String, Size>{'compact': compact, 'medium': medium, 'expanded': expanded};

SemanticsHandle? _semantics;
TestGesture? _mouse;

class Harness {
  Harness(this.app, this.platform, this.container);
  final FakeZalosApp app;
  final FakePlatform platform;
  final ProviderContainer container;

  FakeServerLink get link => app.fakeLink;
  FakeSession get main => link.session('main');
}

Future<Harness> pumpZalos(
  WidgetTester tester, {
  FakeZalosApp? app,
  FakePlatform? platform,
  Size size = compact,
  bool dark = false,
  double textScale = 1,
  Map<String, Object> prefs = const {},
  bool reduceMotion = false,
}) async {
  tester.view.physicalSize = size;
  tester.view.devicePixelRatio = 1;
  tester.platformDispatcher.textScaleFactorTestValue = textScale;
  if (reduceMotion) tester.platformDispatcher.accessibilityFeaturesTestValue = const FakeAccessibilityFeatures(disableAnimations: true);
  addTearDown(() {
    tester.view.reset();
    tester.platformDispatcher.clearAllTestValues();
  });
  _semantics?.dispose();
  _semantics = tester.ensureSemantics();
  _mouse = null;
  ZClock.source = () => fakeNow;
  addTearDown(() => ZClock.source = DateTime.now);
  SharedPreferences.setMockInitialValues({'language': 'vi', 'theme_mode': dark ? 'dark' : 'light', 'notify_enabled': 'on', ...prefs});
  final sp = await SharedPreferences.getInstance();
  final fake = app ?? FakeZalosApp();
  final fakePlatform = platform ?? FakePlatform();
  addTearDown(fake.dispose);
  final container = ProviderContainer(overrides: [
    zalosAppProvider.overrideWithValue(fake),
    sharedPrefsProvider.overrideWithValue(sp),
    platformProvider.overrideWithValue(fakePlatform),
  ]);
  addTearDown(container.dispose);
  await tester.pumpWidget(
    RepaintBoundary(key: const Key('appRoot'), child: UncontrolledProviderScope(container: container, child: const ZalosRoot())),
  );
  await tester.pump();
  await tester.pump(const Duration(milliseconds: 50));
  return Harness(fake, fakePlatform, container);
}

/// Advances fake time in steps so chained timers, futures and animations run.
Future<void> settle(WidgetTester tester, [Duration total = const Duration(milliseconds: 600)]) async {
  const step = Duration(milliseconds: 50);
  for (var elapsed = Duration.zero; elapsed < total; elapsed += step) {
    await tester.pump(step);
  }
}

/// Lets toasts, typing expiry and other timers finish before teardown.
Future<void> drain(WidgetTester tester) async {
  await _mouse?.removePointer();
  _mouse = null;
  await tester.pumpWidget(const SizedBox());
  _semantics?.dispose();
  _semantics = null;
  await tester.pump(const Duration(seconds: 8));
}

Finder byKey(String key) => find.byKey(Key(key));

Future<void> tapKey(WidgetTester tester, String key, {bool scroll = true}) async {
  final finder = byKey(key);
  if (scroll) {
    await tester.ensureVisible(finder);
    await tester.pump();
  }
  await tester.tap(finder);
  await settle(tester);
}

Future<void> openThreadByKey(WidgetTester tester, String id) async {
  final finder = byKey('thread-$id');
  await tester.ensureVisible(finder);
  await tester.pump();
  await tester.tap(finder);
  await settle(tester);
}

Future<void> hover(WidgetTester tester, Finder finder) async {
  var gesture = _mouse;
  if (gesture == null) {
    gesture = await tester.createGesture(kind: PointerDeviceKind.mouse);
    await gesture.addPointer(location: Offset.zero);
    _mouse = gesture;
  }
  await gesture.moveTo(tester.getCenter(finder));
  await tester.pump();
  await tester.pump(const Duration(milliseconds: 200));
}

Future<void> sendKey(WidgetTester tester, LogicalKeyboardKey key, {bool control = false, bool shift = false}) async {
  if (control) await tester.sendKeyDownEvent(LogicalKeyboardKey.controlLeft);
  if (shift) await tester.sendKeyDownEvent(LogicalKeyboardKey.shiftLeft);
  await tester.sendKeyEvent(key);
  if (shift) await tester.sendKeyUpEvent(LogicalKeyboardKey.shiftLeft);
  if (control) await tester.sendKeyUpEvent(LogicalKeyboardKey.controlLeft);
  await settle(tester, const Duration(milliseconds: 300));
}

/// Scrolls the lazily built list [listKey] until [key] exists and is visible.
Future<void> revealIn(WidgetTester tester, String listKey, String key) async {
  final scrollable = find.descendant(of: byKey(listKey), matching: find.byType(Scrollable)).first;
  await tester.scrollUntilVisible(byKey(key), 200, scrollable: scrollable);
  await tester.pump();
}

abstract final class ZClockAccess {
  static void set(DateTime Function() source) => ZClock.source = source;
}
