import 'package:flutter_test/flutter_test.dart';
import 'package:zalos/src/domain/models.dart';

import '../support/harness.dart';

void main() {
  testWidgets('chat header call buttons start voice/video call and show CallOverlay', (tester) async {
    final h = await pumpZalos(tester, size: compact);
    await openThreadByKey(tester, 'u01');

    expect(byKey('chatVoiceCall'), findsOneWidget);
    expect(byKey('chatVideoCall'), findsOneWidget);

    await tapKey(tester, 'chatVoiceCall', scroll: false);
    expect(h.main.callsStarted, hasLength(1));
    expect(h.main.callsStarted.first.media, CallMediaKind.voice);
    expect(byKey('callOverlay'), findsOneWidget);

    // Hang up clears CallOverlay.
    await tapKey(tester, 'callHangupButton', scroll: false);
    expect(h.main.callsHungUp, hasLength(1));
    expect(byKey('callOverlay'), findsNothing);

    // Trigger video call.
    await tapKey(tester, 'chatVideoCall', scroll: false);
    expect(h.main.callsStarted, hasLength(2));
    expect(h.main.callsStarted.last.media, CallMediaKind.video);
    expect(byKey('callOverlay'), findsOneWidget);
    expect(byKey('callCameraButton'), findsOneWidget);

    // Minimize to banner, then restore.
    await tapKey(tester, 'callMinimizeButton', scroll: false);
    expect(byKey('callOverlay'), findsNothing);
    expect(byKey('callMinimizedBanner'), findsOneWidget);

    await tapKey(tester, 'callMinimizedBanner', scroll: false);
    expect(byKey('callOverlay'), findsOneWidget);

    await tapKey(tester, 'callHangupButton', scroll: false);
    expect(byKey('callOverlay'), findsNothing);
    await drain(tester);
  });

  testWidgets('incoming call overlay supports accept, local silence, and decline', (tester) async {
    final h = await pumpZalos(tester, size: expanded);
    h.main.simulateIncomingCall(
      const ActiveCall(
        callId: 'in-101',
        threadId: 'u01',
        threadType: ThreadType.user,
        peerId: 'u01',
        peerName: 'Nguyễn Minh Anh',
        media: CallMediaKind.video,
        direction: CallDirection.incoming,
        status: CallStatus.ringing,
        startedAt: 1700000000000,
      ),
    );
    await settle(tester);

    expect(byKey('callOverlay'), findsOneWidget);
    expect(byKey('callAcceptButton'), findsOneWidget);
    expect(byKey('callDeclineButton'), findsOneWidget);
    expect(byKey('callSilenceButton'), findsOneWidget);

    await tapKey(tester, 'callAcceptButton', scroll: false);
    expect(h.main.callsAccepted, ['in-101']);
    expect(byKey('callHangupButton'), findsOneWidget);
    await tapKey(tester, 'callHangupButton', scroll: false);
    expect(byKey('callOverlay'), findsNothing);

    // Incoming again -> test Silence locally.
    h.main.simulateIncomingCall(
      const ActiveCall(
        callId: 'in-102',
        threadId: 'u02',
        threadType: ThreadType.user,
        peerId: 'u02',
        peerName: 'Trần Quốc Bảo',
        media: CallMediaKind.voice,
        direction: CallDirection.incoming,
        status: CallStatus.ringing,
        startedAt: 1700000005000,
      ),
    );
    await settle(tester);
    await tapKey(tester, 'callSilenceButton', scroll: false);
    expect(h.main.callsRejected, [(callId: 'in-102', localOnly: true)]);
    expect(byKey('callOverlay'), findsNothing);
    await drain(tester);
  });

  testWidgets('hides call buttons when account lacks voiceCall and videoCall capabilities', (tester) async {
    final h = await pumpZalos(tester, size: compact);
    h.app.fakeLink.setCapabilities(
      'main',
      AccountCapability.values.toSet().difference(const {AccountCapability.voiceCall, AccountCapability.videoCall}),
    );
    await settle(tester);
    await openThreadByKey(tester, 'u01');
    expect(byKey('chatVoiceCall'), findsNothing);
    expect(byKey('chatVideoCall'), findsNothing);
    await drain(tester);
  });
}
