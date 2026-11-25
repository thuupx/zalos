import 'package:flutter_test/flutter_test.dart';
import 'package:flutter_webrtc/flutter_webrtc.dart';
import 'package:zalos/src/domain/models.dart';
import 'package:zalos/src/ui/call/call_media_controller.dart';

import '../support/fake_zalos.dart';

class _FakeRenderer extends RTCVideoRenderer {
  @override
  Future<void> initialize() async {}

  @override
  set srcObject(MediaStream? stream) {}
}

class _FakeTrack extends Fake implements MediaStreamTrack {
  _FakeTrack(this.kind);

  @override
  final String? kind;

  @override
  bool enabled = true;

  @override
  Future<void> stop() async {}
}

class _FakeMediaStream extends Fake implements MediaStream {
  _FakeMediaStream(this._tracks);

  final List<MediaStreamTrack> _tracks;

  @override
  List<MediaStreamTrack> getTracks() => _tracks;

  @override
  List<MediaStreamTrack> getAudioTracks() =>
      _tracks.where((t) => t.kind == 'audio').toList();

  @override
  List<MediaStreamTrack> getVideoTracks() =>
      _tracks.where((t) => t.kind == 'video').toList();

  @override
  Future<void> dispose() async {}
}

class _FakePeerConnection extends Fake implements RTCPeerConnection {
  final List<Map<String, dynamic>> configurations = [];
  final List<RTCIceCandidate> addedCandidates = [];
  RTCSessionDescription? remoteDescription;
  bool closed = false;

  @override
  Function(RTCTrackEvent event)? onTrack;

  @override
  Function(RTCIceCandidate candidate)? onIceCandidate;

  @override
  Function(RTCPeerConnectionState state)? onConnectionState;

  @override
  Future<RTCRtpSender> addTrack(MediaStreamTrack track, [MediaStream? stream]) async =>
      _FakeRtpSender();

  @override
  Future<RTCSessionDescription> createOffer([Map<String, dynamic>? constraints]) async =>
      RTCSessionDescription('v=0\r\nm=audio 9 UDP/TLS/RTP/SAVPF 111\r\n', 'offer');

  @override
  Future<void> setLocalDescription(RTCSessionDescription description) async {}

  @override
  Future<void> setConfiguration(Map<String, dynamic> configuration) async {
    configurations.add(configuration);
  }

  @override
  Future<void> setRemoteDescription(RTCSessionDescription description) async {
    remoteDescription = description;
  }

  @override
  Future<void> addCandidate(RTCIceCandidate candidate) async {
    addedCandidates.add(candidate);
  }

  @override
  Future<void> close() async {
    closed = true;
  }
}

class _FakeRtpSender extends Fake implements RTCRtpSender {}

class _TestSession extends FakeSession {
  _TestSession(
    FakeServerLink link, {
    required this.initialIceServers,
    required this.offerResponse,
  }) : super(link, 'main', 'u0', 'Me');

  final List<Map<String, dynamic>> initialIceServers;
  final Map<String, dynamic> offerResponse;
  final List<Map<String, dynamic>> sentIce = [];

  @override
  Future<List<Map<String, dynamic>>> callMediaIceServers() async => initialIceServers;

  @override
  Future<Map<String, dynamic>> callMediaOffer(String callId, String sdp) async => offerResponse;

  @override
  Future<void> callMediaIce(String callId, Map<String, dynamic> candidate) async {
    sentIce.add({'callId': callId, ...candidate});
  }
}

void main() {
  test('normalizeIceServers filters invalid entries and preserves TURN credentials', () {
    final normalized = normalizeIceServers([
      {'urls': 'stun:stun.l.google.com:19302'},
      {
        'urls': ['turn:turn.example.com:3478', ''],
        'username': 'u1',
        'credential': 'p1',
      },
      {'urls': ''},
      'bad',
      null,
    ]);
    expect(normalized, [
      {'urls': 'stun:stun.l.google.com:19302'},
      {
        'urls': ['turn:turn.example.com:3478'],
        'username': 'u1',
        'credential': 'p1',
      },
    ]);
  });

  test('WebRtcCallMediaController applies server iceServers and only marks connected on RTCPeerConnectionStateConnected', () async {
    final app = FakeZalosApp();
    final session = _TestSession(
      app.fakeLink,
      initialIceServers: [
        {'urls': 'stun:stun.custom.example:3478'},
      ],
      offerResponse: {
        'sdp': 'v=0\r\nm=audio 40002 UDP/TLS/RTP/SAVPF 111\r\n',
        'type': 'answer',
        'iceServers': [
          {
            'urls': 'turn:turn.custom.example:3478',
            'username': 'turn-user',
            'credential': 'turn-pass',
          },
        ],
      },
    );

    final createdConfigs = <Map<String, dynamic>>[];
    late _FakePeerConnection fakePc;

    final controller = WebRtcCallMediaController(
      session,
      peerConnectionFactory: (config) async {
        createdConfigs.add(config);
        fakePc = _FakePeerConnection();
        return fakePc;
      },
      getUserMedia: (_) async => _FakeMediaStream([_FakeTrack('audio')]),
      rendererFactory: _FakeRenderer.new,
      setSpeakerphoneOn: (_) async {},
    );

    await controller.start(callId: 'c1', media: CallMediaKind.voice);

    expect(
      controller.errorMessage,
      isNull,
      reason: 'state=${controller.state} err=${controller.errorMessage}',
    );
    // Server ICE config was passed to createPeerConnection AND updated from offer answer.
    expect(createdConfigs, hasLength(1));
    expect(createdConfigs.first['iceServers'], [
      {'urls': 'stun:stun.custom.example:3478'},
    ]);
    expect(fakePc.configurations, hasLength(1));
    expect(fakePc.configurations.first['iceServers'], [
      {
        'urls': 'turn:turn.custom.example:3478',
        'username': 'turn-user',
        'credential': 'turn-pass',
      },
    ]);
    expect(fakePc.remoteDescription?.type, 'answer');

    // Must remain connecting after setRemoteDescription until ICE/DTLS actually connects.
    expect(controller.state, CallMediaState.connecting);

    fakePc.onConnectionState?.call(RTCPeerConnectionState.RTCPeerConnectionStateConnected);
    expect(controller.state, CallMediaState.connected);

    fakePc.onConnectionState?.call(RTCPeerConnectionState.RTCPeerConnectionStateFailed);
    expect(controller.state, CallMediaState.failed);

    await controller.stop();
    expect(fakePc.closed, isTrue);
    expect(controller.state, CallMediaState.idle);
    controller.dispose();
  });
}
