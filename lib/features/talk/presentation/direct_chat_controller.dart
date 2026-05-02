import 'dart:async';
import 'dart:typed_data';

import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../core/auth/session_controller.dart';
import '../../../core/network/api_exception.dart';
import '../../../core/realtime/socket_service.dart';
import 'talk_inbox_screen.dart';
import '../data/chat_message.dart';
import '../data/direct_chat_repository.dart';

final directChatControllerProvider = StateNotifierProvider.autoDispose
    .family<DirectChatController, DirectChatState, String>((ref, userId) {
      final controller = DirectChatController(ref, userId);
      ref.onDispose(controller.dispose);
      return controller;
    });

class DirectChatController extends StateNotifier<DirectChatState> {
  DirectChatController(this._ref, this.userId)
    : super(const DirectChatState()) {
    _socketHandler = _handleSocketMessage;
    _typingHandler = _handleTyping;
    _presenceHandler = _handlePresence;
    _statusHandler = _handleMessageStatus;
    Future<void>.microtask(load);
  }

  final Ref _ref;
  final String userId;
  late final void Function(dynamic data) _socketHandler;
  late final void Function(dynamic data) _typingHandler;
  late final void Function(dynamic data) _presenceHandler;
  late final void Function(dynamic data) _statusHandler;
  bool _markingRead = false;
  int _pendingMessageCounter = 0;

  Future<void> load() async {
    final hadMessages = state.messages.isNotEmpty;
    if (!hadMessages) {
      final cached = await _ref
          .read(directChatRepositoryProvider)
          .readCachedThread(userId);
      if (cached != null && cached.messages.isNotEmpty) {
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

      final socket = _ref.read(socketServiceProvider);
      socket.off('dm:message', _socketHandler);
      socket.off('dm:typing', _typingHandler);
      socket.off('presence:update', _presenceHandler);
      socket.off('dm:message:status', _statusHandler);
      socket.on('dm:message', _socketHandler);
      socket.on('dm:typing', _typingHandler);
      socket.on('presence:update', _presenceHandler);
      socket.on('dm:message:status', _statusHandler);
      socket.emit('dm:join', <String, dynamic>{'threadId': thread.threadId});
      final presencePayload = await socket.emitWithAckRetry(
        'presence:watch',
        <String, dynamic>{'userId': userId},
        timeout: const Duration(seconds: 3),
        maxAttempts: 2,
      );
      if (presencePayload is Map && presencePayload['online'] != null) {
        state = state.copyWith(
          partnerOnline: presencePayload['online'] == true,
        );
      }

      state = state.copyWith(
        isLoading: false,
        threadId: thread.threadId,
        messages: _reconcileWithServerSnapshot(
          current: state.messages,
          server: thread.messages,
        ),
        joinedSocketRoom: true,
        blocked: thread.blocked,
        youBlockedUser: thread.youBlockedUser,
        blockedByUser: thread.blockedByUser,
        supportsTranslation: thread.supportsTranslation,
        supportsCorrection: thread.supportsCorrection,
      );
      unawaited(_persistCache());
      await _markThreadRead();
    } catch (error) {
      state = state.copyWith(isLoading: false, errorMessage: error.toString());
    }
  }

  Future<void> reload() async {
    await load();
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

  void setReplyTarget(ChatMessage? message) {
    state = state.copyWith(replyTargetMessage: message);
  }

  Future<bool> blockUser() async {
    if (state.youBlockedUser) return true;
    try {
      await _ref.read(directChatRepositoryProvider).blockUser(userId);
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

  Future<ChatLearningResult> translateMessage(ChatMessage message) async {
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
          .translateMessage(userId: userId, messageId: message.id, text: text);
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
      mimeType: mimeType,
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
    final socket = _ref.read(socketServiceProvider);
    if (state.joinedSocketRoom && state.threadId.isNotEmpty) {
      socket.emit('dm:leave', <String, dynamic>{'threadId': state.threadId});
    }
    socket.emit('presence:unwatch', <String, dynamic>{'userId': userId});
    socket.off('dm:message', _socketHandler);
    socket.off('dm:typing', _typingHandler);
    socket.off('presence:update', _presenceHandler);
    socket.off('dm:message:status', _statusHandler);
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
