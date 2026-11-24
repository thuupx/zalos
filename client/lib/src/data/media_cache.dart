import 'dart:collection';
import 'dart:typed_data';

/// Byte-bounded LRU. Entries larger than the whole budget are not kept.
class MediaCache {
  MediaCache({this.maxBytes = 64 * 1024 * 1024});

  final int maxBytes;
  final LinkedHashMap<String, Uint8List> _entries = LinkedHashMap();
  int _bytes = 0;

  int get bytes => _bytes;
  int get length => _entries.length;

  Uint8List? get(String key) {
    final hit = _entries.remove(key);
    if (hit != null) _entries[key] = hit;
    return hit;
  }

  void put(String key, Uint8List data) {
    final previous = _entries.remove(key);
    if (previous != null) _bytes -= previous.length;
    if (data.length > maxBytes) return;
    _entries[key] = data;
    _bytes += data.length;
    while (_bytes > maxBytes && _entries.isNotEmpty) {
      final oldest = _entries.keys.first;
      _bytes -= _entries.remove(oldest)!.length;
    }
  }

  void clear() {
    _entries.clear();
    _bytes = 0;
  }
}
