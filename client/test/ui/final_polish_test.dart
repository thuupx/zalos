import 'package:material_ui/material_ui.dart';
import 'package:flutter/semantics.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:zalos/src/domain/models.dart';
import 'package:zalos/src/ui/chat/message_content.dart';
import 'package:zalos/src/ui/chat/message_row.dart';
import 'package:zalos/src/ui/components/avatar.dart';
import 'package:zalos/src/ui/components/basics.dart';
import 'package:zalos/src/ui/components/motion.dart';
import 'package:zalos/src/ui/theme/theme.dart';
import 'package:zalos/src/ui/theme/tokens.dart';

import '../support/fake_platform.dart';
import '../support/harness.dart';

/// The 3 picture grid in g01; the viewer opens on it before the video.
Message _grid(Harness h) => h.main.messages('g01', ThreadType.group).value.firstWhere((m) => m.attachments.length == 3);

Message _video(Harness h) => h.main.messages('g01', ThreadType.group).value.firstWhere((m) => m.kind == MessageKind.video);

Widget _themed(Widget child, {bool reduce = false}) => MaterialApp(
      theme: buildZalosTheme(Brightness.light),
      home: MediaQuery(data: MediaQueryData(disableAnimations: reduce), child: Center(child: child)),
    );

/// True when [label] is part of the compiled semantics tree, not just of a
/// widget that paints it.
bool _announced(WidgetTester tester, String label) {
  final root = tester.binding.renderViews.first.owner?.semanticsOwner?.rootSemanticsNode;
  if (root == null) return false;
  var found = false;
  void visit(SemanticsNode node) {
    if (node.label.contains(label)) found = true;
    node.visitChildren((child) {
      visit(child);
      return !found;
    });
  }

  visit(root);
  return found;
}

void main() {
  testWidgets('a leaving pane is painted but cannot be focused or announced', (tester) async {
    final semantics = tester.ensureSemantics();
    final node = FocusNode(debugLabel: 'paneButton');
    addTearDown(node.dispose);
    Widget host(bool show) => MaterialApp(
          home: Scaffold(
            body: ZPresence(
              child: show
                  ? Semantics(
                      key: const Key('paneBody'),
                      label: 'pane',
                      child: Focus(focusNode: node, child: const SizedBox(width: 40, height: 40)),
                    )
                  : null,
              builder: (context, animation, child) => FadeTransition(opacity: animation, child: child),
            ),
          ),
        );

    await tester.pumpWidget(host(true));
    await tester.pumpAndSettle();
    expect(node.canRequestFocus, isTrue);
    expect(_announced(tester, 'pane'), isTrue);

    await tester.pumpWidget(host(false));
    await tester.pump(ZMotion.exit ~/ 2);
    expect(find.descendant(of: find.byType(ZPresence), matching: find.byType(FadeTransition)), findsOneWidget, reason: 'the pane is still painted through its exit');
    expect(node.context, isNotNull);
    expect(node.canRequestFocus, isFalse, reason: 'Tab must skip a pane that is leaving');
    node.requestFocus();
    await tester.pump();
    expect(node.hasPrimaryFocus, isFalse);
    expect(_announced(tester, 'pane'), isFalse, reason: 'a pane that is leaving is no longer announced');

    await tester.pumpAndSettle();
    expect(byKey('paneBody'), findsNothing, reason: 'the pane is dropped once its exit completes');
    expect(find.descendant(of: find.byType(ZPresence), matching: find.byType(FadeTransition)), findsNothing);
    semantics.dispose();
  });

  testWidgets('neighbouring video pages stay closed until they are the page on screen', (tester) async {
    final platform = FakePlatform();
    final h = await pumpZalos(tester, size: const Size(1440, 2600), platform: platform);
    await openThreadByKey(tester, 'g01');
    final grid = _grid(h);
    final video = _video(h);
    final videoUrl = video.attachments.first.url;

    final thumb = find.descendant(of: byKey('media-${grid.id}'), matching: find.bySemanticsLabel('Mở hình ảnh')).first;
    await tester.ensureVisible(thumb);
    await tester.pump();
    await tester.tap(thumb);
    await settle(tester);
    expect(byKey('mediaViewer'), findsOneWidget);
    expect(tester.getSemantics(byKey('viewerSemantics')).label, isNot(contains('[Video]')));
    expect(cachedMedia(h.main, videoUrl), isNull, reason: 'a video page that is not on screen must not download');
    expect(platform.players, isEmpty, reason: 'no player is created for a video that is not shown');

    for (var i = 0; i < 4 && !tester.getSemantics(byKey('viewerSemantics')).label.contains('[Video]'); i++) {
      await sendKey(tester, LogicalKeyboardKey.arrowRight);
    }
    expect(tester.getSemantics(byKey('viewerSemantics')).label, contains('[Video]'));
    await settle(tester);
    expect(cachedMedia(h.main, videoUrl), isNotNull, reason: 'the video opens once it becomes the page on screen');
    expect(platform.players, hasLength(1));
    expect(platform.players.single.uri, isNotNull);
    expect(platform.players.single.status.value.playing, isTrue);
    await drain(tester);
  });

  testWidgets('the hero shuttle falls back to the bubble thumbnail, never a blank rect', (tester) async {
    final h = await pumpZalos(tester, size: expanded);
    const attachment = Attachment(kind: MessageKind.image, url: 'fake://photo/full', thumbUrl: 'fake://photo/thumb');
    h.app.flags.failMedia.add(attachment.url);
    final shuttle = mediaHeroShuttle(h.main, attachment);
    await tester.pumpWidget(MaterialApp(
      theme: buildZalosTheme(Brightness.light),
      home: Builder(
        builder: (context) => shuttle(context, kAlwaysCompleteAnimation, HeroFlightDirection.push, context, context),
      ),
    ));

    Iterable<MediaImage> shuttled() => tester.widgetList<MediaImage>(find.descendant(of: byKey('mediaHeroShuttle'), matching: find.byType(MediaImage)));
    expect(shuttled().first.fit, BoxFit.cover);
    expect(shuttled().first.url, attachment.url);
    expect(shuttled().last.url, attachment.thumbUrl, reason: 'the thumbnail stands in while the full picture loads');
    expect(shuttled().last.fit, BoxFit.cover);

    await settle(tester);
    expect(shuttled().last.url, attachment.thumbUrl, reason: 'a full picture that fails falls back to the thumbnail');
    expect(shuttled().last.fit, BoxFit.cover);
    await drain(tester);
  });

  testWidgets('reduced motion turns viewer pages without sliding', (tester) async {
    final h = await pumpZalos(tester, size: const Size(1440, 2600), reduceMotion: true);
    await openThreadByKey(tester, 'g01');
    final grid = _grid(h);
    final thumb = find.descendant(of: byKey('media-${grid.id}'), matching: find.bySemanticsLabel('Mở hình ảnh')).first;
    await tester.ensureVisible(thumb);
    await tester.pump();
    await tester.tap(thumb);
    await settle(tester);
    final before = tester.getSemantics(byKey('viewerSemantics')).label;

    await tester.sendKeyEvent(LogicalKeyboardKey.arrowRight);
    await tester.pump();
    expect(tester.getSemantics(byKey('viewerSemantics')).label, isNot(before), reason: 'the next page is already on screen after one frame');
    await drain(tester);
  });

  testWidgets('a cancelled swipe down puts the picture back where it was', (tester) async {
    final h = await pumpZalos(tester, size: const Size(1440, 2600));
    await openThreadByKey(tester, 'g01');
    final grid = _grid(h);
    final thumb = find.descendant(of: byKey('media-${grid.id}'), matching: find.bySemanticsLabel('Mở hình ảnh')).first;
    await tester.ensureVisible(thumb);
    await tester.pump();
    await tester.tap(thumb);
    await settle(tester);

    double drop() => tester
        .widget<Transform>(find.ancestor(of: byKey('viewerSemantics'), matching: find.byType(Transform)).first)
        .transform
        .getTranslation()
        .y;

    final gesture = await tester.startGesture(tester.getCenter(byKey('mediaViewer')));
    await gesture.moveBy(const Offset(0, 30));
    await tester.pump();
    await gesture.moveBy(const Offset(0, 30));
    await tester.pump();
    expect(drop(), greaterThan(0));
    await gesture.cancel();
    await tester.pump();
    expect(drop(), 0);
    expect(byKey('mediaViewer'), findsOneWidget);
    await drain(tester);
  });

  testWidgets('day pill and reduced motion surfaces follow the shared tokens', (tester) async {
    await tester.pumpWidget(_themed(const DayPill(text: 'Hôm nay')));
    final pill = tester.widget<Container>(find.descendant(of: find.byType(DayPill), matching: find.byType(Container)).first);
    expect((pill.decoration! as BoxDecoration).borderRadius, BorderRadius.circular(ZRadius.pill));

    await tester.pumpWidget(_themed(const ZSkeleton(key: Key('skeleton'), width: 40, height: 12), reduce: true));
    expect(find.descendant(of: byKey('skeleton'), matching: find.byType(AnimatedBuilder)), findsNothing);
    await tester.pumpWidget(_themed(const ZSkeleton(key: Key('skeleton'), width: 40, height: 12)));
    expect(find.descendant(of: byKey('skeleton'), matching: find.byType(AnimatedBuilder)), findsOneWidget);
    await tester.pumpWidget(const SizedBox());
  });

  testWidgets('reduced motion leaves the typing dots still', (tester) async {
    final h = await pumpZalos(tester, size: expanded, reduceMotion: true);
    await openThreadByKey(tester, 'u02');
    h.main.emitTyping('u02', 'u02');
    await settle(tester, const Duration(milliseconds: 200));
    expect(byKey('typingIndicator'), findsOneWidget);

    Color dotColor() {
      final dots = tester.widgetList<Container>(find.descendant(of: byKey('typingIndicator'), matching: find.byType(Container))).toList();
      return (dots.last.decoration! as BoxDecoration).color!;
    }

    final before = dotColor();
    await tester.pump(const Duration(milliseconds: 300));
    expect(dotColor(), before);
    await drain(tester);
  });
}
