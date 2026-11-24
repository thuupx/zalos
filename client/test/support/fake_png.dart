import 'dart:math' as math;
import 'dart:typed_data';

/// Dependency-free PNG encoder (stored deflate blocks) for test media.
Uint8List fakePng(String seed, {int width = 64, int height = 64}) {
  var h = 7;
  for (final c in seed.codeUnits) {
    h = (h * 31 + c) & 0x3fffffff;
  }
  final r0 = 80 + h % 120, g0 = 60 + (h ~/ 7) % 120, b0 = 60 + (h ~/ 49) % 120;
  final stride = width * 4 + 1;
  final raw = Uint8List(stride * height);
  for (var y = 0; y < height; y++) {
    final t = y / math.max(1, height - 1);
    for (var x = 0; x < width; x++) {
      final i = y * stride + 1 + x * 4;
      final sun = (x - width * 0.3) * (x - width * 0.3) + (y - height * 0.35) * (y - height * 0.35) < width * height * 0.012;
      raw[i] = sun ? 250 : (r0 + (40 * t)).round().clamp(0, 255);
      raw[i + 1] = sun ? 232 : (g0 + (60 * t)).round().clamp(0, 255);
      raw[i + 2] = sun ? 190 : (b0 - (30 * t)).round().clamp(0, 255);
      raw[i + 3] = 255;
    }
  }
  final out = BytesBuilder();
  out.add(const [0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A, 0x1A, 0x0A]);
  final ihdr = ByteData(13)
    ..setUint32(0, width)
    ..setUint32(4, height)
    ..setUint8(8, 8)
    ..setUint8(9, 6);
  _chunk(out, 'IHDR', ihdr.buffer.asUint8List());
  final z = BytesBuilder()..add(const [0x78, 0x01]);
  var offset = 0;
  while (offset < raw.length) {
    final n = math.min(65535, raw.length - offset);
    final last = offset + n >= raw.length;
    z.add([last ? 1 : 0, n & 0xff, n >> 8, ~n & 0xff, (~n >> 8) & 0xff]);
    z.add(Uint8List.sublistView(raw, offset, offset + n));
    offset += n;
  }
  var a = 1, b = 0;
  for (final byte in raw) {
    a = (a + byte) % 65521;
    b = (b + a) % 65521;
  }
  z.add((ByteData(4)..setUint32(0, (b << 16) | a)).buffer.asUint8List());
  _chunk(out, 'IDAT', z.toBytes());
  _chunk(out, 'IEND', Uint8List(0));
  return out.toBytes();
}

final List<int> _crcTable = List<int>.generate(256, (n) {
  var c = n;
  for (var k = 0; k < 8; k++) {
    c = (c & 1) != 0 ? 0xEDB88320 ^ (c >> 1) : c >> 1;
  }
  return c;
});

void _chunk(BytesBuilder out, String type, Uint8List data) {
  final head = Uint8List(4 + data.length)
    ..setRange(0, 4, type.codeUnits)
    ..setRange(4, 4 + data.length, data);
  var crc = 0xFFFFFFFF;
  for (final byte in head) {
    crc = _crcTable[(crc ^ byte) & 0xff] ^ (crc >> 8);
  }
  crc ^= 0xFFFFFFFF;
  out.add((ByteData(4)..setUint32(0, data.length)).buffer.asUint8List());
  out.add(head);
  out.add((ByteData(4)..setUint32(0, crc)).buffer.asUint8List());
}
