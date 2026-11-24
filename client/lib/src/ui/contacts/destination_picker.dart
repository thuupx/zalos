import 'package:material_ui/material_ui.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../domain/models.dart';
import '../../domain/services.dart';
import '../components/avatar.dart';
import '../components/basics.dart';
import '../components/fields.dart';
import '../components/overlays.dart';
import '../components/pressable.dart';
import '../l10n/strings.dart';
import '../state/app_state.dart';
import '../theme/tokens.dart';
import '../theme/z_icons.dart';
import '../util/format.dart';

@immutable
class Destination {
  const Destination({required this.id, required this.type, required this.name, required this.avatarUrl});
  final String id;
  final ThreadType type;
  final String name;
  final String avatarUrl;

  String get key => '${type.name}/$id';
}

/// Picks conversations and contacts. Single mode returns on tap; multi mode
/// returns the checked set from the confirm button.
Future<List<Destination>?> showDestinationPicker(
  BuildContext context, {
  required AccountSession session,
  required String title,
  required bool multi,
  String? confirmLabel,
}) {
  return showZModal<List<Destination>>(
    context,
    builder: (_) => _DestinationPicker(session: session, title: title, multi: multi, confirmLabel: confirmLabel),
  );
}

class _DestinationPicker extends ConsumerStatefulWidget {
  const _DestinationPicker({required this.session, required this.title, required this.multi, this.confirmLabel});

  final AccountSession session;
  final String title;
  final bool multi;
  final String? confirmLabel;

  @override
  ConsumerState<_DestinationPicker> createState() => _DestinationPickerState();
}

class _DestinationPickerState extends ConsumerState<_DestinationPicker> {
  final TextEditingController _search = TextEditingController();
  final Map<String, Destination> _picked = {};
  late Future<List<Contact>> _contacts = widget.session.contacts();
  String _query = '';

  @override
  void dispose() {
    _search.dispose();
    super.dispose();
  }

  void _tap(Destination d) {
    if (!widget.multi) {
      Navigator.of(context).pop([d]);
      return;
    }
    setState(() {
      if (_picked.remove(d.key) == null) _picked[d.key] = d;
    });
  }

  @override
  Widget build(BuildContext context) {
    final z = context.z;
    final session = widget.session;
    final threads = ref.watchL(session.threads);
    return ZDialogScaffold(
      key: const Key('destinationPicker'),
      title: widget.title,
      showClose: true,
      padBody: false,
      actions: widget.multi
          ? [
              ZButton(label: context.tr('cancel'), variant: ZButtonVariant.text, onPressed: () => Navigator.of(context).pop()),
              ZButton(
                key: const Key('destinationConfirm'),
                label: _picked.isEmpty ? (widget.confirmLabel ?? context.tr('send')) : '${widget.confirmLabel ?? context.tr('send')} (${_picked.length})',
                onPressed: _picked.isEmpty ? null : () => Navigator.of(context).pop(_picked.values.toList()),
              ),
            ]
          : const [],
      child: SizedBox(
        height: 420,
        child: Column(
          children: [
            Padding(
              padding: const EdgeInsets.fromLTRB(ZSpace.s16, 0, ZSpace.s16, ZSpace.s8),
              child: ZSearchField(
                key: const Key('destinationSearch'),
                controller: _search,
                hint: context.tr('searchContactsHint'),
                clearLabel: context.tr('clear'),
                onChanged: (v) => setState(() => _query = v),
              ),
            ),
            Expanded(
              child: FutureBuilder<List<Contact>>(
                future: _contacts,
                builder: (context, snap) {
                  if (snap.hasError) {
                    return ZErrorState(
                      title: context.tr('loadFailed'),
                      retryLabel: context.tr('retry'),
                      onRetry: () => setState(() => _contacts = session.contacts()),
                    );
                  }
                  final seen = <String>{};
                  final items = <Destination>[
                    for (final t in threads)
                      if (seen.add('${t.type.name}/${t.id}')) Destination(id: t.id, type: t.type, name: t.name, avatarUrl: t.avatarUrl),
                    for (final c in snap.data ?? const <Contact>[])
                      if (seen.add('user/${c.uid}'))
                        Destination(id: c.uid, type: ThreadType.user, name: c.alias?.isNotEmpty == true ? c.alias! : c.displayName, avatarUrl: c.avatarUrl),
                  ].where((d) => _query.trim().isEmpty || foldContains(d.name, _query)).toList();
                  if (items.isEmpty) {
                    if (!snap.hasData) return ZSkeletonList(count: 5, avatar: 40, rowHeight: 56, label: context.tr('loading'));
                    return ZEmptyState(icon: ZIcons.searchOff, title: context.tr('noResults'));
                  }
                  return ListView.builder(
                    itemCount: items.length,
                    itemExtent: 56,
                    itemBuilder: (context, i) {
                      final d = items[i];
                      final checked = _picked.containsKey(d.key);
                      return ZPressable(
                        key: Key('destination-${d.key}'),
                        onTap: () => _tap(d),
                        radius: 0,
                        toggled: widget.multi ? checked : null,
                        semanticLabel: d.name,
                        child: Padding(
                          padding: const EdgeInsets.symmetric(horizontal: ZSpace.s16),
                          child: Row(
                            children: [
                              if (widget.multi) ...[
                                Icon(
                                  checked ? ZIcons.checkCircle : ZIcons.radioUnchecked,
                                  size: 22,
                                  fill: checked ? 1 : 0,
                                  color: checked ? z.brandText : z.textTertiary,
                                ),
                                const SizedBox(width: ZSpace.s12),
                              ],
                              ZAvatar(session: session, id: d.id, name: d.name, url: d.avatarUrl, size: 40, group: d.type == ThreadType.group),
                              const SizedBox(width: ZSpace.s12),
                              Expanded(child: ZHighlightText(text: d.name, query: _query, style: z.text.rowTitle)),
                            ],
                          ),
                        ),
                      );
                    },
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
