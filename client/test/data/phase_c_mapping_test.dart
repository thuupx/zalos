import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:zalos/src/data/mapping.dart';
import 'package:zalos/src/domain/models.dart';

void main() {
  group('contact card', () {
    test('maps a full card', () {
      final card = contactCardFromJson(asJson(jsonDecode('''
        {"uid":"u1","displayName":"Trần Thị Hoa","avatarUrl":"https://a/hoa.jpg",
         "phone":"0900000000","qrCodeUrl":"https://a/qr.png"}
      ''')));
      expect(card.uid, 'u1');
      expect(card.displayName, 'Trần Thị Hoa');
      expect(card.avatarUrl, 'https://a/hoa.jpg');
      expect(card.phone, '0900000000');
      expect(card.qrCodeUrl, 'https://a/qr.png');
    });

    test('tolerates missing optional fields', () {
      final card = contactCardFromJson(const {'uid': 'u2'});
      expect(card.uid, 'u2');
      expect(card.displayName, '');
      expect(card.avatarUrl, '');
      expect(card.phone, isNull);
      expect(card.qrCodeUrl, isNull);
    });
  });

  group('card message', () {
    test('maps a plaintext card body', () {
      final message = messageFromJson({
        'id': 'm1',
        'threadId': 't1',
        'threadType': 'user',
        'kind': 'card',
        'body': {
          'text': 'Trần Thị Hoa',
          'card': {'uid': 'u1', 'displayName': 'Trần Thị Hoa', 'avatarUrl': 'https://a/hoa.jpg', 'phone': '0900000000'},
        },
      });
      expect(message.kind, MessageKind.card);
      expect(message.text, 'Trần Thị Hoa');
      expect(message.card!.uid, 'u1');
      expect(message.card!.phone, '0900000000');
      expect(message.card!.qrCodeUrl, isNull);
    });

    test('maps a sealed card body through the opener', () {
      final message = messageFromJson(
        {'id': 'm1', 'threadId': 't1', 'kind': 'card', 'sealed': 'cipher'},
        open: (id, sealed) => {
          'text': 'Trần Thị Hoa',
          'card': {'uid': 'u1', 'displayName': 'Trần Thị Hoa', 'avatarUrl': '', 'qrCodeUrl': 'https://a/qr.png'},
        },
      );
      expect(message.card!.uid, 'u1');
      expect(message.card!.qrCodeUrl, 'https://a/qr.png');
      expect(message.text, 'Trần Thị Hoa');
    });

    test('keeps clear fields when a sealed body does not open', () {
      var locked = 0;
      final message = messageFromJson(
        {'id': 'm1', 'threadId': 't1', 'kind': 'card', 'sealed': 'cipher'},
        open: (id, sealed) => null,
        onLocked: (_) => locked++,
      );
      expect(locked, 1);
      expect(message.kind, MessageKind.card);
      expect(message.card, isNull);
      expect(message.text, isNull);
    });
  });

  test('card kind maps and unknown kinds still degrade to other', () {
    expect(messageKindFromWire('card'), MessageKind.card);
    expect(messageKindToWire(MessageKind.card), 'card');
    expect(messageKindFromWire('hologram'), MessageKind.other);
  });

  group('contacts and groups', () {
    test('contact maps closeFriend and alias', () {
      final friend = contactFromJson({'uid': 'u1', 'displayName': 'Hoa', 'avatarUrl': 'a', 'alias': 'Chị Hoa', 'closeFriend': true});
      expect(friend.alias, 'Chị Hoa');
      expect(friend.closeFriend, isTrue);

      final numeric = contactFromJson({'uid': 'u2', 'closeFriend': 1});
      expect(numeric.closeFriend, isTrue);

      final malformed = contactFromJson({'uid': 'u3', 'closeFriend': 'yes'});
      expect(malformed.closeFriend, isFalse);
      expect(contactFromJson(const {}).closeFriend, isFalse);
    });

    test('group info exposes adminIds for admin gating', () {
      final group = groupInfoFromJson({
        'id': 'g1',
        'name': 'Team',
        'avatarUrl': '',
        'memberIds': ['u1', 'u2'],
        'ownerId': 'u1',
        'adminIds': ['u2', null],
      });
      expect(group.ownerId, 'u1');
      expect(group.adminIds, ['u2']);
      expect(groupInfoFromJson(const {'id': 'g2'}).adminIds, isEmpty);
      expect(groupInfoFromJson(const {'id': 'g3', 'adminIds': 'nope'}).adminIds, isEmpty);
    });

    test('group info maps the total member count above the member page', () {
      final counted = groupInfoFromJson({
        'id': 'g1',
        'memberIds': ['u1', 'u2'],
        'memberCount': 8,
      });
      expect(counted.memberIds, ['u1', 'u2']);
      expect(counted.memberCount, 8);
      expect(groupInfoFromJson(const {'id': 'g2', 'memberIds': ['u1']}).memberCount, isNull);
      expect(groupInfoFromJson(const {'id': 'g3', 'memberCount': 'many'}).memberCount, isNull);
    });
  });

  test('Phase C capabilities map and unknown values stay forward-compatible', () {
    final summary = accountSummaryFromJson({
      'slot': 's1',
      'capabilities': ['friends', 'presence', 'contactCard', 'report', 'deleteForAll', 'futureThing'],
    });
    expect(summary.capabilities, {
      AccountCapability.friends,
      AccountCapability.presence,
      AccountCapability.contactCard,
      AccountCapability.report,
      AccountCapability.deleteForAll,
    });
  });

  group('user profile', () {
    test('maps a full profile', () {
      final user = userProfileFromJson({
        'uid': 'u1',
        'displayName': 'Trần Thị Hoa',
        'avatarUrl': 'https://a/hoa.jpg',
        'zaloName': 'hoa.tran',
        'gender': 'female',
        'phoneNumber': '0900000000',
      })!;
      expect(user.uid, 'u1');
      expect(user.displayName, 'Trần Thị Hoa');
      expect(user.avatarUrl, 'https://a/hoa.jpg');
      expect(user.zaloName, 'hoa.tran');
      expect(user.gender, 'female');
      expect(user.phoneNumber, '0900000000');
    });

    test('returns null when Zalo has no match', () {
      expect(userProfileFromJson(null), isNull);
      expect(userProfileFromJson('nope'), isNull);
      expect(userProfileFromJson(const {}), isNull);
      expect(userProfileFromJson(const {'uid': ''}), isNull);
    });

    test('coerces malformed scalar fields', () {
      final user = userProfileFromJson({'uid': 777, 'displayName': 5, 'gender': 1})!;
      expect(user.uid, '777');
      expect(user.displayName, '5');
      expect(user.gender, '1');
      expect(user.zaloName, isNull);
      expect(user.phoneNumber, isNull);
    });
  });

  test('friend request status maps flags and privacy', () {
    final status = friendRequestStatusFromJson({
      'isFriend': true,
      'isRequested': 1,
      'isRequesting': false,
      'addFriendPrivacy': '2',
      'isSeen': true,
    });
    expect(status.isFriend, isTrue);
    expect(status.isRequested, isTrue);
    expect(status.isRequesting, isFalse);
    expect(status.addFriendPrivacy, 2);
    expect(status.isSeen, isTrue);

    final bare = friendRequestStatusFromJson(const {});
    expect(bare.isFriend, isFalse);
    expect(bare.isRequested, isFalse);
    expect(bare.isRequesting, isFalse);
    expect(bare.addFriendPrivacy, 0);
    expect(bare.isSeen, isFalse);
  });

  test('received and sent friend requests map with optional fields', () {
    final requests = friendRequestsFromJson({
      'received': [
        {'uid': 'u1', 'displayName': 'Hoa', 'avatarUrl': 'a', 'message': 'Xin chào', 'ts': 1700000000000},
      ],
      'sent': [
        {'uid': 'u2', 'displayName': 'Bảo'},
      ],
    });
    expect(requests.received.single.uid, 'u1');
    expect(requests.received.single.message, 'Xin chào');
    expect(requests.received.single.ts, 1700000000000);
    expect(requests.sent.single.uid, 'u2');
    expect(requests.sent.single.message, isNull);
    expect(requests.sent.single.ts, isNull);

    final empty = friendRequestsFromJson(const {});
    expect(empty.received, isEmpty);
    expect(empty.sent, isEmpty);
  });

  test('friend recommendation maps optional phone, gender and message', () {
    final user = friendRecommendationFromJson({
      'uid': 'u1',
      'displayName': 'Ngọc',
      'avatarUrl': 'a',
      'phoneNumber': '0900000001',
      'gender': 'female',
      'message': 'Cùng lớp',
    });
    expect(user.phoneNumber, '0900000001');
    expect(user.gender, 'female');
    expect(user.message, 'Cùng lớp');

    final bare = friendRecommendationFromJson(const {'uid': 'u2'});
    expect(bare.displayName, '');
    expect(bare.phoneNumber, isNull);
    expect(bare.gender, isNull);
    expect(bare.message, isNull);
  });

  test('presence and last seen map and tolerate malformed values', () {
    final presence = friendPresenceFromJson({'uid': 'u1', 'status': 'online', 'online': true});
    expect(presence.uid, 'u1');
    expect(presence.status, 'online');
    expect(presence.online, isTrue);

    final offline = friendPresenceFromJson({'uid': 'u2', 'online': 0});
    expect(offline.status, '');
    expect(offline.online, isFalse);

    final seen = lastSeenFromJson({'showOnlineStatus': 1, 'lastOnline': '1700000000000'});
    expect(seen.showOnlineStatus, isTrue);
    expect(seen.lastOnline, 1700000000000);

    final hidden = lastSeenFromJson(const {});
    expect(hidden.showOnlineStatus, isFalse);
    expect(hidden.lastOnline, 0);
    expect(lastSeenFromJson(const {'lastOnline': 'oops'}).lastOnline, 0);
  });

  test('report reasons map both ways with an other fallback', () {
    for (final reason in ReportReason.values) {
      expect(reportReasonFromWire(reportReasonToWire(reason)), reason);
    }
    expect(reportReasonFromWire('fraud'), ReportReason.fraud);
    expect(reportReasonFromWire('spam'), ReportReason.other);
    expect(reportReasonFromWire(null), ReportReason.other);
    expect(reportReasonToWire(ReportReason.sensitive), 'sensitive');
    expect(reportReasonToWire(ReportReason.other), 'other');
  });

  test('copyMessage keeps the card', () {
    const card = ContactCard(uid: 'u1', displayName: 'Hoa', avatarUrl: '', phone: '0900000000');
    final message = messageFromJson({
      'id': 'm1',
      'threadId': 't1',
      'kind': 'card',
      'body': {'card': {'uid': 'u1', 'displayName': 'Hoa', 'avatarUrl': '', 'phone': '0900000000'}},
    });
    final copy = copyMessage(message, id: 'm2', sendState: SendState.failed);
    expect(copy.id, 'm2');
    expect(copy.sendState, SendState.failed);
    expect(copy.card!.uid, card.uid);
    expect(copy.card!.phone, card.phone);
  });
}
