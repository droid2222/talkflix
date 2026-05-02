import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:socket_io_client/socket_io_client.dart' as io;

import '../config/app_config.dart';

final socketServiceProvider = ChangeNotifierProvider<SocketService>((ref) {
  return SocketService();
});

class SocketService extends ChangeNotifier {
  io.Socket? _socket;
  String? _token;
  String? _expectedUserId;
  String? _expectedSessionId;
  String? _authenticatedUserId;
  String? _authenticatedSessionId;
  String? _lastIdentityError;
  String _status = 'disconnected';
  int _connectionGeneration = 0;
  Completer<bool>? _identityReadyCompleter;

  String get status => _status;
  bool get isConnected =>
      _socket?.connected == true &&
      _status == 'connected' &&
      hasVerifiedIdentity;
  bool get hasVerifiedIdentity =>
      (_authenticatedUserId?.isNotEmpty ?? false) &&
      (_authenticatedSessionId?.isNotEmpty ?? false);
  String? get authenticatedUserId => _authenticatedUserId;
  String? get authenticatedSessionId => _authenticatedSessionId;
  String? get lastIdentityError => _lastIdentityError;

  void connect(
    String token, {
    required String expectedUserId,
    required String expectedSessionId,
  }) {
    if (_socket != null &&
        _token == token &&
        _expectedUserId == expectedUserId &&
        _expectedSessionId == expectedSessionId &&
        (_status == 'connecting' ||
            _status == 'authenticating' ||
            isVerifiedFor(
              userId: expectedUserId,
              sessionId: expectedSessionId,
            ))) {
      return;
    }

    _disposeSocket();

    _token = token;
    _expectedUserId = expectedUserId;
    _expectedSessionId = expectedSessionId;
    _authenticatedUserId = null;
    _authenticatedSessionId = null;
    _lastIdentityError = null;
    _identityReadyCompleter = Completer<bool>();
    final generation = ++_connectionGeneration;

    _socket = io.io(AppConfig.apiBaseUrl, <String, dynamic>{
      'path': '/socket.io',
      'transports': ['websocket', 'polling'],
      'autoConnect': false,
      'forceNew': true,
      'multiplex': false,
      'reconnection': true,
      'reconnectionAttempts': 8,
      'reconnectionDelay': 1000,
      'reconnectionDelayMax': 8000,
      'randomizationFactor': 0.25,
      'timeout': 8000,
      'auth': <String, dynamic>{'token': token},
    });

    _socket!
      ..onConnect((_) {
        if (!_isCurrentGeneration(generation)) return;
        _status = 'authenticating';
        notifyListeners();
      })
      ..on('auth:ready', (dynamic payload) {
        if (!_isCurrentGeneration(generation)) return;
        final data = payload is Map
            ? Map<String, dynamic>.from(payload)
            : const <String, dynamic>{};
        final actualUserId = '${data['userId'] ?? ''}'.trim();
        final actualSessionId = '${data['sessionId'] ?? ''}'.trim();
        final expectedUserId = _expectedUserId ?? '';
        final expectedSessionId = _expectedSessionId ?? '';
        final identityMatches =
            actualUserId.isNotEmpty &&
            actualSessionId.isNotEmpty &&
            actualUserId == expectedUserId &&
            actualSessionId == expectedSessionId;
        if (!identityMatches) {
          _lastIdentityError =
              'Realtime session mismatch. Please reconnect and try again.';
          _status = 'error';
          _completeIdentityReady(false);
          notifyListeners();
          _disposeSocket();
          return;
        }
        _authenticatedUserId = actualUserId;
        _authenticatedSessionId = actualSessionId;
        _lastIdentityError = null;
        _status = 'connected';
        _completeIdentityReady(true);
        notifyListeners();
      })
      ..onDisconnect((_) {
        if (!_isCurrentGeneration(generation)) return;
        _authenticatedUserId = null;
        _authenticatedSessionId = null;
        _status = 'disconnected';
        _completeIdentityReady(false);
        notifyListeners();
      })
      ..onConnectError((dynamic _) {
        if (!_isCurrentGeneration(generation)) return;
        _authenticatedUserId = null;
        _authenticatedSessionId = null;
        _status = 'error';
        _completeIdentityReady(false);
        notifyListeners();
      })
      ..onReconnectAttempt((dynamic _) {
        if (!_isCurrentGeneration(generation)) return;
        _authenticatedUserId = null;
        _authenticatedSessionId = null;
        _status = 'connecting';
        notifyListeners();
      })
      ..onReconnect((dynamic _) {
        if (!_isCurrentGeneration(generation)) return;
        _authenticatedUserId = null;
        _authenticatedSessionId = null;
        _status = 'authenticating';
        notifyListeners();
      })
      ..onReconnectFailed((dynamic _) {
        if (!_isCurrentGeneration(generation)) return;
        _authenticatedUserId = null;
        _authenticatedSessionId = null;
        _status = 'error';
        _completeIdentityReady(false);
        notifyListeners();
      })
      ..onReconnectError((dynamic _) {
        if (!_isCurrentGeneration(generation)) return;
        _authenticatedUserId = null;
        _authenticatedSessionId = null;
        _status = 'error';
        _completeIdentityReady(false);
        notifyListeners();
      })
      ..connect();

    _status = 'connecting';
    notifyListeners();
  }

  Future<bool> ensureSessionIdentity({
    required String token,
    required String expectedUserId,
    required String expectedSessionId,
    Duration timeout = const Duration(seconds: 8),
  }) async {
    connect(
      token,
      expectedUserId: expectedUserId,
      expectedSessionId: expectedSessionId,
    );
    if (isVerifiedFor(
      userId: expectedUserId,
      sessionId: expectedSessionId,
    )) {
      return true;
    }
    final completer = _identityReadyCompleter;
    if (completer == null) return false;
    try {
      return await completer.future.timeout(timeout, onTimeout: () => false);
    } catch (_) {
      return false;
    }
  }

  bool isVerifiedFor({
    required String userId,
    required String sessionId,
  }) {
    if (!isConnected) return false;
    return _authenticatedUserId == userId &&
        _authenticatedSessionId == sessionId;
  }

  void disconnect() {
    _disposeSocket();
    _token = null;
    _expectedUserId = null;
    _expectedSessionId = null;
    _authenticatedUserId = null;
    _authenticatedSessionId = null;
    _lastIdentityError = null;
    _status = 'disconnected';
    _completeIdentityReady(false);
    notifyListeners();
  }

  void emit(String event, dynamic data, {void Function(dynamic ack)? ack}) {
    _socket?.emitWithAck(event, data, ack: ack);
  }

  Future<dynamic> emitWithAckFuture(
    String event,
    dynamic data, {
    Duration timeout = const Duration(seconds: 5),
  }) async {
    if (!isConnected) return null;
    final completer = Completer<dynamic>();
    emit(
      event,
      data,
      ack: (dynamic payload) {
        if (!completer.isCompleted) completer.complete(payload);
      },
    );
    return completer.future.timeout(
      timeout,
      onTimeout: () => null,
    );
  }

  Future<dynamic> emitWithAckRetry(
    String event,
    dynamic data, {
    Duration timeout = const Duration(seconds: 5),
    int maxAttempts = 2,
    Duration retryDelay = const Duration(milliseconds: 450),
    bool shouldRetry = true,
  }) async {
    final attempts = maxAttempts < 1 ? 1 : maxAttempts;
    for (var attempt = 1; attempt <= attempts; attempt++) {
      final payload = await emitWithAckFuture(event, data, timeout: timeout);
      if (payload != null) return payload;
      if (!shouldRetry || attempt >= attempts || !isConnected) break;
      await Future<void>.delayed(retryDelay);
    }
    return null;
  }

  /// Emits [event] immediately, then emits the same payload again after
  /// [resendDelay] if still connected. Only use when the server treats
  /// duplicates safely (for example idempotent `call:end` / `call:cancel`).
  void emitRedundant(
    String event,
    dynamic data, {
    Duration resendDelay = const Duration(milliseconds: 400),
  }) {
    emit(event, data);
    Future<void>.delayed(resendDelay, () {
      if (isConnected) {
        emit(event, data);
      }
    });
  }

  void on(String event, void Function(dynamic data) handler) {
    _socket?.on(event, handler);
  }

  void off(String event, [void Function(dynamic data)? handler]) {
    _socket?.off(event, handler);
  }

  bool _isCurrentGeneration(int generation) =>
      generation == _connectionGeneration;

  void _disposeSocket() {
    _connectionGeneration += 1;
    _socket?.dispose();
    _socket = null;
  }

  void _completeIdentityReady(bool value) {
    final completer = _identityReadyCompleter;
    if (completer != null && !completer.isCompleted) {
      completer.complete(value);
    }
  }
}
