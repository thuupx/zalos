import 'dart:ui' show Tristate;

import 'package:material_ui/material_ui.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:zalos/src/ui/components/basics.dart';
import 'package:zalos/src/ui/components/onboarding.dart';
import 'package:zalos/src/ui/theme/theme.dart';
import 'package:zalos/src/ui/theme/tokens.dart';

import '../support/harness.dart';

Widget _frame(Size size,
        {bool dark = false, bool reduce = false, double maxWidth = 400}) =>
    MaterialApp(
      theme: buildZalosTheme(dark ? Brightness.dark : Brightness.light),
      home: MediaQuery(
        data: MediaQueryData(size: size, disableAnimations: reduce),
        child: LayoutScope(
          layout: layoutClassFor(size.width),
          child: Scaffold(
            body: ZOnboardingFrame(
                maxWidth: maxWidth,
                child: const SizedBox(
                    key: Key('frameChild'),
                    width: double.infinity,
                    height: 200)),
          ),
        ),
      ),
    );

Future<void> _pumpFrame(WidgetTester tester, Size size,
    {bool dark = false, bool reduce = false, double maxWidth = 400}) async {
  tester.view.physicalSize = size;
  tester.view.devicePixelRatio = 1;
  addTearDown(() {
    tester.view.reset();
    tester.platformDispatcher.clearAllTestValues();
  });
  await tester
      .pumpWidget(_frame(size, dark: dark, reduce: reduce, maxWidth: maxWidth));
}

final _frameFinder = find.byType(ZOnboardingFrame);
final _childFinder = find.byKey(const Key('frameChild'));

ScaleTransition _scale(WidgetTester tester) =>
    tester.widget<ScaleTransition>(find
        .ancestor(of: _childFinder, matching: find.byType(ScaleTransition))
        .first);

FadeTransition _fade(WidgetTester tester) => tester.widget<FadeTransition>(find
    .ancestor(of: _childFinder, matching: find.byType(FadeTransition))
    .first);

/// The card of the wide layout, or null when the frame stays edge to edge.
BoxDecoration? _card(WidgetTester tester) {
  for (final box in tester.widgetList<DecoratedBox>(
      find.descendant(of: _frameFinder, matching: find.byType(DecoratedBox)))) {
    final decoration = box.decoration;
    if (decoration is BoxDecoration &&
        decoration.borderRadius == BorderRadius.circular(ZRadius.card)) {
      return decoration;
    }
  }
  return null;
}

void main() {
  testWidgets(
      'onboarding frame: wide centers a card on the warm backdrop with a subtle entrance',
      (tester) async {
    await _pumpFrame(tester, medium);
    await tester.pump();

    expect(
        tester
            .widget<ColoredBox>(find.descendant(
                of: _frameFinder, matching: find.byType(ColoredBox)))
            .color,
        ZalosTokens.light.layerSubtle);
    final card = _card(tester);
    expect(card, isNotNull);
    expect(card!.color, ZalosTokens.light.layer);
    expect(card.border, isNotNull);
    expect(tester.renderObject<RenderBox>(_childFinder).size.width, 400);
    expect(tester.getCenter(_childFinder),
        Offset(medium.width / 2, medium.height / 2));
    expect(_scale(tester).scale.value, inInclusiveRange(0.98, 1.0));

    await tester.pumpAndSettle();
    expect(_scale(tester).scale.value, 1);
    expect(_fade(tester).opacity.value, 1);
  });

  testWidgets('onboarding frame: compact stays edge to edge and scrolls',
      (tester) async {
    await _pumpFrame(tester, compact);
    await tester.pumpAndSettle();

    expect(
        tester
            .widget<ColoredBox>(find.descendant(
                of: _frameFinder, matching: find.byType(ColoredBox)))
            .color,
        ZalosTokens.light.layer);
    expect(_card(tester), isNull);
    expect(
        find.descendant(
            of: _frameFinder, matching: find.byType(SingleChildScrollView)),
        findsOneWidget);
    expect(
        find.descendant(
            of: _frameFinder, matching: find.byType(ScaleTransition)),
        findsNothing);
    expect(tester.renderObject<RenderBox>(_childFinder).size.width,
        compact.width - 2 * ZSpace.s20);
  });

  testWidgets('onboarding frame: reduced motion skips the entrance',
      (tester) async {
    await _pumpFrame(tester, medium, reduce: true);
    await tester.pump();

    expect(_scale(tester).scale.value, 1);
    expect(_fade(tester).opacity.value, 1);
    await tester.pumpAndSettle();
    expect(_scale(tester).scale.value, 1);
  });

  testWidgets('onboarding frame: dark tokens back the backdrop and the card',
      (tester) async {
    await _pumpFrame(tester, medium, dark: true);
    await tester.pumpAndSettle();

    expect(
        tester
            .widget<ColoredBox>(find.descendant(
                of: _frameFinder, matching: find.byType(ColoredBox)))
            .color,
        ZalosTokens.darkTokens.layerSubtle);
    expect(_card(tester)!.color, ZalosTokens.darkTokens.layer);
  });

  testWidgets('contacts compact: one search field in the header still filters',
      (tester) async {
    await pumpZalos(tester);
    await tapKey(tester, 'tab-contacts');
    await settle(tester);

    expect(byKey('contactSearch'), findsOneWidget);
    expect(
        find.descendant(
            of: find.byType(ZPhoneHeader), matching: byKey('contactSearch')),
        findsOneWidget);
    expect(byKey('contactsRefresh'), findsNothing);

    await tester.enterText(byKey('contactSearch'), 'me');
    await settle(tester);
    expect(byKey('contact-u05'), findsOneWidget);
    expect(byKey('contact-u01'), findsNothing);
    await drain(tester);
  });

  testWidgets('info section titles are headers and keep their toggled state',
      (tester) async {
    await pumpZalos(tester, size: expanded);
    await openThreadByKey(tester, 'g01');
    await tapKey(tester, 'chatInfo');

    final title = tester.widget<Text>(find.descendant(
        of: byKey('infoSection-members'), matching: find.byType(Text)));
    expect(title.style, ZalosTokens.light.text.overline);
    expect(title.semanticsLabel, contains('Thành viên'));
    expect(title.data, title.semanticsLabel!.toUpperCase());

    final open =
        tester.getSemantics(byKey('infoSection-members')).getSemanticsData();
    expect(open.label, contains('Thành viên'));
    expect(open.flagsCollection.isHeader, isTrue);
    expect(open.flagsCollection.isButton, isTrue);
    expect(open.flagsCollection.isToggled != Tristate.none, isTrue);
    expect(open.flagsCollection.isToggled == Tristate.isTrue, isTrue);

    await tapKey(tester, 'infoSection-members');
    final closed =
        tester.getSemantics(byKey('infoSection-members')).getSemanticsData();
    expect(closed.flagsCollection.isHeader, isTrue);
    expect(closed.flagsCollection.isToggled == Tristate.isTrue, isFalse);
    await drain(tester);
  });
}
