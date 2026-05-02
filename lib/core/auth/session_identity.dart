import 'dart:convert';

class SessionIdentity {
  const SessionIdentity({
    required this.userId,
    required this.sessionId,
  });

  const SessionIdentity.empty()
    : userId = '',
      sessionId = '';

  final String userId;
  final String sessionId;

  bool get isValid => userId.isNotEmpty && sessionId.isNotEmpty;
}

SessionIdentity parseSessionIdentityFromToken(String token) {
  final normalized = token.trim();
  if (normalized.isEmpty) return const SessionIdentity.empty();

  try {
    final segments = normalized.split('.');
    if (segments.length < 2) return const SessionIdentity.empty();
    final payloadSegment = base64Url.normalize(segments[1]);
    final payloadBytes = base64Url.decode(payloadSegment);
    final payload =
        jsonDecode(utf8.decode(payloadBytes)) as Map<String, dynamic>;
    return SessionIdentity(
      userId: '${payload['sub'] ?? ''}'.trim(),
      sessionId: '${payload['sid'] ?? payload['sessionId'] ?? ''}'.trim(),
    );
  } catch (_) {
    return const SessionIdentity.empty();
  }
}
