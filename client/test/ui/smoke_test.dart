import 'package:flutter_test/flutter_test.dart';

import '../support/fake_zalos.dart';
import '../support/harness.dart';

void main() {
  for (final entry in sizes.entries) {
    for (final dark in [false, true]) {
      testWidgets('walks every pane at ${entry.key} ${dark ? 'dark' : 'light'}', (tester) async {
        final wide = entry.value.width >= 720;
        await pumpZalos(tester, size: entry.value, dark: dark);
        expect(byKey(wide ? 'wideShell' : 'compactShell'), findsOneWidget);
        await openThreadByKey(tester, 'g01');
        expect(byKey('messageList'), findsOneWidget);
        await tapKey(tester, 'chatInfo');
        expect(byKey('infoPane'), findsOneWidget);
        await tapKey(tester, wide ? 'infoClose' : 'infoBack');
        if (!wide) await tapKey(tester, 'chatBack');
        await tapKey(tester, wide ? 'railTab-contacts' : 'tab-contacts');
        expect(byKey('friendsList'), findsOneWidget);
        await tapKey(tester, wide ? 'railTab-me' : 'tab-me');
        expect(byKey('meList'), findsOneWidget);
        await tapKey(tester, 'linkedDevices');
        expect(byKey('devicesList'), findsOneWidget);
        await drain(tester);
      });
    }
  }

  testWidgets('pairing and vault screens build', (tester) async {
    await pumpZalos(tester, app: FakeZalosApp(paired: false));
    expect(byKey('pairingScreen'), findsOneWidget);
    await drain(tester);
    await pumpZalos(tester, app: FakeZalosApp(vaultPending: true), size: expanded);
    expect(byKey('vaultWaiting'), findsOneWidget);
    await drain(tester);
  });
}
