import 'package:material_ui/material_ui.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:zalos/src/domain/models.dart';
import 'package:zalos/src/ui/components/avatar.dart';
import 'package:zalos/src/ui/components/pressable.dart';
import 'package:zalos/src/ui/state/app_state.dart';
import 'package:zalos/src/ui/theme/tokens.dart';
import 'package:zalos/src/ui/threads/thread_tile.dart';

import '../support/fake_platform.dart';
import '../support/fake_zalos.dart';
import '../support/harness.dart';

Future<void> _tab(WidgetTester tester, bool wide, String tab) => tapKey(tester, wide ? 'railTab-$tab' : 'tab-$tab');

void main() {
  for (final entry in sizes.entries) {
    final wide = entry.value.width >= 720;
    testWidgets('info pane at ${entry.key}: docked or overlay, members, media, quick actions', (tester) async {
      final h = await pumpZalos(tester, size: entry.value);
      await openThreadByKey(tester, 'g01');
      await tapKey(tester, 'chatHeaderInfo');
      expect(byKey('infoPane'), findsOneWidget);
      if (entry.key == 'expanded') expect(byKey('infoDocked'), findsOneWidget);
      if (entry.key == 'medium') expect(byKey('infoOverlay'), findsOneWidget);
      expect(find.descendant(of: byKey('infoPane'), matching: find.text('4 thành viên')), findsOneWidget);
      await settle(tester);
      expect(byKey('member-u05'), findsOneWidget);
      expect(find.descendant(of: byKey('member-u05'), matching: find.text('Trưởng nhóm')), findsOneWidget);
      expect(find.descendant(of: byKey('member-u05'), matching: find.text('Mẹ')), findsOneWidget);
      expect(byKey('infoMedia-0'), findsOneWidget);

      await tapKey(tester, 'infoMute');
      expect(h.main.threads.value.firstWhere((t) => t.id == 'g01').muted, isTrue);
      await tapKey(tester, 'infoPin');
      expect(h.main.threads.value.firstWhere((t) => t.id == 'g01').pinned, isFalse);

      await tapKey(tester, 'infoSection-members');
      expect(byKey('member-u05'), findsNothing);
      await tapKey(tester, 'infoSection-members');
      await tapKey(tester, 'member-u04');
      expect(byKey('profileSheet'), findsOneWidget);
      await tapKey(tester, 'profileMessage', scroll: false);
      expect(h.container.read(openThreadProvider)!.id, 'u04');
      expect(h.container.read(infoPaneOpenProvider), isFalse);
      if (!wide) expect(byKey('messageList'), findsOneWidget);
      await drain(tester);
    });
  }

  testWidgets('info pane: empty sections, find messages, delete history, user thread', (tester) async {
    final h = await pumpZalos(tester, size: expanded);
    await revealIn(tester, 'threadList', 'thread-u10');
    await openThreadByKey(tester, 'u10');
    await tapKey(tester, 'chatInfo');
    expect(find.text('Chưa có ảnh được chia sẻ'), findsOneWidget);
    expect(find.text('Chưa có file được chia sẻ'), findsOneWidget);
    expect(find.text('Chưa có link được chia sẻ'), findsOneWidget);
    expect(byKey('infoSection-members'), findsNothing);
    await tapKey(tester, 'infoSearch');
    expect(byKey('chatSearchField'), findsOneWidget);
    await tapKey(tester, 'chatSearchClose', scroll: false);
    await tapKey(tester, 'infoDelete');
    await tapKey(tester, 'confirmOk', scroll: false);
    expect(h.main.threads.value.any((t) => t.id == 'u10'), isFalse);
    expect(h.container.read(openThreadProvider), isNull);
    await drain(tester);
  });

  testWidgets('info pane: total member count can exceed the rendered member page', (tester) async {
    final h = await pumpZalos(tester, size: expanded);
    h.main.groupMemberCounts['g01'] = 8;
    // The thread list already fetched this group; refetch with the new total.
    h.container.invalidate(groupInfoProvider((h.main, 'g01')));
    await openThreadByKey(tester, 'g01');
    await tapKey(tester, 'chatHeaderInfo');
    expect(find.descendant(of: byKey('infoPane'), matching: find.text('8 thành viên')), findsOneWidget);
    expect(find.text('THÀNH VIÊN (8)'), findsOneWidget);
    expect(byKey('member-u05'), findsOneWidget);
    expect(byKey('member-u03'), findsOneWidget);
    await drain(tester);
  });

  testWidgets('info pane: member list error can be retried; media opens the viewer', (tester) async {
    final app = FakeZalosApp()..flags.failGroups = true;
    final h = await pumpZalos(tester, size: expanded, app: app);
    await openThreadByKey(tester, 'g03');
    await tapKey(tester, 'chatInfo');
    expect(find.descendant(of: byKey('infoPane'), matching: find.text('Không tải được dữ liệu')), findsOneWidget);
    h.app.flags.failGroups = false;
    await tester.tap(find.descendant(of: byKey('infoPane'), matching: find.text('Thử lại')));
    await settle(tester);
    expect(byKey('member-u02'), findsOneWidget);
    await drain(tester);

    await pumpZalos(tester, size: expanded);
    await openThreadByKey(tester, 'g01');
    await tapKey(tester, 'chatInfo');
    await tapKey(tester, 'infoMedia-0');
    expect(byKey('mediaViewer'), findsOneWidget);
    await drain(tester);
  });

  for (final entry in sizes.entries) {
    final wide = entry.value.width >= 720;
    testWidgets('contacts at ${entry.key}: loading, sections, alias, groups, open chat', (tester) async {
      final h = await pumpZalos(tester, size: entry.value, app: FakeZalosApp(latency: const Duration(milliseconds: 300)));
      await tester.tap(byKey(wide ? 'railTab-contacts' : 'tab-contacts'));
      await tester.pump(const Duration(milliseconds: 100));
      expect(byKey('contactsLoading'), findsOneWidget);
      await settle(tester);
      expect(byKey('friendsList'), findsOneWidget);
      expect(find.text('Bạn bè (14)'), findsOneWidget);
      expect(find.text('Nhóm (4)'), findsOneWidget);
      final letters = tester.widgetList<Text>(find.descendant(of: byKey('friendsList'), matching: find.byWidgetPredicate((w) => w is Text && RegExp(r'^[A-Z#]$').hasMatch(w.data ?? '')))).map((t) => t.data).toList();
      expect(letters.take(3), ['A', 'B', 'C']);
      expect(byKey('letterIndex'), wide ? findsNothing : findsOneWidget);
      expect(byKey('contactsRefresh'), wide ? findsOneWidget : findsNothing);

      await tester.enterText(byKey('contactSearch'), 'me');
      await settle(tester);
      expect(byKey('contact-u05'), findsOneWidget);
      expect(find.descendant(of: byKey('contact-u05'), matching: find.text('Phạm Thị Mai')), findsOneWidget);
      await tester.enterText(byKey('contactSearch'), '');
      await settle(tester);

      await tester.tap(find.text('Nhóm (4)'));
      await settle(tester);
      expect(byKey('groupsList'), findsOneWidget);
      expect(find.descendant(of: byKey('group-g01'), matching: find.text('4 thành viên')), findsOneWidget);
      await tapKey(tester, 'group-g01');
      expect(h.container.read(openThreadProvider)!.id, 'g01');
      expect(byKey('messageList'), findsOneWidget);
      await drain(tester);
    });
  }

  testWidgets('contacts: error with retry, empty states, refresh, letter index', (tester) async {
    final h = await pumpZalos(tester, size: expanded);
    h.app.flags.failContacts = true;
    await _tab(tester, true, 'contacts');
    expect(byKey('contactsError'), findsOneWidget);
    h.app.flags.failContacts = false;
    await tester.tap(find.text('Thử lại'));
    await settle(tester);
    expect(byKey('friendsList'), findsOneWidget);
    await tester.enterText(byKey('contactSearch'), 'khongco');
    await settle(tester);
    expect(find.text('Không tìm thấy kết quả'), findsOneWidget);
    await tapKey(tester, 'contactsRefresh');
    await drain(tester);

    await pumpZalos(tester, app: FakeZalosApp(empty: true));
    await _tab(tester, false, 'contacts');
    expect(byKey('friendsEmpty'), findsOneWidget);
    expect(find.text('Chưa có bạn bè'), findsOneWidget);
    await tester.tap(find.text('Nhóm (0)'));
    await settle(tester);
    expect(byKey('groupsEmpty'), findsOneWidget);
    await drain(tester);

    await pumpZalos(tester, size: const Size(390, 500));
    await _tab(tester, false, 'contacts');
    final box = tester.getRect(byKey('letterIndex'));
    await tester.tapAt(Offset(box.center.dx, box.bottom - 4));
    await settle(tester);
    expect(byKey('contact-u07'), findsOneWidget);
    await drain(tester);
  });

  for (final entry in sizes.entries) {
    final wide = entry.value.width >= 720;
    testWidgets('me at ${entry.key}: sections, theme, language, notifications', (tester) async {
      final platform = FakePlatform();
      final h = await pumpZalos(tester, size: entry.value, platform: platform);
      await _tab(tester, wide, 'me');
      for (final title in ['TÀI KHOẢN', 'THIẾT BỊ']) {
        expect(find.text(title), findsOneWidget);
      }
      expect(find.descendant(of: byKey('meAccount-shop'), matching: find.text('Cần đăng nhập lại')), findsOneWidget);
      expect(find.descendant(of: byKey('meAccount-main'), matching: find.text('Trực tuyến')), findsOneWidget);
      expect(find.descendant(of: byKey('thisDevice'), matching: find.text('Quản trị')), findsOneWidget);
      await revealIn(tester, 'meList', 'fingerprint');
      expect(find.descendant(of: byKey('fingerprint'), matching: find.text('9F2C')), findsOneWidget);
      expect(find.textContaining('được mã hóa bằng khóa chỉ thiết bị của bạn giữ'), findsOneWidget);

      await revealIn(tester, 'meList', 'languageSwitch');
      await tester.tap(find.descendant(of: byKey('themeSwitch'), matching: find.text('Tối')));
      await settle(tester);
      expect(Theme.of(tester.element(byKey('meList'))).brightness, Brightness.dark);
      expect(h.container.read(sharedPrefsProvider).getString('theme_mode'), 'dark');
      await tester.tap(find.descendant(of: byKey('languageSwitch'), matching: find.text('English')));
      await settle(tester);
      expect(find.text('APPEARANCE'), findsOneWidget);
      await tester.tap(find.descendant(of: byKey('languageSwitch'), matching: find.text('Tiếng Việt')));
      await settle(tester);

      await revealIn(tester, 'meList', 'notifyPreview');
      await tapKey(tester, 'notifyPreview');
      expect(h.container.read(notifyPreviewProvider), isFalse);
      await tapKey(tester, 'notifyEnabled');
      expect(h.container.read(notifyEnabledProvider), isFalse);
      await tapKey(tester, 'notifyEnabled');
      expect(platform.notifications.permissionRequests, 1);
      await revealIn(tester, 'meList', 'appVersion');
      expect(find.text('zalos phiên bản 1.0.0'), findsOneWidget);
      await drain(tester);
    });
  }

  testWidgets('me: account menu relogin and remove with typed name; unpair confirm', (tester) async {
    final h = await pumpZalos(tester, size: expanded);
    await _tab(tester, true, 'me');
    await tapKey(tester, 'meAccountMenu-shop');
    await tapKey(tester, 'menu-remove', scroll: false);
    expect(byKey('removeAccountDialog'), findsOneWidget);
    expect(tester.widget<ZButton>(byKey('removeAccountConfirm')).onPressed, isNull);
    await tester.enterText(byKey('removeAccountField'), 'Tiệm Hoa Nhà Thư');
    await tester.pump();
    await tapKey(tester, 'removeAccountConfirm', scroll: false);
    expect(h.link.manifest.value!.accounts.map((a) => a.slot), ['main']);
    expect(byKey('meAccount-shop'), findsNothing);

    await tapKey(tester, 'meAccountMenu-main');
    await tapKey(tester, 'menu-relogin', scroll: false);
    expect(byKey('loginQrDialog'), findsOneWidget);
    await tapKey(tester, 'loginQrClose', scroll: false);
    expect(h.link.loginQrCancelled, isTrue);

    await revealIn(tester, 'meList', 'unpair');
    await tapKey(tester, 'unpair');
    await tapKey(tester, 'confirmCancel', scroll: false);
    expect(byKey('wideShell'), findsOneWidget);
    await tapKey(tester, 'unpair');
    await tapKey(tester, 'confirmOk', scroll: false);
    expect(byKey('pairingScreen'), findsOneWidget);
    await drain(tester);
  });

  testWidgets('zalo QR login: skeleton, image, refresh notice, scanned, done, failure retry', (tester) async {
    final h = await pumpZalos(tester, size: expanded);
    await _tab(tester, true, 'me');
    await tapKey(tester, 'addZaloAccount');
    await tapKey(tester, 'addPersonal', scroll: false);
    expect(byKey('loginQrSkeleton'), findsOneWidget);
    final png = await h.main.media('fake://photo/qr');
    h.link.loginQr!.add(LoginQrImage(png));
    await tester.pump();
    expect(byKey('loginQrImage'), findsOneWidget);
    expect(find.text('Mở Zalo trên điện thoại, quét mã này'), findsOneWidget);
    expect(byKey('loginQrRefreshed'), findsNothing);
    h.link.loginQr!.add(LoginQrImage(png));
    await tester.pump();
    expect(byKey('loginQrRefreshed'), findsOneWidget);
    h.link.loginQr!.add(const LoginQrScanned('Tiệm Hoa Nhà Thư'));
    await tester.pump();
    expect(find.text('Đã quét. Xác nhận trên điện thoại của Tiệm Hoa Nhà Thư'), findsOneWidget);
    h.link.loginQr!.add(const LoginQrFailed('ZcaApiError: Cannot get scan result'));
    await tester.pump();
    expect(byKey('loginQrFailed'), findsOneWidget);
    expect(find.text('Mã đã hết hạn hoặc lượt đăng nhập bị từ chối. Thử lại để lấy mã mới.'), findsOneWidget);
    expect(find.textContaining('ZcaApiError'), findsNothing, reason: 'raw server text is never shown');
    await tapKey(tester, 'loginQrRetry', scroll: false);
    expect(h.link.loginQrStarts, 2);
    expect(byKey('loginQrSkeleton'), findsOneWidget);
    h.link.finishLogin('shop');
    await tester.pump();
    expect(byKey('loginQrDone'), findsOneWidget);
    await tapKey(tester, 'loginQrOpen', scroll: false);
    expect(h.container.read(preferredSlotProvider), 'shop');
    expect(byKey('needsLoginBanner'), findsNothing);
    await drain(tester);
  });

  for (final entry in sizes.entries) {
    final wide = entry.value.width >= 720;
    testWidgets('devices at ${entry.key}: list, acl saved explicitly, revoke', (tester) async {
      final h = await pumpZalos(tester, size: entry.value, app: FakeZalosApp(latency: const Duration(milliseconds: 200)));
      await _tab(tester, wide, 'me');
      await tester.tap(byKey('linkedDevices'));
      await tester.pump(const Duration(milliseconds: 100));
      await tester.pump(const Duration(milliseconds: 50));
      expect(byKey('devicesLoading'), findsOneWidget);
      await settle(tester);
      expect(byKey('device-dev-iphone'), findsOneWidget);
      expect(byKey('device-dev-ipad'), findsNothing);
      expect(find.descendant(of: byKey('device-dev-self'), matching: find.text('Thiết bị này')), findsOneWidget);
      expect(find.descendant(of: byKey('device-dev-iphone'), matching: find.text('Hoạt động 15 phút trước')), findsOneWidget);
      expect(find.descendant(of: byKey('devicesPage'), matching: byKey('vaultRequest-dev-tablet')), findsOneWidget);
      expect(byKey('deviceRevoke-dev-self'), findsNothing);

      await tapKey(tester, 'deviceAcl-dev-iphone');
      expect(tester.widget<ZButton>(byKey('aclSave-dev-iphone')).onPressed, isNull);
      await tapKey(tester, 'acl-dev-iphone-shop');
      expect(h.link.devices.firstWhere((d) => d.id == 'dev-iphone').slots, ['main']);
      await tapKey(tester, 'aclSave-dev-iphone');
      expect(h.link.devices.firstWhere((d) => d.id == 'dev-iphone').slots, ['main', 'shop']);

      await tapKey(tester, 'deviceRevoke-dev-office');
      expect(find.text('Thu hồi quyền của "Windows văn phòng"?'), findsOneWidget);
      await tapKey(tester, 'confirmOk', scroll: false);
      expect(byKey('device-dev-office'), findsNothing);
      await drain(tester);
    });
  }

  testWidgets('devices: error state with retry', (tester) async {
    final h = await pumpZalos(tester, size: expanded);
    h.app.flags.failDevices = true;
    await _tab(tester, true, 'me');
    await tapKey(tester, 'linkedDevices');
    expect(byKey('devicesError'), findsOneWidget);
    h.app.flags.failDevices = false;
    await tester.tap(find.descendant(of: byKey('devicesPage'), matching: find.text('Thử lại')));
    await settle(tester);
    expect(byKey('devicesList'), findsOneWidget);
    await drain(tester);
  });

  testWidgets('add device: role selector, countdown, warning, copy clears clipboard, expiry', (tester) async {
    final clipboard = <String>[];
    tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(SystemChannels.platform, (call) async {
      if (call.method == 'Clipboard.setData') clipboard.add((call.arguments as Map)['text'] as String);
      if (call.method == 'Clipboard.getData') return {'text': clipboard.isEmpty ? '' : clipboard.last};
      return null;
    });
    addTearDown(() => tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(SystemChannels.platform, null));
    final h = await pumpZalos(tester, size: expanded);
    await _tab(tester, true, 'me');
    await tapKey(tester, 'addDevice');
    expect(byKey('pairingQr'), findsOneWidget);
    expect(find.text('Hết hạn sau 5:00'), findsOneWidget);
    expect(byKey('pairingSecretWarning'), findsOneWidget);
    expect(byKey('pairingCopyHint'), findsOneWidget);
    await tester.tap(find.descendant(of: byKey('pairingRole'), matching: find.text('Quản trị')));
    await settle(tester);
    expect(h.link.pairingSeq, 2);
    await tapKey(tester, 'copyPairingUri', scroll: false);
    expect(clipboard.last, contains('r=admin'));
    expect(byKey('pairingCopied'), findsOneWidget);
    await tester.pump(const Duration(seconds: 61));
    expect(clipboard.last, '');

    h.link.pairingTtl = Duration.zero;
    await tester.tap(find.descendant(of: byKey('pairingRole'), matching: find.text('Thành viên')));
    await settle(tester, const Duration(seconds: 2));
    expect(find.text('Mã đã hết hạn'), findsOneWidget);
    h.link.pairingTtl = const Duration(minutes: 5);
    await tapKey(tester, 'pairingNewCode', scroll: false);
    expect(find.text('Hết hạn sau 5:00'), findsOneWidget);
    h.app.flags.failPairingOffer = true;
    await tester.tap(find.descendant(of: byKey('pairingRole'), matching: find.text('Quản trị')));
    await settle(tester);
    expect(byKey('pairingFailed'), findsOneWidget);
    await drain(tester);
  });

  testWidgets('last admin cannot be revoked and the dialog explains why', (tester) async {
    final app = FakeZalosApp();
    final link = app.fakeLink;
    final i = link.devices.indexWhere((d) => d.id == 'dev-office');
    final d = link.devices[i];
    link.devices[i] = DeviceInfo(id: d.id, name: d.name, role: DeviceRole.admin, createdAt: d.createdAt, lastSeenAt: d.lastSeenAt, revoked: false, slots: d.slots);
    final j = link.devices.indexWhere((d) => d.id == 'dev-self');
    link.devices.removeAt(j);
    await pumpZalos(tester, size: expanded, app: app);
    await _tab(tester, true, 'me');
    await tapKey(tester, 'linkedDevices');
    await tapKey(tester, 'deviceRevoke-dev-office');
    expect(byKey('lastAdminDialog'), findsOneWidget);
    await drain(tester);
  });

  testWidgets('connection banners: connecting after 2 s, disconnected, unauthorized with repair', (tester) async {
    final h = await pumpZalos(tester);
    expect(byKey('bannerConnecting'), findsNothing);
    h.link.setState(LinkState.connecting);
    await tester.pump();
    await tester.pump(const Duration(seconds: 1));
    expect(byKey('bannerConnecting'), findsNothing);
    await tester.pump(const Duration(milliseconds: 1200));
    expect(byKey('bannerConnecting'), findsOneWidget);
    h.link.setState(LinkState.disconnected);
    await tester.pump();
    expect(byKey('bannerDisconnected'), findsOneWidget);
    expect(byKey('threadList'), findsOneWidget);
    await openThreadByKey(tester, 'u02');
    expect(byKey('bannerDisconnected'), findsWidgets);
    await tester.enterText(byKey('composerField'), 'gửi khi mất mạng');
    await tester.pump();
    await tapKey(tester, 'sendButton', scroll: false);
    expect(h.main.messages('u02', ThreadType.user).value.last.sendState, SendState.sending);
    h.link.setState(LinkState.unauthorized);
    await tester.pump();
    expect(byKey('bannerUnauthorized'), findsWidgets);
    // The banner slides in before its action can be tapped.
    await settle(tester, ZMotion.medium);
    await tester.tap(find.text('Ghép nối lại').last);
    await settle(tester);
    expect(byKey('pairingScreen'), findsOneWidget);
    await drain(tester);
  });

  testWidgets('account tunnel state also drives the banner; manifest loading state', (tester) async {
    final h = await pumpZalos(tester, size: expanded);
    h.main.setState(LinkState.disconnected);
    await tester.pump();
    expect(byKey('bannerDisconnected'), findsOneWidget);
    h.main.setState(LinkState.connected);
    h.link.manifestHidden = true;
    h.link.publish();
    await tester.pump();
    expect(byKey('shellLoading'), findsOneWidget);
    await drain(tester);
  });

  testWidgets('notifications: hidden threads notify, muted and visible ones do not, activation opens', (tester) async {
    final platform = FakePlatform();
    final h = await pumpZalos(tester, size: expanded, platform: platform);
    expect(platform.notifications.unread, 20);
    await openThreadByKey(tester, 'u02');
    h.main.receive('u02', 'đang xem nên không báo');
    await settle(tester);
    expect(platform.notifications.shown, isEmpty);
    h.main.receive('g02', 'nhóm đã tắt thông báo', from: 'u01');
    await settle(tester);
    expect(platform.notifications.shown, isEmpty);
    h.main.receive('u05', 'Con ăn cơm chưa?');
    await settle(tester);
    expect(platform.notifications.shown.single.title, 'Mẹ');
    expect(platform.notifications.shown.single.body, 'Con ăn cơm chưa?');
    h.main.receive('g03', 'Họp lúc 3 giờ nhé', from: 'u06');
    await settle(tester);
    expect(platform.notifications.shown.last.title, 'Team Marketing Q3');
    expect(platform.notifications.shown.last.body, 'Linh: Họp lúc 3 giờ nhé');
    expect(platform.notifications.unread, h.link.manifest.value!.accounts.fold<int>(0, (n, a) => n + a.unread));

    h.container.read(notifyPreviewProvider.notifier).set(false);
    h.main.receive('u06', 'bí mật');
    await settle(tester);
    expect(platform.notifications.shown.last.body, 'Tin nhắn mới');
    h.container.read(notifyEnabledProvider.notifier).set(false);
    h.main.receive('u07', 'không báo nữa');
    await settle(tester);
    expect(platform.notifications.shown, hasLength(3));

    platform.notifications.activate.add(platform.notifications.shown.first.payload);
    await settle(tester);
    expect(h.container.read(openThreadProvider)!.id, 'u05');
    await drain(tester);
  });

  testWidgets('avatar tap opens the full size picture when the account can fetch it', (tester) async {
    final h = await pumpZalos(tester, size: expanded, app: FakeZalosApp(withOa: true));
    Iterable<String> viewerUrls() => tester.widgetList<MediaImage>(find.descendant(of: byKey('mediaViewer'), matching: find.byType(MediaImage))).map((w) => w.url);

    await openThreadByKey(tester, 'g01');
    await tapKey(tester, 'chatInfo');
    await tapKey(tester, 'member-u04');
    expect(byKey('profileSheet'), findsOneWidget);
    expect(h.main.fullAvatarCalls, 1, reason: 'the sheet prefetches the picture');
    await tapKey(tester, 'profileAvatar', scroll: false);
    expect(byKey('mediaViewer'), findsOneWidget);
    expect(viewerUrls(), contains('fake://photo/avatar-u04-full'));
    expect(byKey('viewerCounter'), findsNothing);
    expect(h.main.fullAvatarCalls, 1);
    await tapKey(tester, 'viewerClose', scroll: false);
    expect(byKey('mediaViewer'), findsNothing);
    expect(byKey('profileSheet'), findsOneWidget);
    await sendKey(tester, LogicalKeyboardKey.escape);
    expect(byKey('profileSheet'), findsNothing);

    await openThreadByKey(tester, 'u02');
    expect(byKey('infoPane'), findsOneWidget);
    h.app.flags.failMedia.add('fake://photo/avatar-u02-full');
    await tapKey(tester, 'infoAvatar');
    expect(viewerUrls(), contains('fake://photo/avatar-u02-full'));
    expect(h.main.fullAvatarCalls, 2);
    expect(byKey('viewerImageFailed'), findsOneWidget, reason: 'a failed picture is a compact notice on the dark viewer');
    expect(tester.getSize(byKey('viewerImageFailed')).width, lessThan(400));
    await tapKey(tester, 'viewerClose', scroll: false);

    // An OA cannot fetch full size pictures and its threads have no list
    // avatar here, so the info pane shows a plain avatar.
    await tapKey(tester, 'railAccount-oa');
    await openThreadByKey(tester, 'u06');
    await tapKey(tester, 'chatInfo');
    expect(byKey('infoPane'), findsOneWidget);
    expect(byKey('infoAvatar'), findsNothing);
    expect(h.link.session('oa').fullAvatarCalls, 0);
    await drain(tester);
  });
}
