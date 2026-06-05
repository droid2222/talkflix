import 'dart:async';
import 'dart:typed_data';

import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../core/auth/session_controller.dart';
import '../../../core/config/privacy_settings_controller.dart';
import '../../../core/network/api_exception.dart';
import '../../../core/realtime/socket_service.dart';
import '../../profile/data/profile_repository.dart';
import 'talk_inbox_screen.dart';
import '../data/chat_message.dart';
import '../data/direct_chat_repository.dart';

final directChatControllerProvider = StateNotifierProvider.autoDispose
    .family<DirectChatController, DirectChatState, String>((ref, userId) {
      final controller = DirectChatController(ref, userId);
      ref.listen<PrivacySettingsState>(privacySettingsControllerProvider, (
        previous,
        next,
      ) {
        if (previous?.showOnlineStatus == next.showOnlineStatus) return;
        controller.handleShowOnlineStatusPreferenceChanged(
          next.showOnlineStatus,
        );
      });
      return controller;
    });

class DirectChatController extends StateNotifier<DirectChatState> {
  DirectChatController(this._ref, this.userId)
    : super(const DirectChatState()) {
    _socketHandler = _handleSocketMessage;
    _typingHandler = _handleTyping;
    _presenceHandler = _handlePresence;
    _statusHandler = _handleMessageStatus;
    _deleteHandler = _handleMessageDelete;
    _editHandler = _handleMessageEdit;
    _reactionHandler = _handleMessageReaction;
    _socket = _ref.read(socketServiceProvider);
    _lastSocketStatus = _socket.status;
    _showOnlineStatus = _ref
        .read(privacySettingsControllerProvider)
        .showOnlineStatus;
    _bindRealtimeHandlers();
    _socket.addListener(_handleSocketStatusChanged);
    Future<void>.microtask(load);
  }

  final Ref _ref;
  final String userId;
  late final SocketService _socket;
  late final void Function(dynamic data) _socketHandler;
  late final void Function(dynamic data) _typingHandler;
  late final void Function(dynamic data) _presenceHandler;
  late final void Function(dynamic data) _statusHandler;
  late final void Function(dynamic data) _deleteHandler;
  late final void Function(dynamic data) _editHandler;
  late final void Function(dynamic data) _reactionHandler;
  late String _lastSocketStatus;
  late bool _showOnlineStatus;
  bool _markingRead = false;
  String _activeThreadId = '';
  bool _joinedSocketRoom = false;
  bool _watchingPartnerPresence = false;
  int _pendingMessageCounter = 0;

  Future<void> load() async {
    final hadMessages = state.messages.isNotEmpty;
    if (!hadMessages) {
      final cached = await _ref
          .read(directChatRepositoryProvider)
          .readCachedThread(userId);
      if (cached != null && cached.messages.isNotEmpty) {
        _activeThreadId = cached.threadId;
        state = state.copyWith(
          threadId: cached.threadId,
          messages: cached.messages,
          blocked: cached.blocked,
          youBlockedUser: cached.youBlockedUser,
          blockedByUser: cached.blockedByUser,
          supportsTranslation: cached.supportsTranslation,
          supportsCorrection: cached.supportsCorrection,
          errorMessage: null,
        );
      }
    }
    state = state.copyWith(
      isLoading: true,
      errorMessage: null,
      messages: hadMessages ? state.messages : null,
    );

    try {
      final thread = await _ref
          .read(directChatRepositoryProvider)
          .fetchMessages(userId)
          .timeout(
            const Duration(seconds: 12),
            onTimeout: () => throw Exception(
              'Chat took too long to load. Please try again.',
            ),
          );

      await _syncRealtimeSubscriptions(threadId: thread.threadId);
      if (!mounted) return;

      state = state.copyWith(
        isLoading: false,
        threadId: thread.threadId,
        messages: _reconcileWithServerSnapshot(
          current: state.messages,
          server: thread.messages,
        ),
        joinedSocketRoom:
            state.joinedSocketRoom ||
            (_socket.isConnected && thread.threadId.trim().isNotEmpty),
        blocked: thread.blocked,
        youBlockedUser: thread.youBlockedUser,
        blockedByUser: thread.blockedByUser,
        supportsTranslation: thread.supportsTranslation,
        supportsCorrection: thread.supportsCorrection,
      );
      _activeThreadId = thread.threadId;
      _joinedSocketRoom =
          state.joinedSocketRoom ||
          (_socket.isConnected && thread.threadId.trim().isNotEmpty);
      unawaited(_persistCache());
      await _markThreadRead();
    } catch (error) {
      if (!mounted) return;
      state = state.copyWith(isLoading: false, errorMessage: error.toString());
    }
  }

  Future<void> reload() async {
    await load();
  }

  void handleShowOnlineStatusPreferenceChanged(bool value) {
    if (_showOnlineStatus == value) return;
    _showOnlineStatus = value;
    if (!value) {
      if (_socket.isConnected && _watchingPartnerPresence) {
        _socket.emit('presence:unwatch', <String, dynamic>{'userId': userId});
      }
      _watchingPartnerPresence = false;
      if (mounted && state.partnerOnline) {
        state = state.copyWith(partnerOnline: false);
      }
      return;
    }
    unawaited(_syncRealtimeSubscriptions());
  }

  void _bindRealtimeHandlers() {
    _socket.off('dm:message', _socketHandler);
    _socket.off('dm:typing', _typingHandler);
    _socket.off('presence:update', _presenceHandler);
    _socket.off('dm:message:status', _statusHandler);
    _socket.off('dm:message:delete', _deleteHandler);
    _socket.off('dm:message:edit', _editHandler);
    _socket.off('dm:message:reaction', _reactionHandler);
    _socket.on('dm:message', _socketHandler);
    _socket.on('dm:typing', _typingHandler);
    _socket.on('presence:update', _presenceHandler);
    _socket.on('dm:message:status', _statusHandler);
    _socket.on('dm:message:delete', _deleteHandler);
    _socket.on('dm:message:edit', _editHandler);
    _socket.on('dm:message:reaction', _reactionHandler);
  }

  void _handleSocketStatusChanged() {
    if (!mounted) return;
    final nextStatus = _socket.status;
    if (nextStatus == _lastSocketStatus) return;
    _lastSocketStatus = nextStatus;
    if (nextStatus == 'connected') {
      unawaited(_syncRealtimeSubscriptions());
      return;
    }
    _watchingPartnerPresence = false;
    if (_joinedSocketRoom) {
      _joinedSocketRoom = false;
      state = state.copyWith(joinedSocketRoom: false);
    }
  }

  Future<void> _syncRealtimeSubscriptions({String? threadId}) async {
    if (!mounted) return;
    _bindRealtimeHandlers();

    final effectiveThreadId = (threadId ?? state.threadId).trim();
    if (_socket.isConnected && effectiveThreadId.isNotEmpty) {
      _socket.emit('dm:join', <String, dynamic>{'threadId': effectiveThreadId});
      _activeThreadId = effectiveThreadId;
      _joinedSocketRoom = true;
      if (mounted) {
        state = state.copyWith(
          threadId: effectiveThreadId,
          joinedSocketRoom: true,
        );
      }
    }

    if (!_socket.isConnected) return;
    if (!_showOnlineStatus) {
      if (_watchingPartnerPresence) {
        _socket.emit('presence:unwatch', <String, dynamic>{'userId': userId});
        _watchingPartnerPresence = false;
      }
      if (mounted && state.partnerOnline) {
        state = state.copyWith(partnerOnline: false);
      }
      return;
    }

    _watchingPartnerPresence = true;
    final presencePayload = await _socket.emitWithAckRetry(
      'presence:watch',
      <String, dynamic>{'userId': userId},
      timeout: const Duration(seconds: 3),
      maxAttempts: 3,
      retryDelay: const Duration(milliseconds: 700),
    );
    if (!mounted) return;
    if (!_showOnlineStatus) return;
    if (presencePayload is Map && presencePayload['online'] != null) {
      state = state.copyWith(partnerOnline: presencePayload['online'] == true);
    }
  }

  Future<void> sendTextMessage(String text) async {
    final trimmed = text.trim();
    if (trimmed.isEmpty || state.isSending || state.blocked) {
      return;
    }
    final replyTarget = state.replyTargetMessage;
    final replyToMessageId = replyTarget?.id;

    final clientId = _nextClientMessageId();
    _insertOptimisticMessage(
      clientMessageId: clientId,
      type: 'text',
      text: trimmed,
      mimeType: 'text/plain',
      replyToMessageId: replyToMessageId ?? '',
    );
    state = state.copyWith(isSending: true, errorMessage: null);

    try {
      final message = await _ref
          .read(directChatRepositoryProvider)
          .sendTextMessage(
            userId: userId,
            text: trimmed,
            clientMessageId: clientId,
            replyToMessageId: replyToMessageId,
          );
      _replaceOptimisticMessage(
        clientMessageId: clientId,
        serverMessage: message,
      );
      state = state.copyWith(isSending: false, clearReplyTarget: true);
      unawaited(_persistCache());
      _ref.invalidate(recentThreadsProvider);
    } catch (error) {
      _markOptimisticMessageFailed(clientId);
      state = state.copyWith(isSending: false, errorMessage: error.toString());
    }
  }

  Future<void> sendImageMessage({
    required Uint8List bytes,
    required String mimeType,
  }) async {
    if (state.isSending || state.blocked) return;
    final replyTarget = state.replyTargetMessage;
    final replyToMessageId = replyTarget?.id;
    final clientId = _nextClientMessageId();
    _insertOptimisticMessage(
      clientMessageId: clientId,
      type: 'image',
      imageUrl: '',
      text: '',
      mimeType: mimeType,
      replyToMessageId: replyToMessageId ?? '',
    );
    state = state.copyWith(isSending: true, clearError: true);
    try {
      final message = await _ref
          .read(directChatRepositoryProvider)
          .sendImageMessage(
            userId: userId,
            mimeType: mimeType,
            bytes: bytes,
            clientMessageId: clientId,
            replyToMessageId: replyToMessageId,
          );
      _replaceOptimisticMessage(
        clientMessageId: clientId,
        serverMessage: message,
      );
      state = state.copyWith(isSending: false, clearReplyTarget: true);
      unawaited(_persistCache());
      _ref.invalidate(recentThreadsProvider);
    } catch (error) {
      _markOptimisticMessageFailed(clientId);
      state = state.copyWith(isSending: false, errorMessage: error.toString());
    }
  }

  Future<void> sendAudioMessage({
    required Uint8List bytes,
    required String mimeType,
    required int durationSeconds,
  }) async {
    if (state.isSending || state.blocked) return;
    final replyTarget = state.replyTargetMessage;
    final replyToMessageId = replyTarget?.id;
    final clientId = _nextClientMessageId();
    _insertOptimisticMessage(
      clientMessageId: clientId,
      type: 'audio',
      audioUrl: '',
      audioDuration: durationSeconds,
      mimeType: mimeType,
      replyToMessageId: replyToMessageId ?? '',
    );
    state = state.copyWith(isSending: true, clearError: true);
    try {
      final message = await _ref
          .read(directChatRepositoryProvider)
          .sendAudioMessage(
            userId: userId,
            mimeType: mimeType,
            bytes: bytes,
            durationSeconds: durationSeconds,
            clientMessageId: clientId,
            replyToMessageId: replyToMessageId,
          );
      _replaceOptimisticMessage(
        clientMessageId: clientId,
        serverMessage: message,
      );
      state = state.copyWith(isSending: false, clearReplyTarget: true);
      unawaited(_persistCache());
      _ref.invalidate(recentThreadsProvider);
    } catch (error) {
      _markOptimisticMessageFailed(clientId);
      state = state.copyWith(isSending: false, errorMessage: error.toString());
    }
  }

  Future<void> sendFileMessage({
    required Uint8List bytes,
    required String fileName,
    required String mimeType,
  }) async {
    if (state.isSending || state.blocked) return;
    final replyTarget = state.replyTargetMessage;
    final replyToMessageId = replyTarget?.id;
    final clientId = _nextClientMessageId();
    _insertOptimisticMessage(
      clientMessageId: clientId,
      type: 'file',
      fileName: fileName,
      fileSize: bytes.length,
      mimeType: mimeType,
      replyToMessageId: replyToMessageId ?? '',
    );
    state = state.copyWith(isSending: true, clearError: true);
    try {
      final message = await _ref
          .read(directChatRepositoryProvider)
          .sendFileMessage(
            userId: userId,
            bytes: bytes,
            fileName: fileName,
            mimeType: mimeType,
            clientMessageId: clientId,
            replyToMessageId: replyToMessageId,
          );
      _replaceOptimisticMessage(
        clientMessageId: clientId,
        serverMessage: message,
      );
      state = state.copyWith(isSending: false, clearReplyTarget: true);
      unawaited(_persistCache());
      _ref.invalidate(recentThreadsProvider);
    } catch (error) {
      _markOptimisticMessageFailed(clientId);
      state = state.copyWith(isSending: false, errorMessage: error.toString());
    }
  }

  void setReplyTarget(ChatMessage? message) {
    state = state.copyWith(replyTargetMessage: message);
  }

  Future<void> deleteMessageForMe(String messageId) async {
    final next = state.messages
        .where((m) => m.id != messageId && m.clientMessageId != messageId)
        .toList();
    state = state.copyWith(messages: next);
    unawaited(_persistCache());
    if (messageId.startsWith('local-')) return;
    try {
      await _ref
          .read(directChatRepositoryProvider)
          .deleteMessageForMe(userId: userId, messageId: messageId);
    } catch (error) {
      state = state.copyWith(errorMessage: error.toString());
    }
  }

  /// Deletes the message on the server then removes it locally.
  /// Returns true on success.
  Future<bool> deleteMessageForEveryone(String messageId) async {
    // Optimistic: remove locally first
    final next = state.messages
        .where((m) => m.id != messageId && m.clientMessageId != messageId)
        .toList();
    state = state.copyWith(messages: next);
    unawaited(_persistCache());
    try {
      await _ref
          .read(directChatRepositoryProvider)
          .deleteMessageForEveryone(userId: userId, messageId: messageId);
      return true;
    } catch (_) {
      // If the API fails we still keep it removed locally (matches WhatsApp UX)
      return false;
    }
  }

  Future<bool> editMessage({
    required String messageId,
    required String text,
  }) async {
    final trimmed = text.trim();
    if (trimmed.isEmpty || state.blocked) return false;
    try {
      final message = await _ref
          .read(directChatRepositoryProvider)
          .editMessage(userId: userId, messageId: messageId, text: trimmed);
      _replaceMessageById(messageId, message);
      _ref.invalidate(recentThreadsProvider);
      return true;
    } catch (error) {
      state = state.copyWith(errorMessage: error.toString());
      return false;
    }
  }

  Future<void> toggleReaction({
    required String messageId,
    required String emoji,
  }) async {
    if (messageId.startsWith('local-')) return;
    ChatMessage? existing;
    for (final message in state.messages) {
      if (message.id == messageId) {
        existing = message;
        break;
      }
    }
    if (existing == null) return;
    try {
      final normalizedEmoji = emoji.trim();
      final reactions = existing.myReaction == normalizedEmoji
          ? await _ref
                .read(directChatRepositoryProvider)
                .clearReaction(userId: userId, messageId: messageId)
          : await _ref
                .read(directChatRepositoryProvider)
                .setReaction(
                  userId: userId,
                  messageId: messageId,
                  emoji: normalizedEmoji,
                );
      final myReaction = existing.myReaction == normalizedEmoji
          ? ''
          : normalizedEmoji;
      _replaceMessageById(
        messageId,
        existing.copyWith(reactions: reactions, myReaction: myReaction),
      );
    } catch (error) {
      state = state.copyWith(errorMessage: error.toString());
    }
  }

  Future<List<ChatMessage>> searchMessages(String query) {
    return _ref
        .read(directChatRepositoryProvider)
        .searchMessages(userId: userId, query: query);
  }

  Future<List<ChatMessage>> fetchSharedMessages({String type = 'files'}) {
    return _ref
        .read(directChatRepositoryProvider)
        .fetchSharedMessages(userId: userId, type: type);
  }

  Future<bool> blockUser() async {
    if (state.youBlockedUser) return true;
    try {
      await _ref.read(directChatRepositoryProvider).blockUser(userId);
      _ref.invalidate(blockedUsersProvider);
      state = state.copyWith(
        blocked: true,
        youBlockedUser: true,
        clearReplyTarget: true,
      );
      unawaited(_persistCache());
      return true;
    } catch (error) {
      state = state.copyWith(errorMessage: error.toString());
      return false;
    }
  }

  Future<bool> unblockUser() async {
    if (!state.youBlockedUser) return true;
    try {
      await _ref.read(directChatRepositoryProvider).unblockUser(userId);
      _ref.invalidate(blockedUsersProvider);
      final stillBlocked = state.blockedByUser;
      state = state.copyWith(blocked: stillBlocked, youBlockedUser: false);
      unawaited(_persistCache());
      return true;
    } catch (error) {
      state = state.copyWith(errorMessage: error.toString());
      return false;
    }
  }

  Future<bool> reportUser({required String reason}) async {
    try {
      await _ref
          .read(directChatRepositoryProvider)
          .reportUser(userId: userId, reason: reason);
      return true;
    } catch (error) {
      state = state.copyWith(errorMessage: error.toString());
      return false;
    }
  }

  Future<bool> reportMessage({
    required String messageId,
    required String reason,
  }) async {
    try {
      await _ref
          .read(directChatRepositoryProvider)
          .reportMessage(userId: userId, messageId: messageId, reason: reason);
      return true;
    } catch (error) {
      state = state.copyWith(errorMessage: error.toString());
      return false;
    }
  }

  Future<ChatLearningResult> translateMessage(
    ChatMessage message, {
    required String targetLanguage,
  }) async {
    final text = message.text.trim();
    if (text.isEmpty) {
      return const ChatLearningResult(
        output: '',
        note: 'Only text messages can be translated right now.',
      );
    }
    try {
      return await _ref
          .read(directChatRepositoryProvider)
          .translateMessage(
            userId: userId,
            messageId: message.id,
            text: text,
            targetLanguage: targetLanguage,
          );
    } on ApiException catch (error) {
      return ChatLearningResult(output: '', note: userFriendlyMessage(error));
    } catch (_) {
      return const ChatLearningResult(
        output: '',
        note: 'Could not translate this message right now.',
      );
    }
  }

  Future<ChatLearningResult> correctMessage({
    required ChatMessage message,
    required String tone,
  }) async {
    final text = message.text.trim();
    if (text.isEmpty) {
      return const ChatLearningResult(
        output: '',
        note: 'Only text messages can be corrected right now.',
      );
    }
    try {
      return await _ref
          .read(directChatRepositoryProvider)
          .correctMessage(
            userId: userId,
            messageId: message.id,
            text: text,
            tone: tone,
          );
    } on ApiException catch (error) {
      return ChatLearningResult(output: '', note: userFriendlyMessage(error));
    } catch (_) {
      return const ChatLearningResult(
        output: '',
        note: 'Could not generate correction right now.',
      );
    }
  }

  Future<ChatLearningResult> translateDraft({
    required String text,
    required String targetLanguage,
  }) async {
    final trimmed = text.trim();
    if (trimmed.isEmpty) {
      return const ChatLearningResult(
        output: '',
        note: 'Type a message before using translate.',
      );
    }
    try {
      return await _ref
          .read(directChatRepositoryProvider)
          .translateDraft(
            userId: userId,
            text: trimmed,
            targetLanguage: targetLanguage,
          );
    } on ApiException catch (error) {
      return ChatLearningResult(output: '', note: userFriendlyMessage(error));
    } catch (_) {
      return const ChatLearningResult(
        output: '',
        note: 'Could not translate this draft right now.',
      );
    }
  }

  Future<ChatLearningResult> correctDraft({
    required String text,
    required String tone,
  }) async {
    final trimmed = text.trim();
    if (trimmed.isEmpty) {
      return const ChatLearningResult(
        output: '',
        note: 'Type a message before using grammar check.',
      );
    }
    try {
      return await _ref
          .read(directChatRepositoryProvider)
          .correctDraft(userId: userId, text: trimmed, tone: tone);
    } on ApiException catch (error) {
      return ChatLearningResult(output: '', note: userFriendlyMessage(error));
    } catch (_) {
      return const ChatLearningResult(
        output: '',
        note: 'Could not check this draft right now.',
      );
    }
  }

  Future<ChatLearningResult> paraphraseDraft({required String text}) async {
    final trimmed = text.trim();
    if (trimmed.isEmpty) {
      return const ChatLearningResult(
        output: '',
        note: 'Type a message before using paraphrase.',
      );
    }
    try {
      return await _ref
          .read(directChatRepositoryProvider)
          .paraphraseDraft(userId: userId, text: trimmed);
    } on ApiException catch (error) {
      return ChatLearningResult(output: '', note: userFriendlyMessage(error));
    } catch (_) {
      return const ChatLearningResult(
        output: '',
        note: 'Could not paraphrase this draft right now.',
      );
    }
  }

  Future<void> retryFailedMessage(String messageId) async {
    final failedIndex = state.messages.indexWhere((m) => m.id == messageId);
    if (failedIndex < 0 || state.isSending) return;
    final failed = state.messages[failedIndex];
    if (!failed.canRetry) return;
    if (failed.type != 'text') {
      state = state.copyWith(
        errorMessage: 'Retry is available for text messages right now.',
      );
      return;
    }
    _setMessageDeliveryState(
      messageId,
      isPending: true,
      isFailed: false,
      status: 'sending',
    );
    state = state.copyWith(isSending: true, clearError: true);
    try {
      final message = await _ref
          .read(directChatRepositoryProvider)
          .sendTextMessage(
            userId: userId,
            text: failed.text,
            clientMessageId: failed.clientMessageId,
            replyToMessageId: failed.replyToMessageId.isEmpty
                ? null
                : failed.replyToMessageId,
          );
      _replaceMessageById(
        messageId,
        message.copyWith(
          clientMessageId: failed.clientMessageId,
          isPending: false,
          isFailed: false,
        ),
      );
      state = state.copyWith(isSending: false);
      unawaited(_persistCache());
      _ref.invalidate(recentThreadsProvider);
    } catch (error) {
      _setMessageDeliveryState(
        messageId,
        isPending: false,
        isFailed: true,
        status: 'failed',
      );
      state = state.copyWith(isSending: false, errorMessage: error.toString());
    }
  }

  void appendLocalCallEvent({
    required String threadId,
    required String callId,
    required String eventKey,
    required String text,
    DateTime? createdAt,
  }) {
    final normalizedThreadId = threadId.trim().isNotEmpty
        ? threadId.trim()
        : state.threadId;
    if (normalizedThreadId.isEmpty) {
      return;
    }
    if (state.threadId.isNotEmpty && state.threadId != normalizedThreadId) {
      return;
    }
    if (state.threadId != normalizedThreadId) {
      state = state.copyWith(threadId: normalizedThreadId);
    }
    _mergeMessage(
      ChatMessage.localCallEvent(
        threadId: normalizedThreadId,
        callId: callId,
        eventKey: eventKey,
        text: text,
        createdAt: createdAt,
      ),
    );
    unawaited(_persistCache());
  }

  void sendTyping(bool typing) {
    if (!state.joinedSocketRoom || state.threadId.isEmpty || state.blocked) {
      return;
    }
    _ref.read(socketServiceProvider).emit('dm:typing', <String, dynamic>{
      'threadId': state.threadId,
      'typing': typing,
    });
  }

  void _handleSocketMessage(dynamic data) {
    if (data is! Map) {
      return;
    }

    final message = ChatMessage.fromJson(Map<String, dynamic>.from(data));
    if (message.threadId != state.threadId || message.threadId.isEmpty) {
      return;
    }

    _mergeMessage(message);
    if (message.fromUserId == userId) {
      Future<void>.microtask(_markThreadRead);
    }
    _ref.invalidate(recentThreadsProvider);
  }

  void _handleTyping(dynamic data) {
    if (data is! Map) return;
    final payload = Map<String, dynamic>.from(data);
    if (payload['threadId']?.toString() != state.threadId) return;
    // Ignore our own typing echoes — only show partner's indicator.
    final fromId = payload['userId']?.toString() ?? '';
    if (fromId.isNotEmpty && fromId != userId) {
      state = state.copyWith(theirTyping: payload['typing'] == true);
    } else if (fromId.isEmpty) {
      // Server didn't include userId — accept the event (legacy compat).
      state = state.copyWith(theirTyping: payload['typing'] == true);
    }
  }

  void _handlePresence(dynamic data) {
    if (!_showOnlineStatus) return;
    if (data is! Map) return;
    final payload = Map<String, dynamic>.from(data);
    if (payload['userId']?.toString() != userId) return;
    state = state.copyWith(partnerOnline: payload['online'] == true);
  }

  void _handleMessageStatus(dynamic data) {
    if (data is! Map) return;
    final payload = Map<String, dynamic>.from(data);
    if (payload['threadId']?.toString() != state.threadId) return;
    final status = payload['status']?.toString();
    if (status == null || status.isEmpty) return;
    final ids = (payload['messageIds'] as List<dynamic>? ?? const [])
        .map((value) => value.toString())
        .where((value) => value.isNotEmpty)
        .toSet();
    if (ids.isEmpty) return;
    final nextMessages = state.messages
        .map(
          (message) => ids.contains(message.id)
              ? message.copyWith(
                  status: status,
                  isPending: false,
                  isFailed: false,
                )
              : message,
        )
        .toList();
    state = state.copyWith(messages: nextMessages);
    unawaited(_persistCache());
  }

  void _handleMessageDelete(dynamic data) {
    if (data is! Map) return;
    final payload = Map<String, dynamic>.from(data);
    if (payload['threadId']?.toString() != state.threadId) return;
    final messageId = payload['messageId']?.toString() ?? '';
    if (messageId.isEmpty) return;
    final nextMessages = state.messages
        .where((message) => message.id != messageId)
        .toList();
    state = state.copyWith(messages: nextMessages);
    unawaited(_persistCache());
    _ref.invalidate(recentThreadsProvider);
  }

  void _handleMessageEdit(dynamic data) {
    if (data is! Map) return;
    final message = ChatMessage.fromJson(Map<String, dynamic>.from(data));
    if (message.threadId != state.threadId || message.id.isEmpty) return;
    _replaceMessageById(message.id, message);
    _ref.invalidate(recentThreadsProvider);
  }

  void _handleMessageReaction(dynamic data) {
    if (data is! Map) return;
    final payload = Map<String, dynamic>.from(data);
    if (payload['threadId']?.toString() != state.threadId) return;
    final messageId = payload['messageId']?.toString() ?? '';
    if (messageId.isEmpty) return;
    final rawReactions = payload['reactions'];
    final reactions = <String, int>{};
    if (rawReactions is Map) {
      rawReactions.forEach((key, value) {
        final emoji = key.toString().trim();
        final count = (value as num?)?.toInt() ?? 0;
        if (emoji.isNotEmpty && count > 0) reactions[emoji] = count;
      });
    }
    final nextMessages = state.messages
        .map(
          (message) => message.id == messageId
              ? message.copyWith(reactions: reactions)
              : message,
        )
        .toList();
    state = state.copyWith(messages: nextMessages);
    unawaited(_persistCache());
  }

  Future<void> _markThreadRead() async {
    if (_markingRead) return;
    _markingRead = true;
    try {
      final ids = await _ref
          .read(directChatRepositoryProvider)
          .markThreadRead(userId);
      if (ids.isEmpty) return;
      final idSet = ids.toSet();
      final nextMessages = state.messages
          .map(
            (message) => idSet.contains(message.id)
                ? message.copyWith(
                    status: 'read',
                    isPending: false,
                    isFailed: false,
                  )
                : message,
          )
          .toList();
      state = state.copyWith(messages: nextMessages);
      _ref.invalidate(recentThreadsProvider);
    } catch (_) {
    } finally {
      _markingRead = false;
    }
  }

  void _mergeMessage(ChatMessage message) {
    final nextMessages = [...state.messages];
    final index = nextMessages.indexWhere((item) => item.id == message.id);
    if (index >= 0) {
      nextMessages[index] = message;
    } else if (message.clientMessageId.isNotEmpty) {
      final byClientIdIndex = nextMessages.indexWhere(
        (item) => item.clientMessageId == message.clientMessageId,
      );
      if (byClientIdIndex >= 0) {
        nextMessages[byClientIdIndex] = message.copyWith(
          isPending: false,
          isFailed: false,
        );
      } else {
        nextMessages.add(message);
      }
    } else {
      final optimisticMatchIndex = _findOptimisticMatchIndex(
        nextMessages,
        message,
      );
      if (optimisticMatchIndex >= 0) {
        final optimistic = nextMessages[optimisticMatchIndex];
        nextMessages[optimisticMatchIndex] = message.copyWith(
          clientMessageId: optimistic.clientMessageId,
          isPending: false,
          isFailed: false,
        );
      } else {
        nextMessages.add(message);
      }
    }

    nextMessages.sort((a, b) => a.createdAt.compareTo(b.createdAt));
    state = state.copyWith(messages: nextMessages);
  }

  int _findOptimisticMatchIndex(
    List<ChatMessage> messages,
    ChatMessage incoming,
  ) {
    for (var i = 0; i < messages.length; i++) {
      final candidate = messages[i];
      if (!candidate.id.startsWith('local-')) continue;
      if (!candidate.isPending) continue;
      if (candidate.fromUserId != incoming.fromUserId) continue;
      if (candidate.type != incoming.type) continue;
      if (candidate.replyToMessageId != incoming.replyToMessageId) continue;

      final ageDiffSeconds = candidate.createdAt
          .difference(incoming.createdAt)
          .inSeconds
          .abs();
      if (ageDiffSeconds > 20) continue;

      if (incoming.type == 'text' &&
          candidate.text.trim() != incoming.text.trim()) {
        continue;
      }
      return i;
    }
    return -1;
  }

  void _insertOptimisticMessage({
    required String clientMessageId,
    required String type,
    String text = '',
    String imageUrl = '',
    String audioUrl = '',
    int audioDuration = 0,
    String fileUrl = '',
    String fileName = '',
    int fileSize = 0,
    String mimeType = '',
    String replyToMessageId = '',
  }) {
    final optimistic = ChatMessage(
      id: 'local-$clientMessageId',
      clientMessageId: clientMessageId,
      threadId: state.threadId,
      fromUserId: _currentUserId,
      toUserId: userId,
      type: type,
      text: text,
      imageUrl: imageUrl,
      audioUrl: audioUrl,
      audioDuration: audioDuration,
      fileUrl: fileUrl,
      fileName: fileName,
      fileSize: fileSize,
      mimeType: mimeType,
      linkPreview: const <String, dynamic>{},
      reactions: const <String, int>{},
      myReaction: '',
      pinnedByMe: false,
      editedAt: null,
      status: 'sending',
      createdAt: DateTime.now(),
      replyToMessageId: replyToMessageId,
      isPending: true,
      isFailed: false,
    );
    _mergeMessage(optimistic);
  }

  void _replaceOptimisticMessage({
    required String clientMessageId,
    required ChatMessage serverMessage,
  }) {
    final nextMessages = [...state.messages];
    final index = nextMessages.indexWhere(
      (item) => item.clientMessageId == clientMessageId,
    );
    final normalized = serverMessage.copyWith(
      clientMessageId: clientMessageId,
      isPending: false,
      isFailed: false,
    );
    if (index >= 0) {
      nextMessages[index] = normalized;
      nextMessages.sort((a, b) => a.createdAt.compareTo(b.createdAt));
      state = state.copyWith(messages: nextMessages);
      unawaited(_persistCache());
      return;
    }
    _mergeMessage(normalized);
  }

  void _markOptimisticMessageFailed(String clientMessageId) {
    final nextMessages = state.messages
        .map(
          (message) => message.clientMessageId == clientMessageId
              ? message.copyWith(
                  isPending: false,
                  isFailed: true,
                  status: 'failed',
                )
              : message,
        )
        .toList();
    state = state.copyWith(messages: nextMessages);
    unawaited(_persistCache());
  }

  void _setMessageDeliveryState(
    String messageId, {
    required bool isPending,
    required bool isFailed,
    required String status,
  }) {
    final nextMessages = state.messages
        .map(
          (message) => message.id == messageId
              ? message.copyWith(
                  isPending: isPending,
                  isFailed: isFailed,
                  status: status,
                )
              : message,
        )
        .toList();
    state = state.copyWith(messages: nextMessages);
    unawaited(_persistCache());
  }

  void _replaceMessageById(String messageId, ChatMessage nextMessage) {
    final nextMessages = state.messages
        .map((message) => message.id == messageId ? nextMessage : message)
        .toList();
    state = state.copyWith(messages: nextMessages);
    unawaited(_persistCache());
  }

  List<ChatMessage> _reconcileWithServerSnapshot({
    required List<ChatMessage> current,
    required List<ChatMessage> server,
  }) {
    final serverById = <String, ChatMessage>{};
    final serverByClientId = <String, ChatMessage>{};
    for (final message in server) {
      if (message.id.isNotEmpty) {
        serverById[message.id] = message;
      }
      if (message.clientMessageId.isNotEmpty) {
        serverByClientId[message.clientMessageId] = message;
      }
    }

    final pendingLocal = current.where((message) {
      if (!(message.isPending ||
          message.isFailed ||
          message.id.startsWith('local-'))) {
        return false;
      }
      if (message.id.isNotEmpty && serverById.containsKey(message.id)) {
        return false;
      }
      if (message.clientMessageId.isNotEmpty &&
          serverByClientId.containsKey(message.clientMessageId)) {
        return false;
      }
      return true;
    });

    final merged = <ChatMessage>[...server, ...pendingLocal];
    merged.sort((a, b) => a.createdAt.compareTo(b.createdAt));

    final deduped = <ChatMessage>[];
    final seenIds = <String>{};
    final seenClientIds = <String>{};
    for (final message in merged) {
      if (message.id.isNotEmpty && seenIds.contains(message.id)) continue;
      if (message.clientMessageId.isNotEmpty &&
          seenClientIds.contains(message.clientMessageId)) {
        continue;
      }
      deduped.add(message);
      if (message.id.isNotEmpty) seenIds.add(message.id);
      if (message.clientMessageId.isNotEmpty) {
        seenClientIds.add(message.clientMessageId);
      }
    }
    return deduped;
  }

  Future<void> _persistCache() {
    if (state.threadId.isEmpty) return Future<void>.value();
    return _ref
        .read(directChatRepositoryProvider)
        .writeCachedThread(
          userId: userId,
          threadId: state.threadId,
          messages: state.messages,
          blocked: state.blocked,
          youBlockedUser: state.youBlockedUser,
          blockedByUser: state.blockedByUser,
          supportsTranslation: state.supportsTranslation,
          supportsCorrection: state.supportsCorrection,
        );
  }

  String _nextClientMessageId() {
    _pendingMessageCounter += 1;
    return '${DateTime.now().microsecondsSinceEpoch}-$_pendingMessageCounter';
  }

  String get _currentUserId =>
      _ref.read(sessionControllerProvider).user?.id ?? '';

  @override
  void dispose() {
    _socket.removeListener(_handleSocketStatusChanged);
    if (_socket.isConnected &&
        _joinedSocketRoom &&
        _activeThreadId.isNotEmpty) {
      _socket.emit('dm:leave', <String, dynamic>{'threadId': _activeThreadId});
    }
    if (_socket.isConnected && _watchingPartnerPresence) {
      _socket.emit('presence:unwatch', <String, dynamic>{'userId': userId});
    }
    _watchingPartnerPresence = false;
    _socket.off('dm:message', _socketHandler);
    _socket.off('dm:typing', _typingHandler);
    _socket.off('presence:update', _presenceHandler);
    _socket.off('dm:message:status', _statusHandler);
    _socket.off('dm:message:delete', _deleteHandler);
    _socket.off('dm:message:edit', _editHandler);
    _socket.off('dm:message:reaction', _reactionHandler);
    super.dispose();
  }
}

class DirectChatState {
  const DirectChatState({
    this.threadId = '',
    this.messages = const <ChatMessage>[],
    this.isLoading = false,
    this.isSending = false,
    this.joinedSocketRoom = false,
    this.theirTyping = false,
    this.partnerOnline = false,
    this.errorMessage,
    this.replyTargetMessage,
    this.blocked = false,
    this.youBlockedUser = false,
    this.blockedByUser = false,
    this.supportsTranslation = false,
    this.supportsCorrection = false,
  });

  final String threadId;
  final List<ChatMessage> messages;
  final bool isLoading;
  final bool isSending;
  final bool joinedSocketRoom;
  final bool theirTyping;
  final bool partnerOnline;
  final String? errorMessage;
  final ChatMessage? replyTargetMessage;
  final bool blocked;
  final bool youBlockedUser;
  final bool blockedByUser;
  final bool supportsTranslation;
  final bool supportsCorrection;
  DirectChatState copyWith({
    String? threadId,
    List<ChatMessage>? messages,
    bool? isLoading,
    bool? isSending,
    bool? joinedSocketRoom,
    bool? theirTyping,
    bool? partnerOnline,
    bool? blocked,
    bool? youBlockedUser,
    bool? blockedByUser,
    bool? supportsTranslation,
    bool? supportsCorrection,
    String? errorMessage,
    ChatMessage? replyTargetMessage,
    bool clearError = false,
    bool clearReplyTarget = false,
  }) {
    return DirectChatState(
      threadId: threadId ?? this.threadId,
      messages: messages ?? this.messages,
      isLoading: isLoading ?? this.isLoading,
      isSending: isSending ?? this.isSending,
      joinedSocketRoom: joinedSocketRoom ?? this.joinedSocketRoom,
      theirTyping: theirTyping ?? this.theirTyping,
      partnerOnline: partnerOnline ?? this.partnerOnline,
      blocked: blocked ?? this.blocked,
      youBlockedUser: youBlockedUser ?? this.youBlockedUser,
      blockedByUser: blockedByUser ?? this.blockedByUser,
      supportsTranslation: supportsTranslation ?? this.supportsTranslation,
      supportsCorrection: supportsCorrection ?? this.supportsCorrection,
      errorMessage: clearError ? null : errorMessage ?? this.errorMessage,
      replyTargetMessage: clearReplyTarget
          ? null
          : (replyTargetMessage ?? this.replyTargetMessage),
    );
  }
}
