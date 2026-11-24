import 'package:material_ui/material_ui.dart';

import '../../domain/models.dart';
import '../../domain/services.dart';
import '../components/basics.dart';
import '../components/fields.dart';
import '../components/motion.dart';
import '../components/overlays.dart';
import '../components/pressable.dart';
import '../l10n/strings.dart';
import '../theme/tokens.dart';
import '../theme/z_icons.dart';

String _reasonKey(ReportReason reason) => switch (reason) {
      ReportReason.sensitive => 'reportSensitive',
      ReportReason.annoy => 'reportAnnoy',
      ReportReason.fraud => 'reportFraud',
      ReportReason.other => 'reportOther',
    };

/// Reports the conversation to Zalo. Free text is required only for
/// [ReportReason.other]. Returns true when the server accepted the report.
Future<bool> showReportDialog(
  BuildContext context, {
  required AccountSession session,
  required String threadId,
  required ThreadType type,
}) async {
  final sent = await showZModal<bool>(
    context,
    builder: (_) =>
        _ReportDialog(session: session, threadId: threadId, type: type),
  );
  return sent ?? false;
}

class _ReportDialog extends StatefulWidget {
  const _ReportDialog(
      {required this.session, required this.threadId, required this.type});

  final AccountSession session;
  final String threadId;
  final ThreadType type;

  @override
  State<_ReportDialog> createState() => _ReportDialogState();
}

class _ReportDialogState extends State<_ReportDialog> {
  final TextEditingController _content = TextEditingController();
  ReportReason _reason = ReportReason.sensitive;
  bool _busy = false;
  bool _failed = false;

  bool get _needsContent => _reason == ReportReason.other;
  bool get _valid => !_needsContent || _content.text.trim().isNotEmpty;

  @override
  void dispose() {
    _content.dispose();
    super.dispose();
  }

  Future<void> _submit() async {
    if (!_valid || _busy) return;
    setState(() {
      _busy = true;
      _failed = false;
    });
    try {
      await widget.session.report(widget.threadId, widget.type, _reason,
          content: _needsContent ? _content.text.trim() : null);
      if (!mounted) return;
      zToast(context, context.tr('reportSent'));
      Navigator.of(context).pop(true);
    } catch (_) {
      if (mounted) setState(() => _failed = true);
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final z = context.z;
    return ZDismissOnEscape(
      child: ZDialogScaffold(
        key: const Key('reportDialog'),
        title: context.tr('reportTitle'),
        showClose: true,
        actions: [
          ZButton(
              label: context.tr('cancel'),
              variant: ZButtonVariant.text,
              onPressed: _busy ? null : () => Navigator.of(context).pop(false)),
          ZButton(
            key: const Key('reportSubmit'),
            label: context.tr('reportSubmit'),
            loading: _busy,
            onPressed: _valid ? _submit : null,
          ),
        ],
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          mainAxisSize: MainAxisSize.min,
          children: [
            Text(context.tr('reportBody'), style: z.text.rowSub),
            const SizedBox(height: ZSpace.s12),
            Semantics(
              header: true,
              child: Text(context.tr('reportReason').toUpperCase(),
                  style: z.text.overline),
            ),
            for (final reason in ReportReason.values)
              ZPressable(
                key: Key('reportReason-${reason.name}'),
                onTap: _busy ? null : () => setState(() => _reason = reason),
                radius: ZRadius.row,
                selected: _reason == reason,
                toggled: _reason == reason,
                semanticLabel: context.tr(_reasonKey(reason)),
                child: Container(
                  constraints: BoxConstraints(
                      minHeight: LayoutScope.wideOf(context)
                          ? 40
                          : ZSizes.touchTarget),
                  padding: const EdgeInsets.symmetric(
                      horizontal: ZSpace.s8, vertical: ZSpace.s4),
                  child: Row(
                    children: [
                      Icon(
                        _reason == reason
                            ? ZIcons.radioChecked
                            : ZIcons.radioUnchecked,
                        size: 22,
                        fill: _reason == reason ? 1 : 0,
                        color: _reason == reason ? z.brandText : z.textTertiary,
                      ),
                      const SizedBox(width: ZSpace.s8),
                      Expanded(
                          child: Text(context.tr(_reasonKey(reason)),
                              style: z.text.labelRegular)),
                    ],
                  ),
                ),
              ),
            ZReveal(
              child: _needsContent
                  ? Padding(
                      padding: const EdgeInsets.only(top: ZSpace.s8),
                      child: ZTextField(
                        key: const Key('reportContent'),
                        controller: _content,
                        label: context.tr('reportOtherHint'),
                        hint: context.tr('reportOtherHint'),
                        errorText: _content.text.trim().isEmpty
                            ? context.tr('reportOtherRequired')
                            : null,
                        minLines: 3,
                        maxLines: 5,
                        maxLength: 500,
                        enabled: !_busy,
                        onChanged: (_) => setState(() {}),
                      ),
                    )
                  : null,
            ),
            if (_failed)
              Padding(
                padding: const EdgeInsets.only(top: ZSpace.s8),
                child: ZBanner(
                    key: const Key('reportError'),
                    tone: ZTone.danger,
                    icon: ZIcons.error,
                    text: context.tr('reportFailed')),
              ),
          ],
        ),
      ),
    );
  }
}
