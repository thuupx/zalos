import 'package:material_ui/material_ui.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:zalos/src/domain/models.dart';

import '../support/fake_zalos.dart';
import '../support/harness.dart';

typedef Scene = Future<void> Function(WidgetTester tester, Harness h, bool wide);

Future<void> _me(WidgetTester t, bool w) => tapKey(t, w ? 'railTab-me' : 'tab-me');

final Map<String, (FakeZalosApp Function()?, Scene)> _scenes = {
  'pairing': (() => FakeZalosApp(paired: false), (t, h, w) async {}),
  'vault waiting': (() => FakeZalosApp(vaultPending: true), (t, h, w) async {}),
  'threads': (null, (t, h, w) async {}),
  'threads empty': (() => FakeZalosApp(empty: true), (t, h, w) async => settle(t, const Duration(seconds: 2))),
  'search results': (null, (t, h, w) async {
    await t.enterText(byKey('threadSearch'), 'nguyen');
    FocusManager.instance.primaryFocus?.unfocus();
    await settle(t);
  }),
  'chat group': (null, (t, h, w) async => openThreadByKey(t, 'g01')),
  'chat media': (null, (t, h, w) async {
    await openThreadByKey(t, 'g01');
    await t.drag(byKey('messageList'), const Offset(0, 700));
    await settle(t);
  }),
  'chat with reply and attachments': (null, (t, h, w) async {
    await openThreadByKey(t, 'g01');
    final list = h.main.messages('g01', ThreadType.group).value;
    await t.longPress(byKey('bubble-${list.last.id}'));
    await settle(t);
    if (byKey('menu-MessageAction.reply').evaluate().isNotEmpty) await tapKey(t, 'menu-MessageAction.reply', scroll: false);
    await t.enterText(byKey('composerField'), 'Dạ con tới liền @');
    await settle(t);
  }),
  'info pane': (null, (t, h, w) async {
    await openThreadByKey(t, 'g01');
    await tapKey(t, 'chatInfo');
  }),
  'contacts': (null, (t, h, w) async => tapKey(t, w ? 'railTab-contacts' : 'tab-contacts')),
  'me': (null, (t, h, w) async => _me(t, w)),
  'me bottom': (null, (t, h, w) async {
    await _me(t, w);
    await revealIn(t, 'meList', 'appVersion');
  }),
  'devices': (null, (t, h, w) async {
    await _me(t, w);
    await revealIn(t, 'meList', 'linkedDevices');
    await tapKey(t, 'linkedDevices');
    await tapKey(t, 'deviceAcl-dev-iphone');
  }),
  'add device': (null, (t, h, w) async {
    await _me(t, w);
    await revealIn(t, 'meList', 'addDevice');
    await tapKey(t, 'addDevice');
  }),
  'login qr': (null, (t, h, w) async {
    await _me(t, w);
    await tapKey(t, 'addZaloAccount');
    await tapKey(t, 'addPersonal', scroll: false);
    h.link.loginQr!.add(const LoginQrScanned('Tiệm Hoa Nhà Thư'));
    await settle(t);
  }),
  'approve dialog': (null, (t, h, w) async {
    await _me(t, w);
    await tapKey(t, 'vaultApprove-dev-tablet');
  }),
};

void main() {
  for (final scene in _scenes.entries) {
    for (final dark in [false, true]) {
      for (final size in {'compact': compact, 'expanded': expanded}.entries) {
        testWidgets('guidelines: ${scene.key} ${size.key} ${dark ? 'dark' : 'light'}', (tester) async {
          final wide = size.value.width >= 720;
          final h = await pumpZalos(tester, app: scene.value.$1?.call(), size: size.value, dark: dark);
          await scene.value.$2(tester, h, wide);
          await settle(tester);
          await expectLater(tester, meetsGuideline(textContrastGuideline));
          await expectLater(tester, meetsGuideline(labeledTapTargetGuideline));
          if (!wide) await expectLater(tester, meetsGuideline(iOSTapTargetGuideline));
          await drain(tester);
        });
      }
    }
  }

  for (final scene in _scenes.entries) {
    testWidgets('no overflow at 320 px and text scale 1.3: ${scene.key}', (tester) async {
      final h = await pumpZalos(tester, app: scene.value.$1?.call(), size: const Size(320, 568), textScale: 1.3);
      await scene.value.$2(tester, h, false);
      await settle(tester);
      expect(tester.takeException(), isNull);
      await drain(tester);
      final h2 = await pumpZalos(tester, app: scene.value.$1?.call(), size: medium, textScale: 1.3, dark: true);
      await scene.value.$2(tester, h2, true);
      await settle(tester);
      expect(tester.takeException(), isNull);
      await drain(tester);
    });
  }

  testWidgets('text scale is clamped at 1.3', (tester) async {
    await pumpZalos(tester, textScale: 2.5);
    final context = tester.element(byKey('compactShell'));
    expect(MediaQuery.textScalerOf(context).scale(10), 13);
    await drain(tester);
  });
}
