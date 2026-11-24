import 'dart:typed_data';

const int frameChunk = 60000;
const int frameHeader = 6;
const int typeJson = 1;
const int typeBlob = 2;
const int flagFin = 1;
const int jsonLimit = 1024 * 1024;
const int blobLimit = 100 * 1024 * 1024;

class FrameException implements Exception {
  const FrameException(this.message);
  final String message;
  @override
  String toString() => 'FrameException: $message';
}

Uint8List encodeFrame(int type, int flags, int stream, Uint8List chunk) {
  final out = Uint8List(frameHeader + chunk.length);
  out[0] = type;
  out[1] = flags;
  ByteData.sublistView(out).setUint32(2, stream);
  out.setRange(frameHeader, out.length, chunk);
  return out;
}

Iterable<Uint8List> encodeMessage(int type, int stream, Uint8List data) sync* {
  if (data.isEmpty) {
    yield encodeFrame(type, flagFin, stream, data);
    return;
  }
  for (var off = 0; off < data.length; off += frameChunk) {
    final end = off + frameChunk < data.length ? off + frameChunk : data.length;
    final fin = end == data.length ? flagFin : 0;
    yield encodeFrame(type, fin, stream, Uint8List.sublistView(data, off, end));
  }
}

class InboundMessage {
  const InboundMessage(this.type, this.stream, this.data);
  final int type;
  final int stream;
  final Uint8List data;
}

class _Pending {
  _Pending(this.type);
  final int type;
  final BytesBuilder buffer = BytesBuilder(copy: false);
}

/// Reassembles frames into whole messages. Streams may interleave.
class FrameAssembler {
  FrameAssembler({
    this.maxJson = jsonLimit,
    this.maxBlob = blobLimit,
    this.maxOpenStreams = 32,
    this.maxTotalBufferedBytes = 64 * 1024 * 1024,
  });

  final int maxJson;
  final int maxBlob;
  final int maxOpenStreams;
  final int maxTotalBufferedBytes;
  final Map<int, _Pending> _pending = {};
  int _bufferedBytes = 0;

  int get openStreams => _pending.length;
  int get bufferedBytes => _bufferedBytes;

  InboundMessage? feed(Uint8List frame) {
    if (frame.length < frameHeader) throw const FrameException('short frame');
    final type = frame[0];
    final flags = frame[1];
    final stream = ByteData.sublistView(frame).getUint32(2);
    if (type != typeJson && type != typeBlob) {
      throw FrameException('unknown frame type $type');
    }
    final chunkLength = frame.length - frameHeader;
    if (chunkLength > frameChunk) throw const FrameException('oversized chunk');

    var p = _pending[stream];
    if (p == null) {
      if (_pending.length >= maxOpenStreams) {
        throw const FrameException('too many open streams');
      }
      p = _Pending(type);
      _pending[stream] = p;
    }
    if (p.type != type) throw const FrameException('stream type changed');
    final limit = type == typeJson ? maxJson : maxBlob;
    if (p.buffer.length + chunkLength > limit) {
      throw const FrameException('message limit exceeded');
    }
    if (_bufferedBytes + chunkLength > maxTotalBufferedBytes) {
      throw const FrameException('total buffered bytes exceeded');
    }
    p.buffer.add(Uint8List.sublistView(frame, frameHeader));
    _bufferedBytes += chunkLength;

    if (flags & flagFin == 0) return null;
    _pending.remove(stream);
    final data = p.buffer.takeBytes();
    _bufferedBytes -= data.length;
    return InboundMessage(type, stream, data);
  }

  void clear() {
    _pending.clear();
    _bufferedBytes = 0;
  }
}
