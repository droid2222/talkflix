import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:talkflix_flutter/core/network/api_client.dart';
import 'package:talkflix_flutter/features/talk/data/direct_chat_repository.dart';

void main() {
  group('DirectChatThread.fromPayload', () {
    test('parses replies, block flags, and capabilities', () {
      final thread = DirectChatThread.fromPayload({
        'threadId': '1__2',
        'blocked': true,
        'youBlockedUser': true,
        'blockedByUser': false,
        'supportsTranslation': false,
        'supportsCorrection': false,
        'messages': [
          {
            'id': '42',
            'threadId': '1__2',
            'fromUserId': '1',
            'toUserId': '2',
            'type': 'text',
            'text': 'Replying',
            'replyToMessageId': '41',
            'createdAt': 1736898600000,
          },
        ],
      });

      expect(thread.threadId, '1__2');
      expect(thread.blocked, isTrue);
      expect(thread.youBlockedUser, isTrue);
      expect(thread.blockedByUser, isFalse);
      expect(thread.supportsTranslation, isFalse);
      expect(thread.supportsCorrection, isFalse);
      expect(thread.messages, hasLength(1));
      expect(thread.messages.first.replyToMessageId, '41');
    });

    test(
      'treats directional block flags as blocked even without blocked bool',
      () {
        final thread = DirectChatThread.fromPayload({
          'threadId': '2__3',
          'blockedByUser': true,
          'messages': const [],
        });

        expect(thread.blocked, isTrue);
        expect(thread.youBlockedUser, isFalse);
        expect(thread.blockedByUser, isTrue);
      },
    );
  });

  group('DirectChatRepository draft assist', () {
    test('translateDraft posts the draft translation payload', () async {
      final apiClient = _RecordingApiClient(
        response: {
          'translation': 'Hola',
          'targetLanguage': 'Spanish',
          'note': 'translated',
        },
      );
      final container = ProviderContainer(
        overrides: [apiClientProvider.overrideWith((ref) => apiClient)],
      );
      addTearDown(container.dispose);

      final repository = container.read(directChatRepositoryProvider);
      final result = await repository.translateDraft(
        userId: '42',
        text: 'Hello',
        targetLanguage: 'Spanish',
      );

      expect(apiClient.lastPostPath, '/users/42/messages/draft/translate');
      expect(apiClient.lastPostBody, {
        'text': 'Hello',
        'targetLanguage': 'Spanish',
      });
      expect(result.output, 'Hola');
      expect(result.targetLanguage, 'Spanish');
      expect(result.note, 'translated');
    });

    test('correctDraft posts the draft correction payload', () async {
      final apiClient = _RecordingApiClient(
        response: {
          'correction': 'This is corrected.',
          'explanation': 'grammar fixed',
        },
      );
      final container = ProviderContainer(
        overrides: [apiClientProvider.overrideWith((ref) => apiClient)],
      );
      addTearDown(container.dispose);

      final repository = container.read(directChatRepositoryProvider);
      final result = await repository.correctDraft(
        userId: '42',
        text: 'this is corrected',
        tone: 'friendly',
      );

      expect(apiClient.lastPostPath, '/users/42/messages/draft/correct');
      expect(apiClient.lastPostBody, {
        'text': 'this is corrected',
        'tone': 'friendly',
      });
      expect(result.output, 'This is corrected.');
      expect(result.note, 'grammar fixed');
    });

    test('paraphraseDraft posts the draft paraphrase payload', () async {
      final apiClient = _RecordingApiClient(
        response: {
          'paraphrase': 'Could you review this when you have a moment?',
          'note': 'rewritten',
        },
      );
      final container = ProviderContainer(
        overrides: [apiClientProvider.overrideWith((ref) => apiClient)],
      );
      addTearDown(container.dispose);

      final repository = container.read(directChatRepositoryProvider);
      final result = await repository.paraphraseDraft(
        userId: '42',
        text: 'review this asap',
      );

      expect(apiClient.lastPostPath, '/users/42/messages/draft/paraphrase');
      expect(apiClient.lastPostBody, {'text': 'review this asap'});
      expect(result.output, 'Could you review this when you have a moment?');
      expect(result.note, 'rewritten');
    });
  });

  test(
    'fetchDirectChatCallPreferences requests the chat permission endpoint',
    () async {
      final apiClient = _RecordingApiClient(
        response: {'receiveVoiceCalls': false, 'receiveVideoCalls': true},
      );
      final container = ProviderContainer(
        overrides: [apiClientProvider.overrideWith((ref) => apiClient)],
      );
      addTearDown(container.dispose);

      final repository = container.read(directChatRepositoryProvider);
      final permissions = await repository.fetchDirectChatCallPreferences('42');

      expect(apiClient.lastGetPath, '/users/42/direct-call-permissions');
      expect(permissions.receiveVoiceCalls, isFalse);
      expect(permissions.receiveVideoCalls, isTrue);
    },
  );

  test(
    'updateDirectChatCallPreferences patches the chat permission endpoint',
    () async {
      final apiClient = _RecordingApiClient(
        response: {'receiveVoiceCalls': true, 'receiveVideoCalls': false},
      );
      final container = ProviderContainer(
        overrides: [apiClientProvider.overrideWith((ref) => apiClient)],
      );
      addTearDown(container.dispose);

      final repository = container.read(directChatRepositoryProvider);
      final permissions = await repository.updateDirectChatCallPreferences(
        userId: '42',
        receiveVoiceCalls: true,
      );

      expect(apiClient.lastPatchPath, '/users/42/direct-call-permissions');
      expect(apiClient.lastPatchBody, {'receiveVoiceCalls': true});
      expect(permissions.receiveVoiceCalls, isTrue);
      expect(permissions.receiveVideoCalls, isFalse);
    },
  );

  test('fetchCallLogs requests the thread call log endpoint', () async {
    final apiClient = _RecordingApiClient(
      response: {
        'logs': [
          {
            'callId': 'call-1',
            'threadId': '1__42',
            'partnerId': '42',
            'direction': 'incoming',
            'mode': 'voice',
            'outcome': 'answered',
            'requestedAt': '2026-05-15T18:20:00.000Z',
            'durationSeconds': 90,
          },
        ],
        'nextCursor': '1715797200000:8',
      },
    );
    final container = ProviderContainer(
      overrides: [apiClientProvider.overrideWith((ref) => apiClient)],
    );
    addTearDown(container.dispose);

    final repository = container.read(directChatRepositoryProvider);
    final page = await repository.fetchCallLogs(
      userId: '42',
      cursor: '1715797200000:4',
      limit: 25,
    );

    expect(apiClient.lastGetPath, '/users/42/call-logs');
    expect(apiClient.lastGetQueryParameters, {
      'limit': '25',
      'cursor': '1715797200000:4',
    });
    expect(page.entries, hasLength(1));
    expect(page.entries.single.callId, 'call-1');
    expect(page.nextCursor, '1715797200000:8');
  });

  test('fetchAllCallLogs requests the combined call log endpoint', () async {
    final apiClient = _RecordingApiClient(
      response: {
        'logs': [
          {
            'callId': 'call-9',
            'threadId': '1__88',
            'partnerId': '88',
            'partnerDisplayName': 'Noah',
            'partnerUsername': 'noah',
            'partnerPhotoUrl': '/uploads/noah.png',
            'direction': 'outgoing',
            'mode': 'video',
            'outcome': 'answered',
            'requestedAt': '2026-05-16T08:00:00.000Z',
            'durationSeconds': 144,
          },
        ],
        'nextCursor': '',
      },
    );
    final container = ProviderContainer(
      overrides: [apiClientProvider.overrideWith((ref) => apiClient)],
    );
    addTearDown(container.dispose);

    final repository = container.read(directChatRepositoryProvider);
    final page = await repository.fetchAllCallLogs(limit: 30);

    expect(apiClient.lastGetPath, '/me/call-logs');
    expect(apiClient.lastGetQueryParameters, {'limit': '30'});
    expect(page.entries, hasLength(1));
    expect(page.entries.single.partnerDisplayName, 'Noah');
  });

  test('deleteCallLog requests the user call log deletion endpoint', () async {
    final apiClient = _RecordingApiClient(response: {'ok': true});
    final container = ProviderContainer(
      overrides: [apiClientProvider.overrideWith((ref) => apiClient)],
    );
    addTearDown(container.dispose);

    final repository = container.read(directChatRepositoryProvider);
    await repository.deleteCallLog('call-9');

    expect(apiClient.lastDeletePath, '/me/call-logs/call-9');
  });

  test('clearCallLogs requests the user call log clear endpoint', () async {
    final apiClient = _RecordingApiClient(response: {'ok': true});
    final container = ProviderContainer(
      overrides: [apiClientProvider.overrideWith((ref) => apiClient)],
    );
    addTearDown(container.dispose);

    final repository = container.read(directChatRepositoryProvider);
    await repository.clearCallLogs();

    expect(apiClient.lastDeletePath, '/me/call-logs');
  });

  group('DirectChatRepository call history cache', () {
    setUp(() {
      SharedPreferences.setMockInitialValues(<String, Object>{});
    });

    test('creates a cached call event when the chat is closed', () async {
      final container = ProviderContainer();
      addTearDown(container.dispose);

      final repository = container.read(directChatRepositoryProvider);
      await repository.appendCachedLocalCallEvent(
        userId: '42',
        threadId: '1__42',
        callId: 'call-1',
        eventKey: 'incoming',
        text: 'Incoming voice call',
        createdAt: DateTime.parse('2026-05-08T19:30:00Z'),
      );

      final cached = await repository.readCachedThread('42');
      expect(cached, isNotNull);
      expect(cached!.threadId, '1__42');
      expect(cached.messages, hasLength(1));
      expect(cached.messages.single.isCallEvent, isTrue);
      expect(cached.messages.single.text, 'Incoming voice call');
      expect(cached.messages.single.id, 'local-call-event-call-1-incoming');
    });

    test('dedupes repeated cached call events for the same call', () async {
      final container = ProviderContainer();
      addTearDown(container.dispose);

      final repository = container.read(directChatRepositoryProvider);
      await repository.appendCachedLocalCallEvent(
        userId: '42',
        threadId: '1__42',
        callId: 'call-2',
        eventKey: 'missed',
        text: 'Missed call.',
      );
      await repository.appendCachedLocalCallEvent(
        userId: '42',
        threadId: '1__42',
        callId: 'call-2',
        eventKey: 'missed',
        text: 'Missed call.',
      );

      final cached = await repository.readCachedThread('42');
      expect(cached, isNotNull);
      expect(cached!.messages, hasLength(1));
      expect(cached.messages.single.id, 'local-call-event-call-2-missed');
    });
  });
}

class _RecordingApiClient extends ApiClient {
  _RecordingApiClient({required Map<String, dynamic> response})
    : _response = response,
      super(baseUrl: 'http://localhost:4000', token: 'token');

  final Map<String, dynamic> _response;
  String? lastGetPath;
  Map<String, String>? lastGetQueryParameters;
  String? lastPostPath;
  Map<String, dynamic>? lastPostBody;
  String? lastPatchPath;
  Map<String, dynamic>? lastPatchBody;
  String? lastDeletePath;

  @override
  Future<Map<String, dynamic>> getJson(
    String path, {
    Map<String, String>? queryParameters,
    Duration? timeout,
    int? retries,
  }) async {
    lastGetPath = path;
    lastGetQueryParameters = queryParameters;
    return _response;
  }

  @override
  Future<Map<String, dynamic>> postJson(
    String path, {
    Map<String, dynamic>? body,
    Duration? timeout,
    int? retries,
  }) async {
    lastPostPath = path;
    lastPostBody = body;
    return _response;
  }

  @override
  Future<Map<String, dynamic>> patchJson(
    String path, {
    Map<String, dynamic>? body,
    Duration? timeout,
    int? retries,
  }) async {
    lastPatchPath = path;
    lastPatchBody = body;
    return _response;
  }

  @override
  Future<Map<String, dynamic>> deleteJson(
    String path, {
    Map<String, dynamic>? body,
    Duration? timeout,
    int? retries,
  }) async {
    lastDeletePath = path;
    return _response;
  }
}
