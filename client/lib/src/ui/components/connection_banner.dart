import 'dart:async';

import 'package:material_ui/material_ui.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../domain/models.dart';
import '../../domain/services.dart';
import '../l10n/strings.dart';
import '../state/app_state.dart';
import 'basics.dart';
import 'motion.dart';
import '../theme/z_icons.dart';

/// Banner under a header while the server link or the account tunnel is not
/// connected. "Connecting" only shows after two seconds.
class ConnectionBanner extends ConsumerStatefulWidget {
  const ConnectionBanner({super.key, this.session});

  final AccountSession? session;

  @override
  ConsumerState<ConnectionBanner> createState() => _ConnectionBannerState();
}

class _ConnectionBannerState extends ConsumerState<ConnectionBanner> {
  static const Duration _delay = Duration(seconds: 2);
  Timer? _timer;
  bool _connectingShown = false;
  LinkState? _last;

  @override
  void dispose() {
    _timer?.cancel();
    super.dispose();
  }

  void _track(LinkState state) {
    if (state == _last) return;
    _last = state;
    _timer?.cancel();
    _connectingShown = false;
    if (state == LinkState.connecting) {
      _timer = Timer(_delay, () {
        if (mounted) setState(() => _connectingShown = true);
      });
    }
  }

  @override
  Widget build(BuildContext context) {
    var state = ref.watch(linkStateProvider);
    final session = widget.session;
    if (state == LinkState.connected && session != null) state = ref.watchL(session.state);
    _track(state);
    return ZReveal(child: _banner(state));
  }

  Widget? _banner(LinkState state) {
    switch (state) {
      case LinkState.connected:
        return null;
      case LinkState.connecting:
        if (!_connectingShown) return null;
        return ZBanner(key: const Key('bannerConnecting'), text: context.tr('bannerConnecting'), tone: ZTone.info, icon: ZIcons.sync);
      case LinkState.disconnected:
        return ZBanner(key: const Key('bannerDisconnected'), text: context.tr('bannerDisconnected'), tone: ZTone.warning, icon: ZIcons.cloudOff);
      case LinkState.unauthorized:
        return ZBanner(
          key: const Key('bannerUnauthorized'),
          text: context.tr('bannerUnauthorized'),
          tone: ZTone.danger,
          icon: ZIcons.lock,
          actionLabel: context.tr('pairAgain'),
          onAction: () => ref.read(zalosAppProvider).unpair(),
        );
    }
  }
}
