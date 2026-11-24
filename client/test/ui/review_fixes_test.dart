import 'package:material_ui/material_ui.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:zalos/src/domain/models.dart';
import 'package:zalos/src/ui/components/pressable.dart';
import 'package:zalos/src/ui/platform/services.dart';
import 'package:zalos/src/ui/theme/tokens.dart';

import '../support/fake_platform.dart';
import '../support/fake_zalos.dart';
import '../support/harness.dart';

void main() {
  testWidgets('rail: settings button is pinned to the bottom', (tester) async {
    await pumpZalos(tester, size: expanded);
    final rail = tester.getRect(byKey('accountRail'));
    final me = tester.getRect(byKey('railTab-me'));
    expect(rail.bottom - me.bottom, lessThan(24));
    expect(tester.getRect(byKey('railTab-contacts')).bottom, lessThan(rail.height / 2));
    await drain(tester);
  });

  testWidgets('wide chat uses the full pane: incoming at the left edge, outgoing at the right', (tester) async {
    final h = await pumpZalos(tester, size: expanded);
    await openThreadByKey(tester, 'g01');
    final list = tester.getRect(byKey('messageList'));
    final msgs = h.main.messages('g01', ThreadType.group).value;
    final incoming = msgs.lastWhere((m) => !m.isSelf && m.kind == MessageKind.text);
    final outgoing = msgs.lastWhere((m) => m.isSelf && m.kind == MessageKind.text);
    // Layout geometry: 16 px side padding, incoming content at 50 px
    // (40 px avatar + 10 px gap).
    expect(tester.getRect(byKey('bubble-${incoming.id}')).left - list.left, 66);
    expect(list.right - tester.getRect(byKey('bubble-${outgoing.id}')).right, 16);
    await drain(tester);
  });

  testWidgets('unread divider: set once at open, gone after sending and after reopening', (tester) async {
    final h = await pumpZalos(tester, size: expanded);
    await openThreadByKey(tester, 'g01');
    expect(byKey('unreadDivider'), findsOneWidget);
    h.main.receive('g01', 'tới khi đang mở', from: 'u04');
    await settle(tester);
    expect(byKey('unreadDivider'), findsOneWidget);
    await tester.enterText(byKey('composerField'), 'đã đọc rồi');
    await tester.pump();
    await tapKey(tester, 'sendButton', scroll: false);
    expect(byKey('unreadDivider'), findsNothing);
    h.main.receive('g01', 'vẫn đang mở', from: 'u04');
    await settle(tester);
    expect(byKey('unreadDivider'), findsNothing, reason: 'messages arriving while visible never add a divider');
    await openThreadByKey(tester, 'u02');
    await tester.fling(byKey('threadList'), const Offset(0, 3000), 3000);
    await settle(tester);
    await openThreadByKey(tester, 'g01');
    expect(byKey('unreadDivider'), findsNothing, reason: 'read on the last visit');
    await h.main.markUnread('g01', ThreadType.group);
    await settle(tester);
    expect(h.main.threads.value.firstWhere((t) => t.id == 'g01').unread, 1, reason: 'mark unread on the open thread sticks');
    await drain(tester);
  });

  testWidgets('send button is brand filled when there is content and disabled otherwise', (tester) async {
    await pumpZalos(tester, size: expanded);
    await openThreadByKey(tester, 'u02');
    ZIconButton button() => tester.widget<ZIconButton>(byKey('sendButton'));
    expect(button().onPressed, isNull);
    expect(button().fill, isNull);
    await tester.enterText(byKey('composerField'), 'a');
    await tester.pump();
    expect(button().onPressed, isNotNull);
    expect(button().fill, ZalosTokens.light.brand);
    await drain(tester);
  });

  testWidgets('text styles use Plus Jakarta Sans with platform and color emoji fallbacks', (tester) async {
    final body = ZalosTokens.light.text.body;
    expect(body.fontFamily, ZType.fontFamily);
    expect(body.fontFamilyFallback, containsAll(<String>['system-ui', 'Apple Color Emoji', 'Noto Color Emoji']));
  });

  testWidgets('list times tick without new data', (tester) async {
    final h = await pumpZalos(tester, size: expanded);
    var now = fakeNow;
    h.main.receive('u05', 'vừa gửi', ts: now.millisecondsSinceEpoch);
    await settle(tester);
    expect(find.descendant(of: byKey('thread-u05'), matching: find.text('vừa xong')), findsOneWidget);
    now = now.add(const Duration(minutes: 3));
    ZClockAccess.set(() => now);
    await tester.pump(const Duration(seconds: 31));
    expect(find.descendant(of: byKey('thread-u05'), matching: find.text('3 phút')), findsOneWidget);
    await drain(tester);
  });

  testWidgets('hover bar has react, reply and more', (tester) async {
    final h = await pumpZalos(tester, size: expanded);
    await openThreadByKey(tester, 'g01');
    final m = h.main.messages('g01', ThreadType.group).value.last;
    await hover(tester, byKey('bubble-${m.id}'));
    for (final k in ['hoverReact', 'hoverReply', 'hoverMore']) {
      expect(byKey('$k-${m.id}'), findsOneWidget);
    }
    await tapKey(tester, 'hoverReact-${m.id}', scroll: false);
    expect(byKey('reactionPicker'), findsOneWidget);
    await drain(tester);
  });

  testWidgets('image bubble: blurred thumb over a skeleton while loading, then fades in', (tester) async {
    final h = await pumpZalos(tester, size: expanded, app: FakeZalosApp(latency: const Duration(milliseconds: 300)));
    await settle(tester, const Duration(seconds: 1));
    await tester.tap(byKey('thread-u02'));
    final image = h.main.history('u02').lastWhere((m) => m.kind == MessageKind.image && m.attachments.length == 1);
    final bubble = byKey('bubble-${image.id}');
    Finder inBubble(Type type) => find.descendant(of: bubble, matching: find.byType(type));
    for (var i = 0; i < 20 && bubble.evaluate().isEmpty; i++) {
      await tester.pump(const Duration(milliseconds: 50));
    }
    await tester.ensureVisible(bubble);
    await tester.pump();
    expect(inBubble(ImageFiltered), findsOneWidget, reason: 'blurred thumb placeholder');
    expect(inBubble(Image), findsNothing);

    for (var i = 0; i < 20 && inBubble(Image).evaluate().isEmpty; i++) {
      await tester.pump(const Duration(milliseconds: 50));
    }
    await tester.runAsync(() => Future<void>.delayed(const Duration(milliseconds: 200)));
    await tester.pump();
    await tester.pump(ZDurations.fast);
    final fade = tester.widget<AnimatedOpacity>(find.descendant(of: inBubble(Image), matching: find.byType(AnimatedOpacity)).first);
    expect(fade.opacity, 1);
    await drain(tester);
  });

  testWidgets('search in conversation marks the match inside the bubble text', (tester) async {
    await pumpZalos(tester, size: expanded);
    await openThreadByKey(tester, 'u01');
    await tapKey(tester, 'chatSearch', scroll: false);
    await tester.enterText(byKey('chatSearchField'), 'minh');
    await settle(tester);
    final marked = find.byWidgetPredicate((w) {
      final text = switch (w) {
        RichText(:final text) => text,
        SelectableText(:final textSpan?) => textSpan,
        _ => null,
      };
      if (text == null) return false;
      var found = false;
      text.visitChildren((span) {
        if (span is TextSpan && span.style?.backgroundColor == ZalosTokens.light.accent) found = true;
        return !found;
      });
      return found;
    });
    expect(marked, findsWidgets);
    await tapKey(tester, 'chatSearchClose', scroll: false);
    expect(marked, findsNothing);
    await drain(tester);
  });

  testWidgets('a quote of media shows its summary, not an empty line', (tester) async {
    final h = await pumpZalos(tester, size: expanded);
    await openThreadByKey(tester, 'u02');
    final photo = h.main.messages('u02', ThreadType.user).value.lastWhere((m) => m.kind == MessageKind.image);
    await h.main.sendText('u02', ThreadType.user, 'đã xem ảnh', quote: photo);
    await settle(tester);
    final reply = h.main.messages('u02', ThreadType.user).value.last;
    expect(reply.quote!.text, isEmpty, reason: 'the server sends no text for media quotes');
    expect(find.descendant(of: byKey('quote-${reply.id}'), matching: find.text('[Hình ảnh]')), findsOneWidget);
    await drain(tester);
  });

  testWidgets('voice bubble fits a narrow chat pane while playing', (tester) async {
    final platform = FakePlatform();
    final h = await pumpZalos(tester, size: const Size(800, 600), platform: platform);
    await openThreadByKey(tester, 'u05');
    final voice = h.main.messages('u05', ThreadType.user).value.lastWhere((m) => m.kind == MessageKind.voice);
    await tapKey(tester, 'voicePlay-${voice.id}', scroll: false);
    platform.players.single.set(const PlaybackStatus(playing: true, position: Duration(seconds: 12), duration: Duration(seconds: 23), ready: true));
    await tester.pump();
    expect(find.text('0:12 / 0:23'), findsOneWidget);
    expect(tester.takeException(), isNull, reason: 'no overflow inside the bubble');
    await drain(tester);
  });
}
