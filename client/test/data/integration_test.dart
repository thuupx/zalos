// End to end tests of the data layer against the real server in fake gateway
// mode. Needs `bun` on PATH and the release build of the Rust library.
//
// Run: flutter test test/data
import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:zalos/src/data/account_session.dart';
import 'package:zalos/src/data/key_store.dart';
import 'package:zalos/src/data/real_app.dart';
import 'package:zalos/src/data/server_link.dart';
import 'package:zalos/src/data/vault.dart';
import 'package:zalos/src/domain/models.dart';
import 'package:zalos/src/domain/services.dart';
import 'package:zalos/src/rust_lib/api/vault.dart' as rust;

import 'support.dart';

const friend = 'friend-1';
const other = 'friend-2';
const user = ThreadType.user;

void main() {
  late TestServer server;
  final devices = <Device>[];
  final proxies = <TcpProxy>[];

  Future<Device> pair(String uri, String name) async {
    final device = await pairDevice(uri, name);
    devices.add(device);
    return device;
  }

  Future<Device> pairAdmin([String name = 'Device A']) async => pair(await server.pairUri(role: 'admin'), name);

  String withVaultRoot(String uri, List<int> root) =>
      '$uri&vault=${base64Url.encode(root).replaceAll('=', '')}';

  /// Writes a foreign vault key for [slot] straight into the server db so a
  /// vault.setKey from the client conflicts.
  Future<void> flipServerVaultKey(String slot, List<int> publicKey) async {
    final code = """
      import { Database } from "bun:sqlite";
      const db = new Database("${server.dataDir.path}/zalos.db");
      db.run("UPDATE accounts SET vault_public_key = ? WHERE slot = ?",
        ["${base64Encode(Uint8List.fromList(publicKey))}", "$slot"]);
      db.close();
    """;
    final result = await Process.run('bun', ['-e', code]);
    if (result.exitCode != 0) {
      throw StateError('flipVaultKey failed: ${result.stdout}${result.stderr}');
    }
  }

  setUpAll(initRust);

  setUp(() async {
    server = await TestServer.create();
  });

  tearDown(() async {
    for (final device in devices) {
      device.app.dispose();
    }
    devices.clear();
    for (final proxy in proxies) {
      await proxy.close();
    }
    proxies.clear();
    await server.dispose();
  });

  test('pairing stores credentials, connects, and a pairing cannot be reused', () async {
    final uri = await server.pairUri(role: 'admin');
    final a = await pair(uri, 'Device A');

    final manifest = a.link.manifest.value!;
    expect(manifest.deviceName, 'Device A');
    expect(manifest.role, DeviceRole.admin);
    expect(manifest.server.fingerprint, isNotEmpty);
    expect(manifest.accounts, isEmpty);

    final stored = (await Credentials.load(a.keyStore))!;
    expect(stored.port, server.port);
    expect(stored.deviceId, manifest.deviceId);
    expect(stored.devicePsk, hasLength(32));
    expect(stored.devicePrivateKey, hasLength(32));
    expect(stored.boxPrivateKey, hasLength(32));
    expect(stored.boxPublicKey, hasLength(32));

    final second = await RealZalosApp.open(MemoryKeyStore());
    await expectLater(
      second.pair(uri, deviceName: 'Thief'),
      throwsA(isA<PairingException>()
          .having((e) => e.message, 'message', contains('expired or was already used'))
          .having((e) => e.code, 'code', PairingErrorCode.expired)),
    );
    expect(second.link.value, isNull);

    await expectLater(second.pair('zalos://pair?host=x', deviceName: 'x'), throwsA(isA<PairingException>()));

    final unknown = uri.replaceFirst(RegExp(r'id=[0-9a-f]+'), 'id=00000000deadbeef');
    await expectLater(second.pair(unknown, deviceName: 'x'), throwsA(isA<PairingException>()));

    final wrongSecret = (await server.pairUri()).replaceFirst(
      RegExp(r'secret=[^&]+'),
      'secret=${base64Url.encode(List.filled(32, 1)).replaceAll('=', '')}',
    );
    await expectLater(second.pair(wrongSecret, deviceName: 'x'), throwsA(isA<PairingException>()));

    final restored = await RealZalosApp.open(a.keyStore);
    final restoredDevice = Device(restored, a.keyStore);
    devices.add(restoredDevice);
    await restoredDevice.connected();
    expect(restoredDevice.link.manifest.value!.deviceId, manifest.deviceId);

    await restored.unpair();
    expect(restored.link.value, isNull);
    expect(await Credentials.load(a.keyStore), isNull);
  });

  test('fake QR login emits image, scanned, done and the manifest lists the account', () async {
    final a = await pairAdmin();
    final events = await a.link.startLoginQr().toList().timeout(const Duration(seconds: 15));

    expect(events.map((e) => e.runtimeType), [LoginQrImage, LoginQrScanned, LoginQrDone]);
    expect(utf8.decode((events[0] as LoginQrImage).png), 'fake-qr-png');
    expect((events[1] as LoginQrScanned).displayName, 'Fake Account');
    final slot = (events[2] as LoginQrDone).slot;
    expect(slot, isNotEmpty);

    await waitFor(
      () => a.link.manifest.value!.accounts.any((x) => x.slot == slot && x.status == AccountStatus.online),
      what: 'online account in manifest',
    );
    final account = a.link.manifest.value!.accounts.single;
    expect(account.displayName, 'Fake Account');
    expect(account.uid, isNotEmpty);
    expect(account.unread, 0);
    expect(identical(a.link.account(slot), a.link.account(slot)), isTrue);
  });

  test('text from device A shows once on A and once on B, threads stay ordered', () async {
    final a = await pairAdmin();
    final offer = await a.link.createPairing(role: DeviceRole.member);
    expect(offer.uri, contains('host=127.0.0.1&port=${server.port}&'));
    expect(offer.uri, contains('&vault='));
    expect(offer.expiresAt, greaterThan(DateTime.now().millisecondsSinceEpoch));
    final b = await pair(offer.uri, 'Device B');
    expect(b.link.manifest.value!.role, DeviceRole.member);

    final slot = await loginFakeAccount(a);
    await a.link.setDeviceAcl(b.link.manifest.value!.deviceId, [slot]);
    final sa = await openAccount(a, slot);
    final sb = await openAccount(b, slot);
    final listA = sa.messages(friend, user);
    final listB = sb.messages(friend, user);
    expect(identical(listA, sa.messages(friend, user)), isTrue);
    expect(sa.threads.value, isEmpty);

    final sending = sa.sendText(friend, user, 'hello from A');
    expect(listA.value, hasLength(1));
    expect(listA.value.single.sendState, SendState.sending);
    expect(listA.value.single.isSelf, isTrue);
    final cliId = listA.value.single.cliId;
    expect(listA.value.single.id, cliId);
    await sending;

    await waitFor(() => listB.value.isNotEmpty, what: 'message on B');
    await Future<void>.delayed(const Duration(milliseconds: 300));
    expect(listA.value, hasLength(1));
    expect(listA.value.single.sendState, SendState.sent);
    expect(listA.value.single.cliId, cliId);
    expect(listA.value.single.id, isNot(cliId));
    expect(listA.value.single.text, 'hello from A');
    expect(listB.value, hasLength(1));
    expect(listB.value.single.id, listA.value.single.id);
    expect(listB.value.single.isSelf, isTrue);
    expect(listB.value.single.sendState, SendState.sent);

    await waitFor(() => sa.threads.value.length == 1 && sb.threads.value.length == 1, what: 'thread on both');
    expect(sb.threads.value.single.id, friend);
    expect(sb.threads.value.single.lastMessage!.text, 'hello from A');
    expect(sb.threads.value.single.unread, 0);

    await Future<void>.delayed(const Duration(milliseconds: 10));
    await sb.sendText(other, user, 'second thread');
    await waitFor(() => sa.threads.value.length == 2 && sb.threads.value.length == 2, what: 'two threads');
    expect(sa.threads.value.map((t) => t.id), [other, friend]);
    expect(sb.threads.value.map((t) => t.id), [other, friend]);

    await Future<void>.delayed(const Duration(milliseconds: 10));
    final first = listA.value.single;
    await sa.sendText(friend, user, 'bump', quote: first);
    await waitFor(() => sb.threads.value.first.id == friend, what: 'reordered threads');
    expect(sa.threads.value.map((t) => t.id), [friend, other]);
    await waitFor(() => listB.value.length == 2, what: 'second message on B');
    expect(listB.value.map((m) => m.text), ['hello from A', 'bump']);
    expect(listB.value.last.quote!.text, 'hello from A');
    expect(listB.value.last.quote!.msgId, first.id);
    expect(listA.value.map((m) => m.text), ['hello from A', 'bump']);
    expect(listA.value.last.quote!.text, 'hello from A');
    expect(listA.value.last.quote!.senderName, first.senderName);

    // A message without a raw payload cannot be quoted end to end.
    final noRaw = Message(
      id: 'no-raw',
      cliId: null,
      threadId: friend,
      threadType: user,
      senderId: first.senderId,
      senderName: first.senderName,
      ts: first.ts,
      isSelf: true,
      kind: first.kind,
    );
    await sa.sendText(friend, user, 'unquoted', quote: noRaw);
    await waitFor(() => listB.value.length == 3, what: 'third message on B');
    expect(listA.value.last.quote, isNull);
    expect(listB.value.last.quote, isNull);

    await sb.deleteForMe(listB.value.last);
    await waitFor(() => listA.value.length == 2 && listB.value.length == 2, what: 'cleanup delete');

    final fresh = (b.link.account(slot) as RealAccountSession);
    expect(fresh.lastSeq, greaterThan(0));
    expect(await sa.loadOlder(friend, user), isFalse);

    final uid = a.link.manifest.value!.accounts.single.uid;
    await sb.react(listB.value.first, '/-heart');
    await waitFor(() => listA.value.first.reactions.isNotEmpty, what: 'reaction on A');
    expect(listA.value.first.reactions, {
      '/-heart': [uid],
    });
    expect(listB.value.first.reactions['/-heart'], [uid]);
    expect(listA.value.first.text, 'hello from A');
    await sb.react(listB.value.first, '');
    await waitFor(
      () => (listA.value.first.reactions['/-heart'] ?? const []).isEmpty,
      what: 'reaction removed on A',
    );

    await sa.recall(listA.value.first);
    await waitFor(() => listB.value.first.recalled, what: 'recall on B');
    await waitFor(() => listA.value.first.recalled, what: 'recall on A');
    expect(listA.value.first.text, isNull);
    expect(listB.value.first.text, isNull);

    // A message without a raw payload cannot be quoted end to end.
    final noRaw2 = Message(
      id: 'no-raw',
      cliId: null,
      threadId: friend,
      threadType: user,
      senderId: first.senderId,
      senderName: first.senderName,
      ts: first.ts,
      isSelf: true,
      kind: first.kind,
    );
    await sa.sendText(friend, user, 'unquoted2', quote: noRaw2);
    await waitFor(() => listB.value.length == 3, what: 'third message on B');
    expect(listB.value.last.quote, isNull);

    await sb.deleteForMe(listB.value.last);
    await waitFor(() => listA.value.length == 2 && listB.value.length == 2, what: 'delete on both');

    await sa.sendSticker(friend, user, (await sa.searchStickers('hi')).first);
    await waitFor(() => listB.value.length == 3, what: 'sticker on B');
    expect(listB.value.last.kind, MessageKind.sticker);
    expect(listB.value.last.sticker!.id, 1);
    expect(listA.value, hasLength(3));

    await sa.markSeen(friend, user);
    sa.sendTyping(friend, user);
    expect((await sa.contacts()).single.uid, friend);
    expect((await sa.groups()).single.id, 'group-1');
    expect((await sa.groupInfo('group-1')).ownerId, isNotNull);
  });

  test('a new session loads history pages from the server', () async {
    final a = await pairAdmin();
    final slot = await loginFakeAccount(a);
    final sa = await openAccount(a, slot);
    for (var i = 0; i < 60; i++) {
      await sa.sendText(friend, user, 'm$i');
      await Future<void>.delayed(const Duration(milliseconds: 2));
    }

    final again = await RealZalosApp.open(a.keyStore);
    final device = Device(again, a.keyStore);
    devices.add(device);
    await device.connected();
    final session = await openAccount(device, slot);
    await waitFor(() => session.threads.value.isNotEmpty, what: 'threads after first sync');
    expect(session.threads.value.single.lastMessage!.text, 'm59');

    final list = session.messages(friend, user);
    await waitFor(() => list.value.isNotEmpty, what: 'latest page');
    expect(list.value, hasLength(50));
    expect(list.value.first.text, 'm10');
    expect(list.value.last.text, 'm59');

    expect(await session.loadOlder(friend, user), isTrue);
    expect(list.value, hasLength(60));
    expect(list.value.map((m) => m.text), [for (var i = 0; i < 60; i++) 'm$i']);
    expect(await session.loadOlder(friend, user), isFalse);
  }, timeout: const Timeout(Duration(seconds: 60)));

  test('server restart: A reconnects, B replays the gap through sync', () async {
    final a = await pairAdmin();
    final proxy = await TcpProxy.start(server.port);
    proxies.add(proxy);
    final offer = await a.link.createPairing(role: DeviceRole.member);
    final b = await pair(withPort(offer.uri, proxy.port), 'Device B');

    final slot = await loginFakeAccount(a);
    await a.link.setDeviceAcl(b.link.manifest.value!.deviceId, [slot]);
    final sa = await openAccount(a, slot);
    final sb = await openAccount(b, slot) as RealAccountSession;
    final friendB = sb.messages(friend, user);
    final otherA = sa.messages(other, user);
    final otherB = sb.messages(other, user);

    await sa.sendText(friend, user, 'before restart');
    await waitFor(() => friendB.value.length == 1, what: 'first message on B');
    final seqBefore = sb.lastSeq;
    expect(seqBefore, greaterThan(0));

    proxy.disable();
    await server.stop();
    await waitFor(() => sa.state.value != LinkState.connected, what: 'A account link down');
    await waitFor(() => a.link.state.value != LinkState.connected, what: 'A control link down');
    await waitFor(() => sb.state.value != LinkState.connected, what: 'B account link down');

    // Sent while the server is down: goes out once the link is back.
    final queued = sa.sendText(other, user, 'gap 1');
    expect(otherA.value.single.sendState, SendState.sending);

    await server.start();
    await queued;
    await waitFor(() => sa.state.value == LinkState.connected, what: 'A account link back');
    await waitFor(() => a.link.state.value == LinkState.connected, what: 'A control link back');
    expect(otherA.value.single.sendState, SendState.sent);
    await Future<void>.delayed(const Duration(milliseconds: 5));
    await sa.sendText(other, user, 'gap 2');
    expect(otherA.value.map((m) => m.text), ['gap 1', 'gap 2']);

    expect(sb.state.value, isNot(LinkState.connected));
    expect(otherB.value, isEmpty);
    expect(sb.lastSeq, seqBefore);

    proxy.enable();
    await waitFor(() => sb.state.value == LinkState.connected, timeout: const Duration(seconds: 45), what: 'B back');
    await waitFor(() => otherB.value.length == 2, what: 'gap messages on B');
    expect(otherB.value.map((m) => m.text), ['gap 1', 'gap 2']);
    expect(otherB.value.every((m) => m.sendState == SendState.sent), isTrue);
    expect(sb.lastSeq, greaterThan(seqBefore));
    expect(sb.threads.value.first.id, other);
    expect(sb.threads.value.first.lastMessage!.text, 'gap 2');
    await waitFor(() => b.link.state.value == LinkState.connected, what: 'B control link back');
  }, timeout: const Timeout(Duration(seconds: 120)));

  test('a failed send is marked failed and resend delivers it in place', () async {
    final a = await pairAdmin();
    final offer = await a.link.createPairing(role: DeviceRole.member);
    final b = await pair(offer.uri, 'Device B');
    final slot = await loginFakeAccount(a);
    await a.link.setDeviceAcl(b.link.manifest.value!.deviceId, [slot]);
    final sa = await openAccount(a, slot);
    final sb = await openAccount(b, slot);
    final list = sa.messages(friend, user);
    final listB = sb.messages(friend, user);
    await sa.sendText(friend, user, 'first');
    await waitFor(() => listB.value.length == 1, what: 'first on B');

    await server.stop();
    await waitFor(() => sa.state.value != LinkState.connected, what: 'link down');
    await Future.wait([sa.sendText(friend, user, 'lost'), sa.sendText(friend, user, 'dropped')]);
    expect(list.value.map((m) => m.sendState), [SendState.sent, SendState.failed, SendState.failed]);
    final failed = list.value[1];
    await sa.deleteForMe(list.value[2]);
    expect(list.value, hasLength(2));

    await server.start();
    await waitFor(() => sa.state.value == LinkState.connected, timeout: const Duration(seconds: 45), what: 'link back');
    final resending = sa.resend(failed);
    expect(list.value.map((m) => m.sendState), [SendState.sent, SendState.sending]);
    expect(list.value[1].id, failed.id);
    await resending;
    expect(list.value.map((m) => m.text), ['first', 'lost']);
    expect(list.value.map((m) => m.sendState), [SendState.sent, SendState.sent]);
    expect(list.value[1].cliId, failed.cliId);
    expect(list.value[1].id, isNot(failed.id));

    await waitFor(() => listB.value.length == 2, timeout: const Duration(seconds: 45), what: 'resent on B');
    await sa.resend(failed);
    await sa.resend(list.value[0]);
    await Future<void>.delayed(const Duration(milliseconds: 300));
    expect(list.value, hasLength(2));
    expect(listB.value.map((m) => m.text), ['first', 'lost']);
  }, timeout: const Timeout(Duration(seconds: 120)));

  test('sendFile uploads a payload over 200 KB as a blob stream', () async {
    final a = await pairAdmin();
    final offer = await a.link.createPairing(role: DeviceRole.member);
    final b = await pair(offer.uri, 'Device B');
    final slot = await loginFakeAccount(a);
    await a.link.setDeviceAcl(b.link.manifest.value!.deviceId, [slot]);
    final sa = await openAccount(a, slot);
    final sb = await openAccount(b, slot);
    final listA = sa.messages(friend, user);
    final listB = sb.messages(friend, user);

    final payload = patternBytes(250 * 1024 + 123);
    final sending = sa.sendFile(
      friend,
      user,
      OutgoingFile(name: 'report.bin', bytes: payload, kind: MessageKind.file),
      caption: 'the report',
    );
    expect(listA.value.single.sendState, SendState.sending);
    expect(listA.value.single.attachments.single.size, payload.length);
    final localUrl = listA.value.single.attachments.single.url;
    await sending;

    // The selfListen echo merges a fetchable url into the record; both
    // devices see it through message.updated.
    await waitFor(() => listA.value.single.attachments.single.url != localUrl, what: 'echo url on A');
    await waitFor(() => listB.value.isNotEmpty && listB.value.single.attachments.single.url.isNotEmpty,
        what: 'file message on B');
    expect(listA.value, hasLength(1));
    final mine = listA.value.single;
    expect(mine.sendState, SendState.sent);
    expect(mine.kind, MessageKind.file);
    expect(mine.text, 'the report');
    expect(mine.attachments.single.name, 'report.bin');
    expect(mine.attachments.single.size, payload.length);
    final echoUrl = mine.attachments.single.url;
    expect(echoUrl, startsWith('fake://media/'));
    expect(await sa.media(echoUrl), payload);

    final theirs = listB.value.single;
    expect(theirs.id, mine.id);
    expect(theirs.attachments.single.size, payload.length);
    expect(theirs.attachments.single.name, 'report.bin');
    expect(theirs.attachments.single.url, echoUrl);
    expect(await sb.media(echoUrl), payload);
  });

  test('sendFile carries ttl and urgency into the server record', () async {
    final a = await pairAdmin();
    final slot = await loginFakeAccount(a);
    final sa = await openAccount(a, slot);
    final list = sa.messages(friend, user);

    await sa.sendFile(
      friend,
      user,
      OutgoingFile(name: 'photo.jpg', bytes: Uint8List.fromList(const [1, 2, 3]), kind: MessageKind.image),
      caption: 'cap',
      urgency: MessageUrgency.urgent,
      ttl: 60000,
    );
    await waitFor(() => list.value.isNotEmpty && list.value.last.expiresAt != null, what: 'media expiry echo');
    final message = list.value.last;
    expect(message.kind, MessageKind.image);
    expect(message.text, 'cap');
    expect(message.urgency, MessageUrgency.urgent);
    expect(message.ttl, 60000);
    expect(message.expiresAt, greaterThan(message.ts));
  });

  test('a rejected send keeps the server code on the failed message', () async {
    final a = await pairAdmin();
    final slot = await loginFakeAccount(a);
    final sa = await openAccount(a, slot);
    final list = sa.messages(friend, user);

    await sa.sendFile(
      friend,
      user,
      OutgoingFile(name: 'clip.aac', bytes: Uint8List.fromList(const [1]), kind: MessageKind.voice),
      urgency: MessageUrgency.urgent,
    );
    expect(list.value.single.sendState, SendState.failed);
    expect(list.value.single.sendErrorCode, 'not_supported');
  });

  test('media returns bytes, caches them, and shares in-flight fetches', () async {
    final a = await pairAdmin();
    final slot = await loginFakeAccount(a);
    final sa = await openAccount(a, slot);
    const url = 'https://example.com/photo.jpg';

    final both = await Future.wait([sa.media(url), sa.media(url)]);
    expect(utf8.decode(both[0]), 'fake media bytes for $url');
    expect(identical(both[0], both[1]), isTrue);

    // What travelled was sealed: the raw blob is header + ciphertext + tag.
    final raw = await rawChannel(a, slot: slot);
    final fetched = await raw.request('media.fetch', {'url': url}) as Map<String, dynamic>;
    expect(fetched['sealed'], isTrue);
    expect(fetched['size'], both[0].length);
    final blob = await raw.receiveBlob(fetched['stream'] as int);
    expect(blob.length, 32 + both[0].length + 16);
    expect(utf8.decode(blob, allowMalformed: true), isNot(contains('fake media')));
    raw.close();

    await server.stop();
    final cached = await sa.media(url);
    expect(identical(cached, both[0]), isTrue);
  });

  test('sealed media fetch over multiple chunks round-trips', () async {
    final a = await pairAdmin();
    final slot = await loginFakeAccount(a);
    final sa = await openAccount(a, slot);
    const n = 2500000;
    const url = 'https://cdn.example.com/big.bin?size=$n';
    final bytes = await sa.media(url);
    // Fake payload is i % 251, sealed in three 1 MiB chunks.
    expect(bytes.length, n);
    expect(bytes[0], 0);
    expect(bytes[251], 0);
    expect(bytes[n - 1], (n - 1) % 251);
  });

  test('a revoked device ends unauthorized', () async {
    final a = await pairAdmin();
    final offer = await a.link.createPairing(role: DeviceRole.member);
    final b = await pair(offer.uri, 'Device B');
    final slot = await loginFakeAccount(a);
    await a.link.setDeviceAcl(b.link.manifest.value!.deviceId, [slot]);
    final sb = await openAccount(b, slot);

    final listed = await a.link.listDevices();
    expect(listed.map((d) => d.name), containsAll(['Device A', 'Device B']));
    final target = listed.firstWhere((d) => d.name == 'Device B');
    expect(target.role, DeviceRole.member);
    expect(target.slots, [slot]);
    expect(target.id, b.link.manifest.value!.deviceId);

    await expectLater(b.link.listDevices(), throwsA(anything));

    await a.link.setDeviceAcl(target.id, []);
    await waitFor(() => b.link.manifest.value!.accounts.isEmpty, what: 'acl applied');
    await a.link.setDeviceAcl(target.id, [slot]);
    await waitFor(() => b.link.manifest.value!.accounts.length == 1, what: 'acl restored');

    await a.link.revokeDevice(target.id);
    await waitFor(() => b.link.state.value == LinkState.unauthorized, what: 'B control unauthorized');
    await waitFor(() => sb.state.value == LinkState.unauthorized, what: 'B account unauthorized');
    await Future<void>.delayed(const Duration(seconds: 2));
    expect(b.link.state.value, LinkState.unauthorized);
    expect((await a.link.listDevices()).map((d) => d.name), ['Device A']);

    await a.link.removeAccount(slot);
    await waitFor(() => a.link.manifest.value!.accounts.isEmpty, what: 'account removed');
  });

  group('vault', () {
    Future<Device> pairFromCli(String name) async => pair(await server.pairUri(), name);

    Future<List<Map<String, dynamic>>> rawMessages(Device device, String slot, String threadId) async {
      final raw = await rawChannel(device, slot: slot);
      try {
        final result = await raw.request('messages.list', {'threadId': threadId, 'threadType': 'user'});
        return ((result as Map<String, dynamic>)['messages'] as List).cast<Map<String, dynamic>>();
      } finally {
        raw.close();
      }
    }

    test('first device claims the vault, sets account keys, and opens sealed records', () async {
      final a = await pairAdmin();
      expect(a.app.vault.value, VaultState.ready);
      expect(a.app.boxFingerprint, matches(RegExp(r'^([0-9a-f]{4} ){7}[0-9a-f]{4}$')));
      final stored = (await Credentials.load(a.keyStore))!;
      expect(stored.vaultRoot, hasLength(32));

      final slot = await loginFakeAccount(a);
      final control = await rawChannel(a);
      final manifest = await control.request('manifest.get') as Map<String, dynamic>;
      control.close();
      final account = (manifest['accounts'] as List).single as Map<String, dynamic>;
      expect(account['vaultKey'], VaultController(stored, MemoryKeyStore()).publicKeyFor(slot));

      final sa = await openAccount(a, slot);
      final list = sa.messages(friend, user);
      await sa.sendText(friend, user, 'top secret');
      await server.incoming(slot, friend, 'psst');
      await waitFor(() => list.value.length == 2, what: 'both messages');
      expect(list.value.map((m) => m.text), ['top secret', 'psst']);
      expect(list.value.last.senderName, 'Friend One');
      await waitFor(() => sa.threads.value.isNotEmpty && sa.threads.value.single.lastMessage?.text == 'psst',
          what: 'opened last message');

      final records = await rawMessages(a, slot, friend);
      expect(records, hasLength(2));
      for (final record in records) {
        expect(record['sealed'], isA<String>());
        expect(record.containsKey('body'), isFalse);
        expect(record.containsKey('text'), isFalse);
        expect(jsonEncode(record), isNot(contains('secret')));
      }

      // Restored from storage: still ready, opens history without any claim.
      final restored = await RealZalosApp.open(a.keyStore);
      final again = Device(restored, a.keyStore);
      devices.add(again);
      expect(restored.vault.value, VaultState.ready);
      await again.connected();
      final history = (await openAccount(again, slot)).messages(friend, user);
      await waitFor(() => history.value.length == 2, what: 'history after restore');
      expect(history.value.map((m) => m.text), ['top secret', 'psst']);
    });

    test('a device paired from a uri carrying the root reads history', () async {
      final a = await pairAdmin();
      final slot = await loginFakeAccount(a);
      final sa = await openAccount(a, slot);
      for (final text in ['one', 'two', 'three']) {
        await sa.sendText(friend, user, text);
        await Future<void>.delayed(const Duration(milliseconds: 3));
      }

      final offer = await a.link.createPairing(role: DeviceRole.member);
      final b = await pair(offer.uri, 'Device B');
      expect(b.app.vault.value, VaultState.ready);
      expect((await Credentials.load(b.keyStore))!.vaultRoot, (await Credentials.load(a.keyStore))!.vaultRoot);
      expect(a.link.vaultRequests.value, isEmpty);

      final b0 = b.link.manifest.value!.deviceId;
      await a.link.setDeviceAcl(b0, [slot]);
      final sb = await openAccount(b, slot);
      final list = sb.messages(friend, user);
      await waitFor(() => list.value.length == 3, what: 'history on B');
      expect(list.value.map((m) => m.text), ['one', 'two', 'three']);
      await waitFor(() => sb.threads.value.isNotEmpty, what: 'threads on B');
      expect(sb.threads.value.single.lastMessage!.text, 'three');
    });

    test('a device paired without the root waits for approval, then opens what it had locked', () async {
      final a = await pairAdmin();
      final slot = await loginFakeAccount(a);
      final sa = await openAccount(a, slot);
      for (final text in ['one', 'two']) {
        await sa.sendText(friend, user, text);
        await Future<void>.delayed(const Duration(milliseconds: 3));
      }

      final b = await pairFromCli('Device B');
      await a.link.setDeviceAcl(b.link.manifest.value!.deviceId, [slot]);
      await waitFor(() => b.link.manifest.value!.accounts.any((x) => x.slot == slot), what: 'account on B before vault request');
      await b.app.requestVaultApproval();
      expect(b.app.vault.value, VaultState.needsApproval);
      expect(b.app.boxFingerprint, isNotEmpty);
      expect(b.app.boxFingerprint, isNot(a.app.boxFingerprint));
      await expectLater(b.app.exportRecoveryCode(), throwsA(isA<VaultNotReadyException>()));

      await waitFor(() => a.link.vaultRequests.value.isNotEmpty, what: 'request on A');
      final request = a.link.vaultRequests.value.single;
      expect(request.name, 'Device B');
      expect(request.deviceId, b.link.manifest.value!.deviceId);
      expect(request.fingerprint, b.app.boxFingerprint);
      expect(request.requestedAt, greaterThan(0));
      expect(b.link.vaultRequests.value, isEmpty);

      await a.link.setDeviceAcl(request.deviceId, [slot]);
      final sb = await openAccount(b, slot);
      final list = sb.messages(friend, user);
      await waitFor(() => list.value.length == 2, what: 'locked history on B');
      await waitFor(() => sb.threads.value.isNotEmpty, what: 'threads on B');
      await sa.sendText(friend, user, 'three');
      await waitFor(() => list.value.length == 3, what: 'live locked message on B');
      await waitFor(() => sb.threads.value.single.lastMessage?.id == list.value.last.id, what: 'thread update on B');
      expect(list.value.map((m) => m.text), [null, null, null]);
      expect(list.value.map((m) => m.kind), everyElement(MessageKind.text));
      expect(list.value.every((m) => m.isSelf && m.id.isNotEmpty && m.ts > 0), isTrue);
      expect(sb.threads.value.single.lastMessage!.text, isNull);
      await expectLater(sb.media('https://example.com/locked.jpg'), throwsA(isA<VaultNotReadyException>()));
      expect(b.app.vault.value, VaultState.needsApproval);

      await expectLater(
        a.link.approveVaultRequest(VaultRequest(
          deviceId: request.deviceId,
          name: request.name,
          fingerprint: 'aaaa bbbb cccc dddd eeee ffff 0000 1111',
          requestedAt: request.requestedAt,
        )),
        throwsStateError,
      );

      await a.link.approveVaultRequest(request);
      await waitFor(() => b.app.vault.value == VaultState.ready, what: 'B ready');
      await waitFor(() => list.value.every((m) => m.text != null), what: 'reopened messages');
      expect(list.value.map((m) => m.text), ['one', 'two', 'three']);
      expect(sb.threads.value.single.lastMessage!.text, 'three');
      expect(utf8.decode(await sb.media('https://example.com/locked.jpg')), contains('fake media bytes'));
      await waitFor(() => a.link.vaultRequests.value.isEmpty, what: 'request cleared');
      expect((await Credentials.load(b.keyStore))!.vaultRoot, (await Credentials.load(a.keyStore))!.vaultRoot);
      expect(await b.app.exportRecoveryCode(), await a.app.exportRecoveryCode());
    });

    test('a grant that arrives while the device is offline is fetched on the next connect', () async {
      final a = await pairAdmin();
      final proxy = await TcpProxy.start(server.port);
      proxies.add(proxy);
      final b = await pair(withPort(await server.pairUri(), proxy.port), 'Device B');
      expect(b.app.vault.value, VaultState.needsApproval);
      await waitFor(() => a.link.vaultRequests.value.isNotEmpty, what: 'request on A');

      proxy.disable();
      await waitFor(() => b.link.state.value != LinkState.connected, what: 'B offline');
      await a.link.approveVaultRequest(a.link.vaultRequests.value.single);
      expect(b.app.vault.value, VaultState.needsApproval);
      proxy.enable();
      await waitFor(() => b.app.vault.value == VaultState.ready, timeout: const Duration(seconds: 45), what: 'B ready');
    }, timeout: const Timeout(Duration(seconds: 90)));

    test('a rejected request notifies the device, which can resend', () async {
      final a = await pairAdmin();
      final slot = await loginFakeAccount(a);
      await openAccount(a, slot);

      final b = await pairFromCli('Device B');
      expect(b.app.vault.value, VaultState.needsApproval);
      await waitFor(() => a.link.vaultRequests.value.isNotEmpty, what: 'request on A');
      final request = a.link.vaultRequests.value.single;
      expect(b.link.vaultRejected.value, isFalse);

      await a.link.rejectVaultRequest(request);
      await waitFor(() => b.link.vaultRejected.value, what: 'rejected on B');
      expect(a.link.vaultRequests.value, isEmpty);
      expect(b.app.vault.value, VaultState.needsApproval);

      await b.app.requestVaultApproval();
      await waitFor(() => a.link.vaultRequests.value.isNotEmpty, what: 'request again on A');
      expect(b.link.vaultRejected.value, isFalse);

      await a.link.approveVaultRequest(a.link.vaultRequests.value.single);
      await waitFor(() => b.app.vault.value == VaultState.ready, what: 'B ready after approval');
      expect(b.link.vaultRejected.value, isFalse);
    });

    test('recovery code export and import', () async {
      final a = await pairAdmin();
      final slot = await loginFakeAccount(a);
      final sa = await openAccount(a, slot);
      await sa.sendText(friend, user, 'kept safe');

      final code = await a.app.exportRecoveryCode();
      expect(code, matches(RegExp(r'^([A-Z2-7]{4}-){12}[A-Z2-7]{4}$')));
      expect(decodeRecoveryCode(code), (await Credentials.load(a.keyStore))!.vaultRoot);

      final c = await pairFromCli('Device C');
      expect(c.app.vault.value, VaultState.needsApproval);
      await a.link.setDeviceAcl(c.link.manifest.value!.deviceId, [slot]);
      final sc = await openAccount(c, slot);
      final list = sc.messages(friend, user);
      await waitFor(() => list.value.length == 1, what: 'locked message on C');
      expect(list.value.single.text, isNull);

      await expectLater(c.app.importRecoveryCode('not a code'), throwsFormatException);
      await expectLater(c.app.importRecoveryCode(code.substring(0, code.length - 5)), throwsFormatException);
      final foreign = encodeRecoveryCode(List.generate(32, (i) => i));
      await expectLater(c.app.importRecoveryCode(foreign), throwsFormatException);
      expect(c.app.vault.value, VaultState.needsApproval);

      await c.app.importRecoveryCode(code.toLowerCase().replaceAll('-', ' '));
      expect(c.app.vault.value, VaultState.ready);
      await waitFor(() => list.value.single.text == 'kept safe', what: 'reopened on C');
      expect((await Credentials.load(c.keyStore))!.vaultRoot, (await Credentials.load(a.keyStore))!.vaultRoot);
      expect(await c.app.exportRecoveryCode(), code);

      await c.app.unpair();
      expect(c.app.vault.value, VaultState.needsApproval);
      expect(c.app.boxFingerprint, '');
    });

    test('the claimed root is persisted before the claim resolves', () async {
      final a = await pairAdmin();
      // pair() only resolves after the vault work settled; the root must
      // already be on disk, and it is the same root pairing uris carry.
      final stored = (await Credentials.load(a.keyStore))!.vaultRoot;
      expect(stored, isNotNull);
      final offer = await a.link.createPairing(role: DeviceRole.member);
      final encoded = base64Url.encode(stored!).replaceAll('=', '');
      expect(offer.uri, contains('vault=$encoded'));
    });

    test('a mismatched pairing-uri root is discarded, falls back to approval', () async {
      final a = await pairAdmin();
      final slot = await loginFakeAccount(a);
      final sa = await openAccount(a, slot);
      await sa.sendText(friend, user, 'hidden');

      final wrong = List<int>.generate(32, (i) => i ^ 0xa5);
      final b = await pair(withVaultRoot(await server.pairUri(), wrong), 'Device B');
      await a.link.setDeviceAcl(b.link.manifest.value!.deviceId, [slot]);
      await waitFor(() => b.link.manifest.value!.accounts.any((x) => x.slot == slot), what: 'account on B');
      await b.app.requestVaultApproval();
      // The wrong root must not stick: discarded, approval requested.
      await (a.link as RealServerLink).refreshVaultRequests();
      expect(a.link.vaultRequests.value, isNotEmpty);
      expect(b.app.vault.value, VaultState.needsApproval);
      expect((await Credentials.load(b.keyStore))!.vaultRoot, isNull);

      await a.link.approveVaultRequest(a.link.vaultRequests.value.single);
      await waitFor(() => b.app.vault.value == VaultState.ready, what: 'B ready after grant');
      expect((await Credentials.load(b.keyStore))!.vaultRoot, (await Credentials.load(a.keyStore))!.vaultRoot);
    });

    test('a vault.setKey conflict discards the root instead of staying ready', () async {
      // A claims the vault and keys slot1. A's upload for any later slot is
      // blocked through the debug seam so slot2 stays unkeyed until B - who
      // pairs with the real root - loses the setKey race on it.
      final a = await pairAdmin();
      final slot1 = await loginFakeAccount(a);
      await openAccount(a, slot1);

      // D logs in a second account that nothing keys: D has no vault
      // root, but loginQr needs an admin so it pairs with the admin role.
      final d = await pair(await server.pairUri(role: 'admin'), 'Device D');
      final others = {a.link, d.link};
      final foreignRoot = List<int>.generate(32, (i) => i * 3 + 7);
      RealServerLink.debugBeforeSetKey = (link, slot) async {
        if (slot == slot1) return;
        if (!others.contains(link)) {
          // B: a foreign key lands inside its setKey window.
          await flipServerVaultKey(
            slot,
            rust.derivePublicKey(root: Uint8List.fromList(foreignRoot), slot: slot),
          );
          return;
        }
        throw StateError('blocked so the slot stays unkeyed');
      };
      try {
        final events = await d.link.startLoginQr().toList().timeout(const Duration(seconds: 15));
        final slot2 = events.whereType<LoginQrDone>().single.slot;

        // B pairs with the real root; its manifest shows slot1 keyed and
        // slot2 unkeyed. Inside B's setKey window a foreign key lands.
        final rootA = (await Credentials.load(a.keyStore))!.vaultRoot;
        final b = await pair(withVaultRoot(await server.pairUri(), rootA!), 'Device B');
        await a.link.setDeviceAcl(b.link.manifest.value!.deviceId, [slot1, slot2]);
        await waitFor(() => b.link.manifest.value!.accounts.length == 2, what: 'accounts on B');
        await b.app.requestVaultApproval();
        await waitFor(() => b.app.vault.value == VaultState.needsApproval, what: 'B falls back to approval');
        await b.app.requestVaultApproval();
        await (a.link as RealServerLink).refreshVaultRequests();
        expect(a.link.vaultRequests.value, isNotEmpty);
        expect((await Credentials.load(b.keyStore))!.vaultRoot, isNull);
      } finally {
        RealServerLink.debugBeforeSetKey = null;
      }
    });
  });

  test('an incoming message updates unread and thread order on every device', () async {
    final a = await pairAdmin();
    final offer = await a.link.createPairing(role: DeviceRole.member);
    final b = await pair(offer.uri, 'Device B');
    final slot = await loginFakeAccount(a);
    await a.link.setDeviceAcl(b.link.manifest.value!.deviceId, [slot]);
    final sa = await openAccount(a, slot);
    final sb = await openAccount(b, slot);
    final list = sa.messages(other, user);

    await sa.sendText(friend, user, 'mine');
    await waitFor(() => sb.threads.value.length == 1, what: 'first thread');
    await Future<void>.delayed(const Duration(milliseconds: 5));

    await server.incoming(slot, other, 'hi there');
    await waitFor(() => sa.threads.value.length == 2 && sb.threads.value.length == 2, what: 'incoming thread');
    for (final session in [sa, sb]) {
      expect(session.threads.value.map((t) => t.id), [other, friend]);
      expect(session.threads.value.first.unread, 1);
      expect(session.threads.value.first.lastMessage!.text, 'hi there');
      expect(session.threads.value.first.lastMessage!.isSelf, isFalse);
      expect(session.threads.value.last.unread, 0);
    }
    await waitFor(() => list.value.length == 1, what: 'incoming in open list');
    expect(list.value.single.text, 'hi there');
    expect(list.value.single.isSelf, isFalse);
    expect(list.value.single.cliId, isNull);
    await waitFor(() => a.link.manifest.value!.accounts.single.unread == 1, what: 'manifest unread');

    await Future<void>.delayed(const Duration(milliseconds: 5));
    await server.incoming(slot, friend, 'me too');
    await server.incoming(slot, friend, 'and again');
    await waitFor(() => sb.threads.value.first.id == friend && sb.threads.value.first.unread == 2, what: 'reorder on B');
    await waitFor(() => sa.threads.value.first.unread == 2, what: 'unread on A');
    expect(sa.threads.value.map((t) => t.id), [friend, other]);
    expect(sa.threads.value.map((t) => t.unread), [2, 1]);

    await sb.markSeen(friend, user);
    expect(sb.threads.value.first.unread, 0);
    await waitFor(() => sa.threads.value.first.unread == 0, what: 'seen propagated to A');
    expect(sa.threads.value.map((t) => t.unread), [0, 1]);
    await waitFor(() => a.link.manifest.value!.accounts.single.unread == 1, what: 'manifest unread after seen');
  });

  test('a gap of more than 500 events is replayed across sync pages', () async {
    final a = await pairAdmin();
    final proxy = await TcpProxy.start(server.port);
    proxies.add(proxy);
    final offer = await a.link.createPairing(role: DeviceRole.member);
    final b = await pair(withPort(offer.uri, proxy.port), 'Device B');
    final slot = await loginFakeAccount(a);
    await a.link.setDeviceAcl(b.link.manifest.value!.deviceId, [slot]);
    final sa = await openAccount(a, slot);
    final sb = await openAccount(b, slot) as RealAccountSession;
    final listB = sb.messages(friend, user);

    await sa.sendText(friend, user, 'm0');
    await waitFor(() => listB.value.length == 1, what: 'first message on B');
    final seqBefore = sb.lastSeq;

    proxy.disable();
    await waitFor(() => sb.state.value != LinkState.connected, what: 'B offline');
    const count = 300;
    for (var i = 1; i <= count; i++) {
      await sa.sendText(friend, user, 'm$i');
    }
    final seqOnA = (sa as RealAccountSession).lastSeq;
    expect(seqOnA - seqBefore, greaterThan(500));

    proxy.enable();
    await waitFor(() => sb.state.value == LinkState.connected, timeout: const Duration(seconds: 45), what: 'B back');
    await waitFor(() => listB.value.length == count + 1, what: 'all gap messages on B');
    expect(sb.lastSeq, seqOnA);
    expect(listB.value.map((m) => m.text), [for (var i = 0; i <= count; i++) 'm$i']);
    expect(sb.threads.value.single.lastMessage!.text, 'm$count');

    // A fresh session starts from zero and pages through the whole log.
    final restored = await RealZalosApp.open(a.keyStore);
    final again = Device(restored, a.keyStore);
    devices.add(again);
    await again.connected();
    final fresh = await openAccount(again, slot) as RealAccountSession;
    expect(fresh.lastSeq, seqOnA);
    await waitFor(() => fresh.threads.value.isNotEmpty, what: 'threads on fresh session');
    expect(fresh.threads.value.single.lastMessage!.text, 'm$count');
  }, timeout: const Timeout(Duration(seconds: 120)));

  test('a storage write failure during pairing surfaces as PairingException', () async {
    final store = _FailingKeyStore();
    final app = await RealZalosApp.open(store);
    devices.add(Device(app, store));
    await expectLater(
      app.pair(await server.pairUri(), deviceName: 'Broke'),
      throwsA(isA<PairingException>().having((e) => e.code, 'code', PairingErrorCode.storage)),
    );
    expect(store.values[Credentials.storageKey], isNull);
  });

  test('pairing with a server that is not listening is unreachable with host:port', () async {
    final port = await freePort();
    final app = await RealZalosApp.open(MemoryKeyStore());
    await expectLater(
      app.pair(withPort(await server.pairUri(), port), deviceName: 'Lost'),
      throwsA(isA<PairingException>()
          .having((e) => e.code, 'code', PairingErrorCode.unreachable)
          .having((e) => e.detail, 'detail', endsWith(':$port'))),
    );
  });

  test('load states go loading to ready, an empty page is ready, reloads are single flight', () async {
    final a = await pairAdmin();
    final slot = await loginFakeAccount(a);
    final session = a.link.account(slot);
    expect(session.threadsLoad.value, LoadState.loading);
    await waitFor(() => session.threadsLoad.value == LoadState.ready, what: 'threads ready');
    expect(session.threads.value, isEmpty);

    // messagesLoad first, then messages: one shared latest page load.
    final load = session.messagesLoad(friend, user);
    expect(load.value, LoadState.loading);
    final list = session.messages(friend, user);
    final first = session.reloadMessages(friend, user);
    expect(identical(first, session.reloadMessages(friend, user)), isTrue);
    await first;
    expect(load.value, LoadState.ready);
    expect(list.value, isEmpty);
    expect(identical(load, session.messagesLoad(friend, user)), isTrue);

    final reload = session.reloadThreads();
    expect(identical(reload, session.reloadThreads()), isTrue);
    expect(session.threadsLoad.value, LoadState.loading);
    await reload;
    expect(session.threadsLoad.value, LoadState.ready);

    final refresh = session.reloadMessages(friend, user);
    expect(identical(refresh, session.reloadMessages(friend, user)), isTrue);
    expect(load.value, LoadState.ready);
    await refresh;
    expect(load.value, LoadState.ready);
  }, timeout: const Timeout(Duration(seconds: 60)));

  test('load states fail while offline, refetch on reconnect and recover on reload', () async {
    final a = await pairAdmin();
    final proxy = await TcpProxy.start(server.port);
    proxies.add(proxy);
    final offer = await a.link.createPairing(role: DeviceRole.member);
    final b = await pair(withPort(offer.uri, proxy.port), 'Device B');
    final slot = await loginFakeAccount(a);
    await a.link.setDeviceAcl(b.link.manifest.value!.deviceId, [slot]);
    final sa = await openAccount(a, slot);
    await sa.sendText(friend, user, 'hello');
    await waitFor(() => b.link.manifest.value!.accounts.any((x) => x.slot == slot), what: 'account on B');

    proxy.disable();
    final sb = b.link.account(slot);
    await waitFor(() => sb.threadsLoad.value == LoadState.failed, what: 'threads failed');
    final friendLoad = sb.messagesLoad(friend, user);
    expect(friendLoad.value, LoadState.loading);
    await waitFor(() => friendLoad.value == LoadState.failed, timeout: const Duration(seconds: 30), what: 'page failed');

    // Reconnecting refetches both without a reload call.
    final threadStates = <LoadState>[];
    void track() => threadStates.add(sb.threadsLoad.value);
    sb.threadsLoad.addListener(track);
    proxy.enable();
    await waitFor(() => sb.threadsLoad.value == LoadState.ready, timeout: const Duration(seconds: 45), what: 'threads back');
    sb.threadsLoad.removeListener(track);
    expect(threadStates, [LoadState.loading, LoadState.ready]);
    expect(sb.threads.value.single.id, friend);
    await waitFor(() => friendLoad.value == LoadState.ready, what: 'page back');
    expect(sb.messages(friend, user).value.single.text, 'hello');

    // A reload while offline fails, the next one recovers.
    proxy.disable();
    await waitFor(() => sb.state.value != LinkState.connected, what: 'B offline');
    final otherLoad = sb.messagesLoad(other, user);
    final failing = sb.reloadThreads();
    expect(sb.threadsLoad.value, LoadState.loading);
    await Future.wait([failing, sb.reloadMessages(other, user)]);
    expect(sb.threadsLoad.value, LoadState.failed);
    expect(otherLoad.value, LoadState.failed);

    proxy.enable();
    unawaited(sb.reloadThreads());
    expect(sb.threadsLoad.value, LoadState.loading);
    unawaited(sb.reloadMessages(other, user));
    expect(otherLoad.value, LoadState.loading);
    // The reconnect sync may answer first if the backoff outlasts the reload.
    await waitFor(
      () => sb.threadsLoad.value == LoadState.ready && otherLoad.value == LoadState.ready,
      timeout: const Duration(seconds: 45),
      what: 'reloaded',
    );
  }, timeout: const Timeout(Duration(seconds: 180)));

  test('a pruned event log triggers a sync reset that rebuilds threads', () async {
    final a = await pairAdmin();
    final slot = await loginFakeAccount(a);
    final sa = await openAccount(a, slot);
    await sa.sendText(friend, user, 'before restart');
    await waitFor(() => sa.threads.value.isNotEmpty, what: 'thread');

    await server.stop();
    final prune = await Process.run('bun', ['-e', '''
      import { Database } from "bun:sqlite";
      const db = new Database("${server.dataDir.path}/zalos.db");
      db.run("DELETE FROM events");
      db.close();
    ''']);
    expect(prune.exitCode, 0, reason: '${prune.stdout}${prune.stderr}');
    await server.start();
    await server.incoming(slot, friend, 'after restart');

    // The client's lastSeq is now below the log's oldest seq: sync must
    // reset and rebuild the thread list rather than applying a partial tail.
    // Wait for an actual reconnection cycle, not a stale "connected".
    await waitFor(() => sa.state.value != LinkState.connected, what: 'drop noticed');
    await waitFor(() => sa.state.value == LinkState.connected, timeout: const Duration(seconds: 60), what: 'reconnect');
    final list = sa.messages(friend, user);
    await waitFor(
      () => list.value.any((m) => m.text == 'after restart'),
      timeout: const Duration(seconds: 30),
      what: 'reset replay',
    );
    await waitFor(() => sa.threads.value.isNotEmpty, what: 'threads rebuilt');
  }, timeout: const Timeout(Duration(seconds: 90)));
  test('thread pin, mute, markUnread and delete converge', () async {
    final device = await pairAdmin();
    final slot = await loginFakeAccount(device);
    final sa = await openAccount(device, slot);

    await sa.sendText(friend, user, 'pin me');
    await waitFor(() => sa.threads.value.any((t) => t.id == friend), what: 'thread');

    await sa.setPinned(friend, user, true);
    await waitFor(() => sa.threads.value.single.pinned, what: 'pinned');
    await sa.setMuted(friend, user, true);
    await waitFor(() => sa.threads.value.single.muted, what: 'muted');
    await sa.markUnread(friend, user);
    await waitFor(() => sa.threads.value.single.unread >= 1, what: 'unread mark');

    await sa.setPinned(friend, user, false);
    await waitFor(() => !sa.threads.value.single.pinned, what: 'unpinned');
    await sa.setMuted(friend, user, false);
    await waitFor(() => !sa.threads.value.single.muted, what: 'unmuted');

    await sa.deleteThread(friend, user);
    await waitFor(() => sa.threads.value.isEmpty, what: 'thread deleted');
  });

  test('forward copies the text to the destination thread', () async {
    final device = await pairAdmin();
    final slot = await loginFakeAccount(device);
    final sa = await openAccount(device, slot);

    await sa.sendText(friend, user, 'forward me');
    final list = sa.messages(friend, user);
    await waitFor(() => list.value.any((m) => m.text == 'forward me'), what: 'sent');
    final msg = list.value.firstWhere((m) => m.text == 'forward me');

    await sa.forward(msg, [const ThreadRef(other, user)]);
    final dst = sa.messages(other, user);
    await waitFor(
      () => dst.value.any((m) => m.text == 'forward me'),
      what: 'forwarded copy',
    );
  });

  test('fullAvatar returns the full size url through users.avatar', () async {
    final device = await pairAdmin();
    final slot = await loginFakeAccount(device);
    final sa = await openAccount(device, slot);

    expect(await sa.fullAvatar(friend), 'https://example.com/full/$friend.jpg');
    // A second ask is served from the server profile cache with the same url.
    expect(await sa.fullAvatar(friend), 'https://example.com/full/$friend.jpg');
  });

  test('users resolves profiles; delivery state folds into own messages', () async {
    final device = await pairAdmin();
    final slot = await loginFakeAccount(device);
    final sa = await openAccount(device, slot);

    final users = await sa.users([friend]);
    expect(users.single.uid, friend);
    expect(users.single.displayName, isNotEmpty);

    await sa.sendText(friend, user, 'deliver me');
    final list = sa.messages(friend, user);
    await waitFor(() => list.value.any((m) => m.text == 'deliver me'), what: 'sent');
    final msg = list.value.firstWhere((m) => m.text == 'deliver me');

    await server.emit(slot, {
      'event': 'receipt',
      'threadId': friend,
      'kind': 'delivered',
      'threadType': 'user',
      'msgId': msg.id,
      'userIds': [friend],
    });
    await waitFor(
      () => list.value.firstWhere((m) => m.id == msg.id).deliveryState == DeliveryState.delivered,
      what: 'delivered',
    );
    await server.emit(slot, {
      'event': 'receipt',
      'threadId': friend,
      'kind': 'seen',
      'threadType': 'user',
      'msgId': msg.id,
      'userIds': [friend],
    });
    await waitFor(
      () => list.value.firstWhere((m) => m.id == msg.id).deliveryState == DeliveryState.seen,
      what: 'seen',
    );
  });

  test('OA account: manifest kind and capabilities, token updates', () async {
    final admin = await pairAdmin('Admin OA');
    final slot = await admin.link.addOaAccount(
      const OaCredentials(
        appId: 'oa-app-1',
        appSecret: 'oa-secret-1',
        accessToken: 'oa-at-1',
        refreshToken: 'oa-rt-1',
      ),
    );
    await waitFor(
      () => admin.link.manifest.value!.accounts.any((a) => a.slot == slot),
      what: 'oa account in manifest',
    );
    final account = admin.link.manifest.value!.accounts.firstWhere((a) => a.slot == slot);
    expect(account.kind, AccountKind.oa);
    expect(account.capabilities, isEmpty);
    await admin.link.updateOaTokens(slot, accessToken: 'oa-at-2', refreshToken: 'oa-rt-2');
    final session = await openAccount(admin, slot);
    // Baseline messaging still works through the fake OA gateway.
    await session.sendText(friend, user, 'xin chao');
  });

}

class _FailingKeyStore extends MemoryKeyStore {
  @override
  Future<void> write(String key, String value) => throw StateError('disk full');
}
