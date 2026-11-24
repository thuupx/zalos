import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:zalos/src/data/mapping.dart';
import 'package:zalos/src/data/protocol/noise_channel.dart';
import 'package:zalos/src/domain/models.dart';

import '../support/fake_zalos.dart';

void main() {
  group('thread flags', () {
    test('maps hidden, archived and auto-delete ttl', () {
      final thread = threadFromJson({
        'id': 't1',
        'type': 'group',
        'hidden': 1,
        'archived': true,
        'autoDeleteTtl': '604800000',
      });
      expect(thread.hidden, isTrue);
      expect(thread.archived, isTrue);
      expect(thread.autoDeleteTtl, 604800000);

      final malformed = threadFromJson(const {'id': 't2', 'hidden': 'yes', 'archived': 0, 'autoDeleteTtl': 'oops'});
      expect(malformed.hidden, isFalse);
      expect(malformed.archived, isFalse);
      expect(malformed.autoDeleteTtl, 0);
    });

    test('defaults match an old server that does not send the fields', () {
      final thread = threadFromJson(const {'id': 't1', 'lastMessage': null, 'name': null});
      expect(thread.hidden, isFalse);
      expect(thread.archived, isFalse);
      expect(thread.autoDeleteTtl, 0);
    });

    test('copyThread keeps the flags and can override them', () {
      const base = Thread(
        id: 't1',
        type: ThreadType.user,
        name: 'Lan',
        avatarUrl: '',
        lastMessage: null,
        lastTs: 1,
        unread: 0,
        pinned: false,
        muted: false,
        hidden: true,
        archived: true,
        autoDeleteTtl: 86400000,
      );
      final kept = copyThread(base, unread: 3);
      expect(kept.unread, 3);
      expect(kept.hidden, isTrue);
      expect(kept.archived, isTrue);
      expect(kept.autoDeleteTtl, 86400000);

      final cleared = copyThread(base, hidden: false, archived: false, autoDeleteTtl: 0);
      expect(cleared.hidden, isFalse);
      expect(cleared.archived, isFalse);
      expect(cleared.autoDeleteTtl, 0);
    });
  });

  group('hidden conversations', () {
    test('maps the pin flag and conversation refs', () {
      final hidden = hiddenConversationsFromJson(asJson(jsonDecode('''
        {"pinSet":true,"threads":[
          {"threadId":"u1","threadType":"user"},
          {"threadId":"g1","threadType":"group"}
        ]}
      ''')));
      expect(hidden.pinSet, isTrue);
      expect(hidden.threads.map((t) => t.id), ['u1', 'g1']);
      expect(hidden.threads.map((t) => t.type), [ThreadType.user, ThreadType.group]);
    });

    test('defaults are an unset pin and no conversations', () {
      final bare = hiddenConversationsFromJson(const {});
      expect(bare.pinSet, isFalse);
      expect(bare.threads, isEmpty);

      final malformed = hiddenConversationsFromJson(const {'pinSet': 'yes', 'threads': 'nope'});
      expect(malformed.pinSet, isFalse);
      expect(malformed.threads, isEmpty);
    });

    test('a pin hash or plain pin in the payload cannot surface', () {
      final hidden = hiddenConversationsFromJson(const {'pin': '1234', 'pinHash': 'deadbeef', 'threads': []});
      expect(hidden.pinSet, isFalse);
      expect(hidden.threads, isEmpty);
    });
  });

  group('archive list', () {
    test('maps the refs and the list version', () {
      final archive = archivedChatListFromJson({
        'threads': [
          {'threadId': 'g1', 'threadType': 'group'},
          'junk',
        ],
        'version': 7,
      });
      expect(archive.threads.single.id, 'g1');
      expect(archive.threads.single.type, ThreadType.group);
      expect(archive.version, 7);
    });

    test('defaults to an empty list at version zero', () {
      final bare = archivedChatListFromJson(const {});
      expect(bare.threads, isEmpty);
      expect(bare.version, 0);
      expect(archivedChatListFromJson(const {'version': 'oops'}).version, 0);
    });
  });

  group('labels', () {
    test('maps every field and coerces malformed scalars', () {
      final label = conversationLabelFromJson({
        'id': 3,
        'text': 'Gia đình',
        'textKey': 'family',
        'conversations': ['g01', null, 7],
        'color': '#E86A5B',
        'offset': '2',
        'emoji': 'home',
        'createTime': 1700000000000,
      });
      expect(label.id, 3);
      expect(label.text, 'Gia đình');
      expect(label.textKey, 'family');
      expect(label.conversations, ['g01', '7']);
      expect(label.color, '#E86A5B');
      expect(label.offset, 2);
      expect(label.emoji, 'home');
      expect(label.createTime, 1700000000000);
    });

    test('defaults are safe for a bare label', () {
      final label = conversationLabelFromJson(const {'id': 'oops'});
      expect(label.id, 0);
      expect(label.text, '');
      expect(label.textKey, '');
      expect(label.conversations, isEmpty);
      expect(label.color, '');
      expect(label.offset, 0);
      expect(label.emoji, '');
      expect(label.createTime, 0);
    });

    test('the update payload carries the version and the whole set', () {
      const label = ConversationLabel(
        id: 4,
        text: 'Bạn bè',
        textKey: 'friends',
        conversations: ['u01', 'u02'],
        color: '#4A7DFF',
        offset: 1,
        emoji: 'star',
        createTime: 1700000000000,
      );
      final payload = {
        'labels': [conversationLabelToJson(label)],
        'version': 5,
      };
      expect(payload['version'], 5);
      expect(payload['labels'], [
        {
          'id': 4,
          'text': 'Bạn bè',
          'textKey': 'friends',
          'conversations': ['u01', 'u02'],
          'color': '#4A7DFF',
          'offset': 1,
          'emoji': 'star',
          'createTime': 1700000000000,
        },
      ]);
    });

    test('maps the whole label state', () {
      final state = labelsStateFromJson({
        'labels': [
          {'id': 1, 'text': 'Gia đình', 'conversations': ['g01']},
        ],
        'version': 5,
        'lastUpdateTime': 111,
      });
      expect(state.labels.single.text, 'Gia đình');
      expect(state.labels.single.conversations, ['g01']);
      expect(state.version, 5);
      expect(state.lastUpdateTime, 111);

      final bare = labelsStateFromJson(const {});
      expect(bare.labels, isEmpty);
      expect(bare.version, 0);
      expect(bare.lastUpdateTime, 0);
      expect(labelsStateFromJson(const {'labels': 'nope'}).labels, isEmpty);
    });
  });

  group('auto-delete', () {
    test('accepts only the TTLs Zalo supports', () {
      expect(autoDeleteTtls, [0, 86400000, 604800000, 1209600000]);
      for (final ttl in autoDeleteTtls) {
        expect(supportsAutoDeleteTtl(ttl), isTrue, reason: '$ttl');
      }
      for (final ttl in [1, 30000, 1209600001, -86400000]) {
        expect(supportsAutoDeleteTtl(ttl), isFalse, reason: '$ttl');
      }
    });

    test('maps conversations with their ttl and optional created time', () {
      final chat = autoDeleteChatFromJson({
        'conversations': [
          {'threadId': 'u1', 'threadType': 'user', 'ttl': 86400000, 'createdAt': 1700000000000},
          {'threadId': 'g1', 'threadType': 'group', 'ttl': 0},
          'junk',
        ],
      });
      expect(chat.conversations, hasLength(2));
      expect(chat.conversations.first.threadId, 'u1');
      expect(chat.conversations.first.threadType, ThreadType.user);
      expect(chat.conversations.first.ttl, 86400000);
      expect(chat.conversations.first.createdAt, 1700000000000);
      expect(chat.conversations.last.threadType, ThreadType.group);
      expect(chat.conversations.last.createdAt, isNull);
    });

    test('defaults to no conversations', () {
      expect(autoDeleteChatFromJson(const {}).conversations, isEmpty);
      expect(autoDeleteChatFromJson(const {'conversations': 'nope'}).conversations, isEmpty);
      expect(autoDeleteChatFromJson(const {'conversations': [null]}).conversations, isEmpty);
    });
  });

  group('linked devices', () {
    test('maps the master and the companion display fields', () {
      final devices = linkedDevicesFromJson({
        'masterId': 'self',
        'lastUpdateTs': 1700000000000,
        'companions': [
          {
            'id': 'd1',
            'name': 'iPhone 15',
            'platform': 'ios',
            'lastUpdateTs': 1700000000001,
            'current': true,
          },
          {'name': 'Windows', 'current': 1},
        ],
      })!;
      expect(devices.masterId, 'self');
      expect(devices.lastUpdateTs, 1700000000000);
      expect(devices.companions, hasLength(2));
      final phone = devices.companions.first;
      expect(phone.id, 'd1');
      expect(phone.name, 'iPhone 15');
      expect(phone.platform, 'ios');
      expect(phone.lastUpdateTs, 1700000000001);
      expect(phone.current, isTrue);
      expect(phone.summary, isNull);
      expect(devices.companions.last.current, isTrue);
      expect(devices.companions.last.platform, isNull);
    });

    test('identity and signature blobs never reach the model', () {
      final devices = linkedDevicesFromJson({
        'masterId': 'self',
        'companions': [
          {
            'summary': 'object(3)',
            'identityKey': 'SECRET-IDENTITY',
            'signature': 'SECRET-SIGNATURE',
            'secretKey': 'SECRET-KEY',
          },
        ],
      })!;
      final fallback = devices.companions.single;
      expect(fallback.summary, 'object(3)');
      expect(fallback.id, isNull);
      expect(fallback.name, isNull);
      expect(fallback.platform, isNull);
      expect(fallback.lastUpdateTs, isNull);
      expect(fallback.current, isFalse);
    });

    test('defaults and absence are safe', () {
      expect(linkedDevicesFromJson(null), isNull);
      expect(linkedDevicesFromJson('nope'), isNull);
      final bare = linkedDevicesFromJson(const {})!;
      expect(bare.masterId, '');
      expect(bare.lastUpdateTs, isNull);
      expect(bare.companions, isEmpty);
      expect(linkedDevicesFromJson(const {'companions': 'nope'})!.companions, isEmpty);
    });
  });

  test('Phase D capabilities map and unknown values stay forward-compatible', () {
    final summary = accountSummaryFromJson({
      'slot': 's1',
      'capabilities': ['archive', 'hidden', 'labels', 'autoDelete', 'zaloDevices', 'futureThing'],
    });
    expect(summary.capabilities, {
      AccountCapability.archive,
      AccountCapability.hidden,
      AccountCapability.labels,
      AccountCapability.autoDelete,
      AccountCapability.zaloDevices,
    });
  });

  group('fake session', () {
    FakeSession fakeSession() {
      final app = FakeZalosApp();
      addTearDown(app.dispose);
      return app.fakeLink.session('main');
    }

    test('hidden conversations update the thread map and the list', () async {
      final session = fakeSession();
      expect((await session.hiddenConversations()).threads, isEmpty);

      await session.setHidden('u01', ThreadType.user, true);
      expect(session.hiddenThreads.single.id, 'u01');
      expect(session.threads.value.firstWhere((t) => t.id == 'u01').hidden, isTrue);
      final hidden = await session.hiddenConversations();
      expect(hidden.pinSet, isFalse);
      expect(hidden.threads.single.type, ThreadType.user);

      await session.setHidden('u01', ThreadType.user, false);
      expect((await session.hiddenConversations()).threads, isEmpty);
      expect(session.threads.value.firstWhere((t) => t.id == 'u01').hidden, isFalse);
    });

    test('the PIN is forwarded once and never recorded', () async {
      final session = fakeSession();
      await session.setHiddenPin('1234');
      expect(session.hiddenPinSet, isTrue);
      expect(session.hiddenPinSets, 1);
      expect((await session.hiddenConversations()).pinSet, isTrue);

      await session.resetHiddenPin();
      expect(session.hiddenPinSet, isFalse);
      expect((await session.hiddenConversations()).pinSet, isFalse);

      await expectLater(
        session.setHiddenPin('12a4'),
        throwsA(isA<RpcException>()
            .having((e) => e.code, 'code', 'bad_request')
            .having((e) => e.message, 'message', isNot(contains('12a4')))),
      );
      expect(session.hiddenPinSets, 1);
    });

    test('archive list tracks the version and the thread flag', () async {
      final session = fakeSession();
      await session.setArchived('g01', ThreadType.group, true);
      expect(session.archiveVersion, 1);
      expect(session.threads.value.firstWhere((t) => t.id == 'g01').archived, isTrue);
      final archive = await session.archivedChats();
      expect(archive.version, 1);
      expect(archive.threads.single.id, 'g01');
      expect(archive.threads.single.type, ThreadType.group);

      await session.setArchived('g01', ThreadType.group, false);
      expect(session.archiveVersion, 2);
      expect((await session.archivedChats()).threads, isEmpty);
      expect(session.threads.value.firstWhere((t) => t.id == 'g01').archived, isFalse);
    });

    test('labels update with the expected version and conflict on a stale one', () async {
      final session = fakeSession();
      final seeded = await session.labels();
      expect(seeded.version, session.labelsVersion);
      expect(seeded.labels.map((l) => l.id), [1, 2, 3]);

      const next = [ConversationLabel(id: 9, text: 'Mới', conversations: ['u07'])];
      final updated = await session.updateLabels(next, seeded.version);
      expect(updated.version, seeded.version + 1);
      expect(updated.labels.single.id, 9);
      expect(updated.lastUpdateTime, fakeNow.millisecondsSinceEpoch);
      expect((await session.labels()).version, updated.version);

      await expectLater(
        session.updateLabels(next, seeded.version),
        throwsA(isA<RpcException>().having((e) => e.code, 'code', 'conflict')),
      );
      expect((await session.labels()).labels.single.id, 9);
    });

    test('auto-delete validates the ttl and updates the thread flag', () async {
      final session = fakeSession();
      await session.setAutoDelete('u02', ThreadType.user, 86400000);
      expect(session.threads.value.firstWhere((t) => t.id == 'u02').autoDeleteTtl, 86400000);
      final chat = await session.autoDeleteChats();
      expect(chat.conversations.single.threadId, 'u02');
      expect(chat.conversations.single.ttl, 86400000);
      expect(chat.conversations.single.createdAt, fakeNow.millisecondsSinceEpoch);

      await session.setAutoDelete('u02', ThreadType.user, 0);
      expect((await session.autoDeleteChats()).conversations, isEmpty);
      expect(session.threads.value.firstWhere((t) => t.id == 'u02').autoDeleteTtl, 0);

      await expectLater(
        session.setAutoDelete('u02', ThreadType.user, 30000),
        throwsA(isA<ArgumentError>()),
      );
    });

    test('linked devices serve the seeded companions and can be reseeded', () async {
      final session = fakeSession();
      final devices = await session.linkedDevices();
      expect(devices.masterId, session.selfUid);
      expect(devices.companions, hasLength(3));
      expect(devices.companions.first.name, 'iPhone của Thư');
      expect(devices.companions.first.current, isTrue);
      expect(devices.companions.last.summary, 'object(3)');
      expect(devices.companions.last.name, isNull);

      session.linkedDeviceList = const LinkedDevices(masterId: 'other');
      expect((await session.linkedDevices()).companions, isEmpty);
    });
  });
}
