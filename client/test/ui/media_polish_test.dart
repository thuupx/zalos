import 'package:material_ui/material_ui.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:zalos/src/domain/models.dart';
import 'package:zalos/src/ui/chat/message_content.dart';
import 'package:zalos/src/ui/components/avatar.dart';
import 'package:zalos/src/ui/theme/theme.dart';

import '../support/harness.dart';

Finder _shuttle() => byKey('mediaHeroShuttle');

Finder _viewerImages() => find.descendant(of: byKey('mediaViewer'), matching: find.byType(MediaImage));

/// The 3 picture grid in g01; its pictures are items 1 to 3 of the viewer.
Message _grid(Harness h) => h.main.messages('g01', ThreadType.group).value.firstWhere((m) => m.attachments.length == 3);

Future<void> _openThumb(WidgetTester tester, Message m, int index) async {
  final thumb = find.descendant(of: byKey('media-${m.id}'), matching: find.bySemanticsLabel('Mở hình ảnh')).at(index);
  await tester.ensureVisible(thumb);
  await tester.pump();
  await tester.tap(thumb);
}

/// Taps a thumbnail and stops a little way into the push transition.
Future<void> _openMidFlight(WidgetTester tester, Message m, int index) async {
  await _openThumb(tester, m, index);
  await tester.pump();
  await tester.pump();
  await tester.pump(const Duration(milliseconds: 60));
}

void main() {
  testWidgets('hero flight keeps the thumbnail cover crop and lands on contain', (tester) async {
    final h = await pumpZalos(tester, size: const Size(1440, 2600));
    await openThreadByKey(tester, 'g01');
    final grid = _grid(h);

    await _openMidFlight(tester, grid, 1);
    final shuttle = _shuttle();
    expect(shuttle, findsOneWidget, reason: 'the flight must use its own shuttle');
    final flying = tester.widget<MediaImage>(find.descendant(of: shuttle, matching: find.byType(MediaImage)));
    expect(flying.fit, BoxFit.cover, reason: 'the crop must not morph into contain mid-flight');
    expect(flying.url, grid.attachments[1].url);

    await settle(tester);
    expect(_shuttle(), findsNothing);
    final settled = tester.widgetList<MediaImage>(_viewerImages());
    expect(settled, isNotEmpty);
    expect(settled.every((image) => image.fit == BoxFit.contain), isTrue, reason: 'the settled viewer shows the whole picture');
    await drain(tester);
  });

  testWidgets('reduced motion opens the viewer without a hero flight', (tester) async {
    final h = await pumpZalos(tester, size: const Size(1440, 2600), reduceMotion: true);
    await openThreadByKey(tester, 'g01');
    final grid = _grid(h);
    expect(find.byType(Hero), findsNothing, reason: 'no hero is armed when motion is reduced');

    await _openMidFlight(tester, grid, 1);
    expect(_shuttle(), findsNothing);
    expect(find.byType(Hero), findsNothing);

    await settle(tester);
    expect(byKey('mediaViewer'), findsOneWidget);
    expect(tester.widgetList<MediaImage>(_viewerImages()).every((image) => image.fit == BoxFit.contain), isTrue);
    await drain(tester);
  });

  testWidgets('the viewer announces the sender and the position of each page', (tester) async {
    final h = await pumpZalos(tester, size: const Size(1440, 2600));
    await openThreadByKey(tester, 'g01');
    await _openThumb(tester, _grid(h), 1);
    await settle(tester);

    final first = tester.getSemantics(byKey('viewerSemantics')).label;
    expect(first, contains('Phạm Gia Huy'));
    expect(first, contains('3/5'));
    expect(find.bySemanticsLabel(RegExp('Phạm Gia Huy.*3/5')), findsOneWidget);

    await sendKey(tester, LogicalKeyboardKey.arrowRight);
    expect(tester.getSemantics(byKey('viewerSemantics')).label, contains('4/5'));

    await sendKey(tester, LogicalKeyboardKey.arrowRight);
    expect(tester.getSemantics(byKey('viewerSemantics')).label, contains('[Video]'));
    await drain(tester);
  });

  testWidgets('selectable message text offers copy and select all', (tester) async {
    await tester.pumpWidget(MaterialApp(
      theme: buildZalosTheme(Brightness.light),
      locale: const Locale('vi'),
      supportedLocales: const [Locale('vi'), Locale('en')],
      localizationsDelegates: GlobalMaterialLocalizations.delegates,
      home: Material(
        child: Center(
          child: MessageText(
            text: 'Mẹ nấu canh chua rồi đó',
            mentions: const [],
            style: const TextStyle(fontSize: 16),
            selectable: true,
            onOpenLink: (_) {},
          ),
        ),
      ),
    ));
    await tester.longPress(find.byType(SelectableText));
    await tester.pumpAndSettle();

    expect(find.text('Sao chép'), findsOneWidget);
    expect(find.text('Chọn tất cả'), findsOneWidget);
  });
}
