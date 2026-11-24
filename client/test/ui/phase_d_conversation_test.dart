import 'package:flutter/gestures.dart' show kSecondaryButton;
import 'package:material_ui/material_ui.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:zalos/src/ui/theme/z_icons.dart';
import 'package:zalos/src/domain/models.dart';

import '../support/fake_zalos.dart';
import '../support/harness.dart';

Thread _thread(Harness h, String id) => h.main.threads.value.firstWhere((t) => t.id == id);

Future<void> _openMenu(WidgetTester tester, String id) async {
  await tester.tap(byKey('thread-$id'), buttons: kSecondaryButton);
  await settle(tester);
}

Future<void> _openInfo(WidgetTester tester, String id) async {
  await openThreadByKey(tester, id);
  await tapKey(tester, 'chatInfo');
}

TextField _pinField(WidgetTester tester) =>
    tester.widget<TextField>(find.descendant(of: byKey('hiddenPinField'), matching: find.byType(TextField)));

void main() {
  testWidgets('archive: ordinary rows archive, the Archived filter restores and unarchives', (tester) async {
    final h = await pumpZalos(tester, size: expanded);
    expect(byKey('thread-u02'), findsOneWidget);

    await _openMenu(tester, 'u02');
    await tapKey(tester, 'menu-ThreadMenuAction.archive', scroll: false);
    expect(_thread(h, 'u02').archived, isTrue);
    expect(byKey('thread-u02'), findsNothing);

    await tapKey(tester, 'filter-archived');
    expect(byKey('thread-u02'), findsOneWidget);
    await _openMenu(tester, 'u02');
    expect(find.text('Bỏ lưu trữ hội thoại'), findsOneWidget);
    await tapKey(tester, 'menu-ThreadMenuAction.archive', scroll: false);
    expect(_thread(h, 'u02').archived, isFalse);
    expect(byKey('thread-u02'), findsNothing);
    expect(byKey('threadsEmptyArchived'), findsOneWidget);

    await tapKey(tester, 'filter-all');
    expect(byKey('thread-u02'), findsOneWidget);
    await drain(tester);
  });

  testWidgets('hidden gate is a local visibility confirmation, not a PIN check', (tester) async {
    final h = await pumpZalos(tester, size: expanded);
    await _openMenu(tester, 'u02');
    await tapKey(tester, 'menu-ThreadMenuAction.hide', scroll: false);
    expect(find.text('Ẩn hội thoại "Trần Quốc Bảo"?'), findsOneWidget);
    await tapKey(tester, 'confirmOk', scroll: false);
    expect(_thread(h, 'u02').hidden, isTrue);
    expect(byKey('thread-u02'), findsNothing);

    await tapKey(tester, 'hiddenEntry');
    expect(byKey('hiddenGate'), findsOneWidget);
    expect(byKey('hiddenGateBody'), findsOneWidget);
    expect(find.textContaining('không thể kiểm tra PIN Zalo'), findsOneWidget);
    expect(find.descendant(of: byKey('hiddenGate'), matching: find.byType(TextField)), findsNothing);

    await tapKey(tester, 'hiddenGateConfirm', scroll: false);
    expect(byKey('hiddenRow-u02'), findsOneWidget);
    await tapKey(tester, 'hiddenUnhide-u02', scroll: false);
    expect(_thread(h, 'u02').hidden, isFalse);
    expect(byKey('hiddenEmpty'), findsOneWidget);

    // A rejected write still clears the field at once.
    h.app.flags.failThreadActions = true;
    await tester.enterText(byKey('hiddenPinField'), '1234');
    await tester.pump();
    await tapKey(tester, 'hiddenPinSave', scroll: false);
    expect(h.main.hiddenPinSets, 0);
    expect(_pinField(tester).controller!.text, isEmpty);

    h.app.flags.failThreadActions = false;
    await tester.enterText(byKey('hiddenPinField'), '1234');
    await tester.pump();
    await tapKey(tester, 'hiddenPinSave', scroll: false);
    expect(h.main.hiddenPinSets, 1);
    expect(h.main.hiddenPinSet, isTrue);
    expect(byKey('hiddenPinReset'), findsOneWidget);
    expect(find.text('1234'), findsNothing);

    await tapKey(tester, 'hiddenPinReset', scroll: false);
    await tapKey(tester, 'confirmOk', scroll: false);
    expect(h.main.hiddenPinSet, isFalse);
    expect(byKey('hiddenPinField'), findsOneWidget);
    await drain(tester);
  });

  testWidgets('labels: assign, conflict reload, create, rename and delete', (tester) async {
    final h = await pumpZalos(tester, size: expanded);
    await _openInfo(tester, 'u02');
    expect(byKey('infoLabel-2'), findsOneWidget);

    await tapKey(tester, 'infoLabels');
    expect(byKey('labelsSheet'), findsOneWidget);
    expect(byKey('labelAssign-1'), findsOneWidget);
    expect(byKey('labelAssign-2'), findsOneWidget);
    expect(byKey('labelAssign-3'), findsOneWidget);

    await tapKey(tester, 'labelAssign-1');
    expect(h.main.labelList.firstWhere((label) => label.id == 1).conversations, contains('u02'));
    expect(h.main.labelsVersion, 5);

    h.main.labelsVersion = 20;
    await tapKey(tester, 'labelAssign-3');
    expect(byKey('labelsConflict'), findsOneWidget);
    expect(h.main.labelList, hasLength(3));
    expect(h.main.labelList.firstWhere((label) => label.id == 1).conversations, contains('u02'));
    expect(h.main.labelList.firstWhere((label) => label.id == 3).conversations, isNot(contains('u02')));

    await tapKey(tester, 'labelAssign-3');
    expect(byKey('labelsConflict'), findsNothing);
    expect(h.main.labelsVersion, 21);
    expect(h.main.labelList.firstWhere((label) => label.id == 3).conversations, contains('u02'));

    await tester.enterText(byKey('labelCreateField'), 'Ưu tiên');
    await tester.pump();
    await tapKey(tester, 'labelCreateButton', scroll: false);
    final created = h.main.labelList.firstWhere((label) => label.text == 'Ưu tiên');
    expect(created.conversations, contains('u02'));

    await tapKey(tester, 'labelRename-${created.id}');
    expect(byKey('labelRenameDialog'), findsOneWidget);
    await tester.enterText(byKey('labelRenameField'), 'Quan trọng');
    await tester.pump();
    await tapKey(tester, 'labelRenameSave', scroll: false);
    expect(h.main.labelList.any((label) => label.text == 'Quan trọng'), isTrue);

    final renamed = h.main.labelList.firstWhere((label) => label.text == 'Quan trọng');
    await tapKey(tester, 'labelDelete-${renamed.id}');
    await tapKey(tester, 'confirmOk', scroll: false);
    expect(h.main.labelList.any((label) => label.text == 'Quan trọng'), isFalse);
    await drain(tester);
  });

  testWidgets('auto-delete: current value is shown and each TTL is applied', (tester) async {
    final h = await pumpZalos(tester, size: expanded);
    await _openInfo(tester, 'u02');
    expect(find.descendant(of: byKey('infoAutoDelete'), matching: find.text('Tắt')), findsOneWidget);

    await tapKey(tester, 'infoAutoDelete');
    expect(byKey('autoDeleteSheet'), findsOneWidget);
    expect(find.descendant(of: byKey('autoDeleteSheet'), matching: find.textContaining('hết hạn trên Zalo')), findsOneWidget);

    await tapKey(tester, 'autoDelete-604800000', scroll: false);
    expect(_thread(h, 'u02').autoDeleteTtl, 604800000);
    expect(byKey('autoDeleteSheet'), findsNothing);
    expect(find.descendant(of: byKey('infoAutoDelete'), matching: find.text('7 ngày')), findsOneWidget);
    expect(find.descendant(of: byKey('thread-u02'), matching: find.byIcon(ZIcons.timer)), findsOneWidget);

    await tapKey(tester, 'infoAutoDelete');
    expect(find.descendant(of: byKey('autoDelete-604800000'), matching: find.byIcon(ZIcons.check)), findsOneWidget);
    await tapKey(tester, 'autoDelete-0', scroll: false);
    expect(_thread(h, 'u02').autoDeleteTtl, 0);
    expect(find.descendant(of: byKey('infoAutoDelete'), matching: find.text('Tắt')), findsOneWidget);
    await drain(tester);
  });

  testWidgets('Zalo devices: read-only master, current and companions, then unsupported', (tester) async {
    await pumpZalos(tester, size: expanded);
    await tapKey(tester, 'railTab-me');
    await tapKey(tester, 'zaloDevicesEntry');
    expect(byKey('zaloDevicesSheet'), findsOneWidget);
    expect(byKey('zaloDevice-masterUnknown'), findsOneWidget);
    expect(byKey('zaloDevice-zd-1'), findsOneWidget);
    expect(byKey('zaloDevice-zd-2'), findsOneWidget);
    expect(find.text('iPhone của Thư'), findsOneWidget);
    expect(find.text('Windows văn phòng'), findsOneWidget);
    expect(find.text('Phiên này'), findsOneWidget);
    expect(find.text('object(3)'), findsWidgets);
    expect(find.text('zd-1'), findsNothing);
    expect(find.text('zd-2'), findsNothing);
    expect(find.text('self-main'), findsNothing);
    expect(byKey('zaloDevicesReadOnly'), findsOneWidget);
    await sendKey(tester, LogicalKeyboardKey.escape);
    await drain(tester);

    await pumpZalos(tester, size: expanded, app: FakeZalosApp(withOa: true), prefs: {'active_slot': 'oa'});
    await tapKey(tester, 'railTab-me');
    await tapKey(tester, 'zaloDevicesEntry');
    expect(byKey('zaloDevicesUnsupported'), findsOneWidget);
    expect(byKey('zaloDevicesEmpty'), findsNothing);
    await drain(tester);
  });
}
