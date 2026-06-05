import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:talkflix_flutter/app/localization/app_language_controller.dart';
import 'package:talkflix_flutter/app/localization/talkflix_localizations.dart';

void main() {
  group('TalkflixLocalizations', () {
    test('returns Russian auth copy for Russian locale', () {
      const l10n = TalkflixLocalizations(Locale('ru'));

      expect(l10n.welcomeBack, 'С возвращением');
      expect(l10n.createAccount, 'Создать аккаунт');
      expect(l10n.verificationCode, 'Код подтверждения');
    });

    test('returns Spanish auth copy for Spanish locale', () {
      const l10n = TalkflixLocalizations(Locale('es'));

      expect(l10n.forgotPasswordTitle, 'Olvidé mi contraseña');
      expect(l10n.sendResetLink, 'Enviar enlace de restablecimiento');
    });

    test('falls back to English for unsupported locales', () {
      const l10n = TalkflixLocalizations(Locale('it'));

      expect(l10n.welcomeBack, 'Welcome back');
      expect(l10n.signIn, 'Sign In');
    });

    test('resolves supported locales by language code', () {
      expect(
        resolveTalkflixLocale(const Locale('ru', 'RU'), supportedAppLocales),
        const Locale('ru'),
      );
      expect(
        resolveTalkflixLocale(const Locale('it', 'IT'), supportedAppLocales),
        const Locale('en'),
      );
    });
  });
}
