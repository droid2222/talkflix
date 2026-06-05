import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:talkflix_flutter/app/localization/app_language_controller.dart';
import 'package:talkflix_flutter/core/auth/session_controller.dart';
import 'package:talkflix_flutter/core/config/storage_keys.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  group('AppLanguageController', () {
    test('defaults to English on first launch', () async {
      SharedPreferences.setMockInitialValues(<String, Object>{});
      final container = ProviderContainer();
      addTearDown(container.dispose);

      await _settleController(container);

      expect(
        container.read(appLanguageControllerProvider),
        defaultAppLanguageLabel,
      );
      expect(container.read(appLocaleProvider), const Locale('en'));
    });

    test('restores the saved system-default choice', () async {
      SharedPreferences.setMockInitialValues(<String, Object>{
        StorageKeys.appLanguage: systemAppLanguageLabel,
      });
      final container = ProviderContainer();
      addTearDown(container.dispose);

      await _settleController(container);

      expect(
        container.read(appLanguageControllerProvider),
        systemAppLanguageLabel,
      );
      expect(container.read(appLocaleProvider), isNull);
    });

    test(
      'falls back to English when the saved language is unsupported',
      () async {
        SharedPreferences.setMockInitialValues(<String, Object>{
          StorageKeys.appLanguage: 'Polish',
        });
        final container = ProviderContainer();
        addTearDown(container.dispose);

        await _settleController(container);

        expect(
          container.read(appLanguageControllerProvider),
          defaultAppLanguageLabel,
        );
        expect(container.read(appLocaleProvider), const Locale('en'));
      },
    );
  });
}

Future<void> _settleController(ProviderContainer container) async {
  container.read(appLanguageControllerProvider);
  await container.read(sharedPreferencesProvider.future);
  await Future<void>.delayed(const Duration(milliseconds: 10));
}
