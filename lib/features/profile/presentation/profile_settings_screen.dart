import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';
import 'package:url_launcher/url_launcher.dart';

import '../../../app/localization/app_language_controller.dart';
import '../../../app/localization/talkflix_localizations.dart';
import '../../../app/theme/theme_mode_controller.dart';
import '../../../core/auth/session_controller.dart';
import '../../../core/config/app_config.dart';
import '../../../core/config/privacy_settings_controller.dart';
import '../../../core/config/storage_keys.dart';
import '../../../core/config/talkflix_icons.dart';
import '../../../core/navigation/public_home_navigation.dart';
import '../../notifications/application/notification_preferences_controller.dart';
import '../data/profile_repository.dart';
import '../../auth/data/signup_options.dart';

class ProfileSettingsScreen extends ConsumerStatefulWidget {
  const ProfileSettingsScreen({super.key, this.section = 'hub'});

  final String section;

  @override
  ConsumerState<ProfileSettingsScreen> createState() =>
      _ProfileSettingsScreenState();
}

class _ProfileSettingsScreenState extends ConsumerState<ProfileSettingsScreen> {
  bool _chatPlayVoiceNotesAuto = false;
  String _chatTranslateTargetLanguage = 'English';
  bool _chatSettingsLoading = true;
  bool? _relationshipStatusVisible;
  String? _relationshipStatus;
  bool? _showCountry;
  bool? _showFlag;
  bool? _showFollowStats;
  bool _ageVisibilitySaving = false;
  bool _privacySaving = false;
  bool _countryVisibilitySaving = false;
  bool _flagVisibilitySaving = false;
  bool _followStatsVisibilitySaving = false;
  bool _onlineStatusSaving = false;
  bool _receiveVoiceCallsSaving = false;
  bool _receiveVideoCallsSaving = false;
  final Set<String> _unblockingUserIds = <String>{};

  @override
  void initState() {
    super.initState();
    Future<void>.microtask(_loadChatSettings);
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

  Future<void> _openSupportEmail() async {
    final opened = await launchUrl(AppConfig.supportEmailUri);
    if (opened || !mounted) return;
    _showSnack('Could not open your email app right now.');
  }

  Future<void> _loadChatSettings() async {
    final prefs = await ref.read(sharedPreferencesProvider.future);
    final userFirstLanguage =
        ref.read(sessionControllerProvider).user?.firstLanguage ?? 'English';
    if (!mounted) return;
    setState(() {
      _chatPlayVoiceNotesAuto =
          prefs.getBool(StorageKeys.chatPlayVoiceNotesAuto) ?? false;
      _chatTranslateTargetLanguage =
          prefs.getString(StorageKeys.chatTranslateTargetLanguage) ??
          (userFirstLanguage.isEmpty ? 'English' : userFirstLanguage);
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

  static const List<String> _relationshipStatusOptions = <String>[
    'Married',
    'Single',
    'Divorced',
    'Searching',
    'Widowed',
  ];

  void _ensurePrivacyStateSeeded() {
    if (_relationshipStatusVisible != null &&
        _relationshipStatus != null &&
        _showCountry != null &&
        _showFlag != null &&
        _showFollowStats != null) {
      return;
    }
    final user = ref.read(sessionControllerProvider).user;
    _relationshipStatusVisible = user?.relationshipStatusVisible ?? false;
    _relationshipStatus = user?.relationshipStatus ?? '';
    _showCountry = user?.showCountry ?? false;
    _showFlag = user?.showFlag ?? false;
    _showFollowStats = user?.showFollowStats ?? true;
  }

  Future<void> _saveShowFollowStats(bool value) async {
    if (_followStatsVisibilitySaving) return;
    setState(() {
      _followStatsVisibilitySaving = true;
      _showFollowStats = value;
    });
    try {
      final payload = await ref
          .read(profileRepositoryProvider)
          .updatePrivacy(showFollowStats: value);
      await ref.read(sessionControllerProvider.notifier).refreshProfile();
      if (!mounted) return;
      setState(() {
        _showFollowStats = payload.showFollowStats;
      });
    } catch (error) {
      if (mounted) setState(() => _showFollowStats = !value);
      _showSnack(error.toString().replaceFirst('Exception: ', ''));
    } finally {
      if (mounted) {
        setState(() => _followStatsVisibilitySaving = false);
      }
    }
  }

  Future<void> _saveShowCountry(bool value) async {
    if (_countryVisibilitySaving) return;
    setState(() {
      _countryVisibilitySaving = true;
      _showCountry = value;
    });
    try {
      final payload = await ref
          .read(profileRepositoryProvider)
          .updatePrivacy(showCountry: value);
      await ref.read(sessionControllerProvider.notifier).refreshProfile();
      if (!mounted) return;
      setState(() {
        _showCountry = payload.showCountry;
      });
    } catch (error) {
      if (mounted) setState(() => _showCountry = !value);
      _showSnack(error.toString().replaceFirst('Exception: ', ''));
    } finally {
      if (mounted) {
        setState(() => _countryVisibilitySaving = false);
      }
    }
  }

  Future<void> _saveShowFlag(bool value) async {
    if (_flagVisibilitySaving) return;
    setState(() {
      _flagVisibilitySaving = true;
      _showFlag = value;
    });
    try {
      final payload = await ref
          .read(profileRepositoryProvider)
          .updatePrivacy(showFlag: value);
      await ref
          .read(privacySettingsControllerProvider.notifier)
          .setShowFlag(payload.showFlag);
      await ref.read(sessionControllerProvider.notifier).refreshProfile();
      if (!mounted) return;
      setState(() {
        _showFlag = payload.showFlag;
      });
    } catch (error) {
      if (mounted) setState(() => _showFlag = !value);
      _showSnack(error.toString().replaceFirst('Exception: ', ''));
    } finally {
      if (mounted) {
        setState(() => _flagVisibilitySaving = false);
      }
    }
  }

  Future<void> _saveShowAge(bool value) async {
    if (_ageVisibilitySaving) return;
    final privacyNotifier = ref.read(
      privacySettingsControllerProvider.notifier,
    );
    setState(() => _ageVisibilitySaving = true);
    await privacyNotifier.setShowAge(value);
    try {
      final payload = await ref
          .read(profileRepositoryProvider)
          .updatePrivacy(showAge: value);
      await privacyNotifier.setShowAge(payload.showAge);
      await ref.read(sessionControllerProvider.notifier).refreshProfile();
    } catch (error) {
      await privacyNotifier.setShowAge(!value);
      _showSnack(error.toString().replaceFirst('Exception: ', ''));
    } finally {
      if (mounted) {
        setState(() => _ageVisibilitySaving = false);
      }
    }
  }

  Future<void> _saveShowOnlineStatus(bool value) async {
    if (_onlineStatusSaving) return;
    final privacyNotifier = ref.read(
      privacySettingsControllerProvider.notifier,
    );
    setState(() => _onlineStatusSaving = true);
    await privacyNotifier.setShowOnlineStatus(value);
    try {
      final payload = await ref
          .read(profileRepositoryProvider)
          .updatePrivacy(showOnlineStatus: value);
      await privacyNotifier.setShowOnlineStatus(payload.showOnlineStatus);
      await ref.read(sessionControllerProvider.notifier).refreshProfile();
    } catch (error) {
      await privacyNotifier.setShowOnlineStatus(!value);
      _showSnack(error.toString().replaceFirst('Exception: ', ''));
    } finally {
      if (mounted) setState(() => _onlineStatusSaving = false);
    }
  }

  Future<void> _saveReceiveVoiceCalls(bool value) async {
    if (_receiveVoiceCallsSaving) return;
    final privacyNotifier = ref.read(
      privacySettingsControllerProvider.notifier,
    );
    setState(() => _receiveVoiceCallsSaving = true);
    await privacyNotifier.setReceiveVoiceCalls(value);
    try {
      final payload = await ref
          .read(profileRepositoryProvider)
          .updatePrivacy(receiveVoiceCalls: value);
      await privacyNotifier.setReceiveVoiceCalls(payload.receiveVoiceCalls);
      await ref.read(sessionControllerProvider.notifier).refreshProfile();
    } catch (error) {
      await privacyNotifier.setReceiveVoiceCalls(!value);
      _showSnack(error.toString().replaceFirst('Exception: ', ''));
    } finally {
      if (mounted) setState(() => _receiveVoiceCallsSaving = false);
    }
  }

  Future<void> _saveReceiveVideoCalls(bool value) async {
    if (_receiveVideoCallsSaving) return;
    final privacyNotifier = ref.read(
      privacySettingsControllerProvider.notifier,
    );
    setState(() => _receiveVideoCallsSaving = true);
    await privacyNotifier.setReceiveVideoCalls(value);
    try {
      final payload = await ref
          .read(profileRepositoryProvider)
          .updatePrivacy(receiveVideoCalls: value);
      await privacyNotifier.setReceiveVideoCalls(payload.receiveVideoCalls);
      await ref.read(sessionControllerProvider.notifier).refreshProfile();
    } catch (error) {
      await privacyNotifier.setReceiveVideoCalls(!value);
      _showSnack(error.toString().replaceFirst('Exception: ', ''));
    } finally {
      if (mounted) setState(() => _receiveVideoCallsSaving = false);
    }
  }

  Future<String?> _showRelationshipStatusPicker({
    required String selectedValue,
  }) async {
    final l10n = context.l10n;
    final scheme = Theme.of(context).colorScheme;
    return showModalBottomSheet<String>(
      context: context,
      backgroundColor: scheme.surface,
      shape: const RoundedRectangleBorder(
        borderRadius: BorderRadius.vertical(top: Radius.circular(28)),
      ),
      builder: (sheetContext) {
        return SafeArea(
          top: false,
          child: Padding(
            padding: const EdgeInsets.fromLTRB(12, 12, 12, 18),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                Container(
                  width: 42,
                  height: 4,
                  margin: const EdgeInsets.only(bottom: 12),
                  decoration: BoxDecoration(
                    color: scheme.outlineVariant,
                    borderRadius: BorderRadius.circular(999),
                  ),
                ),
                Padding(
                  padding: const EdgeInsets.only(bottom: 6),
                  child: Text(
                    l10n.selectRelationshipStatus,
                    style: Theme.of(context).textTheme.titleMedium?.copyWith(
                      fontWeight: FontWeight.w700,
                    ),
                  ),
                ),
                ..._relationshipStatusOptions.map(
                  (option) => ListTile(
                    leading: Icon(
                      option == selectedValue
                          ? Icons.radio_button_checked_rounded
                          : Icons.radio_button_off_rounded,
                    ),
                    title: Text(l10n.relationshipStatusLabel(option)),
                    onTap: () => Navigator.of(sheetContext).pop(option),
                  ),
                ),
              ],
            ),
          ),
        );
      },
    );
  }

  Future<void> _saveRelationshipStatus({
    required bool visible,
    String? status,
  }) async {
    if (_privacySaving) return;
    setState(() => _privacySaving = true);
    try {
      final payload = await ref
          .read(profileRepositoryProvider)
          .updateRelationshipStatus(visible: visible, status: status);
      if (!mounted) return;
      ref
          .read(sessionControllerProvider.notifier)
          .updateRelationshipStatus(
            relationshipStatus: payload.relationshipStatus,
            relationshipStatusVisible: payload.relationshipStatusVisible,
          );
      setState(() {
        _relationshipStatusVisible = payload.relationshipStatusVisible;
        _relationshipStatus = payload.relationshipStatus;
      });
      _showSnack(
        visible
            ? context.l10n.relationshipStatusUpdated
            : context.l10n.relationshipStatusHiddenNotice,
      );
    } catch (error) {
      _showSnack(error.toString().replaceFirst('Exception: ', ''));
    } finally {
      if (mounted) {
        setState(() => _privacySaving = false);
      }
    }
  }

  Future<void> _handleRelationshipStatusToggle(bool value) async {
    _ensurePrivacyStateSeeded();
    final currentStatus = _relationshipStatus ?? '';
    if (!value) {
      await _saveRelationshipStatus(visible: false);
      return;
    }
    final picked = await _showRelationshipStatusPicker(
      selectedValue: currentStatus.isEmpty
          ? _relationshipStatusOptions.first
          : currentStatus,
    );
    if (!mounted || picked == null || picked.isEmpty) return;
    await _saveRelationshipStatus(visible: true, status: picked);
  }

  Future<void> _handleUnblockUser(BlockedUserEntry user) async {
    if (_unblockingUserIds.contains(user.id)) return;
    setState(() => _unblockingUserIds.add(user.id));
    try {
      await ref.read(profileRepositoryProvider).unblockUser(user.id);
      ref.invalidate(blockedUsersProvider);
      if (!mounted) return;
      _showSnack(context.l10n.userUnblocked);
    } catch (error) {
      if (!mounted) return;
      _showSnack(error.toString().replaceFirst('Exception: ', ''));
    } finally {
      if (mounted) {
        setState(() => _unblockingUserIds.remove(user.id));
      }
    }
  }

  Widget _buildPrivacyContent() {
    _ensurePrivacyStateSeeded();
    final l10n = context.l10n;
    final privacySettings = ref.watch(privacySettingsControllerProvider);
    final blockedUsers = ref.watch(blockedUsersProvider);
    final selectedStatus = _relationshipStatus ?? '';
    final visible = _relationshipStatusVisible ?? false;
    final showFlag = _showFlag ?? privacySettings.showFlag;
    final showCountry = _showCountry ?? false;
    final showFollowStats = _showFollowStats ?? true;
    return SingleChildScrollView(
      padding: const EdgeInsets.fromLTRB(16, 12, 16, 24),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          _SettingsSwitchTile(
            title: l10n.showAge,
            subtitle: l10n.showAgeSubtitle,
            value: privacySettings.showAge,
            isLoading: _ageVisibilitySaving,
            onChanged: _saveShowAge,
          ),
          _SettingsSwitchTile(
            title: l10n.showFlag,
            subtitle: l10n.showFlagSubtitle,
            value: showFlag,
            isLoading: _flagVisibilitySaving,
            onChanged: _saveShowFlag,
          ),
          _SettingsSwitchTile(
            title: l10n.showCountry,
            subtitle: l10n.showCountrySubtitle,
            value: showCountry,
            isLoading: _countryVisibilitySaving,
            onChanged: _saveShowCountry,
          ),
          _SettingsSwitchTile(
            title: l10n.showFollowingFollowers,
            subtitle: l10n.showFollowingFollowersSubtitle,
            value: showFollowStats,
            isLoading: _followStatsVisibilitySaving,
            onChanged: _saveShowFollowStats,
          ),
          _SettingsSwitchTile(
            title: l10n.showOnlineStatus,
            subtitle: l10n.showOnlineStatusSubtitle,
            value: privacySettings.showOnlineStatus,
            isLoading: _onlineStatusSaving,
            onChanged: _saveShowOnlineStatus,
          ),
          if (AppConfig.directCallsEnabled) ...[
            _SettingsSwitchTile(
              title: l10n.receiveVoiceCalls,
              subtitle: l10n.receiveVoiceCallsSubtitle,
              value: privacySettings.receiveVoiceCalls,
              isLoading: _receiveVoiceCallsSaving,
              onChanged: _saveReceiveVoiceCalls,
            ),
            _SettingsSwitchTile(
              title: l10n.receiveVideoCalls,
              subtitle: l10n.receiveVideoCallsSubtitle,
              value: privacySettings.receiveVideoCalls,
              isLoading: _receiveVideoCallsSaving,
              onChanged: _saveReceiveVideoCalls,
            ),
          ],
          const SizedBox(height: 8),
          _SettingsSwitchTile(
            title: l10n.relationshipStatus,
            subtitle: visible && selectedStatus.isNotEmpty
                ? l10n.relationshipStatusLabel(selectedStatus)
                : l10n.relationshipStatusHidden,
            value: visible,
            isLoading: _privacySaving,
            onChanged: _handleRelationshipStatusToggle,
          ),
          if (visible) ...[
            const SizedBox(height: 8),
            _SettingsMenuCard(
              children: [
                _AccountItemRow(
                  title: l10n.relationshipStatus,
                  value: selectedStatus.isEmpty
                      ? ''
                      : l10n.relationshipStatusLabel(selectedStatus),
                  onTap: _privacySaving
                      ? null
                      : () async {
                          final picked = await _showRelationshipStatusPicker(
                            selectedValue: selectedStatus.isEmpty
                                ? _relationshipStatusOptions.first
                                : selectedStatus,
                          );
                          if (!mounted || picked == null || picked.isEmpty) {
                            return;
                          }
                          await _saveRelationshipStatus(
                            visible: true,
                            status: picked,
                          );
                        },
                ),
              ],
            ),
          ],
          const SizedBox(height: 18),
          Text(
            l10n.blacklist,
            style: Theme.of(
              context,
            ).textTheme.titleMedium?.copyWith(fontWeight: FontWeight.w800),
          ),
          const SizedBox(height: 8),
          blockedUsers.when(
            loading: () => const Padding(
              padding: EdgeInsets.symmetric(vertical: 18),
              child: Center(child: CircularProgressIndicator()),
            ),
            error: (error, _) => _SettingsMenuCard(
              children: [
                ListTile(
                  title: Text(l10n.blockedUsersLoadFailed),
                  subtitle: Text(error.toString()),
                  trailing: IconButton(
                    onPressed: () => ref.invalidate(blockedUsersProvider),
                    icon: const Icon(Icons.refresh_rounded),
                  ),
                ),
              ],
            ),
            data: (items) {
              if (items.isEmpty) {
                return _SettingsMenuCard(
                  children: [
                    ListTile(
                      title: Text(l10n.blockedUsers),
                      subtitle: Text(l10n.noBlockedUsers),
                    ),
                  ],
                );
              }
              return _SettingsMenuCard(
                children: [
                  for (final user in items)
                    ListTile(
                      leading: CircleAvatar(
                        radius: 22,
                        backgroundImage: user.profilePhotoUrl.trim().isEmpty
                            ? null
                            : NetworkImage(user.profilePhotoUrl),
                        child: user.profilePhotoUrl.trim().isEmpty
                            ? Text(
                                user.displayName.isEmpty
                                    ? '?'
                                    : user.displayName.characters.first
                                          .toUpperCase(),
                              )
                            : null,
                      ),
                      title: Text(
                        user.displayName,
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                      ),
                      subtitle: Text(
                        user.username.trim().isEmpty
                            ? l10n.blockedUsers
                            : '@${user.username}',
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                      ),
                      trailing: TextButton(
                        onPressed: _unblockingUserIds.contains(user.id)
                            ? null
                            : () => _handleUnblockUser(user),
                        child: Text(l10n.unblock),
                      ),
                    ),
                ],
              );
            },
          ),
        ],
      ),
    );
  }

  Widget _buildAccountContent(ThemeData theme, ColorScheme scheme) {
    final l10n = context.l10n;
    final user = ref.watch(sessionControllerProvider).user;
    final talkflixId = user?.username.trim().isNotEmpty == true
        ? '@${user!.username}'
        : l10n.notSet;
    final email = user?.email.trim().isNotEmpty == true
        ? user!.email
        : l10n.notSet;
    return ListView(
      padding: const EdgeInsets.fromLTRB(16, 12, 16, 24),
      children: [
        _SettingsMenuCard(
          children: [
            _AccountItemRow(
              title: l10n.talkflixId,
              value: talkflixId,
              onTap: () => context.push('/app/profile/edit'),
            ),
            _AccountItemRow(
              title: l10n.email,
              value: email,
              onTap: () => _showEmailActions(email),
            ),
            _AccountItemRow(
              title: l10n.password,
              value: '',
              onTap: _showChangePasswordSheet,
            ),
          ],
        ),
        const SizedBox(height: 10),
        Text(
          'Security changes require your current password.',
          style: theme.textTheme.bodySmall?.copyWith(
            color: scheme.onSurfaceVariant,
          ),
        ),
      ],
    );
  }

  Widget _buildSettingsAccountActions(ThemeData theme, ColorScheme scheme) {
    final l10n = context.l10n;
    return Column(
      children: [
        FilledButton(
          style: FilledButton.styleFrom(
            minimumSize: const Size.fromHeight(52),
            shape: RoundedRectangleBorder(
              borderRadius: BorderRadius.circular(999),
            ),
            backgroundColor: scheme.surfaceContainerHigh,
            foregroundColor: scheme.onSurface,
          ),
          onPressed: _handleLogOut,
          child: Text(l10n.logOut),
        ),
        const SizedBox(height: 18),
        Center(
          child: TextButton(
            onPressed: _confirmDeleteAccount,
            child: Text(
              l10n.deleteAccount,
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
    final l10n = context.l10n;
    return SingleChildScrollView(
      padding: const EdgeInsets.fromLTRB(16, 12, 16, 24),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          _SettingsSwitchTile(
            title: l10n.autoPlayReceivedVoiceNotes,
            subtitle: l10n.handsFreeListening,
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

  Widget _buildNotificationSettingsContent() {
    final state = ref.watch(notificationPreferencesControllerProvider);
    final notifier = ref.read(
      notificationPreferencesControllerProvider.notifier,
    );
    final preferences = state.preferences;
    return ListView(
      padding: const EdgeInsets.fromLTRB(16, 12, 16, 24),
      children: [
        _SettingsSwitchTile(
          title: 'New messages',
          subtitle:
              'Show direct messages in notifications and the notification center.',
          value: preferences.messagesEnabled,
          isLoading: state.isLoading || state.isSaving,
          onChanged: (value) => notifier.setMessagesEnabled(value),
        ),
        _SettingsSwitchTile(
          title: 'Message sound',
          subtitle: 'Play a sound for new message notifications.',
          value: preferences.messageSoundEnabled,
          enabled: preferences.messagesEnabled,
          isLoading: state.isLoading || state.isSaving,
          onChanged: (value) => notifier.setMessageSoundEnabled(value),
        ),
        _SettingsSwitchTile(
          title: 'New followers',
          subtitle:
              'Show a notification when someone starts following your profile.',
          value: preferences.followersEnabled,
          isLoading: state.isLoading || state.isSaving,
          onChanged: (value) => notifier.setFollowersEnabled(value),
        ),
        _SettingsSwitchTile(
          title: 'Follower sound',
          subtitle: 'Play a sound for new follower notifications.',
          value: preferences.followerSoundEnabled,
          enabled: preferences.followersEnabled,
          isLoading: state.isLoading || state.isSaving,
          onChanged: (value) => notifier.setFollowerSoundEnabled(value),
        ),
        if (state.errorMessage != null) ...[
          const SizedBox(height: 8),
          Text(
            state.errorMessage!,
            style: Theme.of(context).textTheme.bodySmall?.copyWith(
              color: Theme.of(context).colorScheme.onSurfaceVariant,
            ),
          ),
        ],
        const SizedBox(height: 16),
        Text(
          'Muted chats stay muted even when message notifications are enabled.',
          style: Theme.of(context).textTheme.bodySmall?.copyWith(
            color: Theme.of(context).colorScheme.onSurfaceVariant,
          ),
        ),
      ],
    );
  }

  Widget _buildLanguageContent(String selectedAppLanguage) {
    final l10n = context.l10n;
    final theme = Theme.of(context);
    final userFirstLanguage =
        ref.watch(sessionControllerProvider).user?.firstLanguage ?? 'English';
    return SingleChildScrollView(
      padding: const EdgeInsets.fromLTRB(16, 12, 16, 24),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(
            l10n.languageFollowsDeviceHint,
            style: theme.textTheme.bodyMedium?.copyWith(
              color: theme.colorScheme.onSurfaceVariant,
            ),
          ),
          const SizedBox(height: 12),
          _SettingsMenuCard(
            children: [
              _AccountItemRow(
                title: l10n.appLanguage,
                value: selectedAppLanguage == systemAppLanguageLabel
                    ? l10n.systemDefault
                    : selectedAppLanguage,
                onTap: () => _showLanguagePicker(
                  title: l10n.appLanguage,
                  options: [systemAppLanguageLabel, ...appLanguageLabels],
                  selectedValue: selectedAppLanguage,
                  displayValueForOption: (option) =>
                      option == systemAppLanguageLabel
                      ? l10n.systemDefault
                      : option,
                  onSelected: (picked) async {
                    await ref
                        .read(appLanguageControllerProvider.notifier)
                        .setLanguage(picked);
                    if (!mounted) return;
                    _showSnack(
                      picked == systemAppLanguageLabel
                          ? l10n.appLanguageSetSystemDefault
                          : l10n.appLanguageSetTo(picked),
                    );
                  },
                ),
              ),
              _AccountItemRow(
                title: l10n.translateReceivedMessagesTo,
                value: _chatTranslateTargetLanguage,
                onTap: () => _showLanguagePicker(
                  title: l10n.translateReceivedMessagesTo,
                  options: languageOptions,
                  selectedValue: _chatTranslateTargetLanguage,
                  onSelected: (picked) async {
                    setState(() => _chatTranslateTargetLanguage = picked);
                    await _setChatPrefString(
                      StorageKeys.chatTranslateTargetLanguage,
                      picked,
                    );
                    if (!mounted) return;
                    _showSnack(l10n.receivedMessagesTranslateTo(picked));
                  },
                ),
              ),
            ],
          ),
          if (userFirstLanguage.isNotEmpty) ...[
            const SizedBox(height: 10),
            Text(
              l10n.defaultTranslationTarget(userFirstLanguage),
              style: theme.textTheme.bodySmall?.copyWith(
                color: theme.colorScheme.onSurfaceVariant,
              ),
            ),
          ],
        ],
      ),
    );
  }

  Future<void> _showLanguagePicker({
    required String title,
    required List<String> options,
    required String selectedValue,
    required Future<void> Function(String picked) onSelected,
    String Function(String option)? displayValueForOption,
  }) async {
    await showModalBottomSheet<void>(
      context: context,
      showDragHandle: true,
      builder: (context) => SafeArea(
        child: ListView.builder(
          shrinkWrap: true,
          itemCount: options.length + 1,
          itemBuilder: (context, index) {
            if (index == 0) {
              return ListTile(
                title: Text(
                  title,
                  style: Theme.of(context).textTheme.titleMedium?.copyWith(
                    fontWeight: FontWeight.w800,
                  ),
                ),
              );
            }
            final option = options[index - 1];
            final selected = option == selectedValue;
            final display = displayValueForOption?.call(option) ?? option;
            return ListTile(
              title: Text(display),
              trailing: selected
                  ? Icon(
                      Icons.check_rounded,
                      color: Theme.of(context).colorScheme.primary,
                    )
                  : null,
              onTap: () async {
                Navigator.of(context).pop();
                if (option == selectedValue) return;
                await onSelected(option);
              },
            );
          },
        ),
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
              title: const Text('Change password'),
              onTap: () {
                Navigator.of(context).pop();
                _showChangePasswordSheet();
              },
            ),
            ListTile(
              leading: const Icon(Icons.alternate_email_rounded),
              title: const Text('Change email'),
              onTap: () {
                Navigator.of(context).pop();
                _showChangeEmailSheet(email);
              },
            ),
          ],
        ),
      ),
    );
  }

  Future<void> _showChangePasswordSheet() async {
    final currentController = TextEditingController();
    final nextController = TextEditingController();
    final confirmController = TextEditingController();
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
                'Change password',
                style: Theme.of(
                  context,
                ).textTheme.titleMedium?.copyWith(fontWeight: FontWeight.w800),
              ),
              const SizedBox(height: 10),
              TextField(
                controller: currentController,
                obscureText: true,
                decoration: const InputDecoration(
                  labelText: 'Current password',
                ),
              ),
              const SizedBox(height: 10),
              TextField(
                controller: nextController,
                obscureText: true,
                decoration: const InputDecoration(
                  labelText: 'New password',
                  helperText: 'At least 8 characters.',
                ),
              ),
              const SizedBox(height: 10),
              TextField(
                controller: confirmController,
                obscureText: true,
                decoration: const InputDecoration(
                  labelText: 'Confirm password',
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
                        final current = currentController.text;
                        final next = nextController.text;
                        final confirm = confirmController.text;
                        if (current.isEmpty ||
                            next.isEmpty ||
                            confirm.isEmpty) {
                          _showSnack('Fill in all password fields.');
                          return;
                        }
                        if (next.length < 8) {
                          _showSnack('Password must be at least 8 characters.');
                          return;
                        }
                        if (next != confirm) {
                          _showSnack('New passwords do not match.');
                          return;
                        }
                        try {
                          await ref
                              .read(profileRepositoryProvider)
                              .changePassword(
                                currentPassword: current,
                                newPassword: next,
                              );
                          if (!context.mounted) return;
                          Navigator.of(context).pop();
                          _showSnack('Password changed.');
                        } catch (error) {
                          _showSnack(
                            error.toString().replaceFirst('Exception: ', ''),
                          );
                        }
                      },
                      child: const Text('Update'),
                    ),
                  ),
                ],
              ),
            ],
          ),
        ),
      ),
    );
    currentController.dispose();
    nextController.dispose();
    confirmController.dispose();
  }

  Future<void> _showChangeEmailSheet(String currentEmail) async {
    final emailController = TextEditingController(text: currentEmail);
    final passwordController = TextEditingController();
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
                'Change email',
                style: Theme.of(
                  context,
                ).textTheme.titleMedium?.copyWith(fontWeight: FontWeight.w800),
              ),
              const SizedBox(height: 10),
              TextField(
                controller: emailController,
                keyboardType: TextInputType.emailAddress,
                decoration: const InputDecoration(labelText: 'New email'),
              ),
              const SizedBox(height: 10),
              TextField(
                controller: passwordController,
                obscureText: true,
                decoration: const InputDecoration(
                  labelText: 'Current password',
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
                        final email = emailController.text.trim();
                        final password = passwordController.text;
                        if (email.isEmpty || password.isEmpty) {
                          _showSnack('Email and password are required.');
                          return;
                        }
                        try {
                          await ref
                              .read(profileRepositoryProvider)
                              .changeEmail(newEmail: email, password: password);
                          await ref
                              .read(sessionControllerProvider.notifier)
                              .refreshProfile();
                          if (!context.mounted) return;
                          Navigator.of(context).pop();
                          _showSnack('Email changed.');
                        } catch (error) {
                          _showSnack(
                            error.toString().replaceFirst('Exception: ', ''),
                          );
                        }
                      },
                      child: const Text('Update'),
                    ),
                  ),
                ],
              ),
            ],
          ),
        ),
      ),
    );
    emailController.dispose();
    passwordController.dispose();
  }

  Future<void> _confirmDeleteAccount() async {
    final confirmController = TextEditingController();
    final passwordController = TextEditingController();
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
            const SizedBox(height: 10),
            TextField(
              controller: passwordController,
              obscureText: true,
              decoration: const InputDecoration(labelText: 'Current password'),
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
                  confirmController.text.trim().toUpperCase() == 'DELETE' &&
                  passwordController.text.isNotEmpty;
              Navigator.of(context).pop(ok);
            },
            child: const Text('Delete'),
          ),
        ],
      ),
    );
    confirmController.dispose();
    final password = passwordController.text;
    passwordController.dispose();
    if (confirmed != true) {
      _showSnack('Delete account cancelled.');
      return;
    }
    try {
      await ref
          .read(profileRepositoryProvider)
          .deleteAccount(password: password);
      await ref.read(sessionControllerProvider.notifier).signOut();
      if (!mounted) return;
      await _goToLoggedOutDestination();
      _showSnack('Account deleted.');
    } catch (error) {
      _showSnack(error.toString().replaceFirst('Exception: ', ''));
    }
  }

  Future<void> _handleLogOut() async {
    await ref.read(sessionControllerProvider.notifier).signOut();
    if (!mounted) return;
    await _goToLoggedOutDestination();
  }

  Future<void> _goToLoggedOutDestination() async {
    await openPublicHome(context);
  }

  Widget _buildAppearanceContent(ThemeMode themeMode) {
    final l10n = context.l10n;
    return ListView(
      padding: const EdgeInsets.fromLTRB(16, 12, 16, 24),
      children: [
        SegmentedButton<ThemeMode>(
          segments: [
            ButtonSegment<ThemeMode>(
              value: ThemeMode.system,
              label: Text(l10n.systemTheme),
              icon: const Icon(Icons.brightness_auto_outlined),
            ),
            ButtonSegment<ThemeMode>(
              value: ThemeMode.light,
              label: Text(l10n.lightTheme),
              icon: const Icon(Icons.light_mode_outlined),
            ),
            ButtonSegment<ThemeMode>(
              value: ThemeMode.dark,
              label: Text(l10n.darkThemeOption),
              icon: const Icon(Icons.dark_mode_outlined),
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
    final l10n = context.l10n;
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;
    final themeMode = ref.watch(themeModeControllerProvider);
    final selectedAppLanguage = ref.watch(appLanguageControllerProvider);
    final section = widget.section;

    if (section != 'hub') {
      final title = switch (section) {
        'account' => l10n.account,
        'notifications' => l10n.notifications,
        'privacy' => l10n.privacy,
        'chat' => l10n.chatSettings,
        'language' => l10n.language,
        'appearance' => l10n.darkTheme,
        'about' => l10n.about,
        'help' => l10n.help,
        _ => l10n.settings,
      };
      return Scaffold(
        backgroundColor: scheme.surface,
        appBar: AppBar(title: Text(title)),
        body: switch (section) {
          'account' => _buildAccountContent(theme, scheme),
          'notifications' => _buildNotificationSettingsContent(),
          'privacy' => _buildPrivacyContent(),
          'chat' =>
            _chatSettingsLoading
                ? const Center(child: CircularProgressIndicator())
                : _buildChatSettingsContent(),
          'language' =>
            _chatSettingsLoading
                ? const Center(child: CircularProgressIndicator())
                : _buildLanguageContent(selectedAppLanguage),
          'appearance' => _buildAppearanceContent(themeMode),
          'about' => _SettingsSimpleBody(text: l10n.aboutBody),
          'help' => _buildHelpContent(theme),
          _ => const SizedBox.shrink(),
        },
      );
    }

    return Scaffold(
      backgroundColor: scheme.surface,
      appBar: AppBar(title: Text(l10n.settings)),
      body: ListView(
        padding: const EdgeInsets.fromLTRB(16, 12, 16, 28),
        children: [
          _SettingsMenuCard(
            children: [
              _SettingsMenuTile(
                icon: Icons.person_outline_rounded,
                iconColor: const Color(0xFFE50914),
                title: l10n.account,
                onTap: () => context.push('/app/profile/settings/account'),
              ),
              _SettingsMenuTile(
                icon: Icons.notifications_none_rounded,
                iconColor: const Color(0xFFE53945),
                title: 'Notification preferences',
                onTap: () =>
                    context.push('/app/profile/settings/notifications'),
              ),
              _SettingsMenuTile(
                icon: Icons.shield_outlined,
                iconColor: const Color(0xFFB71C1C),
                title: l10n.privacy,
                onTap: () => context.push('/app/profile/settings/privacy'),
              ),
              _SettingsMenuTile(
                icon: TalkflixIcons.talks,
                iconColor: const Color(0xFFC62828),
                title: l10n.chatSettings,
                onTap: _chatSettingsLoading
                    ? null
                    : () => context.push('/app/profile/settings/chat'),
              ),
            ],
          ),
          const SizedBox(height: 14),
          _SettingsMenuCard(
            children: [
              _SettingsMenuTile(
                icon: Icons.language_rounded,
                iconColor: const Color(0xFFE50914),
                title: l10n.language,
                onTap: _chatSettingsLoading
                    ? null
                    : () => context.push('/app/profile/settings/language'),
              ),
              _SettingsMenuTile(
                icon: Icons.dark_mode_outlined,
                iconColor: const Color(0xFFAD1457),
                title: l10n.darkTheme,
                onTap: () => context.push('/app/profile/settings/appearance'),
              ),
            ],
          ),
          const SizedBox(height: 14),
          _SettingsMenuCard(
            children: [
              _SettingsMenuTile(
                icon: Icons.info_outline_rounded,
                iconColor: const Color(0xFFD84315),
                title: l10n.about,
                onTap: () => context.push('/app/profile/settings/about'),
              ),
            ],
          ),
          const SizedBox(height: 14),
          _SettingsMenuCard(
            children: [
              _SettingsMenuTile(
                icon: Icons.description_outlined,
                iconColor: const Color(0xFF455A64),
                title: 'Terms of Service',
                onTap: () => context.push('/terms-of-service'),
              ),
              _SettingsMenuTile(
                icon: Icons.privacy_tip_outlined,
                iconColor: const Color(0xFF37474F),
                title: 'Privacy Policy',
                onTap: () => context.push('/privacy-policy'),
              ),
              _SettingsMenuTile(
                icon: Icons.delete_outline_rounded,
                iconColor: const Color(0xFF5D4037),
                title: 'Account Deletion',
                onTap: () => context.push('/account-deletion'),
              ),
            ],
          ),
          const SizedBox(height: 14),
          _SettingsMenuCard(
            children: [
              _SettingsMenuTile(
                icon: Icons.help_outline_rounded,
                iconColor: const Color(0xFFEF5350),
                title: l10n.help,
                onTap: () => context.push('/app/profile/settings/help'),
              ),
              if (AppConfig.localQaToolsEnabled)
                _SettingsMenuTile(
                  icon: Icons.bug_report_outlined,
                  iconColor: const Color(0xFFC62828),
                  title: 'Diagnostics',
                  onTap: () => context.push('/app/profile/diagnostics'),
                ),
            ],
          ),
          const SizedBox(height: 24),
          _buildSettingsAccountActions(theme, scheme),
          const SizedBox(height: 18),
          Text(
            '(c) 2026 Talkflix. All rights reserved.',
            textAlign: TextAlign.center,
            style: theme.textTheme.bodySmall?.copyWith(
              color: scheme.onSurfaceVariant,
              fontWeight: FontWeight.w600,
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildHelpContent(ThemeData theme) {
    final l10n = context.l10n;
    return ListView(
      padding: const EdgeInsets.fromLTRB(16, 16, 16, 24),
      children: [
        Text(
          l10n.helpBody,
          style: theme.textTheme.bodyLarge?.copyWith(height: 1.4),
        ),
        const SizedBox(height: 16),
        _SettingsMenuCard(
          children: [
            _SettingsMenuTile(
              icon: Icons.email_outlined,
              iconColor: const Color(0xFFE53945),
              title: AppConfig.supportEmail,
              onTap: _openSupportEmail,
            ),
          ],
        ),
      ],
    );
  }
}

class _SettingsSwitchTile extends StatelessWidget {
  const _SettingsSwitchTile({
    required this.title,
    required this.subtitle,
    required this.value,
    required this.onChanged,
    this.enabled = true,
    this.isLoading = false,
  });

  final String title;
  final String subtitle;
  final bool value;
  final ValueChanged<bool>? onChanged;
  final bool enabled;
  final bool isLoading;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final effectiveOnChanged = enabled && !isLoading ? onChanged : null;
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
                      color: enabled
                          ? null
                          : theme.colorScheme.onSurfaceVariant,
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
            SizedBox(
              width: 52,
              height: 32,
              child: Center(
                child: isLoading
                    ? SizedBox(
                        width: 22,
                        height: 22,
                        child: CircularProgressIndicator(
                          strokeWidth: 2.2,
                          color: theme.colorScheme.primary,
                        ),
                      )
                    : Switch(value: value, onChanged: effectiveOnChanged),
              ),
            ),
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
  });

  final IconData icon;
  final Color iconColor;
  final String title;
  final VoidCallback? onTap;

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
