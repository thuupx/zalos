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

Future<void> showEditProfileSheet(
  BuildContext context, {
  required AccountSession session,
}) =>
    showZModal<void>(
      context,
      builder: (_) => _EditProfileSheet(session: session),
    );

class _EditProfileSheet extends StatefulWidget {
  const _EditProfileSheet({required this.session});
  final AccountSession session;

  @override
  State<_EditProfileSheet> createState() => _EditProfileSheetState();
}

class _EditProfileSheetState extends State<_EditProfileSheet> {
  final TextEditingController _name = TextEditingController();
  final TextEditingController _dob = TextEditingController();
  final TextEditingController _bio = TextEditingController();
  int _gender = 0;
  List<({String photoId, String url})> _avatars = const [];
  bool _loading = true;
  bool _busy = false;

  @override
  void initState() {
    super.initState();
    _load();
  }

  @override
  void dispose() {
    _name.dispose();
    _dob.dispose();
    _bio.dispose();
    super.dispose();
  }

  Future<void> _load() async {
    try {
      final profile = await widget.session.fetchProfile();
      final avatars = await widget.session.avatarList();
      if (!mounted) return;
      setState(() {
        _name.text = profile.displayName;
        _dob.text = profile.dob;
        _bio.text = profile.bio;
        _gender = profile.gender;
        _avatars = avatars;
        _loading = false;
      });
    } catch (_) {
      if (mounted) setState(() => _loading = false);
    }
  }

  Future<void> _save() async {
    if (_busy || _name.text.trim().isEmpty) return;
    setState(() => _busy = true);
    try {
      await widget.session.updateProfile(
        name: _name.text.trim(),
        dob: _dob.text.trim().isEmpty ? '2000-01-01' : _dob.text.trim(),
        gender: _gender,
      );
      await widget.session.updateProfileBio(_bio.text.trim());
      if (mounted) {
        zToast(context, context.tr('actionSaved'));
        Navigator.of(context).pop();
      }
    } catch (_) {
      if (mounted) zToast(context, context.tr('actionFailed'));
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final z = context.z;
    return ZDialogScaffold(
      key: const Key('editProfileSheet'),
      title: context.tr('editProfile'),
      showClose: true,
      actions: [
        ZButton(
          key: const Key('editProfileSave'),
          label: context.tr('save'),
          onPressed: _loading || _busy ? null : _save,
        ),
      ],
      child: _loading
          ? const ZSkeletonRow(avatar: 40, height: 64)
          : ConstrainedBox(
              constraints: const BoxConstraints(maxHeight: 460),
              child: ListView(
                shrinkWrap: true,
                children: [
                  ZTextField(
                    key: const Key('profileNameField'),
                    controller: _name,
                    label: context.tr('displayNameLabel'),
                  ),
                  const SizedBox(height: ZSpace.s8),
                  ZTextField(
                    key: const Key('profileDobField'),
                    controller: _dob,
                    label: context.tr('dobLabel'),
                  ),
                  const SizedBox(height: ZSpace.s8),
                  Text(context.tr('genderLabel'), style: z.text.label),
                  const SizedBox(height: ZSpace.s4),
                  ZSegmented<int>(
                    segments: [
                      (0, context.tr('genderMale')),
                      (1, context.tr('genderFemale')),
                    ],
                    selected: _gender,
                    onChanged: (v) => setState(() => _gender = v),
                  ),
                  const SizedBox(height: ZSpace.s8),
                  ZTextField(
                    key: const Key('profileBioField'),
                    controller: _bio,
                    label: context.tr('bioLabel'),
                  ),
                  if (_avatars.isNotEmpty) ...[
                    const SizedBox(height: ZSpace.s12),
                    Text(context.tr('avatarHistoryTitle'), style: z.text.labelStrong),
                    for (final av in _avatars)
                      ZRow(
                        icon: ZIcons.image,
                        title: av.photoId,
                        trailing: Row(
                          mainAxisSize: MainAxisSize.min,
                          children: [
                            ZButton(
                              label: context.tr('reuseAvatar'),
                              small: true,
                              variant: ZButtonVariant.text,
                              onPressed: () async {
                                await widget.session.reuseAvatar(av.photoId);
                                if (context.mounted) zToast(context, context.tr('actionSaved'));
                              },
                            ),
                            ZButton(
                              label: context.tr('deleteAvatarAction'),
                              small: true,
                              variant: ZButtonVariant.text,
                              onPressed: () async {
                                await widget.session.deleteAvatars([av.photoId]);
                                await _load();
                              },
                            ),
                          ],
                        ),
                      ),
                  ],
                ],
              ),
            ),
    );
  }
}

Future<void> showZaloSettingsSheet(
  BuildContext context, {
  required AccountSession session,
}) =>
    showZModal<void>(
      context,
      builder: (_) => _ZaloSettingsSheet(session: session),
    );

class _ZaloSettingsSheet extends StatefulWidget {
  const _ZaloSettingsSheet({required this.session});
  final AccountSession session;

  @override
  State<_ZaloSettingsSheet> createState() => _ZaloSettingsSheetState();
}

class _ZaloSettingsSheetState extends State<_ZaloSettingsSheet> {
  Map<String, dynamic> _settings = const {};
  bool _loading = true;

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    try {
      final data = await widget.session.zaloSettings();
      if (mounted) setState(() { _settings = data; _loading = false; });
    } catch (_) {
      if (mounted) setState(() => _loading = false);
    }
  }

  bool _flag(String key) => _settings[key] == 1 || _settings[key] == true;

  Future<void> _setSetting(String key, bool v) async {
    setState(() => _settings = {..._settings, key: v ? 1 : 0});
    await widget.session.updateZaloSetting(key, v ? 1 : 0);
  }

  @override
  Widget build(BuildContext context) {
    final z = context.z;
    final activeStatus = _settings['activeStatus'] != false;
    final lang = (_settings['language']?.toString() ?? 'vi') == 'en' ? 'en' : 'vi';
    return ZDialogScaffold(
      key: const Key('zaloSettingsSheet'),
      title: context.tr('zaloSettings'),
      showClose: true,
      child: _loading
          ? const ZSkeletonRow(avatar: 32, height: 48)
          : Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                ZSwitchRow(
                  key: const Key('zaloActiveStatusSwitch'),
                  icon: ZIcons.eye,
                  title: context.tr('activeStatusToggle'),
                  value: activeStatus,
                  onChanged: (v) async {
                    setState(() => _settings = {..._settings, 'activeStatus': v});
                    await widget.session.updateActiveStatus(v);
                  },
                ),
                ZSwitchRow(
                  key: const Key('zaloFindPhoneSwitch'),
                  icon: ZIcons.search,
                  title: context.tr('settingAllowFindPhone'),
                  value: _flag('allow_find_phone'),
                  onChanged: (v) => _setSetting('allow_find_phone', v),
                ),
                ZSwitchRow(
                  icon: ZIcons.chat,
                  title: context.tr('settingStrangerMsg'),
                  value: _flag('receive_stranger_msg'),
                  onChanged: (v) => _setSetting('receive_stranger_msg', v),
                ),
                ZSwitchRow(
                  icon: ZIcons.markRead,
                  title: context.tr('settingSeenStatus'),
                  value: _flag('display_seen_status'),
                  onChanged: (v) => _setSetting('display_seen_status', v),
                ),
                const SizedBox(height: ZSpace.s8),
                Text(context.tr('language'), style: z.text.label),
                const SizedBox(height: ZSpace.s4),
                ZSegmented<String>(
                  key: const Key('zaloLangSwitch'),
                  segments: const [('vi', 'Tiếng Việt'), ('en', 'English')],
                  selected: lang,
                  onChanged: (v) async {
                    setState(() => _settings = {..._settings, 'language': v});
                    await widget.session.updateZaloLang(v);
                  },
                ),
              ],
            ),
    );
  }
}

Future<void> showBlockedUsersSheet(
  BuildContext context, {
  required AccountSession session,
}) =>
    showZModal<void>(
      context,
      builder: (_) => _BlockedUsersSheet(session: session),
    );

class _BlockedUsersSheet extends StatefulWidget {
  const _BlockedUsersSheet({required this.session});
  final AccountSession session;

  @override
  State<_BlockedUsersSheet> createState() => _BlockedUsersSheetState();
}

class _BlockedUsersSheetState extends State<_BlockedUsersSheet> {
  List<Contact> _users = const [];
  bool _loading = true;

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    setState(() => _loading = true);
    try {
      final list = await widget.session.blockList();
      if (mounted) setState(() => _users = list);
    } finally {
      if (mounted) setState(() => _loading = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final z = context.z;
    return ZDialogScaffold(
      key: const Key('blockedUsersSheet'),
      title: context.tr('blockedUsers'),
      showClose: true,
      child: ConstrainedBox(
        constraints: const BoxConstraints(maxHeight: 360),
        child: _loading
            ? const ZSkeletonRow(avatar: 36, height: 48)
            : _users.isEmpty
                ? Padding(
                    padding: const EdgeInsets.all(ZSpace.s16),
                    child: Text(context.tr('blockedUsersEmpty'), style: z.text.rowSub),
                  )
                : ListView.builder(
                    shrinkWrap: true,
                    itemCount: _users.length,
                    itemBuilder: (context, i) {
                      final u = _users[i];
                      return ZRow(
                        key: Key('blockedUser-${u.uid}'),
                        icon: ZIcons.block,
                        title: u.displayName.isEmpty ? u.uid : u.displayName,
                        trailing: ZButton(
                          label: context.tr('unblockAction'),
                          small: true,
                          variant: ZButtonVariant.secondary,
                          onPressed: () async {
                            await widget.session.unblockUser(u.uid);
                            await _load();
                          },
                        ),
                      );
                    },
                  ),
      ),
    );
  }
}
