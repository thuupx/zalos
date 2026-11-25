import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:flutter_webrtc/flutter_webrtc.dart';

import '../../domain/models.dart';
import '../../domain/services.dart';

enum CallMediaState { idle, connecting, connected, failed }

abstract class CallMediaController extends ChangeNotifier {
  RTCVideoRenderer? get localRenderer;
  RTCVideoRenderer? get remoteRenderer;
  bool get hasLocalVideo;
  bool get hasRemoteVideo;
  CallMediaState get state;
  String? get errorMessage;
  bool get muted;
  bool get speakerOn;
  bool get cameraEnabled;

  Future<void> start({required String callId, required CallMediaKind media});
  Future<void> setMuted(bool muted);
  Future<void> setSpeaker(bool speakerOn);
  Future<void> setCameraEnabled(bool enabled);
  Future<void> switchCamera();
  Future<void> stop();
}

typedef CallMediaControllerFactory = CallMediaController Function(AccountSession session);

const List<Map<String, dynamic>> kDefaultIceServers = [
  <String, dynamic>{'urls': 'stun:stun.l.google.com:19302'},
];

List<Map<String, dynamic>> normalizeIceServers(Object? raw) {
  if (raw is! List) return const [];
  final out = <Map<String, dynamic>>[];
  for (final item in raw) {
    if (item is! Map) continue;
    final urls = item['urls'];
    List<String>? normalizedList;
    String? normalizedSingle;
    if (urls is String && urls.trim().isNotEmpty) {
      normalizedSingle = urls.trim();
    } else if (urls is List) {
      final filtered = [
        for (final u in urls)
          if (u is String && u.trim().isNotEmpty) u.trim(),
      ];
      if (filtered.isNotEmpty) normalizedList = filtered;
    }
    if (normalizedSingle == null && normalizedList == null) continue;
    final map = <String, dynamic>{
      'urls': normalizedList ?? normalizedSingle!,
    };
    final username = item['username'];
    final credential = item['credential'];
    if (username is String && username.isNotEmpty) {
      map['username'] = username;
    }
    if (credential is String && credential.isNotEmpty) {
      map['credential'] = credential;
    }
    out.add(map);
  }
  return out;
}

bool _sameIceServers(List<Map<String, dynamic>> a, List<Map<String, dynamic>> b) {
  if (a.length != b.length) return false;
  for (var i = 0; i < a.length; i++) {
    final ma = a[i];
    final mb = b[i];
    if (ma.length != mb.length) return false;
    for (final key in ma.keys) {
      if (!mb.containsKey(key)) return false;
      final va = ma[key];
      final vb = mb[key];
      if (va is List && vb is List) {
        if (!listEquals(va, vb)) return false;
      } else if (va != vb) {
        return false;
      }
    }
  }
  return true;
}

class WebRtcCallMediaController extends CallMediaController {
  WebRtcCallMediaController(
    this._session, {
    Future<RTCPeerConnection> Function(Map<String, dynamic> configuration)? peerConnectionFactory,
    Future<MediaStream> Function(Map<String, dynamic> constraints)? getUserMedia,
    RTCVideoRenderer Function()? rendererFactory,
    Future<void> Function(bool speakerOn)? setSpeakerphoneOn,
  })  : _peerConnectionFactory = peerConnectionFactory ?? createPeerConnection,
        _getUserMedia = getUserMedia ?? navigator.mediaDevices.getUserMedia,
        _rendererFactory = rendererFactory ?? RTCVideoRenderer.new,
        _setSpeakerphoneOn = setSpeakerphoneOn ?? Helper.setSpeakerphoneOn;

  final AccountSession _session;
  final Future<RTCPeerConnection> Function(Map<String, dynamic> configuration) _peerConnectionFactory;
  final Future<MediaStream> Function(Map<String, dynamic> constraints) _getUserMedia;
  final RTCVideoRenderer Function() _rendererFactory;
  final Future<void> Function(bool speakerOn) _setSpeakerphoneOn;

  RTCPeerConnection? _pc;
  MediaStream? _localStream;
  MediaStream? _remoteStream;
  RTCVideoRenderer? _localRenderer;
  RTCVideoRenderer? _remoteRenderer;
  StreamSubscription<Map<String, dynamic>>? _iceSub;
  final List<RTCIceCandidate> _pendingRemoteIce = [];

  String? _callId;
  bool _hasRemoteDescription = false;
  bool _hasLocalVideo = false;
  bool _hasRemoteVideo = false;
  CallMediaState _state = CallMediaState.idle;
  String? _errorMessage;
  bool _muted = false;
  bool _speakerOn = false;
  bool _cameraEnabled = true;
  bool _disposed = false;

  @override
  RTCVideoRenderer? get localRenderer => _localRenderer;
  @override
  RTCVideoRenderer? get remoteRenderer => _remoteRenderer;
  @override
  bool get hasLocalVideo => _hasLocalVideo;
  @override
  bool get hasRemoteVideo => _hasRemoteVideo;
  @override
  CallMediaState get state => _state;
  @override
  String? get errorMessage => _errorMessage;
  @override
  bool get muted => _muted;
  @override
  bool get speakerOn => _speakerOn;
  @override
  bool get cameraEnabled => _cameraEnabled;

  void _notify() {
    if (!_disposed) notifyListeners();
  }

  @override
  Future<void> start({required String callId, required CallMediaKind media}) async {
    if (_disposed) return;
    if (_callId == callId && _state != CallMediaState.idle && _state != CallMediaState.failed) {
      return;
    }
    await stop();
    if (_disposed) return;

    _callId = callId;
    _cameraEnabled = media == CallMediaKind.video;
    _speakerOn = media == CallMediaKind.video;
    _state = CallMediaState.connecting;
    _errorMessage = null;
    _notify();

    try {
      final localRenderer = _rendererFactory();
      final remoteRenderer = _rendererFactory();
      await localRenderer.initialize();
      await remoteRenderer.initialize();
      _localRenderer = localRenderer;
      _remoteRenderer = remoteRenderer;

      final stream = await _getUserMedia(<String, dynamic>{
        'audio': true,
        'video': media == CallMediaKind.video
            ? <String, dynamic>{
                'facingMode': 'user',
                'width': {'ideal': 640},
                'height': {'ideal': 480},
                'frameRate': {'ideal': 24},
              }
            : false,
      });
      if (_disposed || _callId != callId) {
        await _disposeStream(stream);
        return;
      }
      _localStream = stream;
      _hasLocalVideo = stream.getVideoTracks().isNotEmpty;
      if (_hasLocalVideo) {
        _localRenderer?.srcObject = stream;
      }

      for (final track in stream.getAudioTracks()) {
        track.enabled = !_muted;
      }
      for (final track in stream.getVideoTracks()) {
        track.enabled = _cameraEnabled;
      }

      List<Map<String, dynamic>> initialIceServers = kDefaultIceServers;
      try {
        final fetchedIce = normalizeIceServers(await _session.callMediaIceServers());
        if (fetchedIce.isNotEmpty) {
          initialIceServers = fetchedIce;
        }
      } catch (_) {
        // Fall back to default STUN when config RPC is unavailable.
      }
      if (_disposed || _callId != callId) {
        await _disposeStream(stream);
        return;
      }

      final pc = await _peerConnectionFactory(<String, dynamic>{
        'iceServers': initialIceServers,
        'sdpSemantics': 'unified-plan',
      });
      if (_disposed || _callId != callId) {
        await pc.close();
        return;
      }
      _pc = pc;

      for (final track in stream.getTracks()) {
        await pc.addTrack(track, stream);
      }

      pc.onTrack = (RTCTrackEvent event) {
        if (_disposed || _callId != callId) return;
        if (event.streams.isNotEmpty) {
          _remoteStream = event.streams.first;
          _remoteRenderer?.srcObject = _remoteStream;
        }
        if (event.track.kind == 'video') {
          _hasRemoteVideo = true;
        }
        _notify();
      };

      pc.onIceCandidate = (RTCIceCandidate candidate) {
        if (_disposed || _callId != callId) return;
        final str = candidate.candidate;
        if (str == null || str.isEmpty) return;
        unawaited(
          _session.callMediaIce(callId, <String, dynamic>{
            'candidate': str,
            'sdpMid': candidate.sdpMid,
            'sdpMLineIndex': candidate.sdpMLineIndex,
          }).catchError((_) {}),
        );
      };

      pc.onConnectionState = (RTCPeerConnectionState state) {
        if (_disposed || _callId != callId) return;
        if (state == RTCPeerConnectionState.RTCPeerConnectionStateConnected) {
          _state = CallMediaState.connected;
          _errorMessage = null;
          _notify();
        } else if (state == RTCPeerConnectionState.RTCPeerConnectionStateFailed) {
          _state = CallMediaState.failed;
          _notify();
        } else if (state == RTCPeerConnectionState.RTCPeerConnectionStateConnecting ||
            state == RTCPeerConnectionState.RTCPeerConnectionStateDisconnected) {
          if (_state != CallMediaState.connecting) {
            _state = CallMediaState.connecting;
            _notify();
          }
        }
      };

      _iceSub = _session.callMediaIceEvents.listen((event) async {
        if (_disposed || _callId != callId) return;
        if ('${event['callId'] ?? ''}' != callId) return;
        final raw = event['candidate'];
        if (raw is! Map) return;
        final candStr = raw['candidate'] as String?;
        if (candStr == null || candStr.isEmpty) return;
        final cand = RTCIceCandidate(
          candStr,
          raw['sdpMid'] as String?,
          (raw['sdpMLineIndex'] as num?)?.toInt(),
        );
        if (_hasRemoteDescription) {
          await _safeAddCandidate(cand);
        } else {
          _pendingRemoteIce.add(cand);
        }
      });

      final offer = await pc.createOffer(<String, dynamic>{
        'offerToReceiveAudio': true,
        'offerToReceiveVideo': media == CallMediaKind.video,
      });
      await pc.setLocalDescription(offer);

      final offerSdp = offer.sdp;
      if (offerSdp == null || offerSdp.isEmpty) {
        throw StateError('Empty WebRTC SDP offer');
      }

      final res = await _session.callMediaOffer(callId, offerSdp);
      if (_disposed || _callId != callId) return;

      final offerIce = normalizeIceServers(res['iceServers']);
      if (offerIce.isNotEmpty && !_sameIceServers(offerIce, initialIceServers)) {
        try {
          await pc.setConfiguration(<String, dynamic>{
            'iceServers': offerIce,
            'sdpSemantics': 'unified-plan',
          });
        } catch (_) {
          // Best-effort update when platform WebRTC disallows mid-offer reconfiguration.
        }
      }

      final answerSdp = res['sdp'] as String?;
      if (answerSdp == null || answerSdp.isEmpty) {
        throw StateError('Empty WebRTC SDP answer');
      }

      await pc.setRemoteDescription(RTCSessionDescription(answerSdp, 'answer'));
      _hasRemoteDescription = true;
      for (final c in _pendingRemoteIce) {
        await _safeAddCandidate(c);
      }
      _pendingRemoteIce.clear();

      await _applySpeaker(_speakerOn);
      _notify();
    } on MissingPluginException {
      // Widget/headless VM tests do not register native WebRTC plugins.
      _state = CallMediaState.idle;
      _errorMessage = null;
      _notify();
    } catch (err) {
      if (_disposed) return;
      _state = CallMediaState.failed;
      _errorMessage = '$err';
      _notify();
    }
  }

  Future<void> _safeAddCandidate(RTCIceCandidate cand) async {
    try {
      await _pc?.addCandidate(cand);
    } catch (_) {
      // ignore stale ICE candidates
    }
  }

  Future<void> _applySpeaker(bool speakerOn) async {
    try {
      await _setSpeakerphoneOn(speakerOn);
    } catch (_) {
      // Not supported on desktop/web platforms.
    }
  }

  @override
  Future<void> setMuted(bool muted) async {
    _muted = muted;
    final stream = _localStream;
    if (stream != null) {
      for (final track in stream.getAudioTracks()) {
        track.enabled = !muted;
      }
    }
    _notify();
  }

  @override
  Future<void> setSpeaker(bool speakerOn) async {
    _speakerOn = speakerOn;
    await _applySpeaker(speakerOn);
    _notify();
  }

  @override
  Future<void> setCameraEnabled(bool enabled) async {
    _cameraEnabled = enabled;
    final stream = _localStream;
    if (stream != null) {
      for (final track in stream.getVideoTracks()) {
        track.enabled = enabled;
      }
    }
    _notify();
  }

  @override
  Future<void> switchCamera() async {
    final stream = _localStream;
    if (stream == null) return;
    final tracks = stream.getVideoTracks();
    if (tracks.isEmpty) return;
    try {
      await Helper.switchCamera(tracks.first);
    } catch (_) {
      // Ignore on devices with a single/desktop camera.
    }
  }

  Future<void> _disposeStream(MediaStream? stream) async {
    if (stream == null) return;
    try {
      for (final t in stream.getTracks()) {
        await t.stop();
      }
      await stream.dispose();
    } catch (_) {}
  }

  @override
  Future<void> stop() async {
    _callId = null;
    _hasRemoteDescription = false;
    _hasLocalVideo = false;
    _hasRemoteVideo = false;
    _pendingRemoteIce.clear();
    await _iceSub?.cancel();
    _iceSub = null;

    final pc = _pc;
    _pc = null;
    if (pc != null) {
      try {
        await pc.close();
      } catch (_) {}
    }

    await _disposeStream(_localStream);
    _localStream = null;
    _remoteStream = null;

    final lr = _localRenderer;
    final rr = _remoteRenderer;
    _localRenderer = null;
    _remoteRenderer = null;
    if (lr != null) {
      try {
        lr.srcObject = null;
        await lr.dispose();
      } catch (_) {}
    }
    if (rr != null) {
      try {
        rr.srcObject = null;
        await rr.dispose();
      } catch (_) {}
    }
    _state = CallMediaState.idle;
    _errorMessage = null;
    _notify();
  }

  @override
  void dispose() {
    if (_disposed) return;
    unawaited(stop());
    _disposed = true;
    super.dispose();
  }
}
