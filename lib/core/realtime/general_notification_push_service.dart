import 'dart:async';
import 'dart:io';

import 'package:firebase_core/firebase_core.dart';
import 'package:firebase_messaging/firebase_messaging.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../auth/session_controller.dart';
import '../network/api_client.dart';

const _talkflixAppBundle = 'cc.talkflix.app';

final generalNotificationPushServiceProvider =
    Provider<GeneralNotificationPushService>((ref) {
      final service = GeneralNotificationPushService(ref);
      ref.onDispose(service.dispose);
      return service;
    });

class GeneralNotificationPushService {
  GeneralNotificationPushService(this._ref);

  static const _iosNotificationChannel = MethodChannel(
    'cc.talkflix.app/notifications',
  );

  final Ref _ref;

  StreamSubscription<String>? _tokenRefreshSubscription;
  bool _initializing = false;
  bool _initialized = false;
  String _lastRegisteredToken = '';

  bool get _supported => !kIsWeb && (Platform.isIOS || Platform.isAndroid);

  Future<void> syncDeviceRegistration({bool force = false}) async {
    if (!_supported || _initializing) return;
    final session = _ref.read(sessionControllerProvider);
    if (!session.isAuthenticated || session.user == null) return;
    _initializing = true;
    try {
      final token = Platform.isIOS
          ? await _readIosApnsToken()
          : await _readAndroidFcmToken();
      if (token.isEmpty) {
        return;
      }
      await _registerToken(token, force: force);
      _initialized = true;
    } catch (_) {
      // Device push registration must not block app startup.
    } finally {
      _initializing = false;
    }
  }

  Future<String> _readIosApnsToken() async {
    var token =
        (await _iosNotificationChannel.invokeMethod<String>(
          'requestApnsToken',
        ))?.trim() ??
        '';
    if (token.isNotEmpty) {
      return token;
    }
    await Future<void>.delayed(const Duration(milliseconds: 650));
    token =
        (await _iosNotificationChannel.invokeMethod<String>(
          'getApnsToken',
        ))?.trim() ??
        '';
    return token;
  }

  Future<String> _readAndroidFcmToken() async {
    if (Firebase.apps.isEmpty) {
      await Firebase.initializeApp();
    }
    final messaging = FirebaseMessaging.instance;
    await messaging.requestPermission(alert: true, badge: true, sound: true);
    _tokenRefreshSubscription ??= messaging.onTokenRefresh.listen((token) {
      final trimmed = token.trim();
      if (trimmed.isEmpty) return;
      unawaited(_registerToken(trimmed, force: true));
    });
    return (await messaging.getToken())?.trim() ?? '';
  }

  Future<void> _registerToken(String token, {bool force = false}) async {
    if (!_supported || token.isEmpty) return;
    if (!force && token == _lastRegisteredToken && _initialized) return;
    final session = _ref.read(sessionControllerProvider);
    if (!session.isAuthenticated || session.user == null) return;
    try {
      await _ref
          .read(apiClientProvider)
          .postJson(
            '/me/notification-devices',
            body: <String, dynamic>{
              'platform': Platform.isIOS ? 'ios' : 'android',
              'pushProvider': Platform.isIOS ? 'apns' : 'fcm',
              'deviceToken': token,
              'appBundle': _talkflixAppBundle,
              'enabled': true,
            },
          );
      _lastRegisteredToken = token;
    } catch (_) {
      // The API endpoint may not exist yet in older server deployments.
    }
  }

  void dispose() {
    _tokenRefreshSubscription?.cancel();
    _tokenRefreshSubscription = null;
  }
}
