import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_webrtc/flutter_webrtc.dart';
import 'package:file_picker/file_picker.dart';
import 'package:go_router/go_router.dart';
import 'package:image_picker/image_picker.dart';
import 'package:record/record.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:url_launcher/url_launcher.dart';

import '../../../app/localization/talkflix_localizations.dart';
import '../../../app/theme/app_theme.dart';
import '../../../core/auth/app_user.dart';
import '../../../core/auth/session_controller.dart';
import '../../../core/auth/session_state.dart';
import '../../../core/contacts/talkflix_contacts_actions.dart';
import '../../../core/config/app_config.dart';
import '../../../core/config/privacy_settings_controller.dart';
import '../../../core/config/storage_keys.dart';
import '../../../core/media/audio_message_player.dart';
import '../../../core/media/dm_incoming_ringtone.dart';
import '../../../core/media/media_permission_service.dart';
import '../../../core/media/media_utils.dart';
import '../../../core/network/api_client.dart';
import '../../../core/realtime/dm_callkit_bridge.dart';
import '../../../core/realtime/direct_call_backend_service.dart';
import '../../../core/realtime/direct_call_controller.dart';
import '../../../core/realtime/direct_call_readiness_controller.dart';
import '../../../core/realtime/direct_call_registration_controller.dart';
import '../../../core/realtime/socket_service.dart';
import '../../../core/realtime/webrtc_service.dart';
import '../../../core/widgets/app_avatar.dart';
import '../../../core/widgets/participant_action_target.dart';
import '../../../core/widgets/realtime_warning_banner.dart';
import '../../profile/presentation/profile_screen.dart';
import '../data/chat_message.dart';
import '../data/direct_chat_repository.dart';
import '../data/talk_repository.dart';
import 'chat_recipient_picker.dart';
import 'direct_chat_controller.dart';
import 'talk_inbox_screen.dart';

enum _LocalCameraUiState { off, turningOn, on, turningOff }

class DirectChatScreen extends ConsumerStatefulWidget {
  const DirectChatScreen({
    super.key,
    required this.userId,
    this.initialCallMode,
  });

  final String userId;
  final String? initialCallMode;

  @override
  ConsumerState<DirectChatScreen> createState() => _DirectChatScreenState();
}

class _DirectChatScreenState extends ConsumerState<DirectChatScreen> {
  final _composerController = TextEditingController();
  final _scrollController = ScrollController();
  final _picker = ImagePicker();
  final _audioRecorder = AudioRecorder();
  final _permissionService = MediaPermissionService();
  final _webRtcService = WebRtcService();
  final _localRenderer = RTCVideoRenderer();
  final _remoteRenderer = RTCVideoRenderer();
  late final SocketService _socketService;
  late final DmCallKitBridge _dmCallKitBridge;
  late final DirectCallBackendService _directCallBackendService;
  late final DirectChatController _chatController;
  late final DirectCallController _directCallController;
  late final Future<SharedPreferences> _sharedPreferencesFuture;
  ProviderSubscription<DirectChatState>? _chatStateSubscription;
  ProviderSubscription<DirectCallState>? _directCallStateSubscription;
  ProviderSubscription<SessionState>? _sessionStateSubscription;
  ProviderSubscription<AsyncValue<AppUser>>? _partnerProfileSubscription;

  Timer? _typingTimer;
  Timer? _recordingTimer;
  Timer? _callTimeoutTimer;
  Timer? _callDurationTimer;
  Timer? _callRecoveryTimer;
  Timer? _replyHighlightTimer;
  Future<void>? _callPreparationFuture;
  DateTime? _lastSafetyRefreshAt;

  RTCPeerConnection? _peerConnection;
  String? _localVideoSenderId;
  String? _localPreviewTrackId;
  final List<RTCIceCandidate> _pendingRemoteCandidates = [];

  int _recordingSeconds = 0;
  int _callSeconds = 0;
  bool _recording = false;
  bool _composerActionBusy = false;
  bool _composerAssistBusy = false;
  bool _renderersReady = false;
  bool _callIncoming = false;
  bool _callDialing = false;
  bool _callConnected = false;
  bool _serverCallAccepted = false;
  bool _callMinimized = false;
  bool _callInitiator = false;
  bool _updatingFollow = false;
  bool _callVideoPreferred = false;
  bool _localVideoEnabled = false;
  bool _localPreviewReady = false;
  bool _awaitingLocalPreviewFrame = false;
  int _localPreviewGeneration = 0;
  bool _remoteVideoEnabled = false;
  bool _cameraBusy = false;
  bool _localVideoMirrored = true;
  bool _micEnabled = true;
  bool _speakerOn = false;
  bool _remoteDescriptionReady = false;
  _LocalCameraUiState _localCameraUiState = _LocalCameraUiState.off;
  String _initialOfferSentForCallId = '';
  bool _threadNotificationsMuted = false;
  bool _autoTranslateIncoming = false;
  bool _autoPlayReceivedVoiceNotes = false;
  bool _enableCorrectionAction = false;
  bool _receiveVoiceCallsFromUser = false;
  bool _receiveVideoCallsFromUser = false;
  bool _initialCallHandled = false;
  String _correctionTone = 'friendly';
  bool? _followOverride;
  // Target language for translations. Defaults to the global received-message
  // translation target from Settings.
  String _translateTargetLanguage = '';
  final Map<String, String> _translatedMessageById = <String, String>{};
  final Set<String> _hiddenTranslatedMessageIds = <String>{};
  // Tracks which language each message was last translated into (for the bubble label)
  final Map<String, String> _translateLangByMessageId = <String, String>{};
  final Map<String, int> _autoPlayTokenByMessageId = <String, int>{};
  final Map<String, bool> _autoPlayBadgeVisibleByMessageId = <String, bool>{};
  int _nextAutoPlayToken = 1;
  String _socketStatus = 'disconnected';
  String? _callStatus;
  String? _pendingAudioUrl;
  int _pendingAudioDuration = 0;
  String _pendingAudioMimeType = 'audio/m4a';
  String? _highlightedMessageId;
  String _threadIdValue = '';
  String _currentCallId = '';
  String _meIdValue = '';
  DirectChatState _chatState = const DirectChatState();
  String _sessionFirstLanguage = 'English';
  String _partnerDisplayName = '';
  String _partnerPhotoUrl = '';
  bool _isDisposingOrDisposed = false;
  Map<String, dynamic>? _rtcPeerConnectionConfig;

  // One local reaction per message for the current user.
  final Map<String, String> _selectedReactionByMessageId = <String, String>{};
  // Rendered reaction chips: messageId → emoji → count
  final Map<String, Map<String, int>> _localReactions = {};
  // IDs of messages currently being translated (shows spinner inline)
  final Set<String> _translatingIds = {};
  static const int _translationCacheVersion = 2;
  static const int _reactionCacheVersion = 2;
  static const int _draftTranslateMinLength = 4;
  static const int _draftGrammarMinLength = 10;
  static const int _draftParaphraseMinLength = 20;

  String get _meId => _meIdValue;

  String get _threadId => _threadIdValue;

  SocketService get _socket => _socketService;
  String get _threadNotificationPrefKey =>
      '${StorageKeys.talkThreadMutedPrefix}${widget.userId}';
  String get _translationCacheKey =>
      '${StorageKeys.directChatCachePrefix}${widget.userId}_translations';
  String get _reactionCacheKey =>
      '${StorageKeys.directChatCachePrefix}${widget.userId}_reactions';
  bool get _hasActiveCallSession =>
      _callIncoming || _callDialing || _callConnected;
  String get _composerDraftText => _composerController.text.trim();

  @override
  void initState() {
    super.initState();
    _socketService = ref.read(socketServiceProvider);
    _dmCallKitBridge = ref.read(dmCallKitBridgeProvider);
    _directCallBackendService = ref.read(directCallBackendServiceProvider);
    _chatController = ref.read(
      directChatControllerProvider(widget.userId).notifier,
    );
    _directCallController = ref.read(directCallControllerProvider.notifier);
    _sharedPreferencesFuture = ref.read(sharedPreferencesProvider.future);
    _meIdValue = ref.read(sessionControllerProvider).user?.id ?? '';
    _sessionFirstLanguage =
        ref.read(sessionControllerProvider).user?.firstLanguage ?? 'English';
    _threadIdValue = ref
        .read(directChatControllerProvider(widget.userId))
        .threadId;
    final partner = ref.read(profileProvider(widget.userId)).valueOrNull;
    _partnerDisplayName = partner?.displayName ?? '';
    _partnerPhotoUrl = partner?.profilePhotoUrl ?? '';
    _socketStatus = _socket.status;
    _bindProviderListeners();
    _socket.addListener(_handleSocketStatusChanged);
    _composerController.addListener(_handleComposerTextChanged);
    Future<void>.microtask(_loadThreadPrefs);
    Future<void>.microtask(_initializeRealtimeBits);
    Future<void>.microtask(_maybeLaunchInitialCall);
  }

  void _bindProviderListeners() {
    _chatStateSubscription = ref.listenManual<DirectChatState>(
      directChatControllerProvider(widget.userId),
      _handleChatStateChanged,
      fireImmediately: true,
    );
    _directCallStateSubscription = ref.listenManual<DirectCallState>(
      directCallControllerProvider,
      _handleDirectCallStateChanged,
    );
    _sessionStateSubscription = ref.listenManual<SessionState>(
      sessionControllerProvider,
      _handleSessionStateChanged,
      fireImmediately: true,
    );
    _partnerProfileSubscription = ref.listenManual<AsyncValue<AppUser>>(
      profileProvider(widget.userId),
      _handlePartnerProfileChanged,
      fireImmediately: true,
    );
  }

  void _handleChatStateChanged(
    DirectChatState? previous,
    DirectChatState next,
  ) {
    if (_isDisposingOrDisposed) return;
    _chatState = next;
    _threadIdValue = next.threadId;
    if (previous?.messages.length != next.messages.length) {
      _scrollToBottom();
    }
    _pruneLocalMessageCaches(next.messages);
    _maybeAutoPlayIncomingVoiceNotes(next.messages);
    unawaited(_maybeAutoTranslateMessages(next.messages));
    unawaited(_maybeLaunchInitialCall());
  }

  Future<void> _maybeLaunchInitialCall() async {
    if (_initialCallHandled || _isDisposingOrDisposed || !mounted) return;
    final normalizedMode = (widget.initialCallMode ?? '').trim().toLowerCase();
    if (!AppConfig.directCallsEnabled ||
        (normalizedMode != 'voice' && normalizedMode != 'video')) {
      _initialCallHandled = true;
      return;
    }
    if (_threadId.isEmpty) return;
    _initialCallHandled = true;
    await Future<void>.delayed(Duration.zero);
    if (!mounted || _isDisposingOrDisposed) return;
    await _startCall(video: normalizedMode == 'video');
  }

  void _handleDirectCallStateChanged(
    DirectCallState? previous,
    DirectCallState next,
  ) {
    if (!AppConfig.directCallsEnabled) return;
    if (_isDisposingOrDisposed) return;
    final incoming = next.incoming;
    if (incoming != null && incoming.fromUserId == widget.userId) {
      final wasIncoming = previous?.incoming;
      final isSameIncoming =
          wasIncoming != null &&
          wasIncoming.threadId == incoming.threadId &&
          wasIncoming.fromUserId == incoming.fromUserId &&
          wasIncoming.callId == incoming.callId &&
          wasIncoming.video == incoming.video;
      if (!isSameIncoming) {
        _currentCallId = incoming.callId;
        _threadIdValue = incoming.threadId;
        _callVideoPreferred = incoming.video;
        if (!DmCallKitBridge.enabled) {
          unawaited(DmIncomingRingtone.start());
        }
        if (mounted) {
          setState(() {
            _callMinimized = false;
            _callIncoming = true;
            _callDialing = false;
            _callConnected = false;
            _callInitiator = false;
            _callStatus = incoming.video
                ? 'Incoming video call'
                : 'Incoming voice call';
          });
        }
      }
    }
    final pending = next.pendingAccepted;
    if (pending == null || pending.partnerId != widget.userId) return;
    final was = previous?.pendingAccepted;
    if (was != null &&
        was.threadId == pending.threadId &&
        was.partnerId == pending.partnerId) {
      return;
    }
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted || _isDisposingOrDisposed) return;
      unawaited(_resumeAcceptedGlobalCallIfNeeded());
    });
  }

  void _handleSessionStateChanged(SessionState? previous, SessionState next) {
    if (_isDisposingOrDisposed) return;
    _meIdValue = next.user?.id ?? '';
    _sessionFirstLanguage = next.user?.firstLanguage ?? 'English';
  }

  void _handlePartnerProfileChanged(
    AsyncValue<AppUser>? previous,
    AsyncValue<AppUser> next,
  ) {
    if (_isDisposingOrDisposed) return;
    final user = next.valueOrNull;
    _partnerDisplayName = user?.displayName ?? '';
    _partnerPhotoUrl = user?.profilePhotoUrl ?? '';
  }

  Future<void> _stopIncomingRingtone() async {
    await DmIncomingRingtone.stop();
  }

  void _appendCallEventToHistory({
    required String eventKey,
    required String text,
    String? threadId,
    String callId = '',
    DateTime? createdAt,
  }) {
    final normalizedThreadId = threadId?.trim() ?? '';
    final effectiveThreadId = normalizedThreadId.isNotEmpty
        ? normalizedThreadId
        : _threadId;
    if (effectiveThreadId.isEmpty) {
      return;
    }
    _chatController.appendLocalCallEvent(
      threadId: effectiveThreadId,
      callId: callId,
      eventKey: eventKey,
      text: text,
      createdAt: createdAt,
    );
  }

  Future<Map<String, dynamic>> _peerConnectionConfig() async {
    final cached = _rtcPeerConnectionConfig;
    if (cached != null) return cached;
    try {
      final rtcConfig = await _directCallBackendService.fetchRtcConfig();
      final resolved = rtcConfig?.config ?? AppConfig.rtcPeerConnectionConfig;
      _rtcPeerConnectionConfig = Map<String, dynamic>.from(resolved);
    } catch (_) {
      _rtcPeerConnectionConfig = Map<String, dynamic>.from(
        AppConfig.rtcPeerConnectionConfig,
      );
    }
    return _rtcPeerConnectionConfig!;
  }

  Future<void> _syncCurrentCallSession() async {
    final threadId = _threadId;
    if (threadId.isEmpty || _isDisposingOrDisposed) return;
    try {
      final session = await _directCallBackendService.fetchCurrentSession(
        threadId,
      );
      if (!mounted || _isDisposingOrDisposed || session == null) return;
      _currentCallId = session.callId;
      _serverCallAccepted =
          session.state == 'accepted' || session.state == 'active';
      if (!_hasActiveCallSession) {
        _callVideoPreferred = session.wantsVideo;
      }
    } catch (_) {}
  }

  Future<void> _loadThreadPrefs() async {
    final prefs = await _sharedPreferencesFuture;
    final savedLang = prefs.getString(StorageKeys.chatTranslateTargetLanguage);
    final globalCallPrefs = ref.read(privacySettingsControllerProvider);
    var directChatCallPrefs = DirectChatCallPreferences(
      receiveVoiceCalls: globalCallPrefs.receiveVoiceCalls,
      receiveVideoCalls: globalCallPrefs.receiveVideoCalls,
    );
    if (AppConfig.directCallsEnabled) {
      try {
        directChatCallPrefs = await ref
            .read(directChatRepositoryProvider)
            .fetchDirectChatCallPreferences(widget.userId);
      } catch (_) {}
    }
    final resolvedTranslateTarget = (savedLang != null && savedLang.isNotEmpty)
        ? savedLang
        : _sessionFirstLanguage;
    if (!mounted) return;
    setState(() {
      _threadNotificationsMuted =
          prefs.getBool(_threadNotificationPrefKey) ?? false;
      _autoTranslateIncoming =
          prefs.getBool(StorageKeys.chatAutoTranslateIncoming) ?? false;
      _autoPlayReceivedVoiceNotes =
          prefs.getBool(StorageKeys.chatPlayVoiceNotesAuto) ?? false;
      _enableCorrectionAction =
          prefs.getBool(StorageKeys.chatEnableWritingCorrections) ?? false;
      _receiveVoiceCallsFromUser = directChatCallPrefs.receiveVoiceCalls;
      _receiveVideoCallsFromUser = directChatCallPrefs.receiveVideoCalls;
      _correctionTone =
          prefs.getString(StorageKeys.chatCorrectionTone) ?? 'friendly';
      _translateTargetLanguage = resolvedTranslateTarget;
    });
    await _loadPersistedTranslations();
    await _loadPersistedReactions();
  }

  String _normalizeLanguageKey(String value) => value.trim().toLowerCase();

  String get _effectiveTranslateTargetLanguage =>
      _translateTargetLanguage.trim().isEmpty
      ? 'English'
      : _translateTargetLanguage.trim();

  Future<void> _loadPersistedTranslations() async {
    final prefs = await _sharedPreferencesFuture;
    final raw = prefs.getString(_translationCacheKey);
    if (raw == null || raw.trim().isEmpty || !mounted) return;
    try {
      final decoded = jsonDecode(raw);
      if (decoded is! Map<String, dynamic>) return;
      final version = (decoded['version'] as num?)?.toInt() ?? 0;
      final cacheTargetLanguage = decoded['targetLanguage']?.toString() ?? '';
      if (version < _translationCacheVersion ||
          _normalizeLanguageKey(cacheTargetLanguage) !=
              _normalizeLanguageKey(_effectiveTranslateTargetLanguage)) {
        await prefs.remove(_translationCacheKey);
        return;
      }
      final items = decoded['items'];
      if (items is! Map<String, dynamic>) return;
      setState(() {
        for (final entry in items.entries) {
          final value = entry.value;
          if (value is! Map<String, dynamic>) continue;
          final text = value['text']?.toString().trim() ?? '';
          if (text.isEmpty) continue;
          _translatedMessageById[entry.key] = text;
          final language = value['language']?.toString().trim() ?? '';
          if (language.isNotEmpty) {
            _translateLangByMessageId[entry.key] = language;
          }
          if (value['hidden'] == true) {
            _hiddenTranslatedMessageIds.add(entry.key);
          } else {
            _hiddenTranslatedMessageIds.remove(entry.key);
          }
        }
      });
    } catch (_) {
      await prefs.remove(_translationCacheKey);
    }
  }

  Future<void> _loadPersistedReactions() async {
    final prefs = await _sharedPreferencesFuture;
    final raw = prefs.getString(_reactionCacheKey);
    if (raw == null || raw.trim().isEmpty || !mounted) return;
    try {
      final decoded = jsonDecode(raw);
      if (decoded is! Map<String, dynamic>) return;
      final version = (decoded['version'] as num?)?.toInt() ?? 0;
      if (version < _reactionCacheVersion) {
        await prefs.remove(_reactionCacheKey);
        return;
      }
      final items = decoded['items'];
      if (items is! Map<String, dynamic>) return;
      setState(() {
        for (final entry in items.entries) {
          final emoji = entry.value?.toString().trim() ?? '';
          if (emoji.isEmpty) continue;
          _selectedReactionByMessageId[entry.key] = emoji;
          _localReactions[entry.key] = <String, int>{emoji: 1};
        }
      });
    } catch (_) {
      await prefs.remove(_reactionCacheKey);
    }
  }

  Future<void> _persistTranslationCache() async {
    final prefs = await _sharedPreferencesFuture;
    if (_translatedMessageById.isEmpty) {
      await prefs.remove(_translationCacheKey);
      return;
    }
    final currentMessages = _chatState.messages;
    final validIds = currentMessages
        .map((message) => message.id)
        .where((id) => id.isNotEmpty)
        .toSet();
    final payloadItems = <String, dynamic>{};
    for (final entry in _translatedMessageById.entries) {
      if (validIds.isNotEmpty && !validIds.contains(entry.key)) continue;
      final text = entry.value.trim();
      if (text.isEmpty) continue;
      payloadItems[entry.key] = <String, dynamic>{
        'text': text,
        'language': _translateLangByMessageId[entry.key] ?? '',
        'hidden': _hiddenTranslatedMessageIds.contains(entry.key),
      };
    }
    if (payloadItems.isEmpty) {
      await prefs.remove(_translationCacheKey);
      return;
    }
    await prefs.setString(
      _translationCacheKey,
      jsonEncode(<String, dynamic>{
        'version': _translationCacheVersion,
        'targetLanguage': _effectiveTranslateTargetLanguage,
        'updatedAt': DateTime.now().toIso8601String(),
        'items': payloadItems,
      }),
    );
  }

  Future<void> _persistReactionCache() async {
    final prefs = await _sharedPreferencesFuture;
    if (_selectedReactionByMessageId.isEmpty) {
      await prefs.remove(_reactionCacheKey);
      return;
    }
    final currentMessages = _chatState.messages;
    final validIds = currentMessages
        .map((message) => message.id)
        .where((id) => id.isNotEmpty)
        .toSet();
    final payloadItems = <String, dynamic>{};
    for (final entry in _selectedReactionByMessageId.entries) {
      if (validIds.isNotEmpty && !validIds.contains(entry.key)) continue;
      final emoji = entry.value.trim();
      if (emoji.isEmpty) continue;
      payloadItems[entry.key] = emoji;
    }
    if (payloadItems.isEmpty) {
      await prefs.remove(_reactionCacheKey);
      return;
    }
    await prefs.setString(
      _reactionCacheKey,
      jsonEncode(<String, dynamic>{
        'version': _reactionCacheVersion,
        'updatedAt': DateTime.now().toIso8601String(),
        'items': payloadItems,
      }),
    );
  }

  Future<void> _syncTranslationTargetLanguage() async {
    final prefs = await _sharedPreferencesFuture;
    final savedLang = prefs.getString(StorageKeys.chatTranslateTargetLanguage);
    final resolved = (savedLang != null && savedLang.isNotEmpty)
        ? savedLang
        : _sessionFirstLanguage;
    if (!mounted) return;
    if (_normalizeLanguageKey(resolved) ==
        _normalizeLanguageKey(_effectiveTranslateTargetLanguage)) {
      return;
    }
    setState(() {
      _translateTargetLanguage = resolved;
      _translatedMessageById.clear();
      _translateLangByMessageId.clear();
      _hiddenTranslatedMessageIds.clear();
      _translatingIds.clear();
    });
    await prefs.remove(_translationCacheKey);
  }

  void _toggleMessageReaction(String messageId, String emoji) {
    final normalizedEmoji = emoji.trim();
    if (normalizedEmoji.isEmpty) return;
    setState(() {
      final currentEmoji = _selectedReactionByMessageId[messageId];
      if (currentEmoji == normalizedEmoji) {
        _selectedReactionByMessageId.remove(messageId);
        _localReactions.remove(messageId);
        return;
      }
      _selectedReactionByMessageId[messageId] = normalizedEmoji;
      _localReactions[messageId] = <String, int>{normalizedEmoji: 1};
    });
    unawaited(
      _chatController.toggleReaction(
        messageId: messageId,
        emoji: normalizedEmoji,
      ),
    );
    unawaited(_persistReactionCache());
  }

  void _pruneLocalMessageCaches(List<ChatMessage> messages) {
    final validIds = messages
        .map((message) => message.id)
        .where((id) => id.isNotEmpty)
        .toSet();
    if (validIds.isEmpty) return;
    var translationChanged = false;
    _translatedMessageById.removeWhere((messageId, _) {
      final shouldRemove = !validIds.contains(messageId);
      translationChanged = translationChanged || shouldRemove;
      return shouldRemove;
    });
    _translateLangByMessageId.removeWhere((messageId, _) {
      final shouldRemove = !validIds.contains(messageId);
      translationChanged = translationChanged || shouldRemove;
      return shouldRemove;
    });
    _hiddenTranslatedMessageIds.removeWhere((messageId) {
      final shouldRemove = !validIds.contains(messageId);
      translationChanged = translationChanged || shouldRemove;
      return shouldRemove;
    });
    var reactionChanged = false;
    _selectedReactionByMessageId.removeWhere((messageId, _) {
      final shouldRemove = !validIds.contains(messageId);
      reactionChanged = reactionChanged || shouldRemove;
      return shouldRemove;
    });
    _localReactions.removeWhere((messageId, _) {
      final shouldRemove = !validIds.contains(messageId);
      reactionChanged = reactionChanged || shouldRemove;
      return shouldRemove;
    });
    if (!translationChanged && !reactionChanged) return;
    if (mounted) {
      setState(() {});
    }
    if (translationChanged) {
      unawaited(_persistTranslationCache());
    }
    if (reactionChanged) {
      unawaited(_persistReactionCache());
    }
  }

  Future<void> _maybeAutoTranslateMessages(List<ChatMessage> messages) async {
    if (!_autoTranslateIncoming) return;
    final meId = _meId;
    final targets = messages
        .where(
          (m) =>
              m.fromUserId != meId &&
              m.type == 'text' &&
              m.text.trim().isNotEmpty &&
              !_translatedMessageById.containsKey(m.id),
        )
        .toList(growable: false);
    if (targets.isEmpty) return;
    final controller = _chatController;
    final lang = _effectiveTranslateTargetLanguage;
    final requestedLanguageKey = _normalizeLanguageKey(lang);
    for (final message in targets) {
      final result = await controller.translateMessage(
        message,
        targetLanguage: lang,
      );
      if (!mounted) return;
      if (_normalizeLanguageKey(_effectiveTranslateTargetLanguage) !=
          requestedLanguageKey) {
        continue;
      }
      final translated = result.output.trim();
      if (translated.isEmpty) continue;
      setState(() {
        _translatedMessageById[message.id] = translated;
        _translateLangByMessageId[message.id] =
            result.targetLanguage.trim().isNotEmpty
            ? result.targetLanguage.trim()
            : lang;
        _hiddenTranslatedMessageIds.remove(message.id);
      });
      unawaited(_persistTranslationCache());
    }
  }

  void _maybeAutoPlayIncomingVoiceNotes(List<ChatMessage> messages) {
    if (!_autoPlayReceivedVoiceNotes) return;
    final meId = _meId;
    var changed = false;
    for (final message in messages) {
      if (message.fromUserId == meId) continue;
      if (message.type != 'audio' || message.audioUrl.isEmpty) continue;
      if (_autoPlayTokenByMessageId.containsKey(message.id)) continue;
      _autoPlayTokenByMessageId[message.id] = _nextAutoPlayToken++;
      _autoPlayBadgeVisibleByMessageId[message.id] = true;
      changed = true;
    }
    if (!changed || !mounted) return;
    setState(() {});
  }

  void _onIncomingAudioPlaybackCompleted(String messageId) {
    if (!_autoPlayReceivedVoiceNotes) return;
    if (_autoPlayBadgeVisibleByMessageId[messageId] != true) return;
    if (!mounted) return;
    setState(() {
      _autoPlayBadgeVisibleByMessageId[messageId] = false;
    });
  }

  void _onIncomingAudioPlaybackStarted(String messageId) {
    if (_autoPlayBadgeVisibleByMessageId[messageId] != true) return;
    if (!mounted) return;
    setState(() {
      _autoPlayBadgeVisibleByMessageId[messageId] = false;
    });
  }

  Future<void> _initializeRealtimeBits() async {
    await _localRenderer.initialize();
    if (_isDisposingOrDisposed || !mounted) return;
    _localRenderer.onFirstFrameRendered = () {
      _handleLocalRendererFrameUpdate(frameRendered: true);
    };
    _localRenderer.onResize = _handleLocalRendererFrameUpdate;
    await _remoteRenderer.initialize();
    if (_isDisposingOrDisposed || !mounted) return;
    _socket.on('dm:call:request', _onCallRequest);
    _socket.on('dm:call:accept', _onCallAccept);
    _socket.on('dm:call:ready', _onCallReady);
    _socket.on('dm:rtc:offer', _onRtcOffer);
    _socket.on('dm:rtc:answer', _onRtcAnswer);
    _socket.on('dm:rtc:ice', _onRtcIce);
    _socket.on('dm:call:connected', _onCallConnected);
    _socket.on('dm:call:end', _onCallEnded);
    _socket.on('dm:call:cancel', _onCallCancelled);
    _socket.on('dm:call:missed', _onCallMissed);
    _socket.on('dm:call:camera-state', _onRemoteCameraState);
    if (mounted) {
      setState(() => _renderersReady = true);
    }
    await _syncCurrentCallSession();
    await _resumeAcceptedGlobalCallIfNeeded();
  }

  void _handleLocalRendererFrameUpdate({bool frameRendered = false}) {
    final hasPreviewSource =
        _localRenderer.srcObject != null &&
        _localPreviewTrackId != null &&
        _localPreviewTrackId!.isNotEmpty &&
        _localVideoEnabledForUi;
    if (!hasPreviewSource) {
      if (!_localPreviewReady && !_awaitingLocalPreviewFrame) return;
      _localPreviewReady = false;
      _awaitingLocalPreviewFrame = false;
      if (mounted) {
        setState(() {});
      }
      return;
    }
    final hasSizedFrame =
        _localRenderer.videoWidth > 0 ||
        _localRenderer.videoHeight > 0 ||
        _localRenderer.value.width > 0 ||
        _localRenderer.value.height > 0;
    final nextReady = frameRendered || hasSizedFrame;
    if (!nextReady || (!_awaitingLocalPreviewFrame && _localPreviewReady)) {
      return;
    }
    _awaitingLocalPreviewFrame = false;
    if (_localPreviewReady) return;
    _localPreviewReady = true;
    if (mounted) {
      setState(() {});
    }
  }

  Future<void> _resumeAcceptedGlobalCallIfNeeded() async {
    if (_isDisposingOrDisposed) return;
    final pending = _directCallController.consumePendingForPartner(
      widget.userId,
    );
    if (pending == null) return;
    await _runAcceptedIncomingHandoff(
      threadId: pending.threadId,
      callId: pending.callId,
      video: pending.video,
      dismissNativeSurface: false,
      failureMessage: 'Could not connect call.',
    );
  }

  @override
  void dispose() {
    _isDisposingOrDisposed = true;
    _typingTimer?.cancel();
    _recordingTimer?.cancel();
    _callTimeoutTimer?.cancel();
    _callDurationTimer?.cancel();
    _callRecoveryTimer?.cancel();
    _replyHighlightTimer?.cancel();
    _chatStateSubscription?.close();
    _directCallStateSubscription?.close();
    _sessionStateSubscription?.close();
    _partnerProfileSubscription?.close();
    _composerController.dispose();
    _scrollController.dispose();
    _audioRecorder.dispose();
    _socket.off('dm:call:request', _onCallRequest);
    _socket.off('dm:call:accept', _onCallAccept);
    _socket.off('dm:call:ready', _onCallReady);
    _socket.off('dm:rtc:offer', _onRtcOffer);
    _socket.off('dm:rtc:answer', _onRtcAnswer);
    _socket.off('dm:rtc:ice', _onRtcIce);
    _socket.off('dm:call:connected', _onCallConnected);
    _socket.off('dm:call:end', _onCallEnded);
    _socket.off('dm:call:cancel', _onCallCancelled);
    _socket.off('dm:call:missed', _onCallMissed);
    _socket.off('dm:call:camera-state', _onRemoteCameraState);
    _socket.removeListener(_handleSocketStatusChanged);
    _composerController.removeListener(_handleComposerTextChanged);
    unawaited(_cleanupCall(sendSignal: false));
    _localRenderer.dispose();
    _remoteRenderer.dispose();
    super.dispose();
  }

  Future<void> _send() async {
    final text = _composerController.text;
    if (text.trim().isEmpty) return;
    _composerController.clear();
    _chatController.sendTyping(false);
    await _chatController.sendTextMessage(text);
    if (!mounted) return;
    FocusScope.of(context).unfocus();
    _scrollToBottom();
  }

  Future<void> _pickAndSendImage() async {
    final allowed = await _permissionService.ensurePhotos();
    if (!allowed) return;
    final file = await _picker.pickImage(
      source: ImageSource.gallery,
      imageQuality: 86,
      maxWidth: 1800,
    );
    if (file == null) return;
    final bytes = await file.readAsBytes();
    await _chatController.sendImageMessage(
      bytes: bytes,
      mimeType: file.mimeType ?? 'image/jpeg',
    );
    _scrollToBottom();
  }

  Future<void> _openAttachmentMenu() async {
    final choice = await showModalBottomSheet<String>(
      context: context,
      showDragHandle: true,
      builder: (sheetContext) {
        return SafeArea(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              ListTile(
                leading: const Icon(Icons.image_outlined),
                title: const Text('Photo or video'),
                onTap: () => Navigator.of(sheetContext).pop('media'),
              ),
              ListTile(
                leading: const Icon(Icons.attach_file_rounded),
                title: const Text('Document'),
                subtitle: const Text('PDF, Word, Excel, PowerPoint, text'),
                onTap: () => Navigator.of(sheetContext).pop('file'),
              ),
            ],
          ),
        );
      },
    );
    if (!mounted || choice == null) return;
    if (choice == 'media') {
      await _pickAndSendImage();
      return;
    }
    await _pickAndSendFile();
  }

  Future<void> _pickAndSendFile() async {
    final result = await FilePicker.platform.pickFiles(
      type: FileType.custom,
      allowedExtensions: const [
        'pdf',
        'doc',
        'docx',
        'xls',
        'xlsx',
        'ppt',
        'pptx',
        'txt',
        'csv',
        'rtf',
        'jpg',
        'jpeg',
        'png',
        'webp',
        'gif',
        'm4a',
        'mp3',
        'wav',
        'mp4',
        'mov',
      ],
      withData: true,
    );
    final file = result == null || result.files.isEmpty
        ? null
        : result.files.first;
    if (file == null) return;
    var bytes = file.bytes;
    if (bytes == null && file.path != null) {
      bytes = await XFile(file.path!).readAsBytes();
    }
    if (bytes == null || bytes.isEmpty) {
      _showSnack('That file could not be prepared.');
      return;
    }
    if (bytes.length > 25 * 1024 * 1024) {
      _showSnack('Files must be 25 MB or smaller.');
      return;
    }
    await _chatController.sendFileMessage(
      bytes: bytes,
      fileName: file.name,
      mimeType: _mimeTypeForAttachment(file.name, file.extension),
    );
    if (!mounted) return;
    _scrollToBottom();
  }

  String _mimeTypeForAttachment(String fileName, String? extension) {
    final ext = (extension ?? fileName.split('.').last).toLowerCase().trim();
    const mimeByExt = <String, String>{
      'pdf': 'application/pdf',
      'doc': 'application/msword',
      'docx':
          'application/vnd.openxmlformats-officedocument.wordprocessingml.document',
      'xls': 'application/vnd.ms-excel',
      'xlsx':
          'application/vnd.openxmlformats-officedocument.spreadsheetml.sheet',
      'ppt': 'application/vnd.ms-powerpoint',
      'pptx':
          'application/vnd.openxmlformats-officedocument.presentationml.presentation',
      'txt': 'text/plain',
      'csv': 'text/csv',
      'rtf': 'application/rtf',
      'jpg': 'image/jpeg',
      'jpeg': 'image/jpeg',
      'png': 'image/png',
      'webp': 'image/webp',
      'gif': 'image/gif',
      'm4a': 'audio/m4a',
      'mp3': 'audio/mpeg',
      'wav': 'audio/wav',
      'mp4': 'video/mp4',
      'mov': 'video/quicktime',
    };
    return mimeByExt[ext] ?? 'application/octet-stream';
  }

  Future<void> _toggleRecording() async {
    if (_composerActionBusy) return;
    if (_recording) {
      _composerActionBusy = true;
      try {
        final path = await _audioRecorder.stop();
        _recordingTimer?.cancel();
        setState(() => _recording = false);
        if (path == null) {
          setState(() => _recordingSeconds = 0);
          return;
        }
        final bytes = await XFile(path).readAsBytes();
        if (bytes.isEmpty) {
          setState(() => _recordingSeconds = 0);
          _showSnack('That voice note was empty.');
          return;
        }
        setState(() {
          _pendingAudioUrl = bytesToDataUrl(bytes, 'audio/m4a');
          _pendingAudioDuration = _recordingSeconds.clamp(1, 60);
          _pendingAudioMimeType = 'audio/m4a';
          _recordingSeconds = 0;
        });
      } finally {
        _composerActionBusy = false;
      }
      return;
    }

    _composerActionBusy = true;
    try {
      final hasPermission = await _audioRecorder.hasPermission();
      final allowed =
          hasPermission || await _permissionService.ensureMicrophone();
      final recorderAllowed = allowed && await _audioRecorder.hasPermission();
      if (!recorderAllowed) {
        _showSnack('Microphone permission is required to record voice notes.');
        return;
      }
      final tempDir = Directory.systemTemp;
      final path =
          '${tempDir.path}/voice_${DateTime.now().millisecondsSinceEpoch}.m4a';
      setState(() {
        _pendingAudioUrl = null;
        _pendingAudioDuration = 0;
      });
      await _audioRecorder.start(
        const RecordConfig(encoder: AudioEncoder.aacLc),
        path: path,
      );
      final started = await _audioRecorder.isRecording();
      if (!started) {
        _showSnack('Could not start recording right now.');
        return;
      }
      setState(() {
        _recording = true;
        _recordingSeconds = 0;
      });
      _recordingTimer?.cancel();
      _recordingTimer = Timer.periodic(const Duration(seconds: 1), (_) {
        if (!mounted) return;
        if (_recordingSeconds >= 60) {
          unawaited(_toggleRecording());
          return;
        }
        setState(() => _recordingSeconds += 1);
      });
    } finally {
      _composerActionBusy = false;
    }
  }

  Future<void> _sendPendingAudio() async {
    final audioUrl = _pendingAudioUrl;
    if (audioUrl == null || audioUrl.isEmpty) return;
    final bytes = tryDecodeDataUrl(audioUrl);
    if (bytes == null || bytes.isEmpty) {
      _showSnack('That voice note could not be prepared.');
      return;
    }
    await _chatController.sendAudioMessage(
      bytes: bytes,
      mimeType: _pendingAudioMimeType,
      durationSeconds: _pendingAudioDuration,
    );
    if (!mounted) return;
    setState(() {
      _pendingAudioUrl = null;
      _pendingAudioDuration = 0;
      _pendingAudioMimeType = 'audio/m4a';
    });
    FocusScope.of(context).unfocus();
    _scrollToBottom();
  }

  void _discardPendingAudio() {
    setState(() {
      _pendingAudioUrl = null;
      _pendingAudioDuration = 0;
      _pendingAudioMimeType = 'audio/m4a';
    });
  }

  String? _draftAssistDisabledReason(
    _DraftAssistAction action,
    DirectChatState chatState, {
    String? draft,
  }) {
    final currentDraft = (draft ?? _composerDraftText).trim();
    final draftLength = currentDraft.length;
    if (currentDraft.isEmpty) {
      return 'Type a message before using draft tools.';
    }
    return switch (action) {
      _DraftAssistAction.translate =>
        !chatState.supportsTranslation
            ? 'Translation is not available for this chat yet.'
            : draftLength < _draftTranslateMinLength
            ? 'Translate needs at least $_draftTranslateMinLength characters.'
            : null,
      _DraftAssistAction.grammar =>
        !chatState.supportsCorrection
            ? 'Grammar check is not available for this chat yet.'
            : draftLength < _draftGrammarMinLength
            ? 'Grammar check needs at least $_draftGrammarMinLength characters.'
            : null,
      _DraftAssistAction.paraphrase =>
        draftLength < _draftParaphraseMinLength
            ? 'Paraphrase needs at least $_draftParaphraseMinLength characters.'
            : null,
    };
  }

  String _draftAssistSubtitle(
    _DraftAssistAction action,
    DirectChatState chatState, {
    String? draft,
  }) {
    final disabledReason = _draftAssistDisabledReason(
      action,
      chatState,
      draft: draft,
    );
    if (disabledReason != null) return disabledReason;
    return switch (action) {
      _DraftAssistAction.translate =>
        'Translate into $_effectiveTranslateTargetLanguage',
      _DraftAssistAction.grammar => 'Fix grammar before sending',
      _DraftAssistAction.paraphrase => 'Rewrite the draft before sending',
    };
  }

  String _draftAssistAppliedMessage(_DraftAssistAction action) {
    return switch (action) {
      _DraftAssistAction.translate => 'Translation applied to your draft.',
      _DraftAssistAction.grammar => 'Grammar suggestion applied.',
      _DraftAssistAction.paraphrase => 'Paraphrase applied to your draft.',
    };
  }

  String _draftAssistEmptyResultMessage(_DraftAssistAction action) {
    return switch (action) {
      _DraftAssistAction.translate => 'No translation was returned.',
      _DraftAssistAction.grammar => 'No grammar suggestion was returned.',
      _DraftAssistAction.paraphrase => 'No paraphrase was returned.',
    };
  }

  Future<void> _openDraftAssistMenu() async {
    if (_composerAssistBusy) return;
    final chatState = _chatState;
    final draft = _composerDraftText;
    if (draft.isEmpty) {
      _showSnack('Type a message before using draft tools.');
      return;
    }
    final selection = await showModalBottomSheet<_DraftAssistAction>(
      context: context,
      showDragHandle: true,
      builder: (context) => SafeArea(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            ListTile(
              title: Text(
                'Draft tools',
                style: Theme.of(
                  context,
                ).textTheme.titleMedium?.copyWith(fontWeight: FontWeight.w800),
              ),
              subtitle: const Text('Choose how to refine this message.'),
            ),
            for (final action in _DraftAssistAction.values)
              ListTile(
                enabled:
                    _draftAssistDisabledReason(
                      action,
                      chatState,
                      draft: draft,
                    ) ==
                    null,
                leading: Icon(action.icon),
                title: Text(action.label),
                subtitle: Text(
                  _draftAssistSubtitle(action, chatState, draft: draft),
                ),
                onTap:
                    _draftAssistDisabledReason(
                          action,
                          chatState,
                          draft: draft,
                        ) ==
                        null
                    ? () => Navigator.of(context).pop(action)
                    : null,
              ),
            const SizedBox(height: 8),
          ],
        ),
      ),
    );
    if (selection == null || !mounted) return;
    await _applyDraftAssist(selection);
  }

  Future<void> _applyDraftAssist(_DraftAssistAction action) async {
    final chatState = _chatState;
    final draft = _composerDraftText;
    final disabledReason = _draftAssistDisabledReason(
      action,
      chatState,
      draft: draft,
    );
    if (disabledReason != null) {
      _showSnack(disabledReason);
      return;
    }
    final controller = _chatController;
    setState(() => _composerAssistBusy = true);
    try {
      final result = switch (action) {
        _DraftAssistAction.translate => await controller.translateDraft(
          text: draft,
          targetLanguage: _effectiveTranslateTargetLanguage,
        ),
        _DraftAssistAction.grammar => await controller.correctDraft(
          text: draft,
          tone: _correctionTone,
        ),
        _DraftAssistAction.paraphrase => await controller.paraphraseDraft(
          text: draft,
        ),
      };
      if (!mounted) return;
      final output = result.output.trim();
      if (output.isEmpty) {
        _showSnack(
          result.note.trim().isNotEmpty
              ? result.note.trim()
              : _draftAssistEmptyResultMessage(action),
        );
        return;
      }
      _composerController.value = TextEditingValue(
        text: output,
        selection: TextSelection.collapsed(offset: output.length),
      );
      _handleDraftChanged(output);
      _showSnack(_draftAssistAppliedMessage(action));
    } finally {
      if (mounted) {
        setState(() => _composerAssistBusy = false);
      }
    }
  }

  void _handleDraftChanged(String value) {
    if (mounted) setState(() {});
    if (!_socket.isConnected) return;
    final controller = _chatController;
    controller.sendTyping(value.trim().isNotEmpty);
    _typingTimer?.cancel();
    _typingTimer = Timer(const Duration(milliseconds: 900), () {
      controller.sendTyping(false);
    });
  }

  void _handleComposerTextChanged() {
    if (!mounted) return;
    setState(() {});
  }

  void _handleComposerPrimaryAction() {
    if (_composerController.text.trim().isNotEmpty) {
      unawaited(_send());
      return;
    }
    if (_pendingAudioUrl != null) {
      unawaited(_sendPendingAudio());
      return;
    }
    unawaited(_toggleRecording());
  }

  Future<bool> _ensureDirectCallFeatureReady() async {
    final readiness = ref.read(directCallReadinessProvider);
    if (readiness.canUseForegroundDirectCalls) {
      return true;
    }
    ref.invalidate(directCallServerReadinessProvider);
    unawaited(
      ref.read(directCallRegistrationControllerProvider.notifier).sync(),
    );
    _showSnack(readiness.foregroundUserMessage);
    return false;
  }

  void _startCallRecoveryWindow({
    required String status,
    String timeoutMessage = 'Call connection was lost. Please try again.',
  }) {
    _callRecoveryTimer?.cancel();
    if (mounted) {
      setState(() => _callStatus = status);
    }
    _callRecoveryTimer = Timer(const Duration(seconds: 12), () async {
      if (!mounted || !_hasActiveCallSession) return;
      _showSnack(timeoutMessage);
      await _cleanupCall(sendSignal: false);
    });
  }

  void _clearCallRecoveryWindow() {
    _callRecoveryTimer?.cancel();
    _callRecoveryTimer = null;
  }

  Future<void> _attemptIceRestart() async {
    if (_peerConnection == null ||
        _threadId.isEmpty ||
        _currentCallId.trim().isEmpty ||
        !_callConnected) {
      return;
    }
    try {
      final restartOffer = await _peerConnection!.createOffer(<String, dynamic>{
        'iceRestart': true,
      });
      await _peerConnection!.setLocalDescription(restartOffer);
      _socket.emit('dm:rtc:offer', <String, dynamic>{
        'threadId': _threadId,
        'callId': _currentCallId,
        'sdp': restartOffer.toMap(),
      });
    } catch (_) {}
  }

  Future<void> _startCall({required bool video}) async {
    if (!AppConfig.directCallsEnabled) {
      _showSnack('Direct calls are not available in this app version.');
      return;
    }
    if (_threadId.isEmpty || _callDialing || _callConnected) return;
    _serverCallAccepted = false;
    final featureReady = await _ensureDirectCallFeatureReady();
    if (!featureReady) return;
    if (!_socket.isConnected) {
      _showSnack('You are offline. Reconnect before starting a call.');
      return;
    }
    final permissionsGranted = await _ensureDirectCallPermissions(video: video);
    if (!permissionsGranted) {
      _showSnack(
        video
            ? 'Camera and microphone permission are required for video calls.'
            : 'Microphone permission is required for calls.',
      );
      return;
    }
    final payload = await _socket.emitWithAckRetry(
      'dm:call:request',
      <String, dynamic>{'threadId': _threadId, 'video': video},
      timeout: const Duration(seconds: 5),
      maxAttempts: 2,
    );
    if (!mounted || payload is! Map || payload['ok'] != true) {
      _showSnack(
        payload is Map
            ? '${payload['message'] ?? 'Could not start call.'}'
            : 'Call request timed out. Please try again.',
      );
      unawaited(_cleanupCall(sendSignal: false));
      return;
    }
    _currentCallId = '${payload['callId'] ?? ''}'.trim();
    _initialOfferSentForCallId = '';
    if (DmCallKitBridge.enabled) {
      final calleeName = _partnerDisplayName;
      final avatar = _partnerPhotoUrl;
      unawaited(
        _dmCallKitBridge.startOutgoingDmCall(
          callId: _currentCallId,
          threadId: _threadId,
          toUserId: widget.userId,
          video: video,
          calleeName: calleeName.isEmpty ? 'Talkflix' : calleeName,
          avatarUrl: avatar.isEmpty ? null : avatar,
        ),
      );
    }
    setState(() {
      _callMinimized = false;
      _callDialing = true;
      _callInitiator = true;
      _callIncoming = false;
      _callVideoPreferred = video;
      _callStatus = 'Ringing...';
    });
    _startCallTimeout(
      'No answer yet. You can keep chatting and try the call again.',
    );
    try {
      await _ensurePreparedCall(video: video);
    } catch (_) {
      _showSnack('Could not start call.');
      unawaited(_cleanupCall(sendSignal: false));
    }
  }

  Future<void> _acceptIncomingCall() async {
    final chatState = _chatState;
    if (chatState.blocked) {
      _showSnack(
        chatState.youBlockedUser
            ? 'This user is blocked. Unblock to accept calls.'
            : 'This chat is unavailable for calls right now.',
      );
      _declineIncomingCall();
      return;
    }
    final featureReady = await _ensureDirectCallFeatureReady();
    if (!featureReady) {
      _declineIncomingCall();
      return;
    }
    await _stopIncomingRingtone();
    final threadId = _threadId;
    _directCallController.startAcceptedHandoff(
      threadId: threadId,
      partnerId: widget.userId,
      callId: _currentCallId,
      video: _callVideoPreferred,
    );
    await _dmCallKitBridge.dismissIncomingUiForAcceptedCall(
      threadId: threadId,
      callId: _currentCallId,
    );
    await _runAcceptedIncomingHandoff(
      threadId: threadId,
      callId: _currentCallId,
      video: _callVideoPreferred,
      dismissNativeSurface: false,
      failureMessage: 'Could not accept call.',
    );
  }

  Future<void> _runAcceptedIncomingHandoff({
    required String threadId,
    required String callId,
    required bool video,
    required bool dismissNativeSurface,
    required String failureMessage,
  }) async {
    final normalizedThreadId = threadId.trim();
    if (normalizedThreadId.isEmpty) return;
    _currentCallId = callId.trim();
    _threadIdValue = normalizedThreadId;
    _callVideoPreferred = video;
    _initialOfferSentForCallId = '';

    _directCallController.updateAcceptedHandoffStage(
      threadId: normalizedThreadId,
      stage: AcceptedDirectCallStage.permissions,
      clearError: true,
    );
    final permissionsGranted = await _ensureDirectCallPermissions(video: video);
    if (!permissionsGranted) {
      _directCallController.updateAcceptedHandoffStage(
        threadId: normalizedThreadId,
        stage: AcceptedDirectCallStage.failed,
        errorMessage: 'permissions_denied',
      );
      _directCallController.clearCallForThread(normalizedThreadId);
      await _declineIncomingAcceptedCall(
        threadId: normalizedThreadId,
        callId: _currentCallId,
      );
      if (!mounted) return;
      _showSnack(
        video
            ? 'Camera and microphone permission are required for video calls.'
            : 'Microphone permission is required for calls.',
      );
      await _cleanupCall(sendSignal: false);
      return;
    }

    if (dismissNativeSurface) {
      await _dmCallKitBridge.dismissIncomingUiForAcceptedCall(
        threadId: normalizedThreadId,
        callId: _currentCallId,
      );
    }

    if (!mounted) return;
    setState(() {
      _callMinimized = false;
      _callIncoming = false;
      _callDialing = true;
      _callInitiator = false;
      _callStatus = 'Connecting...';
    });

    var acceptedOnServer = false;
    try {
      _directCallController.updateAcceptedHandoffStage(
        threadId: normalizedThreadId,
        stage: AcceptedDirectCallStage.transportPreparing,
      );
      await _prepareAcceptedTransport(
        threadId: normalizedThreadId,
        callId: _currentCallId,
      );
      acceptedOnServer = true;
      _directCallController.updateAcceptedHandoffStage(
        threadId: normalizedThreadId,
        stage: AcceptedDirectCallStage.transportReady,
        serverAccepted: true,
      );
      await _waitForAcceptedCallHandoffStabilized();
      _directCallController.updateAcceptedHandoffStage(
        threadId: normalizedThreadId,
        stage: AcceptedDirectCallStage.mediaPreparing,
      );
      await _ensurePreparedCallWithRetry(video: video);
      _directCallController.updateAcceptedHandoffStage(
        threadId: normalizedThreadId,
        stage: AcceptedDirectCallStage.mediaReady,
      );
      _directCallController.updateAcceptedHandoffStage(
        threadId: normalizedThreadId,
        stage: AcceptedDirectCallStage.readyEmitting,
      );
      await _emitCallReady(threadId: normalizedThreadId);
      _directCallController.updateAcceptedHandoffStage(
        threadId: normalizedThreadId,
        stage: AcceptedDirectCallStage.ready,
      );
      _startCallTimeout('Connection took too long. Try calling again.');
    } catch (error) {
      _directCallController.updateAcceptedHandoffStage(
        threadId: normalizedThreadId,
        stage: AcceptedDirectCallStage.failed,
        errorMessage: '$error',
        serverAccepted: acceptedOnServer,
      );
      if (acceptedOnServer && _currentCallId.trim().isNotEmpty) {
        unawaited(
          _socket.emitWithAckFuture('dm:call:end', <String, dynamic>{
            'threadId': normalizedThreadId,
            'callId': _currentCallId,
          }, timeout: const Duration(seconds: 2)),
        );
      }
      if (!mounted) return;
      _showSnack(failureMessage);
      await _cleanupCall(sendSignal: false);
    }
  }

  Future<void> _joinDirectCallRoom(String threadId) async {
    final normalizedThreadId = threadId.trim();
    if (normalizedThreadId.isEmpty) return;
    await _ensureRealtimeSocketReady();
    final payload = await _socket.emitWithAckFuture(
      'dm:join',
      <String, dynamic>{'threadId': normalizedThreadId},
      timeout: const Duration(seconds: 4),
    );
    if (payload == null || (payload is Map && payload['ok'] == false)) {
      throw Exception('Could not join call room.');
    }
  }

  Future<bool> _ensureDirectCallPermissions({required bool video}) async {
    final granted = video
        ? await _permissionService.ensureCameraAndMicrophone()
        : await _permissionService.ensureMicrophone();
    if (granted) {
      await _permissionService.warmBluetoothConnectPermission();
    }
    return granted;
  }

  Future<void> _ensureRealtimeSocketReady() async {
    if (_socket.isConnected) return;
    final session = ref.read(sessionControllerProvider);
    final token = session.token?.trim() ?? '';
    final sessionId = session.sessionId?.trim() ?? '';
    final userId = session.user?.id.trim() ?? '';
    if (token.isEmpty || sessionId.isEmpty || userId.isEmpty) {
      throw Exception('Session is not ready.');
    }
    final ok = await _socket.ensureSessionIdentity(
      token: token,
      expectedUserId: userId,
      expectedSessionId: sessionId,
      timeout: const Duration(seconds: 8),
    );
    if (!ok) {
      throw Exception('Socket is not ready.');
    }
  }

  Future<DirectCallSessionSnapshot> _acceptCallSession({
    required String threadId,
    required String callId,
  }) async {
    final normalizedThreadId = threadId.trim();
    if (normalizedThreadId.isEmpty) {
      throw Exception('Call thread was invalid.');
    }
    await _ensureRealtimeSocketReady();
    final payload = await _socket.emitWithAckFuture(
      'dm:call:accept',
      <String, dynamic>{
        'threadId': normalizedThreadId,
        'callId': callId,
        'accept': true,
      },
      timeout: const Duration(seconds: 4),
    );
    if (payload == null || (payload is Map && payload['ok'] == false)) {
      throw Exception('Could not accept call session.');
    }
    if (payload is! Map || payload['session'] is! Map) {
      throw Exception('Call session response was invalid.');
    }
    return DirectCallSessionSnapshot.fromJson(
      Map<String, dynamic>.from(payload['session'] as Map),
    );
  }

  Future<void> _prepareAcceptedTransport({
    required String threadId,
    required String callId,
  }) async {
    final acceptedSession = await _acceptCallSession(
      threadId: threadId,
      callId: callId,
    );
    _currentCallId = acceptedSession.callId;
    _callVideoPreferred = acceptedSession.wantsVideo;
    _serverCallAccepted = true;
    _dmCallKitBridge.markAcceptedForThread(
      threadId: threadId,
      callId: _currentCallId,
    );
    await _joinDirectCallRoom(threadId);
  }

  Future<void> _declineIncomingAcceptedCall({
    required String threadId,
    required String callId,
  }) async {
    final normalizedThreadId = threadId.trim();
    if (normalizedThreadId.isEmpty) return;
    try {
      await _ensureRealtimeSocketReady();
    } catch (_) {
      return;
    }
    unawaited(
      _socket.emitWithAckFuture('dm:call:accept', <String, dynamic>{
        'threadId': normalizedThreadId,
        'callId': callId,
        'accept': false,
      }, timeout: const Duration(seconds: 2)),
    );
  }

  Future<void> _emitCallReady({required String threadId}) async {
    final normalizedThreadId = threadId.trim();
    if (normalizedThreadId.isEmpty || _currentCallId.trim().isEmpty) return;
    final payload = await _socket.emitWithAckFuture(
      'dm:call:ready',
      <String, dynamic>{
        'threadId': normalizedThreadId,
        'callId': _currentCallId,
      },
      timeout: const Duration(seconds: 4),
    );
    if (payload == null || (payload is Map && payload['ok'] == false)) {
      throw Exception('Could not mark call ready.');
    }
  }

  Future<void> _waitForAcceptedCallHandoffStabilized() async {
    if (!Platform.isIOS) return;
    final deadline = DateTime.now().add(const Duration(seconds: 3));
    while (DateTime.now().isBefore(deadline)) {
      if (_isDisposingOrDisposed) return;
      final lifecycleState = WidgetsBinding.instance.lifecycleState;
      if (lifecycleState == null ||
          lifecycleState == AppLifecycleState.resumed) {
        await Future<void>.delayed(const Duration(milliseconds: 140));
        return;
      }
      await Future<void>.delayed(const Duration(milliseconds: 80));
    }
  }

  void _declineIncomingCall() {
    unawaited(_stopIncomingRingtone());
    final threadId = _threadId;
    _directCallController.clearCallForThread(threadId);
    if (threadId.isNotEmpty) {
      unawaited(
        _socket.emitWithAckFuture('dm:call:accept', <String, dynamic>{
          'threadId': threadId,
          'callId': _currentCallId,
          'accept': false,
        }, timeout: const Duration(seconds: 2)),
      );
    }
    setState(() {
      _callMinimized = false;
      _callIncoming = false;
      _callStatus = null;
    });
  }

  Future<void> _endCall() async {
    await _cleanupCall(sendSignal: true);
  }

  Future<void> _prepareCallSession({required bool video}) async {
    if (!_renderersReady) return;
    final stream =
        _webRtcService.localStream ??
        await _webRtcService.createLocalStream(
          audio: true,
          video: video,
          facingMode: 'user',
        );

    _localVideoEnabled = stream.getVideoTracks().any((track) => track.enabled);
    _localCameraUiState = _localVideoEnabled
        ? _LocalCameraUiState.on
        : _LocalCameraUiState.off;
    _localPreviewTrackId =
        _localVideoEnabled && stream.getVideoTracks().isNotEmpty
        ? stream.getVideoTracks().first.id
        : null;
    _localVideoMirrored = _localVideoEnabled;
    _micEnabled = stream.getAudioTracks().any((track) => track.enabled);

    if (_peerConnection == null) {
      final peerConfig = await _peerConnectionConfig();
      _peerConnection = await createPeerConnection(peerConfig);

      _peerConnection!.onIceCandidate = (candidate) {
        if (candidate.candidate == null || _threadId.isEmpty) return;
        _socket.emit('dm:rtc:ice', <String, dynamic>{
          'threadId': _threadId,
          'callId': _currentCallId,
          'candidate': candidate.toMap(),
        });
      };

      _peerConnection!.onTrack = (event) {
        if (event.streams.isNotEmpty) {
          _remoteRenderer.srcObject = event.streams.first;
        }
        if (event.track.kind == 'video' && mounted) {
          setState(() => _remoteVideoEnabled = true);
        }
      };

      _peerConnection!.onConnectionState = (state) {
        if (!mounted) return;
        if (state == RTCPeerConnectionState.RTCPeerConnectionStateConnected) {
          _clearCallRecoveryWindow();
          _clearCallTimeout();
          _startCallDuration();
          unawaited(_stopIncomingRingtone());
          unawaited(_dmCallKitBridge.markConnectedForThread(_threadId));
          _socket.emit('dm:call:connected', <String, dynamic>{
            'threadId': _threadId,
            'callId': _currentCallId,
          });
          _directCallController.updateAcceptedHandoffStage(
            threadId: _threadId,
            stage: AcceptedDirectCallStage.active,
            serverAccepted: true,
          );
          setState(() {
            _callConnected = true;
            _callDialing = false;
            _callStatus = 'Connected';
          });
        } else if (state ==
                RTCPeerConnectionState.RTCPeerConnectionStateDisconnected ||
            state == RTCPeerConnectionState.RTCPeerConnectionStateFailed) {
          _startCallRecoveryWindow(
            status: 'Reconnecting call...',
            timeoutMessage: 'Call connection was lost. Please try again.',
          );
          if (state == RTCPeerConnectionState.RTCPeerConnectionStateFailed) {
            unawaited(_attemptIceRestart());
          }
        } else if (state ==
            RTCPeerConnectionState.RTCPeerConnectionStateClosed) {
          unawaited(_cleanupCall(sendSignal: false));
        }
      };
    }

    final senders = await _peerConnection!.getSenders();
    for (final track in stream.getTracks()) {
      final alreadyAdded = senders.any(
        (sender) => sender.track?.id == track.id,
      );
      if (!alreadyAdded) {
        final addedSender = await _peerConnection!.addTrack(track, stream);
        if (track.kind == 'video') {
          _localVideoSenderId = addedSender.senderId;
        }
      } else if (track.kind == 'video') {
        final existingVideoSender = senders.cast<RTCRtpSender?>().firstWhere(
          (sender) => sender?.track?.id == track.id,
          orElse: () => null,
        );
        _localVideoSenderId =
            existingVideoSender?.senderId ?? _localVideoSenderId;
      }
    }

    await _resetLocalPreviewSurface(
      _localVideoEnabled ? stream : null,
      previewTrackId: _localPreviewTrackId,
    );
    if (mounted) setState(() {});
  }

  Future<void> _ensurePreparedCall({required bool video}) {
    final existing = _callPreparationFuture;
    if (existing != null) return existing;
    final future = _prepareCallSession(video: video);
    _callPreparationFuture = future.whenComplete(() {
      if (identical(_callPreparationFuture, future)) {
        _callPreparationFuture = null;
      }
    });
    return _callPreparationFuture!;
  }

  Future<void> _resetPreparedCallStateForRetry() async {
    await _peerConnection?.close();
    _peerConnection = null;
    _pendingRemoteCandidates.clear();
    _remoteDescriptionReady = false;
    _callPreparationFuture = null;
    _localVideoSenderId = null;
    _localPreviewTrackId = null;
    _localPreviewReady = false;
    _awaitingLocalPreviewFrame = false;
    _localPreviewGeneration = 0;
    _localCameraUiState = _LocalCameraUiState.off;
    _localVideoEnabled = false;
    _remoteVideoEnabled = false;
    _localVideoMirrored = true;
    _cameraBusy = false;
    _micEnabled = true;
    _localRenderer.srcObject = null;
    _remoteRenderer.srcObject = null;
    await _webRtcService.disposeLocalStream();
    if (!mounted) return;
    setState(() {});
  }

  Future<void> _ensurePreparedCallWithRetry({required bool video}) async {
    final maxAttempts = Platform.isIOS ? 3 : 1;
    Object? lastError;
    for (var attempt = 1; attempt <= maxAttempts; attempt += 1) {
      try {
        await _ensurePreparedCall(video: video);
        return;
      } catch (error) {
        lastError = error;
        if (attempt >= maxAttempts || _isDisposingOrDisposed) {
          rethrow;
        }
        await _resetPreparedCallStateForRetry();
        if (_isDisposingOrDisposed) {
          rethrow;
        }
        await Future<void>.delayed(Duration(milliseconds: 180 * attempt));
      }
    }
    throw lastError ?? Exception('Could not prepare call session.');
  }

  bool _isAcceptedHandoffProtected() {
    final handoff = ref.read(directCallControllerProvider).acceptedHandoff;
    if (handoff == null || handoff.threadId != _threadId) {
      return false;
    }
    switch (handoff.stage) {
      case AcceptedDirectCallStage.permissions:
      case AcceptedDirectCallStage.transportPreparing:
      case AcceptedDirectCallStage.transportReady:
      case AcceptedDirectCallStage.mediaPreparing:
      case AcceptedDirectCallStage.mediaReady:
      case AcceptedDirectCallStage.readyEmitting:
      case AcceptedDirectCallStage.ready:
        return true;
      case AcceptedDirectCallStage.pendingNavigation:
      case AcceptedDirectCallStage.active:
      case AcceptedDirectCallStage.failed:
        return false;
    }
  }

  Future<RTCRtpSender?> _resolveLocalVideoSender() async {
    if (_peerConnection == null) return null;
    final senders = await _peerConnection!.getSenders();
    if (_localVideoSenderId != null && _localVideoSenderId!.isNotEmpty) {
      final senderById = senders.cast<RTCRtpSender?>().firstWhere(
        (sender) => sender?.senderId == _localVideoSenderId,
        orElse: () => null,
      );
      if (senderById != null) {
        return senderById;
      }
    }
    final senderByTrack = senders.cast<RTCRtpSender?>().firstWhere(
      (sender) => sender?.track?.kind == 'video',
      orElse: () => null,
    );
    if (senderByTrack != null) {
      _localVideoSenderId = senderByTrack.senderId;
    }
    return senderByTrack;
  }

  bool get _localVideoEnabledForUi =>
      _localCameraUiState == _LocalCameraUiState.on ||
      _localCameraUiState == _LocalCameraUiState.turningOn;

  void _syncLocalVideoUiState({
    required bool enabled,
    required _LocalCameraUiState uiState,
    bool? callVideoPreferred,
  }) {
    _localPreviewReady = false;
    _awaitingLocalPreviewFrame = enabled;
    _localVideoEnabled = enabled;
    _localCameraUiState = uiState;
    if (!mounted) return;
    setState(() {
      _localVideoMirrored = true;
      if (callVideoPreferred != null) {
        _callVideoPreferred = callVideoPreferred;
      }
    });
  }

  String? _resolvePreviewTrackIdFromStream(MediaStream? stream) {
    if (stream == null) return null;
    final videoTracks = stream.getVideoTracks();
    if (videoTracks.isEmpty) return null;
    if (_localPreviewTrackId != null && _localPreviewTrackId!.isNotEmpty) {
      for (final track in videoTracks) {
        if (track.id == _localPreviewTrackId) {
          return track.id;
        }
      }
    }
    return videoTracks.first.id;
  }

  Future<void> _resetLocalPreviewSurface(
    MediaStream? previewStream, {
    String? previewTrackId,
  }) async {
    _localPreviewReady = false;
    _awaitingLocalPreviewFrame = previewStream != null;
    _localRenderer.srcObject = null;
    _localPreviewTrackId = previewTrackId;
    _localPreviewGeneration++;
    if (mounted) {
      setState(() {});
    }
    if (previewStream == null || _isDisposingOrDisposed) {
      return;
    }
    await Future<void>.delayed(Duration.zero);
    if (_isDisposingOrDisposed) return;
    final resolvedTrackId =
        previewTrackId ?? _resolvePreviewTrackIdFromStream(previewStream);
    _localPreviewTrackId = resolvedTrackId;
    try {
      await _localRenderer.setSrcObject(
        stream: previewStream,
        trackId: resolvedTrackId,
      );
    } catch (_) {
      _localRenderer.srcObject = previewStream;
    }
    _localPreviewGeneration++;
    if (mounted) {
      setState(() {});
    }
  }

  Future<void> _createAndSendOffer() async {
    if (_peerConnection == null) return;
    final offer = await _peerConnection!.createOffer();
    await _peerConnection!.setLocalDescription(offer);
    _socket.emit('dm:rtc:offer', <String, dynamic>{
      'threadId': _threadId,
      'callId': _currentCallId,
      'sdp': offer.toMap(),
    });
  }

  String _payloadCallId(Map<String, dynamic> payload) =>
      '${payload['callId'] ?? ''}'.trim();

  bool _matchesActiveCallPayload(Map<String, dynamic> payload) {
    final payloadCallId = _payloadCallId(payload);
    if (payloadCallId.isEmpty || _currentCallId.trim().isEmpty) {
      return true;
    }
    return payloadCallId == _currentCallId.trim();
  }

  void _adoptPayloadCallId(Map<String, dynamic> payload) {
    final payloadCallId = _payloadCallId(payload);
    if (payloadCallId.isNotEmpty) {
      _currentCallId = payloadCallId;
    }
  }

  Future<void> _flushPendingIce() async {
    if (_peerConnection == null) return;
    while (_pendingRemoteCandidates.isNotEmpty) {
      final candidate = _pendingRemoteCandidates.removeAt(0);
      await _peerConnection!.addCandidate(candidate);
    }
  }

  void _onCallRequest(dynamic data) {
    if (_isDisposingOrDisposed) return;
    if (data is! Map) return;
    final payload = Map<String, dynamic>.from(data);
    final payloadThreadId = payload['threadId']?.toString() ?? '';
    if (_threadId.isNotEmpty && payloadThreadId != _threadId) return;
    if (payload['fromUserId']?.toString() == _meId) return;
    if (!_matchesActiveCallPayload(payload)) return;
    unawaited(_handleIncomingCallRequest(payload));
  }

  Future<void> _handleIncomingCallRequest(Map<String, dynamic> payload) async {
    if (_isDisposingOrDisposed || !mounted) return;
    _adoptPayloadCallId(payload);
    _serverCallAccepted = false;
    final chatState = _chatState;
    final threadId = payload['threadId']?.toString().trim() ?? _threadId;
    final video = payload['video'] == true;
    if (chatState.blocked) {
      if (threadId.isNotEmpty) {
        unawaited(_declineIncomingCallRequest(threadId));
      }
      return;
    }
    if (_isDisposingOrDisposed || !mounted) return;
    final callerName = _partnerDisplayName.trim();
    final avatarUrl = _partnerPhotoUrl.trim();
    final caller = callerName.isEmpty && avatarUrl.isEmpty
        ? null
        : AppUser(
            id: widget.userId,
            email: '',
            displayName: callerName.isEmpty ? 'Talkflix' : callerName,
            username: '',
            firstLanguage: '',
            learnLanguage: '',
            role: 'user',
            plan: 'free',
            trialUsed: false,
            meetLanguages: const [],
            city: '',
            country: '',
            countryCode: '',
            nationalityCode: '',
            nationalityName: '',
            profilePhotoUrl: avatarUrl,
            bioText: '',
            bioAudioUrl: '',
            bioAudioDuration: 0,
            followersCount: 0,
            followingCount: 0,
            postsCount: 0,
            isFollowing: false,
          );
    _directCallController.showIncoming(
      threadId: threadId,
      fromUserId: widget.userId,
      callId: _currentCallId,
      video: video,
      caller: caller,
    );
    _appendCallEventToHistory(
      threadId: threadId,
      callId: _currentCallId,
      eventKey: 'incoming',
      text: video ? 'Incoming video call' : 'Incoming voice call',
    );
  }

  Future<void> _declineIncomingCallRequest(String threadId) {
    return _socket.emitWithAckFuture('dm:call:accept', <String, dynamic>{
      'threadId': threadId,
      'callId': _currentCallId,
      'accept': false,
    }, timeout: const Duration(seconds: 2));
  }

  Future<void> _onCallAccept(dynamic data) async {
    if (_isDisposingOrDisposed || !mounted) return;
    if (data is! Map) return;
    final payload = Map<String, dynamic>.from(data);
    if (payload['threadId']?.toString() != _threadId) return;
    if (payload['fromUserId']?.toString() == _meId) return;
    if (!_matchesActiveCallPayload(payload)) return;
    _adoptPayloadCallId(payload);

    if (payload['accept'] != true) {
      _appendCallEventToHistory(
        threadId: payload['threadId']?.toString(),
        callId: _currentCallId,
        eventKey: 'declined',
        text: 'Call declined.',
      );
      await _cleanupCall(sendSignal: false);
      return;
    }

    await _stopIncomingRingtone();
    _serverCallAccepted = true;
    _dmCallKitBridge.markAcceptedForThread(
      threadId: _threadId,
      callId: _currentCallId,
    );
    _callVideoPreferred = payload['video'] == true || _callVideoPreferred;
    if (_isDisposingOrDisposed || !mounted) return;
    setState(() {
      _callMinimized = false;
      _callIncoming = false;
      _callDialing = true;
      _callStatus = 'Connecting...';
    });
    try {
      await _ensurePreparedCall(video: _callVideoPreferred);
      _startCallTimeout('Connection took too long. Try calling again.');
    } catch (_) {
      _showSnack('Could not connect call.');
      await _cleanupCall(sendSignal: false);
    }
  }

  Future<void> _onCallReady(dynamic data) async {
    if (_isDisposingOrDisposed || !mounted) return;
    if (data is! Map) return;
    final payload = Map<String, dynamic>.from(data);
    if (payload['threadId']?.toString() != _threadId) return;
    if (payload['fromUserId']?.toString() == _meId) return;
    if (!_matchesActiveCallPayload(payload)) return;
    _adoptPayloadCallId(payload);
    if (!_callInitiator || _callConnected) return;
    if (_initialOfferSentForCallId == _currentCallId &&
        _currentCallId.isNotEmpty) {
      return;
    }
    try {
      await _ensurePreparedCall(video: _callVideoPreferred);
      await _createAndSendOffer();
      _initialOfferSentForCallId = _currentCallId;
      if (!mounted) return;
      setState(() => _callStatus = 'Connecting...');
    } catch (_) {
      _showSnack('Could not connect call.');
      await _cleanupCall(sendSignal: false);
    }
  }

  Future<void> _onRtcOffer(dynamic data) async {
    if (_isDisposingOrDisposed || !mounted) return;
    if (data is! Map) return;
    final payload = Map<String, dynamic>.from(data);
    if (payload['threadId']?.toString() != _threadId) return;
    if (payload['fromUserId']?.toString() == _meId) return;
    if (!_matchesActiveCallPayload(payload)) return;
    _adoptPayloadCallId(payload);

    await _stopIncomingRingtone();
    await _ensurePreparedCall(video: _callVideoPreferred);
    final sdp = Map<String, dynamic>.from(payload['sdp'] as Map);
    await _peerConnection!.setRemoteDescription(
      RTCSessionDescription(sdp['sdp']?.toString(), sdp['type']?.toString()),
    );
    _remoteDescriptionReady = true;
    await _flushPendingIce();
    final answer = await _peerConnection!.createAnswer();
    await _peerConnection!.setLocalDescription(answer);
    _socket.emit('dm:rtc:answer', <String, dynamic>{
      'threadId': _threadId,
      'callId': _currentCallId,
      'sdp': answer.toMap(),
    });
    if (!mounted) return;
    if (!_callConnected) {
      setState(() => _callStatus = 'Connecting...');
    }
  }

  Future<void> _onRtcAnswer(dynamic data) async {
    if (_isDisposingOrDisposed || !mounted) return;
    if (data is! Map) return;
    final payload = Map<String, dynamic>.from(data);
    if (payload['threadId']?.toString() != _threadId) return;
    if (payload['fromUserId']?.toString() == _meId) return;
    if (!_matchesActiveCallPayload(payload)) return;
    _adoptPayloadCallId(payload);
    if (_peerConnection == null) return;

    await _stopIncomingRingtone();
    final sdp = Map<String, dynamic>.from(payload['sdp'] as Map);
    await _peerConnection!.setRemoteDescription(
      RTCSessionDescription(sdp['sdp']?.toString(), sdp['type']?.toString()),
    );
    _remoteDescriptionReady = true;
    await _flushPendingIce();
  }

  Future<void> _onRtcIce(dynamic data) async {
    if (_isDisposingOrDisposed || !mounted) return;
    if (data is! Map) return;
    final payload = Map<String, dynamic>.from(data);
    if (payload['threadId']?.toString() != _threadId) return;
    if (payload['fromUserId']?.toString() == _meId) return;
    if (!_matchesActiveCallPayload(payload)) return;
    _adoptPayloadCallId(payload);
    final candidateMap = Map<String, dynamic>.from(payload['candidate'] as Map);
    final candidate = RTCIceCandidate(
      candidateMap['candidate']?.toString(),
      candidateMap['sdpMid']?.toString(),
      candidateMap['sdpMLineIndex'] as int?,
    );

    if (_peerConnection == null || !_remoteDescriptionReady) {
      _pendingRemoteCandidates.add(candidate);
      return;
    }

    await _peerConnection!.addCandidate(candidate);
  }

  void _onRemoteCameraState(dynamic data) {
    if (_isDisposingOrDisposed || !mounted) return;
    if (data is! Map) return;
    final payload = Map<String, dynamic>.from(data);
    if (payload['threadId']?.toString() != _threadId) return;
    if (payload['fromUserId']?.toString() == _meId) return;
    if (!_matchesActiveCallPayload(payload)) return;
    _adoptPayloadCallId(payload);
    if (!mounted) return;
    setState(() => _remoteVideoEnabled = payload['enabled'] == true);
  }

  void _onCallConnected(dynamic data) {
    if (_isDisposingOrDisposed || !mounted) return;
    if (data is! Map) return;
    final payload = Map<String, dynamic>.from(data);
    if (payload['threadId']?.toString() != _threadId) return;
    if (!_matchesActiveCallPayload(payload)) return;
    _adoptPayloadCallId(payload);
    _serverCallAccepted = true;
  }

  Future<void> _onCallEnded(dynamic data) async {
    if (_isDisposingOrDisposed || !mounted) return;
    if (data is! Map) return;
    final payload = Map<String, dynamic>.from(data);
    if (payload['threadId']?.toString() != _threadId) return;
    if (!_matchesActiveCallPayload(payload)) return;
    _adoptPayloadCallId(payload);
    await _stopIncomingRingtone();
    await _cleanupCall(sendSignal: false);
  }

  Future<void> _onCallCancelled(dynamic data) async {
    if (_isDisposingOrDisposed || !mounted) return;
    if (data is! Map) return;
    final payload = Map<String, dynamic>.from(data);
    if (payload['threadId']?.toString() != _threadId) return;
    if (!_matchesActiveCallPayload(payload)) return;
    _adoptPayloadCallId(payload);
    await _stopIncomingRingtone();
    _appendCallEventToHistory(
      threadId: payload['threadId']?.toString(),
      callId: _currentCallId,
      eventKey: 'cancelled',
      text: 'Call cancelled.',
    );
    await _cleanupCall(sendSignal: false);
  }

  Future<void> _onCallMissed(dynamic data) async {
    if (_isDisposingOrDisposed || !mounted) return;
    if (data is! Map) return;
    final payload = Map<String, dynamic>.from(data);
    if (payload['threadId']?.toString() != _threadId) return;
    if (!_matchesActiveCallPayload(payload)) return;
    _adoptPayloadCallId(payload);
    await _stopIncomingRingtone();
    _appendCallEventToHistory(
      threadId: payload['threadId']?.toString(),
      callId: _currentCallId,
      eventKey: 'missed',
      text: 'Missed call.',
    );
    await _cleanupCall(sendSignal: false);
  }

  Future<void> _toggleMute() async {
    final stream = _webRtcService.localStream;
    if (stream == null) return;
    for (final track in stream.getAudioTracks()) {
      track.enabled = !track.enabled;
      _micEnabled = track.enabled;
    }
    if (mounted) setState(() {});
  }

  Future<void> _toggleSpeaker() async {
    final next = !_speakerOn;
    await Helper.setSpeakerphoneOn(next);
    if (!mounted) return;
    setState(() => _speakerOn = next);
  }

  Future<void> _toggleCamera() async {
    if (_peerConnection == null || _threadId.isEmpty || _cameraBusy) return;
    final local = _webRtcService.localStream;
    if (local == null) return;
    setState(() => _cameraBusy = true);
    try {
      if (!_localVideoEnabled) {
        _syncLocalVideoUiState(
          enabled: true,
          uiState: _LocalCameraUiState.turningOn,
          callVideoPreferred: true,
        );
        await _resetLocalPreviewSurface(null);
        MediaStream camStream;
        try {
          camStream = await navigator.mediaDevices.getUserMedia({
            'audio': false,
            'video': {'facingMode': 'user'},
          });
        } catch (_) {
          _syncLocalVideoUiState(
            enabled: false,
            uiState: _LocalCameraUiState.off,
            callVideoPreferred: false,
          );
          await _resetLocalPreviewSurface(null);
          _showSnack('Camera permission is required to turn on video.');
          return;
        }
        final newVideoTrack = camStream.getVideoTracks().isNotEmpty
            ? camStream.getVideoTracks().first
            : null;
        if (newVideoTrack == null) {
          _syncLocalVideoUiState(
            enabled: false,
            uiState: _LocalCameraUiState.off,
            callVideoPreferred: false,
          );
          await _resetLocalPreviewSurface(null);
          return;
        }
        try {
          await local.addTrack(newVideoTrack);
          final existingVideoSender = await _resolveLocalVideoSender();
          if (existingVideoSender != null) {
            await existingVideoSender.replaceTrack(newVideoTrack);
            _localVideoSenderId = existingVideoSender.senderId;
          } else {
            final addedSender = await _peerConnection!.addTrack(
              newVideoTrack,
              local,
            );
            _localVideoSenderId = addedSender.senderId;
          }
          _localPreviewTrackId = newVideoTrack.id;
        } catch (_) {
          try {
            await newVideoTrack.stop();
            if (local.getVideoTracks().any(
              (track) => track.id == newVideoTrack.id,
            )) {
              await local.removeTrack(newVideoTrack);
            }
          } catch (_) {}
          _syncLocalVideoUiState(
            enabled: false,
            uiState: _LocalCameraUiState.off,
            callVideoPreferred: false,
          );
          await _resetLocalPreviewSurface(null, previewTrackId: null);
          _showSnack('Could not turn on camera.');
          return;
        }
        _syncLocalVideoUiState(
          enabled: true,
          uiState: _LocalCameraUiState.on,
          callVideoPreferred: true,
        );
        await _resetLocalPreviewSurface(
          local,
          previewTrackId: _localPreviewTrackId,
        );
        await _createAndSendOffer();
        _socket.emit('dm:call:camera-state', <String, dynamic>{
          'threadId': _threadId,
          'callId': _currentCallId,
          'enabled': true,
        });
        return;
      }

      final previousVideoTracks = List<MediaStreamTrack>.from(
        local.getVideoTracks(),
      );
      _syncLocalVideoUiState(
        enabled: false,
        uiState: _LocalCameraUiState.turningOff,
        callVideoPreferred: false,
      );
      await _resetLocalPreviewSurface(null, previewTrackId: null);
      final videoSender = await _resolveLocalVideoSender();
      try {
        if (videoSender != null) {
          final removed = await _peerConnection!.removeTrack(videoSender);
          if (!removed) {
            throw StateError('removeTrack returned false');
          }
          _localVideoSenderId = null;
        }
      } catch (_) {
        _syncLocalVideoUiState(
          enabled: true,
          uiState: _LocalCameraUiState.on,
          callVideoPreferred: true,
        );
        await _resetLocalPreviewSurface(
          local,
          previewTrackId: _resolvePreviewTrackIdFromStream(local),
        );
        _showSnack('Could not turn off camera.');
        return;
      }
      for (final track in previousVideoTracks) {
        try {
          await track.stop();
        } catch (_) {}
        try {
          if (local.getVideoTracks().any(
            (existing) => existing.id == track.id,
          )) {
            await local.removeTrack(track);
          }
        } catch (_) {}
      }
      _syncLocalVideoUiState(
        enabled: false,
        uiState: _LocalCameraUiState.off,
        callVideoPreferred: false,
      );
      _localPreviewTrackId = null;
      await _createAndSendOffer();
      _socket.emit('dm:call:camera-state', <String, dynamic>{
        'threadId': _threadId,
        'callId': _currentCallId,
        'enabled': false,
      });
    } finally {
      if (mounted) {
        setState(() => _cameraBusy = false);
      }
    }
  }

  Future<void> _switchCamera() async {
    final switched = await _webRtcService.switchCamera();
    if (!switched) {
      _showSnack('No active video camera to switch.');
      return;
    }
    if (mounted) {
      setState(() {
        _localVideoMirrored = !_localVideoMirrored;
      });
    }
  }

  Future<void> _cleanupCall({required bool sendSignal}) async {
    _clearCallTimeout();
    _clearCallRecoveryWindow();
    _stopCallDuration();
    await _stopIncomingRingtone();
    _directCallController.clearCallForThread(_threadId);
    unawaited(_dmCallKitBridge.endCallForThread(_threadId));
    if (sendSignal && _threadId.isNotEmpty) {
      if (_callConnected || _serverCallAccepted) {
        _socket.emitRedundant('dm:call:end', <String, dynamic>{
          'threadId': _threadId,
          'callId': _currentCallId,
        });
      } else if (_callDialing || _callIncoming) {
        _socket.emitRedundant('dm:call:cancel', <String, dynamic>{
          'threadId': _threadId,
          'callId': _currentCallId,
        });
      }
    }
    await _peerConnection?.close();
    _peerConnection = null;
    _pendingRemoteCandidates.clear();
    _remoteDescriptionReady = false;
    _callPreparationFuture = null;
    _initialOfferSentForCallId = '';
    _localVideoSenderId = null;
    _localPreviewTrackId = null;
    _localPreviewReady = false;
    _awaitingLocalPreviewFrame = false;
    _localPreviewGeneration = 0;
    _localCameraUiState = _LocalCameraUiState.off;
    _localRenderer.srcObject = null;
    _remoteRenderer.srcObject = null;
    await _webRtcService.disposeLocalStream();
    if (!mounted) return;
    setState(() {
      _callMinimized = false;
      _callIncoming = false;
      _callDialing = false;
      _callConnected = false;
      _serverCallAccepted = false;
      _callInitiator = false;
      _callVideoPreferred = false;
      _localVideoEnabled = false;
      _remoteVideoEnabled = false;
      _cameraBusy = false;
      _localVideoMirrored = true;
      _micEnabled = true;
      _speakerOn = false;
      _callSeconds = 0;
      _callStatus = null;
    });
    _currentCallId = '';
  }

  void _minimizeCallUi() {
    if (!_hasActiveCallSession || _callIncoming || !mounted) return;
    setState(() => _callMinimized = true);
  }

  void _restoreCallUi() {
    if (!_hasActiveCallSession || !mounted) return;
    setState(() => _callMinimized = false);
  }

  void _startCallTimeout(String message) {
    _callTimeoutTimer?.cancel();
    _callTimeoutTimer = Timer(const Duration(seconds: 30), () async {
      if (!mounted || !_callDialing || _callConnected) return;
      _showSnack(message);
      await _cleanupCall(sendSignal: true);
    });
  }

  void _clearCallTimeout() {
    _callTimeoutTimer?.cancel();
    _callTimeoutTimer = null;
  }

  void _startCallDuration() {
    _callDurationTimer?.cancel();
    _callDurationTimer = Timer.periodic(const Duration(seconds: 1), (_) {
      if (!mounted) return;
      setState(() => _callSeconds += 1);
    });
  }

  void _stopCallDuration() {
    _callDurationTimer?.cancel();
    _callDurationTimer = null;
  }

  void _handleSocketStatusChanged() {
    if (_isDisposingOrDisposed || !mounted) return;
    final nextStatus = _socket.status;
    if (nextStatus == _socketStatus) return;
    _socketStatus = nextStatus;

    final isTransportChanging =
        nextStatus == 'connecting' ||
        nextStatus == 'disconnected' ||
        nextStatus == 'error';
    if ((_callIncoming || _callDialing || _callConnected) &&
        isTransportChanging &&
        _isAcceptedHandoffProtected()) {
      _startCallRecoveryWindow(
        status: 'Connecting...',
        timeoutMessage: 'The call setup stalled. Please try again.',
      );
      return;
    }

    if ((_callIncoming || _callDialing || _callConnected) &&
        isTransportChanging) {
      _startCallRecoveryWindow(
        status: 'Realtime connection changed. Reconnecting call...',
      );
      return;
    }

    if (nextStatus == 'connected') {
      _clearCallRecoveryWindow();
      unawaited(_syncCurrentCallSession());
      if (_callConnected && mounted) {
        setState(() => _callStatus = 'Connected');
      }
    }

    setState(() {});
  }

  void _showSnack(String message) {
    if (!mounted) return;
    ScaffoldMessenger.of(
      context,
    ).showSnackBar(SnackBar(content: Text(message)));
  }

  void _refreshSafetyStateIfNeeded() {
    final now = DateTime.now();
    final last = _lastSafetyRefreshAt;
    if (last != null && now.difference(last) < const Duration(seconds: 20)) {
      return;
    }
    _lastSafetyRefreshAt = now;
    _chatController.reload();
  }

  void _jumpToMessage(List<ChatMessage> messages, String messageId) {
    final index = messages.indexWhere((message) => message.id == messageId);
    if (index < 0 || !_scrollController.hasClients) {
      _showSnack('Original message is not available.');
      return;
    }
    final estimatedOffset = (index * 108.0).clamp(
      0.0,
      _scrollController.position.maxScrollExtent,
    );
    _scrollController.animateTo(
      estimatedOffset,
      duration: const Duration(milliseconds: 260),
      curve: Curves.easeOutCubic,
    );
    _replyHighlightTimer?.cancel();
    setState(() => _highlightedMessageId = messageId);
    _replyHighlightTimer = Timer(const Duration(milliseconds: 1400), () {
      if (!mounted) return;
      setState(() => _highlightedMessageId = null);
    });
  }

  Future<void> _openChatSearch() async {
    final queryController = TextEditingController();
    var results = <ChatMessage>[];
    var loading = false;
    await showModalBottomSheet<void>(
      context: context,
      isScrollControlled: true,
      showDragHandle: true,
      builder: (sheetContext) {
        return StatefulBuilder(
          builder: (context, setSheetState) {
            Future<void> runSearch() async {
              final query = queryController.text.trim();
              if (query.length < 2 || loading) return;
              setSheetState(() => loading = true);
              try {
                final found = await _chatController.searchMessages(query);
                if (!context.mounted) return;
                setSheetState(() {
                  results = found;
                  loading = false;
                });
              } catch (error) {
                if (!context.mounted) return;
                setSheetState(() => loading = false);
                _showSnack(error.toString());
              }
            }

            return SafeArea(
              child: Padding(
                padding: EdgeInsets.fromLTRB(
                  18,
                  8,
                  18,
                  18 + MediaQuery.of(context).viewInsets.bottom,
                ),
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    TextField(
                      controller: queryController,
                      autofocus: true,
                      textInputAction: TextInputAction.search,
                      onSubmitted: (_) => runSearch(),
                      decoration: InputDecoration(
                        prefixIcon: const Icon(Icons.search_rounded),
                        suffixIcon: IconButton(
                          onPressed: runSearch,
                          icon: const Icon(Icons.arrow_forward_rounded),
                        ),
                        hintText: 'Search messages',
                        border: const OutlineInputBorder(),
                      ),
                    ),
                    const SizedBox(height: 12),
                    if (loading) const LinearProgressIndicator(),
                    ConstrainedBox(
                      constraints: BoxConstraints(
                        maxHeight: MediaQuery.of(context).size.height * 0.45,
                      ),
                      child: ListView.builder(
                        shrinkWrap: true,
                        itemCount: results.length,
                        itemBuilder: (context, index) {
                          final message = results[index];
                          return ListTile(
                            leading: Icon(
                              message.type == 'file'
                                  ? Icons.insert_drive_file_outlined
                                  : Icons.chat_bubble_outline_rounded,
                            ),
                            title: Text(
                              _replyPreviewText(message),
                              maxLines: 2,
                              overflow: TextOverflow.ellipsis,
                            ),
                            subtitle: Text(
                              formatDirectMessageTime(message.createdAt),
                            ),
                            onTap: () {
                              Navigator.of(sheetContext).pop();
                              _jumpToMessage(_chatState.messages, message.id);
                            },
                          );
                        },
                      ),
                    ),
                  ],
                ),
              ),
            );
          },
        );
      },
    );
    queryController.dispose();
  }

  Future<void> _openSharedFiles() async {
    try {
      final files = await _chatController.fetchSharedMessages(type: 'files');
      if (!mounted) return;
      await showModalBottomSheet<void>(
        context: context,
        showDragHandle: true,
        builder: (sheetContext) {
          return SafeArea(
            child: ListView(
              shrinkWrap: true,
              children: [
                if (files.isEmpty)
                  const ListTile(title: Text('No shared files yet.')),
                for (final message in files)
                  ListTile(
                    leading: const Icon(Icons.insert_drive_file_outlined),
                    title: Text(
                      message.fileName.trim().isEmpty
                          ? 'Attachment'
                          : message.fileName.trim(),
                      maxLines: 2,
                      overflow: TextOverflow.ellipsis,
                    ),
                    subtitle: Text(_formatFileSize(message.fileSize)),
                    onTap: () async {
                      final url = resolveMediaUrl(message.fileUrl);
                      final uri = Uri.tryParse(url);
                      if (uri != null) {
                        await launchUrl(
                          uri,
                          mode: LaunchMode.externalApplication,
                        );
                      }
                    },
                  ),
              ],
            ),
          );
        },
      );
    } catch (error) {
      _showSnack(error.toString());
    }
  }

  Future<void> _openMessageActions(ChatMessage message) async {
    final chatState = _chatState;
    final canCorrect = _enableCorrectionAction && chatState.supportsCorrection;
    final isMine = message.fromUserId == _meId;

    unawaited(HapticFeedback.mediumImpact());

    await showGeneralDialog<void>(
      context: context,
      barrierDismissible: true,
      barrierLabel: 'Dismiss',
      barrierColor: Colors.black.withValues(alpha: 0.55),
      transitionDuration: const Duration(milliseconds: 220),
      transitionBuilder: (ctx, anim, _, child) => FadeTransition(
        opacity: CurvedAnimation(parent: anim, curve: Curves.easeOut),
        child: ScaleTransition(
          scale: Tween<double>(
            begin: 0.93,
            end: 1.0,
          ).animate(CurvedAnimation(parent: anim, curve: Curves.easeOutCubic)),
          child: child,
        ),
      ),
      pageBuilder: (ctx, animation, secondaryAnimation) => _MessageContextMenu(
        message: message,
        isMine: isMine,
        canCorrect: canCorrect,
        correctionTone: _correctionTone,
        onReact: (emoji) {
          Navigator.of(ctx).pop();
          HapticFeedback.selectionClick();
          _toggleMessageReaction(message.id, emoji);
        },
        onReply: () {
          Navigator.of(ctx).pop();
          ref
              .read(directChatControllerProvider(widget.userId).notifier)
              .setReplyTarget(message);
        },
        onCorrect: () {
          Navigator.of(ctx).pop();
          _runCorrection(message);
        },
        onForward: _canForwardMessage(message)
            ? () {
                Navigator.of(ctx).pop();
                unawaited(_forwardMessage(message));
              }
            : null,
        onEdit: isMine && message.type == 'text' && message.text.isNotEmpty
            ? () {
                Navigator.of(ctx).pop();
                unawaited(_editMessage(message));
              }
            : null,
        onRetry: message.canRetry
            ? () {
                Navigator.of(ctx).pop();
                ref
                    .read(directChatControllerProvider(widget.userId).notifier)
                    .retryFailedMessage(message.id);
              }
            : null,
        onCopy: message.text.isNotEmpty
            ? () {
                Navigator.of(ctx).pop();
                Clipboard.setData(ClipboardData(text: message.text.trim()));
                _showSnack('Copied');
              }
            : null,
        onDelete: () {
          Navigator.of(ctx).pop();
          unawaited(_deleteMessage(message));
        },
        onReport: () async {
          Navigator.of(ctx).pop();
          final reason = await _pickReportReason();
          if (reason == null || !mounted) return;
          final ok = await ref
              .read(directChatControllerProvider(widget.userId).notifier)
              .reportMessage(messageId: message.id, reason: reason);
          _showSnack(
            ok
                ? 'Thanks. Your message report was submitted.'
                : 'Could not submit report right now.',
          );
        },
      ),
    );
  }

  Future<void> _deleteMessage(ChatMessage message) async {
    final isMine = message.fromUserId == _meId;
    final result = await showModalBottomSheet<String>(
      context: context,
      backgroundColor: Colors.transparent,
      builder: (sheetCtx) {
        final scheme = Theme.of(sheetCtx).colorScheme;
        final isDark = Theme.of(sheetCtx).brightness == Brightness.dark;
        final bg = isDark ? const Color(0xFF1C1D20) : Colors.white;
        final textColor = isDark ? Colors.white : const Color(0xFF111111);
        final divColor = isDark
            ? Colors.white.withValues(alpha: 0.08)
            : Colors.black.withValues(alpha: 0.06);
        return SafeArea(
          child: Padding(
            padding: const EdgeInsets.fromLTRB(16, 0, 16, 12),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                const SizedBox(height: 8),
                Container(
                  width: 36,
                  height: 4,
                  decoration: BoxDecoration(
                    color: Colors.white24,
                    borderRadius: BorderRadius.circular(2),
                  ),
                ),
                const SizedBox(height: 18),
                Text(
                  'Delete message?',
                  style: TextStyle(
                    color: textColor,
                    fontSize: 16,
                    fontWeight: FontWeight.w700,
                  ),
                ),
                const SizedBox(height: 6),
                Text(
                  isMine
                      ? 'Choose who to delete it for'
                      : 'This will only remove it from your view',
                  style: TextStyle(
                    color: textColor.withValues(alpha: 0.55),
                    fontSize: 13,
                  ),
                ),
                const SizedBox(height: 18),
                Container(
                  decoration: BoxDecoration(
                    color: bg,
                    borderRadius: BorderRadius.circular(16),
                  ),
                  child: Column(
                    children: [
                      // Delete for me — always available
                      InkWell(
                        borderRadius: isMine
                            ? const BorderRadius.vertical(
                                top: Radius.circular(16),
                              )
                            : BorderRadius.circular(16),
                        onTap: () => Navigator.of(sheetCtx).pop('for_me'),
                        child: Padding(
                          padding: const EdgeInsets.symmetric(
                            horizontal: 20,
                            vertical: 16,
                          ),
                          child: Row(
                            children: [
                              Icon(
                                Icons.person_outline_rounded,
                                color: scheme.error,
                                size: 20,
                              ),
                              const SizedBox(width: 16),
                              Text(
                                'Delete for me',
                                style: TextStyle(
                                  color: scheme.error,
                                  fontSize: 16,
                                  fontWeight: FontWeight.w600,
                                ),
                              ),
                            ],
                          ),
                        ),
                      ),
                      // Delete for everyone — own messages only
                      if (isMine) ...[
                        Divider(height: 1, color: divColor),
                        InkWell(
                          borderRadius: const BorderRadius.vertical(
                            bottom: Radius.circular(16),
                          ),
                          onTap: () =>
                              Navigator.of(sheetCtx).pop('for_everyone'),
                          child: Padding(
                            padding: const EdgeInsets.symmetric(
                              horizontal: 20,
                              vertical: 16,
                            ),
                            child: Row(
                              children: [
                                Icon(
                                  Icons.group_off_outlined,
                                  color: scheme.error,
                                  size: 20,
                                ),
                                const SizedBox(width: 16),
                                Text(
                                  'Delete for everyone',
                                  style: TextStyle(
                                    color: scheme.error,
                                    fontSize: 16,
                                    fontWeight: FontWeight.w600,
                                  ),
                                ),
                              ],
                            ),
                          ),
                        ),
                      ],
                    ],
                  ),
                ),
                const SizedBox(height: 10),
                // Cancel
                Container(
                  width: double.infinity,
                  decoration: BoxDecoration(
                    color: bg,
                    borderRadius: BorderRadius.circular(16),
                  ),
                  child: InkWell(
                    borderRadius: BorderRadius.circular(16),
                    onTap: () => Navigator.of(sheetCtx).pop(),
                    child: Padding(
                      padding: const EdgeInsets.symmetric(vertical: 16),
                      child: Center(
                        child: Text(
                          'Cancel',
                          style: TextStyle(
                            color: textColor,
                            fontSize: 16,
                            fontWeight: FontWeight.w600,
                          ),
                        ),
                      ),
                    ),
                  ),
                ),
              ],
            ),
          ),
        );
      },
    );

    if (result == null || !mounted) return;
    final controller = _chatController;

    if (result == 'for_me') {
      unawaited(controller.deleteMessageForMe(message.id));
      // Clean up any cached translation state for this message
      setState(() {
        _translatedMessageById.remove(message.id);
        _translateLangByMessageId.remove(message.id);
        _translatingIds.remove(message.id);
        _hiddenTranslatedMessageIds.remove(message.id);
        _selectedReactionByMessageId.remove(message.id);
        _localReactions.remove(message.id);
      });
      unawaited(_persistTranslationCache());
      unawaited(_persistReactionCache());
    } else if (result == 'for_everyone') {
      // Already removed optimistically inside the controller
      await controller.deleteMessageForEveryone(message.id);
      if (!mounted) return;
      setState(() {
        _translatedMessageById.remove(message.id);
        _translateLangByMessageId.remove(message.id);
        _translatingIds.remove(message.id);
        _hiddenTranslatedMessageIds.remove(message.id);
        _selectedReactionByMessageId.remove(message.id);
        _localReactions.remove(message.id);
      });
      unawaited(_persistTranslationCache());
      unawaited(_persistReactionCache());
    }
  }

  bool _canForwardMessage(ChatMessage message) {
    if (message.isPending || message.isFailed || message.isCallEvent) {
      return false;
    }
    return int.tryParse(message.id.trim()) != null;
  }

  Future<void> _forwardMessage(ChatMessage message) async {
    if (!_canForwardMessage(message)) {
      _showSnack('This message cannot be forwarded yet.');
      return;
    }
    try {
      final threads = await ref
          .read(talkRepositoryProvider)
          .fetchRecentThreads();
      if (!mounted) return;
      final selected = await showChatRecipientPicker(
        context: context,
        threads: threads,
        excludedPartnerIds: <String>{widget.userId, _meId},
        title: 'Forward message',
        actionLabel: 'Forward',
      );
      if (selected.isEmpty || !mounted) return;
      final count = await ref
          .read(directChatRepositoryProvider)
          .forwardMessage(
            messageId: message.id,
            recipientIds: selected.map((thread) => thread.partnerId).toList(),
          );
      if (!mounted) return;
      ref.invalidate(recentThreadsProvider);
      _showSnack(
        count == 1
            ? 'Message forwarded.'
            : count > 1
            ? 'Message forwarded to $count chats.'
            : 'No messages were forwarded.',
      );
    } catch (error) {
      if (!mounted) return;
      _showSnack(error.toString());
    }
  }

  Future<void> _editMessage(ChatMessage message) async {
    final controller = TextEditingController(text: message.text);
    final nextText = await showDialog<String>(
      context: context,
      builder: (dialogContext) {
        return AlertDialog(
          title: const Text('Edit message'),
          content: TextField(
            controller: controller,
            autofocus: true,
            minLines: 1,
            maxLines: 5,
            decoration: const InputDecoration(border: OutlineInputBorder()),
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.of(dialogContext).pop(),
              child: const Text('Cancel'),
            ),
            FilledButton(
              onPressed: () =>
                  Navigator.of(dialogContext).pop(controller.text.trim()),
              child: const Text('Save'),
            ),
          ],
        );
      },
    );
    controller.dispose();
    if (nextText == null || nextText.trim().isEmpty) return;
    final ok = await _chatController.editMessage(
      messageId: message.id,
      text: nextText,
    );
    if (!mounted) return;
    _showSnack(ok ? 'Message updated.' : 'Could not edit message.');
  }

  void _toggleMessageTranslation(ChatMessage message) {
    final cached = _translatedMessageById[message.id]?.trim() ?? '';
    final cachedLanguage = _translateLangByMessageId[message.id] ?? '';
    if (cached.isEmpty ||
        _normalizeLanguageKey(cachedLanguage) !=
            _normalizeLanguageKey(_effectiveTranslateTargetLanguage)) {
      unawaited(_runTranslate(message));
      return;
    }
    setState(() {
      if (_hiddenTranslatedMessageIds.contains(message.id)) {
        _hiddenTranslatedMessageIds.remove(message.id);
      } else {
        _hiddenTranslatedMessageIds.add(message.id);
      }
    });
    unawaited(_persistTranslationCache());
  }

  Future<void> _runTranslate(
    ChatMessage message, {
    String? overrideLanguage,
  }) async {
    final l10n = context.l10n;
    final lang = (overrideLanguage ?? _effectiveTranslateTargetLanguage).trim();
    final requestedLanguageKey = _normalizeLanguageKey(
      lang.isEmpty ? 'English' : lang,
    );
    if (_translatingIds.contains(message.id)) return; // already in flight
    setState(() => _translatingIds.add(message.id));
    try {
      final controller = _chatController;
      final result = await controller.translateMessage(
        message,
        targetLanguage: lang.isEmpty ? 'English' : lang,
      );
      if (!mounted) return;
      setState(() {
        _translatingIds.remove(message.id);
        if (_normalizeLanguageKey(_effectiveTranslateTargetLanguage) !=
            requestedLanguageKey) {
          return;
        }
        final text = result.output.trim();
        if (text.isNotEmpty) {
          _translatedMessageById[message.id] = text;
          _hiddenTranslatedMessageIds.remove(message.id);
          // Remember which language this translation is in so the bubble label stays accurate
          _translateLangByMessageId[message.id] =
              result.targetLanguage.trim().isNotEmpty
              ? result.targetLanguage.trim()
              : (lang.isEmpty ? 'English' : lang);
          unawaited(_persistTranslationCache());
        } else {
          _showSnack(
            result.note.trim().isNotEmpty
                ? result.note.trim()
                : l10n.noTranslationReturned,
          );
        }
      });
    } catch (_) {
      if (!mounted) return;
      setState(() => _translatingIds.remove(message.id));
      _showSnack(l10n.couldNotTranslate);
    }
  }

  /// Let the user pick a different language and re-translate immediately.
  Future<void> _runCorrection(ChatMessage message) async {
    final controller = _chatController;
    final result = await controller.correctMessage(
      message: message,
      tone: _correctionTone,
    );
    if (!mounted) return;
    await _showLearningResultSheet(
      title: 'Correction (${_correctionTone.toLowerCase()})',
      original: message.text.trim(),
      output: result.output,
      note: result.note,
      emptyFallback: 'No correction suggestion returned.',
    );
  }

  Future<void> _showLearningResultSheet({
    required String title,
    required String original,
    required String output,
    required String note,
    required String emptyFallback,
  }) async {
    await showModalBottomSheet<void>(
      context: context,
      isScrollControlled: true,
      builder: (context) => SafeArea(
        child: Padding(
          padding: const EdgeInsets.fromLTRB(16, 12, 16, 20),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(
                title,
                style: Theme.of(
                  context,
                ).textTheme.titleMedium?.copyWith(fontWeight: FontWeight.w800),
              ),
              const SizedBox(height: 10),
              if (original.isNotEmpty) ...[
                Text(
                  'Original',
                  style: Theme.of(
                    context,
                  ).textTheme.labelLarge?.copyWith(fontWeight: FontWeight.w700),
                ),
                const SizedBox(height: 4),
                Text(original),
                const SizedBox(height: 10),
              ],
              Text(
                'Result',
                style: Theme.of(
                  context,
                ).textTheme.labelLarge?.copyWith(fontWeight: FontWeight.w700),
              ),
              const SizedBox(height: 4),
              SelectableText(output.trim().isEmpty ? emptyFallback : output),
              if (note.trim().isNotEmpty) ...[
                const SizedBox(height: 10),
                Text(
                  note,
                  style: Theme.of(context).textTheme.bodySmall?.copyWith(
                    color: Theme.of(context).colorScheme.onSurfaceVariant,
                  ),
                ),
              ],
            ],
          ),
        ),
      ),
    );
  }

  Future<String?> _pickReportReason() async {
    return showModalBottomSheet<String>(
      context: context,
      builder: (context) => SafeArea(
        child: Wrap(
          children: [
            const ListTile(
              title: Text(
                'Report reason',
                style: TextStyle(fontWeight: FontWeight.w700),
              ),
            ),
            ListTile(
              leading: const Icon(Icons.gpp_bad_outlined),
              title: const Text('Harassment or hate'),
              onTap: () => Navigator.of(context).pop('harassment_or_hate'),
            ),
            ListTile(
              leading: const Icon(Icons.warning_amber_rounded),
              title: const Text('Spam or scam'),
              onTap: () => Navigator.of(context).pop('spam_or_scam'),
            ),
            ListTile(
              leading: const Icon(Icons.no_accounts_outlined),
              title: const Text('Inappropriate content'),
              onTap: () => Navigator.of(context).pop('inappropriate_content'),
            ),
          ],
        ),
      ),
    );
  }

  Future<bool> _confirmBlockToggle({required bool currentlyBlocked}) async {
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: Text(currentlyBlocked ? 'Unblock user?' : 'Block user?'),
        content: Text(
          currentlyBlocked
              ? 'You will be able to message and call this user again.'
              : 'You will no longer be able to message or call this user.',
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(context).pop(false),
            child: const Text('Cancel'),
          ),
          FilledButton(
            onPressed: () => Navigator.of(context).pop(true),
            child: Text(currentlyBlocked ? 'Unblock' : 'Block'),
          ),
        ],
      ),
    );
    return confirmed == true;
  }

  Future<void> _toggleFollowUser() async {
    if (_updatingFollow) return;
    setState(() => _updatingFollow = true);
    try {
      final data = await ref
          .read(apiClientProvider)
          .postJson('/users/${widget.userId}/follow');
      if (!mounted) return;
      setState(() {
        _followOverride = data['following'] == true;
      });
      ref.invalidate(profileBaseProvider(widget.userId));
      ref.invalidate(profileProvider(widget.userId));
      _showSnack(
        _followOverride == true ? 'Now following user.' : 'Unfollowed user.',
      );
    } catch (_) {
      if (!mounted) return;
      _showSnack('Could not update follow right now.');
    } finally {
      if (mounted) {
        setState(() => _updatingFollow = false);
      }
    }
  }

  Future<void> _setReceiveVoiceCallsForUser(bool value) async {
    final permissions = await ref
        .read(directChatRepositoryProvider)
        .updateDirectChatCallPreferences(
          userId: widget.userId,
          receiveVoiceCalls: value,
        );
    if (!mounted) return;
    setState(() {
      _receiveVoiceCallsFromUser = permissions.receiveVoiceCalls;
      _receiveVideoCallsFromUser = permissions.receiveVideoCalls;
    });
  }

  Future<void> _setReceiveVideoCallsForUser(bool value) async {
    final permissions = await ref
        .read(directChatRepositoryProvider)
        .updateDirectChatCallPreferences(
          userId: widget.userId,
          receiveVideoCalls: value,
        );
    if (!mounted) return;
    setState(() {
      _receiveVoiceCallsFromUser = permissions.receiveVoiceCalls;
      _receiveVideoCallsFromUser = permissions.receiveVideoCalls;
    });
  }

  Future<void> _showChatMenu() async {
    final scheme = Theme.of(context).colorScheme;
    final chatState = _chatState;
    final youBlockedUser = chatState.youBlockedUser;
    final partner = ref.read(profileProvider(widget.userId)).valueOrNull;
    final isFollowing = _followOverride ?? partner?.isFollowing ?? false;
    await showModalBottomSheet<void>(
      context: context,
      isScrollControlled: true,
      backgroundColor: Theme.of(context).colorScheme.surface,
      shape: const RoundedRectangleBorder(
        borderRadius: BorderRadius.vertical(top: Radius.circular(28)),
      ),
      builder: (sheetContext) {
        var receiveVoiceCallsFromUser = _receiveVoiceCallsFromUser;
        var receiveVideoCallsFromUser = _receiveVideoCallsFromUser;
        return StatefulBuilder(
          builder: (sheetBodyContext, setSheetState) {
            final maxHeight = MediaQuery.sizeOf(sheetBodyContext).height * 0.82;
            return SafeArea(
              top: false,
              child: ConstrainedBox(
                constraints: BoxConstraints(maxHeight: maxHeight),
                child: SingleChildScrollView(
                  padding: const EdgeInsets.fromLTRB(12, 12, 12, 18),
                  child: Column(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      Container(
                        width: 42,
                        height: 4,
                        margin: const EdgeInsets.only(bottom: 12),
                        decoration: BoxDecoration(
                          color: scheme.outlineVariant,
                          borderRadius: BorderRadius.circular(999),
                        ),
                      ),
                      ListTile(
                        leading: const Icon(Icons.person_outline_rounded),
                        title: const Text('View profile'),
                        onTap: () {
                          Navigator.of(sheetContext).pop();
                          context.push('/app/profile/${widget.userId}');
                        },
                      ),
                      if (TalkflixContactsActions.supported)
                        ListTile(
                          leading: const Icon(Icons.contact_phone_outlined),
                          title: const Text('Add to device contacts'),
                          onTap: () async {
                            Navigator.of(sheetContext).pop();
                            final user = await ref.read(
                              profileProvider(widget.userId).future,
                            );
                            if (!mounted) return;
                            await TalkflixContactsActions.saveTalkflixConnection(
                              context: context,
                              displayName: user.displayName,
                              userId: widget.userId,
                              username: user.username,
                            );
                          },
                        ),
                      ListTile(
                        leading: Icon(
                          _threadNotificationsMuted
                              ? Icons.notifications_active_outlined
                              : Icons.notifications_off_outlined,
                        ),
                        title: Text(
                          _threadNotificationsMuted
                              ? 'Unmute notifications'
                              : 'Mute notifications',
                        ),
                        onTap: () async {
                          Navigator.of(sheetContext).pop();
                          final prefs = await _sharedPreferencesFuture;
                          final next = !_threadNotificationsMuted;
                          await prefs.setBool(_threadNotificationPrefKey, next);
                          if (!mounted) return;
                          setState(() => _threadNotificationsMuted = next);
                          _showSnack(
                            next
                                ? 'Notifications muted for this chat.'
                                : 'Notifications enabled for this chat.',
                          );
                        },
                      ),
                      if (AppConfig.directCallsEnabled) ...[
                        SwitchListTile.adaptive(
                          secondary: const Icon(Icons.call_outlined),
                          title: const Text('Receive voice calls'),
                          subtitle: const Text(
                            'Allow this user to reach you by voice call.',
                          ),
                          value: receiveVoiceCallsFromUser,
                          onChanged: (value) async {
                            final previousVoice = receiveVoiceCallsFromUser;
                            final previousVideo = receiveVideoCallsFromUser;
                            setSheetState(() {
                              receiveVoiceCallsFromUser = value;
                            });
                            try {
                              await _setReceiveVoiceCallsForUser(value);
                              if (!mounted) return;
                              setSheetState(() {
                                receiveVoiceCallsFromUser =
                                    _receiveVoiceCallsFromUser;
                                receiveVideoCallsFromUser =
                                    _receiveVideoCallsFromUser;
                              });
                              _showSnack(
                                value
                                    ? 'Voice calls enabled for this user.'
                                    : 'Voice calls turned off for this user.',
                              );
                            } catch (error) {
                              if (!mounted) return;
                              setSheetState(() {
                                receiveVoiceCallsFromUser = previousVoice;
                                receiveVideoCallsFromUser = previousVideo;
                              });
                              _showSnack(
                                error.toString().replaceFirst(
                                  'Exception: ',
                                  '',
                                ),
                              );
                            }
                          },
                        ),
                        SwitchListTile.adaptive(
                          secondary: const Icon(Icons.videocam_outlined),
                          title: const Text('Receive video calls'),
                          subtitle: const Text(
                            'Allow this user to reach you by video call.',
                          ),
                          value: receiveVideoCallsFromUser,
                          onChanged: (value) async {
                            final previousVoice = receiveVoiceCallsFromUser;
                            final previousVideo = receiveVideoCallsFromUser;
                            setSheetState(() {
                              receiveVideoCallsFromUser = value;
                            });
                            try {
                              await _setReceiveVideoCallsForUser(value);
                              if (!mounted) return;
                              setSheetState(() {
                                receiveVoiceCallsFromUser =
                                    _receiveVoiceCallsFromUser;
                                receiveVideoCallsFromUser =
                                    _receiveVideoCallsFromUser;
                              });
                              _showSnack(
                                value
                                    ? 'Video calls enabled for this user.'
                                    : 'Video calls turned off for this user.',
                              );
                            } catch (error) {
                              if (!mounted) return;
                              setSheetState(() {
                                receiveVoiceCallsFromUser = previousVoice;
                                receiveVideoCallsFromUser = previousVideo;
                              });
                              _showSnack(
                                error.toString().replaceFirst(
                                  'Exception: ',
                                  '',
                                ),
                              );
                            }
                          },
                        ),
                      ],
                      ListTile(
                        leading: Icon(
                          isFollowing
                              ? Icons.person_remove_outlined
                              : Icons.person_add_alt_1_outlined,
                        ),
                        title: Text(
                          _updatingFollow
                              ? (isFollowing
                                    ? 'Updating follow...'
                                    : 'Following...')
                              : (isFollowing ? 'Unfollow user' : 'Follow user'),
                        ),
                        onTap: _updatingFollow
                            ? null
                            : () {
                                Navigator.of(sheetContext).pop();
                                unawaited(_toggleFollowUser());
                              },
                      ),
                      ListTile(
                        leading: const Icon(Icons.search_rounded),
                        title: const Text('Search in chat'),
                        onTap: () {
                          Navigator.of(sheetContext).pop();
                          unawaited(_openChatSearch());
                        },
                      ),
                      ListTile(
                        leading: const Icon(Icons.folder_copy_outlined),
                        title: const Text('Shared files'),
                        onTap: () {
                          Navigator.of(sheetContext).pop();
                          unawaited(_openSharedFiles());
                        },
                      ),
                      ListTile(
                        leading: Icon(Icons.flag_outlined, color: scheme.error),
                        title: Text(
                          'Report user',
                          style: TextStyle(
                            color: scheme.error,
                            fontWeight: FontWeight.w600,
                          ),
                        ),
                        onTap: () async {
                          Navigator.of(sheetContext).pop();
                          final reason = await _pickReportReason();
                          if (reason == null) return;
                          final ok = await ref
                              .read(
                                directChatControllerProvider(
                                  widget.userId,
                                ).notifier,
                              )
                              .reportUser(reason: reason);
                          _showSnack(
                            ok
                                ? 'Thanks. Your user report was submitted.'
                                : 'Could not submit report right now.',
                          );
                        },
                      ),
                      ListTile(
                        leading: Icon(
                          youBlockedUser
                              ? Icons.lock_open_rounded
                              : Icons.block_rounded,
                          color: youBlockedUser ? null : scheme.error,
                        ),
                        title: Text(
                          youBlockedUser ? 'Unblock user' : 'Block user',
                          style: TextStyle(
                            color: youBlockedUser ? null : scheme.error,
                            fontWeight: youBlockedUser ? null : FontWeight.w600,
                          ),
                        ),
                        onTap: () async {
                          Navigator.of(sheetContext).pop();
                          final confirmed = await _confirmBlockToggle(
                            currentlyBlocked: youBlockedUser,
                          );
                          if (!confirmed) return;
                          final notifier = _chatController;
                          final ok = youBlockedUser
                              ? await notifier.unblockUser()
                              : await notifier.blockUser();
                          _showSnack(
                            ok
                                ? (youBlockedUser
                                      ? 'User unblocked.'
                                      : 'User blocked. You can no longer message or call.')
                                : 'Could not update block state right now.',
                          );
                        },
                      ),
                    ],
                  ),
                ),
              ),
            );
          },
        );
      },
    );
  }

  void _scrollToBottom() {
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted || _isDisposingOrDisposed) return;
      if (!_scrollController.hasClients) return;
      _scrollController.animateTo(
        _scrollController.position.maxScrollExtent + 100,
        duration: const Duration(milliseconds: 220),
        curve: Curves.easeOut,
      );
    });
  }

  @override
  Widget build(BuildContext context) {
    final chatState = ref.watch(directChatControllerProvider(widget.userId));
    final me = ref.watch(sessionControllerProvider).user;
    final privacySettings = ref.watch(privacySettingsControllerProvider);
    _threadIdValue = chatState.threadId;
    _meIdValue = me?.id ?? '';
    final partner = ref.watch(profileProvider(widget.userId));
    final socketStatus = ref.watch(socketServiceProvider).status;
    final partnerName = partner.maybeWhen(
      data: (user) => user.displayName,
      orElse: () => 'Direct call',
    );
    final partnerPhotoUrl = partner.maybeWhen(
      data: (user) => user.profilePhotoUrl,
      orElse: () => '',
    );
    final callUsesVideo =
        _callVideoPreferred || _localVideoEnabledForUi || _remoteVideoEnabled;
    final subtitle = chatState.theirTyping
        ? 'typing...'
        : socketStatus != 'connected'
        ? 'reconnecting...'
        : !privacySettings.showOnlineStatus
        ? ''
        : chatState.partnerOnline
        ? 'online'
        : 'offline';
    final isDark = Theme.of(context).brightness == Brightness.dark;
    final scheme = Theme.of(context).colorScheme;
    final headerSurface = isDark ? const Color(0xFF111214) : Colors.white;
    final incomingBubble = isDark ? const Color(0xFF292A2E) : Colors.white;
    final incomingText = isDark ? Colors.white : Colors.black;
    final composerDraftText = _composerDraftText;
    final replyTarget = chatState.replyTargetMessage;
    final youBlockedUser = chatState.youBlockedUser;

    return Focus(
      onFocusChange: (hasFocus) {
        if (!hasFocus || !mounted) return;
        _refreshSafetyStateIfNeeded();
        unawaited(_syncTranslationTargetLanguage());
      },
      child: Scaffold(
        backgroundColor: scheme.surface,
        body: Stack(
          children: [
            Column(
              children: [
                if (socketStatus != 'connected')
                  RealtimeWarningBanner(
                    status: socketStatus,
                    scopeLabel: 'Chat',
                    connectingMessage: 'Reconnecting to chat...',
                    margin: const EdgeInsets.fromLTRB(12, 12, 12, 0),
                  ),
                Container(
                  color: headerSurface,
                  padding: EdgeInsets.fromLTRB(
                    14,
                    MediaQuery.of(context).padding.top + 10,
                    14,
                    12,
                  ),
                  child: Row(
                    children: [
                      IconButton(
                        onPressed: () => Navigator.of(context).maybePop(),
                        icon: const Icon(Icons.arrow_back_ios_new_rounded),
                      ),
                      Expanded(
                        child: partner.when(
                          data: (user) => Row(
                            children: [
                              ParticipantActionTarget(
                                onTap: () => context.push(
                                  '/app/profile/${widget.userId}',
                                ),
                                child: AppAvatar(
                                  label: user.displayName,
                                  imageUrl: user.profilePhotoUrl,
                                  radius: 20,
                                ),
                              ),
                              const SizedBox(width: 10),
                              Expanded(
                                child: Column(
                                  crossAxisAlignment: CrossAxisAlignment.start,
                                  children: [
                                    Text(
                                      user.displayName,
                                      maxLines: 1,
                                      overflow: TextOverflow.ellipsis,
                                      style: Theme.of(context)
                                          .textTheme
                                          .titleMedium
                                          ?.copyWith(
                                            fontWeight: FontWeight.w800,
                                          ),
                                    ),
                                    if (subtitle.trim().isNotEmpty)
                                      Text(
                                        subtitle,
                                        maxLines: 1,
                                        overflow: TextOverflow.ellipsis,
                                        style: Theme.of(context)
                                            .textTheme
                                            .bodySmall
                                            ?.copyWith(
                                              color: chatState.theirTyping
                                                  ? const Color(0xFF34C759)
                                                  : scheme.onSurfaceVariant,
                                              fontWeight: chatState.theirTyping
                                                  ? FontWeight.w600
                                                  : null,
                                            ),
                                      ),
                                  ],
                                ),
                              ),
                            ],
                          ),
                          error: (error, stackTrace) =>
                              Text('User ${widget.userId}'),
                          loading: () => const Text('Direct chat'),
                        ),
                      ),
                      if (AppConfig.directCallsEnabled) ...[
                        IconButton(
                          onPressed: chatState.blocked
                              ? null
                              : () => _startCall(video: false),
                          icon: const Icon(Icons.call_outlined),
                        ),
                        IconButton(
                          onPressed: chatState.blocked
                              ? null
                              : () => _startCall(video: true),
                          icon: const Icon(Icons.videocam_outlined),
                        ),
                      ],
                      IconButton(
                        onPressed: _showChatMenu,
                        icon: const Icon(Icons.more_horiz_rounded),
                      ),
                    ],
                  ),
                ),
                if (_hasActiveCallSession && _callMinimized)
                  _MinimizedCallBar(
                    partnerName: partnerName,
                    partnerPhotoUrl: partnerPhotoUrl,
                    status: _callConnected
                        ? _formatCallDuration(_callSeconds)
                        : (_callStatus ?? 'Connecting...'),
                    video: callUsesVideo,
                    onRestore: _restoreCallUi,
                    onHangup: _endCall,
                  ),
                Expanded(
                  child: Stack(
                    children: [
                      RefreshIndicator(
                        onRefresh: () => ref
                            .read(
                              directChatControllerProvider(
                                widget.userId,
                              ).notifier,
                            )
                            .reload(),
                        child: _MessageList(
                          scrollController: _scrollController,
                          messages: chatState.messages,
                          currentUserId: me?.id ?? '',
                          incomingBubble: incomingBubble,
                          incomingText: incomingText,
                          onMessageTap: _toggleMessageTranslation,
                          onMessageLongPress: _openMessageActions,
                          highlightedMessageId: _highlightedMessageId,
                          onRetryMessage: (messageId) {
                            ref
                                .read(
                                  directChatControllerProvider(
                                    widget.userId,
                                  ).notifier,
                                )
                                .retryFailedMessage(messageId);
                          },
                          onReplyPreviewTap: (replyToMessageId) {
                            _jumpToMessage(
                              chatState.messages,
                              replyToMessageId,
                            );
                          },
                          translatedByMessageId: _translatedMessageById,
                          autoplayTokenByMessageId: _autoPlayTokenByMessageId,
                          autoPlayEnabled: _autoPlayReceivedVoiceNotes,
                          autoPlayBadgeVisibleByMessageId:
                              _autoPlayBadgeVisibleByMessageId,
                          onIncomingAudioPlaybackStarted:
                              _onIncomingAudioPlaybackStarted,
                          onIncomingAudioPlaybackCompleted:
                              _onIncomingAudioPlaybackCompleted,
                          localReactions: _localReactions,
                          translatingIds: _translatingIds,
                          hiddenTranslatedMessageIds:
                              _hiddenTranslatedMessageIds,
                          onToggleTranslation: _toggleMessageTranslation,
                        ),
                      ),
                      if (chatState.isLoading && chatState.messages.isEmpty)
                        const Positioned.fill(
                          child: Center(child: CircularProgressIndicator()),
                        ),
                    ],
                  ),
                ),
                if (chatState.errorMessage != null)
                  Padding(
                    padding: const EdgeInsets.fromLTRB(16, 0, 16, 8),
                    child: Row(
                      children: [
                        Expanded(
                          child: Text(
                            chatState.errorMessage!,
                            style: TextStyle(
                              color: Theme.of(context).colorScheme.error,
                            ),
                          ),
                        ),
                        const SizedBox(width: 12),
                        OutlinedButton(
                          onPressed: () => ref
                              .read(
                                directChatControllerProvider(
                                  widget.userId,
                                ).notifier,
                              )
                              .reload(),
                          child: const Text('Retry'),
                        ),
                      ],
                    ),
                  ),
                SafeArea(
                  top: false,
                  bottom: false,
                  child: Padding(
                    padding: const EdgeInsets.fromLTRB(16, 8, 16, 0),
                    child: Column(
                      children: [
                        if (_pendingAudioUrl != null)
                          Container(
                            width: double.infinity,
                            margin: const EdgeInsets.only(bottom: 10),
                            padding: const EdgeInsets.symmetric(
                              horizontal: 14,
                              vertical: 12,
                            ),
                            decoration: BoxDecoration(
                              color: isDark
                                  ? const Color(0xFF1C1D20)
                                  : Colors.white,
                              borderRadius: BorderRadius.circular(24),
                              border: Border.all(color: scheme.outlineVariant),
                            ),
                            child: Row(
                              children: [
                                Expanded(
                                  child: AudioMessagePlayer(
                                    source: _pendingAudioUrl!,
                                    durationSeconds: _pendingAudioDuration,
                                    mine: true,
                                  ),
                                ),
                                const SizedBox(width: 8),
                                TextButton(
                                  onPressed: _discardPendingAudio,
                                  child: const Text('Discard'),
                                ),
                              ],
                            ),
                          ),
                        if (replyTarget != null)
                          Container(
                            width: double.infinity,
                            margin: const EdgeInsets.only(bottom: 10),
                            padding: const EdgeInsets.fromLTRB(12, 10, 8, 10),
                            decoration: BoxDecoration(
                              color: isDark
                                  ? const Color(0xFF1C1D20)
                                  : Colors.white,
                              borderRadius: BorderRadius.circular(16),
                              border: Border.all(color: scheme.outlineVariant),
                            ),
                            child: Row(
                              children: [
                                Expanded(
                                  child: Column(
                                    crossAxisAlignment:
                                        CrossAxisAlignment.start,
                                    children: [
                                      Text(
                                        'Replying to message',
                                        style: Theme.of(context)
                                            .textTheme
                                            .labelMedium
                                            ?.copyWith(
                                              fontWeight: FontWeight.w700,
                                              color: scheme.onSurfaceVariant,
                                            ),
                                      ),
                                      const SizedBox(height: 2),
                                      Text(
                                        replyTarget.text.isNotEmpty
                                            ? replyTarget.text
                                            : '[${replyTarget.type}]',
                                        maxLines: 1,
                                        overflow: TextOverflow.ellipsis,
                                        style: Theme.of(
                                          context,
                                        ).textTheme.bodyMedium,
                                      ),
                                    ],
                                  ),
                                ),
                                IconButton(
                                  onPressed: () {
                                    ref
                                        .read(
                                          directChatControllerProvider(
                                            widget.userId,
                                          ).notifier,
                                        )
                                        .setReplyTarget(null);
                                  },
                                  icon: const Icon(Icons.close_rounded),
                                  tooltip: 'Cancel reply',
                                ),
                              ],
                            ),
                          ),
                        if (_recording)
                          Container(
                            width: double.infinity,
                            margin: const EdgeInsets.only(bottom: 10),
                            padding: const EdgeInsets.symmetric(
                              horizontal: 16,
                              vertical: 12,
                            ),
                            decoration: BoxDecoration(
                              color: isDark
                                  ? const Color(0xFF1C1D20)
                                  : Colors.white,
                              borderRadius: BorderRadius.circular(24),
                              border: Border.all(color: scheme.outlineVariant),
                            ),
                            child: Row(
                              children: [
                                const Icon(
                                  Icons.fiber_manual_record_rounded,
                                  color: talkflixPrimary,
                                  size: 16,
                                ),
                                const SizedBox(width: 8),
                                Expanded(
                                  child: Text(
                                    'Recording voice note ${_recordingSeconds}s / 60s',
                                    style: Theme.of(context)
                                        .textTheme
                                        .bodyMedium
                                        ?.copyWith(fontWeight: FontWeight.w700),
                                  ),
                                ),
                                TextButton(
                                  onPressed: _toggleRecording,
                                  child: const Text('Stop'),
                                ),
                              ],
                            ),
                          ),
                        if (chatState.blocked)
                          Container(
                            width: double.infinity,
                            margin: const EdgeInsets.only(bottom: 10),
                            padding: const EdgeInsets.symmetric(
                              horizontal: 14,
                              vertical: 10,
                            ),
                            decoration: BoxDecoration(
                              color: Theme.of(
                                context,
                              ).colorScheme.errorContainer,
                              borderRadius: BorderRadius.circular(14),
                            ),
                            child: Text(
                              youBlockedUser
                                  ? 'You blocked this user. Unblock from the menu to chat again.'
                                  : 'Messaging is unavailable for this chat right now.',
                              style: Theme.of(context).textTheme.bodySmall
                                  ?.copyWith(
                                    color: Theme.of(
                                      context,
                                    ).colorScheme.onErrorContainer,
                                    fontWeight: FontWeight.w600,
                                  ),
                            ),
                          ),
                        Container(
                          padding: EdgeInsets.fromLTRB(
                            12,
                            10,
                            10,
                            10 + MediaQuery.of(context).padding.bottom,
                          ),
                          decoration: BoxDecoration(
                            color: isDark
                                ? const Color(0xFF16171A)
                                : Colors.white,
                            borderRadius: BorderRadius.circular(28),
                            border: Border.all(color: scheme.outlineVariant),
                          ),
                          child: Row(
                            children: [
                              Container(
                                width: 42,
                                height: 42,
                                decoration: BoxDecoration(
                                  color: isDark
                                      ? const Color(0xFF242529)
                                      : const Color(0xFFF1F2F4),
                                  shape: BoxShape.circle,
                                ),
                                child: IconButton(
                                  onPressed:
                                      socketStatus != 'connected' ||
                                          chatState.isSending ||
                                          chatState.blocked
                                      ? null
                                      : _openAttachmentMenu,
                                  padding: EdgeInsets.zero,
                                  icon: Icon(
                                    Icons.add_rounded,
                                    color: scheme.onSurface,
                                    size: 20,
                                  ),
                                  tooltip: 'Add attachment',
                                ),
                              ),
                              const SizedBox(width: 10),
                              Expanded(
                                child: TextField(
                                  controller: _composerController,
                                  minLines: 1,
                                  maxLines: 5,
                                  enabled:
                                      socketStatus == 'connected' &&
                                      !chatState.blocked &&
                                      !_composerAssistBusy,
                                  textCapitalization:
                                      TextCapitalization.sentences,
                                  keyboardType: TextInputType.multiline,
                                  textInputAction: TextInputAction.newline,
                                  onChanged: _handleDraftChanged,
                                  style: Theme.of(context).textTheme.bodyLarge,
                                  decoration: InputDecoration(
                                    hintText: 'Message...',
                                    hintStyle: TextStyle(
                                      color: scheme.onSurfaceVariant,
                                    ),
                                    border: InputBorder.none,
                                    isCollapsed: true,
                                  ),
                                ),
                              ),
                              AnimatedSwitcher(
                                duration: const Duration(milliseconds: 180),
                                child: composerDraftText.isEmpty
                                    ? const SizedBox.shrink()
                                    : Padding(
                                        key: const ValueKey(
                                          'draft-assist-button',
                                        ),
                                        padding: const EdgeInsets.only(
                                          left: 10,
                                          right: 10,
                                        ),
                                        child: Container(
                                          width: 38,
                                          height: 38,
                                          decoration: BoxDecoration(
                                            color: isDark
                                                ? const Color(0xFF242529)
                                                : const Color(0xFFF1F2F4),
                                            shape: BoxShape.circle,
                                          ),
                                          child: IconButton(
                                            onPressed:
                                                socketStatus != 'connected' ||
                                                    chatState.isSending ||
                                                    chatState.blocked ||
                                                    _composerAssistBusy
                                                ? null
                                                : _openDraftAssistMenu,
                                            tooltip: 'Draft tools',
                                            padding: EdgeInsets.zero,
                                            icon: _composerAssistBusy
                                                ? SizedBox(
                                                    width: 18,
                                                    height: 18,
                                                    child:
                                                        CircularProgressIndicator(
                                                          strokeWidth: 2.2,
                                                          color:
                                                              scheme.onSurface,
                                                        ),
                                                  )
                                                : Icon(
                                                    Icons.auto_fix_high_rounded,
                                                    color: scheme.onSurface,
                                                    size: 18,
                                                  ),
                                          ),
                                        ),
                                      ),
                              ),
                              Container(
                                width: 46,
                                height: 46,
                                decoration: BoxDecoration(
                                  color:
                                      composerDraftText.isNotEmpty ||
                                          _pendingAudioUrl != null
                                      ? talkflixPrimary
                                      : (isDark
                                            ? const Color(0xFF242529)
                                            : const Color(0xFFF1F2F4)),
                                  shape: BoxShape.circle,
                                ),
                                child: IconButton(
                                  onPressed:
                                      socketStatus != 'connected' ||
                                          chatState.isSending ||
                                          chatState.blocked ||
                                          _composerAssistBusy
                                      ? null
                                      : _handleComposerPrimaryAction,
                                  padding: EdgeInsets.zero,
                                  icon: Icon(
                                    composerDraftText.isNotEmpty ||
                                            _pendingAudioUrl != null
                                        ? Icons.send_rounded
                                        : _recording
                                        ? Icons.stop_circle_outlined
                                        : Icons.mic_none_outlined,
                                    color:
                                        composerDraftText.isNotEmpty ||
                                            _pendingAudioUrl != null
                                        ? Colors.white
                                        : scheme.onSurface,
                                    size: 22,
                                  ),
                                ),
                              ),
                            ],
                          ),
                        ),
                      ],
                    ),
                  ),
                ),
              ],
            ),
            if (_hasActiveCallSession && !_callMinimized)
              Positioned.fill(
                child: _CallOverlay(
                  incoming: _callIncoming,
                  connected: _callConnected,
                  remoteVideoEnabled: _remoteVideoEnabled,
                  localVideoEnabled: _localVideoEnabledForUi,
                  localPreviewReady: _localPreviewReady,
                  localPreviewGeneration: _localPreviewGeneration,
                  localVideoMirrored: _localVideoMirrored,
                  micEnabled: _micEnabled,
                  speakerOn: _speakerOn,
                  status: _callConnected ? null : _callStatus,
                  partnerName: partnerName,
                  partnerPhotoUrl: partnerPhotoUrl,
                  callSeconds: _callSeconds,
                  localRenderer: _localRenderer,
                  remoteRenderer: _remoteRenderer,
                  onMinimize: _callIncoming ? null : _minimizeCallUi,
                  onAccept: chatState.blocked ? null : _acceptIncomingCall,
                  onDecline: _declineIncomingCall,
                  onHangup: _endCall,
                  onToggleMute: _toggleMute,
                  onToggleCamera: _toggleCamera,
                  onToggleSpeaker: _toggleSpeaker,
                  onSwitchCamera: _switchCamera,
                ),
              ),
          ],
        ),
      ),
    );
  }

  String _formatCallDuration(int totalSeconds) {
    final minutes = (totalSeconds ~/ 60).toString().padLeft(2, '0');
    final seconds = (totalSeconds % 60).toString().padLeft(2, '0');
    return '$minutes:$seconds';
  }
}

class _MessageList extends StatelessWidget {
  const _MessageList({
    required this.scrollController,
    required this.messages,

    required this.currentUserId,
    required this.incomingBubble,
    required this.incomingText,
    required this.onMessageTap,
    required this.onMessageLongPress,
    required this.onRetryMessage,
    required this.onReplyPreviewTap,
    required this.translatedByMessageId,
    required this.autoplayTokenByMessageId,
    required this.autoPlayEnabled,
    required this.autoPlayBadgeVisibleByMessageId,
    required this.onIncomingAudioPlaybackStarted,
    required this.onIncomingAudioPlaybackCompleted,
    required this.localReactions,
    required this.translatingIds,
    required this.hiddenTranslatedMessageIds,
    required this.onToggleTranslation,
    this.highlightedMessageId,
  });

  final ScrollController scrollController;
  final List<ChatMessage> messages;
  final String currentUserId;
  final Color incomingBubble;
  final Color incomingText;
  final ValueChanged<ChatMessage> onMessageTap;
  final ValueChanged<ChatMessage> onMessageLongPress;
  final ValueChanged<String> onRetryMessage;
  final ValueChanged<String> onReplyPreviewTap;
  final Map<String, String> translatedByMessageId;
  final Map<String, int> autoplayTokenByMessageId;
  final bool autoPlayEnabled;
  final Map<String, bool> autoPlayBadgeVisibleByMessageId;
  final ValueChanged<String> onIncomingAudioPlaybackStarted;
  final ValueChanged<String> onIncomingAudioPlaybackCompleted;
  final Map<String, Map<String, int>> localReactions;
  final Set<String> translatingIds;
  final Set<String> hiddenTranslatedMessageIds;
  final ValueChanged<ChatMessage> onToggleTranslation;
  final String? highlightedMessageId;

  @override
  Widget build(BuildContext context) {
    final messagesById = <String, ChatMessage>{
      for (final message in messages)
        if (message.id.isNotEmpty) message.id: message,
      for (final message in messages)
        if (message.clientMessageId.isNotEmpty)
          message.clientMessageId: message,
    };
    if (messages.isEmpty) {
      return ListView(
        controller: scrollController,
        physics: const AlwaysScrollableScrollPhysics(),
        padding: const EdgeInsets.fromLTRB(18, 18, 18, 8),
        children: [
          const SizedBox(height: 120),
          Center(
            child: Container(
              padding: const EdgeInsets.symmetric(horizontal: 18, vertical: 16),
              decoration: BoxDecoration(
                color: Theme.of(context).colorScheme.surfaceContainerHighest,
                borderRadius: BorderRadius.circular(28),
              ),
              child: const Text(
                'No messages yet. Say hello to start the conversation.',
              ),
            ),
          ),
        ],
      );
    }

    return ListView.builder(
      controller: scrollController,
      padding: const EdgeInsets.fromLTRB(18, 18, 18, 8),
      itemCount: messages.length,
      itemBuilder: (context, index) {
        final message = messages[index];
        if (message.isCallEvent) {
          return Padding(
            padding: const EdgeInsets.only(bottom: 10),
            child: _CallHistoryEventRow(message: message),
          );
        }
        final isMine = message.fromUserId == currentUserId;
        final isImageMessage =
            message.type == 'image' && message.imageUrl.isNotEmpty;
        final isLastMine =
            isMine &&
            messages
                .skip(index + 1)
                .every(
                  (nextMessage) => nextMessage.fromUserId != currentUserId,
                );
        final reactions = <String, int>{...message.reactions};
        final local = localReactions[message.id];
        if (local != null && local.isNotEmpty) {
          reactions.addAll(local);
        }
        final isTranslating = translatingIds.contains(message.id);
        final translatedText = translatedByMessageId[message.id]?.trim() ?? '';
        final hasSavedTranslation = translatedText.isNotEmpty;
        final isTranslationHidden = hiddenTranslatedMessageIds.contains(
          message.id,
        );
        return Padding(
          padding: const EdgeInsets.only(bottom: 10),
          child: Align(
            alignment: isMine ? Alignment.centerRight : Alignment.centerLeft,
            child: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: isMine
                  ? CrossAxisAlignment.end
                  : CrossAxisAlignment.start,
              children: [
                GestureDetector(
                  onTap: () => onMessageTap(message),
                  onLongPress: () => onMessageLongPress(message),
                  child: ConstrainedBox(
                    constraints: const BoxConstraints(maxWidth: 284),
                    child: DecoratedBox(
                      decoration: BoxDecoration(
                        color: message.isFailed
                            ? Theme.of(context).colorScheme.errorContainer
                            : (isMine ? talkflixPrimary : incomingBubble),
                        borderRadius: BorderRadius.circular(20),
                        border: highlightedMessageId == message.id
                            ? Border.all(
                                color: Theme.of(context).colorScheme.tertiary,
                                width: 2,
                              )
                            : (isMine
                                  ? null
                                  : Border.all(
                                      color: Theme.of(
                                        context,
                                      ).colorScheme.outlineVariant,
                                    )),
                      ),
                      child: Padding(
                        padding: isImageMessage
                            ? EdgeInsets.zero
                            : const EdgeInsets.symmetric(
                                horizontal: 16,
                                vertical: 11,
                              ),
                        child: Column(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            DefaultTextStyle.merge(
                              style: TextStyle(
                                color: message.isFailed
                                    ? Theme.of(
                                        context,
                                      ).colorScheme.onErrorContainer
                                    : (isMine ? Colors.white : incomingText),
                                fontSize: 16,
                                fontWeight: FontWeight.w600,
                              ),
                              child: _MessageBody(
                                message: message,
                                mine: isMine,
                                messagesById: messagesById,
                                onReplyPreviewTap: onReplyPreviewTap,
                                translatedText: isTranslationHidden
                                    ? null
                                    : (hasSavedTranslation
                                          ? translatedText
                                          : null),
                                isTranslating: isTranslating,
                                onToggleTranslation: () =>
                                    onToggleTranslation(message),
                                autoplayToken:
                                    autoplayTokenByMessageId[message.id] ?? 0,
                                showAutoplayBadge:
                                    autoPlayEnabled &&
                                    !isMine &&
                                    message.type == 'audio' &&
                                    (autoPlayBadgeVisibleByMessageId[message
                                            .id] ??
                                        false),
                                onAudioPlaybackStarted: () =>
                                    onIncomingAudioPlaybackStarted(message.id),
                                onAudioPlaybackCompleted: () =>
                                    onIncomingAudioPlaybackCompleted(
                                      message.id,
                                    ),
                              ),
                            ),
                            if (!isImageMessage) const SizedBox(height: 6),
                            if (message.canRetry) ...[
                              GestureDetector(
                                onTap: () => onRetryMessage(message.id),
                                child: Text(
                                  'Failed to send - tap to retry',
                                  style: Theme.of(context).textTheme.bodySmall
                                      ?.copyWith(
                                        color: Theme.of(
                                          context,
                                        ).colorScheme.error,
                                        fontWeight: FontWeight.w700,
                                      ),
                                ),
                              ),
                              const SizedBox(height: 6),
                            ],
                            if (!isImageMessage)
                              Row(
                                mainAxisSize: MainAxisSize.min,
                                children: [
                                  Text(
                                    formatDirectMessageTime(message.createdAt),
                                    style: Theme.of(context).textTheme.bodySmall
                                        ?.copyWith(
                                          color: isMine
                                              ? Colors.white.withValues(
                                                  alpha: 0.78,
                                                )
                                              : Theme.of(
                                                  context,
                                                ).colorScheme.onSurfaceVariant,
                                        ),
                                  ),
                                  if (message.editedAt != null) ...[
                                    const SizedBox(width: 6),
                                    Text(
                                      'Edited',
                                      style: Theme.of(context)
                                          .textTheme
                                          .bodySmall
                                          ?.copyWith(
                                            color: isMine
                                                ? Colors.white.withValues(
                                                    alpha: 0.72,
                                                  )
                                                : Theme.of(context)
                                                      .colorScheme
                                                      .onSurfaceVariant,
                                            fontWeight: FontWeight.w600,
                                          ),
                                    ),
                                  ],
                                  if (isLastMine) ...[
                                    const SizedBox(width: 8),
                                    Text(
                                      _formatMessageStatus(message.status),
                                      style: Theme.of(context)
                                          .textTheme
                                          .bodySmall
                                          ?.copyWith(
                                            color: isMine
                                                ? Colors.white.withValues(
                                                    alpha: 0.86,
                                                  )
                                                : Theme.of(context)
                                                      .colorScheme
                                                      .onSurfaceVariant,
                                            fontWeight: FontWeight.w700,
                                          ),
                                    ),
                                  ],
                                ],
                              ),
                          ],
                        ),
                      ),
                    ),
                  ),
                ),
                // ── Telegram-style reaction chips ─────────────────────
                if (reactions.isNotEmpty)
                  Padding(
                    padding: const EdgeInsets.only(top: 5),
                    child: Wrap(
                      spacing: 5,
                      runSpacing: 4,
                      children: reactions.entries.map((e) {
                        return _ReactionChip(
                          emoji: e.key,
                          count: e.value,
                          isMine: isMine,
                        );
                      }).toList(),
                    ),
                  ),
              ], // Column children
            ), // Column
          ),
        );
      },
    );
  }
}

String _formatMessageStatus(String status) {
  switch (status.trim().toLowerCase()) {
    case 'sending':
      return 'Sending...';
    case 'failed':
      return 'Failed';
    case 'read':
      return 'Seen';
    case 'delivered':
      return 'Delivered';
    case 'unread':
      return 'Unread';
    default:
      return 'Sent';
  }
}

String formatDirectMessageTime(DateTime value) {
  final local = value.toLocal();
  final hour = local.hour % 12 == 0 ? 12 : local.hour % 12;
  final minute = local.minute.toString().padLeft(2, '0');
  final suffix = local.hour >= 12 ? 'PM' : 'AM';
  return '$hour:$minute $suffix';
}

class _CallHistoryEventRow extends StatelessWidget {
  const _CallHistoryEventRow({required this.message});

  final ChatMessage message;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return Center(
      child: DecoratedBox(
        decoration: BoxDecoration(
          color: scheme.surfaceContainerHighest,
          borderRadius: BorderRadius.circular(18),
          border: Border.all(color: scheme.outlineVariant),
        ),
        child: Padding(
          padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 8),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              Text(
                message.text,
                textAlign: TextAlign.center,
                style: Theme.of(context).textTheme.labelLarge?.copyWith(
                  color: scheme.onSurfaceVariant,
                  fontWeight: FontWeight.w700,
                ),
              ),
              const SizedBox(height: 2),
              Text(
                formatDirectMessageTime(message.createdAt),
                style: Theme.of(
                  context,
                ).textTheme.bodySmall?.copyWith(color: scheme.onSurfaceVariant),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

class _MessageBody extends StatelessWidget {
  const _MessageBody({
    required this.message,
    required this.mine,
    required this.messagesById,
    required this.onReplyPreviewTap,
    required this.isTranslating,
    this.onToggleTranslation,
    this.translatedText,
    this.autoplayToken = 0,
    this.showAutoplayBadge = false,
    this.onAudioPlaybackStarted,
    this.onAudioPlaybackCompleted,
  });

  final ChatMessage message;
  final bool mine;
  final Map<String, ChatMessage> messagesById;
  final ValueChanged<String> onReplyPreviewTap;
  final bool isTranslating;
  final VoidCallback? onToggleTranslation;
  final String? translatedText;
  final int autoplayToken;
  final bool showAutoplayBadge;
  final VoidCallback? onAudioPlaybackStarted;
  final VoidCallback? onAudioPlaybackCompleted;

  @override
  Widget build(BuildContext context) {
    if (message.replyToMessageId.isNotEmpty) {
      final repliedTo = messagesById[message.replyToMessageId];
      return Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          GestureDetector(
            onTap: () => onReplyPreviewTap(message.replyToMessageId),
            child: Container(
              width: double.infinity,
              margin: const EdgeInsets.only(bottom: 6),
              padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 6),
              decoration: BoxDecoration(
                color: mine ? Colors.white24 : Colors.black12,
                borderRadius: BorderRadius.circular(10),
              ),
              child: Text(
                repliedTo == null
                    ? 'Replying to message'
                    : _replyPreviewText(repliedTo),
                style: Theme.of(context).textTheme.labelSmall?.copyWith(
                  color: mine
                      ? Colors.white.withValues(alpha: 0.95)
                      : Theme.of(context).colorScheme.onSurfaceVariant,
                  fontWeight: FontWeight.w700,
                ),
              ),
            ),
          ),
          _MessageBodyContent(
            message: message,
            mine: mine,
            isTranslating: isTranslating,
            onToggleTranslation: onToggleTranslation,
            translatedText: translatedText,
            autoplayToken: autoplayToken,
            showAutoplayBadge: showAutoplayBadge,
            onAudioPlaybackStarted: onAudioPlaybackStarted,
            onAudioPlaybackCompleted: onAudioPlaybackCompleted,
          ),
        ],
      );
    }
    return _MessageBodyContent(
      message: message,
      mine: mine,
      isTranslating: isTranslating,
      onToggleTranslation: onToggleTranslation,
      translatedText: translatedText,
      autoplayToken: autoplayToken,
      showAutoplayBadge: showAutoplayBadge,
      onAudioPlaybackStarted: onAudioPlaybackStarted,
      onAudioPlaybackCompleted: onAudioPlaybackCompleted,
    );
  }
}

String _replyPreviewText(ChatMessage message) {
  if (message.text.trim().isNotEmpty) return message.text.trim();
  if (message.type == 'image') return '[Photo]';
  if (message.type == 'audio') return '[Voice note]';
  if (message.type == 'file') {
    final name = message.fileName.trim();
    return name.isEmpty ? '[File]' : name;
  }
  return '[${message.type}]';
}

class _MessageBodyContent extends StatelessWidget {
  const _MessageBodyContent({
    required this.message,
    required this.mine,
    required this.isTranslating,
    this.onToggleTranslation,
    this.translatedText,
    this.autoplayToken = 0,
    this.showAutoplayBadge = false,
    this.onAudioPlaybackStarted,
    this.onAudioPlaybackCompleted,
  });

  final ChatMessage message;
  final bool mine;
  final bool isTranslating;
  final VoidCallback? onToggleTranslation;
  final String? translatedText;
  final int autoplayToken;
  final bool showAutoplayBadge;
  final VoidCallback? onAudioPlaybackStarted;
  final VoidCallback? onAudioPlaybackCompleted;

  @override
  Widget build(BuildContext context) {
    final l10n = context.l10n;
    if (message.type == 'image' && message.imageUrl.isNotEmpty) {
      return _DirectImageBubble(source: message.imageUrl, heroTag: message.id);
    }

    if (message.type == 'audio') {
      return Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          if (showAutoplayBadge)
            AnimatedOpacity(
              duration: const Duration(milliseconds: 280),
              curve: Curves.easeOut,
              opacity: showAutoplayBadge ? 1 : 0,
              child: Padding(
                padding: const EdgeInsets.only(bottom: 6),
                child: Container(
                  padding: const EdgeInsets.symmetric(
                    horizontal: 8,
                    vertical: 4,
                  ),
                  decoration: BoxDecoration(
                    color: Theme.of(
                      context,
                    ).colorScheme.onSurface.withValues(alpha: 0.08),
                    borderRadius: BorderRadius.circular(999),
                  ),
                  child: Text(
                    'Auto-play enabled',
                    style: Theme.of(context).textTheme.labelSmall?.copyWith(
                      fontWeight: FontWeight.w700,
                    ),
                  ),
                ),
              ),
            ),
          AudioMessagePlayer(
            source: message.audioUrl,
            durationSeconds: message.audioDuration,
            mine: mine,
            autoplayToken: autoplayToken,
            onPlaybackStarted: onAudioPlaybackStarted,
            onPlaybackCompleted: onAudioPlaybackCompleted,
          ),
        ],
      );
    }

    if (message.type == 'file') {
      return _DirectFileBubble(message: message, mine: mine);
    }

    final text = message.text.isEmpty ? '[${message.type}]' : message.text;
    final canTranslate =
        message.type == 'text' && message.text.trim().isNotEmpty;
    final hasVisibleTranslation = translatedText?.trim().isNotEmpty ?? false;
    if (message.type == 'text' && hasVisibleTranslation) {
      final translationColor = mine
          ? Colors.white.withValues(alpha: 0.85)
          : Theme.of(context).colorScheme.onSurfaceVariant;

      return Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(
            translatedText!,
            style: Theme.of(context).textTheme.bodyMedium?.copyWith(
              fontStyle: FontStyle.italic,
              color: translationColor,
              fontWeight: FontWeight.w500,
              height: 1.35,
            ),
          ),
          _DirectLinkPreview(message: message, mine: mine),
        ],
      );
    }
    if (!canTranslate) {
      return Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(text),
          _DirectLinkPreview(message: message, mine: mine),
        ],
      );
    }
    if (isTranslating) {
      final loadingColor = mine
          ? Colors.white.withValues(alpha: 0.85)
          : Theme.of(context).colorScheme.onSurfaceVariant;
      return Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(text),
          _DirectLinkPreview(message: message, mine: mine),
          const SizedBox(height: 8),
          Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              SizedBox(
                width: 12,
                height: 12,
                child: CircularProgressIndicator(
                  strokeWidth: 1.6,
                  valueColor: AlwaysStoppedAnimation<Color>(loadingColor),
                ),
              ),
              const SizedBox(width: 6),
              Text(
                l10n.translating,
                style: Theme.of(context).textTheme.bodySmall?.copyWith(
                  color: loadingColor,
                  fontWeight: FontWeight.w700,
                ),
              ),
            ],
          ),
        ],
      );
    }
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(text),
        _DirectLinkPreview(message: message, mine: mine),
      ],
    );
  }
}

class _DirectFileBubble extends StatelessWidget {
  const _DirectFileBubble({required this.message, required this.mine});

  final ChatMessage message;
  final bool mine;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final fileName = message.fileName.trim().isEmpty
        ? 'Attachment'
        : message.fileName.trim();
    final label = _formatFileSize(message.fileSize);
    return InkWell(
      borderRadius: BorderRadius.circular(14),
      onTap: () async {
        final url = resolveMediaUrl(message.fileUrl);
        final uri = Uri.tryParse(url);
        if (uri == null) return;
        await launchUrl(uri, mode: LaunchMode.externalApplication);
      },
      child: Container(
        constraints: const BoxConstraints(minWidth: 210),
        padding: const EdgeInsets.all(12),
        decoration: BoxDecoration(
          color: mine ? Colors.white.withValues(alpha: 0.14) : scheme.surface,
          borderRadius: BorderRadius.circular(14),
          border: Border.all(
            color: mine
                ? Colors.white.withValues(alpha: 0.18)
                : scheme.outlineVariant,
          ),
        ),
        child: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(
              Icons.insert_drive_file_outlined,
              color: mine ? Colors.white : scheme.primary,
            ),
            const SizedBox(width: 10),
            Flexible(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    fileName,
                    maxLines: 2,
                    overflow: TextOverflow.ellipsis,
                    style: Theme.of(context).textTheme.bodyMedium?.copyWith(
                      color: mine ? Colors.white : scheme.onSurface,
                      fontWeight: FontWeight.w800,
                    ),
                  ),
                  if (label.isNotEmpty)
                    Text(
                      label,
                      style: Theme.of(context).textTheme.bodySmall?.copyWith(
                        color: mine
                            ? Colors.white.withValues(alpha: 0.78)
                            : scheme.onSurfaceVariant,
                      ),
                    ),
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }
}

class _DirectLinkPreview extends StatelessWidget {
  const _DirectLinkPreview({required this.message, required this.mine});

  final ChatMessage message;
  final bool mine;

  @override
  Widget build(BuildContext context) {
    if (message.linkPreview.isEmpty) return const SizedBox.shrink();
    final url = message.linkPreview['url']?.toString().trim() ?? '';
    if (url.isEmpty) return const SizedBox.shrink();
    final domain = message.linkPreview['domain']?.toString().trim() ?? url;
    final scheme = Theme.of(context).colorScheme;
    return Padding(
      padding: const EdgeInsets.only(top: 8),
      child: InkWell(
        borderRadius: BorderRadius.circular(12),
        onTap: () async {
          final uri = Uri.tryParse(url);
          if (uri == null) return;
          await launchUrl(uri, mode: LaunchMode.externalApplication);
        },
        child: Container(
          width: double.infinity,
          padding: const EdgeInsets.all(10),
          decoration: BoxDecoration(
            color: mine
                ? Colors.white.withValues(alpha: 0.14)
                : scheme.surfaceContainerHighest,
            borderRadius: BorderRadius.circular(12),
            border: Border.all(
              color: mine
                  ? Colors.white.withValues(alpha: 0.18)
                  : scheme.outlineVariant,
            ),
          ),
          child: Row(
            children: [
              Icon(
                Icons.link_rounded,
                size: 18,
                color: mine ? Colors.white : scheme.primary,
              ),
              const SizedBox(width: 8),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      domain,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: Theme.of(context).textTheme.labelLarge?.copyWith(
                        color: mine ? Colors.white : scheme.onSurface,
                        fontWeight: FontWeight.w800,
                      ),
                    ),
                    Text(
                      url,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: Theme.of(context).textTheme.bodySmall?.copyWith(
                        color: mine
                            ? Colors.white.withValues(alpha: 0.78)
                            : scheme.onSurfaceVariant,
                      ),
                    ),
                  ],
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

String _formatFileSize(int bytes) {
  if (bytes <= 0) return '';
  if (bytes < 1024) return '$bytes B';
  final kb = bytes / 1024;
  if (kb < 1024) return '${kb.toStringAsFixed(kb < 10 ? 1 : 0)} KB';
  final mb = kb / 1024;
  return '${mb.toStringAsFixed(mb < 10 ? 1 : 0)} MB';
}

class _DirectImageBubble extends StatelessWidget {
  const _DirectImageBubble({required this.source, required this.heroTag});

  final String source;
  final String heroTag;

  @override
  Widget build(BuildContext context) {
    final bytes = tryDecodeDataUrl(source);
    final provider = bytes != null
        ? MemoryImage(bytes)
        : NetworkImage(resolveMediaUrl(source)) as ImageProvider;
    return GestureDetector(
      onTap: () {
        Navigator.of(context).push(
          PageRouteBuilder<void>(
            opaque: false,
            pageBuilder: (context, animation, secondaryAnimation) =>
                _DirectFullscreenImageView(
                  provider: provider,
                  heroTag: heroTag,
                ),
          ),
        );
      },
      child: Hero(
        tag: heroTag,
        child: ClipRRect(
          borderRadius: BorderRadius.circular(16),
          child: SizedBox(
            width: 220,
            height: 278,
            child: Image(
              image: provider,
              fit: BoxFit.cover,
              gaplessPlayback: true,
              filterQuality: FilterQuality.medium,
            ),
          ),
        ),
      ),
    );
  }
}

class _DirectFullscreenImageView extends StatelessWidget {
  const _DirectFullscreenImageView({
    required this.provider,
    required this.heroTag,
  });

  final ImageProvider provider;
  final String heroTag;

  @override
  Widget build(BuildContext context) {
    return Material(
      color: Colors.black,
      child: SafeArea(
        child: Stack(
          children: [
            Positioned.fill(
              child: InteractiveViewer(
                minScale: 1,
                maxScale: 4,
                child: Center(
                  child: Hero(
                    tag: heroTag,
                    child: Image(
                      image: provider,
                      fit: BoxFit.contain,
                      gaplessPlayback: true,
                    ),
                  ),
                ),
              ),
            ),
            Positioned(
              top: 12,
              left: 12,
              child: IconButton(
                onPressed: () => Navigator.of(context).pop(),
                icon: const Icon(Icons.close_rounded, color: Colors.white),
              ),
            ),
          ],
        ),
      ),
    );
  }
}

class _CallOverlay extends StatefulWidget {
  const _CallOverlay({
    required this.incoming,
    required this.connected,
    required this.remoteVideoEnabled,
    required this.localVideoEnabled,
    required this.localPreviewReady,
    required this.localPreviewGeneration,
    required this.localVideoMirrored,
    required this.micEnabled,
    required this.speakerOn,
    required this.status,
    required this.partnerName,
    required this.partnerPhotoUrl,
    required this.callSeconds,
    required this.localRenderer,
    required this.remoteRenderer,
    required this.onMinimize,
    required this.onAccept,
    required this.onDecline,
    required this.onHangup,
    required this.onToggleMute,
    required this.onToggleCamera,
    required this.onToggleSpeaker,
    required this.onSwitchCamera,
  });

  final bool incoming;
  final bool connected;
  final bool remoteVideoEnabled;
  final bool localVideoEnabled;
  final bool localPreviewReady;
  final int localPreviewGeneration;
  final bool localVideoMirrored;
  final bool micEnabled;
  final bool speakerOn;
  final String? status;
  final String partnerName;
  final String partnerPhotoUrl;
  final int callSeconds;
  final RTCVideoRenderer localRenderer;
  final RTCVideoRenderer remoteRenderer;
  final VoidCallback? onMinimize;
  final VoidCallback? onAccept;
  final VoidCallback onDecline;
  final VoidCallback onHangup;
  final VoidCallback onToggleMute;
  final VoidCallback onToggleCamera;
  final VoidCallback onToggleSpeaker;
  final VoidCallback onSwitchCamera;

  @override
  State<_CallOverlay> createState() => _CallOverlayState();
}

class _CallOverlayState extends State<_CallOverlay> {
  Offset _previewOffset = const Offset(18, 110);
  bool _primaryVideoRemote = true;
  bool _previewMoved = false;

  @override
  void didUpdateWidget(covariant _CallOverlay oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (!widget.remoteVideoEnabled && widget.localVideoEnabled) {
      _primaryVideoRemote = false;
    } else if (!widget.localVideoEnabled && widget.remoteVideoEnabled) {
      _primaryVideoRemote = true;
    } else if (!oldWidget.remoteVideoEnabled && widget.remoteVideoEnabled) {
      _primaryVideoRemote = true;
    }
    if ((oldWidget.remoteVideoEnabled && oldWidget.localVideoEnabled) &&
        !(widget.remoteVideoEnabled && widget.localVideoEnabled)) {
      _previewOffset = const Offset(18, 110);
    }
  }

  @override
  Widget build(BuildContext context) {
    final topInset = MediaQuery.of(context).padding.top;
    final bottomInset = MediaQuery.of(context).padding.bottom;
    final showAnyVideo = widget.remoteVideoEnabled || widget.localVideoEnabled;
    final showPreview = widget.remoteVideoEnabled && widget.localVideoEnabled;
    final primaryRenderer = _primaryVideoRemote
        ? widget.remoteRenderer
        : widget.localRenderer;
    final previewRenderer = _primaryVideoRemote
        ? widget.localRenderer
        : widget.remoteRenderer;
    final primaryIsLocal = !_primaryVideoRemote;
    final previewIsLocal = _primaryVideoRemote;
    final primaryMirror = !_primaryVideoRemote && widget.localVideoMirrored;
    final previewMirror = _primaryVideoRemote && widget.localVideoMirrored;

    return ColoredBox(
      color: Colors.black,
      child: LayoutBuilder(
        builder: (context, constraints) => Stack(
          children: [
            Positioned.fill(
              child: showAnyVideo
                  ? _buildVideoSurface(
                      primaryRenderer,
                      mirror: primaryMirror,
                      isLocal: primaryIsLocal,
                    )
                  : DecoratedBox(
                      decoration: const BoxDecoration(color: Color(0xFF111111)),
                      child: Center(
                        child: Column(
                          mainAxisSize: MainAxisSize.min,
                          children: [
                            CircleAvatar(
                              radius: 54,
                              backgroundColor: Colors.white12,
                              backgroundImage: widget.partnerPhotoUrl.isNotEmpty
                                  ? NetworkImage(
                                      resolveMediaUrl(widget.partnerPhotoUrl),
                                    )
                                  : null,
                              child: widget.partnerPhotoUrl.isEmpty
                                  ? Text(
                                      widget.partnerName.trim().isEmpty
                                          ? '?'
                                          : widget.partnerName
                                                .trim()
                                                .characters
                                                .first
                                                .toUpperCase(),
                                      style: Theme.of(context)
                                          .textTheme
                                          .headlineMedium
                                          ?.copyWith(
                                            color: Colors.white,
                                            fontWeight: FontWeight.w800,
                                          ),
                                    )
                                  : null,
                            ),
                            const SizedBox(height: 18),
                            Text(
                              widget.partnerName,
                              style: Theme.of(context).textTheme.headlineSmall
                                  ?.copyWith(
                                    color: Colors.white,
                                    fontWeight: FontWeight.w800,
                                  ),
                            ),
                            const SizedBox(height: 8),
                            Text(
                              widget.status ??
                                  (widget.connected ? 'Connected' : 'Calling'),
                              style: Theme.of(context).textTheme.titleMedium
                                  ?.copyWith(color: Colors.white70),
                            ),
                          ],
                        ),
                      ),
                    ),
            ),
            if (widget.onMinimize != null)
              Positioned(
                top: topInset + 12,
                left: 12,
                child: IconButton.filledTonal(
                  style: IconButton.styleFrom(
                    backgroundColor: Colors.white.withValues(alpha: 0.12),
                    foregroundColor: Colors.white,
                  ),
                  onPressed: widget.onMinimize,
                  icon: const Icon(Icons.arrow_back_ios_new_rounded),
                  tooltip: 'Minimize call',
                ),
              ),
            Positioned(
              top: topInset + 18,
              left: 0,
              right: 0,
              child: Center(
                child: _CallMetaPill(
                  label: widget.connected
                      ? _formatCallTime(widget.callSeconds)
                      : (widget.status ?? 'Calling'),
                ),
              ),
            ),
            if (showPreview)
              Positioned(
                left: _previewOffset.dx,
                top: _previewOffset.dy,
                child: GestureDetector(
                  onPanStart: (_) {
                    _previewMoved = false;
                  },
                  onPanUpdate: (details) {
                    final previewWidth = constraints.maxWidth <= 640
                        ? 110.0
                        : 126.0;
                    final previewHeight = constraints.maxWidth <= 640
                        ? 156.0
                        : 180.0;
                    final maxX = (constraints.maxWidth - previewWidth - 12.0)
                        .clamp(8.0, double.infinity);
                    final maxY = (constraints.maxHeight - previewHeight - 120.0)
                        .clamp(topInset + 32, double.infinity);
                    setState(() {
                      if (details.delta.distance > 0) {
                        _previewMoved = true;
                      }
                      _previewOffset = Offset(
                        (_previewOffset.dx + details.delta.dx).clamp(8.0, maxX),
                        (_previewOffset.dy + details.delta.dy).clamp(
                          topInset + 32,
                          maxY,
                        ),
                      );
                    });
                  },
                  onPanEnd: (_) {
                    _previewMoved = false;
                  },
                  onTap: () {
                    if (!showPreview || _previewMoved) return;
                    setState(() {
                      _primaryVideoRemote = !_primaryVideoRemote;
                    });
                  },
                  child: SizedBox(
                    width: constraints.maxWidth <= 640 ? 110 : 126,
                    height: constraints.maxWidth <= 640 ? 156 : 180,
                    child: ClipRRect(
                      borderRadius: BorderRadius.circular(18),
                      child: _buildVideoRendererSurface(
                        previewRenderer,
                        mirror: previewMirror,
                        isLocal: previewIsLocal,
                        compact: true,
                        key: previewIsLocal
                            ? ValueKey<String>(
                                'local-preview-${widget.localPreviewGeneration}',
                              )
                            : const ValueKey<String>('remote-preview'),
                      ),
                    ),
                  ),
                ),
              ),
            Positioned(
              left: 20,
              right: 20,
              bottom: bottomInset + 24,
              child: Column(
                mainAxisSize: MainAxisSize.min,
                children: [
                  if (widget.incoming)
                    Row(
                      mainAxisAlignment: MainAxisAlignment.center,
                      children: [
                        FilledButton(
                          onPressed: widget.onAccept,
                          child: const Text('Accept'),
                        ),
                        const SizedBox(width: 12),
                        OutlinedButton(
                          onPressed: widget.onDecline,
                          style: OutlinedButton.styleFrom(
                            foregroundColor: Colors.white,
                            side: const BorderSide(color: Colors.white30),
                          ),
                          child: const Text('Decline'),
                        ),
                      ],
                    )
                  else
                    Row(
                      mainAxisAlignment: MainAxisAlignment.center,
                      children: [
                        IconButton.filledTonal(
                          style: IconButton.styleFrom(
                            backgroundColor: Colors.white12,
                            foregroundColor: Colors.white,
                          ),
                          onPressed: widget.connected
                              ? widget.onToggleMute
                              : null,
                          icon: Icon(
                            widget.micEnabled
                                ? Icons.mic_none
                                : Icons.mic_off_outlined,
                          ),
                        ),
                        const SizedBox(width: 12),
                        IconButton.filledTonal(
                          style: IconButton.styleFrom(
                            backgroundColor: widget.localVideoEnabled
                                ? Colors.white
                                : Colors.white12,
                            foregroundColor: widget.localVideoEnabled
                                ? Colors.black
                                : Colors.white,
                          ),
                          onPressed: widget.connected
                              ? widget.onToggleCamera
                              : null,
                          icon: Icon(
                            widget.localVideoEnabled
                                ? Icons.videocam_outlined
                                : Icons.videocam_off_outlined,
                          ),
                        ),
                        const SizedBox(width: 12),
                        IconButton.filledTonal(
                          style: IconButton.styleFrom(
                            backgroundColor: widget.speakerOn
                                ? const Color(0x33FFFFFF)
                                : Colors.white12,
                            foregroundColor: Colors.white,
                          ),
                          onPressed: widget.connected
                              ? widget.onToggleSpeaker
                              : null,
                          icon: Icon(
                            widget.speakerOn
                                ? Icons.volume_up_outlined
                                : Icons.volume_off_outlined,
                          ),
                        ),
                        const SizedBox(width: 12),
                        IconButton.filledTonal(
                          style: IconButton.styleFrom(
                            backgroundColor: Colors.white12,
                            foregroundColor: Colors.white,
                          ),
                          onPressed:
                              widget.connected && widget.localVideoEnabled
                              ? widget.onSwitchCamera
                              : null,
                          icon: const Icon(Icons.cameraswitch_outlined),
                        ),
                        const SizedBox(width: 12),
                        IconButton.filled(
                          style: IconButton.styleFrom(
                            backgroundColor: talkflixPrimary,
                            foregroundColor: Colors.white,
                          ),
                          onPressed: widget.onHangup,
                          icon: const Icon(Icons.call_end),
                        ),
                      ],
                    ),
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }

  String _formatCallTime(int totalSeconds) {
    final minutes = (totalSeconds ~/ 60).toString().padLeft(2, '0');
    final seconds = (totalSeconds % 60).toString().padLeft(2, '0');
    return '$minutes:$seconds';
  }

  Widget _buildVideoSurface(
    RTCVideoRenderer renderer, {
    required bool mirror,
    required bool isLocal,
  }) {
    return _buildVideoRendererSurface(
      renderer,
      mirror: mirror,
      isLocal: isLocal,
      compact: false,
      key: isLocal
          ? ValueKey<String>('local-primary-${widget.localPreviewGeneration}')
          : const ValueKey<String>('remote-primary'),
    );
  }

  Widget _buildVideoRendererSurface(
    RTCVideoRenderer renderer, {
    required bool mirror,
    required bool isLocal,
    required bool compact,
    required Key key,
  }) {
    final showLocalPlaceholder =
        isLocal && widget.localVideoEnabled && !widget.localPreviewReady;
    return DecoratedBox(
      decoration: const BoxDecoration(color: Color(0xFF111111)),
      child: Stack(
        fit: StackFit.expand,
        children: [
          RTCVideoView(
            renderer,
            key: key,
            mirror: mirror,
            objectFit: RTCVideoViewObjectFit.RTCVideoViewObjectFitCover,
            placeholderBuilder: (_) => const SizedBox.shrink(),
          ),
          if (showLocalPlaceholder)
            Positioned.fill(
              child: _buildVideoPlaceholder(compact: compact, isLocal: true),
            ),
        ],
      ),
    );
  }

  Widget _buildVideoPlaceholder({
    required bool compact,
    required bool isLocal,
  }) {
    final showLocalLoading =
        isLocal && widget.localVideoEnabled && !widget.localPreviewReady;
    return DecoratedBox(
      decoration: const BoxDecoration(color: Color(0xFF111111)),
      child: Center(
        child: showLocalLoading
            ? Column(
                mainAxisSize: MainAxisSize.min,
                children: [
                  SizedBox(
                    width: compact ? 22 : 28,
                    height: compact ? 22 : 28,
                    child: const CircularProgressIndicator(
                      strokeWidth: 2.4,
                      color: Colors.white70,
                    ),
                  ),
                  SizedBox(height: compact ? 10 : 12),
                  Icon(
                    Icons.videocam_outlined,
                    color: Colors.white70,
                    size: compact ? 24 : 32,
                  ),
                ],
              )
            : const SizedBox.shrink(),
      ),
    );
  }
}

class _CallMetaPill extends StatelessWidget {
  const _CallMetaPill({required this.label});

  final String label;

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 6),
      decoration: BoxDecoration(
        color: Colors.white.withValues(alpha: 0.12),
        borderRadius: BorderRadius.circular(999),
      ),
      child: Text(
        label,
        style: Theme.of(
          context,
        ).textTheme.bodySmall?.copyWith(color: Colors.white),
      ),
    );
  }
}

class _MinimizedCallBar extends StatelessWidget {
  const _MinimizedCallBar({
    required this.partnerName,
    required this.partnerPhotoUrl,
    required this.status,
    required this.video,
    required this.onRestore,
    required this.onHangup,
  });

  final String partnerName;
  final String partnerPhotoUrl;
  final String status;
  final bool video;
  final VoidCallback onRestore;
  final VoidCallback onHangup;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final isDark = Theme.of(context).brightness == Brightness.dark;
    return Material(
      color: Colors.transparent,
      child: Container(
        margin: const EdgeInsets.fromLTRB(16, 0, 16, 10),
        decoration: BoxDecoration(
          color: isDark ? const Color(0xFF16171A) : Colors.white,
          borderRadius: BorderRadius.circular(22),
          border: Border.all(color: scheme.outlineVariant),
          boxShadow: [
            BoxShadow(
              color: Colors.black.withValues(alpha: isDark ? 0.18 : 0.06),
              blurRadius: 20,
              offset: const Offset(0, 8),
            ),
          ],
        ),
        child: InkWell(
          onTap: onRestore,
          borderRadius: BorderRadius.circular(22),
          child: Padding(
            padding: const EdgeInsets.fromLTRB(12, 10, 10, 10),
            child: Row(
              children: [
                AppAvatar(
                  label: partnerName,
                  imageUrl: partnerPhotoUrl,
                  radius: 18,
                ),
                const SizedBox(width: 10),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      Text(
                        partnerName,
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: Theme.of(context).textTheme.titleSmall?.copyWith(
                          fontWeight: FontWeight.w800,
                        ),
                      ),
                      const SizedBox(height: 2),
                      Row(
                        children: [
                          Icon(
                            video
                                ? Icons.videocam_outlined
                                : Icons.call_outlined,
                            size: 14,
                            color: scheme.onSurfaceVariant,
                          ),
                          const SizedBox(width: 6),
                          Expanded(
                            child: Text(
                              status,
                              maxLines: 1,
                              overflow: TextOverflow.ellipsis,
                              style: Theme.of(context).textTheme.bodySmall
                                  ?.copyWith(
                                    color: scheme.onSurfaceVariant,
                                    fontWeight: FontWeight.w600,
                                  ),
                            ),
                          ),
                        ],
                      ),
                    ],
                  ),
                ),
                const SizedBox(width: 8),
                IconButton(
                  onPressed: onRestore,
                  tooltip: 'Open call',
                  icon: const Icon(Icons.open_in_full_rounded),
                ),
                IconButton.filled(
                  style: IconButton.styleFrom(
                    backgroundColor: talkflixPrimary,
                    foregroundColor: Colors.white,
                  ),
                  onPressed: onHangup,
                  tooltip: 'End call',
                  icon: const Icon(Icons.call_end),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}

// ─── WhatsApp-style message context menu ────────────────────────────────────

// ── Telegram-style reaction chip shown below a message bubble ────────────────
class _ReactionChip extends StatelessWidget {
  const _ReactionChip({
    required this.emoji,
    required this.count,
    required this.isMine,
  });

  final String emoji;
  final int count;
  final bool isMine;

  @override
  Widget build(BuildContext context) {
    final isDark = Theme.of(context).brightness == Brightness.dark;
    final bg = isMine
        ? Colors.white.withValues(alpha: isDark ? 0.18 : 0.22)
        : (isDark
              ? Colors.white.withValues(alpha: 0.12)
              : const Color(0xFFEEEEEE));
    final textColor = isMine
        ? Colors.white.withValues(alpha: 0.95)
        : Theme.of(context).colorScheme.onSurface;

    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 9, vertical: 4),
      decoration: BoxDecoration(
        color: bg,
        borderRadius: BorderRadius.circular(999),
        border: Border.all(
          color: isMine
              ? Colors.white.withValues(alpha: 0.25)
              : Theme.of(
                  context,
                ).colorScheme.outlineVariant.withValues(alpha: 0.6),
          width: 0.5,
        ),
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          Text(emoji, style: const TextStyle(fontSize: 14, height: 1.2)),
          if (count > 1) ...[
            const SizedBox(width: 4),
            Text(
              '$count',
              style: TextStyle(
                fontSize: 12,
                fontWeight: FontWeight.w700,
                color: textColor,
                height: 1.2,
              ),
            ),
          ],
        ],
      ),
    );
  }
}

class _MessageContextMenu extends StatelessWidget {
  const _MessageContextMenu({
    required this.message,
    required this.isMine,
    required this.canCorrect,
    required this.correctionTone,
    required this.onReact,
    required this.onReply,
    required this.onCorrect,
    required this.onDelete,
    required this.onReport,
    this.onForward,
    this.onEdit,
    this.onRetry,
    this.onCopy,
  });

  final ChatMessage message;
  final bool isMine;
  final bool canCorrect;
  final String correctionTone;
  final ValueChanged<String> onReact;
  final VoidCallback onReply;
  final VoidCallback onCorrect;
  final VoidCallback onDelete;
  final VoidCallback onReport;
  final VoidCallback? onForward;
  final VoidCallback? onEdit;
  final VoidCallback? onRetry;
  final VoidCallback? onCopy;

  // Full Telegram emoji set (30 emojis)
  static const _reactions = [
    '👍',
    '👎',
    '❤️',
    '🔥',
    '🥰',
    '👏',
    '😁',
    '🤔',
    '🤯',
    '😱',
    '🤬',
    '😢',
    '🎉',
    '🤩',
    '🤮',
    '💩',
    '🙏',
    '👌',
    '🕊',
    '🤡',
    '🥱',
    '🥴',
    '😍',
    '🐳',
    '❤️‍🔥',
    '🌚',
    '💯',
    '🤣',
    '⚡',
    '🏆',
  ];

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final isDark = Theme.of(context).brightness == Brightness.dark;
    final cardColor = isDark ? const Color(0xFF1E1E1E) : Colors.white;
    final textColor = isDark ? Colors.white : const Color(0xFF111111);
    final subColor = isDark ? Colors.white54 : Colors.black45;

    // Material is required so InkWell inside _ContextAction can paint ink splashes.
    // The dialog itself provides no Material ancestor, so we add one here.
    return Material(
      color: Colors.transparent,
      child: GestureDetector(
        onTap: () => Navigator.of(context).pop(),
        behavior: HitTestBehavior.opaque,
        child: SafeArea(
          child: Align(
            // Sit in the vertical centre but don't use Center — it gives loose
            // constraints which let Column overflow.  Align with a fixed
            // fraction gives tight constraints and prevents the 299k overflow.
            alignment: Alignment.center,
            child: SingleChildScrollView(
              padding: const EdgeInsets.symmetric(vertical: 24),
              child: GestureDetector(
                onTap: () {},
                child: Padding(
                  padding: const EdgeInsets.symmetric(horizontal: 24),
                  child: Column(
                    mainAxisSize: MainAxisSize.min,
                    crossAxisAlignment: isMine
                        ? CrossAxisAlignment.end
                        : CrossAxisAlignment.start,
                    children: [
                      // ── Emoji reaction strip (full Telegram set, scrollable) ──
                      Container(
                        padding: const EdgeInsets.symmetric(
                          horizontal: 4,
                          vertical: 6,
                        ),
                        decoration: BoxDecoration(
                          color: cardColor,
                          borderRadius: BorderRadius.circular(999),
                          boxShadow: [
                            BoxShadow(
                              color: Colors.black.withValues(alpha: 0.18),
                              blurRadius: 20,
                              offset: const Offset(0, 6),
                            ),
                          ],
                        ),
                        child: SingleChildScrollView(
                          scrollDirection: Axis.horizontal,
                          padding: const EdgeInsets.symmetric(horizontal: 8),
                          child: Row(
                            mainAxisSize: MainAxisSize.min,
                            children: _reactions.map((emoji) {
                              return _ReactionButton(
                                emoji: emoji,
                                onTap: () => onReact(emoji),
                              );
                            }).toList(),
                          ),
                        ),
                      ),
                      const SizedBox(height: 10),
                      // ── Action menu ───────────────────────────────────────
                      Container(
                        width: double.infinity,
                        decoration: BoxDecoration(
                          color: cardColor,
                          borderRadius: BorderRadius.circular(20),
                          boxShadow: [
                            BoxShadow(
                              color: Colors.black.withValues(alpha: 0.18),
                              blurRadius: 20,
                              offset: const Offset(0, 6),
                            ),
                          ],
                        ),
                        child: Column(
                          mainAxisSize: MainAxisSize.min,
                          children: [
                            _ContextAction(
                              icon: Icons.reply_rounded,
                              label: 'Reply',
                              color: textColor,
                              onTap: onReply,
                            ),
                            if (onForward != null) ...[
                              _MenuDivider(color: subColor),
                              _ContextAction(
                                icon: Icons.forward_rounded,
                                label: 'Forward',
                                color: textColor,
                                onTap: onForward!,
                              ),
                            ],
                            if (onEdit != null) ...[
                              _MenuDivider(color: subColor),
                              _ContextAction(
                                icon: Icons.edit_outlined,
                                label: 'Edit',
                                color: textColor,
                                onTap: onEdit!,
                              ),
                            ],
                            if (canCorrect) ...[
                              _MenuDivider(color: subColor),
                              _ContextAction(
                                icon: Icons.spellcheck_rounded,
                                label:
                                    'Correct (${correctionTone.toLowerCase()})',
                                color: textColor,
                                onTap: onCorrect,
                              ),
                            ],
                            if (onRetry != null) ...[
                              _MenuDivider(color: subColor),
                              _ContextAction(
                                icon: Icons.refresh_rounded,
                                label: 'Retry send',
                                color: textColor,
                                onTap: onRetry!,
                              ),
                            ],
                            if (onCopy != null) ...[
                              _MenuDivider(color: subColor),
                              _ContextAction(
                                icon: Icons.copy_rounded,
                                label: 'Copy text',
                                color: textColor,
                                onTap: onCopy!,
                              ),
                            ],
                            _MenuDivider(color: subColor),
                            _ContextAction(
                              icon: Icons.delete_outline_rounded,
                              label: 'Delete',
                              color: scheme.error,
                              onTap: onDelete,
                            ),
                            _MenuDivider(color: subColor),
                            _ContextAction(
                              icon: Icons.flag_outlined,
                              label: 'Report',
                              color: scheme.error,
                              onTap: onReport,
                              isLast: true,
                            ),
                          ],
                        ),
                      ),
                    ],
                  ),
                ),
              ),
            ), // SingleChildScrollView
          ), // Align
        ), // SafeArea
      ), // outer GestureDetector
    ); // Material
  }
}

class _ReactionButton extends StatefulWidget {
  const _ReactionButton({required this.emoji, required this.onTap});
  final String emoji;
  final VoidCallback onTap;

  @override
  State<_ReactionButton> createState() => _ReactionButtonState();
}

class _ReactionButtonState extends State<_ReactionButton>
    with SingleTickerProviderStateMixin {
  late final AnimationController _ctrl;
  late final Animation<double> _scale;

  @override
  void initState() {
    super.initState();
    _ctrl = AnimationController(
      vsync: this,
      duration: const Duration(milliseconds: 200),
    );
    _scale = TweenSequence<double>([
      TweenSequenceItem(tween: Tween(begin: 1.0, end: 1.45), weight: 50),
      TweenSequenceItem(tween: Tween(begin: 1.45, end: 1.0), weight: 50),
    ]).animate(CurvedAnimation(parent: _ctrl, curve: Curves.easeOut));
  }

  @override
  void dispose() {
    _ctrl.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return GestureDetector(
      onTap: () => _ctrl.forward(from: 0).then((_) => widget.onTap()),
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 6),
        child: ScaleTransition(
          scale: _scale,
          child: Text(widget.emoji, style: const TextStyle(fontSize: 28)),
        ),
      ),
    );
  }
}

class _ContextAction extends StatelessWidget {
  const _ContextAction({
    required this.icon,
    required this.label,
    required this.color,
    required this.onTap,
    this.isLast = false,
  });

  final IconData icon;
  final String label;
  final Color color;
  final VoidCallback onTap;
  final bool isLast;

  @override
  Widget build(BuildContext context) {
    return InkWell(
      onTap: onTap,
      borderRadius: isLast
          ? const BorderRadius.vertical(bottom: Radius.circular(20))
          : BorderRadius.zero,
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 20, vertical: 15),
        child: Row(
          children: [
            Icon(icon, color: color, size: 20),
            const SizedBox(width: 16),
            Expanded(
              child: Text(
                label,
                style: TextStyle(
                  color: color,
                  fontSize: 15,
                  fontWeight: FontWeight.w600,
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }
}

enum _DraftAssistAction {
  translate('Translate', Icons.translate_rounded),
  grammar('Grammar check', Icons.spellcheck_rounded),
  paraphrase('Paraphrase', Icons.short_text_rounded);

  const _DraftAssistAction(this.label, this.icon);

  final String label;
  final IconData icon;
}

class _MenuDivider extends StatelessWidget {
  const _MenuDivider({required this.color});
  final Color color;

  @override
  Widget build(BuildContext context) {
    return Divider(
      height: 1,
      thickness: 0.5,
      color: color.withValues(alpha: 0.2),
      indent: 20,
      endIndent: 20,
    );
  }
}
