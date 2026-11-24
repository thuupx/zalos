import 'package:flutter_test/flutter_test.dart';
import 'package:zalos/src/domain/models.dart';
import 'package:zalos/src/domain/services.dart';
import 'package:zalos/src/ui/state/app_state.dart';

import '../support/fake_zalos.dart';
import '../support/harness.dart';

typedef Scene = Future<void> Function(WidgetTester tester, Harness h, bool wide);

class _Spec {
  const _Spec(this.name, this.scene, {this.app});
  final String name;
  final Scene scene;
  final FakeZalosApp Function()? app;
}

Future<void> _images(WidgetTester tester) async {
  for (var i = 0; i < 3; i++) {
    await tester.runAsync(() => Future<void>.delayed(const Duration(milliseconds: 40)));
    await tester.pump(const Duration(milliseconds: 100));
  }
}

Future<void> _me(WidgetTester tester, bool wide) => tapKey(tester, wide ? 'railTab-me' : 'tab-me');

final _specs = <_Spec>[
  _Spec('pairing', (t, h, w) async {}, app: () => FakeZalosApp(paired: false)),
  _Spec('pairing_error', (t, h, w) async {
    h.app.pairError = const PairingException('Could not reach the server at zalos.tailnet.ts.net:8443.', code: PairingErrorCode.unreachable, detail: 'zalos.tailnet.ts.net:8443');
    await t.enterText(byKey('pairUri'), FakeZalosApp.samplePairingUri);
    await tapKey(t, 'pairConnect');
  }, app: () => FakeZalosApp(paired: false)),
  _Spec('threads', (t, h, w) async {}),
  _Spec('threads_loading', (t, h, w) async {}, app: () => FakeZalosApp(empty: true, latency: const Duration(seconds: 1))),
  _Spec('threads_empty', (t, h, w) async => settle(t, const Duration(seconds: 2)), app: () => FakeZalosApp(empty: true)),
  _Spec('threads_search', (t, h, w) async {
    await t.enterText(byKey('threadSearch'), 'nguyen');
    await settle(t);
  }),
  _Spec('chat', (t, h, w) async => openThreadByKey(t, 'g01')),
  _Spec('chat_media', (t, h, w) async {
    await openThreadByKey(t, 'g01');
    await t.drag(byKey('messageList'), const Offset(0, 700));
    await settle(t);
  }),
  _Spec('chat_user', (t, h, w) async {
    await openThreadByKey(t, 'u01');
    h.main.emitTyping('u01', 'u01');
    await settle(t, const Duration(milliseconds: 300));
  }),
  _Spec('chat_composing', (t, h, w) async {
    await openThreadByKey(t, 'g01');
    final list = h.main.messages('g01', ThreadType.group).value;
    h.container.read(openThreadProvider);
    await t.enterText(byKey('composerField'), 'Khoảng 6 giờ con tới nha @');
    await settle(t);
    expect(list, isNotEmpty);
  }),
  _Spec('info', (t, h, w) async {
    await openThreadByKey(t, 'g01');
    await tapKey(t, 'chatInfo');
  }),
  _Spec('contacts', (t, h, w) async => tapKey(t, w ? 'railTab-contacts' : 'tab-contacts')),
  _Spec('me', (t, h, w) async => _me(t, w)),
  _Spec('devices', (t, h, w) async {
    await _me(t, w);
    await tapKey(t, 'linkedDevices');
  }),
  _Spec('add_device', (t, h, w) async {
    await _me(t, w);
    await tapKey(t, 'addDevice');
  }),
  _Spec('login_qr', (t, h, w) async {
    await _me(t, w);
    await tapKey(t, 'addZaloAccount');
    await tapKey(t, 'addPersonal', scroll: false);
    h.link.loginQr!.add(LoginQrImage(await h.main.media('fake://photo/qr')));
    await settle(t);
  }),
  _Spec('vault_waiting', (t, h, w) async {}, app: () => FakeZalosApp(vaultPending: true)),
  _Spec('vault_approve', (t, h, w) async {
    await _me(t, w);
    await tapKey(t, 'vaultApprove-dev-tablet');
  }),
  _Spec('recovery_code', (t, h, w) async {
    await _me(t, w);
    await revealIn(t, 'meList', 'recoveryCodeEntry');
    await tapKey(t, 'recoveryCodeEntry');
    await tapKey(t, 'recoveryReveal');
  }),
];

void main() {
  for (final spec in _specs) {
    for (final entry in sizes.entries) {
      for (final dark in [false, true]) {
        final name = '${spec.name}_${entry.key}_${dark ? 'dark' : 'light'}';
        testWidgets('golden $name', (tester) async {
          final h = await pumpZalos(tester, app: spec.app?.call(), size: entry.value, dark: dark);
          await spec.scene(tester, h, entry.value.width >= 720);
          await _images(tester);
          await expectLater(byKey('appRoot'), matchesGoldenFile('goldens/$name.png'));
          await drain(tester);
        });
      }
    }
  }
}
