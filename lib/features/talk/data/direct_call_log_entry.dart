class DirectCallLogPage {
  const DirectCallLogPage({required this.entries, required this.nextCursor});

  factory DirectCallLogPage.fromJson(Map<String, dynamic> json) {
    final logs = json['logs'] as List<dynamic>? ?? const [];
    return DirectCallLogPage(
      entries: logs
          .whereType<Map<String, dynamic>>()
          .map(DirectCallLogEntry.fromJson)
          .toList(),
      nextCursor: '${json['nextCursor'] ?? ''}'.trim(),
    );
  }

  final List<DirectCallLogEntry> entries;
  final String nextCursor;

  bool get hasMore => nextCursor.isNotEmpty;
}

class DirectCallLogEntry {
  const DirectCallLogEntry({
    required this.callId,
    required this.threadId,
    required this.partnerId,
    required this.partnerDisplayName,
    required this.partnerUsername,
    required this.partnerPhotoUrl,
    required this.direction,
    required this.mode,
    required this.outcome,
    required this.requestedAt,
    required this.durationSeconds,
    this.answeredAt,
    this.startedAt,
    this.endedAt,
    this.endedByUserId = '',
  });

  factory DirectCallLogEntry.fromJson(Map<String, dynamic> json) {
    return DirectCallLogEntry(
      callId: '${json['callId'] ?? ''}'.trim(),
      threadId: '${json['threadId'] ?? ''}'.trim(),
      partnerId: '${json['partnerId'] ?? ''}'.trim(),
      partnerDisplayName: '${json['partnerDisplayName'] ?? ''}'.trim(),
      partnerUsername: '${json['partnerUsername'] ?? ''}'.trim(),
      partnerPhotoUrl: '${json['partnerPhotoUrl'] ?? ''}'.trim(),
      direction: _normalizeDirection(json['direction']),
      mode: _normalizeMode(json['mode']),
      outcome: _normalizeOutcome(json['outcome']),
      requestedAt:
          _parseDateTime(json['requestedAt']) ??
          _parseDateTime(json['initiatedAt']) ??
          DateTime.now(),
      answeredAt: _parseDateTime(json['answeredAt']),
      startedAt: _parseDateTime(json['startedAt']),
      endedAt: _parseDateTime(json['endedAt']),
      durationSeconds: _parseDuration(json['durationSeconds']),
      endedByUserId: '${json['endedByUserId'] ?? ''}'.trim(),
    );
  }

  final String callId;
  final String threadId;
  final String partnerId;
  final String partnerDisplayName;
  final String partnerUsername;
  final String partnerPhotoUrl;
  final String direction;
  final String mode;
  final String outcome;
  final DateTime requestedAt;
  final DateTime? answeredAt;
  final DateTime? startedAt;
  final DateTime? endedAt;
  final int durationSeconds;
  final String endedByUserId;

  bool get isIncoming => direction == 'incoming';
  bool get isVideo => mode == 'video';
  bool get isOngoing => outcome == 'ongoing';
  bool get isNegativeOutcome =>
      outcome == 'missed' ||
      outcome == 'unanswered' ||
      outcome == 'declined' ||
      outcome == 'cancelled';
}

DateTime? _parseDateTime(dynamic value) {
  if (value == null) return null;
  if (value is String) {
    final parsed = DateTime.tryParse(value.trim());
    return parsed?.toLocal();
  }
  if (value is num) {
    final milliseconds = value > 100000000000
        ? value.toInt()
        : value.toInt() * 1000;
    return DateTime.fromMillisecondsSinceEpoch(milliseconds).toLocal();
  }
  return null;
}

int _parseDuration(dynamic value) {
  final parsed =
      (value as num?)?.toInt() ?? int.tryParse('${value ?? ''}') ?? 0;
  return parsed < 0 ? 0 : parsed;
}

String _normalizeDirection(dynamic value) {
  final normalized = '${value ?? ''}'.trim().toLowerCase();
  return normalized == 'incoming' ? 'incoming' : 'outgoing';
}

String _normalizeMode(dynamic value) {
  final normalized = '${value ?? ''}'.trim().toLowerCase();
  return normalized == 'video' ? 'video' : 'voice';
}

String _normalizeOutcome(dynamic value) {
  final normalized = '${value ?? ''}'.trim().toLowerCase();
  switch (normalized) {
    case 'answered':
    case 'ongoing':
    case 'missed':
    case 'unanswered':
    case 'declined':
    case 'cancelled':
      return normalized;
    default:
      return 'answered';
  }
}
