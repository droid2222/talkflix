import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:talkflix_flutter/features/auth/presentation/signup_controller.dart';

void main() {
  group('SignupState.canContinue', () {
    test('account step requires email, password >= 6, verified, and token', () {
      const base = SignupState(step: SignupStep.account);
      expect(base.canContinue, isFalse);

      final partial = base.copyWith(
        email: 'a@b.com',
        password: '123456',
      );
      expect(partial.canContinue, isFalse);

      final ready = partial.copyWith(
        verified: true,
        emailVerificationToken: 'tok',
      );
      expect(ready.canContinue, isTrue);
    });

    test('profile step requires name, dob, and valid gender', () {
      const base = SignupState(step: SignupStep.profile);
      expect(base.canContinue, isFalse);

      final ready = base.copyWith(
        displayName: 'Alice',
        dob: '2000-01-01',
        gender: 'female',
      );
      expect(ready.canContinue, isTrue);

      final badGender = base.copyWith(
        displayName: 'Alice',
        dob: '2000-01-01',
        gender: 'other',
      );
      expect(badGender.canContinue, isFalse);
    });

    test('languages step requires country, first, and learn language', () {
      const base = SignupState(step: SignupStep.languages);
      expect(base.canContinue, isFalse);

      final ready = base.copyWith(
        fromCountry: 'US',
        firstLanguage: 'English',
        learnLanguage: 'Spanish',
      );
      expect(ready.canContinue, isTrue);
    });

    test('photo step always allows continue', () {
      const base = SignupState(step: SignupStep.photo);
      expect(base.canContinue, isTrue);
    });
  });

  group('SignupState.copyWith', () {
    test('clearError removes errorMessage', () {
      const state = SignupState(errorMessage: 'oops');
      final cleared = state.copyWith(clearError: true);
      expect(cleared.errorMessage, isNull);
    });

    test('clearStatus removes statusMessage', () {
      const state = SignupState(statusMessage: 'sent');
      final cleared = state.copyWith(clearStatus: true);
      expect(cleared.statusMessage, isNull);
    });

    test('clearPhoto removes photo fields', () {
      final state = SignupState(
        profilePhotoBytes: Uint8List.fromList([1, 2, 3]),
        profilePhotoMimeType: 'image/png',
        profilePhotoName: 'pic.png',
      );
      final cleared = state.copyWith(clearPhoto: true);
      expect(cleared.profilePhotoBytes, isNull);
      expect(cleared.profilePhotoMimeType, isNull);
      expect(cleared.profilePhotoName, isNull);
    });
  });
}
