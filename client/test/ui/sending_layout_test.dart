import 'package:material_ui/material_ui.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:zalos/src/domain/models.dart';

import '../support/fake_zalos.dart';
import '../support/harness.dart';

const _labels = <String, List<String>>{
  'vi': ['Đang gửi', 'Đã gửi', 'Đã nhận', 'Đã xem'],
  'en': ['Sending', 'Sent', 'Delivered', 'Seen'],
};

Message _latest(Harness h) => h.main.messages('u02', ThreadType.user).value.last;

/// Proves [after] sits exactly where [before] did.
void _expectUnmoved(Rect after, Rect before, String step) {
  expect(after.left, before.left, reason: '$step: left edge moved');
  expect(after.top, before.top, reason: '$step: top edge moved');
  expect(after.right, before.right, reason: '$step: right edge moved');
  expect(after.bottom, before.bottom, reason: '$step: bottom edge moved');
}

void main() {
  for (final size in {'compact': compact, 'wide': expanded}.entries) {
    for (final language in const ['vi', 'en']) {
      testWidgets('a one character message holds its layout from sending through seen (${size.key}, $language)', (tester) async {
        final labels = _labels[language]!;
        final h = await pumpZalos(
          tester,
          size: size.value,
          prefs: {'language': language},
          app: FakeZalosApp(latency: const Duration(milliseconds: 800)),
        );
        await settle(tester, const Duration(seconds: 2));
        await openThreadByKey(tester, 'u02');
        await settle(tester, const Duration(seconds: 1));

        await tester.enterText(byKey('composerField'), 'a');
        await tester.pump();
        await tester.tap(byKey('sendButton'));
        await tester.pump();
        final id = _latest(h).id;
        expect(_latest(h).sendState, SendState.sending);

        // Entrance and the scroll to the new row finish while the send is
        // still pending, so the first measurement is the settled sending row.
        await settle(tester, const Duration(milliseconds: 500));
        expect(_latest(h).sendState, SendState.sending);
        expect(find.descendant(of: byKey('bubble-$id'), matching: find.byKey(const ValueKey('sending'))), findsOneWidget);
        expect(find.bySemanticsLabel(RegExp(RegExp.escape(labels[0]))), findsOneWidget);
        final sendingBubble = tester.getRect(byKey('bubble-$id'));
        final sendingMeta = tester.getRect(byKey('meta-$id'));
        final slotWidth = tester.getSize(byKey('status-$id')).width;

        // The send completes: the clock glyph gives way to the delivery label
        // in the same slot.
        await tester.pump(const Duration(milliseconds: 400));
        await tester.pump();
        await settle(tester, const Duration(milliseconds: 300));
        expect(_latest(h).sendState, SendState.sent);
        expect(find.descendant(of: byKey('bubble-$id'), matching: find.text(labels[1])), findsOneWidget);
        expect(find.bySemanticsLabel(RegExp(RegExp.escape(labels[1]))), findsOneWidget);
        _expectUnmoved(tester.getRect(byKey('bubble-$id')), sendingBubble, 'sent');
        _expectUnmoved(tester.getRect(byKey('meta-$id')), sendingMeta, 'sent');
        expect(tester.getSize(byKey('status-$id')).width, slotWidth, reason: 'sent: status slot resized');
        // The reserved room already fits the label and its leading padding.
        final sentLabel = tester.getSize(byKey('state-$id'));
        expect(slotWidth, greaterThanOrEqualTo(sentLabel.width + 6 - 0.01));

        // Delivery updates only cross-fade the label inside that room.
        for (final (state, label) in [
          (DeliveryState.delivered, labels[2]),
          (DeliveryState.seen, labels[3]),
        ]) {
          h.main.replace(_latest(h), (m) => h.main.copy(m, deliveryState: state));
          await tester.pump();
          await settle(tester, const Duration(milliseconds: 300));
          expect(find.descendant(of: byKey('bubble-$id'), matching: find.text(label)), findsOneWidget);
          expect(find.bySemanticsLabel(RegExp(RegExp.escape(label))), findsOneWidget);
          _expectUnmoved(tester.getRect(byKey('bubble-$id')), sendingBubble, label);
          _expectUnmoved(tester.getRect(byKey('meta-$id')), sendingMeta, label);
          expect(tester.getSize(byKey('status-$id')).width, slotWidth, reason: '$label: status slot resized');
        }
        await drain(tester);
      });
    }
  }
}
