import 'package:flutter/gestures.dart';
import 'package:material_ui/material_ui.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:zalos/src/domain/models.dart';
import 'package:zalos/src/ui/chat/message_row.dart';
import 'package:zalos/src/ui/components/pressable.dart';
import 'package:zalos/src/ui/platform/services.dart';
import 'package:zalos/src/ui/state/app_state.dart';
import 'package:zalos/src/ui/state/thread_ui.dart';
import 'package:zalos/src/ui/theme/tokens.dart';
import 'package:zalos/src/ui/threads/thread_tile.dart';

import '../support/fake_platform.dart';
import '../support/fake_png.dart';
import '../support/fake_zalos.dart';
import '../support/harness.dart';

List<Message> _msgs(Harness h, String id) => h.main
    .messages(id, id.startsWith('g') ? ThreadType.group : ThreadType.user)
    .value;
Message _byText(Harness h, String id, String text) =>
    _msgs(h, id).firstWhere((m) => m.text == text);
ScrollPosition _pos(WidgetTester tester) => tester
    .state<ScrollableState>(find
        .descendant(of: byKey('messageList'), matching: find.byType(Scrollable))
        .first)
    .position;
Finder _tooltip(String message) => find.byWidgetPredicate(
    (widget) => widget is Tooltip && widget.message == message);

Future<void> _rightClick(WidgetTester tester, Finder f) async {
  await tester.tap(f, buttons: kSecondaryButton);
  await settle(tester);
}

void main() {
  testWidgets('chat header: group subtitle uses the total member count',
      (tester) async {
    final h = await pumpZalos(tester, size: expanded);
    h.main.groupMemberCounts['g01'] = 8;
    // The thread list already fetched this group; refetch with the new total.
    h.container.invalidate(groupInfoProvider((h.main, 'g01')));
    await openThreadByKey(tester, 'g01');
    expect(find.text('8 thành viên'), findsOneWidget);
    await drain(tester);
  });

  for (final entry in sizes.entries) {
    final wide = entry.value.width >= 720;
    testWidgets(
        'chat at ${entry.key}: unread divider, mark seen, send text, delivery state',
        (tester) async {
      final h = await pumpZalos(tester, size: entry.value);
      await openThreadByKey(tester, 'g01');
      expect(byKey('unreadDivider'), findsOneWidget);
      expect(find.text('Tin nhắn chưa đọc'), findsOneWidget);
      expect(h.main.threads.value.firstWhere((t) => t.id == 'g01').unread, 0);
      expect(find.text('4 thành viên'), findsOneWidget);
      expect(find.text('Hôm nay'), findsOneWidget);
      expect(find.text('Đã xem'), findsOneWidget);

      await tester.enterText(byKey('composerField'), 'Xin chào cả nhà');
      await tester.pump();
      await tapKey(tester, 'sendButton', scroll: false);
      final sent = _msgs(h, 'g01').last;
      expect(sent.text, 'Xin chào cả nhà');
      expect(byKey('bubble-${sent.id}'), findsOneWidget);
      expect(byKey('state-${sent.id}'), findsOneWidget);
      expect(find.text('Đã gửi'), findsOneWidget);
      h.main.replace(sent, (m) => h.main.copy(m, deliveryState: DeliveryState.delivered));
      await tester.pump();
      expect(find.text('Đã nhận'), findsOneWidget);
      h.main.replace(sent, (m) => h.main.copy(m, deliveryState: DeliveryState.seen));
      await tester.pump();
      expect(find.text('Đã xem'), findsOneWidget);
      if (!wide) {
        await tapKey(tester, 'chatBack');
        expect(byKey('bottomNav'), findsOneWidget);
      }
      await drain(tester);
    });
  }

  testWidgets('grouping: name and avatar once per group, time on the last bubble', (tester) async {
    final h = await pumpZalos(tester, size: expanded);
    await openThreadByKey(tester, 'g01');
    final a = h.main.receive('g01', 'Dòng một', from: 'u04', ts: fakeNow.millisecondsSinceEpoch + 1000);
    final b = h.main.receive('g01', 'Dòng hai', from: 'u04', ts: fakeNow.millisecondsSinceEpoch + 2000);
    final c = h.main.receive('g01', 'Dòng ba', from: 'u04', ts: fakeNow.millisecondsSinceEpoch + 3000);
    await settle(tester);
    RowFlags flags(Message m) => tester.widget<MessageRow>(find.ancestor(of: byKey('bubble-${m.id}'), matching: find.byType(MessageRow))).flags;
    expect((flags(a).first, flags(a).last), (true, false));
    expect((flags(b).first, flags(b).last), (false, false));
    expect((flags(c).first, flags(c).last), (false, true));
    expect(find.descendant(of: byKey('bubble-${a.id}'), matching: find.text('Phạm Gia Huy')), findsOneWidget);
    expect(find.descendant(of: byKey('bubble-${b.id}'), matching: find.text('Phạm Gia Huy')), findsNothing);
    expect(find.descendant(of: byKey('bubble-${c.id}'), matching: find.text('14:05')), findsOneWidget);
    expect(find.descendant(of: byKey('bubble-${a.id}'), matching: find.text('14:05')), findsNothing);
    final late = h.main.receive('g01', 'Ba phút sau', from: 'u04', ts: fakeNow.millisecondsSinceEpoch + 200000);
    await settle(tester);
    expect(flags(late).first, isTrue);
    await drain(tester);
  });

  testWidgets('one to one chat on compact has no avatar and no sender name', (tester) async {
    final h = await pumpZalos(tester);
    await openThreadByKey(tester, 'u02');
    final m = _msgs(h, 'u02').firstWhere((m) => !m.isSelf && m.kind == MessageKind.text);
    final row = find.ancestor(of: byKey('bubble-${m.id}'), matching: find.byType(MessageRow));
    expect(find.descendant(of: row, matching: find.text('Trần Quốc Bảo')), findsNothing);
    await drain(tester);
  });

  testWidgets('every message kind renders its own content', (tester) async {
    final platform = FakePlatform();
    final h = await pumpZalos(tester, size: const Size(1440, 3000), platform: platform);
    await openThreadByKey(tester, 'g01');
    await settle(tester);
    expect(find.text('Mẹ đã thêm Phạm Gia Huy vào nhóm'), findsOneWidget);
    expect(find.descendant(of: byKey('messageList'), matching: find.text('Tin nhắn đã được thu hồi')), findsOneWidget);
    expect(find.text('Tin nhắn được mã hóa. Thiết bị này chưa có khóa.'), findsOneWidget);
    expect(find.text('Loại tin nhắn chưa được hỗ trợ'), findsOneWidget);
    expect(find.text('Lich_ve_que_thang_8.xlsx'), findsOneWidget);
    expect(find.text('XLSX \u00b7 47 KB'), findsOneWidget);
    expect(find.text('0:12'), findsOneWidget);
    expect(find.text('0:34'), findsOneWidget);
    expect(find.text('thoitiet.example.vn'), findsOneWidget);
    final quoted = _byText(h, 'g01', 'Con mua thêm trái cây nha mẹ');
    expect(byKey('quote-${quoted.id}'), findsOneWidget);
    final reacted = _byText(h, 'g01', 'Dạ, con về tối thứ 6 ạ');
    expect(byKey('reactions-${reacted.id}'), findsOneWidget);
    expect(find.descendant(of: byKey('reactions-${reacted.id}'), matching: find.text('3')), findsOneWidget);

    await tester.tap(find.text('thoitiet.example.vn'));
    await settle(tester);
    expect(platform.openedUrls, ['https://thoitiet.example.vn/du-bao-cuoi-tuan']);
    await drain(tester);
  });

  testWidgets('emoji only message renders large without a bubble frame', (tester) async {
    final h = await pumpZalos(tester, size: expanded);
    await openThreadByKey(tester, 'u02');
    final m = h.main.receive('u02', '😀😀');
    await settle(tester);
    expect(byKey('emojiOnly-${m.id}'), findsOneWidget);
    await drain(tester);
  });

  testWidgets('compact composer uses the shared pill radius on every border',
      (tester) async {
    await pumpZalos(tester);
    await openThreadByKey(tester, 'u02');
    final decoration =
        tester.widget<TextField>(byKey('composerField')).decoration!;
    for (final border in [
      decoration.border,
      decoration.enabledBorder,
      decoration.focusedBorder
    ]) {
      expect(border, isA<OutlineInputBorder>());
      expect((border! as OutlineInputBorder).borderRadius,
          BorderRadius.circular(ZRadius.pill));
    }
    await drain(tester);
  });

  testWidgets('file download: ring, then open; failure offers retry',
      (tester) async {
    final platform = FakePlatform();
    final h = await pumpZalos(tester,
        size: const Size(1440, 2600),
        platform: platform,
        app: FakeZalosApp(latency: const Duration(milliseconds: 200)));
    await openThreadByKey(tester, 'g01');
    await settle(tester, const Duration(seconds: 2));
    h.app.flags.failMedia.add('fake://file/lich');
    await tester.tap(byKey('fileDownload-fake://file/lich'));
    await tester.pump(const Duration(milliseconds: 50));
    expect(find.bySemanticsLabel(RegExp('Đang tải về')), findsOneWidget);
    await settle(tester);
    expect(_tooltip('Thử lại'), findsOneWidget);
    h.app.flags.failMedia.clear();
    await tapKey(tester, 'fileDownload-fake://file/lich', scroll: false);
    expect(platform.saved, ['Lich_ve_que_thang_8.xlsx']);
    await tapKey(tester, 'fileOpen-fake://file/lich', scroll: false);
    expect(platform.openedSaved, ['/downloads/Lich_ve_que_thang_8.xlsx']);
    await drain(tester);
  });

  testWidgets('voice: one message plays at a time', (tester) async {
    final platform = FakePlatform();
    final h = await pumpZalos(tester,
        size: const Size(1440, 2600), platform: platform);
    await openThreadByKey(tester, 'g01');
    final voice =
        _msgs(h, 'g01').firstWhere((m) => m.kind == MessageKind.voice);
    await tapKey(tester, 'voicePlay-${voice.id}', scroll: false);
    expect(platform.players, hasLength(1));
    expect(platform.players.single.status.value.playing, isTrue);
    expect(platform.players.single.withVideo, isFalse);
    expect(_tooltip('Tạm dừng'), findsOneWidget);
    platform.players.single.set(const PlaybackStatus(
        playing: true,
        position: Duration(seconds: 5),
        duration: Duration(seconds: 12),
        ready: true));
    await tester.pump();
    expect(find.text('0:05 / 0:12'), findsOneWidget);
    await tapKey(tester, 'voicePlay-${voice.id}', scroll: false);
    expect(platform.players.single.status.value.playing, isFalse);

    final other = h.main.receive('g01', '',
        from: 'u05',
        kind: MessageKind.voice,
        attachments: const [
          Attachment(
              kind: MessageKind.voice, url: 'fake://voice/9', durationMs: 4000)
        ]);
    await settle(tester);
    await tapKey(tester, 'voicePlay-${other.id}', scroll: false);
    expect(platform.players, hasLength(2));
    expect(platform.players.first.disposed, isTrue);
    await drain(tester);
  });

  testWidgets('image viewer: counter, arrow keys, download, Esc; video page has controls', (tester) async {
    final platform = FakePlatform();
    final h = await pumpZalos(tester, size: const Size(1440, 2600), platform: platform);
    await openThreadByKey(tester, 'g01');
    final grid = _msgs(h, 'g01').firstWhere((m) => m.attachments.length == 3);
    await tester.tap(find.descendant(of: byKey('media-${grid.id}'), matching: find.bySemanticsLabel('Mở hình ảnh')).at(1));
    await settle(tester);
    expect(byKey('mediaViewer'), findsOneWidget);
    expect(find.textContaining('3/5'), findsOneWidget);
    await sendKey(tester, LogicalKeyboardKey.escape);
    expect(byKey('mediaViewer'), findsNothing);
    await tester.tap(find.descendant(of: byKey('media-${grid.id}'), matching: find.bySemanticsLabel('Mở hình ảnh')).at(1));
    await settle(tester);
    await sendKey(tester, LogicalKeyboardKey.arrowRight);
    expect(find.textContaining('4/5'), findsOneWidget);
    await tapKey(tester, 'viewerDownload', scroll: false);
    expect(platform.saved, hasLength(1));
    await tapKey(tester, 'viewerShare', scroll: false);
    expect(platform.shared, hasLength(1));
    await sendKey(tester, LogicalKeyboardKey.arrowRight);
    await settle(tester);
    expect(byKey('videoControls'), findsOneWidget);
    expect(byKey('fakeVideoSurface'), findsOneWidget);
    expect(platform.players.last.withVideo, isTrue, reason: 'the video surface exists before the media opens');
    await tapKey(tester, 'videoPlayPause', scroll: false);
    expect(platform.players.last.status.value.playing, isFalse);
    await tapKey(tester, 'viewerClose', scroll: false);
    expect(byKey('mediaViewer'), findsNothing);
    await drain(tester);
  });

  testWidgets('hover action bar and reaction picker on pointer devices', (tester) async {
    final h = await pumpZalos(tester, size: expanded);
    await openThreadByKey(tester, 'g01');
    final m = _byText(h, 'g01', 'Chị Thư ơi mấy giờ chị tới?');
    await hover(tester, byKey('bubble-${m.id}'));
    expect(tester.widget<AnimatedOpacity>(find.ancestor(of: byKey('hoverBar-${m.id}'), matching: find.byType(AnimatedOpacity)).first).opacity, 1);
    expect(byKey('reactButton-${m.id}'), findsOneWidget);
    await tapKey(tester, 'hoverReply-${m.id}', scroll: false);
    expect(byKey('replyBar'), findsOneWidget);
    await sendKey(tester, LogicalKeyboardKey.escape);
    expect(byKey('replyBar'), findsNothing);

    await hover(tester, byKey('bubble-${m.id}'));
    await tester.tap(byKey('reactButton-${m.id}'));
    await settle(tester);
    expect(_byText(h, 'g01', m.text!).reactions['/-heart'], ['self-main']);
    await hover(tester, byKey('bubble-${m.id}'));
    await tester.longPress(byKey('reactButton-${m.id}'));
    await settle(tester);
    expect(byKey('reactionPicker'), findsOneWidget);
    await tapKey(tester, 'react-:>', scroll: false);
    expect(_byText(h, 'g01', m.text!).reactions.keys, [':>']);
    await tapKey(tester, 'reactions-${m.id}', scroll: false);
    expect(byKey('whoReacted'), findsOneWidget);
    expect(find.descendant(of: byKey('whoReacted'), matching: find.text('Bạn')), findsOneWidget);
    await drain(tester);
  });

  testWidgets('context menu: reply with quote, copy, details, recall, delete', (tester) async {
    String? copied;
    tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(SystemChannels.platform, (call) async {
      if (call.method == 'Clipboard.setData') copied = (call.arguments as Map)['text'] as String?;
      return null;
    });
    addTearDown(() => tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(SystemChannels.platform, null));
    final h = await pumpZalos(tester, size: expanded);
    await openThreadByKey(tester, 'g01');
    final peer = _byText(h, 'g01', 'Chị Thư ơi mấy giờ chị tới?');
    await _rightClick(tester, byKey('bubble-${peer.id}'));
    expect(byKey('menu-MessageAction.recall'), findsNothing);
    expect(byKey('react-/-heart'), findsOneWidget);
    await tapKey(tester, 'menu-MessageAction.copy', scroll: false);
    expect(copied, peer.text);

    await _rightClick(tester, byKey('bubble-${peer.id}'));
    await tapKey(tester, 'menu-MessageAction.reply', scroll: false);
    expect(byKey('replyBar'), findsOneWidget);
    expect(find.text('Trả lời Phạm Gia Huy'), findsOneWidget);
    await tester.enterText(byKey('composerField'), 'Khoảng 6 giờ nha');
    await sendKey(tester, LogicalKeyboardKey.enter);
    expect(h.main.sentTexts.last.quote?.id, peer.id);
    expect(byKey('replyBar'), findsNothing);
    final reply = _msgs(h, 'g01').last;
    await tapKey(tester, 'quote-${reply.id}', scroll: false);
    await tester.pump(const Duration(milliseconds: 300));
    expect(byKey('highlight-${peer.id}'), findsOneWidget);
    await settle(tester, const Duration(seconds: 2));
    expect(byKey('highlight-${peer.id}'), findsNothing);

    await _rightClick(tester, byKey('bubble-${reply.id}'));
    await tapKey(tester, 'menu-MessageAction.details', scroll: false);
    expect(byKey('messageDetails'), findsOneWidget);
    await tester.tap(find.text('Đóng'));
    await settle(tester);

    await _rightClick(tester, byKey('bubble-${reply.id}'));
    await tapKey(tester, 'menu-MessageAction.recall', scroll: false);
    expect(find.text('Thu hồi tin nhắn này?'), findsOneWidget);
    await tapKey(tester, 'confirmOk', scroll: false);
    expect(_msgs(h, 'g01').last.recalled, isTrue);
    await _rightClick(tester, byKey('bubble-${reply.id}'));
    expect(byKey('menu-MessageAction.reply'), findsNothing);
    expect(byKey('menu-MessageAction.recall'), findsNothing);
    final count = _msgs(h, 'g01').length;
    await tapKey(tester, 'menu-MessageAction.delete', scroll: false);
    await tapKey(tester, 'confirmOk', scroll: false);
    expect(_msgs(h, 'g01').length, count - 1);
    await drain(tester);
  });

  testWidgets('forward to a destination picker', (tester) async {
    final h = await pumpZalos(tester, size: expanded);
    await openThreadByKey(tester, 'g01');
    final m = _byText(h, 'g01', 'Mẹ nấu canh chua rồi đó');
    await _rightClick(tester, byKey('bubble-${m.id}'));
    await tapKey(tester, 'menu-MessageAction.forward', scroll: false);
    expect(byKey('destinationPicker'), findsOneWidget);
    expect(tester.widget<ZButton>(byKey('destinationConfirm')).onPressed, isNull);
    await tapKey(tester, 'destination-user/u02', scroll: false);
    await tapKey(tester, 'destination-group/g03', scroll: false);
    await tapKey(tester, 'destinationConfirm', scroll: false);
    expect(h.main.forwarded.single.$1.id, m.id);
    expect(h.main.forwarded.single.$2.map((r) => r.id), ['u02', 'g03']);
    expect(find.text('Đã chuyển tiếp'), findsOneWidget);
    await drain(tester);
  });

  testWidgets('touch: long press menu, swipe to reply with haptic tick, heart button', (tester) async {
    final platform = FakePlatform();
    final h = await pumpZalos(tester, platform: platform);
    await openThreadByKey(tester, 'g01');
    final m = _byText(h, 'g01', 'Mẹ nấu canh chua rồi đó');
    await tester.longPress(byKey('bubble-${m.id}'));
    await settle(tester);
    expect(byKey('menu-MessageAction.reply'), findsOneWidget);
    await tester.tapAt(const Offset(5, 5));
    await settle(tester);
    await tester.drag(byKey('bubble-${m.id}'), const Offset(120, 0));
    await settle(tester);
    expect(byKey('replyBar'), findsOneWidget);
    expect(platform.haptics, 1);
    await tapKey(tester, 'replyClose', scroll: false);
    await tapKey(tester, 'reactButton-${m.id}', scroll: false);
    expect(_byText(h, 'g01', m.text!).reactions['/-heart'], ['self-main']);
    await drain(tester);
  });

  testWidgets('failed send: retry row uses resend in place; long press offers delete', (tester) async {
    final h = await pumpZalos(tester, size: expanded);
    await openThreadByKey(tester, 'u02');
    h.app.flags.failSends = true;
    await tester.enterText(byKey('composerField'), 'thử gửi');
    await sendKey(tester, LogicalKeyboardKey.enter);
    final failed = _msgs(h, 'u02').last;
    expect(failed.sendState, SendState.failed);
    expect(find.text('Không gửi được. Thử lại'), findsOneWidget);
    h.app.flags.failSends = false;
    final count = _msgs(h, 'u02').length;
    await tapKey(tester, 'retry-${failed.id}', scroll: false);
    expect(h.main.resent, [failed.id]);
    expect(_msgs(h, 'u02').length, count);
    expect(_msgs(h, 'u02').last.sendState, SendState.sent);

    h.app.flags.failSends = true;
    await tester.enterText(byKey('composerField'), 'lần hai');
    await sendKey(tester, LogicalKeyboardKey.enter);
    final second = _msgs(h, 'u02').last;
    await tester.longPress(byKey('retry-${second.id}'));
    await settle(tester);
    await tapKey(tester, 'menu-MessageAction.delete', scroll: false);
    expect(_msgs(h, 'u02').any((m) => m.id == second.id), isFalse);
    await drain(tester);
  });

  testWidgets('failed sends keep their own code; resend clears or updates it',
      (tester) async {
    final h = await pumpZalos(tester, size: expanded);
    await openThreadByKey(tester, 'u02');

    h.main.sendErrorCode = 'window_expired';
    await tester.enterText(byKey('composerField'), 'một');
    await sendKey(tester, LogicalKeyboardKey.enter);
    final first = _msgs(h, 'u02').last;
    expect(first.sendErrorCode, 'window_expired');
    expect(
        find.text(
            'Người dùng chưa tương tác trong 7 ngày nên OA không thể gửi tin'),
        findsOneWidget);

    h.main.sendErrorCode = 'quota_exceeded';
    await tester.enterText(byKey('composerField'), 'hai');
    await sendKey(tester, LogicalKeyboardKey.enter);
    final second = _msgs(h, 'u02').last;
    expect(second.sendErrorCode, 'quota_exceeded');
    expect(find.textContaining('hết hạn mức'), findsOneWidget);
    expect(
        find.text(
            'Người dùng chưa tương tác trong 7 ngày nên OA không thể gửi tin'),
        findsOneWidget);

    h.main.sendErrorCode = null;
    await tapKey(tester, 'retry-${second.id}', scroll: false);
    final resentSecond = _msgs(h, 'u02').firstWhere((m) => m.id == second.id);
    expect(resentSecond.sendState, SendState.sent);
    expect(resentSecond.sendErrorCode, isNull);

    h.main.sendErrorCode = 'quota_exceeded';
    await tester.enterText(byKey('composerField'), 'ba');
    await sendKey(tester, LogicalKeyboardKey.enter);
    final third = _msgs(h, 'u02').last;
    h.main.sendErrorCode = 'rate_limited';
    await tapKey(tester, 'retry-${third.id}', scroll: false);
    final resentThird = _msgs(h, 'u02').firstWhere((m) => m.id == third.id);
    expect(resentThird.sendState, SendState.failed);
    expect(resentThird.sendErrorCode, 'rate_limited');
    expect(find.textContaining('quá nhanh'), findsOneWidget);
    await drain(tester);
  });

  testWidgets('sending state shows the clock while the send is in flight',
      (tester) async {
    final h = await pumpZalos(tester,
        size: expanded,
        app: FakeZalosApp(latency: const Duration(milliseconds: 400)));
    await openThreadByKey(tester, 'u02');
    await settle(tester, const Duration(seconds: 1));
    await tester.enterText(byKey('composerField'), 'đang gửi');
    await tester.sendKeyEvent(LogicalKeyboardKey.enter);
    await tester.pump(const Duration(milliseconds: 100));
    await tester.pump(const Duration(milliseconds: 100));
    expect(_msgs(h, 'u02').last.sendState, SendState.sending);
    expect(find.bySemanticsLabel(RegExp('Đang gửi')), findsWidgets);
    await settle(tester, const Duration(seconds: 1));
    expect(find.bySemanticsLabel(RegExp('Đang gửi')), findsNothing);
    await drain(tester);
  });

  testWidgets('composer: Shift+Enter newline, draft survives navigation, typing is throttled', (tester) async {
    final h = await pumpZalos(tester, size: expanded);
    await openThreadByKey(tester, 'u02');
    await tester.enterText(byKey('composerField'), 'dòng 1');
    await sendKey(tester, LogicalKeyboardKey.enter, shift: true);
    expect(_msgs(h, 'u02').last.text, isNot('dòng 1'));
    await tester.enterText(byKey('composerField'), 'bản nháp dở');
    await tester.pump();
    await tester.enterText(byKey('composerField'), 'bản nháp dở dang');
    await tester.pump();
    expect(h.main.typingSent, 1);
    await openThreadByKey(tester, 'u05');
    expect(tester.widget<TextField>(byKey('composerField')).controller!.text, '');
    expect(find.textContaining('[Nháp] bản nháp dở dang', findRichText: true), findsOneWidget);
    await openThreadByKey(tester, 'u02');
    expect(tester.widget<TextField>(byKey('composerField')).controller!.text, 'bản nháp dở dang');
    await drain(tester);
  });

  testWidgets('composer: attachments via picker, paste and drop; size limit; send', (tester) async {
    final platform = FakePlatform();
    final h = await pumpZalos(tester, size: expanded, platform: platform);
    await openThreadByKey(tester, 'u02');
    final png = fakePng('a');
    platform.nextImages = [PickedFile('anh.png', png)];
    await tapKey(tester, 'attachImageButton', scroll: false);
    expect(byKey('pendingAttachments'), findsOneWidget);
    platform.nextFiles = [PickedFile('bao-cao.pdf', Uint8List(2048))];
    await tapKey(tester, 'attachFileButton', scroll: false);
    expect(find.textContaining('2 tệp'), findsOneWidget);

    platform.dropOnHover!(true);
    await tester.pump();
    expect(byKey('dropOverlay'), findsOneWidget);
    expect(find.text('Thả file để gửi'), findsOneWidget);
    platform.dropOnHover!(false);
    platform.dropOnDrop!([PickedFile('tha.txt', Uint8List(10))]);
    await tester.pump();
    expect(byKey('dropOverlay'), findsNothing);
    expect(find.textContaining('3 tệp'), findsOneWidget);

    platform.clipboard = PickedFile('clipboard.png', png);
    await tester.tap(byKey('composerField'));
    await sendKey(tester, LogicalKeyboardKey.keyV, control: true);
    expect(find.textContaining('4 tệp'), findsOneWidget);
    await tapKey(tester, 'pendingRemove-3', scroll: false);
    expect(find.textContaining('3 tệp'), findsOneWidget);

    h.container.read(threadUiProvider((slot: 'main', id: 'u02')));
    platform.dropOnDrop!([PickedFile('qua-lon.bin', Uint8List(100 * 1024 * 1024 + 1))]);
    await tester.pump();
    expect(find.textContaining('100 MB'), findsOneWidget);
    expect(find.textContaining('3 tệp'), findsOneWidget);

    await tapKey(tester, 'sendButton', scroll: false);
    expect(h.main.sentFiles.map((f) => f.name), ['anh.png', 'bao-cao.pdf', 'tha.txt']);
    expect(h.main.sentFiles.map((f) => f.kind), [MessageKind.image, MessageKind.file, MessageKind.file]);
    expect(byKey('pendingAttachments'), findsNothing);
    await drain(tester);
  });

  testWidgets('composer: mention picker with @All, keyboard selection, mentions sent', (tester) async {
    final h = await pumpZalos(tester, size: expanded);
    await openThreadByKey(tester, 'g01');
    await tester.enterText(byKey('composerField'), 'Chào @');
    await settle(tester);
    expect(byKey('mentionList'), findsOneWidget);
    expect(byKey('mention--1'), findsOneWidget);
    expect(byKey('mention-u04'), findsOneWidget);
    expect(byKey('mention-self-main'), findsNothing);
    await tester.enterText(byKey('composerField'), 'Chào @huy');
    await settle(tester);
    expect(byKey('mention-u05'), findsNothing);
    await sendKey(tester, LogicalKeyboardKey.enter);
    expect(tester.widget<TextField>(byKey('composerField')).controller!.text, 'Chào @Phạm Gia Huy ');
    expect(byKey('mentionList'), findsNothing);
    await sendKey(tester, LogicalKeyboardKey.enter);
    final sent = h.main.sentTexts.last;
    expect(sent.text, 'Chào @Phạm Gia Huy');
    expect(sent.mentions.single.uid, 'u04');
    expect((sent.mentions.single.pos, sent.mentions.single.len), (5, 13));

    await tester.enterText(byKey('composerField'), '@');
    await settle(tester);
    await tapKey(tester, 'mention--1', scroll: false);
    await sendKey(tester, LogicalKeyboardKey.enter);
    expect(h.main.sentTexts.last.mentions.single.uid, '-1');
    await drain(tester);
  });

  for (final entry in {'compact': compact, 'expanded': expanded}.entries) {
    testWidgets('emoji and sticker panel at ${entry.key}', (tester) async {
      final h = await pumpZalos(tester, size: entry.value, app: FakeZalosApp(latency: const Duration(milliseconds: 200)));
      await openThreadByKey(tester, 'u02');
      await settle(tester, const Duration(seconds: 1));
      await tester.tap(byKey('stickerButton'));
      await tester.pump(const Duration(milliseconds: 50));
      expect(byKey('pickerPanel'), findsOneWidget);
      if (entry.key == 'compact') {
        await tester.pump(const Duration(milliseconds: 300));
        await tapKey(tester, 'emoji-0', scroll: false);
        expect(tester.widget<TextField>(byKey('composerField')).controller!.text, '😀');
        await tester.tap(find.descendant(of: byKey('pickerPanel'), matching: find.text('Sticker')));
        await tester.pump(const Duration(milliseconds: 50));
      }
      expect(byKey('stickerSkeleton'), findsOneWidget);
      await settle(tester);
      expect(byKey('stickerGrid'), findsOneWidget);
      await tester.enterText(byKey('stickerSearch'), 'zzz');
      await settle(tester, const Duration(seconds: 1));
      expect(byKey('stickerEmpty'), findsOneWidget);
      h.app.flags.failStickers = true;
      await tester.enterText(byKey('stickerSearch'), 'meo');
      await settle(tester, const Duration(seconds: 1));
      expect(find.text('Không tải được sticker'), findsOneWidget);
      h.app.flags.failStickers = false;
      await tester.tap(find.descendant(of: byKey('pickerPanel'), matching: find.text('Thử lại')));
      await settle(tester, const Duration(seconds: 1));
      await tapKey(tester, 'sticker-21', scroll: false);
      expect(h.main.sentStickers.single.id, 21);
      await drain(tester);
    });
  }

  testWidgets('voice recording: bar with elapsed time, cancel, send, denied permission', (tester) async {
    final platform = FakePlatform();
    final h = await pumpZalos(tester, size: expanded, platform: platform);
    await openThreadByKey(tester, 'u02');
    platform.micAllowed = false;
    await tapKey(tester, 'voiceButton', scroll: false);
    expect(byKey('recordingBar'), findsNothing);
    expect(find.textContaining('micro'), findsOneWidget);
    platform.micAllowed = true;
    await tapKey(tester, 'voiceButton', scroll: false);
    expect(byKey('recordingBar'), findsOneWidget);
    await tester.pump(const Duration(seconds: 3));
    expect(find.text('Đang ghi âm 0:03'), findsOneWidget);
    await tapKey(tester, 'recordCancel', scroll: false);
    expect(platform.recorders.last.cancelled, isTrue);
    expect(h.main.sentFiles, isEmpty);
    await tapKey(tester, 'voiceButton', scroll: false);
    await tapKey(tester, 'recordSend', scroll: false);
    expect(h.main.sentFiles.single.kind, MessageKind.voice);
    expect(byKey('composerField'), findsOneWidget);
    await drain(tester);
  });

  testWidgets('composer is replaced by a status banner when the account is not online', (tester) async {
    final h = await pumpZalos(tester, size: expanded);
    await openThreadByKey(tester, 'u02');
    h.link.setStatus('main', AccountStatus.reconnecting);
    await tester.pump();
    expect(byKey('composerOffline'), findsOneWidget);
    expect(byKey('composerField'), findsNothing);
    h.link.setStatus('main', AccountStatus.online);
    await tester.pump();
    expect(byKey('composerField'), findsOneWidget);
    await drain(tester);
  });

  testWidgets('paging: skeleton, older pages on scroll, history start', (tester) async {
    final h = await pumpZalos(tester, size: expanded, app: FakeZalosApp(latency: const Duration(milliseconds: 300)));
    await openThreadByKey(tester, 'u01');
    await settle(tester, const Duration(seconds: 1));
    final before = _msgs(h, 'u01').length;
    await tester.drag(byKey('messageList'), const Offset(0, 2500));
    await tester.pump(const Duration(milliseconds: 50));
    await tester.pump(const Duration(milliseconds: 50));
    expect(byKey('olderSpinner'), findsOneWidget);
    await settle(tester, const Duration(seconds: 1));
    expect(_msgs(h, 'u01').length, greaterThan(before));
    for (var i = 0; i < 12; i++) {
      await tester.drag(byKey('messageList'), const Offset(0, 4000));
      await settle(tester, const Duration(seconds: 1));
    }
    expect(_msgs(h, 'u01').length, 80);
    expect(byKey('historyStart'), findsOneWidget);
    await drain(tester);

    await pumpZalos(tester, size: expanded, app: FakeZalosApp(latency: const Duration(seconds: 1)));
    await tapKey(tester, 'newChat');
    await tester.enterText(byKey('destinationSearch'), 'ong hanh');
    await settle(tester);
    await tapKey(tester, 'destination-user/u14', scroll: false);
    await tester.pump();
    expect(byKey('messagesLoading'), findsOneWidget);
    await drain(tester);
  });

  testWidgets('scrolled up: incoming message keeps the viewport, badge counts, button returns', (tester) async {
    final h = await pumpZalos(tester, size: expanded);
    await openThreadByKey(tester, 'u01');
    await tester.drag(byKey('messageList'), const Offset(0, 1400));
    await settle(tester);
    final anchor = _msgs(h, 'u01').reversed.firstWhere((m) => byKey('bubble-${m.id}').evaluate().isNotEmpty);
    final dy = tester.getTopLeft(byKey('bubble-${anchor.id}')).dy;
    h.main.receive('u01', 'Tin tới khi đang đọc cũ 1');
    h.main.receive('u01', 'Tin tới khi đang đọc cũ 2');
    await settle(tester);
    expect(tester.getTopLeft(byKey('bubble-${anchor.id}')).dy, moreOrLessEquals(dy, epsilon: 0.5));
    expect(find.text('Tin tới khi đang đọc cũ 2'), findsNothing);
    expect(find.descendant(of: byKey('awayBadge'), matching: find.text('2')), findsOneWidget);
    await tapKey(tester, 'scrollToLatest', scroll: false);
    await settle(tester);
    expect(find.text('Tin tới khi đang đọc cũ 2'), findsOneWidget);
    expect(byKey('awayBadge'), findsNothing);
    expect(_pos(tester).pixels, moreOrLessEquals(0, epsilon: 1));

    h.main.receive('u01', 'Tin tới khi ở cuối');
    await settle(tester);
    expect(find.text('Tin tới khi ở cuối'), findsOneWidget);
    await drain(tester);
  });

  testWidgets('search in conversation: counter, arrows, loaded-only caption, close', (tester) async {
    await pumpZalos(tester, size: expanded);
    await openThreadByKey(tester, 'u01');
    await tapKey(tester, 'chatSearch', scroll: false);
    expect(find.text('Chỉ tìm trong lịch sử đã tải'), findsOneWidget);
    await tester.enterText(byKey('chatSearchField'), 'minh');
    await settle(tester);
    final counter = tester.widget<Text>(byKey('chatSearchCounter')).data!;
    final total = int.parse(counter.split('/')[1]);
    expect(total, greaterThan(1));
    expect(counter, '$total/$total');
    await tapKey(tester, 'chatSearchPrev', scroll: false);
    expect(tester.widget<Text>(byKey('chatSearchCounter')).data, '${total - 1}/$total');
    await tapKey(tester, 'chatSearchNext', scroll: false);
    await tester.enterText(byKey('chatSearchField'), 'khongcotin');
    await settle(tester);
    expect(find.text('0 kết quả'), findsOneWidget);
    await tapKey(tester, 'chatSearchClose', scroll: false);
    expect(byKey('chatTitle'), findsOneWidget);
    await drain(tester);
  });

  testWidgets('typing indicator and header subtitle', (tester) async {
    final h = await pumpZalos(tester, size: expanded);
    await openThreadByKey(tester, 'u02');
    expect(byKey('typingIndicator'), findsNothing);
    h.main.emitTyping('u02', 'u02');
    await settle(tester, const Duration(milliseconds: 200));
    expect(byKey('typingIndicator'), findsOneWidget);
    expect(find.text('Đang soạn tin...'), findsOneWidget);
    h.main.receive('u02', 'xong rồi');
    await settle(tester, const Duration(milliseconds: 200));
    expect(byKey('typingIndicator'), findsNothing);
    await drain(tester);
  });

  testWidgets('reduced motion: new messages do not slide', (tester) async {
    final h = await pumpZalos(tester, size: expanded, reduceMotion: true);
    await openThreadByKey(tester, 'u02');
    final m = h.main.receive('u02', 'không trượt');
    await tester.pump();
    final row = find.ancestor(of: byKey('bubble-${m.id}'), matching: find.byType(MessageRow));
    expect(find.descendant(of: row, matching: find.byType(SlideTransition)), findsNothing);
    expect(find.descendant(of: row, matching: find.byType(FadeTransition)), findsWidgets);
    await drain(tester);
  });

  testWidgets('chat keeps the thread from another account out of view', (tester) async {
    final h = await pumpZalos(tester, size: expanded);
    await openThreadByKey(tester, 'u02');
    await tapKey(tester, 'railAccount-shop');
    expect(byKey('chatEmpty'), findsOneWidget);
    expect(h.container.read(visibleThreadProvider), isNull);
    await drain(tester);
  });
}
