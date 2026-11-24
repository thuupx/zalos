import 'package:flutter/services.dart';
import 'package:material_ui/material_ui.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../domain/models.dart';
import '../domain/services.dart';
import 'components/overlays.dart';
import 'l10n/strings.dart';
import 'pairing/pairing_screen.dart';
import 'shell/shell.dart';
import 'state/app_state.dart';
import 'state/notifications.dart';
import 'theme/theme.dart';
import 'theme/tokens.dart';
import 'util/haptics.dart';
import 'vault/vault_screens.dart';

class ZalosRoot extends ConsumerStatefulWidget {
  const ZalosRoot({super.key});

  @override
  ConsumerState<ZalosRoot> createState() => _ZalosRootState();
}

class _ZalosRootState extends ConsumerState<ZalosRoot> with WidgetsBindingObserver {
  static const MethodChannel _bgChannel = MethodChannel('dev.zalos/background');

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    _bgChannel.setMethodCallHandler(_onBackgroundCall);
  }

  @override
  void dispose() {
    _bgChannel.setMethodCallHandler(null);
    WidgetsBinding.instance.removeObserver(this);
    super.dispose();
  }

  Future<Object?> _onBackgroundCall(MethodCall call) async {
    if (call.method == 'refresh') _wakeConnection();
    return null;
  }

  void _wakeConnection() {
    if (!mounted) return;
    final link = ref.read(linkProvider);
    if (link case final WakeableLink wakeable) {
      wakeable.wake();
    }
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state == AppLifecycleState.resumed) {
      _wakeConnection();
    }
  }

  @override
  Widget build(BuildContext context) {
    final strings = ref.watch(stringsProvider);
    ZHaptics.enabled = ref.watch(hapticsEnabledProvider);
    ref.watch(notificationCoordinatorProvider);
    return MaterialApp(
      title: 'zalos',
      debugShowCheckedModeBanner: false,
      theme: buildZalosTheme(Brightness.light),
      darkTheme: buildZalosTheme(Brightness.dark),
      themeMode: ref.watch(themeModeProvider),
      locale: Locale(strings.language),
      supportedLocales: const [Locale('vi'), Locale('en')],
      localizationsDelegates: GlobalMaterialLocalizations.delegates,
      builder: (context, child) {
        final width = MediaQuery.sizeOf(context).width;
        return MediaQuery.withClampedTextScaling(
          maxScaleFactor: 1.3,
          child: StringsScope(
            strings: strings,
            child: LayoutScope(
              layout: layoutClassFor(width),
              child: Material(
                type: MaterialType.transparency,
                child: ZToastHost(child: child ?? const SizedBox.shrink()),
              ),
            ),
          ),
        );
      },
      home: const _Root(),
    );
  }
}

class _Root extends ConsumerWidget {
  const _Root();

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final link = ref.watch(linkProvider);
    if (link == null) return const PairingScreen();
    if (ref.watch(vaultStateProvider) == VaultState.needsApproval) return VaultWaitingScreen(link: link);
    return HomeShell(key: ObjectKey(link), link: link);
  }
}
