import 'package:flutter/gestures.dart' show PointerDeviceKind;
import 'package:material_ui/material_ui.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:zalos/src/domain/models.dart';

import '../support/fake_zalos.dart';
import '../support/harness.dart';

/// Proves [after] sits exactly where [before] did.
void _expectUnmoved(Rect after, Rect before, String step) {
  expect(after.left, before.left, reason: '$step: left edge moved');
  expect(after.top, before.top, reason: '$step: top edge moved');
  expect(after.right, before.right, reason: '$step: right edge moved');
  expect(after.bottom, before.bottom, reason: '$step: bottom edge moved');
}

double _heartOpacity(WidgetTester tester, String id) =>
    tester.widget<AnimatedOpacity>(find.ancestor(of: byKey('reactButton-$id'), matching: find.byType(AnimatedOpacity)).first).opacity;

/// The heart stays mounted on wide; while hidden it must be out of hit
/// tests, tab traversal and the semantics tree.
void _expectHeart(WidgetTester tester, String id, {required bool revealed}) {
  final heart = byKey('reactButton-$id');
  expect(heart, findsOneWidget);
  expect(_heartOpacity(tester, id), revealed ? 1 : 0, reason: 'heart opacity');
  expect(
    tester.widget<ExcludeFocus>(find.ancestor(of: heart, matching: find.byType(ExcludeFocus)).first).excluding,
    !revealed,
    reason: revealed ? 'visible heart is not focusable' : 'hidden heart stays in traversal',
  );
  expect(
    tester.widget<IgnorePointer>(find.ancestor(of: heart, matching: find.byType(IgnorePointer)).first).ignoring,
    !revealed,
    reason: revealed ? 'visible heart is not clickable' : 'hidden heart takes pointer input',
  );
  expect(find.bySemanticsLabel('Yêu thích'), revealed ? findsOneWidget : findsNothing);
}

/// The chip pop and bump play once when the chips appear; hover must leave
/// every scale and fade ancestor at rest.
void _expectChipsIdle(WidgetTester tester, Finder chips, String step) {
  for (final s in tester.widgetList<ScaleTransition>(find.ancestor(of: chips, matching: find.byType(ScaleTransition)))) {
    expect(s.scale.value, 1, reason: '$step: chip scale ${s.scale.value}');
  }
  for (final f in tester.widgetList<FadeTransition>(find.ancestor(of: chips, matching: find.byType(FadeTransition)))) {
    expect(f.opacity.value, 1, reason: '$step: chip opacity ${f.opacity.value}');
  }
}

ScrollPosition _listPosition(WidgetTester tester) => tester
    .state<ScrollableState>(find.descendant(of: byKey('messageList'), matching: find.byType(Scrollable)).first)
    .position;

/// The list builds only what is on screen (zero cache extent) and reveal
/// drags coast a little, so pump until the scroll offset is steady before
/// reading rects.
Future<void> _scrollIdle(WidgetTester tester) async {
  for (var i = 0; i < 60; i++) {
    final p = _listPosition(tester).pixels;
    await tester.pump(const Duration(milliseconds: 50));
    if (_listPosition(tester).pixels == p) return;
  }
}

void main() {
  testWidgets('compact: first reaction, losing the last one and recall never move a row', (tester) async {
    final h = await pumpZalos(tester, size: compact);
    await openThreadByKey(tester, 'u02');
    final s = h.main;
    const type = ThreadType.user;
    final base = fakeNow.millisecondsSinceEpoch + 1000;
    // Two incoming then two outgoing group mates, plus a tail so every
    // target has a next row.
    final incomingFirst = s.msg('u02', type, 'u02', base, text: 'peer one');
    final incomingLast = s.msg('u02', type, 'u02', base + 60000, text: 'peer two');
    final outgoingFirst = s.msg('u02', type, s.selfUid, base + 120000, text: 'me one');
    final outgoingLast = s.msg('u02', type, s.selfUid, base + 180000, text: 'me two');
    final tail = s.msg('u02', type, 'u02', base + 240000, text: 'peer three');
    for (final m in [incomingFirst, incomingLast, outgoingFirst, outgoingLast, tail]) {
      s.deliver(m);
    }
    await settle(tester, const Duration(seconds: 1));
    // The newest rows sit at the bottom of the reversed list (offset 0);
    // jumping there builds every target despite the zero cache extent.
    _listPosition(tester).jumpTo(0);
    await _scrollIdle(tester);

    Future<void> checkStable(Message m, Message next, String label) async {
      final bubble = byKey('bubble-${m.id}');
      final meta = byKey('meta-${m.id}');
      final nextBubble = byKey('bubble-${next.id}');
      expect(bubble, findsOneWidget, reason: '$label: target row not built');
      expect(nextBubble, findsOneWidget, reason: '$label: next row not built');
      final hasMeta = meta.evaluate().isNotEmpty;
      final rBubble = tester.getRect(bubble);
      final rMeta = hasMeta ? tester.getRect(meta) : null;
      final rNext = tester.getRect(nextBubble);
      final gap = rNext.top - rBubble.bottom;

      // The first reaction pops into the already reserved slot.
      await s.react(m, '/-heart');
      await tester.pump();
      await settle(tester);
      expect(byKey('reactions-${m.id}'), findsOneWidget, reason: label);
      _expectUnmoved(tester.getRect(bubble), rBubble, '$label: first reaction bubble');
      if (rMeta != null) _expectUnmoved(tester.getRect(meta), rMeta, '$label: first reaction meta');
      _expectUnmoved(tester.getRect(nextBubble), rNext, '$label: first reaction next row');

      // Losing the last reaction leaves the reserved slot behind unchanged.
      s.replace(m, (cur) => s.copy(cur, reactions: const {}));
      await tester.pump();
      await settle(tester);
      expect(byKey('reactions-${m.id}'), findsNothing, reason: label);
      _expectUnmoved(tester.getRect(bubble), rBubble, '$label: last reaction removed bubble');
      if (rMeta != null) _expectUnmoved(tester.getRect(meta), rMeta, '$label: removal meta');
      _expectUnmoved(tester.getRect(nextBubble), rNext, '$label: removal next row');

      // Recall may shrink the bubble but must not collapse the slot: the gap
      // between this bubble's bottom and the next row keeps its height.
      await s.recall(m);
      await tester.pump();
      await settle(tester);
      expect(tester.getRect(bubble).top, rBubble.top, reason: '$label: recall moved the bubble top');
      expect(tester.getRect(nextBubble).top - tester.getRect(bubble).bottom, gap, reason: '$label: recall collapsed the slot');
    }

    await checkStable(incomingFirst, incomingLast, 'incoming non-last');
    await checkStable(incomingLast, outgoingFirst, 'incoming group-last');
    await checkStable(outgoingFirst, outgoingLast, 'outgoing non-last');
    await checkStable(outgoingLast, tail, 'outgoing group-last');
    await drain(tester);
  });

  testWidgets('wide: hovering a reacted row never moves chips or replays the pop', (tester) async {
    final h = await pumpZalos(tester, size: expanded);
    await openThreadByKey(tester, 'g01');
    final msgs = h.main.messages('g01', ThreadType.group).value;
    final target = msgs.lastWhere((m) => m.reactions.isNotEmpty && !m.recalled && m.sendState == SendState.sent);
    final chips = byKey('reactions-${target.id}');
    final bubble = byKey('bubble-${target.id}');
    await revealIn(tester, 'messageList', 'reactions-${target.id}');
    await _scrollIdle(tester);

    final mouse = await tester.createGesture(kind: PointerDeviceKind.mouse);
    await mouse.addPointer(location: Offset.zero);
    await tester.pump();

    _expectHeart(tester, target.id, revealed: false);
    final rChips = tester.getRect(chips);
    final rBubble = tester.getRect(bubble);

    for (var i = 0; i < 3; i++) {
      await mouse.moveTo(tester.getCenter(bubble));
      await tester.pump(const Duration(milliseconds: 30));
      _expectUnmoved(tester.getRect(chips), rChips, 'enter $i mid-fade');
      _expectUnmoved(tester.getRect(bubble), rBubble, 'enter $i mid-fade');
      _expectChipsIdle(tester, chips, 'enter $i');
      await settle(tester);
      _expectUnmoved(tester.getRect(chips), rChips, 'enter $i shown');
      _expectUnmoved(tester.getRect(bubble), rBubble, 'enter $i shown');
      _expectHeart(tester, target.id, revealed: true);

      await mouse.moveTo(tester.getCenter(byKey('composerField')));
      await tester.pump(const Duration(milliseconds: 30));
      _expectUnmoved(tester.getRect(chips), rChips, 'exit $i mid-fade');
      _expectUnmoved(tester.getRect(bubble), rBubble, 'exit $i mid-fade');
      _expectChipsIdle(tester, chips, 'exit $i');
      await settle(tester);
      _expectUnmoved(tester.getRect(chips), rChips, 'exit $i hidden');
      _expectUnmoved(tester.getRect(bubble), rBubble, 'exit $i hidden');
      _expectHeart(tester, target.id, revealed: false);
    }

    // A visible heart acts: tapping it adds the quick reaction.
    await mouse.moveTo(tester.getCenter(bubble));
    await settle(tester);
    await tester.tap(byKey('reactButton-${target.id}'));
    await settle(tester);
    final updated = h.main.messages('g01', ThreadType.group).value.firstWhere((m) => m.id == target.id);
    expect(updated.reactions['/-heart'], contains(h.main.selfUid));
    await mouse.removePointer();
    await drain(tester);
  });

  testWidgets('reduced motion: identical rects, the heart only fades', (tester) async {
    final h = await pumpZalos(tester, size: expanded, reduceMotion: true);
    await openThreadByKey(tester, 'g01');
    final msgs = h.main.messages('g01', ThreadType.group).value;
    final target = msgs.lastWhere((m) => m.reactions.isNotEmpty && !m.recalled && m.sendState == SendState.sent);
    final chips = byKey('reactions-${target.id}');
    final bubble = byKey('bubble-${target.id}');
    final heart = byKey('reactButton-${target.id}');
    await revealIn(tester, 'messageList', 'reactions-${target.id}');
    await _scrollIdle(tester);

    final mouse = await tester.createGesture(kind: PointerDeviceKind.mouse);
    await mouse.addPointer(location: Offset.zero);
    await tester.pump();

    _expectHeart(tester, target.id, revealed: false);
    final rChips = tester.getRect(chips);
    final rBubble = tester.getRect(bubble);

    void expectNoDrift(String step) {
      for (final t in tester.widgetList<Transform>(find.ancestor(of: heart, matching: find.byType(Transform)))) {
        expect(t.transform.getTranslation().x, 0, reason: '$step: heart drifted');
        expect(t.transform.getTranslation().y, 0, reason: '$step: heart drifted');
      }
    }

    await mouse.moveTo(tester.getCenter(bubble));
    await tester.pump(const Duration(milliseconds: 30));
    _expectUnmoved(tester.getRect(chips), rChips, 'reduced enter mid-fade');
    _expectUnmoved(tester.getRect(bubble), rBubble, 'reduced enter mid-fade');
    expectNoDrift('reduced enter');
    await settle(tester);
    _expectHeart(tester, target.id, revealed: true);
    _expectUnmoved(tester.getRect(chips), rChips, 'reduced enter shown');
    _expectUnmoved(tester.getRect(bubble), rBubble, 'reduced enter shown');

    await mouse.moveTo(tester.getCenter(byKey('composerField')));
    await tester.pump(const Duration(milliseconds: 30));
    _expectUnmoved(tester.getRect(chips), rChips, 'reduced exit mid-fade');
    _expectUnmoved(tester.getRect(bubble), rBubble, 'reduced exit mid-fade');
    expectNoDrift('reduced exit');
    await settle(tester);
    _expectHeart(tester, target.id, revealed: false);
    await mouse.removePointer();
    await drain(tester);
  });
}
