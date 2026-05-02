class ChatThread {
  const ChatThread({
    required this.threadId,
    required this.partnerId,
    required this.displayName,
    required this.username,
    required this.lastMessageText,
    required this.unreadCount,
    required this.country,
    required this.profilePhotoUrl,
  });

  final String threadId;
  final String partnerId;
  final String displayName;
  final String username;
  final String lastMessageText;
  final int unreadCount;
  final String country;
  final String profilePhotoUrl;

  factory ChatThread.fromJson(Map<String, dynamic> json) {
    return ChatThread(
      threadId: json['threadId']?.toString() ?? '',
      partnerId: json['partnerId']?.toString() ?? '',
      displayName: json['displayName']?.toString() ?? 'User',
      username: json['username']?.toString() ?? 'user',
      lastMessageText: json['lastMessageText']?.toString() ?? '',
      unreadCount: (json['unreadCount'] as num?)?.toInt() ?? 0,
      country: json['country']?.toString() ?? '',
      profilePhotoUrl: json['profilePhotoUrl']?.toString() ?? '',
    );
  }
}
