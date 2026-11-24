import 'package:material_ui/material_ui.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:zalos/src/ui/theme/theme.dart';
import 'package:zalos/src/ui/theme/tokens.dart';

import '../support/harness.dart';

late BuildContext _context;

Widget _probe({MediaQueryData? data}) => MaterialApp(
      theme: buildZalosTheme(Brightness.light),
      home: data == null
          ? Builder(builder: (context) {
              _context = context;
              return const SizedBox.shrink();
            })
          : MediaQuery(
              data: data,
              child: Builder(builder: (context) {
                _context = context;
                return const SizedBox.shrink();
              }),
            ),
    );

ScrollPosition _pos(WidgetTester tester) =>
    tester.state<ScrollableState>(find.descendant(of: byKey('messageList'), matching: find.byType(Scrollable)).first).position;

AnimatedScale _latestButtonScale(WidgetTester tester) =>
    tester.widget<AnimatedScale>(find.ancestor(of: byKey('scrollToLatest'), matching: find.byType(AnimatedScale)).first);

void main() {
  testWidgets('reduced motion: disableAnimations alone zeroes motion durations', (tester) async {
    await tester.pumpWidget(_probe(data: const MediaQueryData()));
    expect(ZMotion.reduced(_context), isFalse);
    expect(ZMotion.of(_context, ZMotion.medium), ZMotion.medium);

    await tester.pumpWidget(_probe(data: const MediaQueryData(disableAnimations: true)));
    expect(ZMotion.reduced(_context), isTrue);
    expect(ZMotion.of(_context, ZMotion.enter), Duration.zero);
  });

  testWidgets('reduced motion: reduceMotion alone zeroes motion durations', (tester) async {
    addTearDown(tester.platformDispatcher.clearAccessibilityFeaturesTestValue);
    await tester.pumpWidget(_probe());
    expect(ZMotion.reduced(_context), isFalse);

    tester.platformDispatcher.accessibilityFeaturesTestValue = const FakeAccessibilityFeatures(reduceMotion: true);
    await tester.pumpWidget(_probe());
    expect(ZMotion.reduced(_context), isTrue);
    expect(ZMotion.of(_context, ZMotion.medium), Duration.zero);
  });

  testWidgets('chat: the scroll-to-latest control stops scaling with disableAnimations', (tester) async {
    await pumpZalos(tester, size: expanded);
    await openThreadByKey(tester, 'u01');
    expect(_latestButtonScale(tester).duration, ZMotion.fast);
    await drain(tester);

    await pumpZalos(tester, size: expanded, reduceMotion: true);
    await openThreadByKey(tester, 'u01');
    expect(_latestButtonScale(tester).duration, Duration.zero);
    await drain(tester);
  });

  testWidgets('chat: the scroll-to-latest control stops scaling with only reduceMotion', (tester) async {
    addTearDown(tester.platformDispatcher.clearAccessibilityFeaturesTestValue);
    tester.platformDispatcher.accessibilityFeaturesTestValue = const FakeAccessibilityFeatures(reduceMotion: true);
    await pumpZalos(tester, size: expanded);
    await openThreadByKey(tester, 'u01');
    expect(_latestButtonScale(tester).duration, Duration.zero);
    await drain(tester);
  });

  testWidgets('chat: scroll-to-latest snaps to the bottom when only reduceMotion is set', (tester) async {
    addTearDown(tester.platformDispatcher.clearAccessibilityFeaturesTestValue);
    tester.platformDispatcher.accessibilityFeaturesTestValue = const FakeAccessibilityFeatures(reduceMotion: true);
    final h = await pumpZalos(tester, size: expanded);
    await openThreadByKey(tester, 'u01');
    await tester.drag(byKey('messageList'), const Offset(0, 1400));
    await settle(tester);
    h.main.receive('u01', 'tin mới khi đang cuộn');
    await settle(tester);
    expect(byKey('awayBadge'), findsOneWidget);
    expect(_pos(tester).pixels, greaterThan(1));

    await tester.tap(byKey('scrollToLatest'));
    await tester.pump();
    expect(_pos(tester).pixels, moreOrLessEquals(0, epsilon: 1));
    await drain(tester);
  });
}
