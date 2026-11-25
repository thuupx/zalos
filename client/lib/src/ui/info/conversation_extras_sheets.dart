import 'package:material_ui/material_ui.dart';
import 'package:flutter/services.dart';

import '../../domain/models.dart';
import '../../domain/services.dart';
import '../components/basics.dart';
import '../components/overlays.dart';
import '../components/pressable.dart';
import '../l10n/strings.dart';
import '../theme/tokens.dart';
import '../theme/z_icons.dart';

Future<void> showMediaStoreSheet(
  BuildContext context, {
  required AccountSession session,
  required String threadId,
  required ThreadType threadType,
}) =>
    showZModal<void>(
      context,
      builder: (_) => _MediaStoreSheet(
        session: session,
        threadId: threadId,
        threadType: threadType,
      ),
    );

class _MediaStoreSheet extends StatefulWidget {
  const _MediaStoreSheet({
    required this.session,
    required this.threadId,
    required this.threadType,
  });

  final AccountSession session;
  final String threadId;
  final ThreadType threadType;

  @override
  State<_MediaStoreSheet> createState() => _MediaStoreSheetState();
}

class _MediaStoreSheetState extends State<_MediaStoreSheet> {
  String _type = 'image';
  List<MediaStoreEntry> _items = const [];
  bool _loading = true;

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    setState(() => _loading = true);
    try {
      final list = await widget.session.mediaStoreList(widget.threadId, widget.threadType, _type);
      if (mounted) setState(() => _items = list);
    } finally {
      if (mounted) setState(() => _loading = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final z = context.z;
    return ZDialogScaffold(
      key: const Key('mediaStoreSheet'),
      title: context.tr('mediaStore'),
      showClose: true,
      child: SizedBox(
        height: 360,
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            ZSegmented<String>(
              segments: [
                ('image', context.tr('mediaTypeImages')),
                ('video', context.tr('mediaTypeVideos')),
                ('file', context.tr('mediaTypeFiles')),
              ],
              selected: _type,
              onChanged: (v) {
                setState(() => _type = v);
                _load();
              },
            ),
            const SizedBox(height: ZSpace.s12),
            Expanded(
              child: _loading
                  ? const ZSkeletonRow(avatar: 32, height: 48)
                  : _items.isEmpty
                      ? Text(context.tr('mediaStoreEmpty'), style: z.text.rowSub)
                      : ListView.builder(
                          shrinkWrap: true,
                          itemCount: _items.length,
                          itemBuilder: (context, i) {
                            final item = _items[i];
                            return ZRow(
                              key: Key('mediaStoreItem-${item.id}'),
                              icon: ZIcons.image,
                              title: item.name.isEmpty ? item.id : item.name,
                              subtitle: item.url,
                              trailing: ZIconButton(
                                key: Key('removeMediaStore-${item.id}'),
                                icon: ZIcons.delete,
                                label: context.tr('delete'),
                                onPressed: () async {
                                  await widget.session.mediaStoreRemove(
                                    widget.threadId,
                                    widget.threadType,
                                    item.mediaType,
                                    item.id,
                                  );
                                  await _load();
                                },
                              ),
                            );
                          },
                        ),
            ),
          ],
        ),
      ),
    );
  }
}

Future<void> showE2eeStatusSheet(
  BuildContext context, {
  required AccountSession session,
  required String threadId,
  required ThreadType threadType,
}) =>
    showZModal<void>(
      context,
      builder: (_) => _E2eeStatusSheet(
        session: session,
        threadId: threadId,
        threadType: threadType,
      ),
    );

class _E2eeStatusSheet extends StatefulWidget {
  const _E2eeStatusSheet({
    required this.session,
    required this.threadId,
    required this.threadType,
  });

  final AccountSession session;
  final String threadId;
  final ThreadType threadType;

  @override
  State<_E2eeStatusSheet> createState() => _E2eeStatusSheetState();
}

class _E2eeStatusSheetState extends State<_E2eeStatusSheet> {
  bool _enabled = false;
  bool _loading = true;

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    try {
      final res = await widget.session.e2eeCheckCompatible(widget.threadId, widget.threadType);
      if (mounted) setState(() { _enabled = res; _loading = false; });
    } catch (_) {
      if (mounted) setState(() => _loading = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    return ZDialogScaffold(
      key: const Key('e2eeStatusSheet'),
      title: context.tr('e2ee'),
      showClose: true,
      child: _loading
          ? const ZSkeletonRow(avatar: 32, height: 48)
          : ZSwitchRow(
              key: const Key('e2eeEnableSwitch'),
              icon: ZIcons.encrypted,
              title: context.tr('e2eeEnableToggle'),
              subtitle: context.tr(_enabled ? 'e2eeCompatible' : 'e2eeNotCompatible'),
              value: _enabled,
              onChanged: (v) async {
                setState(() => _enabled = v);
                await widget.session.e2eeEnable(widget.threadId, widget.threadType, v);
              },
            ),
    );
  }
}

Future<void> showUserQrSheet(
  BuildContext context, {
  required AccountSession session,
  required String uid,
  required String name,
}) async {
  final map = await session.userQr([uid]);
  final qr = map[uid] ?? '';
  if (!context.mounted) return;
  await showZModal<void>(
    context,
    builder: (_) => ZDialogScaffold(
      key: const Key('userQrSheet'),
      title: name,
      showClose: true,
      actions: [
        ZButton(
          label: context.tr('copied'),
          onPressed: qr.isEmpty
              ? null
              : () {
                  Clipboard.setData(ClipboardData(text: qr));
                  zToast(context, context.tr('copied'));
                  Navigator.of(context).pop();
                },
        ),
      ],
      child: Text(qr.isEmpty ? context.tr('noItemsYet') : qr, key: const Key('userQrValue')),
    ),
  );
}
