import 'dart:convert';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:zalos/src/data/key_store.dart';
import 'package:zalos/src/data/mapping.dart';
import 'package:zalos/src/data/media_cache.dart';
import 'package:zalos/src/data/pairing.dart';
import 'package:zalos/src/domain/models.dart';
import 'package:zalos/src/domain/services.dart';

void main() {
  test('account summary maps wire capabilities and kind', () {
    final a = accountSummaryFromJson(asJson(jsonDecode('''
      {"slot":"s1","kind":"oa","capabilities":["groups","fullAvatar","bogus"],"uid":"u1",
       "displayName":"OA","avatarUrl":"","status":"online"}
    ''')));
    expect(a.kind, AccountKind.oa);
    expect(a.capabilities, {AccountCapability.groups, AccountCapability.fullAvatar});
  });

  group('message', () {
    test('maps a full message', () {
      final message = messageFromJson(asJson(jsonDecode('''
        {"id":"m1","cliId":"c1","threadId":"t1","threadType":"group","senderId":"u1",
         "senderName":"An","ts":1700000000123,"isSelf":true,"kind":"image","text":"hi",
         "attachments":[{"kind":"image","url":"https://x/a.jpg","thumbUrl":"https://x/t.jpg",
           "name":"a.jpg","size":10,"width":3,"height":4,"durationMs":5}],
         "sticker":{"id":1,"cateId":2,"type":3,"url":"https://x/s.png"},
         "quote":{"msgId":"m0","senderId":"u2","senderName":"Binh","text":"old"},
         "mentions":[{"uid":"u2","pos":0,"len":4}],
         "reactions":{"/-heart":["u2","u3"]},"recalled":true,"raw":{"anything":1}}
      ''')));
      expect(message.id, 'm1');
      expect(message.cliId, 'c1');
      expect(message.threadType, ThreadType.group);
      expect(message.ts, 1700000000123);
      expect(message.isSelf, isTrue);
      expect(message.kind, MessageKind.image);
      expect(message.attachments.single.thumbUrl, 'https://x/t.jpg');
      expect(message.attachments.single.durationMs, 5);
      expect(message.sticker!.cateId, 2);
      expect(message.quote!.senderName, 'Binh');
      expect(message.mentions.single.len, 4);
      expect(message.reactions, {
        '/-heart': ['u2', 'u3'],
      });
      expect(message.recalled, isTrue);
      expect(message.sendState, SendState.sent);
    });

    test('tolerates missing optional fields and unknown kind', () {
      final message = messageFromJson({'id': 'm2', 'threadId': 't', 'kind': 'hologram', 'ts': 5.0});
      expect(message.kind, MessageKind.other);
      expect(message.cliId, isNull);
      expect(message.threadType, ThreadType.user);
      expect(message.text, isNull);
      expect(message.attachments, isEmpty);
      expect(message.mentions, isEmpty);
      expect(message.reactions, isEmpty);
      expect(message.sticker, isNull);
      expect(message.quote, isNull);
      expect(message.recalled, isFalse);
      expect(message.isSelf, isFalse);
      expect(message.ts, 5);
      expect(message.senderName, '');
    });

    test('null collections are treated as empty', () {
      final message = messageFromJson({'id': 'm', 'attachments': null, 'mentions': null, 'reactions': null});
      expect(message.attachments, isEmpty);
      expect(message.reactions, isEmpty);
    });
  });

  test('thread with and without last message', () {
    final thread = threadFromJson({
      'id': 't1',
      'type': 'group',
      'name': 'Team',
      'avatarUrl': 'https://x/a.png',
      'lastMessage': {'id': 'm1', 'threadId': 't1', 'kind': 'text', 'text': 'yo'},
      'lastTs': 9,
      'unread': 2,
      'pinned': true,
      'muted': 1,
    });
    expect(thread.type, ThreadType.group);
    expect(thread.lastMessage!.text, 'yo');
    expect(thread.unread, 2);
    expect(thread.pinned, isTrue);
    expect(thread.muted, isTrue);

    final bare = threadFromJson({'id': 't2', 'lastMessage': null, 'name': null});
    expect(bare.lastMessage, isNull);
    expect(bare.name, '');
    expect(bare.lastTs, 0);
    expect(bare.pinned, isFalse);
  });

  test('account status including unknown values', () {
    expect(accountStatusFromWire('online'), AccountStatus.online);
    expect(accountStatusFromWire('needs_login'), AccountStatus.needsLogin);
    expect(accountStatusFromWire('displaced'), AccountStatus.displaced);
    expect(accountStatusFromWire('banned'), AccountStatus.error);
    expect(accountStatusFromWire(null), AccountStatus.error);
  });

  test('manifest', () {
    final manifest = manifestFromJson({
      'server': {'name': 'zalos', 'version': '0.1.0', 'fingerprint': 'ab:cd'},
      'device': {'id': 'd1', 'name': 'Phone', 'role': 'admin'},
      'accounts': [
        {'slot': 's1', 'uid': 'u-me', 'displayName': 'Me', 'avatarUrl': '', 'status': 'reconnecting', 'unread': 4},
        {'slot': 's2', 'status': 'weird'},
      ],
    });
    expect(manifest.server.fingerprint, 'ab:cd');
    expect(manifest.deviceName, 'Phone');
    expect(manifest.role, DeviceRole.admin);
    expect(manifest.accounts[0].status, AccountStatus.reconnecting);
    expect(manifest.accounts[0].unread, 4);
    expect(manifest.accounts[0].uid, 'u-me');
    expect(manifest.accounts[1].uid, '');
    expect(manifest.accounts[1].status, AccountStatus.error);
    expect(manifest.accounts[1].displayName, '');
    expect(manifestFromJson(const {}).accounts, isEmpty);
  });

  test('device, contact, group, pairing offer, typing', () {
    final device = deviceInfoFromJson({
      'id': 'd',
      'name': 'n',
      'role': 'member',
      'createdAt': 1,
      'lastSeenAt': null,
      'slots': ['a', 'b'],
    });
    expect(device.role, DeviceRole.member);
    expect(device.lastSeenAt, isNull);
    expect(device.revoked, isFalse);
    expect(device.slots, ['a', 'b']);

    expect(contactFromJson({'uid': 'u', 'displayName': 'D', 'avatarUrl': 'a'}).alias, isNull);
    final group = groupInfoFromJson({'id': 'g', 'name': 'G', 'avatarUrl': '', 'memberIds': ['x', 'y']});
    expect(group.memberIds, ['x', 'y']);
    expect(group.ownerId, isNull);
    expect(pairingOfferFromJson({'uri': 'zalos://pair?x', 'expiresAt': 12}).expiresAt, 12);
    expect(typingEventFromJson({'threadId': 't', 'threadType': 'user', 'userId': 'u'}).userId, 'u');
  });

  group('pairing uri', () {
    final secret = base64Url.encode(List.filled(32, 7)).replaceAll('=', '');
    final key = base64Url.encode(List.filled(32, 250)).replaceAll('=', '');

    test('parses the optional vault root', () {
      final root = base64Url.encode(List.filled(32, 9)).replaceAll('=', '');
      final base = 'zalos://pair?host=h&port=1&id=ab&secret=$secret&key=$key';
      expect(parsePairingUri(base).vaultRoot, isNull);
      expect(parsePairingUri('$base&vault=$root').vaultRoot, List.filled(32, 9));
      expect(() => parsePairingUri('$base&vault=AAAA'), throwsA(isA<PairingException>()));
    });

    test('parses unpadded base64url fields', () {
      final params = parsePairingUri('zalos://pair?host=100.64.0.1&port=7443&id=0a1b2c3d&secret=$secret&key=$key');
      expect(params.host, '100.64.0.1');
      expect(params.port, 7443);
      expect(params.pairingId, '0a1b2c3d');
      expect(params.secret, List.filled(32, 7));
      expect(params.serverPublicKey, List.filled(32, 250));
    });

    test('rejects bad input', () {
      for (final bad in [
        '',
        'hello',
        'https://pair?host=a&port=1&id=ab&secret=$secret&key=$key',
        'zalos://pair?host=a&port=1&id=ab&secret=$secret',
        'zalos://pair?host=a&port=0&id=ab&secret=$secret&key=$key',
        'zalos://pair?host=a&port=1&id=../x&secret=$secret&key=$key',
        'zalos://pair?host=a&port=1&id=ab&secret=AAAA&key=$key',
        'zalos://pair?host=&port=1&id=ab&secret=$secret&key=$key',
      ]) {
        expect(() => parsePairingUri(bad), throwsA(isA<PairingException>()), reason: bad);
      }
    });
  });

  test('credentials round trip through a key store', () async {
    final store = MemoryKeyStore();
    expect(await Credentials.load(store), isNull);
    final credentials = Credentials(
      host: 'h',
      port: 1,
      serverPublicKey: Uint8List.fromList(List.filled(32, 1)),
      devicePrivateKey: Uint8List.fromList(List.filled(32, 2)),
      devicePublicKey: Uint8List.fromList(List.filled(32, 3)),
      devicePsk: Uint8List.fromList(List.filled(32, 4)),
      deviceId: 'dev',
      boxPrivateKey: Uint8List.fromList(List.filled(32, 5)),
      boxPublicKey: Uint8List.fromList(List.filled(32, 6)),
    );
    await credentials.save(store);
    final loaded = (await Credentials.load(store))!;
    expect(loaded.host, 'h');
    expect(loaded.port, 1);
    expect(loaded.devicePsk, credentials.devicePsk);
    expect(loaded.devicePrivateKey, credentials.devicePrivateKey);
    expect(loaded.deviceId, 'dev');
    expect(loaded.boxPrivateKey, credentials.boxPrivateKey);
    expect(loaded.boxPublicKey, credentials.boxPublicKey);
    expect(loaded.vaultRoot, isNull);
    await credentials.withVaultRoot(Uint8List.fromList(List.filled(32, 7))).save(store);
    expect((await Credentials.load(store))!.vaultRoot, List.filled(32, 7));
    expect(Credentials.decode('not json'), isNull);
  });

  test('media cache evicts least recently used by bytes', () {
    final cache = MediaCache(maxBytes: 100);
    cache.put('a', Uint8List(40));
    cache.put('b', Uint8List(40));
    expect(cache.get('a'), isNotNull);
    cache.put('c', Uint8List(40));
    expect(cache.get('b'), isNull);
    expect(cache.get('a'), isNotNull);
    expect(cache.get('c'), isNotNull);
    expect(cache.bytes, 80);
    cache.put('huge', Uint8List(101));
    expect(cache.get('huge'), isNull);
    expect(cache.bytes, 80);
  });
}
