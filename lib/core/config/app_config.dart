import 'dart:convert';

class AppConfig {
  static const _defaultApiBaseUrl = 'https://api.talkflix.cc';

  // Override this to target a local backend when needed.
  // Examples:
  // flutter run --dart-define=API_BASE_URL=http://127.0.0.1:4000
  // flutter run --dart-define=API_BASE_URL=http://10.0.2.2:4000
  static const _apiBaseUrlOverride = String.fromEnvironment('API_BASE_URL');
  static const _iceServersJsonOverride = String.fromEnvironment(
    'RTC_ICE_SERVERS_JSON',
  );
  static const _turnUrlOverride = String.fromEnvironment('RTC_TURN_URL');
  static const _turnUsernameOverride = String.fromEnvironment(
    'RTC_TURN_USERNAME',
  );
  static const _turnCredentialOverride = String.fromEnvironment(
    'RTC_TURN_CREDENTIAL',
  );
  static const _liveUseAckModerationOverride = String.fromEnvironment(
    'LIVE_USE_ACK_MODERATION',
  );
  static const _liveRequireHostModerationOverride = String.fromEnvironment(
    'LIVE_REQUIRE_HOST_MODERATION',
  );
  static const _liveUseSfuSpeakingIndicatorOverride = String.fromEnvironment(
    'LIVE_USE_SFU_SPEAKING_INDICATOR',
  );
  static const _liveUseSfuAudioOverride = String.fromEnvironment(
    'LIVE_USE_SFU_AUDIO',
  );

  static bool _envFlag(String raw, {required bool fallback}) {
    final normalized = raw.trim().toLowerCase();
    if (normalized.isEmpty) return fallback;
    if (normalized == '1' || normalized == 'true' || normalized == 'yes') {
      return true;
    }
    if (normalized == '0' || normalized == 'false' || normalized == 'no') {
      return false;
    }
    return fallback;
  }

  static String get apiBaseUrl {
    if (_apiBaseUrlOverride.trim().isNotEmpty) {
      return _apiBaseUrlOverride.trim();
    }
    return _defaultApiBaseUrl;
  }

  static List<Map<String, dynamic>> get rtcIceServers {
    final fallback = <Map<String, dynamic>>[
      {'urls': 'stun:stun.l.google.com:19302'},
      {'urls': 'stun:stun1.l.google.com:19302'},
    ];

    if (_iceServersJsonOverride.trim().isNotEmpty) {
      try {
        final decoded = jsonDecode(_iceServersJsonOverride.trim());
        if (decoded is List) {
          final parsed = decoded
              .whereType<Map>()
              .map((item) => Map<String, dynamic>.from(item))
              .where((item) => item['urls'] != null)
              .toList();
          if (parsed.isNotEmpty) return parsed;
        }
      } catch (_) {}
    }

    final turnUrl = _turnUrlOverride.trim();
    final turnUser = _turnUsernameOverride.trim();
    final turnCredential = _turnCredentialOverride.trim();
    if (turnUrl.isNotEmpty &&
        turnUser.isNotEmpty &&
        turnCredential.isNotEmpty) {
      return <Map<String, dynamic>>[
        ...fallback,
        <String, dynamic>{
          'urls': turnUrl,
          'username': turnUser,
          'credential': turnCredential,
        },
      ];
    }
    return fallback;
  }

  static Map<String, dynamic> get rtcPeerConnectionConfig {
    return <String, dynamic>{
      'iceServers': rtcIceServers,
      'sdpSemantics': 'unified-plan',
      'iceCandidatePoolSize': 4,
    };
  }

  // Live room rollout flags. Keep defaults aligned with stable behavior.
  static bool get liveUseAckModeration =>
      _envFlag(_liveUseAckModerationOverride, fallback: true);

  static bool get liveRequireHostModeration =>
      _envFlag(_liveRequireHostModerationOverride, fallback: true);

  static bool get liveUseSfuSpeakingIndicator =>
      _envFlag(_liveUseSfuSpeakingIndicatorOverride, fallback: true);

  // Audio rooms use the LiveKit SFU path in production. Override this with
  // `--dart-define=LIVE_USE_SFU_AUDIO=false` when targeting a local backend
  // that does not provision media sessions yet.
  static bool get liveUseSfuAudio =>
      _envFlag(_liveUseSfuAudioOverride, fallback: true);
}
