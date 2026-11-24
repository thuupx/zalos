import 'package:material_ui/material_ui.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:zalos/src/ui/components/pressable.dart';

import '../support/fake_zalos.dart';
import '../support/harness.dart';

const _keyboard = 336.0;

void main() {
  testWidgets('compact pairing keeps the code field and Connect above the keyboard', (tester) async {
    await pumpZalos(tester, app: FakeZalosApp(paired: false));

    tester.view.viewInsets = const FakeViewPadding(bottom: _keyboard);
    await tester.pumpAndSettle();

    await tester.enterText(byKey('pairUri'), FakeZalosApp.samplePairingUri);
    await tester.pumpAndSettle();

    expect(tester.widget<ZButton>(byKey('pairConnect')).onPressed, isNotNull);
    final keyboardTop = compact.height - _keyboard;
    for (final key in ['pairUri', 'pairConnect']) {
      final rect = tester.getRect(byKey(key));
      expect(rect.bottom, lessThanOrEqualTo(keyboardTop), reason: '$key stays above the keyboard');
      expect(rect.top, greaterThanOrEqualTo(0), reason: '$key stays on screen');
    }

    tester.view.resetViewInsets();
    await tester.pumpAndSettle();

    expect(tester.takeException(), isNull);
    expect(byKey('pairUri'), findsOneWidget);
    final connect = tester.getRect(byKey('pairConnect'));
    expect(connect.top, greaterThanOrEqualTo(0));
    expect(connect.bottom, lessThanOrEqualTo(compact.height));
    expect(find.descendant(of: byKey('pairingScreen'), matching: find.byType(SingleChildScrollView)), findsOneWidget);
    await drain(tester);
  });
}
