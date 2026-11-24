import 'dart:async';
import 'dart:ui' as ui;

import 'package:material_ui/material_ui.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:qr_flutter/qr_flutter.dart';

import '../../domain/models.dart';
import '../../domain/services.dart';
import '../components/basics.dart';
import '../components/overlays.dart';
import '../components/pressable.dart';
import '../l10n/strings.dart';
import '../platform/services.dart';
import '../state/app_state.dart';
import '../theme/tokens.dart';
import '../theme/z_icons.dart';
import '../util/format.dart';
import '../vault/vault_screens.dart';

/// Opens the devices list as a page on phones and as a dialog on wide layouts.
Future<void> openDevicesPage(BuildContext context, ServerLink link) {
  if (LayoutScope.of(context) == LayoutClass.compact) {
    final strings = context.s;
    return Navigator.of(context).push<void>(MaterialPageRoute(
      builder: (_) => StringsScope(strings: strings, child: LayoutScope(layout: LayoutClass.compact, child: Scaffold(body: DevicesPage(link: link)))),
    ));
  }
  return showZModal<void>(context, maxWidth: 520, builder: (_) => SizedBox(height: 640, child: DevicesPage(link: link)));
}

IconData deviceGlyph(String name) {
  final n = name.toLowerCase();
  if (n.contains('iphone') || n.contains('android') || n.contains('phone') || n.contains('điện thoại')) return ZIcons.smartphone;
  if (n.contains('ipad') || n.contains('tab')) return ZIcons.tablet;
  if (n.contains('mac') || n.contains('book') || n.contains('laptop')) return ZIcons.laptop;
  if (n.contains('chrome') || n.contains('web') || n.contains('trình duyệt') || n.contains('firefox') || n.contains('safari')) return ZIcons.globe;
  if (n.contains('windows') || n.contains('pc') || n.contains('linux')) return ZIcons.desktop;
  return ZIcons.devices;
}

class DevicesPage extends ConsumerStatefulWidget {
  const DevicesPage({super.key, required this.link});

  final ServerLink link;

  @override
  ConsumerState<DevicesPage> createState() => _DevicesPageState();
}

class _DevicesPageState extends ConsumerState<DevicesPage> {
  List<DeviceInfo>? _devices;
  bool _failed = false;
  final Set<String> _busy = {};
  String? _aclOpen;
  Set<String> _aclDraft = {};

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    try {
      final list = await widget.link.listDevices();
      if (mounted) {
        setState(() {
          _devices = list;
          _failed = false;
        });
      }
    } catch (_) {
      if (mounted) setState(() => _failed = true);
    }
  }

  Future<void> _mutate(String deviceId, Future<void> Function() action) async {
    final failed = context.tr('actionFailed');
    setState(() => _busy.add(deviceId));
    try {
      await action();
      await _load();
    } catch (_) {
      if (mounted) zToast(context, failed);
    } finally {
      if (mounted) setState(() => _busy.remove(deviceId));
    }
  }

  Future<void> _revoke(DeviceInfo d, {required bool lastAdmin}) async {
    if (lastAdmin) {
      await showZModal<void>(
        context,
        builder: (context) => ZDialogScaffold(
          key: const Key('lastAdminDialog'),
          title: context.tr('lastAdminTitle'),
          actions: [ZButton(label: context.tr('close'), onPressed: () => Navigator.pop(context))],
          child: Text(context.tr('lastAdminBody'), style: context.z.text.body.copyWith(color: context.z.textSecondary)),
        ),
      );
      return;
    }
    final ok = await zConfirm(context, title: context.tr('revokeTitle', [d.name]), message: context.tr('revokeBody'), confirmLabel: context.tr('revoke'));
    if (!ok || !mounted) return;
    final authed = await ref.read(platformProvider).authenticateUser(context.tr('authRequiredReason'));
    if (!authed) {
      if (mounted) zToast(context, context.tr('authDenied'));
      return;
    }
    if (mounted) await _mutate(d.id, () => widget.link.revokeDevice(d.id));
  }

  Future<void> _openAddDevice() async {
    final authed = await ref.read(platformProvider).authenticateUser(context.tr('authRequiredReason'));
    if (!authed) {
      if (mounted) zToast(context, context.tr('authDenied'));
      return;
    }
    if (!mounted) return;
    await showAddDeviceDialog(context, widget.link);
    if (mounted) await _load();
  }

  @override
  Widget build(BuildContext context) {
    final z = context.z;
    final wide = LayoutScope.wideOf(context);
    final manifest = ref.watch(manifestProvider);
    final admin = ref.watch(isAdminProvider);
    final devices = _devices?.where((d) => !d.revoked).toList();
    final adminCount = devices?.where((d) => d.role == DeviceRole.admin).length ?? 0;

    final title = Row(
      children: [
        if (!wide) ZIconButton(key: const Key('devicesBack'), icon: ZIcons.back, label: context.tr('back'), color: z.textOnBrand, hoverColor: z.headerField, iconSize: 24, onPressed: () => Navigator.of(context).pop()) else const SizedBox(width: ZSpace.s16),
        Expanded(child: Semantics(header: true, child: Text(context.tr('linkedDevices'), maxLines: 1, overflow: TextOverflow.ellipsis, style: z.text.title.copyWith(color: wide ? z.textPrimary : z.textOnBrand)))),
        if (admin)
          ZIconButton(
            key: const Key('devicesAdd'),
            icon: ZIcons.link,
            label: context.tr('addDevice'),
            color: wide ? null : z.textOnBrand,
            hoverColor: wide ? null : z.headerField,
            onPressed: _openAddDevice,
          ),
        if (wide) ZIconButton(key: const Key('devicesClose'), icon: ZIcons.close, label: context.tr('close'), onPressed: () => Navigator.of(context).pop()),
        const SizedBox(width: ZSpace.s8),
      ],
    );

    final Widget body;
    if (_failed && devices == null) {
      body = ZErrorState(key: const Key('devicesError'), title: context.tr('loadFailed'), retryLabel: context.tr('retry'), onRetry: _load);
    } else if (devices == null || manifest == null) {
      body = ZSkeletonList(key: const Key('devicesLoading'), count: 4, avatar: 40, rowHeight: 64, label: context.tr('loading'));
    } else {
      body = ListView(
        key: const Key('devicesList'),
        padding: const EdgeInsets.only(bottom: ZSpace.s16),
        children: [
          VaultRequestCards(link: widget.link),
          const SizedBox(height: ZSpace.s12),
          if (devices.isEmpty) Padding(padding: const EdgeInsets.all(ZSpace.s24), child: ZEmptyState(icon: ZIcons.devices, title: context.tr('noDevices'))),
          for (final d in devices)
            _DeviceCard(
              key: Key('device-${d.id}'),
              device: d,
              self: d.id == manifest.deviceId,
              admin: admin,
              busy: _busy.contains(d.id),
              accounts: manifest.accounts,
              aclOpen: _aclOpen == d.id,
              aclDraft: _aclDraft,
              onToggleAcl: () => setState(() {
                if (_aclOpen == d.id) {
                  _aclOpen = null;
                } else {
                  _aclOpen = d.id;
                  _aclDraft = d.slots.toSet();
                }
              }),
              onAclChanged: (slot, v) => setState(() => v ? _aclDraft.add(slot) : _aclDraft.remove(slot)),
              onSaveAcl: () async {
                final slots = _aclDraft.toList();
                await _mutate(d.id, () => widget.link.setDeviceAcl(d.id, slots));
                if (mounted) setState(() => _aclOpen = null);
              },
              onRevoke: () => _revoke(d, lastAdmin: d.role == DeviceRole.admin && adminCount <= 1),
            ),
        ],
      );
    }
    return Material(
      key: const Key('devicesPage'),
      color: z.layerSubtle,
      child: Column(
        children: [
          if (wide) Container(height: ZSizes.wideChatHeader, color: z.layer, child: title) else ZPhoneHeader(child: title),
          Expanded(child: body),
        ],
      ),
    );
  }
}

class _DeviceCard extends StatelessWidget {
  const _DeviceCard({
    super.key,
    required this.device,
    required this.self,
    required this.admin,
    required this.busy,
    required this.accounts,
    required this.aclOpen,
    required this.aclDraft,
    required this.onToggleAcl,
    required this.onAclChanged,
    required this.onSaveAcl,
    required this.onRevoke,
  });

  final DeviceInfo device;
  final bool self;
  final bool admin;
  final bool busy;
  final List<AccountSummary> accounts;
  final bool aclOpen;
  final Set<String> aclDraft;
  final VoidCallback onToggleAcl;
  final void Function(String slot, bool value) onAclChanged;
  final VoidCallback onSaveAcl;
  final VoidCallback onRevoke;

  @override
  Widget build(BuildContext context) {
    final z = context.z;
    final d = device;
    final changed = aclOpen && (aclDraft.length != d.slots.length || !aclDraft.containsAll(d.slots));
    return Padding(
      padding: const EdgeInsets.only(bottom: ZSpace.s8),
      child: ZCard(
        padding: const EdgeInsets.all(ZSpace.s12),
        children: [
          Row(
            children: [
              Container(
                width: 40,
                height: 40,
                decoration: BoxDecoration(color: z.layerSubtle, shape: BoxShape.circle),
                child: Icon(deviceGlyph(d.name), size: 22, color: z.textSecondary),
              ),
              const SizedBox(width: ZSpace.s12),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(d.name, maxLines: 1, overflow: TextOverflow.ellipsis, style: z.text.rowTitle),
                    Text(
                      self ? context.tr('thisDevice') : context.tr('lastSeen', [formatRelative(d.lastSeenAt, context.s)]),
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: z.text.caption.copyWith(color: self ? z.success : z.textTertiary),
                    ),
                  ],
                ),
              ),
              const SizedBox(width: ZSpace.s8),
              ZChip(label: context.tr(d.role == DeviceRole.admin ? 'roleAdmin' : 'roleMember'), tone: d.role == DeviceRole.admin ? ZTone.info : ZTone.neutral),
            ],
          ),
          if (admin) ...[
            const SizedBox(height: ZSpace.s8),
            Wrap(
              spacing: ZSpace.s8,
              runSpacing: ZSpace.s4,
              children: [
                ZButton(key: Key('deviceAcl-${d.id}'), label: context.tr('accountAccess'), icon: ZIcons.manageAccounts, variant: ZButtonVariant.text, small: true, onPressed: busy ? null : onToggleAcl),
                if (!self) ZButton(key: Key('deviceRevoke-${d.id}'), label: context.tr('revoke'), icon: ZIcons.block, variant: ZButtonVariant.destructiveText, small: true, onPressed: busy ? null : onRevoke),
              ],
            ),
          ],
          if (aclOpen) ...[
            Container(height: 1, color: z.divider, margin: const EdgeInsets.symmetric(vertical: ZSpace.s8)),
            if (accounts.isEmpty) Text(context.tr('noAccounts'), style: z.text.rowSub),
            for (final a in accounts)
              ZCheckRow(key: Key('acl-${d.id}-${a.slot}'), label: a.displayName, value: aclDraft.contains(a.slot), onChanged: busy ? null : (v) => onAclChanged(a.slot, v), dense: true),
            const SizedBox(height: ZSpace.s8),
            Align(
              alignment: Alignment.centerRight,
              child: ZButton(key: Key('aclSave-${d.id}'), label: context.tr('save'), small: true, loading: busy, onPressed: changed ? onSaveAcl : null),
            ),
          ],
        ],
      ),
    );
  }
}

Future<void> showAddDeviceDialog(BuildContext context, ServerLink link) => showZModal<void>(context, builder: (_) => AddDeviceDialog(link: link));

class AddDeviceDialog extends StatefulWidget {
  const AddDeviceDialog({super.key, required this.link});

  final ServerLink link;

  @override
  State<AddDeviceDialog> createState() => _AddDeviceDialogState();
}

class _AddDeviceDialogState extends State<AddDeviceDialog> {
  static const Duration clipboardTtl = Duration(seconds: 60);

  DeviceRole _role = DeviceRole.member;
  PairingOffer? _offer;
  bool _failed = false;
  bool _copied = false;
  Timer? _ticker;
  Timer? _clipboardTimer;
  String? _copiedUri;
  int _generation = 0;

  @override
  void initState() {
    super.initState();
    _create();
  }

  @override
  void dispose() {
    _ticker?.cancel();
    if (_clipboardTimer?.isActive ?? false) {
      _clipboardTimer!.cancel();
      _clearClipboard();
    }
    super.dispose();
  }

  Future<void> _clearClipboard() async {
    final uri = _copiedUri;
    if (uri == null) return;
    try {
      final current = await Clipboard.getData(Clipboard.kTextPlain);
      if (current?.text == uri) await Clipboard.setData(const ClipboardData(text: ''));
    } catch (_) {}
  }

  Future<void> _create() async {
    final generation = ++_generation;
    _ticker?.cancel();
    setState(() {
      _offer = null;
      _failed = false;
      _copied = false;
    });
    try {
      final offer = await widget.link.createPairing(role: _role);
      if (!mounted || generation != _generation) return;
      setState(() => _offer = offer);
      _ticker = Timer.periodic(const Duration(seconds: 1), (_) {
        if (mounted) setState(() {});
      });
    } catch (_) {
      if (mounted && generation == _generation) setState(() => _failed = true);
    }
  }

  Future<void> _copy(String uri) async {
    await Clipboard.setData(ClipboardData(text: uri));
    _copiedUri = uri;
    _clipboardTimer?.cancel();
    _clipboardTimer = Timer(clipboardTtl, _clearClipboard);
    if (mounted) setState(() => _copied = true);
  }

  @override
  Widget build(BuildContext context) {
    final z = context.z;
    final offer = _offer;
    final remainingMs = offer == null ? 0 : offer.expiresAt - ZClock.nowMs();
    final expired = offer != null && remainingMs <= 0;
    if (expired) _ticker?.cancel();
    return ZDialogScaffold(
      key: const Key('addDeviceDialog'),
      title: context.tr('addDevice'),
      showClose: true,
      actions: [
        if (expired || _failed)
          ZButton(key: const Key('pairingNewCode'), label: context.tr('newCode'), icon: ZIcons.refresh, onPressed: _create)
        else
          ZButton(key: const Key('copyPairingUri'), label: context.tr('copyCode'), icon: ZIcons.copy, variant: ZButtonVariant.secondary, onPressed: offer == null ? null : () => _copy(offer.uri)),
      ],
      child: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          ZSegmented<DeviceRole>(
            key: const Key('pairingRole'),
            segments: [(DeviceRole.member, context.tr('roleMember')), (DeviceRole.admin, context.tr('roleAdmin'))],
            selected: _role,
            onChanged: (v) {
              _role = v;
              _create();
            },
          ),
          const SizedBox(height: ZSpace.s4),
          Text(context.tr(_role == DeviceRole.admin ? 'roleAdminHint' : 'roleMemberHint'), textAlign: TextAlign.center, style: z.text.caption),
          const SizedBox(height: ZSpace.s12),
          Center(
            child: Container(
              width: 236,
              height: 236,
              padding: const EdgeInsets.all(ZSpace.s8),
              decoration: BoxDecoration(color: ZalosTokens.white, borderRadius: BorderRadius.circular(ZRadius.card), border: Border.all(color: z.border)),
              alignment: Alignment.center,
              child: _failed
                  ? Text(context.tr('loadFailed'), key: const Key('pairingFailed'), textAlign: TextAlign.center, style: z.text.caption.copyWith(color: ZalosTokens.light.danger))
                  : offer == null
                      ? const ZSkeleton(key: Key('pairingSkeleton'), width: 220, height: 220, radius: ZRadius.input)
                      : ImageFiltered(
                          enabled: expired,
                          imageFilter: ui.ImageFilter.blur(sigmaX: 6, sigmaY: 6),
                          child: QrImageView(
                            key: const Key('pairingQr'),
                            data: offer.uri,
                            size: 220,
                            padding: EdgeInsets.zero,
                            backgroundColor: ZalosTokens.white,
                            semanticsLabel: context.tr('pairingQrLabel'),
                          ),
                        ),
            ),
          ),
          const SizedBox(height: ZSpace.s8),
          if (offer != null)
            Text(
              expired ? context.tr('pairingExpired') : context.tr('pairingExpiresIn', [formatDuration(remainingMs)]),
              key: const Key('pairingCountdown'),
              textAlign: TextAlign.center,
              style: z.text.captionStrong.copyWith(color: expired ? z.danger : z.textSecondary),
            ),
          const SizedBox(height: ZSpace.s8),
          Container(
            key: const Key('pairingSecretWarning'),
            padding: const EdgeInsets.all(ZSpace.s8),
            decoration: BoxDecoration(color: z.warningBg, borderRadius: BorderRadius.circular(ZRadius.input)),
            child: Row(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Icon(ZIcons.warning, size: 18, color: z.warning, fill: 1),
                const SizedBox(width: ZSpace.s8),
                Expanded(child: Text(context.tr('pairingSecretWarning'), style: z.text.caption.copyWith(color: z.textPrimary))),
              ],
            ),
          ),
          Padding(
            padding: const EdgeInsets.only(top: ZSpace.s8),
            child: Text(
              context.tr(_copied ? 'pairingCopied' : 'pairingCopyHint'),
              key: Key(_copied ? 'pairingCopied' : 'pairingCopyHint'),
              textAlign: TextAlign.center,
              style: z.text.caption.copyWith(color: _copied ? z.success : z.textTertiary),
            ),
          ),
        ],
      ),
    );
  }
}
