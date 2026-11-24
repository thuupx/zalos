import 'dart:async';
import 'dart:convert';
import 'dart:typed_data';

import 'package:web_socket_channel/web_socket_channel.dart';

import '../../noise/noise.dart';
import 'frame_codec.dart';
import 'ws_connect.dart';

// 4001 = unauthorized (revoked or bad credentials), 4002 = protocol error
// (recoverable; reconnect), 4004 = slot or pairing gone, 1013 = the server
// is shedding backpressure (reconnect and resync).
const int closeAuth = 4001;
const int closeProtocol = 4002;
const int closeNotFound = 4004;
const int closeTryAgain = 1013;

class RpcException implements Exception {
  const RpcException(this.code, this.message);
  final String code;
  final String message;
  @override
  String toString() => 'RpcException($code): $message';
}

class ChannelException implements Exception {
  const ChannelException(this.message, {this.closeCode, this.unreachable = false});
  final String message;
  final int? closeCode;

  /// True when the socket never opened.
  final bool unreachable;
  @override
  String toString() => 'ChannelException: $message${closeCode == null ? '' : ' (close code $closeCode)'}';
}

class ChannelEvent {
  const ChannelEvent(this.name, this.seq, this.data);
  final String name;
  final int? seq;
  final Map<String, dynamic> data;
}

/// One WebSocket carrying one Noise session, with framing and JSON RPC.
class NoiseChannel {
  NoiseChannel._(this._ws, this._session, this._onEvent);

  static const Duration defaultRequestTimeout = Duration(seconds: 30);
  // Burst loads (e.g. opening a 30-cell sticker grid) stream blobs ahead of
  // their RPC JSON responses; keep enough headroom while bounding total bytes.
  static const int _maxUnclaimedBlobs = 128;
  static const int _maxUnclaimedBytes = 32 * 1024 * 1024;

  final WebSocketChannel _ws;
  final Session _session;
  final void Function(ChannelEvent event)? _onEvent;

  // Server replies (a full sync, long lists) are not bound by the 1 MiB limit
  // the server applies to inbound JSON.
  final FrameAssembler _assembler = FrameAssembler(maxJson: 64 * 1024 * 1024, maxTotalBufferedBytes: 128 * 1024 * 1024);
  final Map<int, Completer<dynamic>> _pending = {};
  final Map<int, Uint8List> _blobs = {};
  int _unclaimedBytes = 0;
  final Map<int, Completer<Uint8List>> _blobWaiters = {};
  final Completer<void> _handshake = Completer<void>();
  final Completer<int?> _done = Completer<int?>();
  Future<void> _rx = Future<void>.value();
  Future<void> _tx = Future<void>.value();
  bool _handshakeFinished = false;
  bool _closed = false;
  int _nextId = 1;
  int _nextStream = 1;
  int? _closeCode;

  bool get isClosed => _closed;
  int? get closeCode => _closeCode;

  /// Completes with the WebSocket close code once the channel is gone.
  Future<int?> get done => _done.future;

  static Future<NoiseChannel> connect({
    required Uri uri,
    required String prologue,
    required List<int> localPrivate,
    required List<int> remotePublic,
    required List<int> psk,
    void Function(ChannelEvent event)? onEvent,
    Duration timeout = const Duration(seconds: 10),
  }) async {
    final Session session;
    try {
      session = await Session.initiator(
        prologue: utf8.encode(prologue),
        localPrivate: localPrivate,
        remotePublic: remotePublic,
        psk: psk,
      );
    } catch (e) {
      throw ChannelException('invalid key material: $e');
    }
    final ws = connectWebSocket(uri);
    try {
      await ws.ready.timeout(timeout);
    } catch (e) {
      unawaited(ws.sink.close().catchError((_) {}));
      throw ChannelException('could not connect: $e', unreachable: true);
    }
    final channel = NoiseChannel._(ws, session, onEvent);
    channel._listen();
    try {
      final first = await session.writeHandshake(payload: Uint8List(0));
      ws.sink.add(first);
      await channel._handshake.future.timeout(timeout);
    } on TimeoutException {
      channel.close();
      throw const ChannelException('handshake timed out');
    } catch (e) {
      channel.close();
      if (e is ChannelException) rethrow;
      throw ChannelException('handshake failed: $e');
    }
    return channel;
  }

  void _listen() {
    _ws.stream.listen(
      (data) {
        if (data is! List<int>) return;
        final bytes = data is Uint8List ? data : Uint8List.fromList(data);
        _rx = _rx.then((_) => _handle(bytes));
      },
      onError: (Object _) => _rx = _rx.then((_) => _finish()),
      onDone: () => _rx = _rx.then((_) => _finish()),
      cancelOnError: true,
    );
  }

  Future<void> _handle(Uint8List bytes) async {
    if (_closed) return;
    try {
      if (!_handshakeFinished) {
        await _session.readHandshake(message: bytes);
        _handshakeFinished = true;
        _handshake.complete();
        return;
      }
      final plain = await _session.decrypt(ciphertext: bytes);
      final message = _assembler.feed(plain);
      if (message == null) return;
      if (message.type == typeBlob) {
        _deliverBlob(message.stream, message.data);
      } else {
        _deliverJson(message.data);
      }
    } catch (e) {
      _fail(ChannelException('protocol error: $e'));
    }
  }

  void _deliverBlob(int stream, Uint8List data) {
    final waiter = _blobWaiters.remove(stream);
    if (waiter != null) {
      waiter.complete(data);
      return;
    }
    final prev = _blobs.remove(stream);
    if (prev != null) _unclaimedBytes -= prev.length;
    _blobs[stream] = data;
    _unclaimedBytes += data.length;
    while (_blobs.length > _maxUnclaimedBlobs || (_unclaimedBytes > _maxUnclaimedBytes && _blobs.length > 1)) {
      final oldestKey = _blobs.keys.first;
      final removed = _blobs.remove(oldestKey);
      if (removed != null) _unclaimedBytes -= removed.length;
    }
  }

  void _deliverJson(Uint8List data) {
    final decoded = jsonDecode(utf8.decode(data));
    if (decoded is! Map<String, dynamic>) return;
    final id = decoded['id'];
    if (id is int) {
      final completer = _pending.remove(id);
      if (completer == null) return;
      final error = decoded['error'];
      if (error is Map) {
        completer.completeError(
          RpcException('${error['code'] ?? 'error'}', '${error['message'] ?? ''}'),
          StackTrace.current,
        );
      } else {
        completer.complete(decoded['result']);
      }
      return;
    }
    final name = decoded['event'];
    if (name is! String) return;
    final seq = decoded['seq'];
    final payload = decoded['data'];
    _onEvent?.call(ChannelEvent(
      name,
      seq is num ? seq.toInt() : null,
      payload is Map<String, dynamic> ? payload : const {},
    ));
  }

  void _enqueue(Uint8List frame) {
    _tx = _tx.then((_) async {
      if (_closed) return;
      try {
        final sealed = await _session.encrypt(plaintext: frame);
        if (_closed) return;
        _ws.sink.add(sealed);
      } catch (e) {
        _fail(ChannelException('send failed: $e'));
      }
    });
  }

  void _ensureOpen() {
    if (_closed) throw ChannelException('channel closed', closeCode: _closeCode);
  }

  /// Sends a request and completes with its `result`. Throws [RpcException]
  /// for an error response and [ChannelException] on timeout or close.
  Future<dynamic> request(
    String method, [
    Map<String, dynamic> params = const {},
    Duration? timeout = defaultRequestTimeout,
  ]) {
    _ensureOpen();
    final id = _nextId++;
    final stream = _nextStream++;
    final completer = Completer<dynamic>();
    _pending[id] = completer;
    final body = utf8.encode(jsonEncode({'id': id, 'method': method, 'params': params}));
    for (final frame in encodeMessage(typeJson, stream, body)) {
      _enqueue(frame);
    }
    if (timeout == null) return completer.future;
    return completer.future.timeout(timeout, onTimeout: () {
      _pending.remove(id);
      throw ChannelException('request $method timed out');
    });
  }

  /// Queues [data] as a blob stream and returns its stream id.
  int sendBlob(Uint8List data) {
    _ensureOpen();
    final stream = _nextStream++;
    for (final frame in encodeMessage(typeBlob, stream, data)) {
      _enqueue(frame);
    }
    return stream;
  }

  /// Completes with the bytes of an inbound blob stream, whether it already
  /// arrived or is still in flight.
  Future<Uint8List> receiveBlob(int stream, {Duration timeout = const Duration(seconds: 60)}) {
    final ready = _blobs.remove(stream);
    if (ready != null) {
      _unclaimedBytes -= ready.length;
      return Future.value(ready);
    }
    _ensureOpen();
    final completer = _blobWaiters.putIfAbsent(stream, () => Completer<Uint8List>());
    return completer.future.timeout(timeout, onTimeout: () {
      _blobWaiters.remove(stream);
      throw const ChannelException('blob timed out');
    });
  }

  void close() => _fail(const ChannelException('channel closed'), closeSocket: true);

  void _finish() {
    _closeCode ??= _ws.closeCode;
    _fail(ChannelException('connection closed', closeCode: _closeCode), closeSocket: false);
  }

  void _fail(ChannelException error, {bool closeSocket = true}) {
    if (_closed) return;
    _closed = true;
    if (closeSocket) {
      unawaited(_ws.sink.close().catchError((_) {}));
    }
    final stack = StackTrace.current;
    if (!_handshake.isCompleted) {
      _handshake.future.ignore();
      _handshake.completeError(error, stack);
    }
    for (final completer in _pending.values) {
      completer.future.ignore();
      completer.completeError(error, stack);
    }
    _pending.clear();
    for (final completer in _blobWaiters.values) {
      completer.future.ignore();
      completer.completeError(error, stack);
    }
    _blobWaiters.clear();
    _blobs.clear();
    _assembler.clear();
    _done.complete(_closeCode);
  }
}
