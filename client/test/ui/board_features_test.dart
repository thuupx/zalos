import 'package:flutter_test/flutter_test.dart';
import 'package:material_ui/material_ui.dart';
import 'package:zalos/src/domain/models.dart';

import '../support/harness.dart';

Future<void> _openGroup(WidgetTester tester, {String id = 'g01'}) async {
  await openThreadByKey(tester, id);
}

Future<void> _ensureInfoPane(WidgetTester tester) async {
  if (byKey('infoPane').evaluate().isEmpty) {
    await tapKey(tester, 'chatInfo', scroll: false);
  }
}

void main() {
  testWidgets('pin message shows PinnedBar and unpin removes it', (tester) async {
    final h = await pumpZalos(tester, size: compact);
    await _openGroup(tester);

    // Long-press the latest visible message to open context menu and pin it.
    final session = h.main;
    final msgs = session.messages('g01', ThreadType.group).value;
    final target = msgs.lastWhere((m) => m.kind == MessageKind.text && !m.recalled);

    final bubble = find.text(target.text!).last;
    expect(bubble, findsOneWidget);
    await tester.longPress(bubble);
    await settle(tester);

    await tester.tap(find.text('Ghim tin nhắn').last);
    await settle(tester);

    expect(byKey('pinnedBar'), findsOneWidget);

    // Open pinned board sheet and unpin.
    await tapKey(tester, 'pinnedBarMore', scroll: false);
    expect(byKey('pinnedBoardSheet'), findsOneWidget);

    final pins = await session.listPins('g01', ThreadType.group);
    expect(pins.items, hasLength(1));

    await tapKey(tester, 'unpinItem-${pins.items.first.id}', scroll: false);

    // Close modal and verify PinnedBar disappears.
    Navigator.of(tester.element(byKey('pinnedBoardSheet'))).pop();
    await settle(tester);
    expect(byKey('pinnedBar'), findsNothing);
    await drain(tester);
  });

  testWidgets('create poll, vote, add option, and lock poll in group', (tester) async {
    await pumpZalos(tester, size: expanded);
    await _openGroup(tester);

    // Open composer More menu -> Create Poll
    await tapKey(tester, 'composerMore', scroll: false);
    await tester.tap(find.text('Tạo bình chọn').last);
    await settle(tester);
    expect(byKey('createPollSheet'), findsOneWidget);

    await tester.enterText(byKey('pollQuestionField'), 'Cuối tuần đi đâu?');
    await tester.enterText(byKey('pollOptionField-0'), 'Đà Lạt');
    await tester.enterText(byKey('pollOptionField-1'), 'Vũng Tàu');
    await tapKey(tester, 'createPollSubmit', scroll: false);

    // Open InfoPane -> Pinned Board -> switch to Board tab -> open poll detail
    await _ensureInfoPane(tester);
    await tester.dragUntilVisible(byKey('infoPinnedBoard'), byKey('infoPane'), const Offset(0, -200));
    await tapKey(tester, 'infoPinnedBoard', scroll: false);
    expect(byKey('pinnedBoardSheet'), findsOneWidget);

    await tester.tap(find.text('Bảng tin').last);
    await settle(tester);
    await tester.tap(find.text('Cuối tuần đi đâu?').last);
    await settle(tester);

    expect(byKey('pollDetailSheet'), findsOneWidget);

    // Vote on option 1
    await tester.tap(find.text('Đà Lạt').last);
    await settle(tester);
    await tapKey(tester, 'pollVoteSubmit', scroll: false);

    // Add a new option
    await tester.enterText(byKey('pollNewOptionInput'), 'Phú Quốc');
    await tapKey(tester, 'pollAddOptionSubmit', scroll: false);
    expect(find.text('Phú Quốc'), findsOneWidget);

    // Lock the poll
    await tapKey(tester, 'pollLockButton', scroll: false);
    await tester.tap(find.text('Khóa bình chọn').last);
    await settle(tester);
    expect(find.text('Đã kết thúc'), findsAtLeastNWidgets(1));
    await drain(tester);
  });

  testWidgets('create group note and conversation reminder', (tester) async {
    await pumpZalos(tester, size: expanded);
    await _openGroup(tester);

    // Create note via composer More menu
    await tapKey(tester, 'composerMore', scroll: false);
    await tester.tap(find.text('Tạo ghi chú').last);
    await settle(tester);
    expect(byKey('createNoteSheet'), findsOneWidget);

    await tester.enterText(byKey('noteTitleField'), 'Nhớ mang theo giấy tờ');
    await tapKey(tester, 'createNoteSubmit', scroll: false);

    // Default pin=true so PinnedBar appears immediately
    expect(byKey('pinnedBar'), findsOneWidget);

    // Create reminder via composer More menu
    await tapKey(tester, 'composerMore', scroll: false);
    await tester.tap(find.text('Tạo nhắc hẹn').last);
    await settle(tester);
    expect(byKey('createReminderSheet'), findsOneWidget);

    await tester.enterText(byKey('reminderTitleField'), 'Họp giao ban');
    await tapKey(tester, 'createReminderSubmit', scroll: false);

    // Open Reminders sheet from InfoPane and verify it appears
    await _ensureInfoPane(tester);
    await tester.dragUntilVisible(byKey('infoReminders'), byKey('infoPane'), const Offset(0, -200));
    await tapKey(tester, 'infoReminders', scroll: false);
    expect(byKey('remindersSheet'), findsOneWidget);
    expect(find.text('Họp giao ban'), findsOneWidget);
    await drain(tester);
  });
}
