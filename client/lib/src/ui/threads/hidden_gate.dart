// Hidden conversations. Zalo Web has no verify-PIN call, so the gate is
// an explicit local visibility confirmation; PIN set/reset are separate writes
// whose value never leaves the request.
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
import '../platform/services.dart';
import '../state/app_state.dart';
import '../theme/tokens.dart';
import '../theme/z_icons.dart';

Future<void> showHiddenGate(BuildContext context, AccountSession session) =>
    showZModal<void>(context, builder: (_) => HiddenGate(session: session));

class HiddenGate extends ConsumerStatefulWidget {
  const HiddenGate({super.key, required this.session});

  final AccountSession session;

  @override
  ConsumerState<HiddenGate> createState() => _HiddenGateState();
}

class _HiddenGateState extends ConsumerState<HiddenGate> {
  final TextEditingController _pin = TextEditingController();

  bool _confirmed = false;
  bool _loading = false;
  bool _failed = false;
  HiddenConversations? _hidden;
  String? _busyId;
  bool _pinBusy = false;
  String? _pinError;

  @override
  void initState() {
    super.initState();
    _pin.addListener(_onPinChanged);
  }

  @override
  void dispose() {
    _pin.removeListener(_onPinChanged);
    _pin.dispose();
    super.dispose();
  }

  void _onPinChanged() {
    if (mounted) setState(() {});
  }

  Future<void> _confirm() async {
    setState(() => _confirmed = true);
    await _load();
  }

  Future<void> _load() async {
    setState(() {
      _loading = true;
      _failed = false;
    });
    try {
      final hidden = await widget.session.hiddenConversations();
      if (!mounted) return;
      setState(() {
        _hidden = hidden;
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

  Thread? _threadOf(ThreadRef threadRef) {
    for (final thread in widget.session.threads.value) {
      if (thread.id == threadRef.id && thread.type == threadRef.type) return thread;
    }
    return null;
  }

  void _open(ThreadRef threadRef) {
    final thread = _threadOf(threadRef);
    final name = thread?.name.trim().isNotEmpty == true
        ? thread!.name
        : context.tr(threadRef.type == ThreadType.group ? 'unnamedGroup' : 'unknownUser');
    final avatar = thread?.avatarUrl ?? '';
    Navigator.of(context).pop();
    ref.read(infoPaneOpenProvider.notifier).state = false;
    openThread(ref, OpenThread(slot: widget.session.slot, id: threadRef.id, type: threadRef.type, name: name, avatarUrl: avatar));
  }

  Future<void> _unhide(ThreadRef thread) async {
    if (_busyId != null) return;
    setState(() => _busyId = thread.id);
    try {
      await widget.session.setHidden(thread.id, thread.type, false);
      if (!mounted) return;
      await _load();
    } catch (_) {
      if (mounted) zToast(context, context.tr('actionFailed'));
    } finally {
      if (mounted) setState(() => _busyId = null);
    }
  }

  Future<void> _setPin() async {
    final pin = _pin.text;
    if (!RegExp(r'^\d{4}$').hasMatch(pin)) {
      setState(() => _pinError = context.tr('hiddenPinInvalid'));
      return;
    }
    setState(() {
      _pinBusy = true;
      _pinError = null;
    });
    var saved = false;
    try {
      await widget.session.setHiddenPin(pin);
      saved = true;
      if (mounted) zToast(context, context.tr('hiddenPinSaved'));
    } catch (_) {
      if (mounted) zToast(context, context.tr('actionFailed'));
    } finally {
      if (mounted) {
        // The value only ever lived in this field for the request.
        _pin.clear();
        setState(() {
          _pinBusy = false;
          if (saved) _hidden = HiddenConversations(pinSet: true, threads: _hidden?.threads ?? const []);
        });
      }
    }
  }

  Future<void> _resetPin() async {
    final ok = await zConfirm(
      context,
      title: context.tr('hiddenPinResetTitle'),
      message: context.tr('hiddenPinResetBody'),
      confirmLabel: context.tr('hiddenPinReset'),
    );
    if (!ok || !mounted) return;
    final authed = await ref.read(platformProvider).authenticateUser(context.tr('authRequiredReason'));
    if (!authed) {
      if (mounted) zToast(context, context.tr('authDenied'));
      return;
    }
    if (!mounted) return;
    setState(() => _pinBusy = true);
    try {
      await widget.session.resetHiddenPin();
      if (!mounted) return;
      setState(() => _hidden = HiddenConversations(pinSet: false, threads: _hidden?.threads ?? const []));
      zToast(context, context.tr('hiddenPinResetDone'));
    } catch (_) {
      if (mounted) zToast(context, context.tr('actionFailed'));
    } finally {
      if (mounted) setState(() => _pinBusy = false);
    }
  }

  Widget _hiddenRow(ThreadRef thread) {
    final t = _threadOf(thread);
    final name = t?.name.trim().isNotEmpty == true
        ? t!.name
        : context.tr(thread.type == ThreadType.group ? 'unnamedGroup' : 'unknownUser');
    return SizedBox(
      key: Key('hiddenRow-${thread.id}'),
      height: 56,
      child: Row(
        children: [
          Expanded(
            child: ZPressable(
              key: Key('hiddenOpen-${thread.id}'),
              onTap: () => _open(thread),
              radius: ZRadius.row,
              semanticLabel: name,
              child: Row(
                children: [
                  ZAvatar(session: widget.session, id: thread.id, name: name, url: t?.avatarUrl ?? '', size: 40, group: thread.type == ThreadType.group),
                  const SizedBox(width: ZSpace.s12),
                  Expanded(child: Text(name, maxLines: 1, overflow: TextOverflow.ellipsis, style: context.z.text.rowTitle)),
                ],
              ),
            ),
          ),
          const SizedBox(width: ZSpace.s8),
          ZButton(
            key: Key('hiddenUnhide-${thread.id}'),
            label: context.tr('hiddenUnhide'),
            variant: ZButtonVariant.text,
            small: true,
            loading: _busyId == thread.id,
            onPressed: _busyId == null ? () => _unhide(thread) : null,
          ),
        ],
      ),
    );
  }

  Widget _pinSection(HiddenConversations hidden) {
    final z = context.z;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      mainAxisSize: MainAxisSize.min,
      children: [
        Container(height: 1, margin: const EdgeInsets.symmetric(vertical: ZSpace.s12), color: z.divider),
        Semantics(header: true, child: Text(context.tr('hiddenPinTitle'), style: z.text.labelStrong)),
        const SizedBox(height: ZSpace.s4),
        Text(
          context.tr(hidden.pinSet ? 'hiddenPinSet' : 'hiddenPinNotSet'),
          key: const Key('hiddenPinStatus'),
          style: z.text.rowSub,
        ),
        const SizedBox(height: ZSpace.s4),
        Text(context.tr('hiddenPinExplain'), key: const Key('hiddenPinExplain'), style: z.text.caption),
        const SizedBox(height: ZSpace.s8),
        if (hidden.pinSet)
          Align(
            alignment: Alignment.centerLeft,
            child: ZButton(
              key: const Key('hiddenPinReset'),
              label: context.tr('hiddenPinReset'),
              variant: ZButtonVariant.destructiveText,
              small: true,
              loading: _pinBusy,
              onPressed: _pinBusy ? null : _resetPin,
            ),
          )
        else
          Row(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Expanded(
                child: ZTextField(
                  key: const Key('hiddenPinField'),
                  controller: _pin,
                  hint: context.tr('hiddenPinSetLabel'),
                  errorText: _pinError,
                  obscure: true,
                  maxLength: 4,
                  keyboardType: TextInputType.number,
                  onChanged: (_) {
                    if (_pinError != null) setState(() => _pinError = null);
                  },
                  onSubmitted: (_) => _setPin(),
                ),
              ),
              const SizedBox(width: ZSpace.s8),
              ZButton(
                key: const Key('hiddenPinSave'),
                label: context.tr('hiddenPinSave'),
                small: true,
                loading: _pinBusy,
                onPressed: _pinBusy || _pin.text.length != 4 ? null : _setPin,
              ),
            ],
          ),
      ],
    );
  }

  Widget _body() {
    if (_loading) {
      return const Column(
        key: Key('hiddenListLoading'),
        children: [ZSkeletonRow(avatar: 40, height: 56), ZSkeletonRow(avatar: 40, height: 56), ZSkeletonRow(avatar: 40, height: 56)],
      );
    }
    if (_failed) {
      return ZErrorState(
        key: const Key('hiddenError'),
        title: context.tr('loadFailed'),
        retryLabel: context.tr('retry'),
        onRetry: _load,
      );
    }
    final hidden = _hidden;
    if (hidden == null) return const SizedBox.shrink();
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      mainAxisSize: MainAxisSize.min,
      children: [
        if (hidden.threads.isEmpty)
          ZEmptyState(
            key: const Key('hiddenEmpty'),
            icon: ZIcons.eyeOff,
            title: context.tr('hiddenEmpty'),
            subtitle: context.tr('hiddenEmptyHint'),
          )
        else
          for (final thread in hidden.threads) _hiddenRow(thread),
        _pinSection(hidden),
      ],
    );
  }

  @override
  Widget build(BuildContext context) {
    final z = context.z;
    ref.watchL(widget.session.threads);
    return ZDialogScaffold(
      key: const Key('hiddenGate'),
      title: context.tr('hiddenGateTitle'),
      showClose: true,
      child: _confirmed
          ? _body()
          : Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              mainAxisSize: MainAxisSize.min,
              children: [
                Container(
                  padding: const EdgeInsets.all(ZSpace.s12),
                  decoration: BoxDecoration(color: z.warningBg, borderRadius: BorderRadius.circular(ZRadius.input)),
                  child: Row(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Icon(ZIcons.info, size: 18, color: z.warning, fill: 1),
                      const SizedBox(width: ZSpace.s8),
                      Expanded(
                        child: Text(
                          context.tr('hiddenGateBody'),
                          key: const Key('hiddenGateBody'),
                          style: z.text.body.copyWith(color: z.textPrimary),
                        ),
                      ),
                    ],
                  ),
                ),
                const SizedBox(height: ZSpace.s16),
                ZButton(
                  key: const Key('hiddenGateConfirm'),
                  label: context.tr('hiddenGateConfirm'),
                  icon: ZIcons.eye,
                  onPressed: _confirm,
                ),
              ],
            ),
    );
  }
}
