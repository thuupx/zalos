import 'package:material_ui/material_ui.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:zalos/src/domain/models.dart';
import 'package:zalos/src/domain/services.dart';
import 'package:zalos/src/ui/components/pressable.dart';
import 'package:zalos/src/ui/platform/services.dart';

import '../support/fake_platform.dart';
import '../support/fake_zalos.dart';
import '../support/harness.dart';

void main() {
  for (final entry in sizes.entries) {
    testWidgets('pairing: validation, specific error, success at ${entry.key}', (tester) async {
      final h = await pumpZalos(tester, app: FakeZalosApp(paired: false, latency: const Duration(milliseconds: 200)), size: entry.value);
      expect(tester.widget<TextField>(find.descendant(of: byKey('pairDeviceName'), matching: find.byType(TextField))).controller!.text, 'Máy Mac');
      expect(tester.widget<ZButton>(byKey('pairConnect')).onPressed, isNull);

      await tester.enterText(byKey('pairUri'), 'https://example.com');
      await tester.pump();
      expect(find.text('Mã phải có dạng zalos://pair?...'), findsOneWidget);
      expect(tester.widget<ZButton>(byKey('pairConnect')).onPressed, isNull);

      h.app.pairError = const PairingException('This pairing code has expired or was already used.', code: PairingErrorCode.expired);
      await tester.enterText(byKey('pairUri'), FakeZalosApp.samplePairingUri);
      await tester.pump();
      await tester.tap(byKey('pairConnect'));
      await tester.pump(const Duration(milliseconds: 50));
      expect(tester.widget<ZButton>(byKey('pairConnect')).loading, isTrue);
      await settle(tester);
      expect(byKey('pairError'), findsOneWidget);
      expect(find.textContaining('hết hạn hoặc đã được dùng'), findsOneWidget);
      expect(find.textContaining('expired'), findsNothing);

      h.app.pairError = null;
      await tapKey(tester, 'pairConnect');
      expect(byKey('pairingScreen'), findsNothing);
      expect(byKey(entry.value.width >= 720 ? 'wideShell' : 'compactShell'), findsOneWidget);
      await drain(tester);
    });
  }

  testWidgets('pairing: scanner accepts only pairing uris, shows permission path', (tester) async {
    final platform = FakePlatform();
    await pumpZalos(tester, app: FakeZalosApp(paired: false), platform: platform);
    await tapKey(tester, 'pairScan');
    expect(byKey('scannerScreen'), findsOneWidget);
    platform.scannerOnCode!('https://example.com/qr');
    await tester.pump();
    expect(byKey('scanInvalid'), findsOneWidget);
    await tapKey(tester, 'scannerTorch');
    expect(platform.scannerTorch!.value, isTrue);
    platform.scannerOnProblem!(ScannerProblem.permissionDenied);
    await tester.pump();
    expect(byKey('scannerProblem'), findsOneWidget);
    await tapKey(tester, 'scannerSettings');
    expect(platform.settingsOpened, 1);
    await tapKey(tester, 'scannerClose');

    await tapKey(tester, 'pairScan');
    platform.scannerOnCode!(FakeZalosApp.samplePairingUri);
    await settle(tester);
    expect(byKey('compactShell'), findsOneWidget);
    await drain(tester);
  });

  testWidgets('pairing: no scan button without a camera, paste fills the field', (tester) async {
    tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(SystemChannels.platform, (call) async {
      if (call.method == 'Clipboard.getData') return {'text': FakeZalosApp.samplePairingUri};
      return null;
    });
    addTearDown(() => tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(SystemChannels.platform, null));
    await pumpZalos(tester, app: FakeZalosApp(paired: false), platform: FakePlatform(cameraScanSupported: false));
    expect(byKey('pairScan'), findsNothing);
    await tapKey(tester, 'pairPaste');
    expect(tester.widget<ZButton>(byKey('pairConnect')).onPressed, isNotNull);
    await drain(tester);
  });

  testWidgets('vault waiting: fingerprint, resend, rejection banner, recovery import', (tester) async {
    final h = await pumpZalos(tester, app: FakeZalosApp(vaultPending: true), size: medium);
    expect(byKey('vaultWaiting'), findsOneWidget);
    for (final g in ['4F2A', '91C7', 'D03B', 'E65A', '18FC']) {
      expect(find.descendant(of: byKey('boxFingerprint'), matching: find.text(g)), findsOneWidget);
    }
    expect(byKey('vaultRejected'), findsNothing);
    h.link.setVaultRejected(true);
    await tester.pump();
    expect(byKey('vaultRejected'), findsOneWidget);
    await tapKey(tester, 'vaultResend');
    expect(h.app.vaultRequestsSent, 1);
    expect(byKey('vaultRequestSent'), findsOneWidget);
    expect(byKey('vaultRejected'), findsNothing);

    await tapKey(tester, 'importRecovery');
    await tester.enterText(byKey('recoveryField'), 'abc');
    await tapKey(tester, 'recoverySubmit', scroll: false);
    expect(find.text('Mã khôi phục không hợp lệ'), findsOneWidget);
    await tester.enterText(byKey('recoveryField'), FakeZalosApp.sampleRecoveryCode);
    await tapKey(tester, 'recoverySubmit', scroll: false);
    expect(h.app.vault.value, VaultState.ready);
    expect(byKey('wideShell'), findsOneWidget);
    await drain(tester);
  });

  testWidgets('vault waiting: unpair asks first and returns to pairing', (tester) async {
    await pumpZalos(tester, app: FakeZalosApp(vaultPending: true));
    await tapKey(tester, 'vaultUnpair');
    expect(find.textContaining('Khóa trên thiết bị này sẽ bị xóa'), findsOneWidget);
    await tapKey(tester, 'confirmOk', scroll: false);
    expect(byKey('pairingScreen'), findsOneWidget);
    await drain(tester);
  });

  testWidgets('approval card: approve needs the checkbox, reject removes, errors inline', (tester) async {
    final h = await pumpZalos(tester, size: expanded);
    expect(byKey('vaultDot'), findsOneWidget);
    await tapKey(tester, 'railTab-me');
    expect(byKey('vaultRequest-dev-tablet'), findsOneWidget);
    expect(find.text('9C41'), findsOneWidget);

    await tapKey(tester, 'vaultApprove-dev-tablet');
    expect(byKey('vaultApproveDialog'), findsOneWidget);
    expect(tester.widget<ZButton>(byKey('vaultApproveConfirm')).onPressed, isNull);
    await tapKey(tester, 'vaultApproveCheck', scroll: false);
    h.app.flags.failVaultApprove = true;
    await tapKey(tester, 'vaultApproveConfirm', scroll: false);
    expect(byKey('vaultCardError'), findsOneWidget);
    expect(h.link.vaultRequests.value, hasLength(1));

    h.app.flags.failVaultApprove = false;
    await tapKey(tester, 'vaultApprove-dev-tablet');
    await tapKey(tester, 'vaultApproveCheck', scroll: false);
    await tapKey(tester, 'vaultApproveConfirm', scroll: false);
    expect(h.link.vaultRequests.value, isEmpty);
    expect(byKey('vaultRequestCards'), findsNothing);
    expect(byKey('vaultDot'), findsNothing);
    await drain(tester);
  });

  testWidgets('approval card: reject and member devices see no cards', (tester) async {
    final h = await pumpZalos(tester);
    await tapKey(tester, 'tab-me');
    await tapKey(tester, 'vaultReject-dev-tablet');
    await tapKey(tester, 'confirmOk', scroll: false);
    expect(h.link.vaultRequests.value, isEmpty);
    await drain(tester);

    await pumpZalos(tester, app: FakeZalosApp(role: DeviceRole.member));
    expect(byKey('vaultDot'), findsNothing);
    await tapKey(tester, 'tab-me');
    expect(byKey('addZaloAccount'), findsNothing);
    expect(byKey('addDevice'), findsNothing);
    await drain(tester);
  });

  testWidgets('recovery code dialog: reveal, copy, must confirm saved to close', (tester) async {
    String? copied;
    tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(SystemChannels.platform, (call) async {
      if (call.method == 'Clipboard.setData') copied = (call.arguments as Map)['text'] as String?;
      return null;
    });
    addTearDown(() => tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(SystemChannels.platform, null));
    final h = await pumpZalos(tester, size: expanded);
    await tapKey(tester, 'railTab-me');
    await revealIn(tester, 'meList', 'recoveryCodeEntry');
    await tapKey(tester, 'recoveryCodeEntry');
    expect(find.text('ZLS1'), findsNothing);
    h.app.flags.failRecoveryExport = true;
    await tapKey(tester, 'recoveryReveal', scroll: false);
    expect(find.text('Không lấy được mã khôi phục'), findsOneWidget);
    h.app.flags.failRecoveryExport = false;
    await tapKey(tester, 'recoveryReveal', scroll: false);
    expect(find.text('ZLS1'), findsOneWidget);
    await tapKey(tester, 'recoveryCopy', scroll: false);
    expect(copied, FakeZalosApp.sampleRecoveryCode);
    expect(tester.widget<ZButton>(byKey('recoveryClose')).onPressed, isNull);
    await tapKey(tester, 'recoverySaved', scroll: false);
    await tapKey(tester, 'recoveryClose', scroll: false);
    expect(byKey('recoveryCodeDialog'), findsNothing);
    await drain(tester);
  });
}
