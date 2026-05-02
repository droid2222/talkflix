import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../../../app/theme/theme_mode_controller.dart';
import '../../../core/auth/session_controller.dart';
import '../../../core/config/storage_keys.dart';
import '../../upgrade/presentation/pro_access_sheet.dart';

class ProfileSettingsScreen extends ConsumerStatefulWidget {
  const ProfileSettingsScreen({super.key, this.section = 'hub'});

  final String section;

  @override
  ConsumerState<ProfileSettingsScreen> createState() =>
      _ProfileSettingsScreenState();
}

class _ProfileSettingsScreenState extends ConsumerState<ProfileSettingsScreen> {
  bool _chatAutoTranslateIncoming = false;
  bool _chatShowTranslationOnLongPress = false;
  bool _chatEnableWritingCorrections = false;
  String _chatCorrectionTone = 'friendly';
  bool _chatPlayVoiceNotesAuto = false;
  bool _chatSettingsLoading = true;
  bool _googleBound = true;
  bool _facebookBound = false;
  bool _appleBound = false;
  String _phoneNumber = '';

  @override
  void initState() {
    super.initState();
    Future<void>.microtask(_loadChatLearningSettings);
    Future<void>.microtask(_loadAccountBindingPrefs);
  }

  @override
  void dispose() {
    super.dispose();
  }

  void _showSnack(String message) {
    if (!mounted) return;
    ScaffoldMessenger.of(
      context,
    ).showSnackBar(SnackBar(content: Text(message)));
  }

  Future<void> _loadChatLearningSettings() async {
    final prefs = await ref.read(sharedPreferencesProvider.future);
    if (!mounted) return;
    setState(() {
      _chatAutoTranslateIncoming =
          prefs.getBool(StorageKeys.chatAutoTranslateIncoming) ?? false;
      _chatShowTranslationOnLongPress =
          prefs.getBool(StorageKeys.chatShowTranslationOnLongPress) ?? false;
      _chatEnableWritingCorrections =
          prefs.getBool(StorageKeys.chatEnableWritingCorrections) ?? false;
      _chatCorrectionTone =
          prefs.getString(StorageKeys.chatCorrectionTone) ?? 'friendly';
      _chatPlayVoiceNotesAuto =
          prefs.getBool(StorageKeys.chatPlayVoiceNotesAuto) ?? false;
      _chatSettingsLoading = false;
    });
  }

  Future<void> _setChatPrefBool(String key, bool value) async {
    final prefs = await ref.read(sharedPreferencesProvider.future);
    await prefs.setBool(key, value);
  }

  Future<void> _setChatPrefString(String key, String value) async {
    final prefs = await ref.read(sharedPreferencesProvider.future);
    await prefs.setString(key, value);
  }

  Future<void> _loadAccountBindingPrefs() async {
    final prefs = await ref.read(sharedPreferencesProvider.future);
    if (!mounted) return;
    setState(() {
      _googleBound = prefs.getBool(StorageKeys.accountGoogleBound) ?? true;
      _facebookBound = prefs.getBool(StorageKeys.accountFacebookBound) ?? false;
      _appleBound = prefs.getBool(StorageKeys.accountAppleBound) ?? false;
      _phoneNumber = prefs.getString(StorageKeys.accountPhoneNumber) ?? '';
    });
  }

  Future<void> _setGoogleBound(bool value) async {
    setState(() => _googleBound = value);
    final prefs = await ref.read(sharedPreferencesProvider.future);
    await prefs.setBool(StorageKeys.accountGoogleBound, value);
  }

  Future<void> _setFacebookBound(bool value) async {
    setState(() => _facebookBound = value);
    final prefs = await ref.read(sharedPreferencesProvider.future);
    await prefs.setBool(StorageKeys.accountFacebookBound, value);
  }

  Future<void> _setAppleBound(bool value) async {
    setState(() => _appleBound = value);
    final prefs = await ref.read(sharedPreferencesProvider.future);
    await prefs.setBool(StorageKeys.accountAppleBound, value);
  }

  Future<void> _setPhoneNumber(String value) async {
    setState(() => _phoneNumber = value);
    final prefs = await ref.read(sharedPreferencesProvider.future);
    await prefs.setString(StorageKeys.accountPhoneNumber, value);
  }

  Future<void> _handleProToggle({
    required String featureName,
    required bool nextValue,
    required bool currentValue,
    required ValueSetter<bool> assignState,
    required String prefKey,
    required bool isProLike,
  }) async {
    if (nextValue == currentValue) return;
    if (!isProLike && nextValue) {
      await showProAccessSheet(
        context: context,
        ref: ref,
        featureName: featureName,
        onUnlocked: () {
          if (!mounted) return;
          setState(() => assignState(true));
          unawaited(_setChatPrefBool(prefKey, true));
        },
      );
      return;
    }
    setState(() => assignState(nextValue));
    await _setChatPrefBool(prefKey, nextValue);
  }

  Widget _buildAccountContent(ThemeData theme, ColorScheme scheme) {
    final user = ref.watch(sessionControllerProvider).user;
    final talkflixId = user?.username.trim().isNotEmpty == true
        ? '@${user!.username}'
        : 'Not set';
    final email = user?.email.trim().isNotEmpty == true
        ? user!.email
        : 'Not set';
    return ListView(
      padding: const EdgeInsets.fromLTRB(16, 12, 16, 24),
      children: [
        _SettingsMenuCard(
          children: [
            _AccountItemRow(
              title: 'Talkflix ID',
              value: talkflixId,
              onTap: () => _showSnack('Username change flow is coming soon.'),
            ),
            _AccountItemRow(
              title: 'Email',
              value: email,
              onTap: () => _showEmailActions(email),
            ),
            _AccountItemRow(
              title: 'Password',
              value: '',
              onTap: () => context.go('/forgot-password'),
            ),
          ],
        ),
        const SizedBox(height: 10),
        Text(
          'Bind more login methods to ensure account security.',
          style: theme.textTheme.bodySmall?.copyWith(
            color: scheme.onSurfaceVariant,
          ),
        ),
        const SizedBox(height: 10),
        _SettingsMenuCard(
          children: [
            _AccountItemRow(
              title: 'Phone number',
              value: _phoneNumber.isEmpty ? 'Not bound' : _phoneNumber,
              onTap: _showPhoneBindingSheet,
            ),
            _AccountItemRow(
              title: 'Facebook',
              value: _facebookBound ? 'Bound' : 'Not bound',
              onTap: _showFacebookBindingSheet,
            ),
            _AccountSwitchRow(
              title: 'Google',
              value: _googleBound,
              onChanged: (value) async {
                await _setGoogleBound(value);
                _showSnack(value ? 'Google linked.' : 'Google unlinked.');
              },
            ),
            _AccountItemRow(
              title: 'Apple ID',
              value: _appleBound ? 'Bound' : 'Not bound',
              onTap: _showAppleBindingSheet,
            ),
          ],
        ),
        const SizedBox(height: 16),
        FilledButton(
          style: FilledButton.styleFrom(
            minimumSize: const Size.fromHeight(52),
            shape: RoundedRectangleBorder(
              borderRadius: BorderRadius.circular(999),
            ),
            backgroundColor: scheme.surfaceContainerHigh,
            foregroundColor: scheme.onSurface,
          ),
          onPressed: () async {
            await ref.read(sessionControllerProvider.notifier).signOut();
            if (!mounted) return;
            context.go('/login');
          },
          child: const Text('Log Out'),
        ),
        const SizedBox(height: 18),
        Center(
          child: TextButton(
            onPressed: _confirmDeleteAccount,
            child: Text(
              'Delete Account',
              style: theme.textTheme.bodyMedium?.copyWith(
                color: scheme.onSurfaceVariant.withValues(alpha: 0.65),
              ),
            ),
          ),
        ),
      ],
    );
  }

  Widget _buildChatSettingsContent() {
    return SingleChildScrollView(
      padding: const EdgeInsets.fromLTRB(16, 12, 16, 24),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          _SettingsSwitchTile(
            title: 'Show "Translate" in message actions',
            subtitle:
                'Adds a quick translate action when you long-press messages.',
            value: _chatShowTranslationOnLongPress,
            onChanged: (value) async {
              setState(() => _chatShowTranslationOnLongPress = value);
              await _setChatPrefBool(
                StorageKeys.chatShowTranslationOnLongPress,
                value,
              );
            },
          ),
          _SettingsSwitchTile(
            title: 'Auto-play received voice notes',
            subtitle: 'Hands-free listening while you are in a chat.',
            value: _chatPlayVoiceNotesAuto,
            onChanged: (value) async {
              setState(() => _chatPlayVoiceNotesAuto = value);
              await _setChatPrefBool(StorageKeys.chatPlayVoiceNotesAuto, value);
            },
          ),
        ],
      ),
    );
  }

  Widget _buildLearningSettingsContent(bool isProLike) {
    final theme = Theme.of(context);
    return SingleChildScrollView(
      padding: const EdgeInsets.fromLTRB(16, 12, 16, 24),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          _SettingsSwitchTile(
            title: 'Auto-translate incoming chat messages',
            subtitle: 'Pro feature for instant learning flow.',
            value: _chatAutoTranslateIncoming,
            trailing: isProLike ? null : const ProFeatureBadge(compact: true),
            onChanged: (value) => _handleProToggle(
              featureName: 'Auto-translate',
              nextValue: value,
              currentValue: _chatAutoTranslateIncoming,
              assignState: (next) => _chatAutoTranslateIncoming = next,
              prefKey: StorageKeys.chatAutoTranslateIncoming,
              isProLike: isProLike,
            ),
          ),
          _SettingsSwitchTile(
            title: 'Writing correction suggestions',
            subtitle:
                'Pro feature for grammar and natural phrasing suggestions.',
            value: _chatEnableWritingCorrections,
            trailing: isProLike ? null : const ProFeatureBadge(compact: true),
            onChanged: (value) => _handleProToggle(
              featureName: 'Writing corrections',
              nextValue: value,
              currentValue: _chatEnableWritingCorrections,
              assignState: (next) => _chatEnableWritingCorrections = next,
              prefKey: StorageKeys.chatEnableWritingCorrections,
              isProLike: isProLike,
            ),
          ),
          const SizedBox(height: 8),
          Text(
            'Correction tone',
            style: theme.textTheme.titleSmall?.copyWith(
              fontWeight: FontWeight.w700,
            ),
          ),
          const SizedBox(height: 8),
          SegmentedButton<String>(
            segments: const [
              ButtonSegment<String>(
                value: 'friendly',
                icon: Icon(Icons.favorite_border_rounded),
                label: Text('Friendly'),
              ),
              ButtonSegment<String>(
                value: 'balanced',
                icon: Icon(Icons.balance_rounded),
                label: Text('Balanced'),
              ),
              ButtonSegment<String>(
                value: 'strict',
                icon: Icon(Icons.school_outlined),
                label: Text('Strict'),
              ),
            ],
            selected: <String>{_chatCorrectionTone},
            onSelectionChanged: (selection) async {
              if (selection.isEmpty) return;
              final nextTone = selection.first;
              setState(() => _chatCorrectionTone = nextTone);
              await _setChatPrefString(
                StorageKeys.chatCorrectionTone,
                nextTone,
              );
            },
          ),
        ],
      ),
    );
  }

  Future<void> _showEmailActions(String email) async {
    await showModalBottomSheet<void>(
      context: context,
      showDragHandle: true,
      builder: (context) => SafeArea(
        child: Wrap(
          children: [
            ListTile(
              leading: const Icon(Icons.content_copy_rounded),
              title: const Text('Copy email'),
              onTap: () {
                Navigator.of(context).pop();
                Clipboard.setData(ClipboardData(text: email));
                _showSnack('Email copied.');
              },
            ),
            ListTile(
              leading: const Icon(Icons.password_rounded),
              title: const Text('Reset password'),
              onTap: () {
                Navigator.of(context).pop();
                this.context.go('/forgot-password');
              },
            ),
            ListTile(
              leading: const Icon(Icons.info_outline_rounded),
              title: const Text('Change email'),
              subtitle: const Text(
                'Email change backend flow is not available yet.',
              ),
              onTap: () {
                Navigator.of(context).pop();
                _showSnack('Email change will be enabled in a backend update.');
              },
            ),
          ],
        ),
      ),
    );
  }

  Future<void> _showPhoneBindingSheet() async {
    final controller = TextEditingController(text: _phoneNumber);
    await showModalBottomSheet<void>(
      context: context,
      isScrollControlled: true,
      showDragHandle: true,
      builder: (context) => SafeArea(
        child: Padding(
          padding: EdgeInsets.fromLTRB(
            16,
            8,
            16,
            20 + MediaQuery.of(context).viewInsets.bottom,
          ),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(
                _phoneNumber.isEmpty
                    ? 'Bind phone number'
                    : 'Update phone number',
                style: Theme.of(
                  context,
                ).textTheme.titleMedium?.copyWith(fontWeight: FontWeight.w800),
              ),
              const SizedBox(height: 10),
              TextField(
                controller: controller,
                keyboardType: TextInputType.phone,
                decoration: const InputDecoration(
                  hintText: '+1 234 567 8900',
                  labelText: 'Phone number',
                ),
              ),
              const SizedBox(height: 12),
              Row(
                children: [
                  Expanded(
                    child: OutlinedButton(
                      onPressed: () => Navigator.of(context).pop(),
                      child: const Text('Cancel'),
                    ),
                  ),
                  const SizedBox(width: 10),
                  Expanded(
                    child: FilledButton(
                      onPressed: () async {
                        final normalized = controller.text.trim();
                        await _setPhoneNumber(normalized);
                        if (!context.mounted) return;
                        Navigator.of(context).pop();
                        _showSnack(
                          normalized.isEmpty
                              ? 'Phone number removed.'
                              : 'Phone number saved.',
                        );
                      },
                      child: const Text('Save'),
                    ),
                  ),
                ],
              ),
            ],
          ),
        ),
      ),
    );
    controller.dispose();
  }

  Future<void> _showFacebookBindingSheet() async {
    await showModalBottomSheet<void>(
      context: context,
      showDragHandle: true,
      builder: (context) => SafeArea(
        child: Wrap(
          children: [
            ListTile(
              leading: Icon(
                _facebookBound ? Icons.link_off_rounded : Icons.link_rounded,
              ),
              title: Text(_facebookBound ? 'Unbind Facebook' : 'Bind Facebook'),
              onTap: () async {
                Navigator.of(context).pop();
                await _setFacebookBound(!_facebookBound);
                _showSnack(
                  _facebookBound ? 'Facebook linked.' : 'Facebook unlinked.',
                );
              },
            ),
          ],
        ),
      ),
    );
  }

  Future<void> _showAppleBindingSheet() async {
    await showModalBottomSheet<void>(
      context: context,
      showDragHandle: true,
      builder: (context) => SafeArea(
        child: Wrap(
          children: [
            ListTile(
              leading: Icon(
                _appleBound ? Icons.link_off_rounded : Icons.link_rounded,
              ),
              title: Text(_appleBound ? 'Unbind Apple ID' : 'Bind Apple ID'),
              onTap: () async {
                Navigator.of(context).pop();
                await _setAppleBound(!_appleBound);
                _showSnack(
                  _appleBound ? 'Apple ID linked.' : 'Apple ID unlinked.',
                );
              },
            ),
          ],
        ),
      ),
    );
  }

  Future<void> _confirmDeleteAccount() async {
    final confirmController = TextEditingController();
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('Delete account?'),
        content: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            const Text(
              'This action is permanent. Type DELETE to confirm and sign out.',
            ),
            const SizedBox(height: 10),
            TextField(
              controller: confirmController,
              decoration: const InputDecoration(hintText: 'Type DELETE'),
            ),
          ],
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(context).pop(false),
            child: const Text('Cancel'),
          ),
          FilledButton(
            onPressed: () {
              final ok =
                  confirmController.text.trim().toUpperCase() == 'DELETE';
              Navigator.of(context).pop(ok);
            },
            child: const Text('Delete'),
          ),
        ],
      ),
    );
    confirmController.dispose();
    if (confirmed != true) {
      _showSnack('Delete account cancelled.');
      return;
    }
    await ref.read(sessionControllerProvider.notifier).signOut();
    if (!mounted) return;
    context.go('/login');
    _showSnack('Account deletion request submitted.');
  }

  Widget _buildAppearanceContent(ThemeMode themeMode) {
    return ListView(
      padding: const EdgeInsets.fromLTRB(16, 12, 16, 24),
      children: [
        SegmentedButton<ThemeMode>(
          segments: const [
            ButtonSegment<ThemeMode>(
              value: ThemeMode.system,
              label: Text('System'),
              icon: Icon(Icons.brightness_auto_outlined),
            ),
            ButtonSegment<ThemeMode>(
              value: ThemeMode.light,
              label: Text('Light'),
              icon: Icon(Icons.light_mode_outlined),
            ),
            ButtonSegment<ThemeMode>(
              value: ThemeMode.dark,
              label: Text('Dark'),
              icon: Icon(Icons.dark_mode_outlined),
            ),
          ],
          selected: <ThemeMode>{themeMode},
          onSelectionChanged: (selection) {
            if (selection.isEmpty) return;
            ref
                .read(themeModeControllerProvider.notifier)
                .setThemeMode(selection.first);
          },
        ),
      ],
    );
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;
    final themeMode = ref.watch(themeModeControllerProvider);
    final user = ref.watch(sessionControllerProvider).user;
    final isProLike = user?.isProLike ?? false;
    final section = widget.section;

    if (section != 'hub') {
      final title = switch (section) {
        'account' => 'Account',
        'chat' => 'Chat Settings',
        'learning' => 'Learning Settings',
        'appearance' => 'Appearance',
        'about' => 'About',
        'help' => 'Help',
        _ => 'Settings',
      };
      return Scaffold(
        backgroundColor: scheme.surface,
        appBar: AppBar(title: Text(title)),
        body: switch (section) {
          'account' => _buildAccountContent(theme, scheme),
          'chat' =>
            _chatSettingsLoading
                ? const Center(child: CircularProgressIndicator())
                : _buildChatSettingsContent(),
          'learning' =>
            _chatSettingsLoading
                ? const Center(child: CircularProgressIndicator())
                : _buildLearningSettingsContent(isProLike),
          'appearance' => _buildAppearanceContent(themeMode),
          'about' => const _SettingsSimpleBody(
            text:
                'Talkflix helps language learners practice through direct chat, voice rooms, and live broadcasts.',
          ),
          'help' => const _SettingsSimpleBody(
            text:
                'Help center is coming soon. Reach out in app support anytime.',
          ),
          _ => const SizedBox.shrink(),
        },
      );
    }

    return Scaffold(
      backgroundColor: scheme.surface,
      appBar: AppBar(title: const Text('Settings')),
      body: ListView(
        padding: const EdgeInsets.fromLTRB(16, 12, 16, 28),
        children: [
          _SettingsMenuCard(
            children: [
              _SettingsMenuTile(
                icon: Icons.person_outline_rounded,
                iconColor: const Color(0xFFE50914),
                title: 'Account',
                onTap: () => context.push('/app/profile/settings/account'),
              ),
              _SettingsMenuTile(
                icon: Icons.notifications_none_rounded,
                iconColor: const Color(0xFFE53945),
                title: 'Notifications',
                onTap: () => context.push('/app/notifications'),
              ),
              _SettingsMenuTile(
                icon: Icons.shield_outlined,
                iconColor: const Color(0xFFB71C1C),
                title: 'Privacy',
                onTap: () => _showSnack('Privacy settings are coming soon.'),
              ),
              _SettingsMenuTile(
                icon: Icons.chat_bubble_outline_rounded,
                iconColor: const Color(0xFFC62828),
                title: 'Chat Settings',
                onTap: _chatSettingsLoading
                    ? null
                    : () => context.push('/app/profile/settings/chat'),
              ),
              _SettingsMenuTile(
                icon: Icons.menu_book_rounded,
                iconColor: const Color(0xFFD32F2F),
                title: 'Learning Settings',
                trailing: !isProLike
                    ? const ProFeatureBadge(compact: true)
                    : null,
                onTap: _chatSettingsLoading
                    ? null
                    : () => context.push('/app/profile/settings/learning'),
              ),
            ],
          ),
          const SizedBox(height: 14),
          _SettingsMenuCard(
            children: [
              _SettingsMenuTile(
                icon: Icons.language_rounded,
                iconColor: const Color(0xFFE50914),
                title: 'App Language',
                onTap: () =>
                    _showSnack('App language settings are coming soon.'),
              ),
              _SettingsMenuTile(
                icon: Icons.dark_mode_outlined,
                iconColor: const Color(0xFFAD1457),
                title: 'Dark Mode',
                onTap: () => context.push('/app/profile/settings/appearance'),
              ),
            ],
          ),
          const SizedBox(height: 14),
          _SettingsMenuCard(
            children: [
              _SettingsMenuTile(
                icon: Icons.star_rounded,
                iconColor: const Color(0xFFF44336),
                title: 'Rate Talkflix',
                onTap: () => _showSnack('Thanks! Rate flow is coming soon.'),
              ),
              _SettingsMenuTile(
                icon: Icons.info_outline_rounded,
                iconColor: const Color(0xFFD84315),
                title: 'About',
                onTap: () => context.push('/app/profile/settings/about'),
              ),
            ],
          ),
          const SizedBox(height: 14),
          _SettingsMenuCard(
            children: [
              _SettingsMenuTile(
                icon: Icons.help_outline_rounded,
                iconColor: const Color(0xFFEF5350),
                title: 'Help',
                onTap: () => context.push('/app/profile/settings/help'),
              ),
              _SettingsMenuTile(
                icon: Icons.cleaning_services_outlined,
                iconColor: const Color(0xFFC62828),
                title: 'Manage Storage',
                onTap: () => context.push('/app/profile/diagnostics'),
              ),
            ],
          ),
        ],
      ),
    );
  }
}

class _SettingsSwitchTile extends StatelessWidget {
  const _SettingsSwitchTile({
    required this.title,
    required this.subtitle,
    required this.value,
    required this.onChanged,
    this.trailing,
  });

  final String title;
  final String subtitle;
  final bool value;
  final ValueChanged<bool> onChanged;
  final Widget? trailing;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Padding(
      padding: const EdgeInsets.only(bottom: 10),
      child: Container(
        padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 8),
        decoration: BoxDecoration(
          color: theme.colorScheme.surfaceContainerHigh,
          borderRadius: BorderRadius.circular(14),
        ),
        child: Row(
          children: [
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    title,
                    style: theme.textTheme.titleSmall?.copyWith(
                      fontWeight: FontWeight.w700,
                    ),
                  ),
                  const SizedBox(height: 2),
                  Text(
                    subtitle,
                    style: theme.textTheme.bodySmall?.copyWith(
                      color: theme.colorScheme.onSurfaceVariant,
                    ),
                  ),
                ],
              ),
            ),
            const SizedBox(width: 10),
            if (trailing != null) ...[trailing!, const SizedBox(width: 6)],
            Switch(value: value, onChanged: onChanged),
          ],
        ),
      ),
    );
  }
}

class _SettingsMenuCard extends StatelessWidget {
  const _SettingsMenuCard({required this.children});

  final List<Widget> children;

  @override
  Widget build(BuildContext context) {
    return Container(
      decoration: BoxDecoration(
        color: Theme.of(context).colorScheme.surfaceContainerLowest,
        borderRadius: BorderRadius.circular(18),
      ),
      child: Column(children: children),
    );
  }
}

class _SettingsMenuTile extends StatelessWidget {
  const _SettingsMenuTile({
    required this.icon,
    required this.iconColor,
    required this.title,
    required this.onTap,
    this.trailing,
  });

  final IconData icon;
  final Color iconColor;
  final String title;
  final VoidCallback? onTap;
  final Widget? trailing;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return Material(
      color: Colors.transparent,
      child: InkWell(
        onTap: onTap,
        borderRadius: BorderRadius.circular(18),
        child: Padding(
          padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 13),
          child: Row(
            children: [
              Container(
                width: 30,
                height: 30,
                decoration: BoxDecoration(
                  color: iconColor.withValues(alpha: 0.22),
                  borderRadius: BorderRadius.circular(9),
                ),
                child: Icon(icon, color: iconColor, size: 17),
              ),
              const SizedBox(width: 12),
              Expanded(
                child: Text(
                  title,
                  style: Theme.of(context).textTheme.titleMedium?.copyWith(
                    fontWeight: FontWeight.w600,
                  ),
                ),
              ),
              if (trailing != null) ...[trailing!, const SizedBox(width: 8)],
              Icon(Icons.chevron_right_rounded, color: scheme.onSurfaceVariant),
            ],
          ),
        ),
      ),
    );
  }
}

class _SettingsSimpleBody extends StatelessWidget {
  const _SettingsSimpleBody({required this.text});

  final String text;

  @override
  Widget build(BuildContext context) {
    return ListView(
      padding: const EdgeInsets.fromLTRB(16, 16, 16, 24),
      children: [Text(text, style: Theme.of(context).textTheme.bodyLarge)],
    );
  }
}

class _AccountItemRow extends StatelessWidget {
  const _AccountItemRow({required this.title, required this.value, this.onTap});

  final String title;
  final String value;
  final VoidCallback? onTap;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return ListTile(
      onTap: onTap,
      title: Text(title, style: theme.textTheme.titleMedium),
      trailing: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          if (value.isNotEmpty)
            Text(
              value,
              style: theme.textTheme.bodyMedium?.copyWith(
                color: theme.colorScheme.onSurfaceVariant,
              ),
            ),
          const SizedBox(width: 6),
          Icon(
            Icons.chevron_right_rounded,
            color: theme.colorScheme.onSurfaceVariant,
          ),
        ],
      ),
    );
  }
}

class _AccountSwitchRow extends StatelessWidget {
  const _AccountSwitchRow({
    required this.title,
    required this.value,
    required this.onChanged,
  });

  final String title;
  final bool value;
  final ValueChanged<bool> onChanged;

  @override
  Widget build(BuildContext context) {
    return ListTile(
      title: Text(title, style: Theme.of(context).textTheme.titleMedium),
      trailing: Switch(value: value, onChanged: onChanged),
    );
  }
}
