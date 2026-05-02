import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../core/network/api_client.dart';
import 'app_notification.dart';

final notificationsRepositoryProvider = Provider<NotificationsRepository>((ref) {
  return NotificationsRepository(ref);
});

class NotificationsRepository {
  const NotificationsRepository(this._ref);

  final Ref _ref;

  Future<List<AppNotification>> fetchNotifications() async {
    final data = await _ref.read(apiClientProvider).getJson('/me/notifications');
    final items = data['notifications'] as List<dynamic>? ?? const [];
    return items
        .whereType<Map<String, dynamic>>()
        .map(AppNotification.fromJson)
        .toList();
  }

  Future<void> markAsRead(String notificationId) async {
    await _ref
        .read(apiClientProvider)
        .patchJson('/me/notifications/$notificationId/read');
  }

  Future<void> markAllAsRead() async {
    await _ref.read(apiClientProvider).patchJson('/me/notifications/read-all');
  }

  Future<int> fetchUnreadCount() async {
    final data = await _ref
        .read(apiClientProvider)
        .getJson('/me/notifications/unread-count');
    return (data['count'] as num?)?.toInt() ?? 0;
  }
}
