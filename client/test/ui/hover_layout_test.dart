import 'package:flutter_test/flutter_test.dart';
import 'package:zalos/src/domain/models.dart';

import '../support/harness.dart';

void main() {
  testWidgets('hovering a message never moves any bubble (reaction slot is reserved)', (tester) async {
    final h = await pumpZalos(tester, size: expanded);
    await openThreadByKey(tester, 'g01');
    final msgs = h.main.messages('g01', ThreadType.group).value;
    final target = msgs.lastWhere((m) => !m.isSelf && m.kind == MessageKind.text && m.reactions.isEmpty);
    final visible = [for (final m in msgs) if (byKey('bubble-${m.id}').evaluate().isNotEmpty) m.id];
    final before = {for (final id in visible) id: tester.getRect(byKey('bubble-$id'))};
    await hover(tester, byKey('bubble-${target.id}'));
    await settle(tester);
    expect(byKey('reactButton-${target.id}'), findsOneWidget);
    for (final id in visible) {
      expect(tester.getRect(byKey('bubble-$id')), before[id], reason: 'bubble $id moved on hover');
    }
    await drain(tester);
  });
}
