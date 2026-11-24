// Phase D: Zalo companion sessions. Read only, and only the safe display
// fields: name, platform, last update and the value-free summary.
import 'package:material_ui/material_ui.dart';

import '../../domain/models.dart';
import '../../domain/services.dart';
import '../components/basics.dart';
import '../components/overlays.dart';
import '../l10n/strings.dart';
import '../theme/tokens.dart';
import '../theme/z_icons.dart';
import '../util/format.dart';
import 'devices_page.dart' show deviceGlyph;

Future<void> showZaloDevices(BuildContext context, {required AccountSession session, required bool supported}) =>
    showZModal<void>(context, maxWidth: 480, builder: (_) => ZaloDevicesSheet(session: session, supported: supported));

String? platformLabel(String? platform) {
  final value = platform?.trim() ?? '';
  if (value.isEmpty) return null;
  final lower = value.toLowerCase();
  if (lower.contains('ios') || lower.contains('iphone')) return 'iOS';
  if (lower.contains('android')) return 'Android';
  if (lower.contains('windows')) return 'Windows';
  if (lower.contains('mac')) return 'macOS';
  if (lower.contains('web') || lower.contains('chrome')) return 'Web';
  return value;
}

class ZaloDevicesSheet extends StatefulWidget {
  const ZaloDevicesSheet({super.key, required this.session, required this.supported});

  final AccountSession session;
  final bool supported;

  @override
  State<ZaloDevicesSheet> createState() => _ZaloDevicesSheetState();
}

class _ZaloDevicesSheetState extends State<ZaloDevicesSheet> {
  LinkedDevices? _devices;
  bool _loading = false;
  bool _failed = false;

  @override
  void initState() {
    super.initState();
    if (widget.supported) _load();
  }

  Future<void> _load() async {
    setState(() {
      _loading = true;
      _failed = false;
    });
    try {
      final devices = await widget.session.linkedDevices();
      if (!mounted) return;
      setState(() {
        _devices = devices;
        _loading = false;
      });
    } catch (_) {
      if (!mounted) return;
      setState(() {
        _failed = true;
        _loading = false;
      });
    }
  }

  LinkedDeviceCompanion? _first(bool Function(LinkedDeviceCompanion) test, List<LinkedDeviceCompanion> list) {
    for (final device in list) {
      if (test(device)) return device;
    }
    return null;
  }

  Widget _deviceRow(LinkedDeviceCompanion device, LinkedDevices devices, {required String key}) {
    final name = device.name?.trim().isNotEmpty == true ? device.name! : context.tr('zaloDevicesUnknown');
    final platform = platformLabel(device.platform);
    final updated = device.lastUpdateTs == null ? null : context.tr('zaloDevicesLastUpdate', [formatRelative(device.lastUpdateTs, context.s)]);
    final summary = device.summary?.trim().isNotEmpty == true ? device.summary! : null;
    final subtitle = [platform, updated, summary].whereType<String>().where((part) => part.isNotEmpty).join(' · ');
    final master = device.id != null && device.id == devices.masterId;
    final chip = device.current && master
        ? '${context.tr('zaloDevicesMaster')} · ${context.tr('zaloDevicesCurrent')}'
        : device.current
            ? context.tr('zaloDevicesCurrent')
            : master
                ? context.tr('zaloDevicesMaster')
                : null;
    return ZRow(
      key: Key(key),
      icon: deviceGlyph('$name ${platform ?? ''}'),
      title: name,
      subtitle: subtitle.isEmpty ? context.tr('zaloDevicesSummary') : subtitle,
      trailing: chip == null ? null : ZChip(label: chip, tone: device.current ? ZTone.info : ZTone.warning),
    );
  }

  Widget _body() {
    final z = context.z;
    if (!widget.supported) {
      return ZEmptyState(
        key: const Key('zaloDevicesUnsupported'),
        icon: ZIcons.devices,
        title: context.tr('zaloDevicesUnsupported'),
        subtitle: context.tr('zaloDevicesUnsupportedHint'),
      );
    }
    if (_loading) {
      return const Column(
        key: Key('zaloDevicesLoading'),
        children: [ZSkeletonRow(avatar: 40, height: 56), ZSkeletonRow(avatar: 40, height: 56), ZSkeletonRow(avatar: 40, height: 56)],
      );
    }
    if (_failed) {
      return ZErrorState(
        key: const Key('zaloDevicesError'),
        title: context.tr('zaloDevicesFailed'),
        retryLabel: context.tr('retry'),
        onRetry: _load,
      );
    }
    final devices = _devices;
    if (devices == null) return const SizedBox.shrink();
    final companions = [...devices.companions]
      ..sort((a, b) {
        if (a.current != b.current) return a.current ? -1 : 1;
        return (b.lastUpdateTs ?? 0).compareTo(a.lastUpdateTs ?? 0);
      });
    if (companions.isEmpty) {
      return ZEmptyState(
        key: const Key('zaloDevicesEmpty'),
        icon: ZIcons.devices,
        title: context.tr('zaloDevicesEmpty'),
        subtitle: context.tr('zaloDevicesEmptyHint'),
      );
    }
    final current = _first((device) => device.current, companions);
    final master = _first((device) => device.id != null && device.id == devices.masterId, companions);
    final rest = [for (final device in companions) if (!identical(device, current) && !identical(device, master)) device];
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      mainAxisSize: MainAxisSize.min,
      children: [
        if (master != null)
          _deviceRow(master, devices, key: 'zaloDevice-${master.id ?? 'master'}')
        else
          ZRow(
            key: const Key('zaloDevice-masterUnknown'),
            icon: ZIcons.devices,
            title: context.tr('zaloDevicesMaster'),
            subtitle: context.tr('zaloDevicesMasterUnknown'),
          ),
        if (current != null && !identical(current, master))
          _deviceRow(current, devices, key: 'zaloDevice-${current.id ?? 'current'}'),
        if (rest.isNotEmpty) ...[
          Padding(
            padding: const EdgeInsets.fromLTRB(ZSpace.s16, ZSpace.s16, ZSpace.s16, ZSpace.s4),
            child: Semantics(header: true, child: Text(context.tr('zaloDevicesCompanions').toUpperCase(), style: z.text.overline)),
          ),
          for (final device in rest) _deviceRow(device, devices, key: 'zaloDevice-${device.id ?? 'summary-${rest.indexOf(device)}'}'),
        ],
        const SizedBox(height: ZSpace.s12),
        Row(
          key: const Key('zaloDevicesReadOnly'),
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Icon(ZIcons.lock, size: 16, color: z.textTertiary),
            const SizedBox(width: ZSpace.s8),
            Expanded(child: Text(context.tr('zaloDevicesReadOnly'), style: z.text.caption)),
          ],
        ),
      ],
    );
  }

  @override
  Widget build(BuildContext context) {
    return ZDialogScaffold(
      key: const Key('zaloDevicesSheet'),
      title: context.tr('zaloDevices'),
      showClose: true,
      child: _body(),
    );
  }
}
