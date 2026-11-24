import 'dart:convert';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:zalos/src/data/key_store.dart';
import 'package:zalos/src/data/mapping.dart';
import 'package:zalos/src/data/vault.dart';
import 'package:zalos/src/domain/models.dart';
import 'package:zalos/src/rust_lib/api/vault.dart' as rust;

import 'support.dart';

const slot = 'slot1';

Future<Uint8List> sealMedia(List<int> root, String url, Uint8List plain, {int? claimedSize}) async {
  final aad = utf8.encode('zalos/1/media/$slot/${rust.sha256Hex(data: utf8.encode(url))}/${claimedSize ?? plain.length}');
  final sealer = await rust.FileSealer.create(publicKey: rust.derivePublicKey(root: root, slot: slot), aad: aad);
  final out = BytesBuilder()..add(await sealer.header());
  const chunk = 1024 * 1024;
  for (var offset = 0; offset < plain.length; offset += chunk) {
    final end = offset + chunk < plain.length ? offset + chunk : plain.length;
    out.add(await sealer.sealChunk(chunk: Uint8List.sublistView(plain, offset, end)));
  }
  return out.takeBytes();
}

VaultController controller({Uint8List? root, String deviceId = 'dev1', rust.BoxKeypair? box}) {
  final keys = box ?? rust.boxKeypair();
  return VaultController(
    Credentials(
      host: 'h',
      port: 1,
      serverPublicKey: Uint8List(32),
      devicePrivateKey: Uint8List(32),
      devicePublicKey: Uint8List(32),
      devicePsk: Uint8List(32),
      deviceId: deviceId,
      boxPrivateKey: keys.private,
      boxPublicKey: keys.public,
      vaultRoot: root,
    ),
    MemoryKeyStore(),
  );
}

void main() {
  setUpAll(initRust);

  test('sha256 hex matches the known vector', () {
    expect(
      rust.sha256Hex(data: utf8.encode('abc')),
      'ba7816bf8f01cfea414140de5dae2223b00361a396177a9cb410ff61f20015ad',
    );
  });

  group('recovery code', () {
    test('round trips and is grouped base32', () {
      final root = rust.generateRoot();
      final code = encodeRecoveryCode(root);
      expect(code, matches(RegExp(r'^([A-Z2-7]{4}-){12}[A-Z2-7]{4}$')));
      expect(decodeRecoveryCode(code), root);
      expect(decodeRecoveryCode(' ${code.toLowerCase().replaceAll('-', ' ')} '), root);
      expect(decodeRecoveryCode(encodeRecoveryCode(Uint8List(32))), Uint8List(32));
      expect(decodeRecoveryCode(encodeRecoveryCode(Uint8List(32)..fillRange(0, 32, 255))), List.filled(32, 255));
    });

    test('rejects malformed codes', () {
      final code = encodeRecoveryCode(rust.generateRoot());
      for (final bad in ['', 'hello', code.substring(5), '$code-AAAA', code.replaceRange(0, 1, '1'), '${code.substring(0, code.length - 1)}B']) {
        expect(() => decodeRecoveryCode(bad), throwsFormatException, reason: bad);
      }
    });
  });

  group('sealed media', () {
    const url = 'https://cdn.example/big.bin';

    test('opens a multi chunk file over 1 MiB', () async {
      final root = rust.generateRoot();
      final plain = patternBytes(2 * 1024 * 1024 + 777);
      final blob = await sealMedia(root, url, plain);
      expect(blob.length, 32 + plain.length + 3 * 16);
      final opened = await openSealedMedia(root: root, slot: slot, url: url, size: plain.length, blob: blob);
      expect(opened, plain);
    });

    test('opens an exact 1 MiB file and an empty file', () async {
      final root = rust.generateRoot();
      final exact = patternBytes(1024 * 1024);
      expect(
        await openSealedMedia(root: root, slot: slot, url: url, size: exact.length, blob: await sealMedia(root, url, exact)),
        exact,
      );
      final empty = Uint8List(0);
      expect(
        await openSealedMedia(root: root, slot: slot, url: url, size: 0, blob: await sealMedia(root, url, empty)),
        isEmpty,
      );
    });

    test('rejects a wrong root, url, size, tampering and truncation', () async {
      final root = rust.generateRoot();
      final plain = patternBytes(1024 * 1024 + 5000);
      final blob = await sealMedia(root, url, plain);
      Future<Uint8List> open({List<int>? withRoot, String? withUrl, int? size, Uint8List? data}) => openSealedMedia(
            root: withRoot ?? root,
            slot: slot,
            url: withUrl ?? url,
            size: size ?? plain.length,
            blob: data ?? blob,
          );
      final failure = throwsA(isA<VaultOpenException>());
      await expectLater(open(withRoot: rust.generateRoot()), failure);
      await expectLater(open(withUrl: '$url?x'), failure);
      await expectLater(open(size: plain.length + 1), failure);
      final tampered = Uint8List.fromList(blob)..[blob.length - 20] ^= 1;
      await expectLater(open(data: tampered), failure);
      // Dropping the whole last chunk is only caught by the size check.
      final truncated = Uint8List.sublistView(blob, 0, 32 + 1024 * 1024 + 16);
      await expectLater(open(data: truncated), failure);
      await expectLater(open(data: Uint8List(10)), failure);
    });
  });

  group('records', () {
    Map<String, dynamic> record(String id, {String? sealed, Map<String, dynamic>? body, bool recalled = false}) => {
          'id': id,
          'cliId': null,
          'threadId': 't1',
          'threadType': 'user',
          'senderId': 'u1',
          'ts': 10,
          'isSelf': false,
          'kind': 'image',
          'reactions': {
            '/-heart': ['u2'],
          },
          'recalled': recalled,
          if (sealed != null) 'sealed': sealed,
          if (body != null) 'body': body,
        };

    String sealBody(List<int> root, String id, Map<String, dynamic> body) => base64Encode(rust.seal(
          publicKey: rust.derivePublicKey(root: root, slot: slot),
          aad: utf8.encode('zalos/1/msg/$slot/$id'),
          plaintext: utf8.encode(jsonEncode(body)),
        ));

    const body = {
      'senderName': 'An',
      'text': 'xin chao',
      'attachments': [
        {'kind': 'image', 'url': 'https://x/a.jpg'},
      ],
      'raw': {'msgId': 'm1', 'content': 'xin chao'},
    };

    test('plaintext body', () {
      final message = messageFromJson(record('m1', body: body));
      expect(message.senderName, 'An');
      expect(message.text, 'xin chao');
      expect(message.attachments.single.url, 'https://x/a.jpg');
      expect(message.raw, {'msgId': 'm1', 'content': 'xin chao'});
      expect(message.reactions['/-heart'], ['u2']);
    });

    test('sealed body opens with the root', () {
      final vault = controller(root: rust.generateRoot());
      final sealed = sealBody(vault.root.value!, 'm1', body);
      var locked = 0;
      final message = messageFromJson(
        record('m1', sealed: sealed),
        open: (id, data) => vault.openRecord(slot, id, data),
        onLocked: (_) => locked++,
      );
      expect(locked, 0);
      expect(message.text, 'xin chao');
      expect(message.senderName, 'An');
      expect(message.kind, MessageKind.image);
      expect(message.raw, isNotNull);
    });

    test('sealed body without a root, with a wrong root or wrong id stays locked', () {
      final root = rust.generateRoot();
      final sealed = sealBody(root, 'm1', body);
      for (final vault in [controller(), controller(root: rust.generateRoot())]) {
        final lockedRecords = <Map<String, dynamic>>[];
        final message = messageFromJson(
          record('m1', sealed: sealed),
          open: (id, data) => vault.openRecord(slot, id, data),
          onLocked: lockedRecords.add,
        );
        expect(lockedRecords.single['sealed'], sealed);
        expect(message.id, 'm1');
        expect(message.kind, MessageKind.image);
        expect(message.text, isNull);
        expect(message.senderName, '');
        expect(message.attachments, isEmpty);
        expect(message.raw, isNull);
        expect(message.reactions['/-heart'], ['u2']);
      }
      final right = controller(root: root);
      expect(right.openRecord(slot, 'm2', sealed), isNull);
      expect(right.openRecord(slot, 'm1', 'not base64 !!'), isNull);
      expect(messageFromJson(record('m1', sealed: sealed)).text, isNull);
    });

    test('recalled record has no content', () {
      var locked = 0;
      final message = messageFromJson(record('m1', recalled: true), onLocked: (_) => locked++);
      expect(message.recalled, isTrue);
      expect(message.text, isNull);
      expect(message.attachments, isEmpty);
      expect(locked, 0);
    });

    test('quote maps the normalized shape', () {
      final full = messageFromJson(record('m1', body: {
        'quote': {'msgId': 'q', 'senderId': 's', 'senderName': 'N', 'text': 'T'},
      }));
      expect(full.quote!.msgId, 'q');
      expect(full.quote!.senderId, 's');
      expect(full.quote!.senderName, 'N');
      expect(full.quote!.text, 'T');
      expect(
        messageFromJson(record('m1', body: {'quote': {'raw': {}}})).quote,
        isNull,
      );
    });
  });

  test('root wrapping is bound to the receiving device', () async {
    final owner = controller(root: rust.generateRoot());
    final box = rust.boxKeypair();
    final receiver = controller(deviceId: 'dev2', box: box);
    final wrapped = owner.wrapRootFor('dev2', box.public);
    expect(receiver.unwrapRoot(wrapped), owner.root.value);
    expect(controller(deviceId: 'dev3', box: box).unwrapRoot(wrapped), isNull);
    expect(controller(deviceId: 'dev2').unwrapRoot(wrapped), isNull);
    expect(receiver.unwrapRoot('AAAA'), isNull);
    expect(() => receiver.wrapRootFor('x', box.public), throwsA(isA<VaultNotReadyException>()));

    expect(receiver.isReady, isFalse);
    await receiver.setRoot(owner.root.value!);
    expect(receiver.isReady, isTrue);
    expect(receiver.credentials.vaultRoot, owner.root.value);
    expect(receiver.publicKeyFor(slot), owner.publicKeyFor(slot));
    expect(receiver.boxFingerprint, rust.fingerprint(publicKey: box.public));
    expect(receiver.boxFingerprint, matches(RegExp(r'^([0-9a-f]{4} ){7}[0-9a-f]{4}$')));
  });
}
