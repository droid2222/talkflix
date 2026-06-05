import '../../../core/auth/user_privacy.dart';
import '../../../core/config/privacy_settings_controller.dart';

bool shouldShowMeetFlag({
  required Map<String, dynamic> user,
  required String currentUserId,
  required PrivacySettingsState privacy,
}) {
  final serverPreference = readUserPrivacyPreference(
    user,
    keys: const <String>['showFlag', 'flagVisible', 'showNationalityFlag'],
  );
  if (serverPreference != null) return serverPreference;
  final userId = user['id']?.toString() ?? '';
  if (userId.isNotEmpty && userId == currentUserId) {
    return privacy.showFlag;
  }
  return true;
}

String visibleMeetAgeLabel({
  required Map<String, dynamic> user,
  required String currentUserId,
  required PrivacySettingsState privacy,
}) {
  final age = _readAge(user['age']);
  if (age.isEmpty) return '';
  final serverPreference = readUserPrivacyPreference(
    user,
    keys: const <String>['showAge', 'ageVisible'],
  );
  if (serverPreference != null) {
    return serverPreference ? 'Age $age' : '';
  }
  final userId = user['id']?.toString() ?? '';
  if (userId.isNotEmpty && userId == currentUserId) {
    return privacy.showAge ? 'Age $age' : '';
  }
  return '';
}

String _readAge(dynamic value) {
  if (value is num) {
    final age = value.toInt();
    return age > 0 ? '$age' : '';
  }
  final text = value?.toString().trim() ?? '';
  if (text.isEmpty) return '';
  final parsed = int.tryParse(text);
  if (parsed == null || parsed <= 0) return '';
  return '$parsed';
}
