import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:zalos/src/data/mapping.dart';
import 'package:zalos/src/data/protocol/noise_channel.dart';
import 'package:zalos/src/domain/models.dart';

import '../support/fake_zalos.dart';

void main() {
  group('style runs', () {
    test('map a run and its indent size', () {
      final bold = styleRunFromJson(const {'start': 2, 'len': 5, 'st': 'b'});
      expect(bold.start, 2);
      expect(bold.len, 5);
      expect(bold.st, 'b');
      expect(bold.indentSize, isNull);

      final indent = styleRunFromJson(const {'start': 0, 'len': 1, 'st': 'ind_\$', 'indentSize': '3'});
      expect(indent.st, 'ind_\$');
      expect(indent.indentSize, 3);
    });

    test('serialize only a meaningful indent size', () {
      expect(styleRunToJson(const StyleRun(start: 0, len: 4, st: 'i')), {'start': 0, 'len': 4, 'st': 'i'});
      expect(styleRunToJson(const StyleRun(start: 0, len: 1, st: 'ind_\$', indentSize: 2)), {
        'start': 0,
        'len': 1,
        'st': 'ind_\$',
        'indentSize': 2,
      });
    });

    test('malformed runs fall back to defaults', () {
      final run = styleRunFromJson(const {'start': 'oops'});
      expect(run.start, 0);
      expect(run.len, 0);
      expect(run.st, '');
      expect(run.indentSize, isNull);
    });
  });

  group('urgency', () {
    test('maps default and named values both ways', () {
      expect(messageUrgencyFromWire('default'), MessageUrgency.normal);
      expect(messageUrgencyFromWire('normal'), MessageUrgency.normal);
      expect(messageUrgencyFromWire('important'), MessageUrgency.important);
      expect(messageUrgencyFromWire('urgent'), MessageUrgency.urgent);
      expect(messageUrgencyFromWire('panic'), isNull);
      expect(messageUrgencyFromWire(null), isNull);

      expect(messageUrgencyToWire(MessageUrgency.normal), 'default');
      expect(messageUrgencyToWire(MessageUrgency.important), 'important');
      expect(messageUrgencyToWire(MessageUrgency.urgent), 'urgent');
    });
  });

  test('Phase D kinds map and unknown kinds still degrade to other', () {
    const expected = {
      'gif': MessageKind.gif,
      'bank': MessageKind.bankCard,
      'location': MessageKind.location,
      'poll': MessageKind.poll,
      'note': MessageKind.note,
      'reminder': MessageKind.reminder,
      'call': MessageKind.call,
      'doodle': MessageKind.doodle,
      'album': MessageKind.album,
      'todo': MessageKind.todo,
    };
    expected.forEach((wire, kind) => expect(messageKindFromWire(wire), kind, reason: wire));
    expect(messageKindFromWire('card'), MessageKind.card);
    expect(messageKindFromWire('hologram'), MessageKind.other);
    expect(messageKindToWire(MessageKind.bankCard), 'bank');
    expect(messageKindToWire(MessageKind.gif), 'gif');
  });

  test('Phase D capabilities map and unknown values stay forward-compatible', () {
    final summary = accountSummaryFromJson({
      'slot': 's1',
      'capabilities': [
        'styledText',
        'gif',
        'linkPreview',
        'bankCard',
        'bankAccounts',
        'quickMessages',
        'urgency',
        'messageTtl',
        'futureThing',
      ],
    });
    expect(summary.capabilities, {
      AccountCapability.styledText,
      AccountCapability.gif,
      AccountCapability.linkPreview,
      AccountCapability.bankCard,
      AccountCapability.bankAccounts,
      AccountCapability.quickMessages,
      AccountCapability.urgency,
      AccountCapability.messageTtl,
    });
  });

  group('structured payloads', () {
    test('bank card keeps only the guaranteed fields when the rest is absent', () {
      final card = bankCardFromJson(const {'bin': 970436, 'accountNumber': '0071000123456'});
      expect(card.bin, 970436);
      expect(card.accountNumber, '0071000123456');
      expect(card.holderName, isNull);
      expect(card.bankName, isNull);
      expect(card.bankLogo, isNull);

      final full = bankCardFromJson(const {
        'bin': '970422',
        'accountNumber': '0900123456789',
        'holderName': 'PHAM MINH THU',
        'bankName': 'MB Bank',
        'bankLogo': 'https://a/logo.png',
      });
      expect(full.bin, 970422);
      expect(full.holderName, 'PHAM MINH THU');
      expect(full.bankName, 'MB Bank');
      expect(full.bankLogo, 'https://a/logo.png');
    });

    test('location coerces string coordinates and keeps optionals', () {
      final location = locationFromJson(const {
        'lat': '10.7769',
        'lng': 106.7009,
        'name': 'Chợ Bến Thành',
        'address': 'Lê Lợi, Quận 1',
        'thumbUrl': 'https://a/map.png',
      });
      expect(location.lat, closeTo(10.7769, 1e-9));
      expect(location.lng, closeTo(106.7009, 1e-9));
      expect(location.name, 'Chợ Bến Thành');
      expect(location.address, 'Lê Lợi, Quận 1');
      expect(location.thumbUrl, 'https://a/map.png');

      final bare = locationFromJson(const {'lat': 'oops'});
      expect(bare.lat, 0);
      expect(bare.lng, 0);
      expect(bare.name, isNull);
    });

    test('poll maps options, flags and totals', () {
      final poll = pollFromJson(const {
        'id': 7,
        'question': 'Đi đâu cuối tuần?',
        'options': [
          {'id': 1, 'text': 'Đà Lạt', 'votes': 3, 'voted': true},
          {'id': 2, 'text': 'Vũng Tàu', 'votes': '1'},
          'junk',
        ],
        'multiple': 1,
        'closed': false,
        'anonymous': true,
        'totalVotes': 4,
        'expiredAt': 1700000000000,
      });
      expect(poll.id, 7);
      expect(poll.question, 'Đi đâu cuối tuần?');
      expect(poll.options, hasLength(2));
      expect(poll.options.first.text, 'Đà Lạt');
      expect(poll.options.first.votes, 3);
      expect(poll.options.first.voted, isTrue);
      expect(poll.options.last.votes, 1);
      expect(poll.options.last.voted, isNull);
      expect(poll.multiple, isTrue);
      expect(poll.closed, isFalse);
      expect(poll.anonymous, isTrue);
      expect(poll.totalVotes, 4);
      expect(poll.expiredAt, 1700000000000);
    });

    test('note and reminder map optional fields', () {
      final note = noteFromJson(const {'id': 'n1', 'title': 'Ghim', 'text': 'Nhớ mua hoa', 'pinned': 1});
      expect(note.id, 'n1');
      expect(note.title, 'Ghim');
      expect(note.text, 'Nhớ mua hoa');
      expect(note.pinned, isTrue);

      final reminder = reminderFromJson(const {'id': 'r1', 'title': 'Họp', 'startTime': 1700000000000, 'repeat': 2, 'emoji': 'bell'});
      expect(reminder.id, 'r1');
      expect(reminder.title, 'Họp');
      expect(reminder.startTime, 1700000000000);
      expect(reminder.repeat, 2);
      expect(reminder.emoji, 'bell');
      expect(reminderFromJson(const {'title': 'x'}).startTime, isNull);
    });

    test('call log defaults its type and keeps duration and missed', () {
      final call = callLogFromJson(const {'callType': 'video', 'durationMs': '42000', 'missed': 1, 'state': 'ended'});
      expect(call.callType, 'video');
      expect(call.durationMs, 42000);
      expect(call.missed, isTrue);
      expect(call.state, 'ended');
      expect(callLogFromJson(const {}).callType, 'unknown');
      expect(callLogFromJson(const {}).missed, isNull);
    });

    test('doodle, album and todo map their items', () {
      final doodle = doodleFromJson(const {'url': 'https://a/d.png', 'thumbUrl': 'https://a/dt.png', 'width': 300, 'height': 200});
      expect(doodle.url, 'https://a/d.png');
      expect(doodle.thumbUrl, 'https://a/dt.png');
      expect(doodle.width, 300);
      expect(doodle.height, 200);

      final album = albumFromJson(const {
        'items': [
          {'kind': 'image', 'url': 'https://a/1.jpg', 'width': 320, 'height': 240},
          'junk',
        ],
        'caption': 'Ảnh cưới',
      });
      expect(album.items, hasLength(1));
      expect(album.items.single.url, 'https://a/1.jpg');
      expect(album.items.single.width, 320);
      expect(album.caption, 'Ảnh cưới');

      final todo = todoFromJson(const {
        'id': 't1',
        'title': 'Chuẩn bị',
        'items': [
          {'text': 'Mua hoa', 'done': true},
          {'text': 'Đặt bàn'},
          'junk',
        ],
        'done': false,
      });
      expect(todo.id, 't1');
      expect(todo.title, 'Chuẩn bị');
      expect(todo.items, hasLength(2));
      expect(todo.items.first.done, isTrue);
      expect(todo.items.last.done, isNull);
      expect(todo.done, isFalse);
    });

    test('link preview maps the media fields', () {
      final preview = linkPreviewFromJson(const {
        'title': 'Dự báo thời tiết',
        'description': 'Nắng đẹp',
        'srcUrl': 'https://thoitiet.example.vn/a',
        'href': 'https://thoitiet.example.vn/a',
        'thumbUrl': 'https://a/thumb.png',
        'mediaType': 1,
        'mediaCount': 2,
        'mediaTitle': 'Video',
        'mediaArtist': 'Zalo',
        'streamUrl': 'https://a/stream.mp4',
      });
      expect(preview.title, 'Dự báo thời tiết');
      expect(preview.description, 'Nắng đẹp');
      expect(preview.srcUrl, 'https://thoitiet.example.vn/a');
      expect(preview.href, 'https://thoitiet.example.vn/a');
      expect(preview.thumbUrl, 'https://a/thumb.png');
      expect(preview.mediaType, 1);
      expect(preview.mediaCount, 2);
      expect(preview.mediaTitle, 'Video');
      expect(preview.mediaArtist, 'Zalo');
      expect(preview.streamUrl, 'https://a/stream.mp4');

      final bare = linkPreviewFromJson(const {});
      expect(bare.title, '');
      expect(bare.href, '');
      expect(bare.mediaType, isNull);
    });

    test('bank list, accounts and pagination map', () {
      final bank = bankInfoFromJson(const {
        'bin': 970436,
        'logo': 'https://a/vcb.png',
        'name': 'Ngân hàng TMCP Ngoại thương Việt Nam',
        'nameEn': 'Vietcombank',
        'shortName': 'VCB',
        'searchKeyword': 'vietcombank vcb',
      });
      expect(bank.bin, 970436);
      expect(bank.nameEn, 'Vietcombank');
      expect(bank.shortName, 'VCB');
      expect(bank.searchKeyword, 'vietcombank vcb');

      final account = bankAccountFromJson(const {
        'id': 'ba1',
        'bin': '970436',
        'accountNumber': '0071000123456',
        'holderName': 'PHAM MINH THU',
        'isDefault': 1,
        'accountId': 11,
        'createdAt': 1700000000000,
        'updatedAt': 1700000001000,
        'bankName': 'Vietcombank',
        'bankLogo': 'https://a/vcb.png',
      });
      expect(account.id, 'ba1');
      expect(account.bin, 970436);
      expect(account.accountNumber, '0071000123456');
      expect(account.holderName, 'PHAM MINH THU');
      expect(account.isDefault, isTrue);
      expect(account.accountId, 11);
      expect(account.createdAt, 1700000000000);
      expect(account.updatedAt, 1700000001000);
      expect(account.bankName, 'Vietcombank');
      expect(account.bankLogo, 'https://a/vcb.png');

      final page = bankAccountsFromJson(const {
        'accounts': [
          {'id': 'ba1', 'bin': 970436, 'accountNumber': '1', 'holderName': 'A', 'isDefault': true, 'accountId': 1, 'createdAt': 1, 'updatedAt': 2},
          'junk',
        ],
        'total': 5,
        'hasMore': 1,
      });
      expect(page.accounts, hasLength(1));
      expect(page.total, 5);
      expect(page.hasMore, isTrue);
      expect(bankAccountsFromJson(const {}).accounts, isEmpty);
      expect(bankAccountsFromJson(const {'hasMore': 'yes'}).hasMore, isFalse);
    });

    test('quick messages keep their media, version and cursor', () {
      final messages = quickMessagesFromJson(const {
        'items': [
          {
            'id': 2,
            'keyword': '/banggia',
            'title': 'Bảng giá',
            'type': 1,
            'createdTime': 1700000000000,
            'lastModified': 1700000001000,
            'media': [
              {
                'type': 1,
                'photoId': 9001,
                'title': 'Bảng giá',
                'width': 320,
                'height': 240,
                'previewThumb': 'https://a/p.png',
                'rawUrl': 'https://a/r.png',
                'thumbUrl': 'https://a/t.png',
                'normalUrl': 'https://a/n.png',
                'hdUrl': 'https://a/h.png',
              },
            ],
          },
          'junk',
        ],
        'version': 7,
        'cursor': 19,
      });
      expect(messages.version, 7);
      expect(messages.cursor, 19);
      final item = messages.items.single;
      expect(item.id, 2);
      expect(item.keyword, '/banggia');
      expect(item.title, 'Bảng giá');
      expect(item.type, 1);
      expect(item.createdTime, 1700000000000);
      expect(item.lastModified, 1700000001000);
      final media = item.media.single;
      expect(media.photoId, 9001);
      expect(media.previewThumb, 'https://a/p.png');
      expect(media.rawUrl, 'https://a/r.png');
      expect(media.thumbUrl, 'https://a/t.png');
      expect(media.normalUrl, 'https://a/n.png');
      expect(media.hdUrl, 'https://a/h.png');

      final bare = quickMessagesFromJson(const {});
      expect(bare.items, isEmpty);
      expect(bare.version, 0);
      expect(bare.cursor, 0);
    });
  });

  group('message bodies', () {
    test('maps styles, urgency, ttl and expiry', () {
      final message = messageFromJson({
        'id': 'm1',
        'threadId': 't1',
        'threadType': 'user',
        'kind': 'text',
        'body': {
          'text': 'Xin chào',
          'styles': [
            {'start': 0, 'len': 3, 'st': 'b'},
            {'start': 4, 'len': 4, 'st': 'ind_\$', 'indentSize': 2},
          ],
          'urgency': 'urgent',
          'ttl': 86400000,
          'expiresAt': 1700000086400,
          'raw': {'msgId': 'm1'},
        },
      });
      expect(message.styles, hasLength(2));
      expect(message.styles.first.st, 'b');
      expect(message.styles.last.indentSize, 2);
      expect(message.urgency, MessageUrgency.urgent);
      expect(message.ttl, 86400000);
      expect(message.expiresAt, 1700000086400);
      expect(message.raw, {'msgId': 'm1'});
    });

    test('maps a plaintext structured body', () {
      final message = messageFromJson({
        'id': 'm1',
        'threadId': 't1',
        'kind': 'bank',
        'body': {
          'text': 'Vietcombank',
          'bankCard': {'bin': 970436, 'accountNumber': '0071000123456', 'holderName': 'PHAM MINH THU'},
          'linkPreview': {'title': 'Vietcombank', 'description': '', 'srcUrl': '', 'href': 'https://vcb.example.vn'},
        },
      });
      expect(message.kind, MessageKind.bankCard);
      expect(message.bankCard!.bin, 970436);
      expect(message.bankCard!.accountNumber, '0071000123456');
      expect(message.linkPreview!.href, 'https://vcb.example.vn');
      expect(message.raw, isNull);
    });

    test('maps a sealed body through the opener', () {
      final message = messageFromJson(
        {'id': 'm1', 'threadId': 't1', 'kind': 'poll', 'sealed': 'cipher'},
        open: (id, sealed) => {
          'poll': {
            'question': 'Đi đâu?',
            'options': [
              {'id': 1, 'text': 'Đà Lạt'},
            ],
          },
          'text': 'Đi đâu?',
          'raw': {'msgId': 'm1', 'cliMsgId': 'c1'},
        },
      );
      expect(message.kind, MessageKind.poll);
      expect(message.poll!.question, 'Đi đâu?');
      expect(message.poll!.options.single.text, 'Đà Lạt');
      expect(message.text, 'Đi đâu?');
      expect(message.raw, {'msgId': 'm1', 'cliMsgId': 'c1'});
    });

    test('keeps clear fields when a sealed body does not open', () {
      var locked = 0;
      final message = messageFromJson(
        {'id': 'm1', 'threadId': 't1', 'kind': 'todo', 'sealed': 'cipher'},
        open: (id, sealed) => null,
        onLocked: (_) => locked++,
      );
      expect(locked, 1);
      expect(message.kind, MessageKind.todo);
      expect(message.todo, isNull);
      expect(message.raw, isNull);
    });

    test('malformed payloads degrade instead of throwing', () {
      final message = messageFromJson({
        'id': 'm1',
        'threadId': 't1',
        'kind': 'poll',
        'body': {
          'poll': 'nope',
          'bankCard': ['nope'],
          'album': {'items': 'nope'},
          'todo': {'items': [null, 'junk']},
          'styles': 'nope',
          'urgency': 'panic',
          'ttl': 'oops',
          'expiresAt': 'oops',
        },
      });
      expect(message.poll, isNull);
      expect(message.bankCard, isNull);
      expect(message.album!.items, isEmpty);
      expect(message.todo!.title, '');
      expect(message.todo!.items, isEmpty);
      expect(message.styles, isEmpty);
      expect(message.urgency, isNull);
      expect(message.ttl, isNull);
      expect(message.expiresAt, isNull);
    });

    test('copyMessage keeps the structured payloads and send metadata', () {
      const base = Message(
        id: 'm1',
        cliId: 'c1',
        threadId: 't1',
        threadType: ThreadType.user,
        senderId: 'u1',
        senderName: 'Lan',
        ts: 1,
        isSelf: true,
        kind: MessageKind.bankCard,
        bankCard: BankCard(bin: 970436, accountNumber: '0071000123456'),
        styles: [StyleRun(start: 0, len: 1, st: 'b')],
        urgency: MessageUrgency.important,
        ttl: 86400000,
        expiresAt: 86400001,
      );
      final copy = copyMessage(base, id: 'm2', sendState: SendState.sent);
      expect(copy.id, 'm2');
      expect(copy.bankCard!.bin, 970436);
      expect(copy.styles.single.st, 'b');
      expect(copy.urgency, MessageUrgency.important);
      expect(copy.ttl, 86400000);
      expect(copy.expiresAt, 86400001);
    });

    test('copyMessage keeps or clears the per-message send error', () {
      const base = Message(
        id: 'm1',
        cliId: 'c1',
        threadId: 't1',
        threadType: ThreadType.user,
        senderId: 'u1',
        senderName: 'Lan',
        ts: 1,
        isSelf: true,
        kind: MessageKind.text,
        sendState: SendState.failed,
        sendErrorCode: 'rate_limited',
      );
      expect(copyMessage(base).sendErrorCode, 'rate_limited');
      final cleared = copyMessage(base, sendState: SendState.sending, sendErrorCode: null);
      expect(cleared.sendErrorCode, isNull);
    });
  });

  group('fake session', () {
    FakeSession fakeSession() {
      final app = FakeZalosApp();
      addTearDown(app.dispose);
      return app.fakeLink.session('main');
    }

    test('sendText records styles, urgency and ttl and lists them', () async {
      final session = fakeSession();
      await session.sendText(
        'u01',
        ThreadType.user,
        'Xin chào',
        styles: const [StyleRun(start: 0, len: 3, st: 'b')],
        urgency: MessageUrgency.urgent,
        ttl: 86400000,
      );
      final recorded = session.sentTexts.single;
      expect(recorded.styles.single.st, 'b');
      expect(recorded.urgency, MessageUrgency.urgent);
      expect(recorded.ttl, 86400000);

      final message = session.allOf('u01').last;
      expect(message.kind, MessageKind.text);
      expect(message.styles.single.st, 'b');
      expect(message.urgency, MessageUrgency.urgent);
      expect(message.ttl, 86400000);
      expect(message.sendState, SendState.sent);
    });

    test('sendFile routes a gif by name and keeps other files as files', () async {
      final session = fakeSession();
      await session.sendFile(
        'u01',
        ThreadType.user,
        OutgoingFile(name: 'meme.GIF', bytes: Uint8List.fromList(const [1, 2]), kind: MessageKind.file),
      );
      final gif = session.allOf('u01').last;
      expect(gif.kind, MessageKind.gif);
      expect(gif.attachments.single.kind, MessageKind.gif);
      expect(gif.attachments.single.name, 'meme.GIF');

      await session.sendFile(
        'u01',
        ThreadType.user,
        OutgoingFile(name: 'bao-cao.pdf', bytes: Uint8List.fromList(const [3]), kind: MessageKind.file),
      );
      expect(session.allOf('u01').last.kind, MessageKind.file);
    });

    test('sendFile records ttl and urgency and stamps the local message', () async {
      final session = fakeSession();
      await session.sendFile(
        'u01',
        ThreadType.user,
        OutgoingFile(name: 'anh.png', bytes: Uint8List.fromList(const [1, 2]), kind: MessageKind.image),
        caption: 'Ảnh mẫu',
        urgency: MessageUrgency.urgent,
        ttl: 60000,
      );
      final options = session.sentFileOptions.single;
      expect(options.caption, 'Ảnh mẫu');
      expect(options.urgency, MessageUrgency.urgent);
      expect(options.ttl, 60000);

      final message = session.allOf('u01').last;
      expect(message.text, 'Ảnh mẫu');
      expect(message.urgency, MessageUrgency.urgent);
      expect(message.ttl, 60000);
      expect(message.expiresAt, isNotNull);
    });

    test('parseLink serves a seeded preview and a host fallback', () async {
      final session = fakeSession();
      final seeded = await session.parseLink('https://thoitiet.example.vn/du-bao-cuoi-tuan');
      expect(seeded.title, 'Dự báo thời tiết cuối tuần');
      expect(seeded.thumbUrl, 'fake://photo/weather');

      final generated = await session.parseLink('https://example.vn/tin');
      expect(generated.title, 'example.vn');
      expect(generated.href, 'https://example.vn/tin');
      expect(session.parseLinkCalls, 2);
    });

    test('sendLink lists an optimistic link bubble with its ttl', () async {
      final session = fakeSession();
      await session.sendLink('u01', ThreadType.user, 'https://example.vn/tin', msg: 'Xem nè', ttl: 86400000);
      final recorded = session.sentLinks.single;
      expect(recorded.link, 'https://example.vn/tin');
      expect(recorded.msg, 'Xem nè');
      expect(recorded.ttl, 86400000);

      final message = session.allOf('u01').last;
      expect(message.kind, MessageKind.link);
      expect(message.text, 'Xem nè');
      expect(message.attachments.single.url, 'https://example.vn/tin');
      expect(message.ttl, 86400000);
      expect(message.sendState, SendState.sent);
    });

    test('sendBankCard never invents an id and replays the echo', () async {
      final session = fakeSession();
      const card = BankCard(
        bin: 970436,
        accountNumber: '0071000123456',
        holderName: 'PHAM MINH THU',
        bankName: 'Vietcombank',
      );
      await session.sendBankCard('u01', ThreadType.user, card);
      expect(session.sentBankCards.single.card.accountNumber, '0071000123456');

      final message = session.allOf('u01').last;
      expect(message.kind, MessageKind.bankCard);
      expect(message.bankCard!.bin, 970436);
      expect(message.text, 'Vietcombank');
      // The echo is not correlated to a local cliId.
      expect(message.cliId, isNull);
      expect(message.sendState, SendState.sent);
    });

    test('banks and bank accounts paginate', () async {
      final session = fakeSession();
      final banks = await session.banks();
      expect(banks.map((b) => b.shortName), ['VCB', 'MB', 'TCB']);
      expect(session.bankListCalls, 1);

      final first = await session.bankAccounts(limit: 2);
      expect(first.accounts.map((a) => a.id), ['ba1', 'ba2']);
      expect(first.total, 3);
      expect(first.hasMore, isTrue);

      final second = await session.bankAccounts(page: 1, limit: 2);
      expect(second.accounts.single.id, 'ba3');
      expect(second.hasMore, isFalse);

      final past = await session.bankAccounts(page: 4, limit: 2);
      expect(past.accounts, isEmpty);
      expect(past.hasMore, isFalse);

      await expectLater(
        session.bankAccounts(page: -1),
        throwsA(isA<RpcException>().having((e) => e.code, 'code', 'bad_request')),
      );
      await expectLater(
        session.bankAccounts(limit: 51),
        throwsA(isA<RpcException>().having((e) => e.code, 'code', 'bad_request')),
      );
    });

    test('quick messages keep the cursor and bump the version on each write', () async {
      final session = fakeSession();
      final seeded = await session.quickMessages();
      expect(seeded.version, 3);
      expect(seeded.cursor, 17);
      expect(seeded.items.map((q) => q.id), [1, 2]);
      expect(seeded.items.last.media.single.photoId, 9001);

      final added = await session.addQuickMessage(const QuickMessageDraft(keyword: '/thanks', title: 'Cảm ơn bạn'));
      expect(added.version, 4);
      expect(added.item.id, 3);
      expect(added.item.keyword, '/thanks');
      expect(added.item.media, isEmpty);

      final withMedia = await session.addQuickMessage(QuickMessageDraft(
        keyword: '/anh',
        title: 'Ảnh mẫu',
        media: OutgoingFile(name: 'mau.png', bytes: Uint8List.fromList(const [1, 2]), kind: MessageKind.image),
      ));
      expect(withMedia.item.type, 1);
      expect(withMedia.item.media.single.title, 'Ảnh mẫu');
      expect(withMedia.version, added.version + 1);

      final updated = await session.updateQuickMessage(3, const QuickMessageDraft(keyword: '/cam-on', title: 'Cảm ơn nhiều'));
      expect(updated.item.keyword, '/cam-on');
      expect(updated.item.createdTime, fakeNow.millisecondsSinceEpoch);
      expect(updated.item.lastModified, fakeNow.millisecondsSinceEpoch);
      expect(updated.version, withMedia.version + 1);

      final removed = await session.removeQuickMessages(const [1, 2, 2]);
      expect(removed.itemIds, [1, 2]);
      expect(removed.version, updated.version + 1);
      final left = await session.quickMessages();
      expect(left.items.map((q) => q.id), [3, 4]);
      expect(left.cursor, 17);
      expect(left.version, removed.version);
    });

    test('quick message writes validate the draft and the id', () async {
      final session = fakeSession();
      final before = session.quickMessagesVersion;

      await expectLater(
        session.addQuickMessage(const QuickMessageDraft(keyword: '   ', title: 'x')),
        throwsA(isA<RpcException>().having((e) => e.code, 'code', 'bad_request')),
      );
      await expectLater(
        session.addQuickMessage(QuickMessageDraft(keyword: '/a', title: 'x' * 2001)),
        throwsA(isA<RpcException>().having((e) => e.code, 'code', 'bad_request')),
      );
      await expectLater(
        session.updateQuickMessage(99, const QuickMessageDraft(keyword: '/a', title: 'A')),
        throwsA(isA<RpcException>().having((e) => e.code, 'code', 'not_found')),
      );
      await expectLater(
        session.removeQuickMessages(const []),
        throwsA(isA<RpcException>().having((e) => e.code, 'code', 'bad_request')),
      );
      expect(session.quickMessagesVersion, before);
      expect(session.quickMessageList, hasLength(2));
    });
  });
}
