import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:flutter/gestures.dart' show kSecondaryButton;
import 'package:material_ui/material_ui.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:zalos/src/domain/models.dart';
import 'package:zalos/src/domain/services.dart';
import 'package:zalos/src/ui/chat/message_actions.dart';
import 'package:zalos/src/ui/components/pressable.dart';
import 'package:zalos/src/ui/state/app_state.dart';

import '../support/fake_zalos.dart';
import '../support/harness.dart';

Future<void> _contacts(WidgetTester tester, {bool wide = true}) async {
  await tapKey(tester, wide ? 'railTab-contacts' : 'tab-contacts');
  await settle(tester, const Duration(seconds: 1));
}

Future<void> _rightClick(WidgetTester tester, Finder finder) async {
  await tester.tap(finder, buttons: kSecondaryButton);
  await settle(tester);
}

Future<void> _openFriendMenu(WidgetTester tester, String uid) async {
  await revealIn(tester, 'friendsList', 'contact-$uid');
  await tapKey(tester, 'contactMenu-$uid');
}

Future<void> _revealInPane(
    WidgetTester tester, String paneKey, String key) async {
  final scrollable = find
      .descendant(of: byKey(paneKey), matching: find.byType(Scrollable))
      .first;
  await tester.scrollUntilVisible(byKey(key), 200, scrollable: scrollable);
  await tester.pump();
}

Finder _inSheet(String key, String text) =>
    find.descendant(of: byKey(key), matching: find.text(text));

void main() {
  testWidgets(
      'add friend: idle, loading, not found, error, send, cancel and accept',
      (tester) async {
    final h = await pumpZalos(tester,
        size: expanded,
        app: FakeZalosApp(latency: const Duration(milliseconds: 200)));
    await _contacts(tester);
    await tapKey(tester, 'addFriendButton');
    expect(byKey('addFriendSheet'), findsOneWidget);
    expect(byKey('addFriendIdle'), findsOneWidget);

    await tester.enterText(byKey('addFriendField'), '0900000019');
    await tester.tap(byKey('addFriendSearch'));
    await tester.pump(const Duration(milliseconds: 50));
    expect(byKey('addFriendLoading'), findsOneWidget);
    await settle(tester, const Duration(seconds: 2));
    expect(byKey('addFriendResult'), findsOneWidget);
    expect(find.text('Trần Hữu Phước'), findsWidgets);
    await tapKey(tester, 'addFriendSend', scroll: false);
    expect(h.main.friendRequestsSent.last.uid, 'u19');
    expect(byKey('addFriendCancelRequest'), findsOneWidget);
    await tapKey(tester, 'addFriendCancelRequest', scroll: false);
    expect(h.main.friendRequestsCancelled, contains('u19'));

    await tester.tap(_inSheet('addFriendMode', 'Tên Zalo'));
    await settle(tester);
    await tester.enterText(byKey('addFriendField'), 'minhchau');
    await tester.tap(byKey('addFriendSearch'));
    await settle(tester);
    expect(byKey('addFriendAccept'), findsOneWidget);
    await tapKey(tester, 'addFriendAccept', scroll: false);
    expect(h.main.friendRequestsAccepted, contains('u15'));
    expect(byKey('addFriendMessage'), findsOneWidget);

    await tester.enterText(byKey('addFriendField'), '0000000000');
    await tester.tap(byKey('addFriendSearch'));
    await settle(tester);
    expect(byKey('addFriendNotFound'), findsOneWidget);

    await tester.tap(_inSheet('addFriendMode', 'Số điện thoại'));
    await settle(tester);
    h.app.flags.failContacts = true;
    await tester.enterText(byKey('addFriendField'), '0900000019');
    await tester.tap(byKey('addFriendSearch'));
    await settle(tester);
    expect(byKey('addFriendError'), findsOneWidget);
    h.app.flags.failContacts = false;
    await tester.tap(_inSheet('addFriendError', 'Thử lại'));
    await settle(tester, const Duration(seconds: 2));
    expect(byKey('addFriendResult'), findsOneWidget);

    await sendKey(tester, LogicalKeyboardKey.escape);
    expect(byKey('addFriendSheet'), findsNothing);
    await drain(tester);
  });

  testWidgets(
      'friend requests: loading, accept, reject, cancel, empty and error',
      (tester) async {
    final h = await pumpZalos(tester,
        size: expanded,
        app: FakeZalosApp(latency: const Duration(milliseconds: 200)));
    await _contacts(tester);
    await tester.tap(byKey('friendRequestsButton'));
    await tester.pump(const Duration(milliseconds: 50));
    expect(byKey('friendRequestsLoading'), findsOneWidget);
    await settle(tester, const Duration(seconds: 2));
    expect(byKey('friendRequest-u15'), findsOneWidget);
    expect(byKey('friendRequest-u16'), findsOneWidget);

    await tapKey(tester, 'friendRequestAccept-u15', scroll: false);
    expect(h.main.friendRequestsAccepted, contains('u15'));
    await settle(tester);
    expect(byKey('friendRequest-u15'), findsNothing);
    await tapKey(tester, 'friendRequestReject-u16', scroll: false);
    expect(h.main.friendRequestsRejected, contains('u16'));
    await settle(tester);
    expect(byKey('friendRequestsEmpty-received'), findsOneWidget);

    await tester.tap(_inSheet('friendRequestsTabs', 'Đã gửi'));
    await settle(tester);
    expect(byKey('friendRequest-u17'), findsOneWidget);
    await tapKey(tester, 'friendRequestCancel-u17', scroll: false);
    expect(h.main.friendRequestsCancelled, contains('u17'));
    await settle(tester);
    expect(byKey('friendRequestsEmpty-sent'), findsOneWidget);
    await sendKey(tester, LogicalKeyboardKey.escape);
    expect(byKey('friendRequestsSheet'), findsNothing);
    await drain(tester);

    final h2 = await pumpZalos(tester, size: expanded);
    h2.main.receivedRequests.clear();
    h2.main.sentRequests.clear();
    await _contacts(tester);
    await tapKey(tester, 'friendRequestsButton');
    await settle(tester);
    expect(byKey('friendRequestsEmpty-received'), findsOneWidget);
    await sendKey(tester, LogicalKeyboardKey.escape);

    h2.app.flags.failContacts = true;
    await tapKey(tester, 'friendRequestsButton');
    await settle(tester);
    expect(byKey('friendRequestsError'), findsOneWidget);
    await drain(tester);
  });

  testWidgets(
      'friend row: alias, remove alias, block, unblock, share card and unfriend',
      (tester) async {
    final h = await pumpZalos(tester, size: expanded);
    await _contacts(tester);

    await _openFriendMenu(tester, 'u05');
    await tapKey(tester, 'menu-FriendAction.alias', scroll: false);
    expect(byKey('aliasDialog'), findsOneWidget);
    await tester.enterText(byKey('aliasField'), 'Má');
    await tapKey(tester, 'aliasSave', scroll: false);
    expect(h.main.aliasesSet.last, (uid: 'u05', alias: 'Má'));
    await settle(tester, const Duration(seconds: 1));

    await _openFriendMenu(tester, 'u05');
    await tapKey(tester, 'menu-FriendAction.removeAlias', scroll: false);
    expect(h.main.aliasesRemoved, contains('u05'));
    await settle(tester, const Duration(seconds: 1));

    await _openFriendMenu(tester, 'u05');
    await tapKey(tester, 'menu-FriendAction.block', scroll: false);
    expect(h.main.blockedUsers, contains('u05'));
    await _openFriendMenu(tester, 'u05');
    expect(find.text('Bỏ chặn'), findsOneWidget);
    await tapKey(tester, 'menu-FriendAction.block', scroll: false);
    expect(h.main.unblockedUsers, contains('u05'));

    await _openFriendMenu(tester, 'u05');
    await tapKey(tester, 'menu-FriendAction.share', scroll: false);
    expect(byKey('destinationPicker'), findsOneWidget);
    await tapKey(tester, 'destination-user/u02', scroll: false);
    expect(h.main.sentCards.last.card.uid, 'u05');
    expect(h.main.sentCards.last.threadId, 'u02');

    await _openFriendMenu(tester, 'u05');
    await tapKey(tester, 'menu-FriendAction.unfriend', scroll: false);
    expect(find.textContaining('Hủy kết bạn với'), findsOneWidget);
    await tapKey(tester, 'confirmOk', scroll: false);
    expect(h.main.removedFriends, contains('u05'));
    await settle(tester, const Duration(seconds: 1));
    expect(byKey('contact-u05'), findsNothing);
    await drain(tester);
  });

  testWidgets(
      'recommendations stay collapsed until toggled and keep friends usable',
      (tester) async {
    final h = await pumpZalos(tester,
        size: compact,
        app: FakeZalosApp(latency: const Duration(milliseconds: 300)));
    await _contacts(tester, wide: false);
    final toggle = byKey('recommendationsToggle');
    expect(toggle, findsOneWidget);
    expect(find.text('Xem gợi ý'), findsOneWidget);
    expect(byKey('recommendations'), findsNothing);
    expect(byKey('recommendation-u18'), findsNothing);
    expect(byKey('friendsList'), findsOneWidget);
    expect(byKey('contact-u13'), findsOneWidget);
    expect(tester.getSize(toggle).height, greaterThanOrEqualTo(44));

    await tester.tap(toggle);
    await settle(tester);
    expect(find.text('Ẩn gợi ý'), findsOneWidget);
    expect(byKey('recommendations'), findsOneWidget);
    expect(byKey('recommendation-u18'), findsOneWidget);
    expect(byKey('recommendation-u19'), findsOneWidget);
    expect(byKey('friendsList'), findsOneWidget);
    expect(byKey('contact-u13'), findsOneWidget);

    await tester.tap(toggle);
    await settle(tester);
    expect(find.text('Xem gợi ý'), findsOneWidget);
    expect(byKey('recommendations'), findsNothing);
    expect(byKey('recommendation-u18'), findsNothing);
    expect(byKey('friendsList'), findsOneWidget);
    expect(byKey('contact-u13'), findsOneWidget);

    await tester.tap(toggle);
    await settle(tester);
    final button = byKey('recommendFriend-u18');
    await tester.tap(button);
    await tester.tap(button);
    await settle(tester, const Duration(seconds: 2));
    expect(
        h.main.friendRequestsSent.where((r) => r.uid == 'u18'), hasLength(1));
    expect(byKey('recommendationSent-u18'), findsOneWidget);
    expect(byKey('friendsList'), findsOneWidget);
    expect(byKey('contact-u13'), findsOneWidget);

    await tester.tap(toggle);
    await settle(tester);
    expect(byKey('recommendation-u18'), findsNothing);
    expect(byKey('friendsList'), findsOneWidget);
    expect(byKey('contact-u13'), findsOneWidget);
    expect(tester.takeException(), isNull);
    await drain(tester);
  });

  testWidgets('recommendations send a request and mark close friends',
      (tester) async {
    final h = await pumpZalos(tester, size: expanded);
    h.main.contactList.add(const Contact(
        uid: 'u18',
        displayName: 'Nguyễn Bảo Ngọc',
        avatarUrl: '',
        closeFriend: true));
    await _contacts(tester);
    await tapKey(tester, 'recommendationsToggle', scroll: false);
    expect(byKey('recommendations'), findsOneWidget);
    expect(
        find.descendant(
            of: byKey('recommendation-u18'),
            matching: find.bySemanticsLabel('Bạn thân')),
        findsOneWidget);
    expect(byKey('recommendFriend-u18'), findsNothing,
        reason: 'a known friend is not offered a friend request');
    expect(
        find.descendant(
            of: byKey('recommendationFriend-u18'),
            matching: find.text('Bạn bè')),
        findsOneWidget);
    await tapKey(tester, 'recommendFriend-u19', scroll: false);
    expect(h.main.friendRequestsSent.last.uid, 'u19');
    expect(byKey('recommendationSent-u19'), findsOneWidget);
    await drain(tester);
  });

  testWidgets(
      'presence is read on demand, shows online and last seen, typing wins',
      (tester) async {
    final h = await pumpZalos(tester, size: expanded);
    await _contacts(tester);
    expect(h.main.presenceCalls, 1);
    await revealIn(tester, 'friendsList', 'contact-u01');
    expect(find.text('Trực tuyến'), findsWidgets);
    await revealIn(tester, 'friendsList', 'contact-u02');
    expect(find.text('Hoạt động 30 phút trước'), findsOneWidget);
    await tester.pump(const Duration(seconds: 10));
    expect(h.main.presenceCalls, 1, reason: 'presence is never polled');

    await tapKey(tester, 'railTab-messages');
    await openThreadByKey(tester, 'u02');
    await settle(tester);
    expect(find.text('Hoạt động 30 phút trước'), findsOneWidget);
    h.main.emitTyping('u02', 'u02');
    await settle(tester, const Duration(milliseconds: 200));
    expect(find.text('Đang soạn tin...'), findsOneWidget);
    expect(find.text('Hoạt động 30 phút trước'), findsNothing);
    h.main.receive('u02', 'xong rồi');
    await settle(tester, const Duration(milliseconds: 200));
    expect(find.text('Hoạt động 30 phút trước'), findsOneWidget);
    await drain(tester);
  });

  testWidgets('contact card: send from the composer, render, open and preview',
      (tester) async {
    final h = await pumpZalos(tester, size: expanded);
    await openThreadByKey(tester, 'u02');
    await tapKey(tester, 'shareContactButton', scroll: false);
    expect(byKey('contactPicker'), findsOneWidget);
    await tester.enterText(byKey('contactPickerSearch'), 'Lan');
    await settle(tester);
    await tapKey(tester, 'contactPicker-u01', scroll: false);
    await settle(tester);
    expect(h.main.sentCards.last.card.uid, 'u01');
    expect(h.main.sentCards.last.threadId, 'u02');
    final sent = h.main.messages('u02', ThreadType.user).value.last;
    expect(sent.kind, MessageKind.card);
    expect(byKey('contactCard-${sent.id}'), findsOneWidget);
    expect(find.text('Nguyễn Thị Lan'), findsWidgets);
    expect(
        find.textContaining('[Danh thiếp] Nguyễn Thị Lan', findRichText: true),
        findsWidgets);
    await tapKey(tester, 'contactCardOpen-u01', scroll: false);
    expect(h.container.read(openThreadProvider)!.id, 'u01');
    await drain(tester);
  });

  testWidgets('contact card renders at compact with a phone and no avatar',
      (tester) async {
    final h = await pumpZalos(tester, size: compact);
    await h.main.sendCard(
      'u02',
      ThreadType.user,
      const ContactCard(
          uid: 'u19',
          displayName: 'Trần Hữu Phước',
          avatarUrl: '',
          phone: '0900000019'),
    );
    await openThreadByKey(tester, 'u02');
    await settle(tester);
    final card = h.main.messages('u02', ThreadType.user).value.last;
    expect(byKey('contactCard-${card.id}'), findsOneWidget);
    expect(find.text('0900000019'), findsOneWidget);
    expect(tester.takeException(), isNull);
    await drain(tester);
  });

  testWidgets(
      'report: other needs text, success toast, failure keeps the dialog',
      (tester) async {
    final h = await pumpZalos(tester, size: expanded);
    await openThreadByKey(tester, 'g01');
    final peer = h.main
        .messages('g01', ThreadType.group)
        .value
        .firstWhere((m) => m.text == 'Chị Thư ơi mấy giờ chị tới?');
    await _rightClick(tester, byKey('bubble-${peer.id}'));
    await tapKey(tester, 'menu-MessageAction.report', scroll: false);
    expect(byKey('reportDialog'), findsOneWidget);
    await tapKey(tester, 'reportReason-other', scroll: false);
    expect(tester.widget<ZButton>(byKey('reportSubmit')).onPressed, isNull);
    await tester.enterText(byKey('reportContent'), 'Nội dung không phù hợp');
    await tester.pump();
    await tapKey(tester, 'reportSubmit', scroll: false);
    expect(h.main.reports.last.reason, ReportReason.other);
    expect(h.main.reports.last.content, 'Nội dung không phù hợp');
    expect(byKey('reportDialog'), findsNothing);
    expect(find.text('Đã gửi báo cáo'), findsOneWidget);

    h.app.flags.failThreadActions = true;
    await _rightClick(tester, byKey('bubble-${peer.id}'));
    await tapKey(tester, 'menu-MessageAction.report', scroll: false);
    await tapKey(tester, 'reportSubmit', scroll: false);
    expect(byKey('reportError'), findsOneWidget);
    expect(byKey('reportDialog'), findsOneWidget);
    await tapKey(tester, 'reportReason-fraud', scroll: false);
    await tapKey(tester, 'reportSubmit', scroll: false);
    expect(byKey('reportError'), findsOneWidget);
    await drain(tester);
  });

  testWidgets('report is also reachable from conversation info',
      (tester) async {
    await pumpZalos(tester, size: expanded);
    await openThreadByKey(tester, 'g01');
    await tapKey(tester, 'chatInfo');
    await _revealInPane(tester, 'infoPane', 'infoReport');
    await tapKey(tester, 'infoReport');
    expect(byKey('reportDialog'), findsOneWidget);
    await tapKey(tester, 'reportReason-sensitive', scroll: false);
    await tapKey(tester, 'reportSubmit', scroll: false);
    expect(byKey('reportDialog'), findsNothing);
    await drain(tester);
  });

  testWidgets(
      'delete for everyone: group admin can delete another user message',
      (tester) async {
    final app = FakeZalosApp();
    app.fakeLink.session('main').groupAdminIds['g01'] = ['self-main'];
    final h = await pumpZalos(tester, size: expanded, app: app);
    await openThreadByKey(tester, 'g01');
    final peer = h.main
        .messages('g01', ThreadType.group)
        .value
        .firstWhere((m) => !m.isSelf && m.text == 'Mẹ nấu canh chua rồi đó');
    await _rightClick(tester, byKey('bubble-${peer.id}'));
    expect(byKey('menu-MessageAction.deleteForAll'), findsOneWidget);
    await tapKey(tester, 'menu-MessageAction.deleteForAll', scroll: false);
    expect(find.text('Xóa tin nhắn này cho mọi người?'), findsOneWidget);
    await tapKey(tester, 'confirmOk', scroll: false);
    expect(h.main.deletedForAll, contains(peer.id));
    await settle(tester);
    expect(byKey('bubble-${peer.id}'), findsNothing);
    await drain(tester);
  });

  testWidgets(
      'delete for everyone: hidden for group members who are not owner or deputy',
      (tester) async {
    final h = await pumpZalos(tester, size: expanded);
    await openThreadByKey(tester, 'g01');
    final normal = h.main
        .messages('g01', ThreadType.group)
        .value
        .firstWhere((m) => m.text == 'Chị Thư ơi mấy giờ chị tới?');
    await _rightClick(tester, byKey('bubble-${normal.id}'));
    expect(byKey('menu-MessageAction.deleteForAll'), findsNothing);
    await drain(tester);
  });

  testWidgets('delete for everyone: hidden on own messages', (tester) async {
    final app = FakeZalosApp();
    app.fakeLink.session('main').groupAdminIds['g01'] = ['self-main'];
    final h = await pumpZalos(tester, size: expanded, app: app);
    await openThreadByKey(tester, 'g01');
    final own = h.main
        .messages('g01', ThreadType.group)
        .value
        .firstWhere((m) => m.isSelf && m.sendState == SendState.sent);
    await revealIn(tester, 'messageList', 'bubble-${own.id}');
    await _rightClick(tester, byKey('bubble-${own.id}'));
    expect(byKey('menu-MessageAction.deleteForAll'), findsNothing);
    await drain(tester);
  });

  testWidgets('delete for everyone: hidden in one to one chats',
      (tester) async {
    final app = FakeZalosApp();
    app.fakeLink.session('main').groupAdminIds['g01'] = ['self-main'];
    final h = await pumpZalos(tester, size: expanded, app: app);
    await openThreadByKey(tester, 'u02');
    final userPeer = h.main
        .messages('u02', ThreadType.user)
        .value
        .firstWhere((m) => !m.isSelf);
    await revealIn(tester, 'messageList', 'bubble-${userPeer.id}');
    await _rightClick(tester, byKey('bubble-${userPeer.id}'));
    expect(byKey('menu-MessageAction.deleteForAll'), findsNothing);
    await drain(tester);
  });

  testWidgets('delete for everyone: hidden on recalled and system messages',
      (tester) async {
    final h = await pumpZalos(tester, size: expanded);
    await openThreadByKey(tester, 'g01');
    final messages = h.main.messages('g01', ThreadType.group).value;
    final context = tester.element(byKey('messageList'));
    final caps = h.container.read(activeCapsProvider);
    for (final m in [
      messages.firstWhere((m) => m.recalled),
      messages.firstWhere((m) => m.kind == MessageKind.system),
    ]) {
      unawaited(showMessageMenu(context,
          position: const Offset(200, 200),
          m: m,
          own: const {},
          onReact: (_) {},
          caps: caps,
          isGroup: true,
          admin: true));
      await settle(tester);
      expect(byKey('menu-MessageAction.deleteForAll'), findsNothing,
          reason: '${m.kind} recalled=${m.recalled}');
      expect(byKey('menu-MessageAction.delete'), findsOneWidget);
      await tester.tapAt(const Offset(5, 5));
      await settle(tester);
    }
    await drain(tester);
  });

  testWidgets('add friend: a stale lookup does not replace a newer search',
      (tester) async {
    await pumpZalos(tester,
        size: expanded,
        app: FakeZalosApp(latency: const Duration(milliseconds: 600)));
    await _contacts(tester);
    await tapKey(tester, 'addFriendButton');
    await tester.enterText(byKey('addFriendField'), '0900000019');
    await tester.tap(byKey('addFriendSearch'));
    await tester.pump(const Duration(milliseconds: 100));
    expect(byKey('addFriendLoading'), findsOneWidget);

    await tester.tap(_inSheet('addFriendMode', 'Tên Zalo'));
    await tester.pump();
    await tester.enterText(byKey('addFriendField'), 'minhchau');
    await tester.tap(byKey('addFriendSearch'));
    await tester.pump(const Duration(milliseconds: 550));

    expect(byKey('addFriendResult'), findsNothing,
        reason: 'the older lookup must not replace the newer one');
    expect(byKey('addFriendLoading'), findsOneWidget);

    await settle(tester, const Duration(seconds: 2));
    expect(_inSheet('addFriendSheet', 'Lý Minh Châu'), findsWidgets);
    expect(byKey('addFriendAccept'), findsOneWidget);
    await sendKey(tester, LogicalKeyboardKey.escape);
    await drain(tester);
  });

  testWidgets('add friend: send message opens the thread and closes the sheet',
      (tester) async {
    final h = await pumpZalos(tester, size: expanded);
    await _contacts(tester);
    await tapKey(tester, 'addFriendButton');
    await tester.tap(_inSheet('addFriendMode', 'Tên Zalo'));
    await settle(tester);
    await tester.enterText(byKey('addFriendField'), 'minhchau');
    await tester.tap(byKey('addFriendSearch'));
    await settle(tester);
    await tapKey(tester, 'addFriendAccept', scroll: false);
    await settle(tester);
    await tapKey(tester, 'addFriendMessage', scroll: false);
    expect(byKey('addFriendSheet'), findsNothing);
    expect(h.container.read(openThreadProvider)!.id, 'u15');
    expect(tester.takeException(), isNull);
    await drain(tester);
  });

  testWidgets('friend row: block and unblock refresh the friend list',
      (tester) async {
    final h = await pumpZalos(tester, size: expanded);
    await _contacts(tester);

    h.main.contactList.removeWhere((c) => c.uid == 'u05');
    await _openFriendMenu(tester, 'u05');
    await tapKey(tester, 'menu-FriendAction.block', scroll: false);
    await settle(tester);
    expect(h.main.blockedUsers, contains('u05'));
    expect(byKey('contact-u05'), findsNothing);

    await _openFriendMenu(tester, 'u06');
    await tapKey(tester, 'menu-FriendAction.block', scroll: false);
    await settle(tester);
    expect(h.main.blockedUsers, contains('u06'));
    expect(byKey('contact-u06'), findsOneWidget);

    h.main.contactList.removeWhere((c) => c.uid == 'u06');
    await _openFriendMenu(tester, 'u06');
    expect(find.text('Bỏ chặn'), findsOneWidget);
    await tapKey(tester, 'menu-FriendAction.block', scroll: false);
    await settle(tester);
    expect(h.main.unblockedUsers, contains('u06'));
    expect(byKey('contact-u06'), findsNothing);
    await drain(tester);
  });

  testWidgets('friend menu hides share contact without the capability',
      (tester) async {
    await pumpZalos(tester, size: expanded, app: _NoContactCardApp());
    await _contacts(tester);
    await _openFriendMenu(tester, 'u05');
    expect(byKey('menu-FriendAction.share'), findsNothing);
    expect(byKey('menu-FriendAction.block'), findsOneWidget);
    expect(byKey('menu-FriendAction.unfriend'), findsOneWidget);
    await tester.tapAt(const Offset(5, 5));
    await settle(tester);
    await drain(tester);
  });

  testWidgets('recommendations: a double tap sends one request',
      (tester) async {
    final h = await pumpZalos(tester,
        size: expanded,
        app: FakeZalosApp(latency: const Duration(milliseconds: 300)));
    await _contacts(tester);
    await tapKey(tester, 'recommendationsToggle', scroll: false);
    final button = byKey('recommendFriend-u18');
    await tester.ensureVisible(button);
    await tester.pump();
    await tester.tap(button);
    await tester.tap(button);
    await settle(tester, const Duration(seconds: 2));
    expect(
        h.main.friendRequestsSent.where((r) => r.uid == 'u18'), hasLength(1));
    expect(byKey('recommendationSent-u18'), findsOneWidget);
    await drain(tester);
  });

  testWidgets('account switch clears local blocked state and reloads counts',
      (tester) async {
    final app = FakeZalosApp(withOa: true);
    app.fakeLink.session('oa').contactList.removeWhere((c) => c.uid != 'u01');
    final h = await pumpZalos(tester, size: expanded, app: app);
    await _contacts(tester);
    expect(find.text('Bạn bè (14)'), findsOneWidget);

    await _openFriendMenu(tester, 'u05');
    await tapKey(tester, 'menu-FriendAction.block', scroll: false);
    await settle(tester);
    expect(h.main.blockedUsers, contains('u05'));
    await _openFriendMenu(tester, 'u05');
    expect(find.text('Bỏ chặn'), findsOneWidget);
    await tester.tapAt(const Offset(5, 5));
    await settle(tester);

    await tapKey(tester, 'railAccount-oa');
    await settle(tester, const Duration(seconds: 1));
    expect(find.text('Bạn bè (1)'), findsOneWidget);

    await tapKey(tester, 'railAccount-main');
    await settle(tester, const Duration(seconds: 1));
    expect(find.text('Bạn bè (14)'), findsOneWidget);
    await _openFriendMenu(tester, 'u05');
    expect(find.text('Chặn'), findsOneWidget);
    expect(find.text('Bỏ chặn'), findsNothing);
    await tester.tapAt(const Offset(5, 5));
    await settle(tester);
    await drain(tester);
  });

  testWidgets('account switch drops a stale friend count completion',
      (tester) async {
    final app = FakeZalosApp(
        withOa: true, latency: const Duration(milliseconds: 600));
    app.fakeLink.session('oa').contactList.removeWhere((c) => c.uid != 'u01');
    await pumpZalos(tester, size: expanded, app: app);
    await tester.tap(byKey('railTab-contacts'));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 100));

    await tester.tap(byKey('railAccount-oa'));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 550));

    expect(find.text('Bạn bè (14)'), findsNothing,
        reason: 'the previous account count must be dropped');
    expect(find.text('Bạn bè'), findsOneWidget);

    await settle(tester, const Duration(seconds: 2));
    expect(find.text('Bạn bè (1)'), findsOneWidget);
    await drain(tester);
  });

  testWidgets('contacts keep working at 320 px with reduced motion',
      (tester) async {
    await pumpZalos(tester,
        size: const Size(320, 568), textScale: 1.3, reduceMotion: true);
    await _contacts(tester, wide: false);
    await tapKey(tester, 'addFriendButton', scroll: false);
    expect(byKey('addFriendSheet'), findsOneWidget);
    await sendKey(tester, LogicalKeyboardKey.escape);
    expect(byKey('addFriendSheet'), findsNothing);
    expect(tester.takeException(), isNull);
    await drain(tester);
  });
}

/// A link whose active account is missing [AccountCapability.contactCard].
class _NoContactCardLink extends FakeServerLink {
  _NoContactCardLink(super.app,
      {required super.deviceName, required super.role}) {
    _stripped = ValueNotifier(_strip(super.manifest.value));
  }

  late final ValueNotifier<Manifest?> _stripped;

  static Manifest? _strip(Manifest? manifest) {
    if (manifest == null) return null;
    return Manifest(
      server: manifest.server,
      deviceId: manifest.deviceId,
      deviceName: manifest.deviceName,
      role: manifest.role,
      accounts: [
        for (final a in manifest.accounts)
          if (a.slot == 'main')
            AccountSummary(
              slot: a.slot,
              kind: a.kind,
              capabilities: a.capabilities
                  .where((c) => c != AccountCapability.contactCard)
                  .toSet(),
              uid: a.uid,
              displayName: a.displayName,
              avatarUrl: a.avatarUrl,
              status: a.status,
              unread: a.unread,
            )
          else
            a,
      ],
    );
  }

  @override
  ValueListenable<Manifest?> get manifest => _stripped;

  @override
  void dispose() {
    _stripped.dispose();
    super.dispose();
  }
}

class _NoContactCardApp extends FakeZalosApp {
  _NoContactCardApp() {
    _custom = _NoContactCardLink(this,
        deviceName: 'MacBook của Thư', role: DeviceRole.admin);
    _linkNotifier = ValueNotifier(_custom);
  }

  late final _NoContactCardLink _custom;
  late final ValueNotifier<ServerLink?> _linkNotifier;

  @override
  ValueListenable<ServerLink?> get link => _linkNotifier;

  @override
  FakeServerLink get fakeLink => _custom;

  @override
  void dispose() {
    _linkNotifier.dispose();
    _custom.dispose();
    super.dispose();
  }
}
