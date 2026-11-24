import 'package:material_ui/material_ui.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../domain/models.dart';
import '../../domain/services.dart';
import '../components/avatar.dart';
import '../components/basics.dart';
import '../components/fields.dart';
import '../components/motion.dart';
import '../components/overlays.dart';
import '../components/pressable.dart';
import '../l10n/strings.dart';
import '../state/app_state.dart';
import '../theme/tokens.dart';
import '../theme/z_icons.dart';

enum _LookupMode { phone, username }

enum _LookupState { idle, loading, found, empty, error }

/// Finds a Zalo user by phone number or username, shows the current
/// relationship and offers the matching friend request action.
Future<void> showAddFriendSheet(BuildContext context,
    {required AccountSession session, required VoidCallback onChanged}) {
  return showZModal<void>(
    context,
    builder: (_) => _AddFriendSheet(session: session, onChanged: onChanged),
  );
}

class _AddFriendSheet extends ConsumerStatefulWidget {
  const _AddFriendSheet({required this.session, required this.onChanged});

  final AccountSession session;
  final VoidCallback onChanged;

  @override
  ConsumerState<_AddFriendSheet> createState() => _AddFriendSheetState();
}

class _AddFriendSheetState extends ConsumerState<_AddFriendSheet> {
  final TextEditingController _field = TextEditingController();
  final FocusNode _searchFocus = FocusNode(debugLabel: 'addFriendSearch');
  _LookupMode _mode = _LookupMode.phone;
  _LookupState _state = _LookupState.idle;
  UserProfile? _profile;
  FriendRequestStatus? _status;
  bool _statusLoading = false;
  bool _statusFailed = false;
  bool _busy = false;
  String? _actionError;
  int _searchToken = 0;
  int _statusToken = 0;

  AccountSession get _session => widget.session;

  @override
  void dispose() {
    _field.dispose();
    _searchFocus.dispose();
    super.dispose();
  }

  String get _hint => _mode == _LookupMode.phone
      ? context.tr('searchByPhone')
      : context.tr('searchByUsername');

  Future<void> _search() async {
    final query = _field.text.trim();
    if (query.isEmpty) return;
    _searchFocus.unfocus();
    final token = ++_searchToken;
    _statusToken++;
    setState(() {
      _state = _LookupState.loading;
      _profile = null;
      _status = null;
      _statusFailed = false;
      _actionError = null;
    });
    try {
      final profile = _mode == _LookupMode.phone
          ? await _session.findUserByPhone(query)
          : await _session.findUserByUsername(query);
      if (!mounted || token != _searchToken) return;
      if (profile == null) {
        setState(() => _state = _LookupState.empty);
        return;
      }
      setState(() {
        _state = _LookupState.found;
        _profile = profile;
      });
      await _loadStatus(profile.uid);
    } catch (_) {
      if (mounted && token == _searchToken) {
        setState(() => _state = _LookupState.error);
      }
    }
  }

  Future<void> _loadStatus(String uid) async {
    if (!mounted) return;
    final token = ++_statusToken;
    setState(() {
      _statusLoading = true;
      _statusFailed = false;
    });
    FriendRequestStatus? status;
    var failed = false;
    try {
      status = await _session.friendRequestStatus(uid);
    } catch (_) {
      failed = true;
    }
    if (!mounted || token != _statusToken || _profile?.uid != uid) return;
    setState(() {
      _status = status;
      _statusFailed = failed;
      _statusLoading = false;
    });
  }

  Future<void> _run(Future<void> Function() action, String successKey,
      {String failKey = 'friendRequestFailed'}) async {
    if (_busy) return;
    setState(() {
      _busy = true;
      _actionError = null;
    });
    try {
      await action();
      if (!mounted) return;
      zToast(context, context.tr(successKey));
      widget.onChanged();
      final uid = _profile?.uid;
      if (uid != null) await _loadStatus(uid);
    } catch (_) {
      if (mounted) setState(() => _actionError = context.tr(failKey));
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  void _openChat(UserProfile profile) {
    final thread = OpenThread(
        slot: _session.slot,
        id: profile.uid,
        type: ThreadType.user,
        name: profile.displayName,
        avatarUrl: profile.avatarUrl);
    openThread(ref, thread);
    Navigator.of(context).pop();
  }

  Widget _idle() {
    return Padding(
      key: const Key('addFriendIdle'),
      padding: const EdgeInsets.symmetric(vertical: ZSpace.s20),
      child: Text(context.tr('addFriendIdle'),
          textAlign: TextAlign.center, style: context.z.text.rowSub),
    );
  }

  Widget _result(UserProfile profile) {
    final z = context.z;
    final status = _status;
    final actions = <Widget>[];
    if (_statusLoading) {
      actions.add(
        Row(
          key: const Key('addFriendStatusLoading'),
          mainAxisSize: MainAxisSize.min,
          children: [
            const SizedBox(
                width: 14,
                height: 14,
                child: CircularProgressIndicator(strokeWidth: 2)),
            const SizedBox(width: ZSpace.s8),
            Text(context.tr('loading'),
                style: z.text.caption.copyWith(color: z.textSecondary)),
          ],
        ),
      );
    } else if (status == null) {
      actions.add(
        ZButton(
          key: const Key('addFriendStatusRetry'),
          label: context.tr('retry'),
          variant: ZButtonVariant.secondary,
          small: true,
          onPressed:
              _statusFailed && !_busy ? () => _loadStatus(profile.uid) : null,
        ),
      );
    } else if (status.isFriend) {
      actions.add(ZChip(
          label: context.tr('friends'),
          tone: ZTone.success,
          icon: ZIcons.personCheck));
      actions.add(
        ZButton(
          key: const Key('addFriendMessage'),
          label: context.tr('sendMessage'),
          icon: ZIcons.chat,
          small: true,
          onPressed: () => _openChat(profile),
        ),
      );
    } else if (status.isRequested) {
      actions.add(ZChip(
          label: context.tr('friendRequestIncoming'),
          tone: ZTone.info,
          icon: ZIcons.personAdd));
      actions.add(
        ZButton(
          key: const Key('addFriendAccept'),
          label: context.tr('acceptRequest'),
          small: true,
          loading: _busy,
          onPressed: () => _run(() => _session.acceptFriendRequest(profile.uid),
              'friendRequestAccepted'),
        ),
      );
      actions.add(
        ZButton(
          key: const Key('addFriendReject'),
          label: context.tr('reject'),
          variant: ZButtonVariant.text,
          small: true,
          onPressed: _busy
              ? null
              : () => _run(() => _session.rejectFriendRequest(profile.uid),
                  'friendRequestRejected'),
        ),
      );
    } else if (status.isRequesting) {
      actions.add(ZChip(
          label: context.tr('friendRequestPending'),
          tone: ZTone.warning,
          icon: ZIcons.schedule));
      actions.add(
        ZButton(
          key: const Key('addFriendCancelRequest'),
          label: context.tr('cancelRequest'),
          variant: ZButtonVariant.secondary,
          small: true,
          loading: _busy,
          onPressed: () => _run(() => _session.cancelFriendRequest(profile.uid),
              'friendRequestCancelled'),
        ),
      );
    } else {
      actions.add(
        ZButton(
          key: const Key('addFriendSend'),
          label: context.tr('friendRequestSend'),
          icon: ZIcons.personAdd,
          small: true,
          loading: _busy,
          onPressed: () => _run(() => _session.sendFriendRequest(profile.uid),
              'friendRequestSent',
              failKey: 'friendRequestSendFailed'),
        ),
      );
    }
    return ZPopIn(
      key: const Key('addFriendResult'),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        mainAxisSize: MainAxisSize.min,
        children: [
          Container(
            padding: const EdgeInsets.all(ZSpace.s12),
            decoration: BoxDecoration(
                color: z.layerSubtle,
                borderRadius: BorderRadius.circular(ZRadius.card),
                border: Border.all(color: z.divider)),
            child: Row(
              children: [
                ZAvatar(
                    session: _session,
                    id: profile.uid,
                    name: profile.displayName,
                    url: profile.avatarUrl,
                    size: 56),
                const SizedBox(width: ZSpace.s12),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      Text(profile.displayName,
                          maxLines: 2,
                          overflow: TextOverflow.ellipsis,
                          style: z.text.rowTitleUnread),
                      if (profile.zaloName != null &&
                          profile.zaloName!.isNotEmpty)
                        Text(profile.zaloName!,
                            maxLines: 1,
                            overflow: TextOverflow.ellipsis,
                            style: z.text.rowSub),
                      if (profile.phoneNumber != null &&
                          profile.phoneNumber!.isNotEmpty)
                        Text(profile.phoneNumber!,
                            maxLines: 1,
                            overflow: TextOverflow.ellipsis,
                            style: z.text.caption
                                .copyWith(color: z.textSecondary)),
                    ],
                  ),
                ),
              ],
            ),
          ),
          if (_actionError != null)
            Padding(
              padding: const EdgeInsets.only(top: ZSpace.s8),
              child: ZBanner(
                  key: const Key('addFriendActionError'),
                  tone: ZTone.danger,
                  icon: ZIcons.error,
                  text: _actionError!),
            ),
          Padding(
            padding: const EdgeInsets.only(top: ZSpace.s12),
            child: Wrap(
                alignment: WrapAlignment.end,
                crossAxisAlignment: WrapCrossAlignment.center,
                spacing: ZSpace.s8,
                runSpacing: ZSpace.s8,
                children: actions),
          ),
        ],
      ),
    );
  }

  Widget _body() {
    switch (_state) {
      case _LookupState.idle:
        return _idle();
      case _LookupState.loading:
        return Padding(
          key: const Key('addFriendLoading'),
          padding: const EdgeInsets.symmetric(vertical: ZSpace.s20),
          child: Column(
            children: [
              const SizedBox(
                  width: 24,
                  height: 24,
                  child: CircularProgressIndicator(strokeWidth: 2)),
              const SizedBox(height: ZSpace.s12),
              Text(context.tr('searchingUser'), style: context.z.text.rowSub),
            ],
          ),
        );
      case _LookupState.empty:
        return ZEmptyState(
          key: const Key('addFriendNotFound'),
          icon: ZIcons.search,
          title: context.tr('userNotFound'),
          subtitle: context.tr('userNotFoundHint'),
        );
      case _LookupState.error:
        return ZErrorState(
          key: const Key('addFriendError'),
          title: context.tr('userSearchFailed'),
          retryLabel: context.tr('retry'),
          onRetry: _search,
        );
      case _LookupState.found:
        final profile = _profile;
        return profile == null ? _idle() : _result(profile);
    }
  }

  @override
  Widget build(BuildContext context) {
    final z = context.z;
    final wide = LayoutScope.wideOf(context);
    return ZDismissOnEscape(
      child: ZDialogScaffold(
        key: const Key('addFriendSheet'),
        title: context.tr('addFriendTitle'),
        showClose: true,
        child: SizedBox(
          width: wide ? 400 : null,
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            mainAxisSize: MainAxisSize.min,
            children: [
              Text(context.tr('addFriendHint'), style: z.text.rowSub),
              const SizedBox(height: ZSpace.s12),
              ZSegmented<_LookupMode>(
                key: const Key('addFriendMode'),
                segments: [
                  (_LookupMode.phone, context.tr('searchByPhone')),
                  (_LookupMode.username, context.tr('searchByUsername'))
                ],
                selected: _mode,
                onChanged: (mode) => setState(() {
                  _mode = mode;
                  _state = _LookupState.idle;
                  _profile = null;
                  _status = null;
                }),
              ),
              const SizedBox(height: ZSpace.s12),
              ZTextField(
                key: const Key('addFriendField'),
                controller: _field,
                focusNode: _searchFocus,
                hint: _hint,
                prefixIcon: _mode == _LookupMode.phone
                    ? ZIcons.call
                    : ZIcons.at,
                keyboardType: _mode == _LookupMode.phone
                    ? TextInputType.phone
                    : TextInputType.text,
                textInputAction: TextInputAction.search,
                onSubmitted: (_) => _search(),
                autocorrect: false,
              ),
              const SizedBox(height: ZSpace.s8),
              Align(
                alignment: Alignment.centerRight,
                child: ZButton(
                  key: const Key('addFriendSearch'),
                  label: context.tr('search'),
                  icon: ZIcons.search,
                  small: true,
                  onPressed: _state == _LookupState.loading ? null : _search,
                ),
              ),
              ZReveal(child: _body()),
            ],
          ),
        ),
      ),
    );
  }
}
