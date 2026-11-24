import 'dart:async';

import 'package:flutter/foundation.dart';

import '../../domain/models.dart';
import 'noise_channel.dart';

class ChannelKeys {
  const ChannelKeys({
    required this.host,
    required this.port,
    required this.serverPublicKey,
    required this.devicePrivateKey,
    required this.devicePsk,
  });
  final String host;
  final int port;
  final List<int> serverPublicKey;
  final List<int> devicePrivateKey;
  final List<int> devicePsk;

  Uri uri(String path) => Uri(scheme: 'ws', host: host, port: port, path: path);
}

/// Keeps a control or account channel connected: reconnects with exponential
/// backoff and stops for good once the server rejects the device.
class ManagedChannel {
  ManagedChannel({
    required this.keys,
    required this.path,
    required this.prologue,
    required this.onConnected,
    required this.onEvent,
    this.onDisconnected,
    this.initialBackoff = const Duration(seconds: 1),
    this.maxBackoff = const Duration(seconds: 30),
    this.connector,
  });

  final ChannelKeys keys;
  final String path;
  final String prologue;

  /// Runs on every fresh connection before the channel is handed to callers.
  /// It must send at least one request, the server only treats the channel as
  /// live after the first transport message.
  final Future<void> Function(NoiseChannel channel) onConnected;
  final void Function(ChannelEvent event) onEvent;
  final void Function()? onDisconnected;

  /// Test hook: replaces [NoiseChannel.connect].
  final Future<NoiseChannel> Function(
    void Function(ChannelEvent event)? onEvent,
  )? connector;
  final Duration initialBackoff;
  final Duration maxBackoff;

  final ValueNotifier<LinkState> state = ValueNotifier(LinkState.disconnected);

  NoiseChannel? _live;
  NoiseChannel? _attempt;
  final List<Completer<NoiseChannel>> _waiters = [];
  Completer<void>? _sleep;
  bool _woken = false;
  bool _probing = false;
  bool _started = false;
  bool _stopped = false;

  bool get isStopped => _stopped;

  void start() {
    if (_started) return;
    _started = true;
    unawaited(_run());
  }

  Future<void> _run() async {
    var delay = initialBackoff;
    while (!_stopped) {
      state.value = LinkState.connecting;
      int? code;
      NoiseChannel? channel;
      try {
        void forward(ChannelEvent event) {
          if (!_stopped) onEvent(event);
        }

        channel = connector == null
            ? await NoiseChannel.connect(
                uri: keys.uri(path),
                prologue: prologue,
                localPrivate: keys.devicePrivateKey,
                remotePublic: keys.serverPublicKey,
                psk: keys.devicePsk,
                onEvent: forward,
              )
            : await connector!(forward);
        _attempt = channel;
        if (_stopped) {
          channel.close();
          return;
        }
        await onConnected(channel);
        if (_stopped) {
          channel.close();
          return;
        }
        if (!channel.isClosed) {
          _live = channel;
          delay = initialBackoff;
          state.value = LinkState.connected;
          for (final waiter in _waiters) {
            waiter.complete(channel);
          }
          _waiters.clear();
        }
        code = await channel.done;
      } on ChannelException catch (e) {
        code = e.closeCode ?? channel?.closeCode;
      } catch (_) {
        code = channel?.closeCode;
      } finally {
        channel?.close();
        final wasLive = _live != null;
        _live = null;
        _attempt = null;
        if (wasLive && !_stopped) onDisconnected?.call();
      }
      if (_stopped) return;
      if (code == closeAuth) {
        _halt(LinkState.unauthorized, 'device is not authorized');
        return;
      }
      if (code == closeNotFound) {
        _halt(LinkState.disconnected, 'channel no longer exists');
        return;
      }
      // 4002 (protocol error) and 1013 (server shedding backpressure) fall
      // through to a reconnect; the sync on connect repairs any gap.
      state.value = LinkState.disconnected;
      final sleep = _sleep = Completer<void>();
      final timer = Timer(delay, () {
        if (!sleep.isCompleted) sleep.complete();
      });
      await sleep.future;
      timer.cancel();
      _sleep = null;
      if (_woken) {
        _woken = false;
        delay = initialBackoff;
      } else {
        delay = delay * 2 > maxBackoff ? maxBackoff : delay * 2;
      }
    }
  }

  /// Wakes the channel immediately after returning from background or on a
  /// background refresh: skips any pending backoff sleep, or runs [probe]
  /// against the live socket so half-open connections dropped by the OS are
  /// replaced right away.
  Future<void> wake({Future<void> Function(NoiseChannel channel)? probe}) async {
    if (_stopped) return;
    if (!_started) {
      start();
      return;
    }
    final sleep = _sleep;
    if (sleep != null && !sleep.isCompleted) {
      _woken = true;
      sleep.complete();
      return;
    }
    final live = _live;
    if (live == null || live.isClosed || probe == null || _probing) return;
    _probing = true;
    try {
      await probe(live).timeout(const Duration(seconds: 4));
    } catch (_) {
      if (identical(_live, live) && !live.isClosed) {
        live.close();
      }
    } finally {
      _probing = false;
    }
  }

  void _halt(LinkState end, String reason) {
    _stopped = true;
    state.value = end;
    _failWaiters(ChannelException(reason));
  }

  void _failWaiters(ChannelException error) {
    for (final waiter in _waiters) {
      waiter.future.ignore();
      waiter.completeError(error, StackTrace.current);
    }
    _waiters.clear();
  }

  Future<NoiseChannel> _ready(Duration timeout) {
    final live = _live;
    if (live != null && !live.isClosed) return Future.value(live);
    if (_stopped) {
      return Future.error(const ChannelException('channel stopped'), StackTrace.current);
    }
    final waiter = Completer<NoiseChannel>();
    _waiters.add(waiter);
    return waiter.future.timeout(timeout, onTimeout: () {
      _waiters.remove(waiter);
      throw const ChannelException('not connected');
    });
  }

  /// Runs [action] against the live connection, waiting up to [connectTimeout]
  /// for one. Requests and blobs inside [action] share that one connection.
  Future<T> use<T>(
    Future<T> Function(NoiseChannel channel) action, {
    Duration connectTimeout = const Duration(seconds: 15),
  }) async {
    final channel = await _ready(connectTimeout);
    return action(channel);
  }

  Future<dynamic> request(
    String method, [
    Map<String, dynamic> params = const {},
    Duration? timeout = NoiseChannel.defaultRequestTimeout,
  ]) =>
      use((channel) => channel.request(method, params, timeout));

  bool get isConnected => _live != null && !_live!.isClosed;

  void dispose({LinkState end = LinkState.disconnected}) {
    if (_stopped) {
      if (end == LinkState.unauthorized) state.value = end;
      return;
    }
    _stopped = true;
    _live?.close();
    _attempt?.close();
    final sleep = _sleep;
    if (sleep != null && !sleep.isCompleted) sleep.complete();
    _failWaiters(const ChannelException('channel stopped'));
    state.value = end;
  }
}
