import 'package:material_ui/material_ui.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../domain/models.dart';
import '../../domain/services.dart';
import '../components/basics.dart';
import '../components/fields.dart';
import '../components/overlays.dart';
import '../components/pressable.dart';
import '../l10n/strings.dart';
import '../platform/services.dart';
import '../state/app_state.dart';
import '../theme/tokens.dart';
import '../theme/z_icons.dart';
import 'login_qr_dialog.dart';

const String zaloDevelopersUrl = 'https://developers.zalo.me/tools/explorer';

/// Small "OA" tag for Official Accounts.
class OaTag extends StatelessWidget {
  const OaTag({super.key});

  @override
  Widget build(BuildContext context) {
    final z = context.z;
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: ZSpace.s4, vertical: 1),
      decoration: BoxDecoration(color: z.warningBg, borderRadius: BorderRadius.circular(ZRadius.tight)),
      child: Text('OA', textScaler: TextScaler.noScaling, style: z.text.captionStrong.copyWith(color: z.dark ? z.accentText : z.textPrimary)),
    );
  }
}

/// Chooser between a personal account (QR login) and an Official Account.
Future<void> showAddAccount(BuildContext context, ServerLink link) async {
  final choice = await showZModal<String>(
    context,
    builder: (context) => ZDialogScaffold(
      key: const Key('addAccountChooser'),
      title: context.tr('addAccount'),
      showClose: true,
      padBody: false,
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          ZRow(key: const Key('addPersonal'), icon: ZIcons.qrCode, title: context.tr('accountPersonal'), onTap: () => Navigator.pop(context, 'personal')),
          ZRow(key: const Key('addOa'), icon: ZIcons.storefront, title: context.tr('accountOa'), onTap: () => Navigator.pop(context, 'oa')),
          const SizedBox(height: ZSpace.s8),
        ],
      ),
    ),
  );
  if (!context.mounted) return;
  if (choice == 'personal') {
    await showLoginQrDialog(context, link);
  } else if (choice == 'oa') {
    await showZModal<void>(context, builder: (_) => OaDialog(link: link));
  }
}

Future<void> showOaTokens(BuildContext context, ServerLink link, String slot) =>
    showZModal<void>(context, builder: (_) => OaDialog(link: link, slot: slot));

/// Adds an Official Account, or with [slot] replaces the tokens of one.
class OaDialog extends ConsumerStatefulWidget {
  const OaDialog({super.key, required this.link, this.slot});

  final ServerLink link;
  final String? slot;

  @override
  ConsumerState<OaDialog> createState() => _OaDialogState();
}

class _OaDialogState extends ConsumerState<OaDialog> {
  final _appId = TextEditingController();
  final _secret = TextEditingController();
  final _access = TextEditingController();
  final _refresh = TextEditingController();
  final Set<String> _revealed = {};
  bool _busy = false;
  bool _validate = false;
  String? _error;

  bool get _update => widget.slot != null;

  @override
  void dispose() {
    _appId.dispose();
    _secret.dispose();
    _access.dispose();
    _refresh.dispose();
    super.dispose();
  }

  Future<void> _submit() async {
    final fields = _update ? [_access, _refresh] : [_appId, _secret, _access, _refresh];
    if (fields.any((c) => c.text.trim().isEmpty)) {
      setState(() => _validate = true);
      return;
    }
    final fallback = context.tr('oaAddFailed');
    final navigator = Navigator.of(context);
    setState(() {
      _busy = true;
      _error = null;
    });
    try {
      if (_update) {
        await widget.link.updateOaTokens(widget.slot!, accessToken: _access.text.trim(), refreshToken: _refresh.text.trim());
      } else {
        final slot = await widget.link.addOaAccount(
          OaCredentials(appId: _appId.text.trim(), appSecret: _secret.text.trim(), accessToken: _access.text.trim(), refreshToken: _refresh.text.trim()),
        );
        ref.read(preferredSlotProvider.notifier).set(slot);
        ref.read(openThreadProvider.notifier).state = null;
        ref.read(homeTabProvider.notifier).state = HomeTab.messages;
      }
      if (mounted) navigator.pop();
    } catch (e) {
      final text = '$e'.replaceFirst(RegExp(r'^(Bad state|Exception|[A-Za-z]+Exception): '), '').trim();
      if (mounted) setState(() => _error = text.isEmpty ? fallback : '$fallback: $text');
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  Widget _field(String id, TextEditingController c, String label, {bool secret = false}) {
    final shown = !secret || _revealed.contains(id);
    return Padding(
      padding: const EdgeInsets.only(bottom: ZSpace.s12),
      child: ZTextField(
        key: Key('oa-$id'),
        controller: c,
        label: label,
        hint: label,
        enabled: !_busy,
        obscure: !shown,
        autocorrect: false,
        mono: true,
        errorText: _validate && c.text.trim().isEmpty ? context.tr('oaRequired') : null,
        suffix: secret
            ? ZIconButton(
                key: Key('oaReveal-$id'),
                icon: shown ? ZIcons.eyeOff : ZIcons.eye,
                label: '${context.tr(shown ? 'hide' : 'show')} $label',
                onPressed: () => setState(() => shown ? _revealed.remove(id) : _revealed.add(id)),
              )
            : null,
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final z = context.z;
    return ZDialogScaffold(
      key: const Key('oaDialog'),
      title: context.tr(_update ? 'oaUpdateTokens' : 'accountOa'),
      actions: [
        ZButton(label: context.tr('cancel'), variant: ZButtonVariant.text, onPressed: _busy ? null : () => Navigator.pop(context)),
        ZButton(key: const Key('oaSubmit'), label: context.tr(_update ? 'save' : 'add'), loading: _busy, onPressed: _submit),
      ],
      child: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Text(context.tr('oaHelp'), style: z.text.rowSub.copyWith(color: z.textSecondary)),
          Align(
            alignment: Alignment.centerLeft,
            child: ZButton(
              key: const Key('oaDocs'),
              label: context.tr('oaOpenDocs'),
              icon: ZIcons.openInNew,
              variant: ZButtonVariant.text,
              small: true,
              onPressed: () => ref.read(platformProvider).openUrl(zaloDevelopersUrl),
            ),
          ),
          const SizedBox(height: ZSpace.s8),
          if (!_update) _field('appId', _appId, context.tr('oaAppId')),
          if (!_update) _field('secret', _secret, context.tr('oaAppSecret'), secret: true),
          _field('access', _access, context.tr('oaAccessToken'), secret: true),
          _field('refresh', _refresh, context.tr('oaRefreshToken'), secret: true),
          if (_error != null)
            ClipRRect(
              borderRadius: BorderRadius.circular(ZRadius.input),
              child: ZBanner(key: const Key('oaError'), text: _error!, tone: ZTone.danger, icon: ZIcons.error),
            ),
        ],
      ),
    );
  }
}
