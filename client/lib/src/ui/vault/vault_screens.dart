import 'dart:async';

import 'package:material_ui/material_ui.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../domain/models.dart';
import '../../domain/services.dart';
import '../components/basics.dart';
import '../components/connection_banner.dart';
import '../components/fields.dart';
import '../components/motion.dart';
import '../components/onboarding.dart';
import '../components/overlays.dart';
import '../components/pressable.dart';
import '../l10n/strings.dart';
import '../platform/services.dart';
import '../state/app_state.dart';
import '../theme/tokens.dart';
import '../theme/z_icons.dart';
import '../util/format.dart';

Future<void> confirmUnpair(BuildContext context, WidgetRef ref) async {
  final ok = await zConfirm(context, title: context.tr('unpairTitle'), message: context.tr('unpairBody'), confirmLabel: context.tr('unpairShort'));
  if (!ok) return;
  await ref.read(platformProvider).clearTempMedia();
  ref.read(openThreadProvider.notifier).state = null;
  ref.read(infoPaneOpenProvider.notifier).state = false;
  ref.read(homeTabProvider.notifier).state = HomeTab.messages;
  await ref.read(zalosAppProvider).unpair();
}

/// Replaces the shell while this device has no vault root.
class VaultWaitingScreen extends ConsumerStatefulWidget {
  const VaultWaitingScreen({super.key, required this.link});

  final ServerLink link;

  @override
  ConsumerState<VaultWaitingScreen> createState() => _VaultWaitingScreenState();
}

class _VaultWaitingScreenState extends ConsumerState<VaultWaitingScreen> {
  bool _sending = false;
  bool _sent = false;
  String? _error;

  Future<void> _resend() async {
    setState(() {
      _sending = true;
      _error = null;
    });
    final failed = context.tr('actionFailed');
    try {
      await ref.read(zalosAppProvider).requestVaultApproval();
      if (mounted) setState(() => _sent = true);
    } catch (_) {
      if (mounted) setState(() => _error = failed);
    } finally {
      if (mounted) setState(() => _sending = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final z = context.z;
    final app = ref.watch(zalosAppProvider);
    final rejected = ref.watch(vaultRejectedProvider);
    Widget step(int n, String text) => Padding(
          padding: const EdgeInsets.symmetric(vertical: ZSpace.s4),
          child: Row(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Container(
                width: 22,
                height: 22,
                alignment: Alignment.center,
                decoration: BoxDecoration(color: z.brandSubtle, shape: BoxShape.circle),
                child: Text('$n', textScaler: TextScaler.noScaling, style: z.text.captionStrong.copyWith(color: z.brandText, fontWeight: FontWeight.w700)),
              ),
              const SizedBox(width: ZSpace.s8),
              Expanded(child: Text(text, style: z.text.rowSub.copyWith(color: z.textSecondary))),
            ],
          ),
        );
    return Scaffold(
      key: const Key('vaultWaiting'),
      backgroundColor: z.layer,
      body: ZOnboardingFrame(
        maxWidth: 440,
        header: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            const ConnectionBanner(),
            ZReveal(child: rejected ? ZBanner(key: const Key('vaultRejected'), tone: ZTone.danger, icon: ZIcons.block, text: context.tr('vaultRejected')) : null),
          ],
        ),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Center(
              child: Container(
                width: 72,
                height: 72,
                decoration: BoxDecoration(color: z.brandSubtle, shape: BoxShape.circle),
                child: Icon(ZIcons.lock, size: 36, color: z.brandText),
              ),
            ),
            const SizedBox(height: ZSpace.s16),
            Semantics(header: true, child: Text(context.tr('vaultWaitTitle'), textAlign: TextAlign.center, style: z.text.title)),
            const SizedBox(height: ZSpace.s8),
            Text(context.tr('vaultWaitBody'), textAlign: TextAlign.center, style: z.text.rowSub.copyWith(color: z.textSecondary)),
            const SizedBox(height: ZSpace.s24),
            Text(context.tr('vaultThisFingerprint'), textAlign: TextAlign.center, style: z.text.overline),
            const SizedBox(height: ZSpace.s8),
            ZCodeGroups(key: const Key('boxFingerprint'), value: app.boxFingerprint, size: 22),
            const SizedBox(height: ZSpace.s20),
            step(1, context.tr('vaultStep1')),
            step(2, context.tr('vaultStep2')),
            step(3, context.tr('vaultStep3')),
            const SizedBox(height: ZSpace.s20),
            ZReveal(
              child: _error == null
                  ? null
                  : Padding(padding: const EdgeInsets.only(bottom: ZSpace.s8), child: Text(_error!, textAlign: TextAlign.center, style: z.text.caption.copyWith(color: z.danger))),
            ),
            ZReveal(
              child: _sent
                  ? Padding(padding: const EdgeInsets.only(bottom: ZSpace.s8), child: Text(context.tr('vaultRequestSent'), key: const Key('vaultRequestSent'), textAlign: TextAlign.center, style: z.text.caption.copyWith(color: z.success)))
                  : null,
            ),
            ZButton(key: const Key('vaultResend'), label: context.tr('vaultResend'), icon: ZIcons.send, loading: _sending, onPressed: _resend, expand: true),
            const SizedBox(height: ZSpace.s8),
            ZButton(
              key: const Key('importRecovery'),
              label: context.tr('enterRecoveryCode'),
              icon: ZIcons.key,
              variant: ZButtonVariant.secondary,
              expand: true,
              onPressed: () => showZModal<void>(context, builder: (_) => const RecoveryImportDialog()),
            ),
            const SizedBox(height: ZSpace.s8),
            ZButton(key: const Key('vaultUnpair'), label: context.tr('unpair'), variant: ZButtonVariant.destructiveText, expand: true, onPressed: () => confirmUnpair(context, ref)),
          ],
        ),
      ),
    );
  }
}

class RecoveryImportDialog extends ConsumerStatefulWidget {
  const RecoveryImportDialog({super.key});

  @override
  ConsumerState<RecoveryImportDialog> createState() => _RecoveryImportDialogState();
}

class _RecoveryImportDialogState extends ConsumerState<RecoveryImportDialog> {
  final TextEditingController _code = TextEditingController();
  bool _busy = false;
  String? _error;

  @override
  void dispose() {
    _code.dispose();
    super.dispose();
  }

  Future<void> _submit() async {
    final code = _code.text.trim();
    if (_busy) return;
    final invalid = context.tr('recoveryInvalid');
    final failed = context.tr('actionFailed');
    if (code.isEmpty) {
      setState(() => _error = invalid);
      return;
    }
    setState(() {
      _busy = true;
      _error = null;
    });
    final navigator = Navigator.of(context);
    try {
      await ref.read(zalosAppProvider).importRecoveryCode(code);
      if (mounted) navigator.pop();
    } on FormatException {
      if (mounted) setState(() => _error = invalid);
    } catch (_) {
      if (mounted) setState(() => _error = failed);
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final z = context.z;
    return ZDialogScaffold(
      key: const Key('recoveryImportDialog'),
      title: context.tr('enterRecoveryCode'),
      actions: [
        ZButton(label: context.tr('cancel'), variant: ZButtonVariant.text, onPressed: _busy ? null : () => Navigator.pop(context)),
        ZButton(key: const Key('recoverySubmit'), label: context.tr('restore'), loading: _busy, onPressed: _submit),
      ],
      child: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Text(context.tr('recoveryImportHint'), style: z.text.rowSub.copyWith(color: z.textSecondary)),
          const SizedBox(height: ZSpace.s12),
          ZTextField(
            key: const Key('recoveryField'),
            controller: _code,
            label: context.tr('recoveryCode'),
            hint: context.tr('recoveryCode'),
            enabled: !_busy,
            autofocus: true,
            autocorrect: false,
            mono: true,
            minLines: 1,
            maxLines: 3,
            capitalization: TextCapitalization.characters,
            onSubmitted: (_) => _submit(),
            errorText: _error,
          ),
        ],
      ),
    );
  }
}

/// Cards of devices waiting for the vault root. Renders nothing when empty.
class VaultRequestCards extends ConsumerWidget {
  const VaultRequestCards({super.key, required this.link});

  final ServerLink link;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final requests = ref.watch(vaultRequestsProvider);
    if (requests.isEmpty || !ref.watch(isAdminProvider)) return const SizedBox.shrink();
    return Column(
      key: const Key('vaultRequestCards'),
      mainAxisSize: MainAxisSize.min,
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        for (final r in requests) Padding(padding: const EdgeInsets.only(top: ZSpace.s12), child: _VaultRequestCard(key: Key('vaultRequest-${r.deviceId}'), link: link, request: r)),
      ],
    );
  }
}

class _VaultRequestCard extends StatefulWidget {
  const _VaultRequestCard({super.key, required this.link, required this.request});

  final ServerLink link;
  final VaultRequest request;

  @override
  State<_VaultRequestCard> createState() => _VaultRequestCardState();
}

class _VaultRequestCardState extends State<_VaultRequestCard> {
  bool _busy = false;
  String? _error;

  Future<void> _run(Future<void> Function() action) async {
    final failed = context.tr('actionFailed');
    setState(() {
      _busy = true;
      _error = null;
    });
    try {
      await action();
    } catch (_) {
      if (mounted) setState(() => _error = failed);
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  Future<void> _approve() async {
    final r = widget.request;
    final ok = await showZModal<bool>(context, builder: (_) => _ApproveDialog(request: r));
    if (ok == true && mounted) await _run(() => widget.link.approveVaultRequest(r));
  }

  Future<void> _reject() async {
    final r = widget.request;
    final ok = await zConfirm(context, title: context.tr('vaultRejectTitle', [r.name]), message: context.tr('vaultRejectBody'), confirmLabel: context.tr('reject'));
    if (ok && mounted) await _run(() => widget.link.rejectVaultRequest(r));
  }

  @override
  Widget build(BuildContext context) {
    final z = context.z;
    final r = widget.request;
    return ZCard(
      color: z.layer,
      borderColor: z.brandText.withValues(alpha: 0.5),
      padding: const EdgeInsets.all(ZSpace.s12),
      children: [
        Row(
          children: [
            Icon(ZIcons.encrypted, size: 20, color: z.brandText),
            const SizedBox(width: ZSpace.s8),
            Expanded(child: Text(context.tr('vaultRequestTitle'), style: z.text.labelStrong)),
          ],
        ),
        const SizedBox(height: ZSpace.s8),
        Text(r.name, maxLines: 1, overflow: TextOverflow.ellipsis, style: z.text.rowTitleUnread),
        Text(context.tr('vaultRequestedAt', [formatRelative(r.requestedAt, context.s)]), style: z.text.caption.copyWith(color: z.textSecondary)),
        const SizedBox(height: ZSpace.s8),
        ZCodeGroups(value: r.fingerprint, size: 13, alignment: WrapAlignment.start),
        if (_error != null)
          Padding(
            padding: const EdgeInsets.only(top: ZSpace.s8),
            child: Text(_error!, key: const Key('vaultCardError'), style: z.text.caption.copyWith(color: z.danger)),
          ),
        const SizedBox(height: ZSpace.s12),
        Wrap(
          alignment: WrapAlignment.end,
          spacing: ZSpace.s8,
          runSpacing: ZSpace.s8,
          children: [
            ZButton(key: Key('vaultReject-${r.deviceId}'), label: context.tr('reject'), variant: ZButtonVariant.destructiveText, small: true, onPressed: _busy ? null : _reject),
            ZButton(key: Key('vaultApprove-${r.deviceId}'), label: context.tr('approve'), small: true, loading: _busy, onPressed: _approve),
          ],
        ),
      ],
    );
  }
}

class _ApproveDialog extends StatefulWidget {
  const _ApproveDialog({required this.request});

  final VaultRequest request;

  @override
  State<_ApproveDialog> createState() => _ApproveDialogState();
}

class _ApproveDialogState extends State<_ApproveDialog> {
  bool _checked = false;

  @override
  Widget build(BuildContext context) {
    final z = context.z;
    final r = widget.request;
    return ZDialogScaffold(
      key: const Key('vaultApproveDialog'),
      title: context.tr('vaultApproveTitle', [r.name]),
      actions: [
        ZButton(label: context.tr('cancel'), variant: ZButtonVariant.text, onPressed: () => Navigator.pop(context, false)),
        ZButton(key: const Key('vaultApproveConfirm'), label: context.tr('approve'), onPressed: _checked ? () => Navigator.pop(context, true) : null),
      ],
      child: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          ZCodeGroups(value: r.fingerprint, size: 20),
          const SizedBox(height: ZSpace.s12),
          Text(context.tr('vaultApproveBody'), textAlign: TextAlign.center, style: z.text.rowSub.copyWith(color: z.textSecondary)),
          const SizedBox(height: ZSpace.s8),
          ZCheckRow(key: const Key('vaultApproveCheck'), label: context.tr('vaultApproveCheck'), value: _checked, onChanged: (v) => setState(() => _checked = v)),
        ],
      ),
    );
  }
}

Future<void> showRecoveryCodeDialog(BuildContext context) => showZModal<void>(context, dismissible: false, builder: (_) => const RecoveryCodeDialog());

class RecoveryCodeDialog extends ConsumerStatefulWidget {
  const RecoveryCodeDialog({super.key});

  @override
  ConsumerState<RecoveryCodeDialog> createState() => _RecoveryCodeDialogState();
}

class _RecoveryCodeDialogState extends ConsumerState<RecoveryCodeDialog> {
  static const Duration _clipboardTtl = Duration(seconds: 60);

  String? _code;
  String? _error;
  bool _busy = false;
  bool _copied = false;
  bool _saved = false;
  Timer? _clipboardTimer;
  String? _copiedCode;

  @override
  void dispose() {
    if (_clipboardTimer?.isActive ?? false) {
      _clipboardTimer!.cancel();
      _clearClipboard();
    }
    super.dispose();
  }

  Future<void> _clearClipboard() async {
    final copied = _copiedCode;
    if (copied == null) return;
    try {
      final current = await Clipboard.getData(Clipboard.kTextPlain);
      if (current?.text == copied) {
        await Clipboard.setData(const ClipboardData(text: ''));
      }
    } catch (_) {}
  }

  Future<void> _copy(String code) async {
    await Clipboard.setData(ClipboardData(text: code));
    _copiedCode = code;
    _clipboardTimer?.cancel();
    _clipboardTimer = Timer(_clipboardTtl, _clearClipboard);
    if (mounted) setState(() => _copied = true);
  }

  Future<void> _reveal() async {
    final failed = context.tr('recoveryExportFailed');
    final denied = context.tr('authDenied');
    final reason = context.tr('authRequiredReason');
    setState(() {
      _busy = true;
      _error = null;
    });
    try {
      final authed = await ref.read(platformProvider).authenticateUser(reason);
      if (!authed) {
        if (mounted) setState(() => _error = denied);
        return;
      }
      final code = await ref.read(zalosAppProvider).exportRecoveryCode();
      if (mounted) setState(() => _code = code);
    } catch (_) {
      if (mounted) setState(() => _error = failed);
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final z = context.z;
    final code = _code;
    return ZDialogScaffold(
      key: const Key('recoveryCodeDialog'),
      title: context.tr('recoveryCode'),
      actions: [
        if (code != null)
          ZButton(
            key: const Key('recoveryCopy'),
            label: context.tr('copyCode'),
            icon: ZIcons.copy,
            variant: ZButtonVariant.secondary,
            onPressed: () => _copy(code),
          ),
        ZButton(
          key: const Key('recoveryClose'),
          label: context.tr('close'),
          variant: code == null ? ZButtonVariant.text : ZButtonVariant.primary,
          onPressed: code == null || _saved ? () => Navigator.pop(context) : null,
        ),
      ],
      child: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Container(
            padding: const EdgeInsets.all(ZSpace.s12),
            decoration: BoxDecoration(color: z.warningBg, borderRadius: BorderRadius.circular(ZRadius.input)),
            child: Row(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Icon(ZIcons.warning, size: 20, color: z.warning, fill: 1),
                const SizedBox(width: ZSpace.s8),
                Expanded(child: Text(context.tr('recoveryWarning'), style: z.text.meta.copyWith(color: z.textPrimary))),
              ],
            ),
          ),
          const SizedBox(height: ZSpace.s12),
          if (code == null)
            ZButton(key: const Key('recoveryReveal'), label: context.tr('recoveryReveal'), icon: ZIcons.eye, variant: ZButtonVariant.secondary, loading: _busy, onPressed: _reveal, expand: true)
          else ...[
            ZCodeGroups(key: const Key('recoveryCodeText'), value: code, size: 15),
            const SizedBox(height: ZSpace.s8),
            ZCheckRow(key: const Key('recoverySaved'), label: context.tr('recoverySavedCheck'), value: _saved, onChanged: (v) => setState(() => _saved = v)),
          ],
          if (_error != null) Padding(padding: const EdgeInsets.only(top: ZSpace.s8), child: Text(_error!, style: z.text.caption.copyWith(color: z.danger))),
          if (_copied)
            Padding(
              padding: const EdgeInsets.only(top: ZSpace.s4),
              child: Text(context.tr('copied'), key: const Key('recoveryCopied'), textAlign: TextAlign.center, style: z.text.caption.copyWith(color: z.success)),
            ),
        ],
      ),
    );
  }
}
