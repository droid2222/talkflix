import 'package:flutter_test/flutter_test.dart';
import 'package:talkflix_flutter/features/notifications/data/app_notification.dart';

void main() {
  group('AppNotification.fromJson', () {
    test('parses complete notification', () {
      final n = AppNotification.fromJson({
        'id': 'n-1',
        'type': 'follow',
        'title': 'New follower',
        'body': 'Alice started following you',
        'fromUserId': 'user-a',
        'fromDisplayName': 'Alice',
        'fromPhotoUrl': 'https://img.test/a.jpg',
        'targetId': 'user-me',
        'isRead': false,
        'createdAt': '2025-06-01T12:00:00Z',
      });
      expect(n.id, 'n-1');
      expect(n.type, 'follow');
      expect(n.isFollowType, isTrue);
      expect(n.isRead, isFalse);
      expect(n.createdAt.year, 2025);
    });

    test('defaults for empty JSON', () {
      final n = AppNotification.fromJson({});
      expect(n.id, '');
      expect(n.type, 'system');
      expect(n.isSystemType, isTrue);
      expect(n.isRead, isFalse);
    });

    test('type getters work correctly', () {
      expect(
          AppNotification.fromJson({'type': 'message'}).isMessageType, isTrue);
      expect(
          AppNotification.fromJson({'type': 'follow'}).isFollowType, isTrue);
      expect(
          AppNotification.fromJson({'type': 'system'}).isSystemType, isTrue);
      expect(
          AppNotification.fromJson({'type': 'follow'}).isMessageType, isFalse);
    });

    test('handles int createdAt', () {
      final ms = DateTime(2024, 1, 1).millisecondsSinceEpoch;
      final n = AppNotification.fromJson({'createdAt': ms});
      expect(n.createdAt.year, 2024);
    });
  });
}
