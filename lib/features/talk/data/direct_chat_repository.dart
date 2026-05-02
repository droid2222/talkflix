import 'dart:typed_data';
import 'dart:convert';

import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../core/auth/session_controller.dart';
import '../../../core/config/storage_keys.dart';
import '../../../core/network/api_exception.dart';
import '../../../core/network/api_client.dart';
import '../../../core/media/media_utils.dart';
import 'chat_message.dart';

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
    final data = await _ref
        .read(apiClientProvider)
        .postJson(
          '/users/$userId/messages',
          body: <String, dynamic>{
            'type': 'image',
            'imageUrl': bytesToDataUrl(bytes, mimeType),
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

  Future<ChatMessage> sendAudioMessage({
    required String userId,
    required String mimeType,
    required Uint8List bytes,
    required int durationSeconds,
    String? clientMessageId,
    String? replyToMessageId,
  }) async {
    final data = await _ref
        .read(apiClientProvider)
        .postJson(
          '/users/$userId/messages',
          body: <String, dynamic>{
            'type': 'audio',
            'audioUrl': bytesToDataUrl(bytes, mimeType),
            'audioDuration': durationSeconds,
            'mimeType': mimeType,
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
  }) async {
    try {
      final data = await _ref
          .read(apiClientProvider)
          .postJson(
            '/users/$userId/messages/$messageId/translate',
            body: <String, dynamic>{'text': text},
          );
      return ChatLearningResult(
        output: data['translation']?.toString().trim() ?? '',
        note: data['note']?.toString().trim() ?? '',
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
  const ChatLearningResult({required this.output, required this.note});

  final String output;
  final String note;
}
