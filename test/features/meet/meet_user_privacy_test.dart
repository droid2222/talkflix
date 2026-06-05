import 'package:flutter_test/flutter_test.dart';
import 'package:talkflix_flutter/core/config/privacy_settings_controller.dart';
import 'package:talkflix_flutter/features/meet/presentation/meet_user_privacy.dart';

void main() {
  group('shouldShowMeetFlag', () {
    test('uses local privacy preference for the signed-in user', () {
      final showFlag = shouldShowMeetFlag(
        user: const <String, dynamic>{'id': 'me', 'countryCode': 'US'},
        currentUserId: 'me',
        privacy: const PrivacySettingsState(showFlag: false),
      );

      expect(showFlag, isFalse);
    });

    test('honors explicit server flag visibility for other users', () {
      final showFlag = shouldShowMeetFlag(
        user: const <String, dynamic>{
          'id': 'them',
          'countryCode': 'US',
          'showFlag': false,
        },
        currentUserId: 'me',
        privacy: const PrivacySettingsState(showFlag: true),
      );

      expect(showFlag, isFalse);
    });

    test('honors nested privacy flag visibility for other users', () {
      final showFlag = shouldShowMeetFlag(
        user: const <String, dynamic>{
          'id': 'them',
          'countryCode': 'US',
          'privacy': {'flagVisible': false},
        },
        currentUserId: 'me',
        privacy: const PrivacySettingsState(showFlag: true),
      );

      expect(showFlag, isFalse);
    });
  });

  group('visibleMeetAgeLabel', () {
    test('hides age by default for the signed-in user', () {
      final ageLabel = visibleMeetAgeLabel(
        user: const <String, dynamic>{'id': 'me', 'age': 27},
        currentUserId: 'me',
        privacy: const PrivacySettingsState(showAge: false),
      );

      expect(ageLabel, isEmpty);
    });

    test('shows age for the signed-in user when enabled', () {
      final ageLabel = visibleMeetAgeLabel(
        user: const <String, dynamic>{'id': 'me', 'age': 27},
        currentUserId: 'me',
        privacy: const PrivacySettingsState(showAge: true),
      );

      expect(ageLabel, 'Age 27');
    });

    test('hides age for other users unless server says it is visible', () {
      final hiddenAge = visibleMeetAgeLabel(
        user: const <String, dynamic>{'id': 'them', 'age': 31},
        currentUserId: 'me',
        privacy: const PrivacySettingsState(showAge: true),
      );
      final shownAge = visibleMeetAgeLabel(
        user: const <String, dynamic>{'id': 'them', 'age': 31, 'showAge': true},
        currentUserId: 'me',
        privacy: const PrivacySettingsState(showAge: false),
      );

      expect(hiddenAge, isEmpty);
      expect(shownAge, 'Age 31');
    });

    test('shows age for other users when nested privacy marks it visible', () {
      final ageLabel = visibleMeetAgeLabel(
        user: const <String, dynamic>{
          'id': 'them',
          'age': 31,
          'privacy': {'ageVisible': true},
        },
        currentUserId: 'me',
        privacy: const PrivacySettingsState(showAge: false),
      );

      expect(ageLabel, 'Age 31');
    });
  });
}
