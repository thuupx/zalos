import 'package:material_ui/material_ui.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:zalos/src/ui/theme/tokens.dart';

import '../support/harness.dart';

double _chatWidth(WidgetTester tester) => tester.getRect(byKey('messageList')).width;

void main() {
  testWidgets('docked info: opening reflows the chat once, not on every frame', (tester) async {
    await pumpZalos(tester, size: expanded);
    await openThreadByKey(tester, 'g01');
    final before = _chatWidth(tester);
    final widths = <double>[before];

    await tester.tap(byKey('chatHeaderInfo'));
    await tester.pump();
    expect(byKey('infoDocked'), findsOneWidget);
    widths.add(_chatWidth(tester));

    for (var i = 0; i < 4; i++) {
      await tester.pump(const Duration(milliseconds: 40));
      widths.add(_chatWidth(tester));
    }
    await settle(tester);
    widths.add(_chatWidth(tester));

    expect(before - widths.last, moreOrLessEquals(ZSizes.infoDocked, epsilon: 0.5));
    expect(widths.skip(1).toSet(), hasLength(1), reason: 'chat kept reflowing while the pane animated in: $widths');
    expect(widths.toSet().length, lessThanOrEqualTo(2), reason: 'chat width changed more than once: $widths');
    await drain(tester);
  });

  testWidgets('docked info: closing keeps the pane and its allocation until the exit ends', (tester) async {
    await pumpZalos(tester, size: expanded);
    await openThreadByKey(tester, 'g01');
    await tester.tap(byKey('chatHeaderInfo'));
    await settle(tester);
    final open = _chatWidth(tester);
    expect(byKey('infoPane'), findsOneWidget);

    await tester.tap(byKey('infoClose'));
    await tester.pump();
    expect(byKey('infoPane'), findsOneWidget, reason: 'the pane stays on screen for its exit');
    expect(byKey('infoDocked'), findsOneWidget);
    final widths = <double>[_chatWidth(tester)];
    for (var i = 0; i < 3; i++) {
      await tester.pump(const Duration(milliseconds: 30));
      expect(byKey('infoPane'), findsOneWidget);
      widths.add(_chatWidth(tester));
    }
    expect(widths.toSet(), hasLength(1), reason: 'chat kept reflowing while the pane animated out: $widths');

    await settle(tester);
    expect(byKey('infoPane'), findsNothing);
    expect(byKey('infoDocked'), findsNothing);
    expect(_chatWidth(tester), moreOrLessEquals(open + ZSizes.infoDocked, epsilon: 0.5));
    await drain(tester);
  });

  testWidgets('docked info: reduced motion allocates once and fades without sliding', (tester) async {
    await pumpZalos(tester, size: expanded, reduceMotion: true);
    await openThreadByKey(tester, 'g01');
    final before = _chatWidth(tester);

    await tester.tap(byKey('chatHeaderInfo'));
    await tester.pump();
    expect(byKey('infoDocked'), findsOneWidget);
    expect(_chatWidth(tester), moreOrLessEquals(before - ZSizes.infoDocked, epsilon: 0.5));
    expect(find.descendant(of: byKey('infoDocked'), matching: find.byType(SlideTransition)), findsNothing);

    await settle(tester);
    expect(_chatWidth(tester), moreOrLessEquals(before - ZSizes.infoDocked, epsilon: 0.5));
    await drain(tester);
  });
}
