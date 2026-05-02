import 'package:flutter_test/flutter_test.dart';
import 'package:talkflix_flutter/features/meet/presentation/meet_filters_controller.dart';

void main() {
  late MeetFiltersController controller;

  setUp(() {
    controller = MeetFiltersController(
      const MeetFiltersState(
        selectedNativeLanguage: 'Any',
        selectedLearningLanguage: 'Any',
        availableLanguages: ['Any', 'English', 'Spanish'],
      ),
    );
  });

  group('MeetFiltersController', () {
    test('selectNativeLanguage updates state', () {
      controller.selectNativeLanguage('English');
      expect(controller.state.selectedNativeLanguage, 'English');
    });

    test('addAvailableLanguage adds and sorts', () {
      controller.addAvailableLanguage('French');
      expect(controller.state.availableLanguages, contains('French'));
      expect(controller.state.availableLanguages.first, 'Any');
      expect(controller.state.selectedNativeLanguage, 'French');
    });

    test('addAvailableLanguage ignores empty and Any', () {
      final before = List<String>.from(controller.state.availableLanguages);
      controller.addAvailableLanguage('');
      controller.addAvailableLanguage('Any');
      expect(controller.state.availableLanguages, before);
    });

    test('selectGender updates state', () {
      controller.selectGender('female');
      expect(controller.state.selectedGender, 'female');
    });

    test('reset restores defaults', () {
      controller.selectGender('male');
      controller.selectCountry('US');
      controller.setNewUsers(true);
      controller.reset();

      expect(controller.state.selectedGender, 'all');
      expect(controller.state.selectedCountry, 'Any');
      expect(controller.state.newUsersOnly, isFalse);
      expect(controller.state.minAge, 18);
      expect(controller.state.maxAge, 90);
    });

    test('selectCountry resets city to Any', () {
      controller.selectCity('LA');
      controller.selectCountry('UK');
      expect(controller.state.selectedCity, 'Any');
    });
  });
}
