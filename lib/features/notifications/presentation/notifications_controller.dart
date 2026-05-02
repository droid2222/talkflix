import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../core/realtime/socket_service.dart';
import '../data/app_notification.dart';
import '../data/notifications_repository.dart';

final notificationsControllerProvider = StateNotifierProvider.autoDispose<
    NotificationsController, NotificationsState>((ref) {
  final controller = NotificationsController(ref);
  ref.onDispose(controller._cleanup);
  return controller;
});

final unreadNotificationCountProvider = StateProvider<int>((ref) => 0);

class NotificationsController extends StateNotifier<NotificationsState> {
  NotificationsController(this._ref) : super(const NotificationsState()) {
    _socketHandler = _handleRealtimeNotification;
    Future<void>.microtask(load);
  }

  final Ref _ref;
  late final void Function(dynamic data) _socketHandler;

  Future<void> load() async {
    state = state.copyWith(isLoading: true, errorMessage: null);
    try {
      final notifications = await _ref
          .read(notificationsRepositoryProvider)
          .fetchNotifications();

      final socket = _ref.read(socketServiceProvider);
      socket.off('notification:new', _socketHandler);
      socket.on('notification:new', _socketHandler);

      state = state.copyWith(
        isLoading: false,
        notifications: notifications,
      );
      _syncUnreadCount();
    } catch (error) {
      state = state.copyWith(
        isLoading: false,
        errorMessage: error.toString(),
      );
    }
  }

  Future<void> refresh() => load();

  Future<void> markAsRead(String id) async {
    try {
      await _ref.read(notificationsRepositoryProvider).markAsRead(id);
      final updated = state.notifications.map((n) {
        if (n.id == id) {
          return AppNotification(
            id: n.id,
            type: n.type,
            title: n.title,
            body: n.body,
            fromUserId: n.fromUserId,
            fromDisplayName: n.fromDisplayName,
            fromPhotoUrl: n.fromPhotoUrl,
            targetId: n.targetId,
            isRead: true,
            createdAt: n.createdAt,
          );
        }
        return n;
      }).toList();
      state = state.copyWith(notifications: updated);
      _syncUnreadCount();
    } catch (_) {}
  }

  Future<void> markAllAsRead() async {
    try {
      await _ref.read(notificationsRepositoryProvider).markAllAsRead();
      final updated = state.notifications.map((n) {
        return AppNotification(
          id: n.id,
          type: n.type,
          title: n.title,
          body: n.body,
          fromUserId: n.fromUserId,
          fromDisplayName: n.fromDisplayName,
          fromPhotoUrl: n.fromPhotoUrl,
          targetId: n.targetId,
          isRead: true,
          createdAt: n.createdAt,
        );
      }).toList();
      state = state.copyWith(notifications: updated);
      _syncUnreadCount();
    } catch (_) {}
  }

  void _handleRealtimeNotification(dynamic data) {
    if (data is! Map) return;
    final notification =
        AppNotification.fromJson(Map<String, dynamic>.from(data));
    final next = [notification, ...state.notifications];
    state = state.copyWith(notifications: next);
    _syncUnreadCount();
  }

  void _syncUnreadCount() {
    final count = state.notifications.where((n) => !n.isRead).length;
    _ref.read(unreadNotificationCountProvider.notifier).state = count;
  }

  void _cleanup() {
    _ref.read(socketServiceProvider).off('notification:new', _socketHandler);
  }
}

class NotificationsState {
  const NotificationsState({
    this.notifications = const [],
    this.isLoading = false,
    this.errorMessage,
  });

  final List<AppNotification> notifications;
  final bool isLoading;
  final String? errorMessage;

  int get unreadCount => notifications.where((n) => !n.isRead).length;

  NotificationsState copyWith({
    List<AppNotification>? notifications,
    bool? isLoading,
    String? errorMessage,
  }) {
    return NotificationsState(
      notifications: notifications ?? this.notifications,
      isLoading: isLoading ?? this.isLoading,
      errorMessage: errorMessage ?? this.errorMessage,
    );
  }
}
