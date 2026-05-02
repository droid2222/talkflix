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
  String _status = 'disconnected';

  String get status => _status;
  bool get isConnected => _socket?.connected == true;

  void connect(String token) {
    if (_socket != null &&
        _token == token &&
        (_socket!.connected || _status == 'connecting')) {
      return;
    }

    _token = token;

    _socket?.dispose();
    _socket = io.io(AppConfig.apiBaseUrl, <String, dynamic>{
      'path': '/socket.io',
      'transports': ['websocket', 'polling'],
      'autoConnect': false,
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
        _status = 'connected';
        notifyListeners();
      })
      ..onDisconnect((_) {
        _status = 'disconnected';
        notifyListeners();
      })
      ..onConnectError((dynamic _) {
        _status = 'error';
        notifyListeners();
      })
      ..onReconnectAttempt((dynamic _) {
        _status = 'connecting';
        notifyListeners();
      })
      ..onReconnect((dynamic _) {
        _status = 'connected';
        notifyListeners();
      })
      ..onReconnectFailed((dynamic _) {
        _status = 'error';
        notifyListeners();
      })
      ..onReconnectError((dynamic _) {
        _status = 'error';
        notifyListeners();
      })
      ..connect();

    _status = 'connecting';
    notifyListeners();
  }

  void disconnect() {
    _socket?.dispose();
    _socket = null;
    _token = null;
    _status = 'disconnected';
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
}
