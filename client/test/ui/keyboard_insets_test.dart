import 'package:material_ui/material_ui.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:zalos/src/domain/models.dart';

import '../support/fake_zalos.dart';
import '../support/harness.dart';

const _keyboard = 336.0;

FocusNode _focusOf(WidgetTester tester, String key) {
  final finder = byKey(key);
  final widget = tester.widget(finder);
  if (widget is TextField) return widget.focusNode!;
  return tester.widget<TextField>(find.descendant(of: finder, matching: find.byType(TextField))).focusNode!;
}

/// The surface named by [key] stays on screen and above [keyboardTop]; with
/// [hittable] it must also be reachable by a tap.
void _expectAboveKeyboard(WidgetTester tester, String key, double keyboardTop, {bool hittable = true}) {
  final finder = byKey(key);
  final rect = tester.getRect(finder);
  expect(rect.bottom, lessThanOrEqualTo(keyboardTop), reason: '$key stays above the keyboard');
  expect(rect.top, greaterThanOrEqualTo(0), reason: '$key stays on screen');
  if (hittable) expect(finder.hitTestable(), findsOneWidget, reason: '$key is reachable');
}

Future<Harness> _openAddFriend(WidgetTester tester, {required Size size, required bool wide}) async {
  final h = await pumpZalos(tester, size: size, app: FakeZalosApp(latency: const Duration(milliseconds: 50)));
  await tapKey(tester, wide ? 'railTab-contacts' : 'tab-contacts');
  await settle(tester, const Duration(seconds: 1));
  await tapKey(tester, 'addFriendButton');
  expect(byKey('addFriendSheet'), findsOneWidget);
  return h;
}

void main() {
  testWidgets('medium dialog keeps the field and its action above the keyboard', (tester) async {
    final h = await _openAddFriend(tester, size: medium, wide: true);

    tester.view.viewInsets = const FakeViewPadding(bottom: _keyboard);
    await settle(tester);
    final keyboardTop = medium.height - _keyboard;

    await tester.enterText(byKey('addFriendField'), '0900000019');
    await settle(tester);
    _expectAboveKeyboard(tester, 'addFriendField', keyboardTop);
    _expectAboveKeyboard(tester, 'addFriendSearch', keyboardTop);

    await tester.tap(byKey('addFriendSearch'));
    await settle(tester, const Duration(seconds: 2));
    expect(byKey('addFriendSend'), findsOneWidget);

    await tester.ensureVisible(byKey('addFriendSend'));
    await tester.pump();
    _expectAboveKeyboard(tester, 'addFriendSend', keyboardTop);
    await tester.tap(byKey('addFriendSend'));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 100));
    expect(h.main.friendRequestsSent.map((r) => r.uid), contains('u19'));
    expect(byKey('toast'), findsOneWidget);
    _expectAboveKeyboard(tester, 'toast', keyboardTop, hittable: false);

    tester.view.resetViewInsets();
    await settle(tester);
    expect(tester.takeException(), isNull);
    await drain(tester);
  });

  testWidgets('compact sheet keeps the search field and result action above the keyboard', (tester) async {
    final h = await _openAddFriend(tester, size: compact, wide: false);

    tester.view.viewInsets = const FakeViewPadding(bottom: _keyboard);
    await settle(tester);
    final keyboardTop = compact.height - _keyboard;

    await tester.enterText(byKey('addFriendField'), '0900000019');
    await tester.pump();
    final field = _focusOf(tester, 'addFriendField');
    expect(field.hasFocus, isTrue);
    _expectAboveKeyboard(tester, 'addFriendField', keyboardTop);

    await tester.testTextInput.receiveAction(TextInputAction.search);
    await settle(tester, const Duration(seconds: 2));
    expect(field.hasFocus, isFalse, reason: 'starting a search dismisses the keyboard');
    expect(byKey('addFriendSend'), findsOneWidget);

    await tester.ensureVisible(byKey('addFriendSend'));
    await tester.pump();
    _expectAboveKeyboard(tester, 'addFriendSend', keyboardTop);
    await tester.tap(byKey('addFriendSend'));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 100));
    expect(h.main.friendRequestsSent.map((r) => r.uid), contains('u19'));
    expect(byKey('toast'), findsOneWidget);
    _expectAboveKeyboard(tester, 'toast', keyboardTop, hittable: false);

    tester.view.resetViewInsets();
    await settle(tester);
    expect(tester.takeException(), isNull);
    await drain(tester);
  });

  testWidgets('dragging the message list dismisses the composer keyboard', (tester) async {
    await pumpZalos(tester, size: compact);
    await openThreadByKey(tester, 'g01');
    final composer = _focusOf(tester, 'composerField');
    await tester.enterText(byKey('composerField'), 'xin chào');
    await tester.pump();
    expect(composer.hasFocus, isTrue);

    await tester.drag(byKey('messageList'), const Offset(0, 700));
    await settle(tester);
    expect(composer.hasFocus, isFalse, reason: 'dragging the messages dismisses the keyboard');
    await drain(tester);
  });

  testWidgets('escape unfocuses the idle composer but a pending reply consumes it first', (tester) async {
    final h = await pumpZalos(tester, size: expanded);
    await openThreadByKey(tester, 'g01');
    final composer = _focusOf(tester, 'composerField');

    await tester.enterText(byKey('composerField'), 'xin chào');
    await tester.pump();
    expect(composer.hasFocus, isTrue);
    await sendKey(tester, LogicalKeyboardKey.escape);
    expect(composer.hasFocus, isFalse, reason: 'Escape dismisses the hardware keyboard');

    final m = h.main.messages('g01', ThreadType.group).value.last;
    await hover(tester, byKey('bubble-${m.id}'));
    await tapKey(tester, 'hoverReply-${m.id}', scroll: false);
    expect(byKey('replyBar'), findsOneWidget);
    expect(composer.hasFocus, isTrue);
    await sendKey(tester, LogicalKeyboardKey.escape);
    expect(byKey('replyBar'), findsNothing);
    expect(composer.hasFocus, isTrue, reason: 'a pending reply keeps focus and consumes Escape');
    await drain(tester);
  });
}
