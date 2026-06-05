import 'dart:async';
import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:flutter_callkit_incoming/entities/android_params.dart';
import 'package:flutter_callkit_incoming/entities/call_event.dart';
import 'package:flutter_callkit_incoming/entities/call_kit_params.dart';
import 'package:flutter_callkit_incoming/entities/ios_params.dart';
import 'package:flutter_callkit_incoming/entities/notification_params.dart';
import 'package:flutter_callkit_incoming/flutter_callkit_incoming.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:uuid/uuid.dart';

import '../config/app_config.dart';
import 'direct_call_controller.dart';
import 'direct_call_registration_controller.dart';
import 'socket_service.dart';

final dmCallKitBridgeProvider = Provider<DmCallKitBridge>((ref) {
  final bridge = DmCallKitBridge(ref);
  ref.onDispose(bridge.dispose);
  return bridge;
});

/// Native call surface bridge for Talkflix direct-message calls.
///
/// - iOS: CallKit
/// - Android: flutter_callkit_incoming custom incoming screen + ongoing call notification
///
/// iOS still requires PushKit / VoIP push for suspended/terminated incoming calls.
///
class DmCallKitBridge {
  DmCallKitBridge(this._ref) {
    if (!enabled) return;
    _subscription = FlutterCallkitIncoming.onEvent.listen(_onCallKitEvent);
  }

  final Ref _ref;
  StreamSubscription<CallEvent?>? _subscription;

  /// CallKit UUID → tracked call session (cleanup / endCall / sync).
  final Map<String, _TrackedCallKitSession> _sessionByCallId = {};
  final Map<String, bool> _suppressedEndedCallIds = <String, bool>{};
  static const Duration _acceptedHandoffProtectionWindow = Duration(
    seconds: 15,
  );

  static bool get enabled =>
      AppConfig.directCallsEnabled &&
      !kIsWeb &&
      (Platform.isIOS || Platform.isAndroid);

  static final RegExp _uuidPattern = RegExp(
    r'^[0-9a-fA-F]{8}\-[0-9a-fA-F]{4}\-[0-9a-fA-F]{4}\-[0-9a-fA-F]{4}\-[0-9a-fA-F]{12}$',
  );

  static String _resolveNativeCallSurfaceId(String callId) {
    final trimmed = callId.trim();
    if (_uuidPattern.hasMatch(trimmed)) return trimmed.toLowerCase();
    return const Uuid().v4();
  }

  static bool _isTruthy(dynamic value) {
    if (value == true) return true;
    final normalized = '$value'.trim().toLowerCase();
    return normalized == '1' || normalized == 'true' || normalized == 'yes';
  }

  static Future<Set<String>> _activeNativeCallIds() async {
    try {
      final raw = await FlutterCallkitIncoming.activeCalls();
      if (raw is! List) return <String>{};
      return raw
          .map((entry) {
            if (entry is Map) {
              return '${entry['id'] ?? ''}'.trim().toLowerCase();
            }
            return '';
          })
          .where((id) => id.isNotEmpty)
          .toSet();
    } catch (_) {
      return <String>{};
    }
  }

  static Future<void> prepareAndroidIncomingCallPermissions() async {
    if (!enabled || !Platform.isAndroid) return;
    try {
      await FlutterCallkitIncoming.requestNotificationPermission({
        'title': 'Call notifications',
        'rationaleMessagePermission':
            'Talkflix needs notification permission to show incoming calls.',
        'postNotificationMessageRequired':
            'Enable notifications so Talkflix can show incoming calls.',
      });
    } catch (_) {}
    try {
      final canUseFullScreenIntent =
          await FlutterCallkitIncoming.canUseFullScreenIntent() == true;
      if (!canUseFullScreenIntent) {
        await FlutterCallkitIncoming.requestFullIntentPermission();
      }
    } catch (_) {}
  }

  static const AndroidParams _androidParams = AndroidParams(
    isCustomNotification: true,
    isCustomSmallExNotification: true,
    isShowLogo: false,
    isShowCallID: false,
    ringtonePath: 'system_ringtone_default',
    backgroundColor: '#C1121F',
    actionColor: '#FFFFFF',
    textColor: '#FFFFFF',
    incomingCallNotificationChannelName: 'Talkflix Calls',
    missedCallNotificationChannelName: 'Missed Talkflix Calls',
    isShowFullLockedScreen: true,
    isImportant: true,
  );

  static const NotificationParams _callingNotification = NotificationParams(
    showNotification: true,
    isShowCallback: true,
    subtitle: 'Calling…',
    callbackText: 'Hang Up',
  );

  static const NotificationParams _missedCallNotification = NotificationParams(
    showNotification: true,
    isShowCallback: true,
    subtitle: 'Missed call',
    callbackText: 'Call back',
  );

  static CallKitParams _buildIncomingCallParams({
    required String nativeId,
    required String callId,
    required String threadId,
    required String fromUserId,
    required bool video,
    required String callerName,
    String? avatarUrl,
  }) {
    return CallKitParams(
      id: nativeId,
      nameCaller: callerName.trim().isEmpty ? 'Talkflix' : callerName.trim(),
      appName: 'Talkflix',
      avatar: (avatarUrl ?? '').trim(),
      handle: 'Talkflix',
      type: video ? 1 : 0,
      duration: 45000,
      textAccept: 'Accept',
      textDecline: 'Decline',
      missedCallNotification: Platform.isAndroid
          ? _missedCallNotification
          : null,
      callingNotification: Platform.isAndroid ? _callingNotification : null,
      extra: <String, dynamic>{
        'callId': callId,
        'threadId': threadId,
        'fromUserId': fromUserId,
        'video': video,
      },
      android: Platform.isAndroid ? _androidParams : null,
      ios: IOSParams(
        iconName: 'CallKitLogo',
        handleType: 'generic',
        supportsVideo: video,
        maximumCallGroups: 1,
        maximumCallsPerCallGroup: 1,
        ringtonePath: 'system_ringtone_default',
        configureAudioSession: true,
        audioSessionMode: video ? 'videoChat' : 'voiceChat',
        audioSessionActive: true,
        audioSessionPreferredSampleRate: 48000,
        audioSessionPreferredIOBufferDuration: 0.005,
        supportsDTMF: false,
        supportsHolding: true,
        supportsGrouping: false,
        supportsUngrouping: false,
      ),
    );
  }

  static Future<void> handleRemotePushPayload(
    Map<String, dynamic> rawPayload,
  ) async {
    if (!enabled || !Platform.isAndroid) return;
    final payload = Map<String, dynamic>.from(rawPayload);
    final event = '${payload['event'] ?? ''}'.trim().toLowerCase();
    final callId = '${payload['callId'] ?? payload['id'] ?? ''}'.trim();
    if (callId.isEmpty) return;
    final nativeId = _resolveNativeCallSurfaceId(callId);
    if (event == 'cancel' || event == 'end') {
      try {
        await FlutterCallkitIncoming.endCall(nativeId);
      } catch (_) {}
      return;
    }
    if (event != 'incoming') return;
    final threadId = '${payload['threadId'] ?? ''}'.trim();
    final fromUserId = '${payload['fromUserId'] ?? ''}'.trim();
    if (threadId.isEmpty || fromUserId.isEmpty) return;
    final activeIds = await _activeNativeCallIds();
    if (activeIds.contains(nativeId)) return;
    final params = _buildIncomingCallParams(
      nativeId: nativeId,
      callId: callId,
      threadId: threadId,
      fromUserId: fromUserId,
      video: _isTruthy(payload['isVideo']) || _isTruthy(payload['video']),
      callerName: '${payload['nameCaller'] ?? ''}',
      avatarUrl: '${payload['avatar'] ?? ''}',
    );
    await FlutterCallkitIncoming.showCallkitIncoming(params);
  }

  void dispose() {
    _subscription?.cancel();
    _subscription = null;
  }

  MapEntry<String, _TrackedCallKitSession>? _findTrackedSession({
    String threadId = '',
    String callId = '',
  }) {
    final normalizedThreadId = threadId.trim();
    final normalizedCallId = callId.trim();
    for (final entry in _sessionByCallId.entries) {
      final session = entry.value;
      if (normalizedThreadId.isNotEmpty &&
          session.threadId == normalizedThreadId) {
        return entry;
      }
      if (normalizedCallId.isNotEmpty && session.callId == normalizedCallId) {
        return entry;
      }
    }
    return null;
  }

  void _suppressNativeEnd(String nativeId, {required bool removeSession}) {
    if (nativeId.trim().isEmpty) return;
    _suppressedEndedCallIds[nativeId] = removeSession;
  }

  void _markAcceptedHandoff(_TrackedCallKitSession session, {String? callId}) {
    if (callId != null && callId.trim().isNotEmpty) {
      session.callId = callId.trim();
    }
    session.acceptedHandoff = true;
    session.acceptedAt = DateTime.now();
  }

  bool _shouldIgnoreNativeAbort({
    required String threadId,
    required String callId,
    _TrackedCallKitSession? session,
  }) {
    final acceptedByController = _ref
        .read(directCallControllerProvider.notifier)
        .hasAcceptedHandoffFor(threadId: threadId, callId: callId);
    if (acceptedByController) return true;
    if (session == null || session.connected) return false;
    if (!session.acceptedHandoff) return false;
    final acceptedAt = session.acceptedAt;
    if (acceptedAt == null) return false;
    return DateTime.now().difference(acceptedAt) <=
        _acceptedHandoffProtectionWindow;
  }

  Future<void> onSessionReset() async {
    if (!enabled) return;
    for (final id in _sessionByCallId.keys) {
      _suppressNativeEnd(id, removeSession: true);
    }
    _sessionByCallId.clear();
    await FlutterCallkitIncoming.endAllCalls();
  }

  Future<void> endCallForThread(String threadId) async {
    if (!enabled || threadId.isEmpty) return;
    final entry = _sessionByCallId.entries
        .where((e) => e.value.threadId == threadId)
        .toList(growable: false);
    for (final e in entry) {
      _suppressNativeEnd(e.key, removeSession: true);
      try {
        await FlutterCallkitIncoming.endCall(e.key);
      } catch (_) {}
      _sessionByCallId.remove(e.key);
    }
  }

  Future<void> dismissIncomingUiForAcceptedCall({
    required String threadId,
    String callId = '',
  }) async {
    if (!enabled || threadId.trim().isEmpty) return;
    final entry = _findTrackedSession(threadId: threadId, callId: callId);
    if (entry == null) return;
    _markAcceptedHandoff(entry.value, callId: callId);
    _suppressNativeEnd(entry.key, removeSession: true);
    try {
      await FlutterCallkitIncoming.endCall(entry.key);
    } catch (_) {}
    _sessionByCallId.remove(entry.key);
  }

  void markAcceptedForThread({required String threadId, String callId = ''}) {
    if (!enabled || threadId.trim().isEmpty) return;
    final entry = _findTrackedSession(threadId: threadId, callId: callId);
    if (entry == null) return;
    _markAcceptedHandoff(entry.value, callId: callId);
  }

  /// Presents the native incoming-call UI. Ends any prior CallKit session first.
  Future<void> showIncomingDmCall({
    required String callId,
    required String threadId,
    required String fromUserId,
    required bool video,
    required String callerName,
    String? avatarUrl,
  }) async {
    if (!enabled) return;
    if (Platform.isAndroid) {
      await prepareAndroidIncomingCallPermissions();
    }
    final id = _resolveNativeCallSurfaceId(callId);
    final activeIds = await _activeNativeCallIds();
    if (activeIds.contains(id)) {
      _sessionByCallId[id] = _TrackedCallKitSession(
        callId: callId,
        threadId: threadId,
        partnerUserId: fromUserId,
        initiator: false,
      );
      return;
    }
    if (activeIds.isNotEmpty || _sessionByCallId.isNotEmpty) {
      await FlutterCallkitIncoming.endAllCalls();
      for (final id in _sessionByCallId.keys) {
        _suppressNativeEnd(id, removeSession: true);
      }
      _sessionByCallId.clear();
    }
    _sessionByCallId[id] = _TrackedCallKitSession(
      callId: callId,
      threadId: threadId,
      partnerUserId: fromUserId,
      initiator: false,
    );

    final params = _buildIncomingCallParams(
      nativeId: id,
      callId: callId,
      threadId: threadId,
      fromUserId: fromUserId,
      video: video,
      callerName: callerName,
      avatarUrl: avatarUrl,
    );
    await FlutterCallkitIncoming.showCallkitIncoming(params);
  }

  Future<void> startOutgoingDmCall({
    required String callId,
    required String threadId,
    required String toUserId,
    required bool video,
    required String calleeName,
    String? avatarUrl,
  }) async {
    if (!enabled || threadId.isEmpty || toUserId.isEmpty) return;
    if (Platform.isAndroid) {
      await prepareAndroidIncomingCallPermissions();
    }
    final id = _resolveNativeCallSurfaceId(callId);
    final existing = _sessionByCallId.entries
        .where((entry) => entry.value.threadId == threadId)
        .toList(growable: false);
    for (final entry in existing) {
      _suppressNativeEnd(entry.key, removeSession: true);
      try {
        await FlutterCallkitIncoming.endCall(entry.key);
      } catch (_) {}
      _sessionByCallId.remove(entry.key);
    }
    _sessionByCallId[id] = _TrackedCallKitSession(
      callId: callId,
      threadId: threadId,
      partnerUserId: toUserId,
      initiator: true,
    );

    final params = CallKitParams(
      id: id,
      nameCaller: calleeName.trim().isEmpty ? 'Talkflix' : calleeName.trim(),
      appName: 'Talkflix',
      avatar: (avatarUrl ?? '').trim(),
      handle: 'Talkflix',
      type: video ? 1 : 0,
      duration: 45000,
      textAccept: 'Accept',
      textDecline: 'Decline',
      missedCallNotification: Platform.isAndroid
          ? _missedCallNotification
          : null,
      callingNotification: Platform.isAndroid ? _callingNotification : null,
      extra: <String, dynamic>{
        'callId': callId,
        'threadId': threadId,
        'fromUserId': toUserId,
        'video': video,
      },
      android: Platform.isAndroid ? _androidParams : null,
      ios: IOSParams(
        iconName: 'CallKitLogo',
        handleType: 'generic',
        supportsVideo: video,
        maximumCallGroups: 1,
        maximumCallsPerCallGroup: 1,
        ringtonePath: 'system_ringtone_default',
        configureAudioSession: true,
        audioSessionMode: video ? 'videoChat' : 'voiceChat',
        audioSessionActive: true,
        audioSessionPreferredSampleRate: 48000,
        audioSessionPreferredIOBufferDuration: 0.005,
        supportsDTMF: false,
        supportsHolding: true,
        supportsGrouping: false,
        supportsUngrouping: false,
      ),
    );
    await FlutterCallkitIncoming.startCall(params);
  }

  Future<void> markConnectedForThread(String threadId) async {
    if (!enabled || threadId.isEmpty) return;
    for (final e in _sessionByCallId.entries) {
      if (e.value.threadId != threadId) continue;
      try {
        await FlutterCallkitIncoming.setCallConnected(e.key);
      } catch (_) {}
      e.value.connected = true;
      break;
    }
  }

  void _onCallKitEvent(CallEvent? event) {
    if (event == null) return;
    final raw = event.body;
    if (raw is! Map) return;
    final body = Map<String, dynamic>.from(raw);
    final id = body['id']?.toString();
    if (id == null || id.isEmpty) return;

    switch (event.event) {
      case Event.actionCallAccept:
        _handleAccept(id, body);
        break;
      case Event.actionCallDecline:
      case Event.actionCallTimeout:
        _handleDeclineOrTimeout(id, body);
        break;
      case Event.actionCallEnded:
        _handleEnded(id, body);
        break;
      case Event.actionDidUpdateDevicePushTokenVoip:
        final token = body['deviceTokenVoIP']?.toString().trim() ?? '';
        unawaited(
          _ref
              .read(directCallRegistrationControllerProvider.notifier)
              .handleNativeVoipTokenChanged(token),
        );
        break;
      default:
        break;
    }
  }

  Map<String, dynamic> _readExtra(Map<String, dynamic> body) {
    final extra = body['extra'];
    if (extra is Map) {
      return Map<String, dynamic>.from(extra);
    }
    return <String, dynamic>{};
  }

  void _handleAccept(String id, Map<String, dynamic> body) {
    final extra = _readExtra(body);
    final callId = extra['callId']?.toString() ?? '';
    final threadFromExtra = extra['threadId']?.toString() ?? '';
    final threadId = threadFromExtra.isNotEmpty
        ? threadFromExtra
        : (_sessionByCallId[id]?.threadId ?? '');
    final fromUserId = extra['fromUserId']?.toString() ?? '';
    if (threadId.isEmpty || fromUserId.isEmpty) return;

    final video = _isTruthy(extra['video']);
    final session = _sessionByCallId.putIfAbsent(
      id,
      () => _TrackedCallKitSession(
        callId: callId,
        threadId: threadId,
        partnerUserId: fromUserId,
        initiator: false,
      ),
    );
    _markAcceptedHandoff(session, callId: callId);
    _ref
        .read(directCallControllerProvider.notifier)
        .stageCalleeAcceptedFromCallKit(
          threadId: threadId,
          partnerId: fromUserId,
          callId: callId,
          video: video,
        );
  }

  void _handleDeclineOrTimeout(String id, Map<String, dynamic> body) {
    final extra = _readExtra(body);
    final session = _sessionByCallId[id];
    final callId = extra['callId']?.toString() ?? (session?.callId ?? '');
    final threadFromExtra = extra['threadId']?.toString() ?? '';
    final threadId = threadFromExtra.isNotEmpty
        ? threadFromExtra
        : (session?.threadId ?? '');
    if (threadId.isEmpty) return;
    if (_shouldIgnoreNativeAbort(
      threadId: threadId,
      callId: callId,
      session: session,
    )) {
      return;
    }

    final socket = _ref.read(socketServiceProvider);
    unawaited(
      socket.emitWithAckFuture('dm:call:accept', <String, dynamic>{
        'threadId': threadId,
        'callId': callId,
        'accept': false,
      }, timeout: const Duration(seconds: 4)),
    );
    final controller = _ref.read(directCallControllerProvider.notifier);
    controller.clearCallForThread(threadId);
    _sessionByCallId.remove(id);
    _suppressNativeEnd(id, removeSession: true);
    unawaited(FlutterCallkitIncoming.endCall(id));
  }

  void _handleEnded(String id, Map<String, dynamic> body) {
    final removeSession = _suppressedEndedCallIds.remove(id);
    if (removeSession != null) {
      if (removeSession) {
        _sessionByCallId.remove(id);
      }
      return;
    }
    final extra = _readExtra(body);
    final callId =
        extra['callId']?.toString() ?? (_sessionByCallId[id]?.callId ?? '');
    final session = _sessionByCallId[id];
    final threadFromExtra = extra['threadId']?.toString() ?? '';
    final threadId = threadFromExtra.isNotEmpty
        ? threadFromExtra
        : (session?.threadId ?? '');
    if (threadId.isEmpty) {
      _sessionByCallId.remove(id);
      return;
    }
    if (_shouldIgnoreNativeAbort(
      threadId: threadId,
      callId: callId,
      session: session,
    )) {
      return;
    }

    final socket = _ref.read(socketServiceProvider);
    if (session?.connected == true) {
      unawaited(
        socket.emitWithAckFuture('dm:call:end', <String, dynamic>{
          'threadId': threadId,
          'callId': callId,
        }, timeout: const Duration(seconds: 4)),
      );
    } else {
      unawaited(
        socket.emitWithAckFuture('dm:call:cancel', <String, dynamic>{
          'threadId': threadId,
          'callId': callId,
        }, timeout: const Duration(seconds: 4)),
      );
    }

    final controller = _ref.read(directCallControllerProvider.notifier);
    controller.clearCallForThread(threadId);
    _sessionByCallId.remove(id);
  }
}

class _TrackedCallKitSession {
  _TrackedCallKitSession({
    required this.callId,
    required this.threadId,
    required this.partnerUserId,
    required this.initiator,
  });

  String callId;
  final String threadId;
  final String partnerUserId;
  final bool initiator;
  bool connected = false;
  bool acceptedHandoff = false;
  DateTime? acceptedAt;
}
