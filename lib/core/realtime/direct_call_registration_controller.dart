import 'dart:async';
import 'dart:io';

import 'package:firebase_core/firebase_core.dart';
import 'package:firebase_messaging/firebase_messaging.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter_callkit_incoming/flutter_callkit_incoming.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../auth/session_controller.dart';
import '../config/app_config.dart';
import 'direct_call_backend_service.dart';
import 'direct_call_push_service.dart';

final directCallRegistrationControllerProvider =
    StateNotifierProvider<
      DirectCallRegistrationController,
      DirectCallRegistrationState
    >((ref) {
      return DirectCallRegistrationController(ref);
    });

class DirectCallRegistrationController
    extends StateNotifier<DirectCallRegistrationState> {
  DirectCallRegistrationController(this._ref)
    : super(
        DirectCallRegistrationState(
          supported:
              AppConfig.directCallsEnabled &&
              !kIsWeb &&
              (Platform.isIOS || Platform.isAndroid),
          platform: kIsWeb
              ? 'web'
              : Platform.isIOS
              ? 'ios'
              : Platform.isAndroid
              ? 'android'
              : Platform.operatingSystem,
          expectedPushProvider: kIsWeb
              ? ''
              : Platform.isIOS
              ? 'voip_apns'
              : Platform.isAndroid
              ? 'fcm'
              : '',
        ),
      );

  final Ref _ref;
  Future<void>? _syncInFlight;
  DateTime? _lastSyncStartedAt;

  bool get _supported => state.supported;

  Future<void> sync({bool force = false}) async {
    if (!_supported) return;
    if (!force &&
        _syncInFlight != null &&
        _lastSyncStartedAt != null &&
        DateTime.now().difference(_lastSyncStartedAt!) <
            const Duration(seconds: 6)) {
      return _syncInFlight!;
    }
    _lastSyncStartedAt = DateTime.now();
    final future = _performSync();
    _syncInFlight = future;
    try {
      await future;
    } finally {
      if (identical(_syncInFlight, future)) {
        _syncInFlight = null;
      }
    }
  }

  Future<void> handleNativeVoipTokenChanged(String token) async {
    final normalizedToken = token.trim();
    state = state.copyWith(
      localToken: normalizedToken,
      lastCheckedAt: DateTime.now(),
      clearError: true,
    );
    if (normalizedToken.isEmpty || !_supported || !Platform.isIOS) {
      return;
    }
    final session = _ref.read(sessionControllerProvider);
    if (!session.isAuthenticated || session.user == null) {
      return;
    }
    await _registerIosVoipToken(normalizedToken);
    await _refreshDevices();
  }

  Future<void> _performSync() async {
    final session = _ref.read(sessionControllerProvider);
    final localToken = await _readLocalToken();
    state = state.copyWith(
      syncing: true,
      localToken: localToken,
      lastCheckedAt: DateTime.now(),
      clearError: true,
    );
    try {
      if (session.isAuthenticated && session.user != null) {
        if (Platform.isIOS) {
          if (localToken.isNotEmpty) {
            await _registerIosVoipToken(localToken);
          }
        } else if (Platform.isAndroid) {
          await _ref
              .read(directCallPushServiceProvider)
              .syncDeviceRegistration();
        }
      }
      await _refreshDevices();
    } catch (error) {
      state = state.copyWith(
        syncing: false,
        lastError: '$error',
        lastCheckedAt: DateTime.now(),
      );
    }
  }

  Future<void> _registerIosVoipToken(String token) {
    return _ref
        .read(directCallBackendServiceProvider)
        .registerDevice(
          platform: 'ios',
          pushProvider: 'voip_apns',
          deviceToken: token,
          appBundle: kIosDirectCallAppBundle,
          enabled: true,
        );
  }

  Future<String> _readLocalToken() async {
    if (!_supported) return '';
    if (Platform.isIOS) {
      final rawToken = await FlutterCallkitIncoming.getDevicePushTokenVoIP();
      return '${rawToken ?? ''}'.trim();
    }
    if (Platform.isAndroid) {
      if (Firebase.apps.isEmpty) {
        await Firebase.initializeApp();
      }
      return (await FirebaseMessaging.instance.getToken())?.trim() ?? '';
    }
    return '';
  }

  Future<void> _refreshDevices() async {
    final devices = await _ref
        .read(directCallBackendServiceProvider)
        .fetchDevices();
    final currentDevice = _matchCurrentDevice(
      devices: devices,
      localToken: state.localToken,
      platform: state.platform,
      pushProvider: state.expectedPushProvider,
    );
    state = state.copyWith(
      syncing: false,
      devices: devices,
      currentDevice: currentDevice,
      clearCurrentDevice: currentDevice == null,
      lastCheckedAt: DateTime.now(),
      clearError: true,
    );
  }

  DirectCallRegisteredDevice? _matchCurrentDevice({
    required List<DirectCallRegisteredDevice> devices,
    required String localToken,
    required String platform,
    required String pushProvider,
  }) {
    for (final device in devices) {
      if (device.platform != platform || device.pushProvider != pushProvider) {
        continue;
      }
      if (localToken.isNotEmpty &&
          device.tokenSuffix.isNotEmpty &&
          localToken.endsWith(device.tokenSuffix)) {
        return device;
      }
    }
    final matches = devices
        .where(
          (device) =>
              device.platform == platform &&
              device.pushProvider == pushProvider,
        )
        .toList(growable: false);
    if (matches.length == 1) return matches.first;
    return null;
  }
}

class DirectCallRegistrationState {
  const DirectCallRegistrationState({
    required this.supported,
    required this.platform,
    required this.expectedPushProvider,
    this.syncing = false,
    this.localToken = '',
    this.devices = const <DirectCallRegisteredDevice>[],
    this.currentDevice,
    this.lastCheckedAt,
    this.lastError,
  });

  final bool supported;
  final String platform;
  final String expectedPushProvider;
  final bool syncing;
  final String localToken;
  final List<DirectCallRegisteredDevice> devices;
  final DirectCallRegisteredDevice? currentDevice;
  final DateTime? lastCheckedAt;
  final String? lastError;

  bool get localTokenAvailable => localToken.isNotEmpty;
  String get localTokenPreview {
    if (localToken.isEmpty) return 'Missing';
    final suffix = localToken.length <= 12
        ? localToken
        : localToken.substring(localToken.length - 12);
    return '…$suffix';
  }

  bool get registeredForCurrentToken => currentDevice != null;

  bool get backgroundCallable =>
      currentDevice?.enabled == true &&
      currentDevice?.healthyForBackgroundIncoming == true;

  int get enabledDeviceCount =>
      devices.where((device) => device.enabled).length;

  DirectCallRegistrationState copyWith({
    bool? syncing,
    String? localToken,
    List<DirectCallRegisteredDevice>? devices,
    DirectCallRegisteredDevice? currentDevice,
    bool clearCurrentDevice = false,
    DateTime? lastCheckedAt,
    String? lastError,
    bool clearError = false,
  }) {
    return DirectCallRegistrationState(
      supported: supported,
      platform: platform,
      expectedPushProvider: expectedPushProvider,
      syncing: syncing ?? this.syncing,
      localToken: localToken ?? this.localToken,
      devices: devices ?? this.devices,
      currentDevice: clearCurrentDevice
          ? null
          : (currentDevice ?? this.currentDevice),
      lastCheckedAt: lastCheckedAt ?? this.lastCheckedAt,
      lastError: clearError ? null : (lastError ?? this.lastError),
    );
  }
}
