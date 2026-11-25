import 'package:material_ui/material_ui.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../domain/models.dart';
import '../../domain/services.dart';
import '../components/basics.dart';
import '../components/connection_banner.dart';
import '../components/fields.dart';
import '../components/overlays.dart';
import '../components/pressable.dart';
import '../devices/devices_page.dart';
import '../devices/zalo_devices.dart';
import '../l10n/strings.dart';
import '../platform/services.dart';
import '../shell/shell.dart';
import '../state/app_state.dart';
import '../theme/tokens.dart';
import '../theme/z_icons.dart';
import '../util/haptics.dart';
import '../vault/vault_screens.dart';
import 'business_tools_sheet.dart';
import 'login_qr_dialog.dart';
import 'oa_dialog.dart';
import 'profile_settings_sheets.dart';

class MePane extends ConsumerWidget {
  const MePane({super.key, required this.link});

  final ServerLink link;

  Future<void> _removeAccount(BuildContext context, AccountSummary a) async {
    final ok = await showZModal<bool>(context, builder: (_) => _TypedConfirmDialog(name: a.displayName));
    if (ok != true || !context.mounted) return;
    final failed = context.tr('actionFailed');
    try {
      await link.removeAccount(a.slot);
    } catch (_) {
      if (context.mounted) zToast(context, failed);
    }
  }

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final z = context.z;
    final wide = LayoutScope.wideOf(context);
    final manifest = ref.watch(manifestProvider);
    final active = ref.watch(activeAccountProvider.select((a) => a?.slot));
    final activeAccount = ref.watch(activeAccountProvider);
    final activeSession = ref.watch(activeSessionProvider);
    final admin = ref.watch(isAdminProvider);
    final themeMode = ref.watch(themeModeProvider);
    final language = ref.watch(languageProvider);
    final vault = ref.watch(vaultStateProvider);
    final platform = ref.watch(platformProvider);
    if (manifest == null) return ZSkeletonList(label: context.tr('loading'));

    return ColoredBox(
      color: z.layerSubtle,
      child: Column(
        children: [
          if (wide)
            Container(
              height: ZSizes.wideSearchRow,
              color: z.layer,
              alignment: Alignment.centerLeft,
              padding: const EdgeInsets.symmetric(horizontal: ZSpace.s16),
              child: Semantics(header: true, child: Text(context.tr('tabMe'), style: z.text.title)),
            )
          else
            ZPhoneHeader(
              child: Padding(
                padding: const EdgeInsets.symmetric(horizontal: ZSpace.s16),
                child: Align(alignment: Alignment.centerLeft, child: Semantics(header: true, child: Text(context.tr('tabMe')))),
              ),
            ),
          const ConnectionBanner(),
          Expanded(
            child: ListView(
              key: const Key('meList'),
              padding: const EdgeInsets.only(bottom: ZSpace.s24),
              children: [
                VaultRequestCards(link: link),
                ZCard(
                  title: context.tr('accounts'),
                  children: [
                    for (final a in manifest.accounts)
                      AccountRow(
                        key: Key('meAccount-${a.slot}'),
                        account: a,
                        session: link.account(a.slot),
                        active: a.slot == active,
                        onTap: () => switchAccount(ref, a.slot),
                        trailing: admin
                            ? Builder(
                                builder: (buttonContext) => ZIconButton(
                                  key: Key('meAccountMenu-${a.slot}'),
                                  icon: ZIcons.moreVert,
                                  label: context.tr('accountOptions', [a.displayName]),
                                  onPressed: () async {
                                    final box = buttonContext.findRenderObject()! as RenderBox;
                                    final picked = await showZMenu<String>(
                                      context,
                                      position: box.localToGlobal(Offset(0, box.size.height)),
                                      items: [
                                        ZMenuItem(value: 'relogin', label: context.tr(a.kind == AccountKind.oa ? 'oaUpdateTokens' : 'relogin'), icon: a.kind == AccountKind.oa ? ZIcons.key : ZIcons.qrCode),
                                        ZMenuItem(value: 'remove', label: context.tr('removeFromServer'), icon: ZIcons.delete, danger: true, dividerBefore: true),
                                      ],
                                    );
                                    if (!context.mounted) return;
                                    if (picked == 'relogin') await (a.kind == AccountKind.oa ? showOaTokens(context, link, a.slot) : showLoginQrDialog(context, link));
                                    if (picked == 'remove' && context.mounted) await _removeAccount(context, a);
                                  },
                                ),
                              )
                            : null,
                      ),
                    if (manifest.accounts.isEmpty)
                      Padding(padding: const EdgeInsets.all(ZSpace.s16), child: Text(context.tr('noAccounts'), key: const Key('meNoAccounts'), style: z.text.rowSub)),
                    if (admin) ZRow(key: const Key('addZaloAccount'), icon: ZIcons.personAdd, title: context.tr('addZaloAccount'), accent: true, onTap: () => showAddAccount(context, link)),
                  ],
                ),
                ZCard(
                  title: context.tr('devices'),
                  children: [
                    ZRow(
                      key: const Key('thisDevice'),
                      icon: ZIcons.devices,
                      title: manifest.deviceName,
                      subtitle: context.tr('thisDevice'),
                      trailing: ZChip(label: context.tr(admin ? 'roleAdmin' : 'roleMember'), tone: admin ? ZTone.info : ZTone.neutral),
                    ),
                    ZRow(
                      key: const Key('linkedDevices'),
                      icon: ZIcons.devices,
                      title: context.tr('linkedDevices'),
                      trailing: Icon(ZIcons.chevronRight, color: z.textTertiary, size: 20),
                      onTap: () => openDevicesPage(context, link),
                    ),
                    if (admin) ZRow(key: const Key('addDevice'), icon: ZIcons.link, title: context.tr('addDevice'), accent: true, onTap: () => showAddDeviceDialog(context, link)),
                  ],
                ),
                ZCard(
                  title: context.tr('zaloDevices'),
                  children: [
                    ZRow(
                      key: const Key('zaloDevicesEntry'),
                      icon: ZIcons.smartphone,
                      title: context.tr('zaloDevicesEntry'),
                      subtitle: context.tr('zaloDevicesHint'),
                      trailing: Icon(ZIcons.chevronRight, color: z.textTertiary, size: 20),
                      onTap: activeSession == null
                          ? null
                          : () => showZaloDevices(
                                context,
                                session: activeSession,
                                supported: capsOf(activeAccount).contains(AccountCapability.zaloDevices),
                              ),
                    ),
                  ],
                ),
                if (activeSession != null &&
                    (capsOf(activeAccount).contains(AccountCapability.profileSettings) ||
                        capsOf(activeAccount).contains(AccountCapability.friends) ||
                        capsOf(activeAccount).contains(AccountCapability.businessTools)))
                  ZCard(
                    title: context.tr('zaloAccountSection'),
                    children: [
                      if (capsOf(activeAccount).contains(AccountCapability.profileSettings)) ...[
                        ZRow(
                          key: const Key('meEditProfile'),
                          icon: ZIcons.user,
                          title: context.tr('editProfile'),
                          trailing: Icon(ZIcons.chevronRight, color: z.textTertiary, size: 20),
                          onTap: () => showEditProfileSheet(context, session: activeSession),
                        ),
                        ZRow(
                          key: const Key('meZaloSettings'),
                          icon: ZIcons.settings,
                          title: context.tr('zaloSettings'),
                          trailing: Icon(ZIcons.chevronRight, color: z.textTertiary, size: 20),
                          onTap: () => showZaloSettingsSheet(context, session: activeSession),
                        ),
                      ],
                      if (capsOf(activeAccount).contains(AccountCapability.friends))
                        ZRow(
                          key: const Key('meBlockedUsers'),
                          icon: ZIcons.block,
                          title: context.tr('blockedUsers'),
                          trailing: Icon(ZIcons.chevronRight, color: z.textTertiary, size: 20),
                          onTap: () => showBlockedUsersSheet(context, session: activeSession),
                        ),
                      if (capsOf(activeAccount).contains(AccountCapability.businessTools))
                        ZRow(
                          key: const Key('meBusinessTools'),
                          icon: ZIcons.storefront,
                          title: context.tr('businessTools'),
                          trailing: Icon(ZIcons.chevronRight, color: z.textTertiary, size: 20),
                          onTap: () => showBusinessToolsSheet(context, session: activeSession),
                        ),
                    ],
                  ),
                ZCard(
                  title: context.tr('security'),
                  children: [
                    ZRow(key: const Key('serverInfo'), icon: ZIcons.server, title: manifest.server.name, subtitle: context.tr('serverVersion', [manifest.server.version])),
                    ZRow(
                      key: const Key('fingerprint'),
                      icon: ZIcons.fingerprint,
                      title: context.tr('serverFingerprint'),
                      subtitleWidget: ZCodeGroups(value: manifest.server.fingerprint, size: 12, alignment: WrapAlignment.start),
                      trailing: ZIconButton(
                        key: const Key('fingerprintCopy'),
                        icon: ZIcons.copy,
                        label: context.tr('copyFingerprint'),
                        onPressed: () {
                          Clipboard.setData(ClipboardData(text: manifest.server.fingerprint));
                          zToast(context, context.tr('copied'));
                        },
                      ),
                    ),
                    ZRow(
                      key: const Key('vaultStatus'),
                      icon: ZIcons.encrypted,
                      title: context.tr(vault == VaultState.ready ? 'vaultReady' : 'vaultNotReady'),
                      subtitle: context.tr('vaultNote'),
                    ),
                    ZRow(
                      key: const Key('recoveryCodeEntry'),
                      icon: ZIcons.key,
                      title: context.tr('recoveryCode'),
                      subtitle: context.tr('recoveryEntryHint'),
                      trailing: Icon(ZIcons.chevronRight, color: z.textTertiary, size: 20),
                      onTap: () => showRecoveryCodeDialog(context),
                    ),
                  ],
                ),
                ZCard(
                  title: context.tr('appearance'),
                  padding: const EdgeInsets.all(ZSpace.s12),
                  children: [
                    Text(context.tr('theme'), style: z.text.label),
                    const SizedBox(height: ZSpace.s4),
                    ZSegmented<ThemeMode>(
                      key: const Key('themeSwitch'),
                      segments: [(ThemeMode.system, context.tr('themeSystem')), (ThemeMode.light, context.tr('themeLight')), (ThemeMode.dark, context.tr('themeDark'))],
                      selected: themeMode,
                      onChanged: (v) => ref.read(themeModeProvider.notifier).set(v),
                    ),
                    const SizedBox(height: ZSpace.s12),
                    Text(context.tr('language'), style: z.text.label),
                    const SizedBox(height: ZSpace.s4),
                    ZSegmented<String>(
                      key: const Key('languageSwitch'),
                      segments: const [('vi', 'Tiếng Việt'), ('en', 'English')],
                      selected: language ?? context.s.language,
                      onChanged: (v) => ref.read(languageProvider.notifier).set(v),
                    ),
                  ],
                ),
                ZCard(
                  title: context.tr('notifications'),
                  children: [
                    ZSwitchRow(
                      key: const Key('notifyEnabled'),
                      icon: ZIcons.bell,
                      title: context.tr('notifyEnable'),
                      value: ref.watch(notifyEnabledProvider),
                      onChanged: (v) {
                        ref.read(notifyEnabledProvider.notifier).set(v);
                        if (v) platform.notifications.requestPermission();
                      },
                    ),
                    ZSwitchRow(
                      key: const Key('notifyPreview'),
                      icon: ZIcons.eye,
                      title: context.tr('notifyPreview'),
                      subtitle: context.tr('notifyPreviewHint'),
                      value: ref.watch(notifyPreviewProvider),
                      onChanged: ref.watch(notifyEnabledProvider) ? (v) => ref.read(notifyPreviewProvider.notifier).set(v) : null,
                    ),
                    ZSwitchRow(
                      key: const Key('hapticsEnabled'),
                      icon: ZIcons.haptics,
                      title: context.tr('hapticsEnable'),
                      subtitle: context.tr('hapticsHint'),
                      value: ref.watch(hapticsEnabledProvider),
                      onChanged: (v) {
                        ref.read(hapticsEnabledProvider.notifier).set(v);
                        ZHaptics.enabled = v;
                        if (v) ZHaptics.selection();
                      },
                    ),
                  ],
                ),
                const SizedBox(height: ZSpace.s16),
                ZCard(children: [ZRow(key: const Key('unpair'), icon: ZIcons.linkOff, title: context.tr('unpair'), danger: true, onTap: () => confirmUnpair(context, ref))]),
                const SizedBox(height: ZSpace.s16),
                Center(
                  child: Text(
                    context.tr('appVersion', [platform.appVersion]),
                    key: const Key('appVersion'),
                    textAlign: TextAlign.center,
                    style: z.text.meta.copyWith(color: z.textSecondary),
                  ),
                ),
                Center(
                  child: ZButton(
                    key: const Key('licenses'),
                    label: context.tr('licenses'),
                    variant: ZButtonVariant.text,
                    small: true,
                    onPressed: () => showLicensePage(context: context, applicationName: 'zalos', applicationVersion: platform.appVersion),
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

/// Destructive confirmation that requires typing the object's name.
class _TypedConfirmDialog extends StatefulWidget {
  const _TypedConfirmDialog({required this.name});

  final String name;

  @override
  State<_TypedConfirmDialog> createState() => _TypedConfirmDialogState();
}

class _TypedConfirmDialogState extends State<_TypedConfirmDialog> {
  final TextEditingController _typed = TextEditingController();

  @override
  void initState() {
    super.initState();
    _typed.addListener(() => setState(() {}));
  }

  @override
  void dispose() {
    _typed.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final z = context.z;
    final matches = _typed.text.trim() == widget.name.trim();
    return ZDialogScaffold(
      key: const Key('removeAccountDialog'),
      title: context.tr('removeAccountTitle', [widget.name]),
      actions: [
        ZButton(label: context.tr('cancel'), variant: ZButtonVariant.text, onPressed: () => Navigator.pop(context, false)),
        ZButton(key: const Key('removeAccountConfirm'), label: context.tr('removeFromServer'), variant: ZButtonVariant.destructive, onPressed: matches ? () => Navigator.pop(context, true) : null),
      ],
      child: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Text(context.tr('removeAccountBody'), style: z.text.rowSub.copyWith(color: z.textSecondary)),
          const SizedBox(height: ZSpace.s12),
          ZTextField(key: const Key('removeAccountField'), controller: _typed, label: context.tr('typeNameToConfirm', [widget.name]), hint: widget.name, autofocus: true, autocorrect: false),
        ],
      ),
    );
  }
}
