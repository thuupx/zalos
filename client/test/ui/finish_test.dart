import 'dart:async';

import 'package:material_ui/material_ui.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:zalos/src/domain/models.dart';
import 'package:zalos/src/ui/platform/services.dart';

import '../support/fake_platform.dart';
import '../support/fake_zalos.dart';
import '../support/harness.dart';

/// [node]'s rect with vertical scrolling undone, so stops inside a list that
/// scrolls to reveal them keep their place in the list's content.
Rect contentRect(FocusNode node) {
  var rect = node.rect;
  for (var s = Scrollable.maybeOf(node.context!); s != null; s = Scrollable.maybeOf(s.context)) {
    final pixels = s.position.pixels;
    rect = switch (s.axisDirection) {
      AxisDirection.down => rect.shift(Offset(0, pixels)),
      AxisDirection.up => rect.shift(Offset(0, -pixels)),
      AxisDirection.left || AxisDirection.right => rect,
    };
  }
  return rect;
}

/// Tabs through the screen and returns the content rect of every focus stop
/// until focus returns to the first one.
Future<List<Rect>> tabStops(WidgetTester tester, {int max = 80}) async {
  final stops = <Rect>[];
  FocusNode? first;
  for (var i = 0; i < max; i++) {
    await tester.sendKeyEvent(LogicalKeyboardKey.tab);
    await tester.pump(const Duration(milliseconds: 20));
    final node = FocusManager.instance.primaryFocus;
    if (node == null || node.context == null) continue;
    if (identical(node, first)) return stops;
    first ??= node;
    stops.add(contentRect(node));
  }
  return stops;
}

/// Visual order on wide layouts: panes left to right, inside a pane top to
/// bottom, inside a line left to right.
void expectVisualOrder(List<Rect> stops, List<double> paneEdges, {required String reason, int minStops = 4}) {
  int pane(Rect r) => paneEdges.where((e) => r.center.dx >= e).length;
  expect(stops.length, greaterThanOrEqualTo(minStops), reason: reason);
  for (var i = 1; i < stops.length; i++) {
    final a = stops[i - 1];
    final b = stops[i];
    final pa = pane(a);
    final pb = pane(b);
    final ok = pb > pa || (pb == pa && (b.center.dy > a.center.dy + 6 || ((b.center.dy - a.center.dy).abs() <= 24 && b.center.dx >= a.center.dx - 1)));
    expect(ok, isTrue, reason: '$reason: stop $i at $b comes after $a');
  }
}

void main() {
  testWidgets('tab order follows visual order: shell with chat and info pane', (tester) async {
    await pumpZalos(tester, size: expanded);
    await openThreadByKey(tester, 'u02');
    await tapKey(tester, 'chatInfo');
    FocusManager.instance.primaryFocus?.unfocus();
    await tester.pump();
    expectVisualOrder(await tabStops(tester), [64, 408, 1096], reason: 'shell');
    await drain(tester);
  });

  testWidgets('tab order follows visual order: contacts and me', (tester) async {
    await pumpZalos(tester, size: expanded);
    for (final tab in ['contacts', 'me']) {
      await tapKey(tester, 'railTab-$tab');
      FocusManager.instance.primaryFocus?.unfocus();
      await tester.pump();
      expectVisualOrder(await tabStops(tester), [64, 408], reason: tab);
    }
    await drain(tester);
  });

  testWidgets('tab order follows visual order: pairing and vault waiting', (tester) async {
    await pumpZalos(tester, size: expanded, app: FakeZalosApp(paired: false));
    expectVisualOrder(await tabStops(tester), const [], reason: 'pairing');
    await drain(tester);
    await pumpZalos(tester, size: expanded, app: FakeZalosApp(vaultPending: true));
    // UI.md 3.9: resend, enter recovery code and unpair are its only actions.
    expectVisualOrder(await tabStops(tester), const [], reason: 'vault', minStops: 3);
    await drain(tester);
  });

  testWidgets('tab order follows visual order: devices and add device dialog', (tester) async {
    await pumpZalos(tester, size: expanded);
    await tapKey(tester, 'railTab-me');
    await tapKey(tester, 'linkedDevices');
    FocusManager.instance.primaryFocus?.unfocus();
    await tester.pump();
    expectVisualOrder(await tabStops(tester), [64, 408], reason: 'devices');
    await drain(tester);
  });

  testWidgets('quote far away: loads older pages with progress, then jumps and highlights', (tester) async {
    final h = await pumpZalos(tester, size: expanded, app: FakeZalosApp(latency: const Duration(milliseconds: 100)));
    final oldest = h.main.history('u01').first;
    // The fake send waits [latency] on the fake clock, so the pumps below
    // complete it; awaiting it here would block the test forever.
    unawaited(h.main.sendText('u01', ThreadType.user, 'trả lời tin rất cũ', quote: oldest));
    await settle(tester);
    await openThreadByKey(tester, 'u01');
    await settle(tester, const Duration(seconds: 1));
    final reply = h.main.messages('u01', ThreadType.user).value.last;
    expect(h.main.messages('u01', ThreadType.user).value.any((m) => m.id == oldest.id), isFalse);
    await tester.tap(byKey('quote-${reply.id}'));
    await tester.pump(const Duration(milliseconds: 50));
    expect(byKey('seekingOlder'), findsOneWidget);
    // The highlight is brief, so stop pumping as soon as it shows.
    for (var waited = 0; waited < 3000 && byKey('highlight-${oldest.id}').evaluate().isEmpty; waited += 50) {
      await tester.pump(const Duration(milliseconds: 50));
    }
    expect(byKey('seekingOlder'), findsNothing);
    expect(byKey('highlight-${oldest.id}'), findsOneWidget);
    await drain(tester);
  });

  testWidgets('far jump lands in a few frames in a 5,000 message thread', (tester) async {
    final h = await pumpZalos(tester, size: expanded, app: FakeZalosApp(large: true));
    await openThreadByKey(tester, 'u01');
    final msgs = h.main.messages('u01', ThreadType.user).value;
    final target = msgs[msgs.length - 3000];
    await h.main.sendText('u01', ThreadType.user, 'nhảy xa', quote: target);
    await settle(tester);
    final reply = h.main.messages('u01', ThreadType.user).value.last;
    await tester.tap(byKey('quote-${reply.id}'));
    var frames = 0;
    while (byKey('highlight-${target.id}').evaluate().isEmpty && frames < 40) {
      await tester.pump(const Duration(milliseconds: 16));
      frames++;
    }
    expect(byKey('highlight-${target.id}'), findsOneWidget);
    expect(frames, lessThan(40));
    await drain(tester);
  });

  testWidgets('sticky day pill appears while scrolling and hides at rest', (tester) async {
    await pumpZalos(tester, size: expanded);
    await openThreadByKey(tester, 'u01');
    expect(byKey('stickyDay'), findsNothing);
    await tester.drag(byKey('messageList'), const Offset(0, 900));
    await tester.pump(const Duration(milliseconds: 100));
    expect(byKey('stickyDay'), findsOneWidget);
    await tester.pump(const Duration(seconds: 2));
    expect(byKey('stickyDay'), findsNothing);
    await drain(tester);
  });

  testWidgets('voice bubble: draggable position seeks the player', (tester) async {
    final platform = FakePlatform();
    final h = await pumpZalos(tester, size: const Size(1440, 2600), platform: platform);
    await openThreadByKey(tester, 'g01');
    final voice = h.main.messages('g01', ThreadType.group).value.firstWhere((m) => m.kind == MessageKind.voice);
    expect(tester.widget<Slider>(byKey('voiceSeek-${voice.id}')).onChanged, isNull);
    await tapKey(tester, 'voicePlay-${voice.id}', scroll: false);
    platform.players.single.set(const PlaybackStatus(playing: true, position: Duration(seconds: 3), duration: Duration(seconds: 12), ready: true));
    await tester.pump();
    final box = tester.getRect(byKey('voiceSeek-${voice.id}'));
    await tester.tapAt(Offset(box.left + box.width * 0.75, box.center.dy));
    await tester.pump();
    expect(platform.players.single.status.value.position.inSeconds, inInclusiveRange(8, 10));
    await drain(tester);
  });

  testWidgets('file download can be cancelled: nothing is saved', (tester) async {
    final platform = FakePlatform();
    await pumpZalos(tester, size: const Size(1440, 2600), platform: platform, app: FakeZalosApp(latency: const Duration(milliseconds: 300)));
    await openThreadByKey(tester, 'g01');
    await settle(tester, const Duration(seconds: 2));
    await tester.tap(byKey('fileDownload-fake://file/lich'));
    await tester.pump(const Duration(milliseconds: 50));
    await tester.tap(byKey('fileCancel-fake://file/lich'));
    await settle(tester, const Duration(seconds: 1));
    expect(platform.saved, isEmpty);
    expect(byKey('fileDownload-fake://file/lich'), findsOneWidget);
    await drain(tester);
  });

  testWidgets('mention picker floats above the input on wide layouts', (tester) async {
    await pumpZalos(tester, size: expanded);
    await openThreadByKey(tester, 'g01');
    await tester.enterText(byKey('composerField'), '@');
    await settle(tester);
    final list = tester.getRect(byKey('mentionList'));
    expect(list.width, 300);
    expect(list.bottom, lessThanOrEqualTo(tester.getRect(byKey('composerField')).top));
    await drain(tester);
  });

  testWidgets('notification permission is requested by the Me toggle only', (tester) async {
    final platform = FakePlatform();
    final h = await pumpZalos(tester, size: expanded, platform: platform, prefs: {'notify_enabled': 'off'});
    h.main.receive('u05', 'tin mới');
    await settle(tester);
    expect(platform.notifications.permissionRequests, 0);
    await tapKey(tester, 'railTab-me');
    await revealIn(tester, 'meList', 'notifyEnabled');
    await tapKey(tester, 'notifyEnabled');
    expect(platform.notifications.permissionRequests, 1);
    await drain(tester);
  });
}
