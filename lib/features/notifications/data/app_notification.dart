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
  final bool isRead;
  final DateTime createdAt;

  bool get isFollowType => type == 'follow';
  bool get isMessageType => type == 'message';
  bool get isSystemType => type == 'system';

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
      isRead: json['isRead'] == true,
      createdAt: createdAt,
    );
  }
}
