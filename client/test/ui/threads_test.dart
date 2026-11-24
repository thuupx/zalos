import 'package:flutter/gestures.dart';
import 'package:material_ui/material_ui.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:zalos/src/domain/models.dart';
import 'package:zalos/src/ui/state/app_state.dart';
import 'package:zalos/src/ui/state/thread_ui.dart';

import '../support/fake_zalos.dart';
import '../support/harness.dart';

Thread _t(Harness h, String id) => h.main.threads.value.firstWhere((t) => t.id == id);

void main() {
  for (final entry in sizes.entries) {
    testWidgets('list states at ${entry.key}: loading, empty, populated', (tester) async {
      await pumpZalos(tester, app: FakeZalosApp(empty: true, latency: const Duration(seconds: 1)), size: entry.value);
      expect(byKey('threadsLoading'), findsOneWidget);
      await settle(tester, const Duration(seconds: 2));
      expect(byKey('threadsEmpty'), findsOneWidget);
      expect(find.text('Chưa có hội thoại'), findsOneWidget);
      expect(find.text('Tin nhắn mới sẽ xuất hiện ở đây'), findsOneWidget);
      await drain(tester);

      await pumpZalos(tester, size: entry.value);
      expect(byKey('threadList'), findsOneWidget);
      expect(find.text('Mai: Mẹ nấu canh chua rồi đó'), findsOneWidget);
      expect(find.text('[Hình ảnh]'), findsOneWidget);
      expect(find.text('[Tin nhắn thoại]'), findsOneWidget);
      expect(find.text('[Sticker]'), findsOneWidget);
      expect(find.textContaining('[File] Bao_cao'), findsOneWidget);
      await drain(tester);
    });
  }

  testWidgets('needs login banner: admin can relogin, member is told to ask', (tester) async {
    final h = await pumpZalos(tester, size: expanded);
    await tapKey(tester, 'railAccount-shop');
    expect(byKey('needsLoginBanner'), findsOneWidget);
    expect(byKey('thread-u13'), findsOneWidget);
    await tester.tap(find.text('Đăng nhập lại'));
    await settle(tester);
    expect(byKey('loginQrDialog'), findsOneWidget);
    expect(h.link.loginQrStarts, 1);
    await drain(tester);

    await pumpZalos(tester, app: FakeZalosApp(role: DeviceRole.member), prefs: {'active_slot': 'shop'});
    expect(find.textContaining('Liên hệ quản trị viên'), findsOneWidget);
    expect(find.text('Đăng nhập lại'), findsNothing);
    await drain(tester);
  });

  testWidgets('no accounts state offers adding one to admins', (tester) async {
    await pumpZalos(tester, app: FakeZalosApp(noAccounts: true));
    expect(byKey('noAccounts'), findsOneWidget);
    expect(find.text('Thêm tài khoản Zalo'), findsOneWidget);
    await drain(tester);
  });

  testWidgets('filter chips and search without diacritics with grouped results', (tester) async {
    final h = await pumpZalos(tester, size: expanded);
    await tapKey(tester, 'filter-unread');
    expect(byKey('thread-u01'), findsNothing);
    expect(byKey('thread-u02'), findsOneWidget);
    await h.main.markSeen('g01', ThreadType.group);
    await tester.pump();
    expect(byKey('thread-g01'), findsNothing);
    await tapKey(tester, 'filter-all');

    await tester.enterText(byKey('threadSearch'), 'nguyen');
    await settle(tester);
    expect(byKey('searchResults'), findsOneWidget);
    expect(find.text('HỘI THOẠI'), findsOneWidget);
    expect(find.text('DANH BẠ'), findsOneWidget);
    expect(byKey('result-thread-u01'), findsOneWidget);
    expect(byKey('result-contact-u01'), findsOneWidget);
    final rich = tester.widget<RichText>(find.descendant(of: byKey('result-thread-u01'), matching: find.byType(RichText)).first);
    expect((rich.text as TextSpan).toPlainText(), 'Nguyễn Thị Lan');
    expect(rich.text.getSpanForPosition(const TextPosition(offset: 1))!.style!.fontWeight, FontWeight.w700);

    await tester.enterText(byKey('threadSearch'), 'khongco');
    await settle(tester);
    expect(find.text('Không tìm thấy kết quả'), findsOneWidget);
    await tester.enterText(byKey('threadSearch'), 'ngoc anh');
    await settle(tester);
    await tapKey(tester, 'result-contact-u11');
    expect(h.container.read(openThreadProvider)!.id, 'u11');
    await drain(tester);
  });

  testWidgets('hover shows the row menu button; menu pins, mutes, marks, deletes', (tester) async {
    final h = await pumpZalos(tester, size: expanded);
    await hover(tester, byKey('thread-u02'));
    expect(byKey('threadMore-u02'), findsOneWidget);
    await tapKey(tester, 'threadMore-u02', scroll: false);
    expect(find.text('Ghim'), findsOneWidget);
    expect(find.text('Tắt thông báo'), findsOneWidget);
    expect(find.text('Đánh dấu đã đọc'), findsOneWidget);
    await tapKey(tester, 'menu-ThreadMenuAction.pin', scroll: false);
    expect(_t(h, 'u02').pinned, isTrue);

    await tester.tap(byKey('thread-u02'), buttons: kSecondaryButton);
    await settle(tester);
    expect(find.text('Bỏ ghim'), findsOneWidget);
    await tapKey(tester, 'menu-ThreadMenuAction.mute', scroll: false);
    expect(_t(h, 'u02').muted, isTrue);

    await tester.tap(byKey('thread-u02'), buttons: kSecondaryButton);
    await settle(tester);
    await tapKey(tester, 'menu-ThreadMenuAction.read', scroll: false);
    expect(_t(h, 'u02').unread, 0);
    await tester.tap(byKey('thread-u02'), buttons: kSecondaryButton);
    await settle(tester);
    expect(find.text('Đánh dấu chưa đọc'), findsOneWidget);
    await tapKey(tester, 'menu-ThreadMenuAction.read', scroll: false);
    expect(_t(h, 'u02').unread, 1);

    await tester.tap(byKey('thread-u02'), buttons: kSecondaryButton);
    await settle(tester);
    await tapKey(tester, 'menu-ThreadMenuAction.delete', scroll: false);
    expect(find.text('Xóa hội thoại "Trần Quốc Bảo"?'), findsOneWidget);
    await tapKey(tester, 'confirmOk', scroll: false);
    expect(byKey('thread-u02'), findsNothing);
    await drain(tester);
  });

  testWidgets('failed thread action shows a toast', (tester) async {
    final h = await pumpZalos(tester, size: expanded);
    h.app.flags.failThreadActions = true;
    await tester.tap(byKey('thread-u02'), buttons: kSecondaryButton);
    await settle(tester);
    await tapKey(tester, 'menu-ThreadMenuAction.pin', scroll: false);
    expect(byKey('toast'), findsOneWidget);
    expect(_t(h, 'u02').pinned, isFalse);
    await drain(tester);
  });

  testWidgets('touch: long press menu and swipe actions', (tester) async {
    final h = await pumpZalos(tester);
    await tester.longPress(byKey('thread-u02'));
    await settle(tester);
    expect(find.text('Xóa hội thoại'), findsOneWidget);
    await tester.tapAt(const Offset(5, 5));
    await settle(tester);

    await tester.drag(byKey('thread-u02'), const Offset(-200, 0));
    await settle(tester);
    expect(byKey('swipePin-u02'), findsOneWidget);
    await tapKey(tester, 'swipeMute-u02', scroll: false);
    expect(_t(h, 'u02').muted, isTrue);
    await tester.drag(byKey('thread-u02'), const Offset(-200, 0));
    await settle(tester);
    await tapKey(tester, 'swipePin-u02', scroll: false);
    expect(_t(h, 'u02').pinned, isTrue);
    await drain(tester);
  });

  testWidgets('draft and typing previews', (tester) async {
    final h = await pumpZalos(tester, size: expanded);
    h.container.read(threadUiProvider((slot: 'main', id: 'u02'))).input.text = 'Mai mình qua nhé';
    await tester.pump();
    final rich = find.descendant(of: byKey('thread-u02'), matching: find.textContaining('[Nháp] Mai mình qua nhé', findRichText: true));
    expect(rich, findsOneWidget);
    h.main.emitTyping('u05', 'u05');
    await settle(tester, const Duration(milliseconds: 200));
    expect(find.descendant(of: byKey('thread-u05'), matching: find.text('đang soạn tin...')), findsOneWidget);
    await settle(tester, const Duration(seconds: 7));
    expect(find.text('đang soạn tin...'), findsNothing);
    await drain(tester);
  });

  testWidgets('new chat picker opens a contact', (tester) async {
    final h = await pumpZalos(tester);
    await tapKey(tester, 'newChat');
    expect(byKey('destinationPicker'), findsOneWidget);
    await tester.enterText(byKey('destinationSearch'), 'chu van');
    await settle(tester);
    await tapKey(tester, 'destination-user/u12', scroll: false);
    expect(h.container.read(openThreadProvider)!.id, 'u12');
    expect(byKey('messagesEmpty'), findsOneWidget);
    await drain(tester);
  });

  testWidgets('account switching: rail, shortcut, phone sheet with remembered slot', (tester) async {
    final h = await pumpZalos(tester, size: expanded);
    await tapKey(tester, 'railAccount-shop');
    expect(byKey('thread-u01'), findsNothing);
    await sendKey(tester, LogicalKeyboardKey.digit1, control: true);
    expect(byKey('thread-u01'), findsOneWidget);
    await sendKey(tester, LogicalKeyboardKey.digit2, control: true);
    expect(h.container.read(preferredSlotProvider), 'shop');
    await drain(tester);

    await pumpZalos(tester);
    await tapKey(tester, 'accountAvatar');
    expect(byKey('accountSheet'), findsOneWidget);
    await tapKey(tester, 'sheetAccount-shop', scroll: false);
    expect(byKey('accountSheet'), findsNothing);
    expect(byKey('thread-u13'), findsOneWidget);
    await drain(tester);
    await pumpZalos(tester, prefs: {'active_slot': 'shop'});
    expect(byKey('thread-u13'), findsOneWidget);
    await drain(tester);
  });

  testWidgets('keyboard: Ctrl+K focuses search, arrows move, Enter opens, Esc clears', (tester) async {
    final h = await pumpZalos(tester, size: expanded);
    await sendKey(tester, LogicalKeyboardKey.keyK, control: true);
    expect(FocusManager.instance.primaryFocus?.debugLabel, 'threadSearch');
    await sendKey(tester, LogicalKeyboardKey.tab);
    await sendKey(tester, LogicalKeyboardKey.tab);
    await sendKey(tester, LogicalKeyboardKey.tab);
    await sendKey(tester, LogicalKeyboardKey.tab);
    await sendKey(tester, LogicalKeyboardKey.arrowDown);
    await sendKey(tester, LogicalKeyboardKey.enter);
    expect(h.container.read(openThreadProvider), isNotNull);
    await tapKey(tester, 'chatInfo');
    expect(h.container.read(infoPaneOpenProvider), isTrue);
    FocusManager.instance.primaryFocus?.unfocus();
    await tester.pump();
    await sendKey(tester, LogicalKeyboardKey.escape);
    expect(h.container.read(infoPaneOpenProvider), isFalse);
    await sendKey(tester, LogicalKeyboardKey.escape);
    expect(h.container.read(openThreadProvider), isNull);
    await drain(tester);
  });

  testWidgets('layout switches live and keeps the open thread and scroll position', (tester) async {
    final h = await pumpZalos(tester, size: expanded);
    await openThreadByKey(tester, 'u01');
    await tester.drag(byKey('messageList'), const Offset(0, 900));
    await settle(tester);
    final before = tester.state<ScrollableState>(find.descendant(of: byKey('messageList'), matching: find.byType(Scrollable)).first).position.pixels;
    expect(before, greaterThan(500));
    final stateBefore = tester.state(find.byType(Scrollable).last);
    expect(stateBefore, isNotNull);

    tester.view.physicalSize = compact;
    await settle(tester);
    expect(byKey('compactShell'), findsOneWidget);
    expect(byKey('messageList'), findsOneWidget);
    expect(h.container.read(openThreadProvider)!.id, 'u01');
    final after = tester.state<ScrollableState>(find.descendant(of: byKey('messageList'), matching: find.byType(Scrollable)).first).position.pixels;
    expect(after, greaterThan(300));

    tester.view.physicalSize = medium;
    await settle(tester);
    expect(byKey('wideShell'), findsOneWidget);
    expect(byKey('messageList'), findsOneWidget);
    await drain(tester);
  });
}
