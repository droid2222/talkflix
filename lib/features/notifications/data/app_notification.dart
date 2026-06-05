// ignore_for_file: prefer_final_locals

class AppNotification {
  const AppNotification({
    required this.id,
    required this.type,
    required this.title,
    required this.body,
    required this.fromUserId,
    required this.fromDisplayName,
    required this.fromPhotoUrl,
    required this.targetId,
    required this.targetType,
    required this.route,
    required this.isRead,
    required this.createdAt,
  });

  final String id;
  final String type; // 'follow', 'message', 'like', 'mention', 'system'
  final String title;
  final String body;
  final String fromUserId;
  final String fromDisplayName;
  final String fromPhotoUrl;
  final String targetId;
  final String targetType;
  final String route;
  final bool isRead;
  final DateTime createdAt;

  bool get isFollowType {
    final normalized = type.trim().toLowerCase();
    return normalized == 'follow' ||
        normalized == 'follower' ||
        normalized == 'new_follower';
  }

  bool get isMessageType {
    final normalized = type.trim().toLowerCase();
    return normalized == 'message' ||
        normalized == 'direct_message' ||
        normalized == 'chat_message';
  }

  bool get isNotificationCenterVisible => !isMessageType;

  bool get isSystemType => type == 'system';

  String get resolvedRoute {
    final explicit = route.trim();
    if (explicit.startsWith('/app/')) return explicit;

    final normalizedType = type.trim().toLowerCase();
    final normalizedTargetType = targetType.trim().toLowerCase();
    final target = targetId.trim();
    final fromUser = fromUserId.trim();

    if (normalizedTargetType == 'profile' && target.isNotEmpty) {
      return '/app/profile/$target';
    }
    if (normalizedTargetType == 'video') {
      if (target.isNotEmpty) return '/app/content/videos/$target';
    }
    if (normalizedTargetType == 'post' || normalizedTargetType == 'content') {
      return '/app/content';
    }
    if (normalizedTargetType == 'live_room' && target.isNotEmpty) {
      return '/app/live?broadcastId=$target';
    }
    if (normalizedTargetType == 'direct_chat' && fromUser.isNotEmpty) {
      return '/app/talk/$fromUser';
    }

    if (isFollowType && fromUser.isNotEmpty) return '/app/profile/$fromUser';
    if (normalizedType.contains('message') && fromUser.isNotEmpty) {
      return '/app/talk/$fromUser';
    }
    if (normalizedType.startsWith('video_') && target.isNotEmpty) {
      return '/app/content/videos/$target';
    }
    if (normalizedType.startsWith('post_') ||
        normalizedType.contains('content')) {
      return '/app/content';
    }
    if ((normalizedType.contains('like') ||
            normalizedType.contains('comment')) &&
        target.isNotEmpty) {
      return '/app/content';
    }
    if (normalizedType.contains('live') && target.isNotEmpty) {
      return '/app/live?broadcastId=$target';
    }
    return '';
  }

  factory AppNotification.fromJson(Map<String, dynamic> json) {
    final rawCreatedAt = json['createdAt'];
    final createdAt = switch (rawCreatedAt) {
      int value => DateTime.fromMillisecondsSinceEpoch(value),
      num value => DateTime.fromMillisecondsSinceEpoch(value.toInt()),
      String value => DateTime.tryParse(value) ?? DateTime.now(),
      _ => DateTime.now(),
    };

    return AppNotification(
      id: json['id']?.toString() ?? '',
      type: json['type']?.toString() ?? 'system',
      title: json['title']?.toString() ?? '',
      body: json['body']?.toString() ?? '',
      fromUserId: json['fromUserId']?.toString() ?? '',
      fromDisplayName: json['fromDisplayName']?.toString() ?? '',
      fromPhotoUrl: json['fromPhotoUrl']?.toString() ?? '',
      targetId: json['targetId']?.toString() ?? '',
      targetType: json['targetType']?.toString() ?? '',
      route: json['route']?.toString() ?? '',
      isRead: json['isRead'] == true,
      createdAt: createdAt,
    );
  }
}
