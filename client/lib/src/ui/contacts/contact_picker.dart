import 'package:material_ui/material_ui.dart';

import '../../domain/models.dart';
import '../../domain/services.dart';
import '../components/avatar.dart';
import '../components/basics.dart';
import '../components/fields.dart';
import '../components/overlays.dart';
import '../components/pressable.dart';
import '../l10n/strings.dart';
import '../theme/tokens.dart';
import '../theme/z_icons.dart';
import '../util/format.dart';

/// Picks one friend to share as a contact card.
Future<Contact?> showContactPicker(BuildContext context,
    {required AccountSession session, String? title}) {
  return showZModal<Contact>(
    context,
    builder: (_) => _ContactPicker(
        session: session, title: title ?? context.tr('contactPickerTitle')),
  );
}

class _ContactPicker extends StatefulWidget {
  const _ContactPicker({required this.session, required this.title});

  final AccountSession session;
  final String title;

  @override
  State<_ContactPicker> createState() => _ContactPickerState();
}

class _ContactPickerState extends State<_ContactPicker> {
  final TextEditingController _search = TextEditingController();
  late Future<List<Contact>> _contacts = widget.session.contacts();
  String _query = '';

  @override
  void dispose() {
    _search.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final z = context.z;
    final session = widget.session;
    return ZDismissOnEscape(
      child: ZDialogScaffold(
        key: const Key('contactPicker'),
        title: widget.title,
        showClose: true,
        padBody: false,
        child: SizedBox(
          height: 420,
          child: Column(
            children: [
              Padding(
                padding: const EdgeInsets.fromLTRB(
                    ZSpace.s16, 0, ZSpace.s16, ZSpace.s8),
                child: ZSearchField(
                  key: const Key('contactPickerSearch'),
                  controller: _search,
                  hint: context.tr('searchFriends'),
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
                        key: const Key('contactPickerError'),
                        title: context.tr('loadFailed'),
                        retryLabel: context.tr('retry'),
                        onRetry: () =>
                            setState(() => _contacts = session.contacts()),
                      );
                    }
                    if (!snap.hasData) {
                      return ZSkeletonList(
                          key: const Key('contactPickerLoading'),
                          count: 6,
                          avatar: 40,
                          rowHeight: 56,
                          label: context.tr('loading'));
                    }
                    final items = [
                      for (final c in snap.data!)
                        if (_query.trim().isEmpty ||
                            foldContains(
                                c.alias?.isNotEmpty == true
                                    ? c.alias!
                                    : c.displayName,
                                _query) ||
                            foldContains(c.displayName, _query))
                          c,
                    ]..sort((a, b) {
                        String label(Contact c) => c.alias?.isNotEmpty == true
                            ? c.alias!
                            : c.displayName;
                        return foldVi(label(a)).compareTo(foldVi(label(b)));
                      });
                    if (items.isEmpty) {
                      return ZEmptyState(
                        key: const Key('contactPickerEmpty'),
                        icon: ZIcons.contacts,
                        title: context.tr(
                            _query.trim().isEmpty ? 'noContacts' : 'noResults'),
                        subtitle: _query.trim().isEmpty
                            ? context.tr('noContactsHint')
                            : null,
                      );
                    }
                    return ListView.builder(
                      key: const Key('contactPickerList'),
                      padding: EdgeInsets.zero,
                      itemCount: items.length,
                      itemExtent: 56,
                      itemBuilder: (context, i) {
                        final c = items[i];
                        final name = c.alias?.isNotEmpty == true
                            ? c.alias!
                            : c.displayName;
                        return ZPressable(
                          key: Key('contactPicker-${c.uid}'),
                          onTap: () => Navigator.of(context).pop(c),
                          radius: 0,
                          semanticLabel: name == c.displayName
                              ? name
                              : '$name, ${c.displayName}',
                          child: Padding(
                            padding: const EdgeInsets.symmetric(
                                horizontal: ZSpace.s16),
                            child: Row(
                              children: [
                                ZAvatar(
                                    session: session,
                                    id: c.uid,
                                    name: c.displayName,
                                    url: c.avatarUrl,
                                    size: 40),
                                const SizedBox(width: ZSpace.s12),
                                Expanded(
                                  child: Column(
                                    mainAxisAlignment: MainAxisAlignment.center,
                                    crossAxisAlignment:
                                        CrossAxisAlignment.start,
                                    children: [
                                      ZHighlightText(
                                          text: name,
                                          query: _query,
                                          style: z.text.rowTitle),
                                      if (name != c.displayName)
                                        Text(c.displayName,
                                            maxLines: 1,
                                            overflow: TextOverflow.ellipsis,
                                            style: z.text.rowSub),
                                    ],
                                  ),
                                ),
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
      ),
    );
  }
}
