// ignore_for_file: prefer_final_locals

class ChatMessage {
  const ChatMessage({
    required this.id,
    required this.clientMessageId,
    required this.threadId,
    required this.fromUserId,
    required this.toUserId,
    required this.type,
    required this.text,
    required this.imageUrl,
    required this.audioUrl,
    required this.audioDuration,
    required this.mimeType,
    required this.status,
    required this.createdAt,
    this.replyToMessageId = '',
    this.isPending = false,
    this.isFailed = false,
  });

  final String id;
  final String clientMessageId;
  final String threadId;
  final String fromUserId;
  final String toUserId;
  final String type;
  final String text;
  final String imageUrl;
  final String audioUrl;
  final int audioDuration;
  final String mimeType;
  final String status;
  final DateTime createdAt;
  final String replyToMessageId;
  final bool isPending;
  final bool isFailed;

  bool get isText => type == 'text';
  bool get canRetry => isFailed;

  factory ChatMessage.fromJson(Map<String, dynamic> json) {
    final rawCreatedAt = json['createdAt'];
    final createdAt = switch (rawCreatedAt) {
      int value => DateTime.fromMillisecondsSinceEpoch(value),
      num value => DateTime.fromMillisecondsSinceEpoch(value.toInt()),
      String value => DateTime.tryParse(value) ?? DateTime.now(),
      _ => DateTime.now(),
    };

    return ChatMessage(
      id: json['id']?.toString() ?? '',
      clientMessageId: json['clientMessageId']?.toString() ?? '',
      threadId: json['threadId']?.toString() ?? '',
      fromUserId: json['fromUserId']?.toString() ?? '',
      toUserId: json['toUserId']?.toString() ?? '',
      type: json['type']?.toString() ?? 'text',
      text: json['text']?.toString() ?? '',
      imageUrl: json['imageUrl']?.toString() ?? '',
      audioUrl: json['audioUrl']?.toString() ?? '',
      audioDuration: (json['audioDuration'] as num?)?.toInt() ?? 0,
      mimeType: json['mimeType']?.toString() ?? '',
      status: json['status']?.toString() ?? 'sent',
      createdAt: createdAt,
      replyToMessageId: json['replyToMessageId']?.toString() ?? '',
      isPending: json['isPending'] == true,
      isFailed: json['isFailed'] == true,
    );
  }

  ChatMessage copyWith({
    String? id,
    String? clientMessageId,
    String? threadId,
    String? fromUserId,
    String? toUserId,
    String? type,
    String? text,
    String? imageUrl,
    String? audioUrl,
    int? audioDuration,
    String? mimeType,
    String? status,
    DateTime? createdAt,
    String? replyToMessageId,
    bool? isPending,
    bool? isFailed,
  }) {
    return ChatMessage(
      id: id ?? this.id,
      clientMessageId: clientMessageId ?? this.clientMessageId,
      threadId: threadId ?? this.threadId,
      fromUserId: fromUserId ?? this.fromUserId,
      toUserId: toUserId ?? this.toUserId,
      type: type ?? this.type,
      text: text ?? this.text,
      imageUrl: imageUrl ?? this.imageUrl,
      audioUrl: audioUrl ?? this.audioUrl,
      audioDuration: audioDuration ?? this.audioDuration,
      mimeType: mimeType ?? this.mimeType,
      status: status ?? this.status,
      createdAt: createdAt ?? this.createdAt,
      replyToMessageId: replyToMessageId ?? this.replyToMessageId,
      isPending: isPending ?? this.isPending,
      isFailed: isFailed ?? this.isFailed,
    );
  }

  Map<String, dynamic> toJson() {
    return <String, dynamic>{
      'id': id,
      'clientMessageId': clientMessageId,
      'threadId': threadId,
      'fromUserId': fromUserId,
      'toUserId': toUserId,
      'type': type,
      'text': text,
      'imageUrl': imageUrl,
      'audioUrl': audioUrl,
      'audioDuration': audioDuration,
      'mimeType': mimeType,
      'status': status,
      'createdAt': createdAt.toIso8601String(),
      'replyToMessageId': replyToMessageId,
      'isPending': isPending,
      'isFailed': isFailed,
    };
  }
}
