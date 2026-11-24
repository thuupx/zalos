import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';

import '../support/fake_platform.dart';
import '../support/harness.dart';

void main() {
  testWidgets('recovery code export requires step-up and auto-clears clipboard after 60s', (tester) async {
    String? clipboardText;
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger.setMockMethodCallHandler(
      SystemChannels.platform,
      (call) async {
        if (call.method == 'Clipboard.setData') {
          clipboardText = (call.arguments as Map)['text'] as String?;
        } else if (call.method == 'Clipboard.getData') {
          return {'text': clipboardText};
        }
        return null;
      },
    );
    addTearDown(() => TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger.setMockMethodCallHandler(SystemChannels.platform, null));

    final platform = FakePlatform()..stepUpAllowed = false;
    await pumpZalos(tester, size: expanded, platform: platform);

    // Open Me -> Recovery code
    await tapKey(tester, 'railTab-me', scroll: false);
    await revealIn(tester, 'meList', 'recoveryCodeEntry');
    await tapKey(tester, 'recoveryCodeEntry');
    expect(byKey('recoveryCodeDialog'), findsOneWidget);

    // Denied step-up blocks reveal.
    await tapKey(tester, 'recoveryReveal', scroll: false);
    expect(platform.stepUpCalls, 1);
    expect(byKey('recoveryCodeText'), findsNothing);

    // Granted step-up reveals and copies, then clears after 60s.
    platform.stepUpAllowed = true;
    await tapKey(tester, 'recoveryReveal', scroll: false);
    expect(platform.stepUpCalls, 2);
    expect(byKey('recoveryCodeText'), findsOneWidget);

    await tapKey(tester, 'recoveryCopy', scroll: false);
    expect(clipboardText, isNotNull);
    expect(clipboardText, isNotEmpty);

    await tester.pump(const Duration(seconds: 61));
    expect(clipboardText, '');
    await drain(tester);
  });

  testWidgets('add device requires step-up authentication', (tester) async {
    final platform = FakePlatform()..stepUpAllowed = false;
    await pumpZalos(tester, size: expanded, platform: platform);

    await tapKey(tester, 'railTab-me', scroll: false);
    await revealIn(tester, 'meList', 'linkedDevices');
    await tapKey(tester, 'linkedDevices');
    expect(byKey('devicesPage'), findsOneWidget);

    await tapKey(tester, 'devicesAdd', scroll: false);
    expect(platform.stepUpCalls, 1);
    expect(byKey('addDeviceDialog'), findsNothing);

    platform.stepUpAllowed = true;
    await tapKey(tester, 'devicesAdd', scroll: false);
    expect(platform.stepUpCalls, 2);
    expect(byKey('addDeviceDialog'), findsOneWidget);
    await drain(tester);
  });
}
