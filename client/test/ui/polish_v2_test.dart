import 'package:flutter_test/flutter_test.dart';
import 'package:material_ui/material_ui.dart';
import 'package:zalos/src/domain/models.dart';
import 'package:zalos/src/ui/qr/zalo_qr_scanner.dart';
import 'package:zalos/src/ui/state/app_state.dart';
import 'package:zalos/src/ui/util/haptics.dart';

import '../support/fake_platform.dart';
import '../support/harness.dart';

void main() {
  testWidgets('swipe-back slides continuously from drag position without flashing back to x=0', (tester) async {
    await pumpZalos(tester, size: compact);
    await openThreadByKey(tester, 'g01');
    await settle(tester);

    final chatFinder = byKey('messageList');
    expect(chatFinder, findsOneWidget);
    final startLeft = tester.getTopLeft(chatFinder).dx;
    expect(startLeft, moreOrLessEquals(0, epsilon: 1));

    // Drag right from the left edge past the 30% pop threshold.
    final gesture = await tester.startGesture(const Offset(10, 300));
    await gesture.moveBy(const Offset(40, 0));
    await tester.pump();
    await gesture.moveBy(const Offset(140, 0));
    await tester.pump();

    final draggedLeft = tester.getTopLeft(chatFinder).dx;
    expect(draggedLeft, greaterThan(100));

    // Release: on the very next frame and throughout the exit animation,
    // the chat pane must NEVER snap back toward x = 0.
    await gesture.up();
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 16));
    if (chatFinder.evaluate().isNotEmpty) {
      expect(
        tester.getTopLeft(chatFinder).dx,
        greaterThanOrEqualTo(draggedLeft - 1),
        reason: 'swipe-back must not snap back to x=0 on release',
      );
    }
    await tester.pump(const Duration(milliseconds: 40));
    if (chatFinder.evaluate().isNotEmpty) {
      expect(
        tester.getTopLeft(chatFinder).dx,
        greaterThan(draggedLeft),
        reason: 'swipe-back must keep gliding right off-screen',
      );
    }

    await settle(tester);
    expect(chatFinder, findsNothing);
    await drain(tester);
  });

  testWidgets('haptics toggle in Me updates hapticsEnabledProvider and ZHaptics.enabled', (tester) async {
    final h = await pumpZalos(tester, size: compact);
    expect(h.container.read(hapticsEnabledProvider), isTrue);
    expect(ZHaptics.enabled, isTrue);

    await tapKey(tester, 'tab-me');
    await revealIn(tester, 'meList', 'hapticsEnabled');
    await tapKey(tester, 'hapticsEnabled');
    await settle(tester);

    expect(h.container.read(hapticsEnabledProvider), isFalse);
    expect(ZHaptics.enabled, isFalse);

    await tapKey(tester, 'hapticsEnabled');
    await settle(tester);

    expect(h.container.read(hapticsEnabledProvider), isTrue);
    expect(ZHaptics.enabled, isTrue);
    await drain(tester);
  });

  testWidgets('long-pressing a message opens menu with staggered reaction icons', (tester) async {
    final h = await pumpZalos(tester, size: compact);
    await openThreadByKey(tester, 'g01');
    final m = h.main.messages('g01', ThreadType.group).value.last;

    await tester.longPress(byKey('bubble-${m.id}'));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 40));
    expect(byKey('react-/-heart'), findsOneWidget);
    expect(byKey('menu-MessageAction.reply'), findsOneWidget);

    await settle(tester);
    await tester.tapAt(const Offset(5, 5));
    await settle(tester);
    await drain(tester);
  });

  testWidgets('floating bottom nav keeps compact height and passes touch targets', (tester) async {
    await pumpZalos(tester, size: compact);
    final navSize = tester.getSize(byKey('bottomNav'));
    expect(navSize.height, 52);
    expect(navSize.width, lessThan(compact.width));
    await drain(tester);
  });

  testWidgets('tapping a message bubble does not trigger hold scale animation', (tester) async {
    final h = await pumpZalos(tester, size: compact);
    await openThreadByKey(tester, 'g01');
    final m = h.main.messages('g01', ThreadType.group).value.last;
    final bubble = byKey('bubble-${m.id}');

    final gesture = await tester.startGesture(tester.getCenter(bubble));
    await tester.pump(const Duration(milliseconds: 50));
    final scales = tester
        .widgetList<AnimatedScale>(
            find.ancestor(of: bubble, matching: find.byType(AnimatedScale)))
        .map((w) => w.scale)
        .toList();
    expect(scales, everyElement(1.0));
    await gesture.up();
    await settle(tester);
    await drain(tester);
  });

  testWidgets('sticker picker renders Zalo category tabs and loads stickers without empty query', (tester) async {
    await pumpZalos(tester, size: compact);
    await openThreadByKey(tester, 'u02');
    await tapKey(tester, 'stickerButton', scroll: false);
    await tester.tap(find.descendant(of: byKey('pickerPanel'), matching: find.text('Sticker')));
    await settle(tester);

    expect(byKey('stickerCategories'), findsOneWidget);
    expect(byKey('stickerCat-popular'), findsOneWidget);
    expect(byKey('stickerGrid'), findsOneWidget);

    await tapKey(tester, 'stickerCat-love', scroll: false);
    await settle(tester);
    expect(byKey('stickerGrid'), findsOneWidget);
    await drain(tester);
  });

  test('parseZaloQr classifies phone, username, group link, and generic URLs', () {
    expect(parseZaloQr('https://zalo.me/0912345678').kind, ZaloQrKind.userPhone);
    expect(parseZaloQr('https://zalo.me/minhthu').kind, ZaloQrKind.userUsername);
    expect(parseZaloQr('https://zalo.me/g/abc123').kind, ZaloQrKind.groupLink);
    expect(parseZaloQr('https://zaloapp.com/qr/p/xyz').kind, ZaloQrKind.zaloLink);
    expect(parseZaloQr('https://example.com/test').kind, ZaloQrKind.url);
    expect(parseZaloQr('hello world').kind, ZaloQrKind.text);
  });

  testWidgets('header QR button opens Zalo QR scanner and shows scanned result', (tester) async {
    final platform = FakePlatform();
    await pumpZalos(tester, size: compact, platform: platform);
    expect(byKey('headerScanQr'), findsOneWidget);

    await tapKey(tester, 'headerScanQr', scroll: false);
    expect(byKey('zaloQrScannerScreen'), findsOneWidget);

    platform.scannerOnCode!('https://zalo.me/g/demo123');
    await settle(tester);
    expect(byKey('zaloQrResultSheet'), findsOneWidget);
    expect(byKey('qrOpenLink'), findsOneWidget);
    await drain(tester);
  });
}
