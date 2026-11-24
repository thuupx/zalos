import 'package:flutter_test/flutter_test.dart';
import 'package:material_ui/material_ui.dart';
import 'package:zalos/src/ui/chat/message_row.dart';
import 'package:zalos/src/ui/theme/theme.dart';
import 'package:zalos/src/ui/theme/tokens.dart';

import '../support/harness.dart';

double _contrastRatio(Color a, Color b) {
  final x = a.computeLuminance();
  final y = b.computeLuminance();
  return (x > y ? x + 0.05 : y + 0.05) / (x > y ? y + 0.05 : x + 0.05);
}

void _expectPillContrast(ZalosTokens z) {
  expect(z.onPill, z.dark ? z.textPrimary : ZalosTokens.white);
  final fill = Color.alphaBlend(z.pillBg, z.surface);
  expect(_contrastRatio(z.onPill, fill), greaterThanOrEqualTo(4.5));
}

void main() {
  for (final dark in [false, true]) {
    final themeName = dark ? 'dark' : 'light';

    testWidgets('day pill uses the semantic foreground in $themeName',
        (tester) async {
      final semantics = tester.ensureSemantics();
      final z = dark ? ZalosTokens.darkTokens : ZalosTokens.light;
      _expectPillContrast(z);

      await tester.pumpWidget(MaterialApp(
        theme: buildZalosTheme(dark ? Brightness.dark : Brightness.light),
        home: Scaffold(
          backgroundColor: z.surface,
          body: const Center(child: DayPill(text: 'Today')),
        ),
      ));

      final text = tester.widget<Text>(find.descendant(
          of: find.byType(DayPill), matching: find.byType(Text)));
      expect(text.style?.color, z.onPill);
      await expectLater(tester, meetsGuideline(textContrastGuideline));
      semantics.dispose();
    });

    testWidgets(
        'bare-bubble meta pill uses the semantic foreground in $themeName',
        (tester) async {
      final z = dark ? ZalosTokens.darkTokens : ZalosTokens.light;
      _expectPillContrast(z);

      final h = await pumpZalos(tester, size: expanded, dark: dark);
      await openThreadByKey(tester, 'u02');
      final message = h.main.receive('u02', '😀😀');
      await settle(tester);

      final meta = byKey('meta-${message.id}');
      expect(meta, findsOneWidget);
      final texts = tester.widgetList<Text>(
          find.descendant(of: meta, matching: find.byType(Text)));
      expect(texts, isNotEmpty);
      for (final text in texts) {
        expect(text.style?.color, z.onPill);
      }

      final pill = tester
          .widgetList<Container>(
              find.ancestor(of: meta, matching: find.byType(Container)))
          .firstWhere((container) {
        final decoration = container.decoration;
        return decoration is BoxDecoration && decoration.color == z.pillBg;
      });
      expect((pill.decoration! as BoxDecoration).color, z.pillBg);
      await expectLater(tester, meetsGuideline(textContrastGuideline));
      await drain(tester);
    });
  }
}
