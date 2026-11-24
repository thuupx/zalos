import 'package:material_ui/material_ui.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:zalos/src/domain/models.dart';
import 'package:zalos/src/ui/components/pressable.dart';
import 'package:zalos/src/ui/l10n/strings.dart';
import 'package:zalos/src/ui/platform/services.dart';
import 'package:zalos/src/ui/state/thread_ui.dart';
import 'package:zalos/src/ui/util/format.dart';
import 'package:zalos/src/ui/util/style_runs.dart';

import '../support/fake_platform.dart';
import '../support/fake_png.dart';
import '../support/fake_zalos.dart';
import '../support/harness.dart';

TextField _field(WidgetTester tester) => tester.widget<TextField>(byKey('composerField'));

DraftTextController _controller(WidgetTester tester) => _field(tester).controller! as DraftTextController;

Future<void> _select(WidgetTester tester, int start, int end) async {
  _controller(tester).selection = TextSelection(baseOffset: start, extentOffset: end);
  await settle(tester, const Duration(milliseconds: 300));
}

Future<void> _openMore(WidgetTester tester) async {
  await tapKey(tester, 'composerMore', scroll: false);
}

List<(int, int, String)> _runs(List<StyleRun> runs) => [for (final run in runs) (run.start, run.len, run.st)];

Message _message(
  MessageKind kind, {
  String? text,
  BankCard? bankCard,
  Location? location,
  Poll? poll,
  Note? note,
  Reminder? reminder,
  CallLog? callLog,
  Doodle? doodle,
  Album? album,
  Todo? todo,
  LinkPreview? linkPreview,
  List<Attachment> attachments = const [],
  List<StyleRun> styles = const [],
  MessageUrgency? urgency,
  int? ttl,
}) =>
    Message(
      id: 'm-${kind.name}',
      cliId: null,
      threadId: 'u02',
      threadType: ThreadType.user,
      senderId: 'u02',
      senderName: 'Trần Quốc Bảo',
      ts: 1000,
      isSelf: false,
      kind: kind,
      text: text,
      bankCard: bankCard,
      location: location,
      poll: poll,
      note: note,
      reminder: reminder,
      callLog: callLog,
      doodle: doodle,
      album: album,
      todo: todo,
      linkPreview: linkPreview,
      attachments: attachments,
      styles: styles,
      urgency: urgency,
      ttl: ttl,
    );

Thread _thread(Message message, {ThreadType type = ThreadType.user}) => Thread(
      id: 'u02',
      type: type,
      name: 'Trần Quốc Bảo',
      avatarUrl: '',
      lastMessage: message,
      lastTs: message.ts,
      unread: 0,
      pinned: false,
      muted: false,
    );

void main() {
  group('style runs', () {
    test('shift with insertions and deletions', () {
      const runs = [StyleRun(start: 0, len: 4, st: 'b')];
      expect(_runs(shiftStyleRuns(runs, 'abcd', 'abXcd')), [(0, 5, 'b')]);
      expect(_runs(shiftStyleRuns(runs, 'abcd', 'acd')), [(0, 3, 'b')]);
      expect(_runs(shiftStyleRuns(runs, 'abcd', 'abcdX')), [(0, 4, 'b')]);
      expect(_runs(shiftStyleRuns(runs, 'abcd', '')), isEmpty);
    });

    test('toggle adds, removes and splits', () {
      expect(_runs(toggleStyleRun(const [], 'b', 1, 3)), [(1, 2, 'b')]);
      expect(_runs(toggleStyleRun([const StyleRun(start: 0, len: 5, st: 'b')], 'b', 1, 3)), [(0, 1, 'b'), (3, 2, 'b')]);
      expect(styleRunsCover([const StyleRun(start: 0, len: 5, st: 'b')], 'b', 1, 3), isTrue);
      expect(styleRunsCover([const StyleRun(start: 0, len: 2, st: 'b')], 'b', 1, 3), isFalse);
    });

    test('shift follows trimmed leading and trailing whitespace', () {
      expect(_runs(shiftStyleRuns(const [StyleRun(start: 2, len: 3, st: 'b')], '  abc', 'abc')), [(0, 3, 'b')]);
      expect(_runs(shiftStyleRuns(const [StyleRun(start: 0, len: 3, st: 'b')], 'abc  ', 'abc')), [(0, 3, 'b')]);
      expect(_runs(shiftStyleRuns(const [StyleRun(start: 3, len: 2, st: 'b')], 'abc  ', 'abc')), isEmpty);
      expect(shiftTextOffset(2, '  abc', 'abc'), 0);
      expect(shiftTextOffset(0, 'abc', ' abc'), 1);
    });
  });

  group('mention picks', () {
    test('need a token boundary and keep the longest overlapping pick', () {
      expect(resolveMentionPicks('@Alice', const [MentionPick(name: 'Al', uid: 'a', start: 0)]), isEmpty);
      expect(resolveMentionPicks('@Alice', const [
        MentionPick(name: 'Al', uid: 'a', start: 0),
        MentionPick(name: 'Alice', uid: 'b', start: 0),
      ]).map((m) => m.uid), ['b']);
      expect(resolveMentionPicks('@Al X', const [
        MentionPick(name: 'Al', uid: 'a', start: 0),
        MentionPick(name: 'Al X', uid: 'b', start: 0),
      ]).single.uid, 'b');
      expect(resolveMentionPicks('@Al, ok', const [MentionPick(name: 'Al', uid: 'a', start: 0)]).single.len, 3);
      expect(resolveMentionPicks('Chào @Al', const [MentionPick(name: 'Al', uid: 'a', start: 5)]).single.pos, 5);
    });

    test('keep duplicate display names apart and drop edited-away tokens', () {
      expect(resolveMentionPicks('@Alice @Alice', const [
        MentionPick(name: 'Alice', uid: 'a', start: 0),
        MentionPick(name: 'Alice', uid: 'b', start: 7),
      ]).map((m) => m.uid), ['a', 'b']);
      expect(resolveMentionPicks('Chào bạn', const [MentionPick(name: 'Alice', uid: 'a', start: 0)]), isEmpty);
    });
  });

  testWidgets('styled text: selection toggles real runs, drafts keep them and sendText receives them', (tester) async {
    final h = await pumpZalos(tester, size: expanded);
    await openThreadByKey(tester, 'u02');
    await tester.enterText(byKey('composerField'), 'Xin chào cả nhà');
    await tester.pump();

    await _select(tester, 0, 3);
    expect(byKey('formatBar'), findsOneWidget);
    await tapKey(tester, 'formatBold', scroll: false);
    expect(_runs(_controller(tester).runs), [(0, 3, 'b')]);

    await _select(tester, 4, 8);
    await tapKey(tester, 'formatItalic', scroll: false);
    expect(_runs(_controller(tester).runs), [(0, 3, 'b'), (4, 4, 'i')]);

    await _select(tester, 0, 3);
    await tapKey(tester, 'formatBold', scroll: false);
    expect(_runs(_controller(tester).runs), [(4, 4, 'i')]);
    await tapKey(tester, 'formatBold', scroll: false);
    expect(_runs(_controller(tester).runs), [(0, 3, 'b'), (4, 4, 'i')]);

    await _select(tester, 9, 13);
    await sendKey(tester, LogicalKeyboardKey.keyU, control: true);
    expect(_runs(_controller(tester).runs), [(0, 3, 'b'), (4, 4, 'i'), (9, 4, 'u')]);

    await tapKey(tester, 'sendButton', scroll: false);
    final sent = h.main.sentTexts.last;
    expect(sent.text, 'Xin chào cả nhà');
    expect(_runs(sent.styles), [(0, 3, 'b'), (4, 4, 'i'), (9, 4, 'u')]);
    expect(_controller(tester).runs, isEmpty);
    await drain(tester);
  });

  testWidgets('send trims text and shifts style runs over the trimmed text', (tester) async {
    final h = await pumpZalos(tester, size: expanded);
    await openThreadByKey(tester, 'u02');
    await tester.enterText(byKey('composerField'), '  Xin chào  ');
    await tester.pump();
    await _select(tester, 2, 10);
    await tapKey(tester, 'formatBold', scroll: false);
    expect(_runs(_controller(tester).runs), [(2, 8, 'b')]);

    await tapKey(tester, 'sendButton', scroll: false);
    final sent = h.main.sentTexts.last;
    expect(sent.text, 'Xin chào');
    expect(_runs(sent.styles), [(0, 8, 'b')]);
    await drain(tester);
  });

  testWidgets('mention picks keep duplicate names apart and drop edited-away tokens', (tester) async {
    final h = await pumpZalos(tester, size: expanded);
    final index = h.main.contactList.indexWhere((c) => c.uid == 'u03');
    h.main.contactList[index] = const Contact(uid: 'u03', displayName: 'Phạm Gia Huy', avatarUrl: '');
    await openThreadByKey(tester, 'g01');

    await tester.enterText(byKey('composerField'), 'Chào @huy');
    await settle(tester);
    expect(byKey('mention-u04'), findsOneWidget);
    expect(byKey('mention-u03'), findsOneWidget);
    await tapKey(tester, 'mention-u04', scroll: false);
    expect(_field(tester).controller!.text, 'Chào @Phạm Gia Huy ');

    await tester.enterText(byKey('composerField'), 'Chào @Phạm Gia Huy và @huy');
    await settle(tester);
    await tapKey(tester, 'mention-u03', scroll: false);
    await tapKey(tester, 'sendButton', scroll: false);
    final sent = h.main.sentTexts.last;
    expect(sent.mentions.map((m) => m.uid), ['u04', 'u03']);
    expect(sent.mentions.map((m) => m.pos), [5, 22]);
    expect(sent.mentions.map((m) => m.len), [13, 13]);

    await tester.enterText(byKey('composerField'), '@huy');
    await settle(tester);
    await tapKey(tester, 'mention-u04', scroll: false);
    await tester.enterText(byKey('composerField'), 'Chào bạn');
    await tester.pump();
    await tapKey(tester, 'sendButton', scroll: false);
    expect(h.main.sentTexts.last.mentions, isEmpty);
    await drain(tester);
  });

  testWidgets('a picked mention shifts when leading whitespace is trimmed', (tester) async {
    final h = await pumpZalos(tester, size: expanded);
    await openThreadByKey(tester, 'g01');
    await tester.enterText(byKey('composerField'), '  @huy');
    await settle(tester);
    await tapKey(tester, 'mention-u04', scroll: false);
    await tapKey(tester, 'sendButton', scroll: false);
    final sent = h.main.sentTexts.last;
    expect(sent.text, '@Phạm Gia Huy');
    expect(sent.mentions.single.pos, 0);
    expect(sent.mentions.single.len, 13);
    await drain(tester);
  });

  testWidgets('drafts keep style runs per thread across navigation', (tester) async {
    await pumpZalos(tester, size: expanded);
    await openThreadByKey(tester, 'u02');
    await tester.enterText(byKey('composerField'), 'Bản nháp');
    await tester.pump();
    await _select(tester, 0, 4);
    await tapKey(tester, 'formatUnderline', scroll: false);
    expect(_runs(_controller(tester).runs), [(0, 4, 'u')]);

    await openThreadByKey(tester, 'u05');
    expect(_controller(tester).runs, isEmpty);
    await openThreadByKey(tester, 'u02');
    expect(_field(tester).controller!.text, 'Bản nháp');
    expect(_runs(_controller(tester).runs), [(0, 4, 'u')]);
    await drain(tester);
  });

  testWidgets('send options: urgency and ttl apply to the next text and clear after send', (tester) async {
    final h = await pumpZalos(tester, size: expanded);
    await openThreadByKey(tester, 'u02');
    await _openMore(tester);
    await tapKey(tester, 'menu-sendOptions', scroll: false);
    expect(byKey('sendOptionsSheet'), findsOneWidget);
    await tapKey(tester, 'urgency-urgent', scroll: false);
    expect(byKey('sendOptionsSheet'), findsNothing);
    expect(byKey('urgencyChip'), findsOneWidget);
    expect(find.descendant(of: byKey('urgencyChip'), matching: find.text('Khẩn cấp')), findsOneWidget);

    await _openMore(tester);
    await tapKey(tester, 'menu-sendOptions', scroll: false);
    await tapKey(tester, 'ttl-86400000', scroll: false);
    expect(byKey('ttlChip'), findsOneWidget);
    expect(find.descendant(of: byKey('ttlChip'), matching: find.text('1 ngày')), findsOneWidget);

    await tester.enterText(byKey('composerField'), 'Gấp nhé');
    await tester.pump();
    await tapKey(tester, 'sendButton', scroll: false);
    final sent = h.main.sentTexts.last;
    expect(sent.text, 'Gấp nhé');
    expect(sent.urgency, MessageUrgency.urgent);
    expect(sent.ttl, 86400000);
    expect(byKey('urgencyChip'), findsNothing);
    expect(byKey('ttlChip'), findsNothing);
    await drain(tester);
  });

  testWidgets('send options apply to attachments and keep their expiry metadata', (tester) async {
    final platform = FakePlatform();
    final h = await pumpZalos(tester, size: expanded, platform: platform);
    await openThreadByKey(tester, 'u02');
    await _openMore(tester);
    await tapKey(tester, 'menu-sendOptions', scroll: false);
    await tapKey(tester, 'urgency-important', scroll: false);
    await _openMore(tester);
    await tapKey(tester, 'menu-sendOptions', scroll: false);
    await tapKey(tester, 'ttl-3600000', scroll: false);

    platform.nextImages = [PickedFile('anh.png', fakePng('opt'))];
    await tapKey(tester, 'attachImageButton', scroll: false);
    await tapKey(tester, 'sendButton', scroll: false);

    final options = h.main.sentFileOptions.single;
    expect(options.urgency, MessageUrgency.important);
    expect(options.ttl, 3600000);
    final sent = h.main.messages('u02', ThreadType.user).value.last;
    expect(sent.kind, MessageKind.image);
    expect(sent.urgency, MessageUrgency.important);
    expect(sent.ttl, 3600000);
    expect(sent.expiresAt, isNotNull);
    await drain(tester);
  });

  testWidgets('compact composer exposes send options from the more menu without overflow', (tester) async {
    await pumpZalos(tester, size: compact);
    await openThreadByKey(tester, 'u02');
    await _openMore(tester);
    await tapKey(tester, 'menu-sendOptions', scroll: false);
    expect(byKey('sendOptionsSheet'), findsOneWidget);
    await tapKey(tester, 'urgency-important', scroll: false);
    expect(byKey('urgencyChip'), findsOneWidget);
    expect(tester.takeException(), isNull);
    await drain(tester);
  });

  testWidgets('link preview is debounced, dismissable and URL-only text sends through sendLink', (tester) async {
    final h = await pumpZalos(tester, size: expanded);
    await openThreadByKey(tester, 'u02');
    const url = 'https://thoitiet.example.vn/du-bao-cuoi-tuan';
    await tester.enterText(byKey('composerField'), url);
    await tester.pump();
    expect(byKey('linkPreviewLoading'), findsOneWidget);
    expect(h.main.parseLinkCalls, 0);
    await tester.pump(const Duration(milliseconds: 300));
    expect(h.main.parseLinkCalls, 0);

    await settle(tester, const Duration(milliseconds: 600));
    expect(h.main.parseLinkCalls, 1);
    expect(find.text('Dự báo thời tiết cuối tuần'), findsOneWidget);

    await tester.enterText(byKey('composerField'), 'https://example.vn/x');
    await tester.pump();
    await settle(tester, const Duration(milliseconds: 600));
    expect(h.main.parseLinkCalls, 2);

    await tapKey(tester, 'linkPreviewDismiss', scroll: false);
    expect(byKey('linkPreviewLoading'), findsNothing);
    expect(find.text('example.vn'), findsNothing);
    expect(h.main.parseLinkCalls, 2);

    await tester.enterText(byKey('composerField'), url);
    await tester.pump();
    await settle(tester, const Duration(milliseconds: 600));
    await tapKey(tester, 'sendButton', scroll: false);
    expect(h.main.sentLinks.single.link, url);
    expect(h.main.sentTexts, isEmpty);
    final sent = h.main.messages('u02', ThreadType.user).value.last;
    expect(sent.kind, MessageKind.link);
    expect(byKey('bubble-${sent.id}'), findsOneWidget);
    await drain(tester);
  });

  testWidgets('a URL inside ordinary text keeps the sendText path but still previews', (tester) async {
    final h = await pumpZalos(tester, size: expanded);
    await openThreadByKey(tester, 'u02');
    await tester.enterText(byKey('composerField'), 'Xem https://thoitiet.example.vn/du-bao-cuoi-tuan nhé');
    await tester.pump();
    await settle(tester, const Duration(milliseconds: 600));
    expect(h.main.parseLinkCalls, 1);
    await tapKey(tester, 'sendButton', scroll: false);
    expect(h.main.sentLinks, isEmpty);
    expect(h.main.sentTexts.single.text, 'Xem https://thoitiet.example.vn/du-bao-cuoi-tuan nhé');
    await drain(tester);
  });

  testWidgets('two URLs are not previewed', (tester) async {
    final h = await pumpZalos(tester, size: expanded);
    await openThreadByKey(tester, 'u02');
    await tester.enterText(byKey('composerField'), 'https://a.example.vn/x https://b.example.vn/y');
    await tester.pump();
    await settle(tester, const Duration(milliseconds: 600));
    expect(h.main.parseLinkCalls, 0);
    expect(byKey('linkPreviewLoading'), findsNothing);
    await drain(tester);
  });

  testWidgets('a .gif file is routed through the gif kind and opens in the media viewer', (tester) async {
    final platform = FakePlatform();
    final h = await pumpZalos(tester, size: expanded, platform: platform);
    await openThreadByKey(tester, 'u02');
    platform.nextFiles = [PickedFile('meme.GIF', Uint8List.fromList(fakePng('gif')))];
    await tapKey(tester, 'attachFileButton', scroll: false);
    expect(byKey('pendingAttachments'), findsOneWidget);
    await tapKey(tester, 'sendButton', scroll: false);

    expect(h.main.sentFiles.single.kind, MessageKind.gif);
    final sent = h.main.messages('u02', ThreadType.user).value.last;
    expect(sent.kind, MessageKind.gif);
    expect(byKey('bubble-${sent.id}'), findsOneWidget);
    await tester.tap(find.descendant(of: byKey('bubble-${sent.id}'), matching: find.bySemanticsLabel('Mở hình ảnh')));
    await settle(tester);
    expect(byKey('mediaViewer'), findsOneWidget);
    await drain(tester);
  });

  testWidgets('bank card: loads saved accounts, sends the real card and renders the echo', (tester) async {
    final h = await pumpZalos(tester, size: expanded);
    await openThreadByKey(tester, 'u02');
    await _openMore(tester);
    await tapKey(tester, 'menu-bankCard', scroll: false);
    expect(byKey('bankCardSheet'), findsOneWidget);
    expect(byKey('bankAccount-ba1'), findsOneWidget);
    expect(find.descendant(of: byKey('bankAccount-ba1'), matching: find.text('Mặc định')), findsOneWidget);

    await tapKey(tester, 'bankAccount-ba1', scroll: false);
    expect(h.main.sentBankCards.single.card.bin, 970436);
    expect(h.main.sentBankCards.single.card.accountNumber, '0071000123456');
    expect(byKey('bankCardSheet'), findsNothing);
    final sent = h.main.messages('u02', ThreadType.user).value.last;
    expect(sent.kind, MessageKind.bankCard);
    expect(byKey('bankCard-${sent.id}'), findsOneWidget);
    expect(find.text('Vietcombank'), findsWidgets);
    expect(find.text('0071000123456'), findsWidgets);
    await drain(tester);
  });

  testWidgets('bank accounts beyond the first page are listed once', (tester) async {
    final h = await pumpZalos(tester, size: expanded);
    h.main.bankAccountList.addAll([
      for (var i = 4; i <= 21; i++)
        BankAccount(
          id: 'ba$i',
          bin: 970436,
          accountNumber: '000$i',
          holderName: 'PHAM MINH THU',
          isDefault: false,
          accountId: i,
          createdAt: 1,
          updatedAt: 2,
          bankName: 'Vietcombank',
        ),
    ]);
    await openThreadByKey(tester, 'u02');
    await _openMore(tester);
    await tapKey(tester, 'menu-bankCard', scroll: false);
    await settle(tester);

    expect(byKey('bankAccount-ba1'), findsOneWidget);
    expect(byKey('bankAccount-ba21'), findsOneWidget);
    expect(h.main.bankAccountsCalls, 2);
    await drain(tester);
  });

  testWidgets('bank card states: loading, empty and a failed send keeps the sheet', (tester) async {
    final h = await pumpZalos(tester, size: expanded, app: FakeZalosApp(latency: const Duration(milliseconds: 200)));
    await openThreadByKey(tester, 'u02');
    await settle(tester, const Duration(seconds: 1));
    await _openMore(tester);
    await tester.tap(byKey('menu-bankCard'));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 100));
    expect(byKey('bankCardLoading'), findsOneWidget);
    await settle(tester, const Duration(seconds: 1));
    expect(byKey('bankAccount-ba1'), findsOneWidget);

    h.app.flags.failSends = true;
    await tapKey(tester, 'bankAccount-ba1', scroll: false);
    expect(byKey('bankCardSheet'), findsOneWidget);
    expect(find.text('Không gửi được thẻ ngân hàng'), findsOneWidget);
    h.app.flags.failSends = false;
    await tapKey(tester, 'bankAccount-ba1', scroll: false);
    expect(byKey('bankCardSheet'), findsNothing);

    h.main.bankAccountList.clear();
    await _openMore(tester);
    await tapKey(tester, 'menu-bankCard', scroll: false);
    await settle(tester, const Duration(seconds: 1));
    expect(byKey('bankCardEmpty'), findsOneWidget);
    await drain(tester);
  });

  testWidgets('quick messages: search, insert text and media, add, edit and delete', (tester) async {
    final platform = FakePlatform();
    final h = await pumpZalos(tester, size: expanded, platform: platform);
    await openThreadByKey(tester, 'u02');
    await _openMore(tester);
    await tapKey(tester, 'menu-quickMessages', scroll: false);
    expect(byKey('quickSheet'), findsOneWidget);
    expect(byKey('quickItem-1'), findsOneWidget);

    await tester.enterText(byKey('quickSearch'), 'bang');
    await settle(tester);
    expect(byKey('quickItem-1'), findsNothing);
    expect(byKey('quickItem-2'), findsOneWidget);
    await tester.enterText(byKey('quickSearch'), '');
    await settle(tester);

    await tapKey(tester, 'quickInsert-1', scroll: false);
    expect(_field(tester).controller!.text, 'Địa chỉ shop: 12 Nguyễn Huệ, Quận 1, TP.HCM');

    await _openMore(tester);
    await tapKey(tester, 'menu-quickMessages', scroll: false);
    await tapKey(tester, 'quickInsert-2', scroll: false);
    await settle(tester);
    expect(byKey('pendingAttachments'), findsOneWidget);

    await _openMore(tester);
    await tapKey(tester, 'menu-quickMessages', scroll: false);
    await tapKey(tester, 'quickAdd', scroll: false);
    expect(byKey('quickForm'), findsOneWidget);
    await tapKey(tester, 'quickSave', scroll: false);
    expect(find.text('Nhập từ khóa và nội dung'), findsOneWidget);

    await tester.enterText(byKey('quickKeywordField'), '/chao');
    await tester.enterText(byKey('quickTitleField'), 'Chào bạn');
    platform.nextImages = [PickedFile('anh.png', fakePng('q'))];
    await tapKey(tester, 'quickMediaPick', scroll: false);
    await tapKey(tester, 'quickSave', scroll: false);
    expect(h.main.quickMessagesAdded.single.keyword, '/chao');
    expect(h.main.quickMessagesAdded.single.media, isNotNull);
    expect(h.main.quickMessagesVersion, 4);
    expect(byKey('quickItem-3'), findsOneWidget);

    await tapKey(tester, 'quickEdit-3', scroll: false);
    await tester.enterText(byKey('quickTitleField'), 'Chào bạn nhé');
    await tapKey(tester, 'quickSave', scroll: false);
    expect(h.main.quickMessagesUpdated.single.id, 3);
    expect(h.main.quickMessagesVersion, 5);
    expect(find.text('Chào bạn nhé'), findsOneWidget);

    await tapKey(tester, 'quickDelete-3', scroll: false);
    await tapKey(tester, 'confirmOk', scroll: false);
    expect(h.main.quickMessagesRemoved.single, [3]);
    expect(h.main.quickMessagesVersion, 6);
    expect(byKey('quickItem-3'), findsNothing);
    await drain(tester);
  });

  testWidgets('quick-message media blocks send until the photo has downloaded', (tester) async {
    final h = await pumpZalos(tester, size: expanded, app: FakeZalosApp(latency: const Duration(milliseconds: 300)));
    await openThreadByKey(tester, 'u02');
    await settle(tester, const Duration(seconds: 1));
    await _openMore(tester);
    await tapKey(tester, 'menu-quickMessages', scroll: false);
    await settle(tester, const Duration(seconds: 1));

    await tester.tap(byKey('quickInsert-2'));
    await tester.pump(const Duration(milliseconds: 180));
    await tester.pump();
    expect(_field(tester).controller!.text, 'Bảng giá hoa hồng Đà Lạt');
    expect(byKey('quickMediaPending'), findsOneWidget);
    expect(tester.widget<ZIconButton>(byKey('sendButton')).onPressed, isNull);
    await tester.tap(byKey('sendButton'));
    await tester.pump();
    expect(h.main.sentTexts, isEmpty);

    await settle(tester, const Duration(seconds: 1));
    expect(byKey('quickMediaPending'), findsNothing);
    expect(byKey('pendingAttachments'), findsOneWidget);
    expect(tester.widget<ZIconButton>(byKey('sendButton')).onPressed, isNotNull);

    await tapKey(tester, 'sendButton', scroll: false);
    expect(h.main.sentFiles, hasLength(1));
    expect(h.main.sentTexts.single.text, 'Bảng giá hoa hồng Đà Lạt');
    await drain(tester);
  });

  testWidgets('a failed quick-message photo leaves a text-only composer', (tester) async {
    final h = await pumpZalos(tester, size: expanded);
    await openThreadByKey(tester, 'u02');
    h.app.flags.failMedia.add('*');
    await _openMore(tester);
    await tapKey(tester, 'menu-quickMessages', scroll: false);
    await tapKey(tester, 'quickInsert-2', scroll: false);
    await settle(tester);

    expect(byKey('quickMediaPending'), findsNothing);
    expect(byKey('pendingAttachments'), findsNothing);
    expect(find.text('Không tải được ảnh của tin nhắn nhanh'), findsOneWidget);
    expect(_field(tester).controller!.text, 'Bảng giá hoa hồng Đà Lạt');
    expect(tester.widget<ZIconButton>(byKey('sendButton')).onPressed, isNotNull);

    await tapKey(tester, 'sendButton', scroll: false);
    expect(h.main.sentFiles, isEmpty);
    expect(h.main.sentTexts.single.text, 'Bảng giá hoa hồng Đà Lạt');
    await drain(tester);
  });

  testWidgets('quick messages show loading and empty states', (tester) async {
    await pumpZalos(tester, size: expanded, app: FakeZalosApp(latency: const Duration(milliseconds: 200)));
    await openThreadByKey(tester, 'u02');
    await settle(tester, const Duration(seconds: 1));
    await _openMore(tester);
    await tester.tap(byKey('menu-quickMessages'));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 100));
    expect(byKey('quickLoading'), findsOneWidget);
    await settle(tester, const Duration(seconds: 1));
    expect(byKey('quickItem-1'), findsOneWidget);
    await drain(tester);

    final h = await pumpZalos(tester, size: expanded);
    h.main.quickMessageList.clear();
    await openThreadByKey(tester, 'u02');
    await _openMore(tester);
    await tapKey(tester, 'menu-quickMessages', scroll: false);
    expect(byKey('quickEmpty'), findsOneWidget);
    await drain(tester);
  });

  testWidgets('structured kinds render cards with key fields and open actions', (tester) async {
    final platform = FakePlatform();
    final h = await pumpZalos(tester, size: const Size(1440, 4000), platform: platform);
    await openThreadByKey(tester, 'u10');
    await settle(tester);
    var seq = 0;
    Message add(MessageKind kind, {
      String? text,
      BankCard? bankCard,
      Location? location,
      Poll? poll,
      Note? note,
      Reminder? reminder,
      CallLog? callLog,
      Doodle? doodle,
      Album? album,
      Todo? todo,
      LinkPreview? linkPreview,
      List<Attachment> attachments = const [],
      List<StyleRun> styles = const [],
      MessageUrgency? urgency,
      int? ttl,
    }) {
      final message = h.main.msg(
        'u10',
        ThreadType.user,
        'u10',
        fakeNow.millisecondsSinceEpoch + (++seq) * 180000,
        kind: kind,
        text: text,
        bankCard: bankCard,
        location: location,
        poll: poll,
        note: note,
        reminder: reminder,
        callLog: callLog,
        doodle: doodle,
        album: album,
        todo: todo,
        linkPreview: linkPreview,
        attachments: attachments,
        styles: styles,
        urgency: urgency,
        ttl: ttl,
      );
      h.main.deliver(message);
      return message;
    }

    final bank = add(MessageKind.bankCard,
        bankCard: const BankCard(bin: 970436, accountNumber: '0071000123456', holderName: 'PHAM MINH THU', bankName: 'Vietcombank', bankLogo: 'fake://bank/vcb'));
    final location = add(MessageKind.location,
        location: const Location(lat: 10.7769, lng: 106.7009, name: 'Chợ Bến Thành', address: 'Lê Lợi, Quận 1'));
    final poll = add(MessageKind.poll,
        poll: const Poll(question: 'Bạn thích món nào?', options: [
          PollOption(id: 1, text: 'Phở', votes: 3, voted: true),
          PollOption(id: 2, text: 'Bún chả', votes: 2),
        ], totalVotes: 5, multiple: true));
    final note = add(MessageKind.note, note: const Note(title: 'Ghi chú họp', text: 'Chốt ngân sách quý 3', pinned: true));
    final reminder = add(MessageKind.reminder,
        reminder: Reminder(title: 'Họp nhóm', startTime: fakeNow.millisecondsSinceEpoch, repeat: 1));
    final call = add(MessageKind.call, callLog: const CallLog(callType: 'video', durationMs: 65000, missed: true));
    final doodle = add(MessageKind.doodle,
        doodle: const Doodle(url: 'fake://photo/doodle', thumbUrl: 'fake://photo/doodle', width: 320, height: 240));
    final album = add(MessageKind.album,
        album: const Album(items: [
          Attachment(kind: MessageKind.image, url: 'fake://photo/a1', thumbUrl: 'fake://photo/a1', width: 320, height: 240),
          Attachment(kind: MessageKind.image, url: 'fake://photo/a2', thumbUrl: 'fake://photo/a2', width: 320, height: 240),
        ], caption: 'Ảnh cuối tuần'));
    final todo = add(MessageKind.todo,
        todo: const Todo(title: 'Việc nhà', items: [TodoItem(text: 'Mua sữa', done: true), TodoItem(text: 'Đổ rác')], done: true));
    final link = add(MessageKind.link,
        linkPreview: const LinkPreview(
          title: 'Dự báo thời tiết cuối tuần',
          description: 'Miền Trung nắng đẹp, ít mưa.',
          srcUrl: 'https://thoitiet.example.vn/du-bao-cuoi-tuan',
          href: 'https://thoitiet.example.vn/du-bao-cuoi-tuan',
          thumbUrl: 'fake://photo/weather',
        ));
    final styled = add(MessageKind.text,
        text: 'bold italic under strike',
        styles: const [
          StyleRun(start: 0, len: 4, st: 'b'),
          StyleRun(start: 5, len: 6, st: 'i'),
          StyleRun(start: 12, len: 5, st: 'u'),
          StyleRun(start: 18, len: 6, st: 's'),
        ]);
    final urgent = add(MessageKind.text, text: 'Gấp lắm', urgency: MessageUrgency.urgent, ttl: 86400000);
    await settle(tester);

    expect(byKey('bankCard-${bank.id}'), findsOneWidget);
    expect(find.text('Vietcombank'), findsWidgets);
    expect(find.text('0071000123456'), findsWidgets);

    expect(byKey('location-${location.id}'), findsOneWidget);
    expect(find.text('Chợ Bến Thành'), findsOneWidget);
    await tapKey(tester, 'locationOpen-${location.id}', scroll: false);
    expect(platform.openedUrls.last, contains('10.7769'));

    expect(byKey('poll-${poll.id}'), findsOneWidget);
    expect(find.text('Bạn thích món nào?'), findsOneWidget);
    expect(find.text('Phở'), findsOneWidget);
    expect(find.text('5 lượt bình chọn'), findsOneWidget);

    expect(byKey('note-${note.id}'), findsOneWidget);
    expect(find.text('Ghi chú họp'), findsOneWidget);
    expect(find.text('Đã ghim'), findsOneWidget);

    expect(byKey('reminder-${reminder.id}'), findsOneWidget);
    expect(find.text('Họp nhóm'), findsOneWidget);
    expect(find.text('Có lặp lại'), findsOneWidget);

    expect(byKey('call-${call.id}'), findsOneWidget);
    expect(find.text('Cuộc gọi video'), findsOneWidget);
    expect(find.text('Cuộc gọi nhỡ'), findsOneWidget);

    expect(byKey('doodle-${doodle.id}'), findsOneWidget);
    await tapKey(tester, 'doodle-${doodle.id}', scroll: false);
    expect(byKey('mediaViewer'), findsOneWidget);
    await tapKey(tester, 'viewerClose', scroll: false);

    expect(byKey('album-${album.id}'), findsOneWidget);
    expect(byKey('albumItem-${album.id}-0'), findsOneWidget);
    await tapKey(tester, 'albumItem-${album.id}-0', scroll: false);
    expect(byKey('mediaViewer'), findsOneWidget);
    await tapKey(tester, 'viewerClose', scroll: false);

    expect(byKey('todo-${todo.id}'), findsOneWidget);
    expect(find.text('Mua sữa'), findsOneWidget);
    expect(find.text('Đã xong'), findsWidgets);

    expect(byKey('linkPreview-${link.id}'), findsOneWidget);
    expect(find.text('Dự báo thời tiết cuối tuần'), findsOneWidget);
    await tapKey(tester, 'linkPreview-${link.id}', scroll: false);
    expect(platform.openedUrls.last, 'https://thoitiet.example.vn/du-bao-cuoi-tuan');

    expect(byKey('urgency-${urgent.id}'), findsOneWidget);
    expect(byKey('ttl-${urgent.id}'), findsOneWidget);
    final urgencyIcon = tester.widget<Icon>(find.descendant(of: byKey('urgency-${urgent.id}'), matching: find.byType(Icon)));
    expect(urgencyIcon.semanticLabel, 'Tin nhắn khẩn cấp');
    final ttlIcon = tester.widget<Icon>(find.descendant(of: byKey('ttl-${urgent.id}'), matching: find.byType(Icon)));
    expect(ttlIcon.semanticLabel, contains('Tin nhắn tự hủy sau 1 ngày'));

    final selectable = tester.widget<SelectableText>(
      find.descendant(of: byKey('bubble-${styled.id}'), matching: find.byType(SelectableText)),
    );
    TextStyle? styleOf(String part) {
      TextStyle? found;
      selectable.textSpan!.visitChildren((span) {
        if (span is TextSpan && span.text == part) {
          found = span.style;
          return false;
        }
        return true;
      });
      return found;
    }

    expect(styleOf('bold')?.fontWeight, FontWeight.w700);
    expect(styleOf('italic')?.fontStyle, FontStyle.italic);
    expect(styleOf('under')?.decoration?.contains(TextDecoration.underline), isTrue);
    expect(styleOf('strike')?.decoration?.contains(TextDecoration.lineThrough), isTrue);
    await drain(tester);
  });

  testWidgets('expired messages disappear through the event path', (tester) async {
    final h = await pumpZalos(tester, size: expanded);
    await openThreadByKey(tester, 'u02');
    final message = h.main.receive('u02', 'Tin tạm thời');
    await settle(tester);
    expect(byKey('bubble-${message.id}'), findsOneWidget);
    h.main.replace(message, (_) => null);
    await settle(tester);
    expect(byKey('bubble-${message.id}'), findsNothing);
    await drain(tester);
  });

  testWidgets('Phase D composer actions stay hidden without the capability', (tester) async {
    await pumpZalos(tester, size: expanded, app: FakeZalosApp(withOa: true), prefs: {'active_slot': 'oa'});
    await openThreadByKey(tester, 'u06');
    expect(byKey('composerMore'), findsNothing);
    expect(byKey('formatBar'), findsNothing);
    expect(byKey('urgencyChip'), findsNothing);
    await tester.enterText(byKey('composerField'), 'Xin chào');
    await tester.pump();
    _controller(tester).selection = const TextSelection(baseOffset: 0, extentOffset: 3);
    await settle(tester, const Duration(milliseconds: 300));
    expect(byKey('formatBar'), findsNothing);
    expect(tester.takeException(), isNull);
    await drain(tester);
  });

  test('every Phase D kind has a thread preview', () {
    const s = S('vi');
    expect(messageSummary(_message(MessageKind.bankCard, bankCard: const BankCard(bin: 970436, accountNumber: '0071000123456', bankName: 'Vietcombank')), s),
        '[Thẻ ngân hàng] Vietcombank');
    expect(messageSummary(_message(MessageKind.location, location: const Location(lat: 10.7, lng: 106.7, name: 'Chợ Bến Thành')), s),
        '[Vị trí] Chợ Bến Thành');
    expect(messageSummary(_message(MessageKind.poll, poll: const Poll(question: 'Món nào?')), s), '[Bình chọn] Món nào?');
    expect(messageSummary(_message(MessageKind.note, note: const Note(title: 'Ghi chú')), s), '[Ghi chú] Ghi chú');
    expect(messageSummary(_message(MessageKind.reminder, reminder: const Reminder(title: 'Họp')), s), '[Nhắc hẹn] Họp');
    expect(messageSummary(_message(MessageKind.call, callLog: const CallLog(callType: 'voice', missed: true)), s), '[Cuộc gọi nhỡ]');
    expect(messageSummary(_message(MessageKind.doodle, doodle: const Doodle(url: 'fake://photo/d')), s), '[Hình vẽ]');
    expect(messageSummary(_message(MessageKind.album, album: const Album(items: [])), s), '[Album] 0 ảnh');
    expect(messageSummary(_message(MessageKind.todo, todo: const Todo(title: 'Việc nhà')), s), '[Việc cần làm] Việc nhà');
    expect(
        messageSummary(
            _message(MessageKind.link,
                linkPreview: const LinkPreview(title: 'Tin', description: '', srcUrl: 'https://a.vn', href: 'https://a.vn')),
            s),
        '[Link] Tin');
    expect(
        messageSummary(
            _message(MessageKind.gif, attachments: const [Attachment(kind: MessageKind.gif, url: 'fake://photo/g')]),
            s),
        '[Ảnh động]');
    expect(messageSummary(_message(MessageKind.other), s), 'Loại tin nhắn chưa được hỗ trợ');
    expect(messageSummary(_message(MessageKind.other, text: 'Khác'), s), 'Khác');

    final group = _thread(_message(MessageKind.bankCard, bankCard: const BankCard(bin: 970436, accountNumber: '1', bankName: 'VCB')), type: ThreadType.group);
    expect(threadPreview(group, s), 'Bảo: [Thẻ ngân hàng] VCB');
  });
}
