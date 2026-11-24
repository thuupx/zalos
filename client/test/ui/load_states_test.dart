import 'package:flutter_test/flutter_test.dart';
import 'package:zalos/src/domain/models.dart';
import 'package:zalos/src/ui/state/app_state.dart';

import '../support/fake_zalos.dart';
import '../support/harness.dart';

const _latency = Duration(milliseconds: 300);

Future<void> _retry(WidgetTester tester, String within) async {
  await tester.tap(find.descendant(of: byKey(within), matching: find.text('Thử lại')));
  await tester.pump();
}

void _open(Harness h, String id, String name) {
  h.container.read(openThreadProvider.notifier).state = OpenThread(slot: 'main', id: id, type: ThreadType.user, name: name, avatarUrl: '');
}

void main() {
  group('thread list', () {
    for (final entry in sizes.entries) {
      testWidgets('loading then ready and empty at ${entry.key}', (tester) async {
        await pumpZalos(tester, app: FakeZalosApp(empty: true, latency: _latency), size: entry.value);
        expect(byKey('threadsLoading'), findsOneWidget);
        expect(byKey('threadsEmpty'), findsNothing);
        await settle(tester);
        expect(byKey('threadsLoading'), findsNothing);
        expect(byKey('threadsEmpty'), findsOneWidget);
        await drain(tester);
      });
    }

    testWidgets('cached threads show at once while loading', (tester) async {
      final h = await pumpZalos(tester, app: FakeZalosApp(latency: _latency), size: expanded);
      expect(h.main.threadsLoad.value, LoadState.loading);
      expect(byKey('threadsLoading'), findsNothing);
      expect(byKey('threadList'), findsOneWidget);
      await settle(tester);
      expect(byKey('threadsStaleBanner'), findsNothing);
      await drain(tester);
    });

    testWidgets('failed with no threads: error state, retry recovers', (tester) async {
      final app = FakeZalosApp(empty: true, latency: _latency);
      app.fakeLink.session('main').failNextThreadsLoad = true;
      final h = await pumpZalos(tester, app: app, size: expanded);
      await settle(tester);
      expect(byKey('threadsError'), findsOneWidget);
      expect(find.text('Không tải được danh sách hội thoại'), findsOneWidget);
      expect(byKey('threadsEmpty'), findsNothing);

      await _retry(tester, 'threadsError');
      expect(h.main.reloadThreadsCalls, 1);
      expect(byKey('threadsLoading'), findsOneWidget);
      await settle(tester);
      expect(byKey('threadsError'), findsNothing);
      expect(byKey('threadsEmpty'), findsOneWidget);
      await drain(tester);
    });

    testWidgets('failed with cached threads: inline banner above the list, retry clears it', (tester) async {
      final app = FakeZalosApp();
      app.fakeLink.session('main').failNextThreadsLoad = true;
      final h = await pumpZalos(tester, app: app, size: compact);
      expect(byKey('threadsStaleBanner'), findsOneWidget);
      expect(find.text('Chưa cập nhật được danh sách hội thoại'), findsOneWidget);
      expect(byKey('threadList'), findsOneWidget);
      expect(byKey('threadsError'), findsNothing);
      expect(tester.getBottomLeft(byKey('threadsStaleBanner')).dy, lessThanOrEqualTo(tester.getTopLeft(byKey('threadList')).dy));

      await _retry(tester, 'threadsStaleBanner');
      await settle(tester);
      expect(h.main.reloadThreadsCalls, 1);
      expect(byKey('threadsStaleBanner'), findsNothing);
      expect(byKey('threadList'), findsOneWidget);
      await drain(tester);
    });
  });

  group('chat first page', () {
    testWidgets('loading then ready and empty', (tester) async {
      final h = await pumpZalos(tester, app: FakeZalosApp(latency: _latency), size: expanded);
      await settle(tester);
      _open(h, 'u14', 'Ông Hạnh chủ nhà');
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 50));
      expect(byKey('messagesLoading'), findsOneWidget);
      expect(byKey('messagesEmpty'), findsNothing);
      await settle(tester);
      expect(byKey('messagesLoading'), findsNothing);
      expect(byKey('messagesEmpty'), findsOneWidget);
      await drain(tester);
    });

    testWidgets('cached messages show at once while loading', (tester) async {
      final h = await pumpZalos(tester, app: FakeZalosApp(latency: _latency), size: expanded);
      await settle(tester);
      _open(h, 'u01', 'Nguyễn Thị Lan');
      await tester.pump();
      expect(h.main.messagesLoad('u01', ThreadType.user).value, LoadState.loading);
      expect(byKey('messageList'), findsOneWidget);
      expect(byKey('messagesLoading'), findsNothing);
      await settle(tester);
      expect(byKey('messagesStaleBanner'), findsNothing);
      await drain(tester);
    });

    testWidgets('failed with no messages: error state, retry recovers', (tester) async {
      final h = await pumpZalos(tester, app: FakeZalosApp(latency: _latency), size: expanded);
      await settle(tester);
      h.main.failNextMessagesLoad = true;
      _open(h, 'u14', 'Ông Hạnh chủ nhà');
      await settle(tester);
      expect(byKey('messagesError'), findsOneWidget);
      expect(find.text('Không tải được tin nhắn'), findsOneWidget);
      expect(byKey('messagesEmpty'), findsNothing);

      await _retry(tester, 'messagesError');
      expect(h.main.reloadMessagesCalls, 1);
      expect(byKey('messagesLoading'), findsOneWidget);
      await settle(tester);
      expect(byKey('messagesError'), findsNothing);
      expect(byKey('messagesEmpty'), findsOneWidget);
      await drain(tester);
    });

    testWidgets('failed with cached messages: inline banner, retry clears it', (tester) async {
      final h = await pumpZalos(tester, size: expanded);
      h.main.failNextMessagesLoad = true;
      await openThreadByKey(tester, 'u01');
      expect(byKey('messagesStaleBanner'), findsOneWidget);
      expect(find.text('Chưa tải được tin nhắn mới nhất'), findsOneWidget);
      expect(byKey('messageList'), findsOneWidget);
      expect(byKey('messagesError'), findsNothing);

      await _retry(tester, 'messagesStaleBanner');
      await settle(tester);
      expect(h.main.reloadMessagesCalls, 1);
      expect(byKey('messagesStaleBanner'), findsNothing);
      expect(byKey('messageList'), findsOneWidget);
      await drain(tester);
    });
  });
}
