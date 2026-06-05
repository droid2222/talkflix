import 'dart:async';
import 'dart:io';

import 'package:firebase_core/firebase_core.dart';
import 'package:firebase_messaging/firebase_messaging.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/widgets.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../auth/session_controller.dart';
import '../config/app_config.dart';
import 'direct_call_backend_service.dart';
import 'dm_callkit_bridge.dart';

const _androidDirectCallAppBundle = 'cc.talkflix.app';

Future<void> initializeDirectCallAndroidPushRuntime() async {
  if (!AppConfig.directCallsEnabled) return;
  if (kIsWeb || !Platform.isAndroid) return;
  WidgetsFlutterBinding.ensureInitialized();
  if (Firebase.apps.isEmpty) {
    await Firebase.initializeApp();
  }
  FirebaseMessaging.onBackgroundMessage(
    directCallFirebaseMessagingBackgroundHandler,
  );
}

@pragma('vm:entry-point')
Future<void> directCallFirebaseMessagingBackgroundHandler(
  RemoteMessage message,
) async {
  if (!AppConfig.directCallsEnabled) return;
  if (kIsWeb || !Platform.isAndroid) return;
  WidgetsFlutterBinding.ensureInitialized();
  if (Firebase.apps.isEmpty) {
    await Firebase.initializeApp();
  }
  await DmCallKitBridge.handleRemotePushPayload(message.data);
}

final directCallPushServiceProvider = Provider<DirectCallPushService>((ref) {
  final service = DirectCallPushService(ref);
  ref.onDispose(service.dispose);
  unawaited(service.initialize());
  return service;
});

class DirectCallPushService {
  DirectCallPushService(this._ref);

  final Ref _ref;

  StreamSubscription<RemoteMessage>? _messageSubscription;
  StreamSubscription<String>? _tokenRefreshSubscription;
  bool _initialized = false;
  String _lastRegisteredToken = '';

  bool get _supported =>
      AppConfig.directCallsEnabled && !kIsWeb && Platform.isAndroid;

  Future<void> initialize() async {
    if (!_supported || _initialized) return;
    _initialized = true;
    if (Firebase.apps.isEmpty) {
      await Firebase.initializeApp();
    }
    _messageSubscription = FirebaseMessaging.onMessage.listen((message) {
      unawaited(DmCallKitBridge.handleRemotePushPayload(message.data));
    });
    _tokenRefreshSubscription = FirebaseMessaging.instance.onTokenRefresh
        .listen((token) {
          final trimmed = token.trim();
          if (trimmed.isEmpty) return;
          unawaited(_registerToken(trimmed));
        });

    final initialMessage = await FirebaseMessaging.instance.getInitialMessage();
    if (initialMessage != null) {
      await DmCallKitBridge.handleRemotePushPayload(initialMessage.data);
    }
  }

  Future<bool> syncDeviceRegistration() async {
    if (!_supported) return false;
    await initialize();
    final token = (await FirebaseMessaging.instance.getToken())?.trim() ?? '';
    if (token.isEmpty) return false;
    return _registerToken(token);
  }

  Future<bool> _registerToken(String token) async {
    if (!_supported || token.isEmpty) return false;
    final session = _ref.read(sessionControllerProvider);
    if (!session.isAuthenticated || session.user == null) {
      return false;
    }
    if (_lastRegisteredToken == token) return true;
    await _ref
        .read(directCallBackendServiceProvider)
        .registerDevice(
          platform: 'android',
          pushProvider: 'fcm',
          deviceToken: token,
          appBundle: _androidDirectCallAppBundle,
          enabled: true,
        );
    _lastRegisteredToken = token;
    return true;
  }

  void dispose() {
    _messageSubscription?.cancel();
    _tokenRefreshSubscription?.cancel();
    _messageSubscription = null;
    _tokenRefreshSubscription = null;
  }
}
