import 'dart:convert';

import 'package:flutter/foundation.dart';

class AppConfig {
  static const _defaultApiBaseUrl = 'https://api.talkflix.cc';

  /// Public web / store landing page used in SMS invites and contact cards.
  static const publicMarketingUrl = 'https://www.talkflix.cc';
  static const accountDeletionPath = '/account-deletion';
  static const accountDeletionUrl = '$publicMarketingUrl$accountDeletionPath';
  static const supportEmail = 'info@talkflix.cc';

  static Uri get supportEmailUri => Uri(
    scheme: 'mailto',
    path: supportEmail,
    queryParameters: const <String, String>{'subject': 'Talkflix Support'},
  );

  static Uri get accountDeletionEmailUri => Uri(
    scheme: 'mailto',
    path: supportEmail,
    queryParameters: const <String, String>{
      'subject': 'Talkflix Account Deletion Request',
      'body':
          'Please delete my Talkflix account.\n\n'
          'Account email:\n'
          'Username, if known:\n'
          'Reason, optional:\n\n'
          'Do not include your password in this email.',
    },
  );

  static String get smsInviteBody =>
      "Let's chat on Talkflix — download the app and find me there: $publicMarketingUrl";

  static String liveBroadcastShareUrl(String broadcastId) {
    final normalizedId = broadcastId.trim();
    if (normalizedId.isEmpty) {
      return '$publicMarketingUrl/app/live';
    }
    final uri = Uri.parse(
      '$publicMarketingUrl/app/live',
    ).replace(queryParameters: <String, String>{'broadcastId': normalizedId});
    return uri.toString();
  }

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
  static const _directCallsEnabledOverride = String.fromEnvironment(
    'DIRECT_CALLS_ENABLED',
  );
  static const _deviceContactsEnabledOverride = String.fromEnvironment(
    'DEVICE_CONTACTS_ENABLED',
  );
  static const _paidUpgradeEnabledOverride = String.fromEnvironment(
    'PAID_UPGRADE_ENABLED',
  );
  static const _proProductIdsOverride = String.fromEnvironment(
    'IAP_PRO_PRODUCT_IDS',
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

  // Release rollout gates. Direct calls are part of v1 by default.
  static bool get directCallsEnabled =>
      _envFlag(_directCallsEnabledOverride, fallback: true);

  static bool get deviceContactsEnabled =>
      _envFlag(_deviceContactsEnabledOverride, fallback: false);

  static bool get paidUpgradeEnabled =>
      _envFlag(_paidUpgradeEnabledOverride, fallback: true);

  /// Local diagnostics and QA screens are for debug builds only.
  ///
  /// Keep this off for profile/release builds so normal users, app reviewers,
  /// and production web users cannot access internal diagnostics tools.
  static const bool localQaToolsEnabled = kDebugMode;

  static List<String> get proProductIds {
    final overrideIds = _proProductIdsOverride
        .split(',')
        .map((id) => id.trim())
        .where((id) => id.isNotEmpty)
        .toList(growable: false);
    if (overrideIds.isNotEmpty) return overrideIds;
    return const <String>[
      'talkflix_pro_monthly',
      'talkflix_pro_6_months',
      'talkflix_pro_yearly',
    ];
  }
}
