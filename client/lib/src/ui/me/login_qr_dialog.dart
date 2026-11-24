import 'dart:async';
import 'dart:typed_data';

import 'package:material_ui/material_ui.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../domain/models.dart';
import '../../domain/services.dart';
import '../components/basics.dart';
import '../components/overlays.dart';
import '../components/pressable.dart';
import '../l10n/strings.dart';
import '../state/app_state.dart';
import '../theme/tokens.dart';
import '../theme/z_icons.dart';

Future<void> showLoginQrDialog(BuildContext context, ServerLink link) {
  return showZModal<void>(context, builder: (_) => LoginQrDialog(link: link));
}

class LoginQrDialog extends ConsumerStatefulWidget {
  const LoginQrDialog({super.key, required this.link});

  final ServerLink link;

  @override
  ConsumerState<LoginQrDialog> createState() => _LoginQrDialogState();
}

class _LoginQrDialogState extends ConsumerState<LoginQrDialog> {
  StreamSubscription<LoginQrEvent>? _sub;
  Uint8List? _png;
  int _images = 0;
  String? _scannedBy;
  String? _doneSlot;
  /// Set when the login ended without an account. The server reason is
  /// free text from Zalo (often English), so only a localized hint is shown.
  bool _failed = false;

  @override
  void initState() {
    super.initState();
    _start();
  }

  void _start() {
    _sub?.cancel();
    _png = null;
    _images = 0;
    _scannedBy = null;
    _doneSlot = null;
    _failed = false;
    _sub = widget.link.startLoginQr().listen(
      (event) {
        if (!mounted) return;
        setState(() {
          switch (event) {
            case LoginQrImage(:final png):
              _png = png;
              _images++;
              _scannedBy = null;
            case LoginQrScanned(:final displayName):
              _scannedBy = displayName;
            case LoginQrDone(:final slot):
              _doneSlot = slot;
            case LoginQrFailed():
              _failed = true;
          }
        });
      },
      onError: (Object _) {
        if (mounted) setState(() => _failed = true);
      },
    );
  }

  @override
  void dispose() {
    _sub?.cancel();
    super.dispose();
  }

  String _accountName(String slot) {
    final accounts = widget.link.manifest.value?.accounts ?? const <AccountSummary>[];
    for (final a in accounts) {
      if (a.slot == slot) return a.displayName;
    }
    return _scannedBy ?? '';
  }

  @override
  Widget build(BuildContext context) {
    final z = context.z;
    final Widget body;
    final List<Widget> actions;
    final close = ZButton(key: const Key('loginQrClose'), label: context.tr('close'), variant: ZButtonVariant.text, onPressed: () => Navigator.pop(context));
    if (_doneSlot != null) {
      final name = _accountName(_doneSlot!);
      body = Column(
        key: const Key('loginQrDone'),
        mainAxisSize: MainAxisSize.min,
        children: [
          Icon(ZIcons.checkCircle, color: z.success, size: 56, fill: 1),
          const SizedBox(height: ZSpace.s12),
          Text(context.tr('loginDone'), textAlign: TextAlign.center, style: z.text.rowTitleUnread),
          if (name.isNotEmpty) Text(name, textAlign: TextAlign.center, style: z.text.rowSub),
        ],
      );
      actions = [
        close,
        ZButton(
          key: const Key('loginQrOpen'),
          label: context.tr('openAccount'),
          onPressed: () {
            ref.read(preferredSlotProvider.notifier).set(_doneSlot);
            ref.read(openThreadProvider.notifier).state = null;
            ref.read(homeTabProvider.notifier).state = HomeTab.messages;
            Navigator.pop(context);
          },
        ),
      ];
    } else if (_failed) {
      body = Column(
        key: const Key('loginQrFailed'),
        mainAxisSize: MainAxisSize.min,
        children: [
          Icon(ZIcons.error, color: z.danger, size: 56, fill: 1),
          const SizedBox(height: ZSpace.s12),
          Text(context.tr('loginFailed'), textAlign: TextAlign.center, style: z.text.rowTitleUnread),
          Text(context.tr('loginFailedHint'), textAlign: TextAlign.center, style: z.text.rowSub),
        ],
      );
      actions = [close, ZButton(key: const Key('loginQrRetry'), label: context.tr('retry'), onPressed: () => setState(_start))];
    } else if (_scannedBy != null) {
      body = Column(
        key: const Key('loginQrScanned'),
        mainAxisSize: MainAxisSize.min,
        children: [
          Icon(ZIcons.smartphone, color: z.brandText, size: 56),
          const SizedBox(height: ZSpace.s12),
          Text(context.tr('loginScanned', [_scannedBy!]), textAlign: TextAlign.center, style: z.text.rowTitleUnread),
          const SizedBox(height: ZSpace.s16),
          SizedBox(width: 20, height: 20, child: CircularProgressIndicator(strokeWidth: 2, semanticsLabel: context.tr('loading'))),
        ],
      );
      actions = [close];
    } else {
      body = Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          Container(
            width: 240,
            height: 240,
            padding: const EdgeInsets.all(ZSpace.s8),
            decoration: BoxDecoration(color: ZalosTokens.white, borderRadius: BorderRadius.circular(ZRadius.card), border: Border.all(color: z.border)),
            child: _png == null
                ? const ZSkeleton(key: Key('loginQrSkeleton'), width: 224, height: 224, radius: ZRadius.input)
                : Image.memory(_png!, key: const Key('loginQrImage'), fit: BoxFit.contain, gaplessPlayback: true, filterQuality: FilterQuality.none, semanticLabel: context.tr('loginQrTitle')),
          ),
          const SizedBox(height: ZSpace.s12),
          Text(context.tr('loginQrHint'), textAlign: TextAlign.center, style: z.text.rowSub.copyWith(color: z.textSecondary)),
          if (_images > 1)
            Padding(
              padding: const EdgeInsets.only(top: ZSpace.s8),
              child: ZChip(key: const Key('loginQrRefreshed'), label: context.tr('loginQrRefreshed'), tone: ZTone.info, icon: ZIcons.refresh),
            ),
        ],
      );
      actions = [close];
    }
    return ZDialogScaffold(
      key: const Key('loginQrDialog'),
      title: context.tr('loginQrTitle'),
      actions: actions,
      child: SizedBox(width: double.infinity, child: body),
    );
  }
}
