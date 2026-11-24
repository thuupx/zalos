import 'package:flutter/gestures.dart';
import 'package:material_ui/material_ui.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:zalos/src/domain/models.dart';
import 'package:zalos/src/domain/services.dart';
import 'package:zalos/src/ui/pairing/pairing_screen.dart';
import 'package:zalos/src/ui/l10n/strings.dart';
import 'package:zalos/src/ui/state/app_state.dart';

import '../support/fake_platform.dart';
import '../support/fake_zalos.dart';
import '../support/harness.dart';

const _gated = ['stickerButton', 'voiceButton', 'infoMute', 'infoPin', 'infoDelete'];

void main() {
  testWidgets('OA account hides every gated control; personal account shows them', (tester) async {
    final h = await pumpZalos(tester, size: expanded, app: FakeZalosApp(withOa: true));
    expect(byKey('oaTag-oa'), findsOneWidget);
    expect(byKey('oaTag-main'), findsNothing);

    await openThreadByKey(tester, 'g01');
    await tapKey(tester, 'chatInfo');
    for (final k in _gated.where((k) => k != 'infoDelete')) {
      expect(byKey(k), findsOneWidget, reason: k);
    }
    await revealIn(tester, 'infoPane', 'infoDelete');
    expect(byKey('infoDelete'), findsOneWidget);
    final own = h.main.messages('g01', ThreadType.group).value.lastWhere((m) => m.isSelf);
    await tester.tap(byKey('bubble-${own.id}'), buttons: kSecondaryButton);
    await settle(tester);
    for (final k in ['menu-MessageAction.forward', 'menu-MessageAction.recall', 'menu-MessageAction.delete', 'react-/-heart']) {
      expect(byKey(k), findsOneWidget, reason: k);
    }
    await tester.tapAt(const Offset(5, 5));
    await settle(tester);
    expect(find.text('Đã xem'), findsOneWidget);
    await tester.tap(byKey('thread-u02'), buttons: kSecondaryButton);
    await settle(tester);
    expect(byKey('menu-ThreadMenuAction.pin'), findsOneWidget);
    await tester.tapAt(const Offset(5, 5));
    await settle(tester);

    await tapKey(tester, 'railAccount-oa');
    final oa = h.link.session('oa');
    await openThreadByKey(tester, 'u06');
    await tapKey(tester, 'chatInfo');
    for (final k in _gated) {
      expect(byKey(k), findsNothing, reason: k);
    }
    expect(byKey('attachImageButton'), findsOneWidget);
    expect(byKey('attachFileButton'), findsOneWidget);
    expect(find.text('Đã xem'), findsNothing);
    final mine = oa.messages('u06', ThreadType.user).value.firstWhere((m) => m.isSelf);
    await hover(tester, byKey('bubble-${mine.id}'));
    expect(byKey('hoverReact-${mine.id}'), findsNothing);
    expect(byKey('reactButton-${mine.id}'), findsNothing);
    expect(byKey('hoverReply-${mine.id}'), findsOneWidget);
    await tester.tap(byKey('bubble-${mine.id}'), buttons: kSecondaryButton);
    await settle(tester);
    expect(byKey('menu-MessageAction.reply'), findsOneWidget);
    for (final k in ['menu-MessageAction.forward', 'menu-MessageAction.recall', 'menu-MessageAction.delete', 'react-/-heart']) {
      expect(byKey(k), findsNothing, reason: k);
    }
    await tester.tapAt(const Offset(5, 5));
    await settle(tester);
    await tester.tap(byKey('thread-u09'), buttons: kSecondaryButton);
    await settle(tester);
    expect(byKey('menu-ThreadMenuAction.pin'), findsNothing);
    expect(byKey('menu-ThreadMenuAction.delete'), findsNothing);
    await hover(tester, byKey('thread-u09'));
    expect(byKey('threadMore-u09'), findsNothing);
    await tester.enterText(byKey('composerField'), 'Dạ shop gửi @');
    await settle(tester);
    expect(byKey('mentionList'), findsNothing);
    expect(oa.typingSent, 0);
    await tapKey(tester, 'emojiButton', scroll: false);
    expect(find.descendant(of: byKey('pickerPanel'), matching: find.text('Sticker')), findsNothing);
    await tester.tapAt(const Offset(700, 300));
    await settle(tester);

    await tapKey(tester, 'railTab-contacts');
    expect(find.textContaining('Nhóm'), findsNothing);
    await tapKey(tester, 'railAccount-main');
    expect(find.textContaining('Nhóm ('), findsOneWidget);
    await drain(tester);
  });

  testWidgets('OA send errors: window_expired has no retry, others offer it', (tester) async {
    final h = await pumpZalos(tester, size: expanded, app: FakeZalosApp(withOa: true), prefs: {'active_slot': 'oa'});
    final oa = h.link.session('oa');
    await openThreadByKey(tester, 'u09');
    oa.sendErrorCode = 'window_expired';
    await tester.enterText(byKey('composerField'), 'Shop báo giá ạ');
    await tester.pump();
    await tapKey(tester, 'sendButton', scroll: false);
    final failed = oa.messages('u09', ThreadType.user).value.last;
    expect(failed.sendState, SendState.failed);
    expect(find.text('Người dùng chưa tương tác trong 7 ngày nên OA không thể gửi tin'), findsOneWidget);
    await tester.tap(byKey('retry-${failed.id}'));
    await settle(tester);
    expect(oa.resent, isEmpty);

    oa.sendErrorCode = 'quota_exceeded';
    await tester.enterText(byKey('composerField'), 'Lần nữa');
    await tester.pump();
    await tapKey(tester, 'sendButton', scroll: false);
    expect(find.textContaining('hết hạn mức').first, findsOneWidget);
    oa.sendErrorCode = null;
    final second = oa.messages('u09', ThreadType.user).value.last;
    await tester.tap(byKey('retry-${second.id}'));
    await settle(tester);
    expect(oa.resent, [second.id]);
    await drain(tester);
  });

  testWidgets('add account chooser, OA form validation, reveal, error, success; update tokens', (tester) async {
    final platform = FakePlatform();
    final h = await pumpZalos(tester, size: expanded, platform: platform, app: FakeZalosApp(latency: const Duration(milliseconds: 200)));
    await tapKey(tester, 'railTab-me');
    await tapKey(tester, 'addZaloAccount');
    expect(byKey('addAccountChooser'), findsOneWidget);
    await tapKey(tester, 'addOa', scroll: false);
    expect(byKey('oaDialog'), findsOneWidget);
    await tapKey(tester, 'oaSubmit', scroll: false);
    expect(find.text('Hãy điền đủ các trường'), findsNWidgets(4));
    await tapKey(tester, 'oaDocs', scroll: false);
    expect(platform.openedUrls.single, contains('developers.zalo.me'));
    TextField field(String id) => tester.widget<TextField>(find.descendant(of: byKey('oa-$id'), matching: find.byType(TextField)));
    expect(field('secret').obscureText, isTrue);
    expect(field('appId').obscureText, isFalse);
    await tapKey(tester, 'oaReveal-secret', scroll: false);
    expect(field('secret').obscureText, isFalse);
    await tester.enterText(byKey('oa-appId'), '1234567890');
    await tester.enterText(byKey('oa-secret'), 'bi-mat');
    await tester.enterText(byKey('oa-access'), 'access-1');
    await tester.enterText(byKey('oa-refresh'), 'refresh-1');
    h.link.oaError = 'invalid_token: Access token không hợp lệ';
    await tester.tap(byKey('oaSubmit'));
    await tester.pump(const Duration(milliseconds: 50));
    await settle(tester);
    expect(byKey('oaError'), findsOneWidget);
    expect(find.textContaining('Access token không hợp lệ'), findsOneWidget);
    h.link.oaError = null;
    await tapKey(tester, 'oaSubmit', scroll: false);
    expect(byKey('oaDialog'), findsNothing);
    expect(h.link.oaAdded.single.appId, '1234567890');
    final slot = h.link.manifest.value!.accounts.last.slot;
    expect(h.container.read(preferredSlotProvider), slot);

    h.link.setStatus(slot, AccountStatus.needsLogin);
    await settle(tester);
    expect(find.text('Cập nhật token'), findsOneWidget);
    await tester.tap(find.text('Cập nhật token'));
    await settle(tester);
    expect(byKey('oa-appId'), findsNothing);
    await tester.enterText(byKey('oa-access'), 'access-2');
    await tester.enterText(byKey('oa-refresh'), 'refresh-2');
    await tapKey(tester, 'oaSubmit', scroll: false);
    expect(h.link.oaTokenUpdates.single.accessToken, 'access-2');
    expect(byKey('needsLoginBanner'), findsNothing);
    await drain(tester);
  });

  test('pairing errors map by code and never show raw English', () {
    const s = S('vi');
    expect(pairingErrorText(s, const PairingException('This pairing code has expired.', code: PairingErrorCode.expired)), contains('hết hạn'));
    expect(pairingErrorText(s, const PairingException('Could not reach the server at host:1.', code: PairingErrorCode.unreachable, detail: 'host:1')), contains('host:1'));
    expect(pairingErrorText(s, const PairingException('Could not reach the server.', code: PairingErrorCode.unreachable)), 'Không kết nối được tới máy chủ. Hãy kiểm tra mạng.');
    expect(pairingErrorText(s, const PairingException('expired: Totally new English text')), 'Không ghép nối được. Hãy thử lại.');
    for (final code in PairingErrorCode.values) {
      expect(pairingErrorText(s, PairingException('English detail', code: code, detail: 'host:1')), isNot(contains('English')));
    }
  });
}
