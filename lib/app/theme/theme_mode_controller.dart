import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../core/auth/session_controller.dart';
import '../../core/config/storage_keys.dart';

final themeModeControllerProvider =
    StateNotifierProvider<ThemeModeController, ThemeMode>((ref) {
      return ThemeModeController(ref);
    });

class ThemeModeController extends StateNotifier<ThemeMode> {
  ThemeModeController(this._ref) : super(ThemeMode.system) {
    Future<void>.microtask(_bootstrap);
  }

  final Ref _ref;

  Future<void> _bootstrap() async {
    final prefs = await _ref.read(sharedPreferencesProvider.future);
    final saved = prefs.getString(StorageKeys.themeMode);
    state = _deserialize(saved);
  }

  Future<void> setThemeMode(ThemeMode mode) async {
    state = mode;
    final prefs = await _ref.read(sharedPreferencesProvider.future);
    await prefs.setString(StorageKeys.themeMode, _serialize(mode));
  }

  String _serialize(ThemeMode mode) {
    switch (mode) {
      case ThemeMode.light:
        return 'light';
      case ThemeMode.dark:
        return 'dark';
      case ThemeMode.system:
        return 'system';
    }
  }

  ThemeMode _deserialize(String? value) {
    switch (value) {
      case 'light':
        return ThemeMode.light;
      case 'dark':
        return ThemeMode.dark;
      default:
        return ThemeMode.system;
    }
  }
}
