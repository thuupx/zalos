import 'package:material_ui/material_ui.dart';

import '../../domain/models.dart';
import '../../domain/services.dart';
import '../components/basics.dart';
import '../components/fields.dart';
import '../components/overlays.dart';
import '../components/pressable.dart';
import '../l10n/strings.dart';
import '../theme/tokens.dart';
import '../theme/z_icons.dart';

Future<void> showBusinessToolsSheet(
  BuildContext context, {
  required AccountSession session,
}) =>
    showZModal<void>(
      context,
      builder: (_) => _BusinessToolsSheet(session: session),
    );

class _BusinessToolsSheet extends StatefulWidget {
  const _BusinessToolsSheet({required this.session});
  final AccountSession session;

  @override
  State<_BusinessToolsSheet> createState() => _BusinessToolsSheetState();
}

class _BusinessToolsSheetState extends State<_BusinessToolsSheet> {
  int _tab = 0;
  List<AutoReplyRule> _autoReplies = const [];
  List<CatalogItem> _catalogs = const [];
  List<BankAccount> _banks = const [];
  final Map<String, List<CatalogProduct>> _products = {};
  final TextEditingController _arText = TextEditingController();
  final TextEditingController _catName = TextEditingController();
  final TextEditingController _bin = TextEditingController(text: '970436');
  final TextEditingController _accNum = TextEditingController();
  final TextEditingController _holder = TextEditingController();
  bool _loading = true;

  @override
  void initState() {
    super.initState();
    _load();
  }

  @override
  void dispose() {
    _arText.dispose();
    _catName.dispose();
    _bin.dispose();
    _accNum.dispose();
    _holder.dispose();
    super.dispose();
  }

  Future<void> _load() async {
    setState(() => _loading = true);
    try {
      final res = await Future.wait([
        widget.session.autoReplies(),
        widget.session.catalogs(),
        widget.session.bankAccounts(page: 0, limit: 50),
      ]);
      if (!mounted) return;
      setState(() {
        _autoReplies = res[0] as List<AutoReplyRule>;
        _catalogs = res[1] as List<CatalogItem>;
        _banks = (res[2] as BankAccounts).accounts;
      });
    } finally {
      if (mounted) setState(() => _loading = false);
    }
  }

  Future<void> _loadProducts(String catalogId) async {
    final list = await widget.session.catalogProducts(catalogId);
    if (mounted) setState(() => _products[catalogId] = list);
  }

  @override
  Widget build(BuildContext context) {
    final z = context.z;
    return ZDialogScaffold(
      key: const Key('businessToolsSheet'),
      title: context.tr('businessTools'),
      showClose: true,
      child: SizedBox(
        height: 400,
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            ZSegmented<int>(
              key: const Key('businessToolsTabs'),
              segments: [
                (0, context.tr('autoReplyTab')),
                (1, context.tr('catalogsTab')),
                (2, context.tr('bankAccountsTab')),
              ],
              selected: _tab,
              onChanged: (v) => setState(() => _tab = v),
            ),
            const SizedBox(height: ZSpace.s12),
            Expanded(
              child: _loading
                  ? const ZSkeletonRow(avatar: 32, height: 48)
                  : _tab == 0
                      ? _buildAutoReplyTab(z)
                      : _tab == 1
                          ? _buildCatalogsTab(z)
                          : _buildBanksTab(z),
            ),
          ],
        ),
      ),
    );
  }

  Widget _buildAutoReplyTab(ZalosTokens z) => ListView(
        shrinkWrap: true,
        children: [
          Row(
            children: [
              Expanded(
                child: ZTextField(
                  key: const Key('autoReplyInput'),
                  controller: _arText,
                  label: context.tr('autoReplyContentLabel'),
                ),
              ),
              const SizedBox(width: ZSpace.s8),
              ZButton(
                key: const Key('addAutoReplyButton'),
                label: context.tr('addAutoReply'),
                small: true,
                onPressed: () async {
                  final text = _arText.text.trim();
                  if (text.isEmpty) return;
                  await widget.session.createAutoReply(enabled: true, content: text);
                  _arText.clear();
                  await _load();
                },
              ),
            ],
          ),
          const SizedBox(height: ZSpace.s8),
          if (_autoReplies.isEmpty)
            Text(context.tr('autoReplyEmpty'), style: z.text.rowSub)
          else
            for (final rule in _autoReplies)
              ZRow(
                key: Key('autoReply-${rule.id}'),
                icon: ZIcons.bolt,
                title: rule.content,
                trailing: Row(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    Switch(
                      value: rule.enabled,
                      onChanged: (v) async {
                        await widget.session.updateAutoReply(AutoReplyRule(
                          id: rule.id,
                          enabled: v,
                          content: rule.content,
                          startTime: rule.startTime,
                          endTime: rule.endTime,
                          scope: rule.scope,
                        ));
                        await _load();
                      },
                    ),
                    ZIconButton(
                      key: Key('deleteAutoReply-${rule.id}'),
                      icon: ZIcons.delete,
                      label: context.tr('delete'),
                      onPressed: () async {
                        await widget.session.deleteAutoReply(rule.id);
                        await _load();
                      },
                    ),
                  ],
                ),
              ),
        ],
      );

  Widget _buildCatalogsTab(ZalosTokens z) => ListView(
        shrinkWrap: true,
        children: [
          Row(
            children: [
              Expanded(
                child: ZTextField(
                  key: const Key('catalogNameInput'),
                  controller: _catName,
                  label: context.tr('catalogNameLabel'),
                ),
              ),
              const SizedBox(width: ZSpace.s8),
              ZButton(
                key: const Key('addCatalogButton'),
                label: context.tr('addCatalog'),
                small: true,
                onPressed: () async {
                  final name = _catName.text.trim();
                  if (name.isEmpty) return;
                  await widget.session.createCatalog(name);
                  _catName.clear();
                  await _load();
                },
              ),
            ],
          ),
          const SizedBox(height: ZSpace.s8),
          if (_catalogs.isEmpty)
            Text(context.tr('catalogsEmpty'), style: z.text.rowSub)
          else
            for (final c in _catalogs) ...[
              ZRow(
                key: Key('catalog-${c.catalogId}'),
                icon: ZIcons.storefront,
                title: c.catalogName,
                onTap: () => _loadProducts(c.catalogId),
                trailing: Row(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    ZIconButton(
                      icon: ZIcons.plus,
                      label: context.tr('addProduct'),
                      onPressed: () async {
                        await widget.session.createCatalogProduct(
                          c.catalogId,
                          name: '${c.catalogName} #1',
                          price: '100000',
                          description: c.catalogName,
                        );
                        await _loadProducts(c.catalogId);
                      },
                    ),
                    ZIconButton(
                      key: Key('deleteCatalog-${c.catalogId}'),
                      icon: ZIcons.delete,
                      label: context.tr('delete'),
                      onPressed: () async {
                        await widget.session.deleteCatalog(c.catalogId);
                        await _load();
                      },
                    ),
                  ],
                ),
              ),
              for (final p in _products[c.catalogId] ?? const <CatalogProduct>[])
                Padding(
                  padding: const EdgeInsets.only(left: ZSpace.s16),
                  child: ZRow(
                    icon: ZIcons.label,
                    title: '${p.productName} - ${p.price}${p.currencyUnit}',
                    trailing: ZIconButton(
                      icon: ZIcons.close,
                      label: context.tr('delete'),
                      onPressed: () async {
                        await widget.session.deleteCatalogProduct(c.catalogId, [p.productId]);
                        await _loadProducts(c.catalogId);
                      },
                    ),
                  ),
                ),
            ],
        ],
      );

  Widget _buildBanksTab(ZalosTokens z) => ListView(
        shrinkWrap: true,
        children: [
          ZTextField(key: const Key('bankBinInput'), controller: _bin, label: context.tr('bankBinLabel')),
          const SizedBox(height: ZSpace.s4),
          ZTextField(key: const Key('bankAccNumInput'), controller: _accNum, label: context.tr('bankAccNumLabel')),
          const SizedBox(height: ZSpace.s4),
          ZTextField(key: const Key('bankHolderInput'), controller: _holder, label: context.tr('bankHolderLabel')),
          const SizedBox(height: ZSpace.s8),
          ZButton(
            key: const Key('addBankAccountButton'),
            label: context.tr('addBankAccount'),
            small: true,
            onPressed: () async {
              final bin = int.tryParse(_bin.text.trim()) ?? 970436;
              final num = _accNum.text.trim();
              final holder = _holder.text.trim();
              if (num.isEmpty || holder.isEmpty) return;
              await widget.session.createBankAccount(bin: bin, accountNumber: num, holderName: holder);
              _accNum.clear();
              _holder.clear();
              await _load();
            },
          ),
          const SizedBox(height: ZSpace.s8),
          for (final b in _banks)
            ZRow(
              key: Key('bankItem-${b.id}'),
              icon: ZIcons.bank,
              title: '${b.bankName ?? b.bin} · ${b.accountNumber}',
              subtitle: b.holderName,
              trailing: ZIconButton(
                key: Key('deleteBank-${b.id}'),
                icon: ZIcons.delete,
                label: context.tr('delete'),
                onPressed: () async {
                  await widget.session.deleteBankAccount(b.id, isDefault: b.isDefault);
                  await _load();
                },
              ),
            ),
        ],
      );
}
