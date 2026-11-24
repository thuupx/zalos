import 'package:material_ui/material_ui.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:zalos/src/domain/models.dart';
import 'package:zalos/src/ui/chat/message_actions.dart';
import 'package:zalos/src/ui/chat/message_row.dart';
import 'package:zalos/src/ui/components/basics.dart';
import 'package:zalos/src/ui/components/motion.dart';
import 'package:zalos/src/ui/theme/theme.dart';
import 'package:zalos/src/ui/theme/tokens.dart';
import 'package:zalos/src/ui/util/format.dart';

import '../support/harness.dart';

/// Largest vertical paint offset applied inside the row of [bubbleKey].
double _rowRise(WidgetTester tester, String bubbleKey) {
  final row = find.ancestor(of: byKey(bubbleKey), matching: find.byType(MessageRow));
  var rise = 0.0;
  for (final t in tester.widgetList<Transform>(find.descendant(of: row, matching: find.byType(Transform)))) {
    rise = t.transform.getTranslation().y.abs() > rise ? t.transform.getTranslation().y.abs() : rise;
  }
  return rise;
}

double _scaleOf(WidgetTester tester, Finder target) => tester.widget<ScaleTransition>(find.ancestor(of: target, matching: find.byType(ScaleTransition)).first).scale.value;

Widget _themed(Widget child, {bool reduce = false}) => MaterialApp(
      theme: buildZalosTheme(Brightness.light),
      home: MediaQuery(data: MediaQueryData(disableAnimations: reduce), child: Center(child: child)),
    );

void main() {
  test('motion tokens: micro interactions 150 to 300 ms, nothing over 500 ms, exits faster than entrances', () {
    for (final d in [ZMotion.fast, ZMotion.enter, ZMotion.medium, ZMotion.exit, ZMotion.bump, ReactionRow.entranceDuration]) {
      expect(d.inMilliseconds, inInclusiveRange(150, 300));
    }
    expect(ZMotion.exit, lessThan(ZMotion.medium));
    expect(ZMotion.enterCurve, isNot(Curves.linear));
  });

  testWidgets('reduced motion: durations are zero, badges do not bump', (tester) async {
    late BuildContext captured;
    Widget badge(int count, {required bool reduce}) => _themed(
          Builder(builder: (context) {
            captured = context;
            return ZBadge(key: const Key('badge'), count: count);
          }),
          reduce: reduce,
        );

    await tester.pumpWidget(badge(1, reduce: true));
    expect(ZMotion.of(captured, ZMotion.medium), Duration.zero);
    await tester.pumpWidget(badge(2, reduce: true));
    await tester.pump(const Duration(milliseconds: 60));
    expect(_scaleOf(tester, find.text('2')), 1);

    await tester.pumpWidget(badge(1, reduce: false));
    expect(ZMotion.of(captured, ZMotion.medium), ZMotion.medium);
    await tester.pumpWidget(badge(2, reduce: false));
    await tester.pump(const Duration(milliseconds: 60));
    expect(_scaleOf(tester, find.text('2')), greaterThan(1));
    await tester.pumpAndSettle();
    expect(_scaleOf(tester, find.text('2')), 1);
  });

  testWidgets('reduced motion: the reaction picker opens without zoom or stagger', (tester) async {
    final h = await pumpZalos(tester, size: expanded, reduceMotion: true);
    await openThreadByKey(tester, 'g01');
    final m = h.main.messages('g01', ThreadType.group).value.last;
    await hover(tester, byKey('bubble-${m.id}'));
    await tester.tap(byKey('hoverReact-${m.id}'));
    await tester.pump();
    final picker = byKey('reactionPicker');
    expect(find.descendant(of: picker, matching: find.byType(ScaleTransition)), findsNothing);
    expect(find.ancestor(of: picker, matching: find.byType(ScaleTransition)), findsNothing);
    await drain(tester);
  });

  testWidgets('only messages that arrive while the chat is open play the entrance, once', (tester) async {
    final h = await pumpZalos(tester, size: expanded);
    await openThreadByKey(tester, 'u02');
    final history = h.main.messages('u02', ThreadType.user).value;
    for (final m in history) {
      if (byKey('bubble-${m.id}').evaluate().isNotEmpty) expect(_rowRise(tester, 'bubble-${m.id}'), 0, reason: 'history row ${m.id} animated');
    }

    final live = h.main.receive('u02', 'vừa tới');
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 40));
    final rising = _rowRise(tester, 'bubble-${live.id}');
    expect(rising, greaterThan(0));
    expect(rising, lessThanOrEqualTo(ZMotion.rise));
    await settle(tester);
    expect(_rowRise(tester, 'bubble-${live.id}'), 0);

    // A rebuild of the same row (a reaction lands) does not replay it.
    await h.main.react(h.main.messages('u02', ThreadType.user).value.last, '/-strong');
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 40));
    expect(_rowRise(tester, 'bubble-${live.id}'), 0);
    await drain(tester);
  });

  testWidgets('reaction picker icons zoom in one after another and all finish', (tester) async {
    final h = await pumpZalos(tester, size: expanded);
    await openThreadByKey(tester, 'g01');
    final m = h.main.messages('g01', ThreadType.group).value.last;
    await hover(tester, byKey('bubble-${m.id}'));
    await tester.tap(byKey('hoverReact-${m.id}'));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 60));
    final first = byKey('react-${reactionIcons.first}');
    final last = byKey('react-${reactionIcons.last}');
    expect(_scaleOf(tester, first), greaterThan(_scaleOf(tester, last)));
    await settle(tester, ReactionRow.entranceDuration * 2);
    for (final icon in reactionIcons) {
      expect(_scaleOf(tester, byKey('react-$icon')), 1, reason: icon);
      final fade = tester.widget<FadeTransition>(find.ancestor(of: byKey('react-$icon'), matching: find.byType(FadeTransition)).first);
      expect(fade.opacity.value, 1, reason: icon);
    }
    await drain(tester);
  });

  testWidgets('a thread with new activity rises to the top while the rows it passes slide down', (tester) async {
    final h = await pumpZalos(tester, size: expanded);
    final threads = h.main.threads.value;
    final mover = threads[4];
    final passed = threads.firstWhere((t) => !t.pinned);
    h.main.receive(mover.id, 'lên đầu');
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 40));
    double dy(String id) => tester.widget<Transform>(find.ancestor(of: byKey('thread-$id'), matching: find.byType(Transform)).first).transform.getTranslation().y;
    expect(dy(passed.id), lessThan(0));
    await settle(tester);
    expect(dy(passed.id), 0);
    expect(dy(mover.id), 0);
    await drain(tester);
  });

  testWidgets('connection banner slides in and out', (tester) async {
    final h = await pumpZalos(tester, size: expanded);
    double bannerHeight() {
      final banner = byKey('bannerDisconnected');
      if (banner.evaluate().isEmpty) return 0;
      return tester.getSize(find.ancestor(of: banner, matching: find.byType(ClipRect)).first).height;
    }

    h.link.setState(LinkState.disconnected);
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 60));
    final full = tester.getSize(byKey('bannerDisconnected')).height;
    expect(bannerHeight(), inExclusiveRange(0, full));
    await settle(tester);
    expect(bannerHeight(), full);

    h.link.setState(LinkState.connected);
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 60));
    expect(bannerHeight(), inExclusiveRange(0, full));
    await settle(tester);
    expect(byKey('bannerDisconnected'), findsNothing);
    await drain(tester);
  });

  testWidgets('disposing mid animation leaves no ticker running', (tester) async {
    final h = await pumpZalos(tester, size: expanded);
    await openThreadByKey(tester, 'g01');
    final m = h.main.messages('g01', ThreadType.group).value.last;
    h.main.receive('g01', 'giữa chừng');
    h.main.receive('u05', 'đổi thứ tự');
    h.link.setState(LinkState.disconnected);
    await hover(tester, byKey('bubble-${m.id}'));
    await tester.tap(byKey('hoverReact-${m.id}'));
    await tester.pump(const Duration(milliseconds: 30));
    await tester.pumpWidget(const SizedBox());
    expect(tester.takeException(), isNull);
    expect(tester.binding.transientCallbackCount, 0);
    await drain(tester);
  });

  testWidgets('ZPresence keeps the child through its exit and then drops it', (tester) async {
    Widget host(bool show) => _themed(ZPresence(
          child: show ? const Text('pane', key: Key('pane')) : null,
          builder: (context, animation, child) => FadeTransition(opacity: animation, child: child),
        ));
    await tester.pumpWidget(host(false));
    expect(byKey('pane'), findsNothing);
    await tester.pumpWidget(host(true));
    await tester.pump(ZMotion.medium ~/ 2);
    expect(tester.widget<FadeTransition>(find.ancestor(of: byKey('pane'), matching: find.byType(FadeTransition)).first).opacity.value, inExclusiveRange(0, 1));
    await tester.pumpAndSettle();
    await tester.pumpWidget(host(false));
    await tester.pump(ZMotion.exit ~/ 2);
    expect(byKey('pane'), findsOneWidget);
    await tester.pumpAndSettle();
    expect(byKey('pane'), findsNothing);
  });
}
