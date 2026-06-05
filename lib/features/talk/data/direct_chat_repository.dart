import 'dart:typed_data';
import 'dart:convert';

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:http_parser/http_parser.dart';

import '../../../core/auth/session_controller.dart';
import '../../../core/config/privacy_settings_controller.dart';
import '../../../core/config/storage_keys.dart';
import '../../../core/network/api_exception.dart';
import '../../../core/network/api_client.dart';
import 'chat_message.dart';
import 'direct_call_log_entry.dart';

final directChatRepositoryProvider = Provider<DirectChatRepository>((ref) {
  return DirectChatRepository(ref);
});

class DirectChatRepository {
  const DirectChatRepository(this._ref);

  final Ref _ref;
  static const int _cacheMessageLimit = 180;
  static const int _cacheSchemaVersion = 2;
  static const Duration _cacheTtl = Duration(hours: 24);

  Future<DirectChatThread> fetchMessages(String userId) async {
    final data = await _ref
        .read(apiClientProvider)
        .getJson('/users/$userId/messages');
    return DirectChatThread.fromPayload(data);
  }

  Future<List<String>> markThreadRead(String userId) async {
    final data = await _ref
        .read(apiClientProvider)
        .patchJson('/users/$userId/messages/read');
    return (data['messageIds'] as List<dynamic>? ?? const [])
        .map((value) => value.toString())
        .where((value) => value.isNotEmpty)
        .toList();
  }

  Future<DirectCallLogPage> fetchCallLogs({
    required String userId,
    String? cursor,
    int limit = 40,
  }) async {
    final data = await _ref
        .read(apiClientProvider)
        .getJson(
          '/users/$userId/call-logs',
          queryParameters: <String, String>{
            'limit': '${limit.clamp(1, 50)}',
            if ((cursor ?? '').trim().isNotEmpty) 'cursor': cursor!.trim(),
          },
        );
    return DirectCallLogPage.fromJson(data);
  }

  Future<DirectCallLogPage> fetchAllCallLogs({
    String? cursor,
    int limit = 40,
  }) async {
    final data = await _ref
        .read(apiClientProvider)
        .getJson(
          '/me/call-logs',
          queryParameters: <String, String>{
            'limit': '${limit.clamp(1, 50)}',
            if ((cursor ?? '').trim().isNotEmpty) 'cursor': cursor!.trim(),
          },
        );
    return DirectCallLogPage.fromJson(data);
  }

  Future<void> deleteCallLog(String callId) async {
    final normalizedCallId = callId.trim();
    if (normalizedCallId.isEmpty) return;
    await _ref
        .read(apiClientProvider)
        .deleteJson('/me/call-logs/$normalizedCallId');
  }

  Future<void> clearCallLogs() async {
    await _ref.read(apiClientProvider).deleteJson('/me/call-logs');
  }

  Future<DirectChatCallPreferences> fetchDirectChatCallPreferences(
    String userId,
  ) async {
    final data = await _ref
        .read(apiClientProvider)
        .getJson('/users/$userId/direct-call-permissions');
    return _directChatCallPreferencesFromJson(data);
  }

  Future<DirectChatCallPreferences> updateDirectChatCallPreferences({
    required String userId,
    bool? receiveVoiceCalls,
    bool? receiveVideoCalls,
  }) async {
    final body = <String, dynamic>{};
    if (receiveVoiceCalls != null) {
      body['receiveVoiceCalls'] = receiveVoiceCalls;
    }
    if (receiveVideoCalls != null) {
      body['receiveVideoCalls'] = receiveVideoCalls;
    }
    final data = await _ref
        .read(apiClientProvider)
        .patchJson('/users/$userId/direct-call-permissions', body: body);
    return _directChatCallPreferencesFromJson(data);
  }

  Future<DirectChatThread?> readCachedThread(String userId) async {
    final prefs = await _ref.read(sharedPreferencesProvider.future);
    final cacheKey = '${StorageKeys.directChatCachePrefix}$userId';
    final raw = prefs.getString(cacheKey);
    if (raw == null || raw.trim().isEmpty) return null;
    try {
      final data = jsonDecode(raw);
      if (data is! Map<String, dynamic>) {
        await prefs.remove(cacheKey);
        return null;
      }
      final version = (data['version'] as num?)?.toInt() ?? 0;
      if (version != _cacheSchemaVersion) {
        await prefs.remove(cacheKey);
        return null;
      }
      final updatedAtRaw = data['updatedAt']?.toString() ?? '';
      final updatedAt = DateTime.tryParse(updatedAtRaw);
      if (updatedAt == null ||
          DateTime.now().difference(updatedAt) > _cacheTtl) {
        await prefs.remove(cacheKey);
        return null;
      }
      final messages =
          (data['messages'] as List<dynamic>? ?? const [])
              .whereType<Map<String, dynamic>>()
              .map(ChatMessage.fromJson)
              .toList()
            ..sort((a, b) => a.createdAt.compareTo(b.createdAt));
      return DirectChatThread.fromCachePayload(data, messages);
    } catch (_) {
      await prefs.remove(cacheKey);
      return null;
    }
  }

  Future<void> writeCachedThread({
    required String userId,
    required String threadId,
    required List<ChatMessage> messages,
    required bool blocked,
    required bool youBlockedUser,
    required bool blockedByUser,
    required bool supportsTranslation,
    required bool supportsCorrection,
  }) async {
    final prefs = await _ref.read(sharedPreferencesProvider.future);
    final trimmed = messages.length > _cacheMessageLimit
        ? messages.sublist(messages.length - _cacheMessageLimit)
        : messages;
    final payload = <String, dynamic>{
      'version': _cacheSchemaVersion,
      'threadId': threadId,
      'blocked': blocked,
      'youBlockedUser': youBlockedUser,
      'blockedByUser': blockedByUser,
      'supportsTranslation': supportsTranslation,
      'supportsCorrection': supportsCorrection,
      'messages': trimmed.map((message) => message.toJson()).toList(),
      'updatedAt': DateTime.now().toIso8601String(),
    };
    await prefs.setString(
      '${StorageKeys.directChatCachePrefix}$userId',
      jsonEncode(payload),
    );
  }

  Future<void> appendCachedLocalCallEvent({
    required String userId,
    required String threadId,
    required String callId,
    required String eventKey,
    required String text,
    DateTime? createdAt,
  }) async {
    final cached = await readCachedThread(userId);
    final normalizedThreadId = threadId.trim();
    final effectiveThreadId = normalizedThreadId.isNotEmpty
        ? normalizedThreadId
        : cached?.threadId ?? '';
    if (effectiveThreadId.isEmpty) {
      return;
    }

    final eventMessage = ChatMessage.localCallEvent(
      threadId: effectiveThreadId,
      callId: callId,
      eventKey: eventKey,
      text: text,
      createdAt: createdAt,
    );
    final nextMessages = [...?cached?.messages];
    final alreadyExists = nextMessages.any(
      (message) =>
          message.id == eventMessage.id ||
          message.clientMessageId == eventMessage.clientMessageId,
    );
    if (alreadyExists) {
      return;
    }

    nextMessages.add(eventMessage);
    nextMessages.sort((a, b) => a.createdAt.compareTo(b.createdAt));
    await writeCachedThread(
      userId: userId,
      threadId: effectiveThreadId,
      messages: nextMessages,
      blocked: cached?.blocked ?? false,
      youBlockedUser: cached?.youBlockedUser ?? false,
      blockedByUser: cached?.blockedByUser ?? false,
      supportsTranslation: cached?.supportsTranslation ?? false,
      supportsCorrection: cached?.supportsCorrection ?? false,
    );
  }

  Future<ChatMessage> sendTextMessage({
    required String userId,
    required String text,
    String? clientMessageId,
    String? replyToMessageId,
  }) async {
    final data = await _ref
        .read(apiClientProvider)
        .postJson(
          '/users/$userId/messages',
          body: <String, dynamic>{
            'type': 'text',
            'text': text.trim(),
            if (clientMessageId != null && clientMessageId.isNotEmpty)
              'clientMessageId': clientMessageId,
            if (replyToMessageId != null && replyToMessageId.isNotEmpty)
              'replyToMessageId': replyToMessageId,
          },
        );

    return ChatMessage.fromJson(
      data['message'] as Map<String, dynamic>? ?? const <String, dynamic>{},
    );
  }

  Future<ChatMessage> sendImageMessage({
    required String userId,
    required String mimeType,
    required Uint8List bytes,
    String? clientMessageId,
    String? replyToMessageId,
  }) async {
    return sendFileMessage(
      userId: userId,
      bytes: bytes,
      fileName: 'photo_${DateTime.now().millisecondsSinceEpoch}.jpg',
      mimeType: mimeType,
      clientMessageId: clientMessageId,
      replyToMessageId: replyToMessageId,
    );
  }

  Future<ChatMessage> sendAudioMessage({
    required String userId,
    required String mimeType,
    required Uint8List bytes,
    required int durationSeconds,
    String? clientMessageId,
    String? replyToMessageId,
  }) async {
    return sendFileMessage(
      userId: userId,
      bytes: bytes,
      fileName: 'voice_${DateTime.now().millisecondsSinceEpoch}.m4a',
      mimeType: mimeType,
      durationSeconds: durationSeconds,
      clientMessageId: clientMessageId,
      replyToMessageId: replyToMessageId,
    );
  }

  Future<ChatMessage> sendFileMessage({
    required String userId,
    required Uint8List bytes,
    required String fileName,
    required String mimeType,
    int? durationSeconds,
    String? clientMessageId,
    String? replyToMessageId,
  }) async {
    final data = await _ref
        .read(apiClientProvider)
        .postMultipart(
          '/users/$userId/messages/file',
          fileField: 'file',
          bytes: bytes,
          filename: fileName.trim().isEmpty ? 'attachment' : fileName.trim(),
          contentType: _mediaTypeFromMime(mimeType),
          fields: <String, String>{
            'mimeType': mimeType,
            if (durationSeconds != null && durationSeconds > 0)
              'audioDuration': '$durationSeconds',
            if (clientMessageId != null && clientMessageId.isNotEmpty)
              'clientMessageId': clientMessageId,
            if (replyToMessageId != null && replyToMessageId.isNotEmpty)
              'replyToMessageId': replyToMessageId,
          },
          timeout: const Duration(seconds: 60),
          retries: 0,
        );
    return ChatMessage.fromJson(
      data['message'] as Map<String, dynamic>? ?? const <String, dynamic>{},
    );
  }

  Future<int> forwardMessage({
    required String messageId,
    required List<String> recipientIds,
  }) async {
    final normalizedMessageId = messageId.trim();
    final normalizedRecipients = recipientIds
        .map((value) => value.trim())
        .where((value) => value.isNotEmpty)
        .toSet()
        .toList(growable: false);
    if (normalizedMessageId.isEmpty || normalizedRecipients.isEmpty) {
      return 0;
    }
    final data = await _ref
        .read(apiClientProvider)
        .postJson(
          '/me/messages/forward',
          body: <String, dynamic>{
            'messageId': normalizedMessageId,
            'recipientIds': normalizedRecipients,
          },
        );
    return (data['forwardedCount'] as num?)?.toInt() ?? 0;
  }

  /// Deletes a message for everyone (server-side). Only valid for own messages.
  Future<void> deleteMessageForEveryone({
    required String userId,
    required String messageId,
  }) async {
    await _ref
        .read(apiClientProvider)
        .deleteJson(
          '/users/$userId/messages/$messageId',
          body: <String, dynamic>{'scope': 'everyone'},
        );
  }

  Future<void> deleteMessageForMe({
    required String userId,
    required String messageId,
  }) async {
    await _ref
        .read(apiClientProvider)
        .deleteJson(
          '/users/$userId/messages/$messageId',
          body: <String, dynamic>{'scope': 'me'},
        );
  }

  Future<ChatMessage> editMessage({
    required String userId,
    required String messageId,
    required String text,
  }) async {
    final data = await _ref
        .read(apiClientProvider)
        .patchJson(
          '/users/$userId/messages/$messageId',
          body: <String, dynamic>{'text': text.trim()},
        );
    return ChatMessage.fromJson(
      data['message'] as Map<String, dynamic>? ?? const <String, dynamic>{},
    );
  }

  Future<Map<String, int>> setReaction({
    required String userId,
    required String messageId,
    required String emoji,
  }) async {
    final data = await _ref
        .read(apiClientProvider)
        .postJson(
          '/users/$userId/messages/$messageId/reaction',
          body: <String, dynamic>{'emoji': emoji},
        );
    return _parseReactionMap(data['reactions']);
  }

  Future<Map<String, int>> clearReaction({
    required String userId,
    required String messageId,
  }) async {
    final data = await _ref
        .read(apiClientProvider)
        .deleteJson('/users/$userId/messages/$messageId/reaction');
    return _parseReactionMap(data['reactions']);
  }

  Future<List<ChatMessage>> searchMessages({
    required String userId,
    required String query,
  }) async {
    final data = await _ref
        .read(apiClientProvider)
        .getJson(
          '/users/$userId/messages/search',
          queryParameters: <String, String>{'q': query.trim()},
        );
    return (data['messages'] as List<dynamic>? ?? const [])
        .whereType<Map<String, dynamic>>()
        .map(ChatMessage.fromJson)
        .toList();
  }

  Future<List<ChatMessage>> fetchSharedMessages({
    required String userId,
    String type = 'files',
  }) async {
    final data = await _ref
        .read(apiClientProvider)
        .getJson(
          '/users/$userId/messages/shared',
          queryParameters: <String, String>{'type': type},
        );
    return (data['messages'] as List<dynamic>? ?? const [])
        .whereType<Map<String, dynamic>>()
        .map(ChatMessage.fromJson)
        .toList();
  }

  Future<void> blockUser(String userId) async {
    await _ref.read(apiClientProvider).postJson('/users/$userId/block');
  }

  Future<void> unblockUser(String userId) async {
    await _ref.read(apiClientProvider).deleteJson('/users/$userId/block');
  }

  Future<void> reportUser({
    required String userId,
    required String reason,
  }) async {
    await _ref
        .read(apiClientProvider)
        .postJson(
          '/users/$userId/report',
          body: <String, dynamic>{'reason': reason},
        );
  }

  Future<void> reportMessage({
    required String userId,
    required String messageId,
    required String reason,
  }) async {
    await _ref
        .read(apiClientProvider)
        .postJson(
          '/users/$userId/messages/$messageId/report',
          body: <String, dynamic>{'reason': reason},
        );
  }

  Future<ChatLearningResult> translateMessage({
    required String userId,
    required String messageId,
    required String text,
    required String targetLanguage,
  }) async {
    try {
      final data = await _ref
          .read(apiClientProvider)
          .postJson(
            '/users/$userId/messages/$messageId/translate',
            body: <String, dynamic>{
              'text': text,
              'targetLanguage': targetLanguage,
            },
          );
      return ChatLearningResult(
        output: data['translation']?.toString().trim() ?? '',
        note: data['note']?.toString().trim() ?? '',
        targetLanguage:
            data['targetLanguage']?.toString().trim() ?? targetLanguage.trim(),
      );
    } on ApiException catch (error) {
      if (error.isNotFound || error.isForbidden) {
        return const ChatLearningResult(
          output: '',
          note: 'Translation API is not available yet for this account.',
        );
      }
      rethrow;
    }
  }

  Future<ChatLearningResult> correctMessage({
    required String userId,
    required String messageId,
    required String text,
    required String tone,
  }) async {
    try {
      final data = await _ref
          .read(apiClientProvider)
          .postJson(
            '/users/$userId/messages/$messageId/correct',
            body: <String, dynamic>{'text': text, 'tone': tone},
          );
      return ChatLearningResult(
        output: data['correction']?.toString().trim() ?? '',
        note: data['explanation']?.toString().trim() ?? '',
      );
    } on ApiException catch (error) {
      if (error.isNotFound || error.isForbidden) {
        return const ChatLearningResult(
          output: '',
          note: 'Correction API is not available yet for this account.',
        );
      }
      rethrow;
    }
  }

  Future<ChatLearningResult> translateDraft({
    required String userId,
    required String text,
    required String targetLanguage,
  }) async {
    try {
      final data = await _ref
          .read(apiClientProvider)
          .postJson(
            '/users/$userId/messages/draft/translate',
            body: <String, dynamic>{
              'text': text,
              'targetLanguage': targetLanguage,
            },
          );
      return ChatLearningResult(
        output: data['translation']?.toString().trim() ?? '',
        note: data['note']?.toString().trim() ?? '',
        targetLanguage:
            data['targetLanguage']?.toString().trim() ?? targetLanguage.trim(),
      );
    } on ApiException catch (error) {
      if (error.isNotFound || error.isForbidden) {
        return const ChatLearningResult(
          output: '',
          note: 'Draft translation API is not available yet for this account.',
        );
      }
      rethrow;
    }
  }

  Future<ChatLearningResult> correctDraft({
    required String userId,
    required String text,
    required String tone,
  }) async {
    try {
      final data = await _ref
          .read(apiClientProvider)
          .postJson(
            '/users/$userId/messages/draft/correct',
            body: <String, dynamic>{'text': text, 'tone': tone},
          );
      return ChatLearningResult(
        output: _readFirstNonEmptyString(data, const [
          'correction',
          'output',
          'text',
        ]),
        note: _readFirstNonEmptyString(data, const ['explanation', 'note']),
      );
    } on ApiException catch (error) {
      if (error.isNotFound || error.isForbidden) {
        return const ChatLearningResult(
          output: '',
          note: 'Draft correction API is not available yet for this account.',
        );
      }
      rethrow;
    }
  }

  Future<ChatLearningResult> paraphraseDraft({
    required String userId,
    required String text,
  }) async {
    try {
      final data = await _ref
          .read(apiClientProvider)
          .postJson(
            '/users/$userId/messages/draft/paraphrase',
            body: <String, dynamic>{'text': text},
          );
      return ChatLearningResult(
        output: _readFirstNonEmptyString(data, const [
          'paraphrase',
          'rewrite',
          'output',
          'text',
        ]),
        note: _readFirstNonEmptyString(data, const ['explanation', 'note']),
      );
    } on ApiException catch (error) {
      if (error.isNotFound || error.isForbidden) {
        return const ChatLearningResult(
          output: '',
          note: 'Draft paraphrase API is not available yet for this account.',
        );
      }
      rethrow;
    }
  }

  String _readFirstNonEmptyString(
    Map<String, dynamic> data,
    List<String> keys,
  ) {
    for (final key in keys) {
      final value = data[key]?.toString().trim() ?? '';
      if (value.isNotEmpty) return value;
    }
    return '';
  }

  MediaType? _mediaTypeFromMime(String mimeType) {
    final parts = mimeType.trim().split('/');
    if (parts.length != 2 || parts.first.isEmpty || parts.last.isEmpty) {
      return null;
    }
    return MediaType(parts.first, parts.last);
  }

  Map<String, int> _parseReactionMap(dynamic raw) {
    final reactions = <String, int>{};
    if (raw is! Map) return reactions;
    raw.forEach((key, value) {
      final emoji = key.toString().trim();
      final count = (value as num?)?.toInt() ?? 0;
      if (emoji.isNotEmpty && count > 0) reactions[emoji] = count;
    });
    return reactions;
  }

  DirectChatCallPreferences _directChatCallPreferencesFromJson(
    Map<String, dynamic> json,
  ) {
    bool parsePreference(String key) {
      final value = json[key];
      if (value is bool) return value;
      if (value is num) return value == 1;
      if (value is String) {
        final normalized = value.trim().toLowerCase();
        if (normalized == 'true' || normalized == '1') return true;
        if (normalized == 'false' || normalized == '0') return false;
      }
      return true;
    }

    return DirectChatCallPreferences(
      receiveVoiceCalls: parsePreference('receiveVoiceCalls'),
      receiveVideoCalls: parsePreference('receiveVideoCalls'),
    );
  }
}

class DirectChatThread {
  const DirectChatThread({
    required this.threadId,
    required this.messages,
    this.blocked = false,
    this.youBlockedUser = false,
    this.blockedByUser = false,
    this.supportsTranslation = false,
    this.supportsCorrection = false,
  });

  final String threadId;
  final List<ChatMessage> messages;
  final bool blocked;
  final bool youBlockedUser;
  final bool blockedByUser;
  final bool supportsTranslation;
  final bool supportsCorrection;

  factory DirectChatThread.fromPayload(Map<String, dynamic> data) {
    final messages =
        (data['messages'] as List<dynamic>? ?? const [])
            .whereType<Map<String, dynamic>>()
            .map(ChatMessage.fromJson)
            .toList()
          ..sort((a, b) => a.createdAt.compareTo(b.createdAt));
    return DirectChatThread(
      threadId: data['threadId']?.toString() ?? '',
      messages: messages,
      blocked:
          data['blocked'] == true ||
          data['isBlocked'] == true ||
          data['youBlockedUser'] == true ||
          data['blockedByUser'] == true,
      youBlockedUser:
          data['youBlockedUser'] == true ||
          (data['blocked'] == true && data['blockedByUser'] != true),
      blockedByUser: data['blockedByUser'] == true,
      supportsTranslation: data['supportsTranslation'] == true,
      supportsCorrection: data['supportsCorrection'] == true,
    );
  }

  factory DirectChatThread.fromCachePayload(
    Map<String, dynamic> data,
    List<ChatMessage> messages,
  ) {
    return DirectChatThread(
      threadId: data['threadId']?.toString() ?? '',
      messages: messages,
      blocked:
          data['blocked'] == true ||
          data['youBlockedUser'] == true ||
          data['blockedByUser'] == true,
      youBlockedUser: data['youBlockedUser'] == true || data['blocked'] == true,
      blockedByUser: data['blockedByUser'] == true,
      supportsTranslation: data['supportsTranslation'] == true,
      supportsCorrection: data['supportsCorrection'] == true,
    );
  }
}

class ChatLearningResult {
  const ChatLearningResult({
    required this.output,
    required this.note,
    this.targetLanguage = '',
  });

  final String output;
  final String note;
  final String targetLanguage;
}
