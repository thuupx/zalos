import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:material_ui/material_ui.dart';

import '../../domain/models.dart';
import '../../domain/services.dart';
import '../components/avatar.dart';
import '../components/overlays.dart';
import '../components/pressable.dart';
import '../l10n/strings.dart';
import '../platform/services.dart';
import '../state/app_state.dart';
import '../theme/tokens.dart';
import '../theme/z_icons.dart';
import '../util/haptics.dart';

enum ZaloQrKind { userPhone, userUsername, groupLink, zaloLink, url, text }

@immutable
class ParsedZaloQr {
  const ParsedZaloQr({required this.kind, required this.raw, required this.value});

  final ZaloQrKind kind;
  final String raw;
  final String value;
}

/// Classifies a scanned QR payload into Zalo user/group/link/text categories.
ParsedZaloQr parseZaloQr(String input) {
  final raw = input.trim();
  final uri = Uri.tryParse(raw);
  if (uri != null && (uri.scheme == 'http' || uri.scheme == 'https')) {
    final host = uri.host.toLowerCase();
    final segs = [for (final s in uri.pathSegments) if (s.isNotEmpty) s];
    if (host == 'zalo.me' || host == 'www.zalo.me') {
      if (segs.length >= 2 && segs[0].toLowerCase() == 'g') {
        return ParsedZaloQr(kind: ZaloQrKind.groupLink, raw: raw, value: raw);
      }
      if (segs.length == 1) {
        final target = segs[0];
        if (RegExp(r'^\+?\d{8,15}$').hasMatch(target)) {
          return ParsedZaloQr(kind: ZaloQrKind.userPhone, raw: raw, value: target);
        }
        return ParsedZaloQr(kind: ZaloQrKind.userUsername, raw: raw, value: target);
      }
    }
    if (host == 'zaloapp.com' || host.endsWith('.zaloapp.com') || host.endsWith('.zalo.me')) {
      if (segs.length >= 2 && segs[0] == 'qr' && segs[1] == 'g') {
        return ParsedZaloQr(kind: ZaloQrKind.groupLink, raw: raw, value: raw);
      }
      return ParsedZaloQr(kind: ZaloQrKind.zaloLink, raw: raw, value: raw);
    }
    return ParsedZaloQr(kind: ZaloQrKind.url, raw: raw, value: raw);
  }
  final digits = raw.replaceAll(RegExp(r'[\s\-\(\)]'), '');
  if (RegExp(r'^(\+?84|0)\d{8,10}$').hasMatch(digits)) {
    return ParsedZaloQr(kind: ZaloQrKind.userPhone, raw: raw, value: digits);
  }
  return ParsedZaloQr(kind: ZaloQrKind.text, raw: raw, value: raw);
}

/// Opens the full-screen Zalo QR scanner and handles the scanned payload.
Future<void> openZaloQrScanner(BuildContext context, AccountSession session) async {
  final raw = await Navigator.of(context).push<String>(
    MaterialPageRoute(builder: (_) => const ZaloQrScannerScreen()),
  );
  if (raw == null || raw.trim().isEmpty || !context.mounted) return;
  final parsed = parseZaloQr(raw);
  final rescan = await showZModal<bool>(
    context,
    builder: (_) => _ZaloQrResultSheet(session: session, parsed: parsed),
  );
  if (rescan == true && context.mounted) {
    await openZaloQrScanner(context, session);
  }
}

class ZaloQrScannerScreen extends ConsumerStatefulWidget {
  const ZaloQrScannerScreen({super.key});

  @override
  ConsumerState<ZaloQrScannerScreen> createState() => _ZaloQrScannerScreenState();
}

class _ZaloQrScannerScreenState extends ConsumerState<ZaloQrScannerScreen> {
  final ValueNotifier<bool> _torch = ValueNotifier(false);
  bool _done = false;
  ScannerProblem? _problem;

  @override
  void dispose() {
    _torch.dispose();
    super.dispose();
  }

  void _onCode(String value) {
    final trimmed = value.trim();
    if (_done || trimmed.isEmpty || !mounted) return;
    _done = true;
    ZHaptics.medium();
    Navigator.of(context).pop(trimmed);
  }

  @override
  Widget build(BuildContext context) {
    final z = context.z;
    final platform = ref.watch(platformProvider);
    final white = z.text.label.copyWith(color: ZalosTokens.white);
    final problem = _problem;
    return Scaffold(
      key: const Key('zaloQrScannerScreen'),
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
                  width: 248,
                  height: 248,
                  decoration: BoxDecoration(
                    borderRadius: BorderRadius.circular(ZRadius.sheet),
                    border: Border.all(color: ZalosTokens.white, width: 2),
                    boxShadow: const [
                      BoxShadow(color: ZalosTokens.mediaChip, spreadRadius: 2000),
                    ],
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
                      context.tr(problem == ScannerProblem.permissionDenied
                          ? 'cameraDenied'
                          : 'cameraUnavailable'),
                      key: const Key('zaloScannerProblem'),
                      textAlign: TextAlign.center,
                      style: white,
                    ),
                    if (problem == ScannerProblem.permissionDenied) ...[
                      const SizedBox(height: ZSpace.s16),
                      ZButton(
                        key: const Key('zaloScannerSettings'),
                        label: context.tr('openSettings'),
                        onPressed: platform.openAppSettings,
                      ),
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
                        key: const Key('zaloScannerClose'),
                        icon: ZIcons.close,
                        label: context.tr('close'),
                        color: ZalosTokens.white,
                        hoverColor: ZalosTokens.mediaHover,
                        size: 40,
                        iconSize: 24,
                        onPressed: () => Navigator.of(context).pop(),
                      ),
                      Expanded(
                        child: Text(
                          context.tr('scanZaloQr'),
                          textAlign: TextAlign.center,
                          style: z.text.title.copyWith(color: ZalosTokens.white),
                        ),
                      ),
                      ValueListenableBuilder<bool>(
                        valueListenable: _torch,
                        builder: (context, on, _) => ZIconButton(
                          key: const Key('zaloScannerTorch'),
                          icon: on ? ZIcons.flashOff : ZIcons.flashOn,
                          label: context.tr('torch'),
                          color: ZalosTokens.white,
                          hoverColor: ZalosTokens.mediaHover,
                          size: 40,
                          iconSize: 24,
                          onPressed: problem == null
                              ? () {
                                  ZHaptics.selection();
                                  _torch.value = !on;
                                }
                              : null,
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
                      padding: const EdgeInsets.symmetric(
                        horizontal: ZSpace.s16,
                        vertical: ZSpace.s8,
                      ),
                      decoration: BoxDecoration(
                        color: ZalosTokens.viewerBar,
                        borderRadius: BorderRadius.circular(ZRadius.card),
                      ),
                      child: Text(
                        context.tr('scanZaloHint'),
                        key: const Key('zaloScanHint'),
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

class _ZaloQrResultSheet extends ConsumerStatefulWidget {
  const _ZaloQrResultSheet({required this.session, required this.parsed});

  final AccountSession session;
  final ParsedZaloQr parsed;

  @override
  ConsumerState<_ZaloQrResultSheet> createState() => _ZaloQrResultSheetState();
}

class _ZaloQrResultSheetState extends ConsumerState<_ZaloQrResultSheet> {
  bool _loading = false;
  bool _busy = false;
  UserProfile? _profile;
  FriendRequestStatus? _status;
  LinkPreview? _preview;

  @override
  void initState() {
    super.initState();
    _resolve();
  }

  Future<void> _resolve() async {
    final p = widget.parsed;
    if (p.kind == ZaloQrKind.userPhone || p.kind == ZaloQrKind.userUsername) {
      setState(() => _loading = true);
      try {
        final user = p.kind == ZaloQrKind.userPhone
            ? await widget.session.findUserByPhone(p.value)
            : await widget.session.findUserByUsername(p.value);
        FriendRequestStatus? status;
        if (user != null) {
          try {
            status = await widget.session.friendRequestStatus(user.uid);
          } catch (_) {}
        }
        if (mounted) {
          setState(() {
            _profile = user;
            _status = status;
            _loading = false;
          });
        }
      } catch (_) {
        if (mounted) setState(() => _loading = false);
      }
      return;
    }
    if (p.kind == ZaloQrKind.groupLink ||
        p.kind == ZaloQrKind.zaloLink ||
        p.kind == ZaloQrKind.url) {
      setState(() => _loading = true);
      try {
        final preview = await widget.session.parseLink(p.raw);
        if (mounted) {
          setState(() {
            _preview = preview;
            _loading = false;
          });
        }
      } catch (_) {
        if (mounted) setState(() => _loading = false);
      }
    }
  }

  Future<void> _sendFriendRequest(UserProfile user) async {
    if (_busy) return;
    setState(() => _busy = true);
    try {
      await widget.session.sendFriendRequest(user.uid, message: '');
      final next = await widget.session.friendRequestStatus(user.uid);
      if (!mounted) return;
      ZHaptics.light();
      setState(() => _status = next);
      zToast(context, context.tr('friendRequestSent'));
    } catch (_) {
      if (mounted) zToast(context, context.tr('friendRequestSendFailed'));
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  void _openChat(UserProfile user) {
    Navigator.of(context).pop(false);
    openThread(
      ref,
      OpenThread(
        slot: widget.session.slot,
        id: user.uid,
        type: ThreadType.user,
        name: user.displayName,
        avatarUrl: user.avatarUrl,
      ),
    );
  }

  Future<void> _openUrl(String url) async {
    final opened = await ref.read(platformProvider).openUrl(url);
    if (!mounted) return;
    if (!opened) {
      await Clipboard.setData(ClipboardData(text: url));
      if (mounted) zToast(context, context.tr('linkCopied'));
    } else {
      Navigator.of(context).pop(false);
    }
  }

  Future<void> _copy(String value) async {
    await Clipboard.setData(ClipboardData(text: value));
    ZHaptics.light();
    if (mounted) zToast(context, context.tr('copied'));
  }

  @override
  Widget build(BuildContext context) {
    final z = context.z;
    final p = widget.parsed;
    final isLink = p.kind == ZaloQrKind.groupLink ||
        p.kind == ZaloQrKind.zaloLink ||
        p.kind == ZaloQrKind.url;
    final profile = _profile;
    final status = _status;
    final preview = _preview;

    final Widget content;
    final List<Widget> actions = [
      ZButton(
        key: const Key('qrScanAgain'),
        label: context.tr('scanAgain'),
        variant: ZButtonVariant.text,
        onPressed: () => Navigator.of(context).pop(true),
      ),
    ];

    if (_loading) {
      content = Padding(
        padding: const EdgeInsets.symmetric(vertical: ZSpace.s24),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            const SizedBox(
              width: 24,
              height: 24,
              child: CircularProgressIndicator(strokeWidth: 2),
            ),
            const SizedBox(height: ZSpace.s12),
            Text(
              context.tr(p.kind == ZaloQrKind.userPhone ||
                      p.kind == ZaloQrKind.userUsername
                  ? 'scanFindingUser'
                  : 'loading'),
              style: z.text.rowSub,
            ),
          ],
        ),
      );
    } else if (profile != null) {
      content = Column(
        key: const Key('qrUserResult'),
        mainAxisSize: MainAxisSize.min,
        children: [
          ZAvatar(
            session: widget.session,
            id: profile.uid,
            name: profile.displayName,
            url: profile.avatarUrl,
            size: 72,
          ),
          const SizedBox(height: ZSpace.s12),
          Text(profile.displayName, textAlign: TextAlign.center, style: z.text.title),
          if (profile.zaloName != null &&
              profile.zaloName!.isNotEmpty &&
              profile.zaloName != profile.displayName)
            Text(profile.zaloName!, textAlign: TextAlign.center, style: z.text.rowSub),
        ],
      );
      if (status != null && !status.isFriend && !status.isRequested && !status.isRequesting) {
        actions.add(
          ZButton(
            key: const Key('qrAddFriend'),
            label: context.tr('sendRequest'),
            variant: ZButtonVariant.secondary,
            loading: _busy,
            onPressed: () => _sendFriendRequest(profile),
          ),
        );
      }
      actions.add(
        ZButton(
          key: const Key('qrOpenChat'),
          label: context.tr('sendMessage'),
          icon: ZIcons.chat,
          onPressed: () => _openChat(profile),
        ),
      );
    } else {
      content = Column(
        key: const Key('qrGenericResult'),
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          if (p.kind == ZaloQrKind.groupLink) ...[
            Row(
              children: [
                Icon(ZIcons.groups, size: 22, color: z.brandText),
                const SizedBox(width: ZSpace.s8),
                Expanded(
                  child: Text(
                    preview?.title.isNotEmpty == true
                        ? preview!.title
                        : context.tr('scanGroupLink'),
                    style: z.text.rowTitleUnread,
                  ),
                ),
              ],
            ),
            const SizedBox(height: ZSpace.s4),
            Text(
              preview?.description.isNotEmpty == true
                  ? preview!.description
                  : context.tr('scanGroupHint'),
              style: z.text.rowSub,
            ),
            const SizedBox(height: ZSpace.s12),
          ] else if (preview != null && preview.title.isNotEmpty) ...[
            Text(preview.title, style: z.text.rowTitleUnread),
            if (preview.description.isNotEmpty) ...[
              const SizedBox(height: ZSpace.s4),
              Text(preview.description, maxLines: 3, overflow: TextOverflow.ellipsis, style: z.text.rowSub),
            ],
            const SizedBox(height: ZSpace.s12),
          ],
          Container(
            padding: const EdgeInsets.all(ZSpace.s12),
            decoration: BoxDecoration(
              color: z.layerSubtle,
              borderRadius: BorderRadius.circular(ZRadius.input),
              border: Border.all(color: z.divider),
            ),
            child: SelectableText(p.raw, style: z.text.meta.copyWith(color: z.textPrimary)),
          ),
        ],
      );
      actions.add(
        ZButton(
          key: const Key('qrCopy'),
          label: context.tr('copy'),
          variant: isLink ? ZButtonVariant.secondary : ZButtonVariant.primary,
          icon: ZIcons.copy,
          onPressed: () => _copy(p.raw),
        ),
      );
      if (isLink) {
        actions.add(
          ZButton(
            key: const Key('qrOpenLink'),
            label: context.tr('scanOpenLink'),
            icon: ZIcons.openInNew,
            onPressed: () => _openUrl(p.raw),
          ),
        );
      }
    }

    return ZDialogScaffold(
      key: const Key('zaloQrResultSheet'),
      title: context.tr('scanResultTitle'),
      showClose: true,
      actions: actions,
      child: content,
    );
  }
}
