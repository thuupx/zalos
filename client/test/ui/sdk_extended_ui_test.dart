import 'package:flutter/widgets.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:zalos/src/domain/models.dart';
import 'package:zalos/src/ui/theme/z_icons.dart';

import '../support/harness.dart';

Future<void> _closeDialog(WidgetTester tester) async {
  await tester.tap(find.byIcon(ZIcons.close).last);
  await settle(tester);
}

void main() {
  testWidgets('ContactsPane Groups tab creates group cleanly', (tester) async {
    final h = await pumpZalos(tester, size: expanded);

    await tapKey(tester, 'railTab-contacts', scroll: false);
    final groupsSegment = find.textContaining('Nhóm');
    expect(groupsSegment, findsOneWidget);
    await tester.tap(groupsSegment);
    await settle(tester);

    expect(byKey('createGroupButton'), findsOneWidget);
    await tapKey(tester, 'createGroupButton', scroll: false);
    expect(byKey('createGroupSheet'), findsOneWidget);

    await tester.enterText(byKey('createGroupName'), 'Nhóm Dự Án Mới');
    await tapKey(tester, 'pickMember-u01', scroll: true);
    await tapKey(tester, 'createGroupSubmit', scroll: false);
    await settle(tester);

    final created = await h.main.groups();
    expect(created.any((g) => g.name == 'Nhóm Dự Án Mới'), isTrue);

    await drain(tester);
  });

  testWidgets('InfoPane manages group, opens media store, E2EE, and user QR', (tester) async {
    final h = await pumpZalos(tester, size: compact);

    // 1. Open Group Info -> Manage Group + Media Store + E2EE
    await openThreadByKey(tester, 'g01');
    await tapKey(tester, 'chatInfo', scroll: false);

    final infoScroll = find.descendant(
      of: byKey('infoPane'),
      matching: find.byType(Scrollable),
    );
    await tester.scrollUntilVisible(byKey('infoManageGroup'), 200, scrollable: infoScroll);
    expect(byKey('infoManageGroup'), findsOneWidget);

    await tapKey(tester, 'infoManageGroup', scroll: true);
    expect(byKey('groupManageSheet'), findsOneWidget);
    await tester.enterText(byKey('manageGroupNameField'), 'Gia Đình Zalos');
    await tapKey(tester, 'manageGroupRenameButton', scroll: false);
    await tapKey(tester, 'settingLockSend', scroll: true);
    final infoAfter = await h.main.groupInfo('g01');
    expect(infoAfter.name, 'Gia Đình Zalos');
    await _closeDialog(tester);

    // 2. Open Media Store
    await tester.scrollUntilVisible(byKey('infoMediaStore'), 200, scrollable: infoScroll);
    expect(byKey('infoMediaStore'), findsOneWidget);
    await tapKey(tester, 'infoMediaStore', scroll: true);
    expect(byKey('mediaStoreSheet'), findsOneWidget);
    await _closeDialog(tester);

    // 3. Open E2EE sheet and toggle
    await tester.scrollUntilVisible(byKey('infoE2ee'), 200, scrollable: infoScroll);
    expect(byKey('infoE2ee'), findsOneWidget);
    await tapKey(tester, 'infoE2ee', scroll: true);
    expect(byKey('e2eeStatusSheet'), findsOneWidget);
    await tapKey(tester, 'e2eeEnableSwitch', scroll: false);
    expect(await h.main.e2eeCheckCompatible('g01', ThreadType.group), isTrue);
    await _closeDialog(tester);

    // 4. Open Pinned Board & delete note if present
    await tester.scrollUntilVisible(byKey('infoPinnedBoard'), -200, scrollable: infoScroll);
    await tapKey(tester, 'infoPinnedBoard', scroll: true);
    expect(byKey('pinnedBoardSheet'), findsOneWidget);
    final deleteNotes = find.byWidgetPredicate(
      (w) => w.key is ValueKey<String> && (w.key! as ValueKey<String>).value.startsWith('deleteNote-'),
    );
    if (deleteNotes.evaluate().isNotEmpty) {
      await tester.tap(deleteNotes.first);
      await settle(tester);
    }
    await _closeDialog(tester);

    // Go back and open 1:1 user thread for User QR
    await tapKey(tester, 'infoBack', scroll: false);
    await tapKey(tester, 'chatBack', scroll: false);
    await openThreadByKey(tester, 'u01');
    await tapKey(tester, 'chatInfo', scroll: false);
    final userInfoScroll = find.descendant(
      of: byKey('infoPane'),
      matching: find.byType(Scrollable),
    );
    await tester.scrollUntilVisible(byKey('infoUserQr'), 200, scrollable: userInfoScroll);
    await tapKey(tester, 'infoUserQr', scroll: true);
    expect(byKey('userQrSheet'), findsOneWidget);
    expect(find.textContaining('u01'), findsWidgets);
    await _closeDialog(tester);

    await drain(tester);
  });

  testWidgets('MePane Profile Edit, Zalo Settings, Blocked Users, and Business Tools sheets work', (tester) async {
    final h = await pumpZalos(tester, size: expanded);
    await tapKey(tester, 'railTab-me', scroll: false);

    final meScroll = find.descendant(
      of: byKey('meList'),
      matching: find.byType(Scrollable),
    );
    await tester.scrollUntilVisible(byKey('meBusinessTools'), 200, scrollable: meScroll);

    expect(byKey('meEditProfile'), findsOneWidget);
    expect(byKey('meZaloSettings'), findsOneWidget);
    expect(byKey('meBlockedUsers'), findsOneWidget);
    expect(byKey('meBusinessTools'), findsOneWidget);

    // Edit profile
    await tapKey(tester, 'meEditProfile', scroll: true);
    expect(byKey('editProfileSheet'), findsOneWidget);
    await tester.enterText(byKey('profileNameField'), 'Minh Thư Zalos');
    await tester.enterText(byKey('profileBioField'), 'Bio cập nhật');
    await tapKey(tester, 'editProfileSave', scroll: false);
    final profile = await h.main.fetchProfile();
    expect(profile.displayName, 'Minh Thư Zalos');
    expect(profile.bio, 'Bio cập nhật');

    // Zalo settings
    await tapKey(tester, 'meZaloSettings', scroll: true);
    expect(byKey('zaloSettingsSheet'), findsOneWidget);
    await tapKey(tester, 'zaloFindPhoneSwitch', scroll: false);
    final settings = await h.main.zaloSettings();
    expect(settings['allow_find_phone'], 0);
    await _closeDialog(tester);

    // Blocked users
    await tapKey(tester, 'meBlockedUsers', scroll: true);
    expect(byKey('blockedUsersSheet'), findsOneWidget);
    await _closeDialog(tester);

    // Business Tools
    await tapKey(tester, 'meBusinessTools', scroll: true);
    expect(byKey('businessToolsSheet'), findsOneWidget);
    await tester.enterText(byKey('autoReplyInput'), 'Shop mở cửa 8h-22h');
    await tapKey(tester, 'addAutoReplyButton', scroll: false);
    final ars = await h.main.autoReplies();
    expect(ars.any((r) => r.content == 'Shop mở cửa 8h-22h'), isTrue);
    await _closeDialog(tester);

    await drain(tester);
  });

  testWidgets('OA account hides new extended personal-only entries', (tester) async {
    final h = await pumpZalos(tester, size: expanded);
    h.app.fakeLink.setCapabilities('main', const {});
    await settle(tester);

    await tapKey(tester, 'railTab-me', scroll: false);
    expect(byKey('meEditProfile'), findsNothing);
    expect(byKey('meZaloSettings'), findsNothing);
    expect(byKey('meBlockedUsers'), findsNothing);
    expect(byKey('meBusinessTools'), findsNothing);

    await tapKey(tester, 'railTab-messages', scroll: false);
    await openThreadByKey(tester, 'u01');
    await tapKey(tester, 'chatInfo', scroll: false);
    expect(byKey('infoMediaStore'), findsNothing);
    expect(byKey('infoE2ee'), findsNothing);
    expect(byKey('infoUserQr'), findsNothing);

    await drain(tester);
  });
}
