import 'dart:ui' show PlatformDispatcher;

import 'package:flutter/material.dart';
import 'package:flutter_localizations/flutter_localizations.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../core/auth/session_controller.dart';
import '../../core/config/storage_keys.dart';

const systemAppLanguageLabel = 'System Default';
const defaultAppLanguageLabel = 'English';

@immutable
class AppLanguageOption {
  const AppLanguageOption({required this.label, required this.locale});

  const AppLanguageOption.system()
    : label = systemAppLanguageLabel,
      locale = null;

  final String label;
  final Locale? locale;
}

const appLanguageOptions = <AppLanguageOption>[
  AppLanguageOption.system(),
  AppLanguageOption(label: 'English', locale: Locale('en')),
  AppLanguageOption(label: 'Arabic', locale: Locale('ar')),
  AppLanguageOption(label: 'Bengali', locale: Locale('bn')),
  AppLanguageOption(label: 'Chinese (Simplified)', locale: Locale('zh')),
  AppLanguageOption(label: 'French', locale: Locale('fr')),
  AppLanguageOption(label: 'German', locale: Locale('de')),
  AppLanguageOption(label: 'Hindi', locale: Locale('hi')),
  AppLanguageOption(label: 'Indonesian', locale: Locale('id')),
  AppLanguageOption(label: 'Japanese', locale: Locale('ja')),
  AppLanguageOption(label: 'Korean', locale: Locale('ko')),
  AppLanguageOption(label: 'Portuguese', locale: Locale('pt')),
  AppLanguageOption(label: 'Russian', locale: Locale('ru')),
  AppLanguageOption(label: 'Spanish', locale: Locale('es')),
  AppLanguageOption(label: 'Turkish', locale: Locale('tr')),
  AppLanguageOption(label: 'Urdu', locale: Locale('ur')),
  AppLanguageOption(label: 'Vietnamese', locale: Locale('vi')),
];

final supportedAppLocales = (() {
  final locales = <Locale>[];
  final seen = <String>{};
  for (final option in appLanguageOptions) {
    final locale = option.locale;
    if (locale == null) continue;
    if (!GlobalMaterialLocalizations.delegate.isSupported(locale)) continue;
    final key = '${locale.languageCode}_${locale.countryCode ?? ''}';
    if (seen.add(key)) {
      locales.add(locale);
    }
  }
  if (!seen.contains('en_')) {
    locales.insert(0, const Locale('en'));
  }
  return List<Locale>.unmodifiable(locales);
})();

AppLanguageOption appLanguageOptionForLabel(String? label) {
  return appLanguageOptions.firstWhere(
    (option) => option.label == label,
    orElse: () => const AppLanguageOption(
      label: defaultAppLanguageLabel,
      locale: Locale('en'),
    ),
  );
}

final appLanguageLabels = List<String>.unmodifiable(<String>[
  for (final option in appLanguageOptions)
    if (option.locale != null) option.label,
]);

final appLanguageControllerProvider =
    StateNotifierProvider<AppLanguageController, String>((ref) {
      return AppLanguageController(ref);
    });

final appLocaleProvider = Provider<Locale?>((ref) {
  final selectedLabel = ref.watch(appLanguageControllerProvider);
  final locale = appLanguageOptionForLabel(selectedLabel).locale;
  if (locale == null) return null;
  if (!GlobalMaterialLocalizations.delegate.isSupported(locale)) return null;
  return locale;
});

final effectiveAppLocaleProvider = Provider<Locale>((ref) {
  final selectedLocale = ref.watch(appLocaleProvider);
  if (selectedLocale != null) {
    return selectedLocale;
  }
  return _resolveAppLocale(
        PlatformDispatcher.instance.locale,
        supportedAppLocales,
      ) ??
      const Locale('en');
});

Locale? _resolveAppLocale(Locale? locale, Iterable<Locale> supportedLocales) {
  if (locale == null) return supportedLocales.firstOrNull;
  for (final supported in supportedLocales) {
    if (supported.languageCode == locale.languageCode &&
        (supported.countryCode == null ||
            supported.countryCode == locale.countryCode)) {
      return supported;
    }
  }
  for (final supported in supportedLocales) {
    if (supported.languageCode == locale.languageCode) {
      return supported;
    }
  }
  return supportedLocales.firstOrNull;
}

class AppLanguageController extends StateNotifier<String> {
  AppLanguageController(this._ref) : super(defaultAppLanguageLabel) {
    Future<void>.microtask(_bootstrap);
  }

  final Ref _ref;

  Future<void> _bootstrap() async {
    final prefs = await _ref.read(sharedPreferencesProvider.future);
    if (!mounted) return;
    final saved = prefs.getString(StorageKeys.appLanguage);
    state = appLanguageOptionForLabel(saved).label;
  }

  Future<void> setLanguage(String label) async {
    final normalized = appLanguageOptionForLabel(label).label;
    state = normalized;
    final prefs = await _ref.read(sharedPreferencesProvider.future);
    await prefs.setString(StorageKeys.appLanguage, normalized);
  }
}
