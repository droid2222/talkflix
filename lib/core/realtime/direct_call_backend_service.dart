import 'dart:io' show Platform;

import 'package:flutter/foundation.dart' show kIsWeb;
import 'package:flutter_callkit_incoming/flutter_callkit_incoming.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../network/api_client.dart';

const kIosDirectCallAppBundle = 'cc.talkflix.app';

final directCallBackendServiceProvider = Provider<DirectCallBackendService>((
  ref,
) {
  return DirectCallBackendService(ref.read(apiClientProvider));
});

class DirectCallBackendService {
  const DirectCallBackendService(this._apiClient);

  final ApiClient _apiClient;

  Future<DirectCallRtcConfig?> fetchRtcConfig() async {
    final response = await _apiClient.getJson('/me/direct-call/rtc-config');
    final rawConfig = response['rtcConfig'];
    if (rawConfig is! Map) return null;
    return DirectCallRtcConfig(
      config: Map<String, dynamic>.from(rawConfig),
      hasRelay: response['hasRelay'] == true,
    );
  }

  Future<DirectCallServerReadiness?> fetchReadiness() async {
    final response = await _apiClient.getJson('/me/direct-call/readiness');
    final rawSummary = response['deviceSummary'];
    return DirectCallServerReadiness(
      relayRequired: response['relayRequired'] != false,
      hasRelay: response['hasRelay'] == true,
      deviceSummary: rawSummary is Map
          ? DirectCallDeviceSummary.fromJson(
              Map<String, dynamic>.from(rawSummary),
            )
          : const DirectCallDeviceSummary(),
    );
  }

  Future<DirectCallSessionSnapshot?> fetchCurrentSession(
    String threadId,
  ) async {
    if (threadId.trim().isEmpty) return null;
    final response = await _apiClient.getJson(
      '/me/direct-call/sessions/current',
      queryParameters: <String, String>{'threadId': threadId},
    );
    final rawSession = response['session'];
    if (rawSession is! Map) return null;
    return DirectCallSessionSnapshot.fromJson(
      Map<String, dynamic>.from(rawSession),
    );
  }

  Future<void> registerDevice({
    required String platform,
    required String pushProvider,
    required String deviceToken,
    String appBundle = '',
    String deviceLabel = '',
    bool enabled = true,
  }) async {
    await _apiClient.postJson(
      '/me/direct-call/devices',
      body: <String, dynamic>{
        'platform': platform,
        'pushProvider': pushProvider,
        'deviceToken': deviceToken,
        'appBundle': appBundle,
        'deviceLabel': deviceLabel,
        'enabled': enabled,
      },
    );
  }

  Future<List<DirectCallRegisteredDevice>> fetchDevices() async {
    final response = await _apiClient.getJson('/me/direct-call/devices');
    final rawDevices = response['devices'];
    if (rawDevices is! List) return const <DirectCallRegisteredDevice>[];
    return rawDevices
        .whereType<Map>()
        .map(
          (raw) => DirectCallRegisteredDevice.fromJson(
            Map<String, dynamic>.from(raw),
          ),
        )
        .toList(growable: false);
  }

  Future<bool> registerNativeVoipDeviceIfAvailable() async {
    if (kIsWeb || !Platform.isIOS) return false;
    final rawToken = await FlutterCallkitIncoming.getDevicePushTokenVoIP();
    final token = '${rawToken ?? ''}'.trim();
    if (token.isEmpty) return false;
    await registerDevice(
      platform: 'ios',
      pushProvider: 'voip_apns',
      deviceToken: token,
      appBundle: kIosDirectCallAppBundle,
      enabled: true,
    );
    return true;
  }
}

class DirectCallRtcConfig {
  const DirectCallRtcConfig({required this.config, required this.hasRelay});

  final Map<String, dynamic> config;
  final bool hasRelay;
}

class DirectCallServerReadiness {
  const DirectCallServerReadiness({
    required this.relayRequired,
    required this.hasRelay,
    required this.deviceSummary,
  });

  final bool relayRequired;
  final bool hasRelay;
  final DirectCallDeviceSummary deviceSummary;
}

class DirectCallDeviceSummary {
  const DirectCallDeviceSummary({
    this.deviceCount = 0,
    this.enabledDeviceCount = 0,
    this.backgroundCallableDeviceCount = 0,
    this.healthyBackgroundCallableDeviceCount = 0,
    this.failingDeviceCount = 0,
    this.latestSeenAt,
    this.latestVerifiedAt,
    this.latestPushSuccessAt,
    this.latestPushFailureAt,
  });

  factory DirectCallDeviceSummary.fromJson(Map<String, dynamic> json) {
    return DirectCallDeviceSummary(
      deviceCount: (json['deviceCount'] as num?)?.toInt() ?? 0,
      enabledDeviceCount: (json['enabledDeviceCount'] as num?)?.toInt() ?? 0,
      backgroundCallableDeviceCount:
          (json['backgroundCallableDeviceCount'] as num?)?.toInt() ?? 0,
      healthyBackgroundCallableDeviceCount:
          (json['healthyBackgroundCallableDeviceCount'] as num?)?.toInt() ?? 0,
      failingDeviceCount: (json['failingDeviceCount'] as num?)?.toInt() ?? 0,
      latestSeenAt: json['latestSeenAt']?.toString(),
      latestVerifiedAt: json['latestVerifiedAt']?.toString(),
      latestPushSuccessAt: json['latestPushSuccessAt']?.toString(),
      latestPushFailureAt: json['latestPushFailureAt']?.toString(),
    );
  }

  final int deviceCount;
  final int enabledDeviceCount;
  final int backgroundCallableDeviceCount;
  final int healthyBackgroundCallableDeviceCount;
  final int failingDeviceCount;
  final String? latestSeenAt;
  final String? latestVerifiedAt;
  final String? latestPushSuccessAt;
  final String? latestPushFailureAt;
}

class DirectCallSessionSnapshot {
  const DirectCallSessionSnapshot({
    required this.callId,
    required this.threadId,
    required this.callerId,
    required this.calleeId,
    required this.wantsVideo,
    required this.state,
    required this.sessionVersion,
  });

  factory DirectCallSessionSnapshot.fromJson(Map<String, dynamic> json) {
    return DirectCallSessionSnapshot(
      callId: '${json['callId'] ?? ''}'.trim(),
      threadId: '${json['threadId'] ?? ''}'.trim(),
      callerId: '${json['callerId'] ?? ''}'.trim(),
      calleeId: '${json['calleeId'] ?? ''}'.trim(),
      wantsVideo: json['wantsVideo'] == true,
      state: '${json['state'] ?? ''}'.trim(),
      sessionVersion: (json['sessionVersion'] as num?)?.toInt() ?? 1,
    );
  }

  final String callId;
  final String threadId;
  final String callerId;
  final String calleeId;
  final bool wantsVideo;
  final String state;
  final int sessionVersion;
}

class DirectCallRegisteredDevice {
  const DirectCallRegisteredDevice({
    required this.id,
    required this.platform,
    required this.pushProvider,
    required this.appBundle,
    required this.deviceLabel,
    required this.enabled,
    required this.supportsBackgroundIncoming,
    required this.healthyForBackgroundIncoming,
    required this.consecutiveFailures,
    required this.tokenSuffix,
    this.lastSeenAt,
    this.lastVerifiedAt,
    this.lastPushSuccessAt,
    this.lastPushFailureAt,
    this.lastPushError,
    this.createdAt,
    this.updatedAt,
  });

  factory DirectCallRegisteredDevice.fromJson(Map<String, dynamic> json) {
    return DirectCallRegisteredDevice(
      id: '${json['id'] ?? ''}'.trim(),
      platform: '${json['platform'] ?? ''}'.trim(),
      pushProvider: '${json['pushProvider'] ?? ''}'.trim(),
      appBundle: '${json['appBundle'] ?? ''}'.trim(),
      deviceLabel: '${json['deviceLabel'] ?? ''}'.trim(),
      enabled: json['enabled'] == true,
      supportsBackgroundIncoming: json['supportsBackgroundIncoming'] == true,
      healthyForBackgroundIncoming:
          json['healthyForBackgroundIncoming'] == true,
      consecutiveFailures: (json['consecutiveFailures'] as num?)?.toInt() ?? 0,
      tokenSuffix: '${json['tokenSuffix'] ?? ''}'.trim(),
      lastSeenAt: json['lastSeenAt']?.toString(),
      lastVerifiedAt: json['lastVerifiedAt']?.toString(),
      lastPushSuccessAt: json['lastPushSuccessAt']?.toString(),
      lastPushFailureAt: json['lastPushFailureAt']?.toString(),
      lastPushError: json['lastPushError']?.toString(),
      createdAt: json['createdAt']?.toString(),
      updatedAt: json['updatedAt']?.toString(),
    );
  }

  final String id;
  final String platform;
  final String pushProvider;
  final String appBundle;
  final String deviceLabel;
  final bool enabled;
  final bool supportsBackgroundIncoming;
  final bool healthyForBackgroundIncoming;
  final int consecutiveFailures;
  final String tokenSuffix;
  final String? lastSeenAt;
  final String? lastVerifiedAt;
  final String? lastPushSuccessAt;
  final String? lastPushFailureAt;
  final String? lastPushError;
  final String? createdAt;
  final String? updatedAt;
}
