import 'package:material_ui/material_ui.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:zalos/src/ui/theme/tokens.dart';

import '../support/harness.dart';

/// WCAG contrast ratio, the same formula as the text contrast guideline.
double _ratio(Color a, Color b) {
  final x = a.computeLuminance(), y = b.computeLuminance();
  return (x > y ? x + 0.05 : y + 0.05) / (x > y ? y + 0.05 : x + 0.05);
}

TextField _field(WidgetTester tester) =>
    tester.widget<TextField>(find.descendant(of: byKey('threadSearch'), matching: find.byType(TextField)));

void main() {
  for (final dark in [false, true]) {
    testWidgets('compact search text and hint meet AA on the header ${dark ? 'dark' : 'light'}', (tester) async {
      await pumpZalos(tester, dark: dark);
      await tester.enterText(byKey('threadSearch'), 'nguyen');
      FocusManager.instance.primaryFocus?.unfocus();
      await settle(tester);

      final field = _field(tester);
      final z = tester.element(byKey('threadSearch')).z;
      // The dark header field is still a translucent tint, so resolve it over
      // the header surface before measuring; the light one is already opaque.
      final fill = Color.alphaBlend(field.decoration!.fillColor!, z.headerStart);
      expect(_ratio(field.style!.color!, fill), greaterThanOrEqualTo(4.5));
      expect(_ratio(Color.alphaBlend(field.decoration!.hintStyle!.color!, fill), fill), greaterThanOrEqualTo(4.5));
      await expectLater(tester, meetsGuideline(textContrastGuideline));
      await drain(tester);
    });
  }

  testWidgets('wide search field keeps its layer surface', (tester) async {
    await pumpZalos(tester, size: medium);
    final z = tester.element(byKey('threadSearch')).z;
    final field = _field(tester);
    expect(field.decoration!.fillColor, z.layerSubtle);
    expect(field.style!.color, z.textPrimary);
    await drain(tester);
  });
}
