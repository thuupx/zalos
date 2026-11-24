import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:zalos/src/data/protocol/frame_codec.dart';

Uint8List bytes(int length, [int seed = 0]) =>
    Uint8List.fromList(List.generate(length, (i) => (i + seed) & 0xff));

void main() {
  test('frame layout is type, flags, big endian stream, chunk', () {
    final frame = encodeFrame(typeBlob, flagFin, 0x01020304, Uint8List.fromList([9, 8]));
    expect(frame, [2, 1, 1, 2, 3, 4, 9, 8]);
  });

  test('empty message is a single FIN frame', () {
    final frames = encodeMessage(typeJson, 7, Uint8List(0)).toList();
    expect(frames, hasLength(1));
    expect(frames.single, [1, 1, 0, 0, 0, 7]);
    final message = FrameAssembler().feed(frames.single)!;
    expect(message.type, typeJson);
    expect(message.stream, 7);
    expect(message.data, isEmpty);
  });

  test('splits at 60000 bytes and sets FIN only on the last frame', () {
    final data = bytes(frameChunk * 2 + 5);
    final frames = encodeMessage(typeBlob, 3, data).toList();
    expect(frames.map((f) => f.length), [frameChunk + 6, frameChunk + 6, 11]);
    expect(frames.map((f) => f[1]), [0, 0, flagFin]);

    final exact = encodeMessage(typeBlob, 3, bytes(frameChunk)).toList();
    expect(exact, hasLength(1));
    expect(exact.single[1], flagFin);
  });

  test('reassembles a split message', () {
    final data = bytes(150001, 3);
    final assembler = FrameAssembler();
    InboundMessage? out;
    for (final frame in encodeMessage(typeBlob, 42, data)) {
      expect(out, isNull);
      out = assembler.feed(frame);
    }
    expect(out!.stream, 42);
    expect(out.type, typeBlob);
    expect(out.data, data);
    expect(assembler.openStreams, 0);
  });

  test('reassembles interleaved streams independently', () {
    final a = bytes(130000, 1);
    final b = bytes(70000, 2);
    final c = Uint8List.fromList('{"id":1}'.codeUnits);
    final framesA = encodeMessage(typeBlob, 1, a).toList();
    final framesB = encodeMessage(typeBlob, 2, b).toList();
    final framesC = encodeMessage(typeJson, 3, c).toList();
    final order = [framesA[0], framesB[0], framesC[0], framesA[1], framesB[1], framesA[2]];

    final assembler = FrameAssembler();
    final done = <int, InboundMessage>{};
    for (final frame in order) {
      final message = assembler.feed(frame);
      if (message != null) done[message.stream] = message;
    }
    expect(done.keys, [3, 2, 1]);
    expect(done[1]!.data, a);
    expect(done[2]!.data, b);
    expect(done[3]!.data, c);
    expect(done[3]!.type, typeJson);
  });

  test('a stream id can be reused after FIN', () {
    final assembler = FrameAssembler();
    expect(assembler.feed(encodeFrame(typeJson, flagFin, 5, bytes(3)))!.data, bytes(3));
    expect(assembler.feed(encodeFrame(typeBlob, flagFin, 5, bytes(4)))!.type, typeBlob);
  });

  test('rejects malformed frames', () {
    final assembler = FrameAssembler();
    expect(() => assembler.feed(Uint8List(5)), throwsA(isA<FrameException>()));
    expect(() => assembler.feed(encodeFrame(9, 0, 1, bytes(1))), throwsA(isA<FrameException>()));
    expect(() => assembler.feed(encodeFrame(typeBlob, 0, 1, bytes(frameChunk + 1))), throwsA(isA<FrameException>()));
    assembler.feed(encodeFrame(typeJson, 0, 8, bytes(1)));
    expect(() => assembler.feed(encodeFrame(typeBlob, 0, 8, bytes(1))), throwsA(isA<FrameException>()));
  });

  test('enforces the size limit', () {
    final assembler = FrameAssembler(maxJson: 100);
    assembler.feed(encodeFrame(typeJson, 0, 1, bytes(60)));
    expect(() => assembler.feed(encodeFrame(typeJson, 0, 1, bytes(60))), throwsA(isA<FrameException>()));
  });

  test('enforces maxOpenStreams and maxTotalBufferedBytes', () {
    final byStreams = FrameAssembler(maxOpenStreams: 2);
    byStreams.feed(encodeFrame(typeBlob, 0, 1, bytes(10)));
    byStreams.feed(encodeFrame(typeBlob, 0, 2, bytes(10)));
    expect(() => byStreams.feed(encodeFrame(typeBlob, 0, 3, bytes(10))), throwsA(isA<FrameException>()));

    final byBytes = FrameAssembler(maxTotalBufferedBytes: 100);
    byBytes.feed(encodeFrame(typeBlob, 0, 1, bytes(60)));
    expect(() => byBytes.feed(encodeFrame(typeBlob, 0, 2, bytes(50))), throwsA(isA<FrameException>()));
  });
}
