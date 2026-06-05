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
    required this.fileUrl,
    required this.fileName,
    required this.fileSize,
    required this.mimeType,
    required this.linkPreview,
    required this.reactions,
    required this.myReaction,
    required this.pinnedByMe,
    required this.editedAt,
    required this.status,
    required this.createdAt,
    this.replyToMessageId = '',
    this.isPending = false,
    this.isFailed = false,
  });

  static const String callEventType = 'call_event';

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
  final String fileUrl;
  final String fileName;
  final int fileSize;
  final String mimeType;
  final Map<String, dynamic> linkPreview;
  final Map<String, int> reactions;
  final String myReaction;
  final bool pinnedByMe;
  final DateTime? editedAt;
  final String status;
  final DateTime createdAt;
  final String replyToMessageId;
  final bool isPending;
  final bool isFailed;

  bool get isText => type == 'text';
  bool get isFile => type == 'file';
  bool get isCallEvent => type == callEventType;
  bool get canRetry => isFailed;

  factory ChatMessage.localCallEvent({
    required String threadId,
    required String callId,
    required String eventKey,
    required String text,
    DateTime? createdAt,
  }) {
    final timestamp = createdAt ?? DateTime.now();
    final normalizedId = localCallEventId(
      callId: callId,
      eventKey: eventKey,
      createdAt: timestamp,
    );
    return ChatMessage(
      id: normalizedId,
      clientMessageId: normalizedId,
      threadId: threadId,
      fromUserId: '',
      toUserId: '',
      type: callEventType,
      text: text.trim(),
      imageUrl: '',
      audioUrl: '',
      audioDuration: 0,
      fileUrl: '',
      fileName: '',
      fileSize: 0,
      mimeType: 'text/plain',
      linkPreview: const <String, dynamic>{},
      reactions: const <String, int>{},
      myReaction: '',
      pinnedByMe: false,
      editedAt: null,
      status: 'sent',
      createdAt: timestamp,
    );
  }

  static String localCallEventId({
    required String callId,
    required String eventKey,
    DateTime? createdAt,
  }) {
    final normalizedCallId = callId.trim();
    if (normalizedCallId.isNotEmpty) {
      return 'local-call-event-$normalizedCallId-$eventKey';
    }
    final timestamp = createdAt ?? DateTime.now();
    return 'local-call-event-${timestamp.microsecondsSinceEpoch}-$eventKey';
  }

  factory ChatMessage.fromJson(Map<String, dynamic> json) {
    final rawCreatedAt = json['createdAt'];
    final createdAt = switch (rawCreatedAt) {
      int value => DateTime.fromMillisecondsSinceEpoch(value),
      num value => DateTime.fromMillisecondsSinceEpoch(value.toInt()),
      String value => DateTime.tryParse(value) ?? DateTime.now(),
      _ => DateTime.now(),
    };
    final rawEditedAt = json['editedAt'];
    final editedAt = switch (rawEditedAt) {
      int value when value > 0 => DateTime.fromMillisecondsSinceEpoch(value),
      num value when value > 0 => DateTime.fromMillisecondsSinceEpoch(
        value.toInt(),
      ),
      String value when value.isNotEmpty => DateTime.tryParse(value),
      _ => null,
    };
    final rawReactions = json['reactions'];
    final reactions = <String, int>{};
    if (rawReactions is Map) {
      rawReactions.forEach((key, value) {
        final emoji = key.toString().trim();
        final count = (value as num?)?.toInt() ?? 0;
        if (emoji.isNotEmpty && count > 0) reactions[emoji] = count;
      });
    }

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
      fileUrl: json['fileUrl']?.toString() ?? '',
      fileName: json['fileName']?.toString() ?? '',
      fileSize: (json['fileSize'] as num?)?.toInt() ?? 0,
      mimeType: json['mimeType']?.toString() ?? '',
      linkPreview: json['linkPreview'] is Map
          ? Map<String, dynamic>.from(json['linkPreview'] as Map)
          : const <String, dynamic>{},
      reactions: reactions,
      myReaction: json['myReaction']?.toString() ?? '',
      pinnedByMe: json['pinnedByMe'] == true,
      editedAt: editedAt,
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
    String? fileUrl,
    String? fileName,
    int? fileSize,
    String? mimeType,
    Map<String, dynamic>? linkPreview,
    Map<String, int>? reactions,
    String? myReaction,
    bool? pinnedByMe,
    DateTime? editedAt,
    bool clearEditedAt = false,
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
      fileUrl: fileUrl ?? this.fileUrl,
      fileName: fileName ?? this.fileName,
      fileSize: fileSize ?? this.fileSize,
      mimeType: mimeType ?? this.mimeType,
      linkPreview: linkPreview ?? this.linkPreview,
      reactions: reactions ?? this.reactions,
      myReaction: myReaction ?? this.myReaction,
      pinnedByMe: pinnedByMe ?? this.pinnedByMe,
      editedAt: clearEditedAt ? null : editedAt ?? this.editedAt,
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
      'fileUrl': fileUrl,
      'fileName': fileName,
      'fileSize': fileSize,
      'mimeType': mimeType,
      'linkPreview': linkPreview,
      'reactions': reactions,
      'myReaction': myReaction,
      'pinnedByMe': pinnedByMe,
      'editedAt': editedAt?.toIso8601String(),
      'status': status,
      'createdAt': createdAt.toIso8601String(),
      'replyToMessageId': replyToMessageId,
      'isPending': isPending,
      'isFailed': isFailed,
    };
  }
}
