import 'package:material_ui/material_ui.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:zalos/src/ui/theme/z_icons.dart';
import 'package:zalos/src/domain/models.dart';
import 'package:zalos/src/ui/platform/services.dart';
import 'package:zalos/src/ui/state/thread_ui.dart';
import 'package:zalos/src/ui/theme/tokens.dart';

import '../support/fake_platform.dart';
import '../support/harness.dart';

List<Message> _msgs(Harness h, String id) => h.main.messages(id, id.startsWith('g') ? ThreadType.group : ThreadType.user).value;
Message _byText(Harness h, String id, String text) => _msgs(h, id).firstWhere((m) => m.text == text);

/// True when the primary focus belongs to the subtree of [key].
bool _focusedWithin(String key) {
  final focus = FocusManager.instance.primaryFocus?.context;
  final matches = byKey(key).evaluate();
  if (focus == null || matches.isEmpty) return false;
  final target = matches.first;
  if (identical(focus, target)) return true;
  var found = false;
  focus.visitAncestorElements((element) {
    if (identical(element, target)) {
      found = true;
      return false;
    }
    return true;
  });
  return found;
}

/// Tabs forward until [key] holds focus.
Future<bool> _tabTo(WidgetTester tester, String key, {int max = 10}) async {
  for (var i = 0; i < max; i++) {
    await sendKey(tester, LogicalKeyboardKey.tab);
    if (_focusedWithin(key)) return true;
  }
  return false;
}

void main() {
  testWidgets('keyboard focus reveals wide message actions and activates them', (tester) async {
    final h = await pumpZalos(tester, size: expanded);
    await openThreadByKey(tester, 'g01');
    final m = _byText(h, 'g01', 'Chị Thư ơi mấy giờ chị tới?');
    final bar = find.ancestor(of: byKey('hoverBar-${m.id}'), matching: find.byType(AnimatedOpacity)).first;
    expect(tester.widget<AnimatedOpacity>(bar).opacity, 0);

    final node = tester.widget<Focus>(byKey('messageFocus-${m.id}')).focusNode!;
    node.requestFocus();
    await settle(tester);
    expect(tester.widget<AnimatedOpacity>(bar).opacity, 1);

    expect(await _tabTo(tester, 'hoverReact-${m.id}'), isTrue);
    expect(tester.widget<AnimatedOpacity>(bar).opacity, 1, reason: 'the bar stays visible while focus is inside');
    await sendKey(tester, LogicalKeyboardKey.enter);
    expect(byKey('reactionPicker'), findsOneWidget);
    await tapKey(tester, 'react-:>', scroll: false);
    expect(_byText(h, 'g01', m.text!).reactions.keys, contains(':>'));

    node.requestFocus();
    await settle(tester);
    expect(await _tabTo(tester, 'hoverReply-${m.id}'), isTrue);
    await sendKey(tester, LogicalKeyboardKey.enter);
    expect(byKey('replyBar'), findsOneWidget);
    await sendKey(tester, LogicalKeyboardKey.escape);
    expect(byKey('replyBar'), findsNothing);

    node.requestFocus();
    await settle(tester);
    expect(await _tabTo(tester, 'hoverMore-${m.id}'), isTrue);
    await sendKey(tester, LogicalKeyboardKey.enter);
    expect(byKey('menu-MessageAction.reply'), findsOneWidget);
    await tester.tapAt(const Offset(5, 5));
    await settle(tester);

    FocusManager.instance.primaryFocus?.unfocus();
    await settle(tester);
    expect(tester.widget<AnimatedOpacity>(bar).opacity, 0, reason: 'the bar hides again once focus leaves');
    await drain(tester);
  });

  testWidgets('swipe to reply reveals a reply glyph that follows the drag', (tester) async {
    final platform = FakePlatform();
    final h = await pumpZalos(tester, platform: platform);
    await openThreadByKey(tester, 'g01');
    final m = _byText(h, 'g01', 'Mẹ nấu canh chua rồi đó');
    final glyph = byKey('swipeReply-${m.id}');
    expect(glyph, findsOneWidget);
    expect(tester.widget<Opacity>(glyph).opacity, 0);
    expect(find.descendant(of: glyph, matching: find.byIcon(ZIcons.reply)), findsOneWidget);

    final gesture = await tester.startGesture(tester.getCenter(byKey('bubble-${m.id}')));
    // The first move crosses the touch slop and starts the drag.
    await gesture.moveBy(const Offset(24, 0));
    await tester.pump();
    await gesture.moveBy(const Offset(24, 0));
    await tester.pump();
    final mid = tester.widget<Opacity>(glyph).opacity;
    expect(mid, greaterThan(0));
    expect(mid, lessThan(1));
    await gesture.moveBy(const Offset(64, 0));
    await tester.pump();
    expect(tester.widget<Opacity>(glyph).opacity, 1);
    await gesture.up();
    await settle(tester);
    expect(byKey('replyBar'), findsOneWidget);
    expect(platform.haptics, 1);
    expect(tester.widget<Opacity>(glyph).opacity, 0);
    await drain(tester);
  });

  testWidgets('draft preview keeps unread styling and the danger tag', (tester) async {
    final h = await pumpZalos(tester, size: expanded);
    h.container.read(threadUiProvider((slot: 'main', id: 'u02'))).input.text = 'Mai mình qua nhé';
    await tester.pump();
    final preview = find.byWidgetPredicate((w) => w is Text && w.textSpan != null && w.textSpan!.toPlainText().contains('Mai mình qua nhé'));
    expect(preview, findsOneWidget);
    final text = tester.widget<Text>(preview);
    final z = tester.element(byKey('thread-u02')).z;
    expect(text.style!.color, z.textPrimary);
    final spans = (text.textSpan! as TextSpan).children!.cast<TextSpan>();
    expect(spans.first.style!.color, z.danger);
    expect(spans.last.style?.color, isNull, reason: 'the draft body follows the unread-aware preview style');
    await drain(tester);
  });

  testWidgets('wide filter underline covers the row divider', (tester) async {
    await pumpZalos(tester, size: expanded);
    expect(tester.getSize(byKey('filter-all')).height, 32);
    await tapKey(tester, 'filter-unread');
    expect(tester.getSize(byKey('filter-unread')).height, 32, reason: 'the underline sits on the divider instead of stacking above it');
    expect(byKey('thread-u01'), findsNothing);
    expect(byKey('thread-u02'), findsOneWidget);
    await drain(tester);
  });

  for (final entry in {'pointer': expanded, 'touch': compact}.entries) {
    testWidgets('pending attachment remove control keeps a ${entry.key} hit target', (tester) async {
      final platform = FakePlatform();
      await pumpZalos(tester, size: entry.value, platform: platform);
      await openThreadByKey(tester, 'u02');
      platform.dropOnDrop!([PickedFile('bao-cao.pdf', Uint8List(2048))]);
      await settle(tester);
      expect(byKey('pendingAttachments'), findsOneWidget);

      final remove = byKey('pendingRemove-0');
      final target = entry.key == 'pointer' ? ZSizes.pointerTarget : ZSizes.touchTarget;
      expect(tester.getSize(remove), Size(target, target));
      final glyph = find.descendant(of: remove, matching: find.byType(SizedBox)).first;
      expect(tester.getSize(glyph), const Size(20, 20));

      await tapKey(tester, 'pendingRemove-0', scroll: false);
      expect(byKey('pendingAttachments'), findsNothing);
      await drain(tester);
    });
  }
}
