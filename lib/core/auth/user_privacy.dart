bool? readUserPrivacyPreference(
  Map<String, dynamic> user, {
  required List<String> keys,
}) {
  final direct = _readBoolPreference(user, keys: keys);
  if (direct != null) return direct;
  final privacy = _coerceStringMap(user['privacy']);
  if (privacy == null) return null;
  return _readBoolPreference(privacy, keys: keys);
}

bool? _readBoolPreference(
  Map<String, dynamic> user, {
  required List<String> keys,
}) {
  for (final key in keys) {
    final parsed = _parseBool(user[key]);
    if (parsed != null) return parsed;
  }
  return null;
}

Map<String, dynamic>? _coerceStringMap(dynamic value) {
  if (value is! Map) return null;
  return value.map((key, nestedValue) => MapEntry(key.toString(), nestedValue));
}

bool? _parseBool(dynamic value) {
  if (value is bool) return value;
  if (value is num) {
    if (value == 1) return true;
    if (value == 0) return false;
  }
  final normalized = value?.toString().trim().toLowerCase();
  if (normalized == 'true' || normalized == '1') return true;
  if (normalized == 'false' || normalized == '0') return false;
  return null;
}
