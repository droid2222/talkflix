import 'package:flutter_test/flutter_test.dart';
import 'package:talkflix_flutter/features/meet/presentation/meet_user_filter.dart';

void main() {
  group('discoverableMeetUsers', () {
    test('excludes admin users from meet discovery results', () {
      final users = discoverableMeetUsers([
        {'id': 'regular', 'role': 'user'},
        {'id': 'admin', 'role': 'admin'},
        {'id': 'superadmin', 'role': 'superadmin'},
        {'id': 'creator', 'role': 'creator'},
      ]);

      expect(users.map((user) => user['id']), ['regular', 'creator']);
    });

    test('matches admin role case-insensitively', () {
      final users = discoverableMeetUsers([
        {'id': 'admin', 'role': ' Admin '},
        {'id': 'regular', 'role': 'user'},
      ]);

      expect(users.map((user) => user['id']), ['regular']);
    });
  });
}
