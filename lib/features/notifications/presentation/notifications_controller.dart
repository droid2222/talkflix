import 'dart:async';

import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../core/auth/session_controller.dart';
import '../../../core/config/storage_keys.dart';
import '../../../core/media/notification_sound_player.dart';
import '../../../core/realtime/socket_service.dart';
import '../application/notification_preferences_controller.dart';
import '../data/app_notification.dart';
import '../data/notifications_repository.dart';

final notificationsControllerProvider =
    StateNotifierProvider.autoDispose<
      NotificationsController,
      NotificationsState
    >((ref) {
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
        notifications: _visibleNotifications(notifications),
      );
      _syncUnreadCount();
    } catch (error) {
      state = state.copyWith(isLoading: false, errorMessage: error.toString());
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
            targetType: n.targetType,
            route: n.route,
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
      final unreadNotifications = state.notifications
          .where((notification) => !notification.isRead)
          .toList(growable: false);
      await Future.wait(
        unreadNotifications.map(
          (notification) => _ref
              .read(notificationsRepositoryProvider)
              .markAsRead(notification.id),
        ),
      );
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
          targetType: n.targetType,
          route: n.route,
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
    final notification = AppNotification.fromJson(
      Map<String, dynamic>.from(data),
    );
    unawaited(_applyRealtimeNotification(notification));
  }

  Future<void> _applyRealtimeNotification(AppNotification notification) async {
    if (await _shouldPlaySound(notification)) {
      unawaited(NotificationSoundPlayer.play());
    }
    if (!await _shouldDisplay(notification)) return;
    final next = [notification, ...state.notifications];
    state = state.copyWith(notifications: next);
    _syncUnreadCount();
  }

  Future<bool> _shouldDisplay(AppNotification notification) async {
    final preferences = _ref
        .read(notificationPreferencesControllerProvider)
        .preferences;
    if (!notification.isNotificationCenterVisible) {
      return false;
    }
    if (notification.isFollowType && !preferences.followersEnabled) {
      return false;
    }
    return true;
  }

  Future<bool> _shouldPlaySound(AppNotification notification) async {
    final preferences = _ref
        .read(notificationPreferencesControllerProvider)
        .preferences;
    if (notification.isMessageType) {
      return preferences.messagesEnabled &&
          preferences.messageSoundEnabled &&
          !await _messageThreadMuted(notification);
    }
    if (notification.isFollowType) {
      return preferences.followersEnabled && preferences.followerSoundEnabled;
    }
    return false;
  }

  Future<bool> _messageThreadMuted(AppNotification notification) async {
    final partnerId = notification.fromUserId.trim();
    if (partnerId.isEmpty) return false;
    final prefs = await _ref.read(sharedPreferencesProvider.future);
    return prefs.getBool('${StorageKeys.talkThreadMutedPrefix}$partnerId') ??
        false;
  }

  void _syncUnreadCount() {
    final count = state.notifications
        .where((n) => n.isNotificationCenterVisible && !n.isRead)
        .length;
    _ref.read(unreadNotificationCountProvider.notifier).state = count;
  }

  List<AppNotification> _visibleNotifications(
    List<AppNotification> notifications,
  ) {
    return notifications
        .where((notification) => notification.isNotificationCenterVisible)
        .toList(growable: false);
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
