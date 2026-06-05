import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../core/auth/session_controller.dart';
import '../../../core/config/storage_keys.dart';
import '../../../core/network/api_client.dart';

final notificationPreferencesControllerProvider =
    StateNotifierProvider<
      NotificationPreferencesController,
      NotificationPreferencesState
    >((ref) {
      return NotificationPreferencesController(ref);
    });

class NotificationPreferencesController
    extends StateNotifier<NotificationPreferencesState> {
  NotificationPreferencesController(this._ref)
    : super(const NotificationPreferencesState()) {
    Future<void>.microtask(load);
  }

  final Ref _ref;

  Future<void> load() async {
    state = state.copyWith(isLoading: true, clearError: true);
    final prefs = await _ref.read(sharedPreferencesProvider.future);
    var next = NotificationPreferences(
      messagesEnabled:
          prefs.getBool(StorageKeys.notificationMessagesEnabled) ?? true,
      messageSoundEnabled:
          prefs.getBool(StorageKeys.notificationMessageSoundEnabled) ?? true,
      followersEnabled:
          prefs.getBool(StorageKeys.notificationFollowersEnabled) ?? true,
      followerSoundEnabled:
          prefs.getBool(StorageKeys.notificationFollowerSoundEnabled) ?? true,
    );

    try {
      final response = await _ref
          .read(apiClientProvider)
          .getJson('/me/notification-preferences');
      final rawPreferences = response['preferences'];
      if (rawPreferences is Map) {
        next = NotificationPreferences.fromJson(
          Map<String, dynamic>.from(rawPreferences),
          fallback: next,
        );
      }
      await _persistLocal(next);
    } catch (_) {
      // Preferences still work locally until the API endpoint is available.
    }

    if (!mounted) return;
    state = state.copyWith(isLoading: false, preferences: next);
  }

  Future<void> setMessagesEnabled(bool value) {
    return _update(
      state.preferences.copyWith(
        messagesEnabled: value,
        messageSoundEnabled: value
            ? state.preferences.messageSoundEnabled
            : false,
      ),
    );
  }

  Future<void> setMessageSoundEnabled(bool value) {
    return _update(state.preferences.copyWith(messageSoundEnabled: value));
  }

  Future<void> setFollowersEnabled(bool value) {
    return _update(
      state.preferences.copyWith(
        followersEnabled: value,
        followerSoundEnabled: value
            ? state.preferences.followerSoundEnabled
            : false,
      ),
    );
  }

  Future<void> setFollowerSoundEnabled(bool value) {
    return _update(state.preferences.copyWith(followerSoundEnabled: value));
  }

  Future<void> _update(NotificationPreferences next) async {
    final previous = state.preferences;
    state = state.copyWith(preferences: next, isSaving: true, clearError: true);
    await _persistLocal(next);
    try {
      final response = await _ref
          .read(apiClientProvider)
          .patchJson('/me/notification-preferences', body: next.toJson());
      final rawPreferences = response['preferences'];
      final saved = rawPreferences is Map
          ? NotificationPreferences.fromJson(
              Map<String, dynamic>.from(rawPreferences),
              fallback: next,
            )
          : next;
      await _persistLocal(saved);
      if (!mounted) return;
      state = state.copyWith(preferences: saved, isSaving: false);
    } catch (error) {
      if (!mounted) return;
      state = state.copyWith(
        preferences: next,
        isSaving: false,
        errorMessage:
            'Saved on this device. Server sync is unavailable right now.',
      );
      if (previous != next) {
        await _persistLocal(next);
      }
    }
  }

  Future<void> _persistLocal(NotificationPreferences preferences) async {
    final prefs = await _ref.read(sharedPreferencesProvider.future);
    await prefs.setBool(
      StorageKeys.notificationMessagesEnabled,
      preferences.messagesEnabled,
    );
    await prefs.setBool(
      StorageKeys.notificationMessageSoundEnabled,
      preferences.messageSoundEnabled,
    );
    await prefs.setBool(
      StorageKeys.notificationFollowersEnabled,
      preferences.followersEnabled,
    );
    await prefs.setBool(
      StorageKeys.notificationFollowerSoundEnabled,
      preferences.followerSoundEnabled,
    );
  }
}

class NotificationPreferencesState {
  const NotificationPreferencesState({
    this.preferences = const NotificationPreferences(),
    this.isLoading = false,
    this.isSaving = false,
    this.errorMessage,
  });

  final NotificationPreferences preferences;
  final bool isLoading;
  final bool isSaving;
  final String? errorMessage;

  NotificationPreferencesState copyWith({
    NotificationPreferences? preferences,
    bool? isLoading,
    bool? isSaving,
    String? errorMessage,
    bool clearError = false,
  }) {
    return NotificationPreferencesState(
      preferences: preferences ?? this.preferences,
      isLoading: isLoading ?? this.isLoading,
      isSaving: isSaving ?? this.isSaving,
      errorMessage: clearError ? null : errorMessage ?? this.errorMessage,
    );
  }
}

class NotificationPreferences {
  const NotificationPreferences({
    this.messagesEnabled = true,
    this.messageSoundEnabled = true,
    this.followersEnabled = true,
    this.followerSoundEnabled = true,
  });

  final bool messagesEnabled;
  final bool messageSoundEnabled;
  final bool followersEnabled;
  final bool followerSoundEnabled;

  factory NotificationPreferences.fromJson(
    Map<String, dynamic> json, {
    required NotificationPreferences fallback,
  }) {
    bool readBool(String key, bool fallbackValue) {
      final value = json[key];
      if (value is bool) return value;
      if (value is num) return value != 0;
      if (value is String) {
        final normalized = value.trim().toLowerCase();
        if (normalized == 'true' || normalized == '1') return true;
        if (normalized == 'false' || normalized == '0') return false;
      }
      return fallbackValue;
    }

    return NotificationPreferences(
      messagesEnabled: readBool('messagesEnabled', fallback.messagesEnabled),
      messageSoundEnabled: readBool(
        'messageSoundEnabled',
        fallback.messageSoundEnabled,
      ),
      followersEnabled: readBool('followersEnabled', fallback.followersEnabled),
      followerSoundEnabled: readBool(
        'followerSoundEnabled',
        fallback.followerSoundEnabled,
      ),
    );
  }

  NotificationPreferences copyWith({
    bool? messagesEnabled,
    bool? messageSoundEnabled,
    bool? followersEnabled,
    bool? followerSoundEnabled,
  }) {
    return NotificationPreferences(
      messagesEnabled: messagesEnabled ?? this.messagesEnabled,
      messageSoundEnabled:
          messageSoundEnabled ??
          (messagesEnabled == false ? false : this.messageSoundEnabled),
      followersEnabled: followersEnabled ?? this.followersEnabled,
      followerSoundEnabled:
          followerSoundEnabled ??
          (followersEnabled == false ? false : this.followerSoundEnabled),
    );
  }

  Map<String, dynamic> toJson() {
    return <String, dynamic>{
      'messagesEnabled': messagesEnabled,
      'messageSoundEnabled': messageSoundEnabled,
      'followersEnabled': followersEnabled,
      'followerSoundEnabled': followerSoundEnabled,
    };
  }
}
