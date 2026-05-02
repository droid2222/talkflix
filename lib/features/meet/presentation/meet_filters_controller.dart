import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../core/auth/session_controller.dart';

final meetFiltersProvider =
    StateNotifierProvider<MeetFiltersController, MeetFiltersState>((ref) {
      final session = ref.watch(sessionControllerProvider);
      final user = session.user;
      final availableLanguages = <String>{
        'Any',
        if ((user?.learnLanguage ?? '').isNotEmpty) user!.learnLanguage,
        ...?user?.meetLanguages,
      }.toList();

      final initialLanguage = availableLanguages.isNotEmpty
          ? availableLanguages.first
          : 'Any';

      return MeetFiltersController(
        MeetFiltersState(
          selectedNativeLanguage: initialLanguage,
          selectedLearningLanguage: 'Any',
          availableLanguages: availableLanguages,
        ),
      );
    });

class MeetFiltersController extends StateNotifier<MeetFiltersState> {
  MeetFiltersController(super.state);

  void selectNativeLanguage(String value) {
    state = state.copyWith(selectedNativeLanguage: value);
  }

  void addAvailableLanguage(String value) {
    final trimmed = value.trim();
    if (trimmed.isEmpty || trimmed == 'Any') return;

    final updated = <String>{
      'Any',
      ...state.availableLanguages.where((item) => item != 'Any'),
      trimmed,
    }.toList()
      ..sort((a, b) {
        if (a == 'Any') return -1;
        if (b == 'Any') return 1;
        return a.toLowerCase().compareTo(b.toLowerCase());
      });

    state = state.copyWith(
      availableLanguages: updated,
      selectedNativeLanguage: trimmed,
    );
  }

  void selectLearningLanguage(String value) {
    state = state.copyWith(selectedLearningLanguage: value);
  }

  void selectCountry(String value) {
    state = state.copyWith(selectedCountry: value, selectedCity: 'Any');
  }

  void selectCity(String value) {
    state = state.copyWith(selectedCity: value);
  }

  void setUseProSearch(bool value) {
    state = state.copyWith(useProSearch: value);
  }

  void selectGender(String value) {
    state = state.copyWith(selectedGender: value);
  }

  void selectAgeRange(RangeValues value) {
    state = state.copyWith(
      minAge: value.start.round(),
      maxAge: value.end.round(),
    );
  }

  void setNewUsers(bool value) {
    state = state.copyWith(newUsersOnly: value);
  }

  void setPrioritizeNearby(bool value) {
    state = state.copyWith(prioritizeNearby: value);
  }

  void reset() {
    state = state.copyWith(
      selectedNativeLanguage: state.availableLanguages.isNotEmpty
          ? state.availableLanguages.first
          : 'Any',
      selectedLearningLanguage: 'Any',
      selectedCountry: 'Any',
      selectedCity: 'Any',
      selectedGender: 'all',
      minAge: 18,
      maxAge: 90,
      newUsersOnly: false,
      prioritizeNearby: false,
      useProSearch: false,
    );
  }
}

class MeetFiltersState {
  const MeetFiltersState({
    required this.selectedNativeLanguage,
    required this.selectedLearningLanguage,
    required this.availableLanguages,
    this.selectedCountry = 'Any',
    this.selectedCity = 'Any',
    this.selectedGender = 'all',
    this.minAge = 18,
    this.maxAge = 90,
    this.newUsersOnly = false,
    this.prioritizeNearby = false,
    this.useProSearch = false,
  });

  final String selectedNativeLanguage;
  final String selectedLearningLanguage;
  final List<String> availableLanguages;
  final String selectedCountry;
  final String selectedCity;
  final String selectedGender;
  final int minAge;
  final int maxAge;
  final bool newUsersOnly;
  final bool prioritizeNearby;
  final bool useProSearch;

  MeetFiltersState copyWith({
    String? selectedNativeLanguage,
    String? selectedLearningLanguage,
    List<String>? availableLanguages,
    String? selectedCountry,
    String? selectedCity,
    String? selectedGender,
    int? minAge,
    int? maxAge,
    bool? newUsersOnly,
    bool? prioritizeNearby,
    bool? useProSearch,
  }) {
    return MeetFiltersState(
      selectedNativeLanguage:
          selectedNativeLanguage ?? this.selectedNativeLanguage,
      selectedLearningLanguage:
          selectedLearningLanguage ?? this.selectedLearningLanguage,
      availableLanguages: availableLanguages ?? this.availableLanguages,
      selectedCountry: selectedCountry ?? this.selectedCountry,
      selectedCity: selectedCity ?? this.selectedCity,
      selectedGender: selectedGender ?? this.selectedGender,
      minAge: minAge ?? this.minAge,
      maxAge: maxAge ?? this.maxAge,
      newUsersOnly: newUsersOnly ?? this.newUsersOnly,
      prioritizeNearby: prioritizeNearby ?? this.prioritizeNearby,
      useProSearch: useProSearch ?? this.useProSearch,
    );
  }
}
