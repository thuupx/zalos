import 'package:material_ui/material_ui.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../domain/services.dart';
import '../components/basics.dart';
import '../components/fields.dart';
import '../components/motion.dart';
import '../components/onboarding.dart';
import '../components/pressable.dart';
import '../l10n/strings.dart';
import '../platform/services.dart';
import '../theme/tokens.dart';
import '../theme/z_icons.dart';

bool isPairingUri(String text) {
  final uri = Uri.tryParse(text.trim());
  if (uri == null || uri.scheme != 'zalos' || uri.host != 'pair') return false;
  return uri.queryParameters.isNotEmpty ||
      (uri.pathSegments.length == 1 && uri.pathSegments.first.isNotEmpty);
}

/// Maps the data layer's pairing failure to a specific localized message.
String pairingErrorText(S s, Object error) {
  if (error is! PairingException) return s.t('pairErrUnknown');
  final host = error.detail;
  return switch (error.code) {
    PairingErrorCode.invalid => s.t('pairErrInvalid'),
    PairingErrorCode.expired => s.t('pairErrExpired'),
    PairingErrorCode.unreachable => host == null || host.isEmpty ? s.t('pairErrUnreachableNoHost') : s.t('pairErrUnreachable', [host]),
    PairingErrorCode.handshake => s.t('pairErrKey'),
    PairingErrorCode.refused => s.t('pairErrRefused'),
    PairingErrorCode.protocol => s.t('pairErrProtocol'),
    PairingErrorCode.storage => s.t('pairErrStorage'),
    PairingErrorCode.unknown => s.t('pairErrUnknown'),
  };
}

class ZalosMark extends StatelessWidget {
  const ZalosMark({super.key, this.size = 72});

  final double size;

  @override
  Widget build(BuildContext context) {
    return ExcludeSemantics(
      child: Image.asset(
        'assets/logo/zalos-mark.png',
        width: size,
        height: size,
        filterQuality: FilterQuality.medium,
        errorBuilder: (context, _, __) => Container(
          width: size,
          height: size,
          decoration: BoxDecoration(gradient: ZalosTokens.markGradient, borderRadius: BorderRadius.circular(size * 0.24)),
          child: Icon(ZIcons.forum, color: ZalosTokens.white, size: size * 0.55, fill: 1),
        ),
      ),
    );
  }
}

class PairingScreen extends ConsumerStatefulWidget {
  const PairingScreen({super.key});

  @override
  ConsumerState<PairingScreen> createState() => _PairingScreenState();
}

class _PairingScreenState extends ConsumerState<PairingScreen> {
  final TextEditingController _name = TextEditingController();
  final TextEditingController _uri = TextEditingController();
  bool _nameSeeded = false;
  bool _busy = false;
  String? _error;

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    if (!_nameSeeded) {
      _nameSeeded = true;
      _name.text = context.tr(ref.read(platformProvider).defaultDeviceNameKey);
    }
  }

  @override
  void initState() {
    super.initState();
    _uri.addListener(() => setState(() {}));
  }

  @override
  void dispose() {
    _name.dispose();
    _uri.dispose();
    super.dispose();
  }

  Future<void> _pair(String uri) async {
    final value = uri.trim();
    if (_busy || !isPairingUri(value)) return;
    setState(() {
      _busy = true;
      _error = null;
    });
    final s = context.s;
    final fallback = s.t(ref.read(platformProvider).defaultDeviceNameKey);
    final name = _name.text.trim().isEmpty ? fallback : _name.text.trim();
    try {
      await ref.read(zalosAppProvider).pair(value, deviceName: name);
    } catch (e) {
      if (mounted) setState(() => _error = pairingErrorText(s, e));
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  Future<void> _scan() async {
    final result = await Navigator.of(context).push<String>(MaterialPageRoute(builder: (_) => const PairingScannerScreen()));
    if (result == null || !mounted) return;
    _uri.text = result;
    await _pair(result);
  }

  Future<void> _paste() async {
    final data = await Clipboard.getData(Clipboard.kTextPlain);
    final text = data?.text?.trim();
    if (text != null && text.isNotEmpty) _uri.text = text;
  }

  @override
  Widget build(BuildContext context) {
    final z = context.z;
    final platform = ref.watch(platformProvider);
    final valid = isPairingUri(_uri.text);
    final typed = _uri.text.trim().isNotEmpty;
    return Scaffold(
      key: const Key('pairingScreen'),
      backgroundColor: z.layer,
      body: ZOnboardingFrame(
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            const Center(child: ZalosMark()),
            const SizedBox(height: ZSpace.s12),
            Semantics(header: true, child: Text('zalos', textAlign: TextAlign.center, style: z.text.display.copyWith(color: z.brandText))),
            const SizedBox(height: ZSpace.s8),
            Text(context.tr('pairIntro'), textAlign: TextAlign.center, style: z.text.rowSub.copyWith(color: z.textSecondary)),
            const SizedBox(height: ZSpace.s24),
            ZTextField(
              key: const Key('pairDeviceName'),
              controller: _name,
              label: context.tr('deviceName'),
              hint: context.tr('deviceName'),
              enabled: !_busy,
              maxLength: 40,
              prefixIcon: ZIcons.devices,
              textInputAction: TextInputAction.next,
            ),
            const SizedBox(height: ZSpace.s16),
            if (platform.cameraScanSupported) ...[
              ZButton(key: const Key('pairScan'), label: context.tr('scanQr'), icon: ZIcons.qrScanner, onPressed: _busy ? null : _scan, expand: true),
              const SizedBox(height: ZSpace.s16),
              Row(children: [
                Expanded(child: Container(height: 1, color: z.divider)),
                Padding(
                  padding: const EdgeInsets.symmetric(horizontal: ZSpace.s12),
                  child: Text(context.tr('or'), style: z.text.caption),
                ),
                Expanded(child: Container(height: 1, color: z.divider)),
              ]),
              const SizedBox(height: ZSpace.s16),
            ],
            ZTextField(
              key: const Key('pairUri'),
              controller: _uri,
              label: context.tr('pairCode'),
              hint: 'zalos://pair?...',
              enabled: !_busy,
              mono: true,
              minLines: 1,
              maxLines: 3,
              autocorrect: false,
              keyboardType: TextInputType.url,
              textInputAction: TextInputAction.done,
              onSubmitted: _pair,
              errorText: typed && !valid ? context.tr('pairNotUri') : null,
              suffix: ZIconButton(key: const Key('pairPaste'), icon: ZIcons.paste, label: context.tr('paste'), onPressed: _busy ? null : _paste),
            ),
            ZReveal(
              child: _error == null
                  ? null
                  : Padding(
                      padding: const EdgeInsets.only(top: ZSpace.s12),
                      child: ClipRRect(
                        borderRadius: BorderRadius.circular(ZRadius.input),
                        child: ZBanner(key: const Key('pairError'), text: _error!, tone: ZTone.danger, icon: ZIcons.error),
                      ),
                    ),
            ),
            const SizedBox(height: ZSpace.s16),
            ZButton(
              key: const Key('pairConnect'),
              label: context.tr('connect'),
              onPressed: valid ? () => _pair(_uri.text) : null,
              loading: _busy,
              variant: platform.cameraScanSupported ? ZButtonVariant.secondary : ZButtonVariant.primary,
              expand: true,
            ),
            const SizedBox(height: ZSpace.s16),
            Text(context.tr('pairHint'), textAlign: TextAlign.center, style: z.text.caption),
          ],
        ),
      ),
    );
  }
}

class PairingScannerScreen extends ConsumerStatefulWidget {
  const PairingScannerScreen({super.key});

  @override
  ConsumerState<PairingScannerScreen> createState() => _PairingScannerScreenState();
}

class _PairingScannerScreenState extends ConsumerState<PairingScannerScreen> {
  final ValueNotifier<bool> _torch = ValueNotifier(false);
  bool _done = false;
  bool _invalid = false;
  ScannerProblem? _problem;

  @override
  void dispose() {
    _torch.dispose();
    super.dispose();
  }

  void _onCode(String value) {
    if (_done || !mounted) return;
    if (isPairingUri(value)) {
      _done = true;
      Navigator.of(context).pop(value);
    } else if (!_invalid) {
      setState(() => _invalid = true);
    }
  }

  @override
  Widget build(BuildContext context) {
    final z = context.z;
    final platform = ref.watch(platformProvider);
    final white = z.text.label.copyWith(color: ZalosTokens.white);
    final problem = _problem;
    return Scaffold(
      key: const Key('scannerScreen'),
      backgroundColor: ZalosTokens.black,
      body: Stack(
        fit: StackFit.expand,
        children: [
          if (problem == null)
            platform.scanner(
              onCode: _onCode,
              onProblem: (p) {
                if (mounted) setState(() => _problem = p);
              },
              torch: _torch,
            ),
          if (problem == null)
            IgnorePointer(
              child: Center(
                child: Container(
                  width: 240,
                  height: 240,
                  decoration: BoxDecoration(
                    borderRadius: BorderRadius.circular(ZRadius.card),
                    border: Border.all(color: ZalosTokens.white, width: 2),
                    boxShadow: const [BoxShadow(color: ZalosTokens.mediaChip, spreadRadius: 2000)],
                  ),
                ),
              ),
            ),
          if (problem != null)
            Center(
              child: Padding(
                padding: const EdgeInsets.all(ZSpace.s24),
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    const Icon(ZIcons.cameraOff, size: 48, color: ZalosTokens.white),
                    const SizedBox(height: ZSpace.s12),
                    Text(
                      context.tr(problem == ScannerProblem.permissionDenied ? 'cameraDenied' : 'cameraUnavailable'),
                      key: const Key('scannerProblem'),
                      textAlign: TextAlign.center,
                      style: white,
                    ),
                    if (problem == ScannerProblem.permissionDenied) ...[
                      const SizedBox(height: ZSpace.s16),
                      ZButton(key: const Key('scannerSettings'), label: context.tr('openSettings'), onPressed: platform.openAppSettings),
                    ],
                  ],
                ),
              ),
            ),
          SafeArea(
            child: Column(
              children: [
                Padding(
                  padding: const EdgeInsets.all(ZSpace.s8),
                  child: Row(
                    children: [
                      ZIconButton(
                        key: const Key('scannerClose'),
                        icon: ZIcons.close,
                        label: context.tr('close'),
                        color: ZalosTokens.white,
                        hoverColor: ZalosTokens.mediaHover,
                        size: 40,
                        iconSize: 24,
                        onPressed: () => Navigator.of(context).pop(),
                      ),
                      Expanded(child: Text(context.tr('scanQr'), textAlign: TextAlign.center, style: z.text.title.copyWith(color: ZalosTokens.white))),
                      ValueListenableBuilder<bool>(
                        valueListenable: _torch,
                        builder: (context, on, _) => ZIconButton(
                          key: const Key('scannerTorch'),
                          icon: on ? ZIcons.flashOff : ZIcons.flashOn,
                          label: context.tr('torch'),
                          color: ZalosTokens.white,
                          hoverColor: ZalosTokens.mediaHover,
                          size: 40,
                          iconSize: 24,
                          onPressed: problem == null ? () => _torch.value = !on : null,
                        ),
                      ),
                    ],
                  ),
                ),
                const Spacer(),
                if (problem == null)
                  Padding(
                    padding: const EdgeInsets.all(ZSpace.s24),
                    child: Container(
                      padding: const EdgeInsets.symmetric(horizontal: ZSpace.s12, vertical: ZSpace.s8),
                      decoration: BoxDecoration(color: ZalosTokens.viewerBar, borderRadius: BorderRadius.circular(ZRadius.input)),
                      child: Text(
                        context.tr(_invalid ? 'scanInvalid' : 'scanHint'),
                        key: Key(_invalid ? 'scanInvalid' : 'scanHint'),
                        textAlign: TextAlign.center,
                        style: white,
                      ),
                    ),
                  ),
              ],
            ),
          ),
        ],
      ),
    );
  }
}
