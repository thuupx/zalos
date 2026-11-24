import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../domain/models.dart';
import '../../domain/services.dart';
import '../components/avatar.dart';
import '../platform/services.dart';

/// Plays one voice message at a time.
class VoiceDeck extends ChangeNotifier {
  VoiceDeck(this._platform);

  final PlatformServices _platform;
  PlaybackHandle? _handle;
  String? _currentKey;
  bool _loading = false;
  bool _failed = false;
  int _generation = 0;
  bool _disposed = false;

  String? get currentKey => _currentKey;
  bool get loading => _loading;
  bool get failed => _failed;
  PlaybackStatus get status => _handle?.status.value ?? const PlaybackStatus();

  void _changed() {
    if (!_disposed) notifyListeners();
  }

  Future<void> toggle(String key, AccountSession session, Attachment attachment) async {
    final handle = _handle;
    if (_currentKey == key && handle != null && !_failed) {
      if (status.completed) {
        await handle.seek(Duration.zero);
        await handle.play();
      } else if (status.playing) {
        await handle.pause();
      } else {
        await handle.play();
      }
      return;
    }
    stop();
    final generation = ++_generation;
    _currentKey = key;
    _loading = true;
    _failed = false;
    _changed();
    try {
      final bytes = await loadMedia(session, attachment.url);
      final uri = await _platform.materialize(attachment.name ?? 'voice.m4a', bytes);
      if (generation != _generation || _disposed) return;
      final next = _platform.createPlayer();
      next.status.addListener(_changed);
      _handle = next;
      await next.open(uri);
    } catch (_) {
      if (generation != _generation) return;
      _failed = true;
    } finally {
      if (generation == _generation) {
        _loading = false;
        _changed();
      }
    }
  }

  Future<void> seek(String key, Duration position) async {
    if (_currentKey == key) await _handle?.seek(position);
  }

  void stop() {
    _generation++;
    final handle = _handle;
    _handle = null;
    _currentKey = null;
    _loading = false;
    if (handle != null) {
      handle.status.removeListener(_changed);
      handle.dispose();
    }
    _changed();
  }

  @override
  void dispose() {
    stop();
    _disposed = true;
    super.dispose();
  }
}

final voiceDeckProvider = Provider<VoiceDeck>((ref) {
  final deck = VoiceDeck(ref.watch(platformProvider));
  ref.onDispose(deck.dispose);
  return deck;
});

enum DownloadPhase { idle, loading, done, failed }

@immutable
class DownloadEntry {
  const DownloadEntry(this.phase, [this.path]);
  final DownloadPhase phase;
  final String? path;
}

/// File downloads keyed by media url. Desktop and web save to Downloads and
/// can open the result; phones hand the file to the share sheet.
class Downloads extends ChangeNotifier {
  Downloads(this._platform);

  final PlatformServices _platform;
  final Map<String, DownloadEntry> _entries = {};
  final Map<String, int> _runs = {};
  bool _disposed = false;

  DownloadEntry of(String url) => _entries[url] ?? const DownloadEntry(DownloadPhase.idle);

  void _set(String url, DownloadEntry entry) {
    _entries[url] = entry;
    if (!_disposed) notifyListeners();
  }

  /// Returns true when the file ended up saved or shared.
  Future<bool> fetch(AccountSession session, String url, String name) async {
    if (of(url).phase == DownloadPhase.loading) return false;
    final run = _runs[url] = (_runs[url] ?? 0) + 1;
    bool stale() => _disposed || _runs[url] != run;
    _set(url, const DownloadEntry(DownloadPhase.loading));
    try {
      final bytes = await loadMedia(session, url);
      // media() cannot be aborted, so a cancelled result is dropped here.
      if (stale()) return false;
      final path = await _platform.saveToDownloads(name, bytes);
      if (path == null) {
        await _platform.share(name, bytes);
        _set(url, const DownloadEntry(DownloadPhase.idle));
      } else {
        _set(url, DownloadEntry(DownloadPhase.done, path));
      }
      return true;
    } catch (_) {
      if (stale()) return false;
      _set(url, const DownloadEntry(DownloadPhase.failed));
      return false;
    }
  }

  /// Drops a running download; nothing is saved when it completes.
  void cancel(String url) {
    if (of(url).phase != DownloadPhase.loading) return;
    _runs[url] = (_runs[url] ?? 0) + 1;
    _set(url, const DownloadEntry(DownloadPhase.idle));
  }

  Future<void> open(String url) async {
    final path = of(url).path;
    if (path != null) await _platform.openSaved(path);
  }

  @override
  void dispose() {
    _disposed = true;
    super.dispose();
  }
}

final downloadsProvider = Provider<Downloads>((ref) {
  final d = Downloads(ref.watch(platformProvider));
  ref.onDispose(d.dispose);
  return d;
});
