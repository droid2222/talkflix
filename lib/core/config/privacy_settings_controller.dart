import 'package:flutter/foundation.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../auth/app_user.dart';
import '../auth/session_controller.dart';
import '../auth/session_state.dart';
import 'app_config.dart';
import 'storage_keys.dart';

@immutable
class PrivacySettingsState {
  const PrivacySettingsState({
    this.showAge = false,
    this.showFlag = false,
    this.showFollowStats = true,
    this.showOnlineStatus = true,
    this.receiveVoiceCalls = true,
    this.receiveVideoCalls = true,
  });

  final bool showAge;
  final bool showFlag;
  final bool showFollowStats;
  final bool showOnlineStatus;
  final bool receiveVoiceCalls;
  final bool receiveVideoCalls;

  PrivacySettingsState copyWith({
    bool? showAge,
    bool? showFlag,
    bool? showFollowStats,
    bool? showOnlineStatus,
    bool? receiveVoiceCalls,
    bool? receiveVideoCalls,
  }) {
    return PrivacySettingsState(
      showAge: showAge ?? this.showAge,
      showFlag: showFlag ?? this.showFlag,
      showFollowStats: showFollowStats ?? this.showFollowStats,
      showOnlineStatus: showOnlineStatus ?? this.showOnlineStatus,
      receiveVoiceCalls: receiveVoiceCalls ?? this.receiveVoiceCalls,
      receiveVideoCalls: receiveVideoCalls ?? this.receiveVideoCalls,
    );
  }
}

@immutable
class DirectChatCallPreferences {
  const DirectChatCallPreferences({
    this.receiveVoiceCalls = true,
    this.receiveVideoCalls = true,
  });

  final bool receiveVoiceCalls;
  final bool receiveVideoCalls;
}

final privacySettingsControllerProvider =
    StateNotifierProvider<PrivacySettingsController, PrivacySettingsState>((
      ref,
    ) {
      return PrivacySettingsController(ref);
    });

class PrivacySettingsController extends StateNotifier<PrivacySettingsState> {
  PrivacySettingsController(this._ref) : super(const PrivacySettingsState()) {
    Future<void>.microtask(_bootstrap);
    _ref.listen<SessionState>(sessionControllerProvider, (previous, next) {
      final user = next.user;
      if (user == null) return;
      _syncFromSessionUser(user);
    });
  }

  final Ref _ref;

  void _syncFromSessionUser(AppUser user) {
    state = state.copyWith(
      showAge: user.showAge,
      showFlag: user.showFlag,
      showFollowStats: user.showFollowStats,
      showOnlineStatus: user.showOnlineStatus,
      receiveVoiceCalls: user.receiveVoiceCalls,
      receiveVideoCalls: user.receiveVideoCalls,
    );
  }

  Future<void> _bootstrap() async {
    final prefs = await _ref.read(sharedPreferencesProvider.future);
    final sessionUser = _ref.read(sessionControllerProvider).user;
    const showAgePrefKey = StorageKeys.profilePrivacyShowAge;
    const showFlagPrefKey = StorageKeys.profilePrivacyShowFlag;
    state = PrivacySettingsState(
      showAge: prefs.containsKey(showAgePrefKey)
          ? (prefs.getBool(showAgePrefKey) ?? false)
          : (sessionUser?.showAge ?? false),
      showFlag: prefs.containsKey(showFlagPrefKey)
          ? (prefs.getBool(showFlagPrefKey) ?? false)
          : (sessionUser?.showFlag ?? false),
      showFollowStats:
          sessionUser?.showFollowStats ??
          prefs.getBool(StorageKeys.profilePrivacyShowFollowStats) ??
          true,
      showOnlineStatus:
          sessionUser?.showOnlineStatus ??
          prefs.getBool(StorageKeys.profilePrivacyShowOnlineStatus) ??
          true,
      receiveVoiceCalls: sessionUser?.receiveVoiceCalls ?? true,
      receiveVideoCalls: sessionUser?.receiveVideoCalls ?? true,
    );
  }

  Future<void> setShowAge(bool value) async {
    state = state.copyWith(showAge: value);
    final prefs = await _ref.read(sharedPreferencesProvider.future);
    await prefs.setBool(StorageKeys.profilePrivacyShowAge, value);
  }

  Future<void> setShowFlag(bool value) async {
    state = state.copyWith(showFlag: value);
    final prefs = await _ref.read(sharedPreferencesProvider.future);
    await prefs.setBool(StorageKeys.profilePrivacyShowFlag, value);
  }

  Future<void> setShowFollowStats(bool value) async {
    state = state.copyWith(showFollowStats: value);
    final prefs = await _ref.read(sharedPreferencesProvider.future);
    await prefs.setBool(StorageKeys.profilePrivacyShowFollowStats, value);
  }

  Future<void> setShowOnlineStatus(bool value) async {
    state = state.copyWith(showOnlineStatus: value);
    final prefs = await _ref.read(sharedPreferencesProvider.future);
    await prefs.setBool(StorageKeys.profilePrivacyShowOnlineStatus, value);
  }

  Future<void> setReceiveVoiceCalls(bool value) async {
    state = state.copyWith(receiveVoiceCalls: value);
    final prefs = await _ref.read(sharedPreferencesProvider.future);
    await prefs.setBool(StorageKeys.profilePrivacyReceiveVoiceCalls, value);
  }

  Future<void> setReceiveVideoCalls(bool value) async {
    state = state.copyWith(receiveVideoCalls: value);
    final prefs = await _ref.read(sharedPreferencesProvider.future);
    await prefs.setBool(StorageKeys.profilePrivacyReceiveVideoCalls, value);
  }

  Future<bool> canReceiveDirectChatCall({
    required String userId,
    required bool video,
  }) async {
    if (!AppConfig.directCallsEnabled) return false;
    final sharedPrefs = await _ref.read(sharedPreferencesProvider.future);
    if (video) {
      final receiveVideoCalls =
          sharedPrefs.getBool(StorageKeys.profilePrivacyReceiveVideoCalls) ??
          state.receiveVideoCalls;
      return receiveVideoCalls;
    }
    final receiveVoiceCalls =
        sharedPrefs.getBool(StorageKeys.profilePrivacyReceiveVoiceCalls) ??
        state.receiveVoiceCalls;
    return receiveVoiceCalls;
  }
}
