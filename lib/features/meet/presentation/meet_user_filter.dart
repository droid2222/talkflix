bool isDiscoverableMeetUser(Map<String, dynamic> user) {
  final role = user['role']?.toString().trim().toLowerCase() ?? '';
  return role != 'admin' && role != 'superadmin';
}

List<Map<String, dynamic>> discoverableMeetUsers(dynamic users) {
  return (users as List<dynamic>? ?? const [])
      .whereType<Map<String, dynamic>>()
      .where(isDiscoverableMeetUser)
      .toList();
}
