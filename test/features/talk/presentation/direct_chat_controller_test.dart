import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:talkflix_flutter/core/config/privacy_settings_controller.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:talkflix_flutter/core/network/api_client.dart';
import 'package:talkflix_flutter/core/realtime/socket_service.dart';
import 'package:talkflix_flutter/features/talk/presentation/direct_chat_controller.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  setUp(() {
    SharedPreferences.setMockInitialValues(<String, Object>{});
  });

  test(
    're-watches partner presence when the socket connects after the chat loads',
    () async {
      final socket = _FakeSocketService();
      final apiClient = _DirectChatApiClient();
      final container = ProviderContainer(
        overrides: [
          socketServiceProvider.overrideWith((ref) => socket),
          apiClientProvider.overrideWith((ref) => apiClient),
        ],
      );
      addTearDown(container.dispose);

      final subscription = container.listen<DirectChatState>(
        directChatControllerProvider('42'),
        (previous, next) {},
        fireImmediately: true,
      );
      addTearDown(subscription.close);

      await _settle();

      expect(
        container.read(directChatControllerProvider('42')).threadId,
        '1__42',
      );
      expect(
        container.read(directChatControllerProvider('42')).partnerOnline,
        isFalse,
      );
      expect(socket.presenceWatchCount, 0);

      socket.nextPresenceAck = <String, dynamic>{'online': true};
      socket.setConnectionStatus('connected', connected: true);
      await _settle();

      final state = container.read(directChatControllerProvider('42'));
      expect(state.joinedSocketRoom, isTrue);
      expect(state.partnerOnline, isTrue);
      expect(socket.presenceWatchCount, 1);
      expect(
        socket.emittedEvents,
        contains(
          predicate<_RecordedSocketEmit>(
            (emit) =>
                emit.event == 'dm:join' && emit.payload['threadId'] == '1__42',
          ),
        ),
      );
    },
  );

  test(
    'turning off show online status clears presence and unwatches partner status',
    () async {
      final socket = _FakeSocketService()
        ..nextPresenceAck = <String, dynamic>{'online': true}
        ..setConnectionStatus('connected', connected: true);
      final apiClient = _DirectChatApiClient();
      final container = ProviderContainer(
        overrides: [
          socketServiceProvider.overrideWith((ref) => socket),
          apiClientProvider.overrideWith((ref) => apiClient),
        ],
      );
      addTearDown(container.dispose);

      final subscription = container.listen<DirectChatState>(
        directChatControllerProvider('42'),
        (previous, next) {},
        fireImmediately: true,
      );
      addTearDown(subscription.close);

      await _settle();
      expect(
        container.read(directChatControllerProvider('42')).partnerOnline,
        isTrue,
      );

      await container
          .read(privacySettingsControllerProvider.notifier)
          .setShowOnlineStatus(false);
      await _settle();

      final state = container.read(directChatControllerProvider('42'));
      expect(state.partnerOnline, isFalse);
      expect(
        socket.emittedEvents,
        contains(
          predicate<_RecordedSocketEmit>(
            (emit) =>
                emit.event == 'presence:unwatch' &&
                emit.payload['userId'] == '42',
          ),
        ),
      );
    },
  );
}

Future<void> _settle() async {
  await Future<void>.delayed(const Duration(milliseconds: 50));
}

class _FakeSocketService extends SocketService {
  String _status = 'disconnected';
  bool _connected = false;
  int presenceWatchCount = 0;
  dynamic nextPresenceAck;
  final List<_RecordedSocketEmit> emittedEvents = <_RecordedSocketEmit>[];
  final Map<String, List<void Function(dynamic data)>> _handlers =
      <String, List<void Function(dynamic data)>>{};

  @override
  String get status => _status;

  @override
  bool get isConnected => _connected;

  void setConnectionStatus(String status, {required bool connected}) {
    _status = status;
    _connected = connected;
    notifyListeners();
  }

  @override
  void emit(String event, dynamic data, {void Function(dynamic ack)? ack}) {
    emittedEvents.add(
      _RecordedSocketEmit(
        event: event,
        payload: Map<String, dynamic>.from(data as Map),
      ),
    );
    ack?.call(null);
  }

  @override
  Future<dynamic> emitWithAckRetry(
    String event,
    dynamic data, {
    Duration timeout = const Duration(seconds: 5),
    int maxAttempts = 2,
    Duration retryDelay = const Duration(milliseconds: 450),
    bool shouldRetry = true,
  }) async {
    emittedEvents.add(
      _RecordedSocketEmit(
        event: event,
        payload: Map<String, dynamic>.from(data as Map),
      ),
    );
    if (event == 'presence:watch') {
      presenceWatchCount += 1;
      return nextPresenceAck;
    }
    return null;
  }

  @override
  void on(String event, void Function(dynamic data) handler) {
    _handlers.putIfAbsent(event, () => <void Function(dynamic)>[]).add(handler);
  }

  @override
  void off(String event, [void Function(dynamic data)? handler]) {
    final handlers = _handlers[event];
    if (handlers == null) return;
    if (handler == null) {
      _handlers.remove(event);
      return;
    }
    handlers.removeWhere((candidate) => candidate == handler);
    if (handlers.isEmpty) {
      _handlers.remove(event);
    }
  }
}

class _RecordedSocketEmit {
  const _RecordedSocketEmit({required this.event, required this.payload});

  final String event;
  final Map<String, dynamic> payload;
}

class _DirectChatApiClient extends ApiClient {
  _DirectChatApiClient() : super(baseUrl: 'http://localhost:4000', token: 't');

  @override
  Future<Map<String, dynamic>> getJson(
    String path, {
    Map<String, String>? queryParameters,
    Duration? timeout,
    int? retries,
  }) async {
    if (path == '/users/42/messages') {
      return <String, dynamic>{
        'threadId': '1__42',
        'messages': const <Map<String, dynamic>>[],
      };
    }
    throw StateError('Unexpected GET $path');
  }

  @override
  Future<Map<String, dynamic>> patchJson(
    String path, {
    Map<String, dynamic>? body,
    Duration? timeout,
    int? retries,
  }) async {
    if (path == '/users/42/messages/read') {
      return <String, dynamic>{'messageIds': const <String>[]};
    }
    throw StateError('Unexpected PATCH $path');
  }
}
