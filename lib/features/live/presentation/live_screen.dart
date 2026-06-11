import 'dart:async';
import 'dart:developer' as developer;
import 'dart:math' as math;

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_webrtc/flutter_webrtc.dart';
import 'package:go_router/go_router.dart';
import 'package:livekit_client/livekit_client.dart';
import 'package:image_picker/image_picker.dart';
import 'package:share_plus/share_plus.dart';

import '../../../app/theme/app_theme.dart';
import '../../../core/auth/session_controller.dart';
import '../../../core/config/app_config.dart';
import '../../../core/config/storage_keys.dart';
import '../../../core/formatters/compact_count_formatter.dart';
import '../../../core/media/media_permission_service.dart';
import '../../../core/media/media_utils.dart';
import '../../../core/network/api_client.dart';
import '../../../core/network/api_exception.dart';
import '../../../core/realtime/socket_service.dart';
import '../../../core/realtime/webrtc_service.dart';
import '../../../core/widgets/participant_action_target.dart';
import '../../../core/widgets/realtime_warning_banner.dart';
import '../../content/data/content_repository.dart';
import '../../talk/data/direct_chat_repository.dart';
import '../../talk/data/talk_repository.dart';
import '../../talk/presentation/chat_recipient_picker.dart';
import '../application/live_room_session_controller.dart';
import '../data/live_audio_service.dart';
import '../application/live_room_controller.dart';
import '../domain/live_role.dart';
import '../../auth/data/signup_options.dart';
import '../../upgrade/presentation/pro_access_sheet.dart';
import 'flying_reactions.dart';

/// True while the user is inside any live broadcast room on the Live tab.
/// Drives shell chrome (e.g. hiding the bottom navigation bar) for immersive
/// audio and video rooms.
final liveAudioRoomActiveProvider = StateProvider<bool>((ref) => false);
final liveBrowseTypeProvider = StateProvider<String>((ref) => 'audio');
final liveBroadcastCacheProvider = StateProvider<List<Map<String, dynamic>>>(
  (ref) => const [],
);

const Set<String> _liveBackgroundThemes = <String>{
  'gold',
  'red',
  'blue',
  'black',
};
const Set<String> _liveCommentThemes = <String>{
  'glass',
  'soft',
  'aqua',
  'berry',
  'mint',
};
const Set<String> _liveMicEffects = <String>{
  'pulse',
  'halo',
  'echo',
  'spotlight',
};

String _normalizeMicEffect(String? value) {
  final normalized = (value ?? '').trim().toLowerCase();
  return _liveMicEffects.contains(normalized) ? normalized : 'pulse';
}

class LiveScreen extends ConsumerStatefulWidget {
  const LiveScreen({super.key, this.initialBroadcastId});

  final String? initialBroadcastId;

  @override
  ConsumerState<LiveScreen> createState() => _LiveScreenState();
}

class _LiveScreenState extends ConsumerState<LiveScreen> {
  final _permissionService = MediaPermissionService();
  final _commentController = TextEditingController();
  final _commentFocusNode = FocusNode();
  final _immersiveCommentsController = ScrollController();
  final _audioRoomPageController = PageController();
  final _videoRoomPageController = PageController();
  final _reactionController = StreamController<String>.broadcast();
  static const _audioRoomPanel = Color(0xFF2C1E00);
  static const _audioRoomAccent = talkflixPrimary;
  static const _liveExitRed = Color(0xFFDC2626);
  static const _liveExitRedBright = Color(0xFFEF4444);
  RTCVideoRenderer? _localRenderer;
  final Map<String, RTCVideoRenderer> _remoteRenderers = {};
  final Map<String, RTCPeerConnection> _peerConnections = {};
  final Map<String, String> _peerStates = {};
  final Map<String, List<RTCIceCandidate>> _pendingIce = {};
  final Set<String> _remoteDescriptionReady = <String>{};
  final Map<String, String> _peerMeshMediaSignatures = <String, String>{};
  final Map<String, Timer> _peerReconnectTimers = <String, Timer>{};
  final Map<String, int> _peerReconnectAttempts = <String, int>{};
  int _rtcSyncedSpeakerVersion = 0;
  bool _syncingRtc = false;
  bool _syncRtcPending = false;
  Timer? _rtcSyncDebounceTimer;
  Timer? _speakingProbeTimer;
  Timer? _speakingEmitTimer;
  Timer? _audioRecoveryTimer;
  Timer? _roomHealthTimer;
  Timer? _browseListRefreshTimer;
  Timer? _pollClearTimer;
  Timer? _guestPreviewCountdownTimer;
  final Map<String, Timer> _speakingDecayTimers = {};
  bool _lastLocalSpeaking = false;
  DateTime? _lastSpeakingEmitAt;
  bool? _pendingSpeakingEmit;
  int _speakingPositiveSamples = 0;
  int _speakingNegativeSamples = 0;
  DateTime? _lastInboundAudioAt;
  int _audioRecoveryAttempts = 0;
  int _activeRoomMissingFromListCount = 0;
  int _activeRoomVersion = 0;
  int _activeSpeakerVersion = 0;
  bool _topologyReady = false;
  bool _sfuConnected = false;
  Future<void>? _sfuConnectInFlight;
  final Map<String, int> _latestSpeakingSeqByUser = <String, int>{};
  final List<String> _rtcTransitionLog = <String>[];
  String? _pendingSharedBroadcastId;
  bool _sharedBroadcastLookupRetried = false;
  bool _joiningPendingSharedBroadcast = false;
  static const int _rtcTransitionLogLimit = 20;
  static const _rtcSyncDebounceWindow = Duration(milliseconds: 180);
  static const _speakingEmitMinInterval = Duration(milliseconds: 850);
  static const _speakingProbeInterval = Duration(milliseconds: 700);
  static const _videoRoomChromeHideDelay = Duration(seconds: 4);

  void _recordRtcTransition(String event) {
    final now = DateTime.now();
    final hh = now.hour.toString().padLeft(2, '0');
    final mm = now.minute.toString().padLeft(2, '0');
    final ss = now.second.toString().padLeft(2, '0');
    _rtcTransitionLog.add('$hh:$mm:$ss $event');
    if (_rtcTransitionLog.length > _rtcTransitionLogLimit) {
      _rtcTransitionLog.removeRange(
        0,
        _rtcTransitionLog.length - _rtcTransitionLogLimit,
      );
    }
  }

  List<Map<String, dynamic>> _broadcasts = const [];
  Map<String, dynamic>? _activeRoom;
  List<Map<String, dynamic>> _comments = const [];
  List<Map<String, dynamic>> _joinRequests = const [];
  Map<String, dynamic>? _activePoll;
  String? _myPollVoteOptionId;
  String? _lastShownNoticeId;
  bool _liveNoticeDialogOpen = false;
  bool _loadingList = true;
  bool _creating = false;
  bool _handRaised = false;
  bool _rejoiningRoom = false;
  bool _localRendererReady = false;
  RTCVideoRenderer? _hostHeroRenderer;
  bool _hostHeroRendererReady = false;
  bool _socketBound = false;
  // Stored during _bindSocket so dispose() can clean up without touching ref.
  SocketService? _socketRef;
  LiveAudioService? _liveAudioServiceRef;
  int _broadcastRequestToken = 0;
  bool _localMicEnabled = true;
  bool _localVideoEnabled = false;
  bool _didInitializeStageMic = false;
  bool _wasOnStage = false;
  bool _isFollowingHost = false;
  bool _followingHostBusy = false;
  int _heartCount = 0;
  int _audioRoomPageIndex = 0;
  int _videoRoomPageIndex = 0;
  bool _videoRoomChromeVisible = true;
  bool _videoRoomActionsExpanded = false;
  Timer? _videoRoomChromeHideTimer;
  String? _videoRoomChromeSessionId;
  bool _guestPreviewJoinInFlight = false;
  bool _guestPreviewExpired = false;
  DateTime? _guestPreviewEndsAt;
  String _myCommentTheme = 'glass';
  String _myMicEffect = 'pulse';

  /// Cached plain-bool set at room-join time. Used in socket callbacks where
  /// provider reads may return stale/initial state (autoDispose caveat).
  bool _amHosting = false;
  String _socketStatus = 'disconnected';
  String _browseType = 'audio';
  String? _browseLanguage;
  String _language = 'English';
  final Set<String> _activeSpeakers = {};

  LiveAudioService get _liveAudioService {
    final cached = _liveAudioServiceRef;
    if (cached != null) return cached;
    final resolved = ref.read(liveAudioServiceProvider);
    _liveAudioServiceRef = resolved;
    return resolved;
  }

  bool get _shouldUseGuestLivePreview {
    final broadcastId = _pendingSharedBroadcastId ?? widget.initialBroadcastId;
    if (!kIsWeb || broadcastId == null || broadcastId.trim().isEmpty) {
      return false;
    }
    return !ref.read(sessionControllerProvider).isAuthenticated;
  }

  int get _guestPreviewSecondsRemaining {
    final endsAt = _guestPreviewEndsAt;
    if (endsAt == null) return 0;
    final remaining = endsAt.difference(DateTime.now()).inSeconds;
    return remaining < 0 ? 0 : remaining;
  }

  @override
  void initState() {
    super.initState();
    _pendingSharedBroadcastId = _normalizeBroadcastId(
      widget.initialBroadcastId,
    );
    _browseType = ref.read(liveBrowseTypeProvider);
    _restorePersistedLiveRoomSession();
    final cached = ref.read(liveBroadcastCacheProvider);
    if (cached.isNotEmpty) {
      _broadcasts = cached;
      _loadingList = false;
    }
    _socketStatus = _socket.status;
    _socket.addListener(_handleSocketStatusChanged);
    _commentFocusNode.addListener(_handleCommentFocusChanged);
    unawaited(_loadMyCommentTheme());
    unawaited(_loadMyMicEffect());
    if (_shouldUseGuestLivePreview) {
      _socket.connectGuestLivePreview(broadcastId: _pendingSharedBroadcastId!);
      _socketStatus = _socket.status;
    }
    _bindSocket();
    _queueSharedBroadcastResolution();
    if (_activeRoom != null) {
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (!mounted || _activeRoom == null) return;
        ref.read(liveRoomSessionProvider.notifier).setMinimized(false);
        _syncRoomChromeState();
        unawaited(_resumePersistedLiveRoomSession());
      });
    }
    _syncBrowseListRefreshTimer();
  }

  @override
  void didUpdateWidget(covariant LiveScreen oldWidget) {
    super.didUpdateWidget(oldWidget);
    final nextBroadcastId = _normalizeBroadcastId(widget.initialBroadcastId);
    if (nextBroadcastId ==
        _normalizeBroadcastId(oldWidget.initialBroadcastId)) {
      return;
    }
    _pendingSharedBroadcastId = nextBroadcastId;
    _sharedBroadcastLookupRetried = false;
    _queueSharedBroadcastResolution();
  }

  String? _normalizeBroadcastId(String? value) {
    final normalized = (value ?? '').trim();
    if (normalized.isEmpty) return null;
    return normalized;
  }

  Map<String, dynamic>? _broadcastById(String broadcastId) {
    for (final broadcast in _broadcasts) {
      if ('${broadcast['id'] ?? ''}'.trim() == broadcastId) {
        return broadcast;
      }
    }
    return null;
  }

  void _queueSharedBroadcastResolution() {
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted) return;
      unawaited(_maybeResolveSharedBroadcast());
    });
  }

  Future<void> _maybeResolveSharedBroadcast() async {
    final targetBroadcastId = _pendingSharedBroadcastId;
    if (!mounted || targetBroadcastId == null || targetBroadcastId.isEmpty) {
      return;
    }
    final activeBroadcastId = '${_activeRoom?['id'] ?? ''}'.trim();
    if (activeBroadcastId == targetBroadcastId) {
      _pendingSharedBroadcastId = null;
      _sharedBroadcastLookupRetried = false;
      return;
    }
    if (activeBroadcastId.isNotEmpty) {
      _pendingSharedBroadcastId = null;
      _sharedBroadcastLookupRetried = false;
      return;
    }
    if (_joiningPendingSharedBroadcast) {
      return;
    }
    final room = _broadcastById(targetBroadcastId);
    if (room == null) {
      if (_loadingList) return;
      if (!_sharedBroadcastLookupRetried) {
        _sharedBroadcastLookupRetried = true;
        await _requestBroadcasts();
        return;
      }
      _pendingSharedBroadcastId = null;
      _sharedBroadcastLookupRetried = false;
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('This live room is unavailable.')),
      );
      return;
    }
    _joiningPendingSharedBroadcast = true;
    try {
      if (_shouldUseGuestLivePreview) {
        await _joinGuestLivePreview(room);
      } else {
        await _joinBroadcast(room);
      }
    } finally {
      _joiningPendingSharedBroadcast = false;
    }
    if (!mounted) return;
    if ('${_activeRoom?['id'] ?? ''}'.trim() == targetBroadcastId) {
      _pendingSharedBroadcastId = null;
    }
    _sharedBroadcastLookupRetried = false;
  }

  @override
  void dispose() {
    final preserveMinimizedSession = _shouldPreserveMinimizedAudioSession;
    _unbindSocket();
    _socket.removeListener(_handleSocketStatusChanged);
    _commentFocusNode
      ..removeListener(_handleCommentFocusChanged)
      ..dispose();
    _rtcSyncDebounceTimer?.cancel();
    _stopSpeakingProbe(clearSpeaking: false);
    _speakingEmitTimer?.cancel();
    _audioRecoveryTimer?.cancel();
    _roomHealthTimer?.cancel();
    _browseListRefreshTimer?.cancel();
    _pollClearTimer?.cancel();
    _guestPreviewCountdownTimer?.cancel();
    _cancelVideoRoomChromeHideTimer();
    for (final timer in _speakingDecayTimers.values) {
      timer.cancel();
    }
    _speakingDecayTimers.clear();
    _commentController.dispose();
    _immersiveCommentsController.dispose();
    _audioRoomPageController.dispose();
    _videoRoomPageController.dispose();
    unawaited(_reactionController.close());
    if (!preserveMinimizedSession) {
      unawaited(_liveAudioService.disconnect());
      unawaited(_disposeRtc());
    }
    final localRenderer = _localRenderer;
    _localRenderer = null;
    if (_localRendererReady) {
      localRenderer?.dispose();
      _localRendererReady = false;
    }
    for (final renderer in _remoteRenderers.values) {
      renderer.dispose();
    }
    super.dispose();
  }

  // Use cached ref when available so dispose() callbacks never touch ref.
  SocketService get _socket => _socketRef ?? ref.read(socketServiceProvider);

  void _handleCommentFocusChanged() {
    if (!mounted) return;
    _syncVideoRoomChromeWithActivity();
    setState(() {});
  }

  bool _videoRoomChromePinned({bool? isCommenting, String? socketStatus}) {
    if (!_roomUsesVideo) return false;
    final commenting =
        isCommenting ??
        (_commentFocusNode.hasFocus || MediaQuery.viewInsetsOf(context).bottom > 0);
    final status = socketStatus ?? _socketStatus;
    return commenting || status != 'connected' || _videoRoomPageIndex == 1;
  }

  void _cancelVideoRoomChromeHideTimer() {
    _videoRoomChromeHideTimer?.cancel();
    _videoRoomChromeHideTimer = null;
  }

  void _resetVideoRoomChromeSession() {
    _videoRoomChromeSessionId = null;
    _cancelVideoRoomChromeHideTimer();
    _videoRoomChromeVisible = true;
    _videoRoomActionsExpanded = false;
  }

  void _toggleVideoRoomActions() {
    if (!_roomUsesVideo || _activeRoom == null) return;
    setState(() => _videoRoomActionsExpanded = !_videoRoomActionsExpanded);
  }

  void _ensureVideoRoomChromeAutoHide() {
    final roomId = '${_activeRoom?['id'] ?? ''}';
    if (roomId.isEmpty || !_roomUsesVideo) return;
    if (_videoRoomChromeSessionId == roomId) return;
    _videoRoomChromeSessionId = roomId;
    _videoRoomChromeVisible = true;
    _revealVideoRoomChrome();
  }

  void _revealVideoRoomChrome({bool restartHideTimer = true}) {
    if (!mounted || !_roomUsesVideo) return;
    if (_videoRoomChromePinned()) {
      _cancelVideoRoomChromeHideTimer();
      if (!_videoRoomChromeVisible) {
        setState(() => _videoRoomChromeVisible = true);
      }
      return;
    }
    if (!_videoRoomChromeVisible) {
      setState(() => _videoRoomChromeVisible = true);
    }
    if (restartHideTimer) {
      _scheduleVideoRoomChromeHide();
    }
  }

  void _scheduleVideoRoomChromeHide() {
    _cancelVideoRoomChromeHideTimer();
    if (!mounted || !_roomUsesVideo || _videoRoomChromePinned()) return;
    _videoRoomChromeHideTimer = Timer(_videoRoomChromeHideDelay, () {
      if (!mounted || _videoRoomChromePinned()) return;
      setState(() => _videoRoomChromeVisible = false);
    });
  }

  void _syncVideoRoomChromeWithActivity() {
    if (!_roomUsesVideo || _activeRoom == null) return;
    if (_videoRoomChromePinned()) {
      _revealVideoRoomChrome(restartHideTimer: false);
      return;
    }
    _revealVideoRoomChrome();
  }

  Future<void> _loadMyCommentTheme() async {
    final prefs = await ref.read(sharedPreferencesProvider.future);
    final saved = (prefs.getString(StorageKeys.liveCommentTheme) ?? 'glass')
        .trim()
        .toLowerCase();
    if (!mounted) return;
    setState(() {
      _myCommentTheme = _liveCommentThemes.contains(saved) ? saved : 'glass';
    });
  }

  Future<void> _saveMyCommentTheme(String value) async {
    final normalized = value.trim().toLowerCase();
    if (!_liveCommentThemes.contains(normalized)) return;
    final prefs = await ref.read(sharedPreferencesProvider.future);
    await prefs.setString(StorageKeys.liveCommentTheme, normalized);
    if (!mounted) return;
    setState(() => _myCommentTheme = normalized);
  }

  Future<void> _loadMyMicEffect() async {
    final prefs = await ref.read(sharedPreferencesProvider.future);
    final saved = (prefs.getString(StorageKeys.liveMicEffect) ?? 'pulse')
        .trim()
        .toLowerCase();
    if (!mounted) return;
    setState(() {
      _myMicEffect = _liveMicEffects.contains(saved) ? saved : 'pulse';
    });
  }

  Future<void> _saveMyMicEffect(String value) async {
    final normalized = _normalizeMicEffect(value);
    final prefs = await ref.read(sharedPreferencesProvider.future);
    await prefs.setString(StorageKeys.liveMicEffect, normalized);
    if (!mounted) return;
    setState(() => _myMicEffect = normalized);
    _syncMyMicEffectToRoom();
  }

  void _syncRoomChromeState() {
    ref.read(liveAudioRoomActiveProvider.notifier).state = _activeRoom != null;
    ref
        .read(liveRoomSessionProvider.notifier)
        .sync(
          room: _activeRoom,
          localMicEnabled: _localMicEnabled,
          handRaised: _handRaised,
          browseType: _browseType,
        );
    ref
        .read(liveRoomControllerProvider.notifier)
        .hydrate(
          room: _activeRoom,
          meId: _meId,
          localMicEnabled: _localMicEnabled,
        );
    // Cache host status as a plain bool so socket callbacks can read it
    // without touching autoDispose providers (which return initial state
    // when read outside a watch context).
    final myId = _meId;
    _amHosting = myId.isNotEmpty && _resolveHostUserId(_activeRoom) == myId;
    _syncRoomHealthMonitor();
  }

  bool get _shouldPreserveMinimizedAudioSession {
    final session = ref.read(liveRoomSessionProvider);
    return session.minimized &&
        session.isAudioRoom &&
        _activeRoom != null &&
        !_roomUsesVideo &&
        _usesSfuAudioPath;
  }

  void _restorePersistedLiveRoomSession() {
    final session = ref.read(liveRoomSessionProvider);
    final room = session.room;
    if (room == null) return;
    _activeRoom = _cloneRoomSnapshot(room);
    _browseType = session.browseType;
    _localMicEnabled = session.localMicEnabled;
    _handRaised = session.handRaised;
    _sfuConnected = _liveAudioService.isConnected;
    _loadingList = false;
    _refreshTopologyReady(_activeRoom);
  }

  Future<void> _resumePersistedLiveRoomSession() async {
    final room = _activeRoom;
    if (room == null) return;
    _sfuConnected = _liveAudioService.isConnectedToRoom('${room['id'] ?? ''}');
    if (_socketStatus == 'connected') {
      await _refreshActiveRoomViaJoin();
    }
    if (!mounted || _activeRoom == null) return;
    if (_usesSfuAudioPath) {
      await _refreshLiveAudioPublishState();
    } else {
      await _syncRtcParticipants();
    }
  }

  void _syncRoomHealthMonitor() {
    final hasActiveRoom = _activeRoom != null;
    if (!hasActiveRoom) {
      _roomHealthTimer?.cancel();
      _roomHealthTimer = null;
      _activeRoomMissingFromListCount = 0;
      return;
    }
    _roomHealthTimer ??= Timer.periodic(const Duration(seconds: 7), (_) {
      if (!mounted || _activeRoom == null) return;
      if (_socketStatus != 'connected') return;
      unawaited(_requestBroadcasts());
    });
  }

  void _syncBrowseListRefreshTimer() {
    final shouldRefresh =
        mounted && _activeRoom == null && _socketStatus == 'connected';
    if (!shouldRefresh) {
      _browseListRefreshTimer?.cancel();
      _browseListRefreshTimer = null;
      return;
    }
    _browseListRefreshTimer ??= Timer.periodic(const Duration(seconds: 6), (_) {
      if (!mounted || _activeRoom != null || _socketStatus != 'connected') {
        _syncBrowseListRefreshTimer();
        return;
      }
      unawaited(_requestBroadcasts(showLoadingOnFailure: false));
    });
  }

  Future<void> _refreshHostFollowState([Map<String, dynamic>? room]) async {
    final activeRoom = room ?? _activeRoom;
    if (activeRoom == null) return;
    final hostUserId = '${activeRoom['hostUserId'] ?? ''}';
    if (hostUserId.isEmpty || hostUserId == _meId) {
      if (mounted) {
        setState(() {
          _isFollowingHost = false;
          _followingHostBusy = false;
        });
      }
      return;
    }
    try {
      final response = await ref
          .read(apiClientProvider)
          .getJson('/users/$hostUserId');
      if (!mounted ||
          _activeRoom == null ||
          '${_activeRoom!['hostUserId'] ?? ''}' != hostUserId) {
        return;
      }
      setState(() {
        _isFollowingHost =
            (response['user'] as Map<String, dynamic>? ??
                const {})['isFollowing'] ==
            true;
      });
    } catch (_) {
      if (!mounted ||
          _activeRoom == null ||
          '${_activeRoom!['hostUserId'] ?? ''}' != hostUserId) {
        return;
      }
      setState(() => _isFollowingHost = false);
    }
  }

  void _cacheBroadcasts(List<Map<String, dynamic>> broadcasts) {
    ref.read(liveBroadcastCacheProvider.notifier).state = broadcasts;
  }

  bool _enrichActiveRoomFromBroadcasts() {
    final room = _activeRoom;
    if (room == null) return false;
    final roomId = '${room['id'] ?? ''}';
    if (roomId.isEmpty) return false;
    final matches = _broadcasts.where(
      (item) => '${item['id'] ?? ''}' == roomId,
    );
    if (matches.isEmpty) return false;
    final candidate = _normalizeBroadcast(
      Map<String, dynamic>.from(matches.first),
    );
    final next = Map<String, dynamic>.from(room);
    var changed = false;
    final currentHost = _resolveHostUserId(next);
    final candidateHost = _resolveHostUserId(candidate);
    if (currentHost.isEmpty && candidateHost.isNotEmpty) {
      next['hostUserId'] = candidateHost;
      changed = true;
    }
    final currentSpeakers = (next['speakers'] as List<dynamic>? ?? const []);
    final candidateSpeakers =
        (candidate['speakers'] as List<dynamic>? ?? const []);
    if (currentSpeakers.isEmpty && candidateSpeakers.isNotEmpty) {
      next['speakers'] = candidateSpeakers;
      changed = true;
    }
    if (!changed) return false;
    _activeRoom = next;
    return true;
  }

  Map<String, dynamic> _normalizeBroadcast(Map<String, dynamic> room) {
    final normalized = Map<String, dynamic>.from(room);
    final resolvedHost = _resolveHostUserId(normalized);
    if (resolvedHost.isNotEmpty) {
      normalized['hostUserId'] = resolvedHost;
    }
    normalized['comments'] =
        (normalized['comments'] as List<dynamic>? ?? const [])
            .whereType<Map>()
            .where((item) => !_isHiddenLiveSystemComment(item))
            .map((item) => Map<String, dynamic>.from(item))
            .toList(growable: true);
    normalized['activeNotice'] = normalized['activeNotice'] is Map
        ? Map<String, dynamic>.from(normalized['activeNotice'] as Map)
        : null;
    normalized['activePoll'] = normalized['activePoll'] is Map
        ? Map<String, dynamic>.from(normalized['activePoll'] as Map)
        : null;
    return normalized;
  }

  bool _isHiddenLiveSystemComment(Map<dynamic, dynamic> item) {
    final author = '${item['author'] ?? ''}'.trim().toLowerCase();
    final text = '${item['text'] ?? ''}'.trim().toLowerCase();
    return author == 'system' && text == 'broadcast started.';
  }

  int _roomVersionFrom(Map<String, dynamic>? room) {
    if (room == null) return 0;
    final roomVersion = (room['roomVersion'] as num?)?.toInt();
    if (roomVersion != null && roomVersion > 0) return roomVersion;
    final eventVersion = (room['eventVersion'] as num?)?.toInt();
    if (eventVersion != null && eventVersion > 0) return eventVersion;
    final revision = (room['revision'] as num?)?.toInt();
    if (revision != null && revision > 0) return revision;
    final seq = (room['seq'] as num?)?.toInt();
    if (seq != null && seq > 0) return seq;
    final version = (room['version'] as num?)?.toInt();
    if (version != null && version > 0) return version;
    final updatedAt = (room['updatedAt'] as num?)?.toInt();
    if (updatedAt != null && updatedAt > 0) return updatedAt;
    return 0;
  }

  int _speakerVersionFrom(Map<String, dynamic>? payload) {
    if (payload == null) return 0;
    final speakerVersion = (payload['speakerVersion'] as num?)?.toInt();
    if (speakerVersion != null && speakerVersion > 0) return speakerVersion;
    final stageVersion = (payload['stageVersion'] as num?)?.toInt();
    if (stageVersion != null && stageVersion > 0) return stageVersion;
    return 0;
  }

  bool _isStaleRoomEvent(Map<String, dynamic> room) {
    final incomingVersion = _roomVersionFrom(room);
    if (incomingVersion <= 0 || _activeRoomVersion <= 0) return false;
    return incomingVersion < _activeRoomVersion;
  }

  bool get _canUseStageMic {
    if (_socketStatus != 'connected') return false;
    if (!_usesSfuAudioPath) return true;
    return _liveAudioService.isConnected && _sfuConnected;
  }

  Future<bool> _ensureVerifiedLiveSocket({bool showError = true}) async {
    final session = ref.read(sessionControllerProvider);
    final token = session.token;
    final sessionId = session.sessionId;
    final user = session.user;
    if (token == null ||
        token.isEmpty ||
        sessionId == null ||
        sessionId.isEmpty ||
        user == null ||
        user.id.isEmpty) {
      if (showError && mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(
            content: Text(
              'Your session needs to be refreshed. Please sign in again.',
            ),
          ),
        );
      }
      return false;
    }
    final ready = await _socket.ensureSessionIdentity(
      token: token,
      expectedUserId: user.id,
      expectedSessionId: sessionId,
    );
    if (!ready && showError && mounted) {
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text(
            _socket.lastIdentityError ??
                'Realtime session is reconnecting. Please try again.',
          ),
        ),
      );
    }
    return ready;
  }

  void _recoverFromLiveIdentityMismatch(String message) {
    final session = ref.read(sessionControllerProvider);
    final token = session.token;
    final sessionId = session.sessionId;
    final user = session.user;
    _socket.disconnect();
    if (token != null &&
        token.isNotEmpty &&
        sessionId != null &&
        sessionId.isNotEmpty &&
        user != null &&
        user.id.isNotEmpty) {
      unawaited(
        _socket.ensureSessionIdentity(
          token: token,
          expectedUserId: user.id,
          expectedSessionId: sessionId,
        ),
      );
    }
    if (mounted) {
      ScaffoldMessenger.of(
        context,
      ).showSnackBar(SnackBar(content: Text(message)));
    }
  }

  bool _computeTopologyReady(Map<String, dynamic>? room) {
    if (room == null) return false;
    final hostUserId = _resolveHostUserId(room);
    if (hostUserId.isNotEmpty) return true;
    final speakers = (room['speakers'] as List<dynamic>? ?? const [])
        .whereType<Map>()
        .map((item) => Map<String, dynamic>.from(item));
    for (final speaker in speakers) {
      final occupied = speaker['occupied'] != false;
      final userId = '${speaker['userId'] ?? speaker['id'] ?? ''}'.trim();
      if (occupied && userId.isNotEmpty) return true;
    }
    return false;
  }

  void _refreshTopologyReady([Map<String, dynamic>? room]) {
    _topologyReady = _computeTopologyReady(room ?? _activeRoom);
  }

  void _upsertBroadcastLocally(Map<String, dynamic> broadcast) {
    final normalized = _normalizeBroadcast(broadcast);
    final next =
        [
          ..._broadcasts.where(
            (item) => '${item['id']}' != '${normalized['id']}',
          ),
          normalized,
        ]..sort(
          (a, b) => (b['createdAt'] as num? ?? 0).compareTo(
            a['createdAt'] as num? ?? 0,
          ),
        );
    if (!mounted) return;
    setState(() {
      _broadcasts = next;
      _loadingList = false;
    });
    _cacheBroadcasts(next);
    _syncBrowseListRefreshTimer();
  }

  void _removeBroadcastLocally(String broadcastId) {
    final next = _broadcasts
        .where((item) => '${item['id']}' != broadcastId)
        .toList();
    if (!mounted) return;
    setState(() {
      _broadcasts = next;
      _loadingList = false;
    });
    _cacheBroadcasts(next);
    _syncBrowseListRefreshTimer();
  }

  Future<void> _showBroadcastEndedCard() async {
    if (!mounted) return;
    await showDialog<void>(
      context: context,
      barrierDismissible: true,
      builder: (context) {
        final theme = Theme.of(context);
        return Dialog(
          insetPadding: const EdgeInsets.symmetric(horizontal: 28),
          shape: RoundedRectangleBorder(
            borderRadius: BorderRadius.circular(28),
          ),
          child: Padding(
            padding: const EdgeInsets.fromLTRB(24, 24, 24, 20),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                Icon(
                  Icons.graphic_eq_rounded,
                  size: 34,
                  color: theme.colorScheme.primary,
                ),
                const SizedBox(height: 14),
                Text(
                  'Live broadcast has ended',
                  textAlign: TextAlign.center,
                  style: theme.textTheme.titleLarge?.copyWith(
                    fontWeight: FontWeight.w800,
                  ),
                ),
                const SizedBox(height: 10),
                Text(
                  'You have been returned to the live list.',
                  textAlign: TextAlign.center,
                  style: theme.textTheme.bodyMedium?.copyWith(
                    color: theme.colorScheme.onSurfaceVariant,
                  ),
                ),
                const SizedBox(height: 18),
                FilledButton(
                  onPressed: () => Navigator.of(context).pop(),
                  style: FilledButton.styleFrom(
                    minimumSize: const Size.fromHeight(48),
                  ),
                  child: const Text('Okay'),
                ),
              ],
            ),
          ),
        );
      },
    );
  }

  Future<void> _followHost() async {
    final room = _activeRoom;
    if (room == null ||
        _followingHostBusy ||
        _isFollowingHost ||
        '${room['hostUserId'] ?? ''}'.isEmpty ||
        '${room['hostUserId'] ?? ''}' == _meId) {
      return;
    }
    setState(() => _followingHostBusy = true);
    try {
      final response = await ref
          .read(apiClientProvider)
          .postJson('/users/${room['hostUserId']}/follow');
      if (!mounted) return;
      setState(() {
        _isFollowingHost = response['following'] == true;
      });
    } catch (_) {
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('Unable to follow host right now')),
      );
    } finally {
      if (mounted) {
        setState(() => _followingHostBusy = false);
      }
    }
  }

  Future<void> _ensureLocalRendererReady() async {
    if (_localRendererReady) return;
    final renderer = RTCVideoRenderer();
    await renderer.initialize();
    _localRenderer = renderer;
    _localRendererReady = true;
  }

  Future<void> _disposeHostHeroRenderer() async {
    if (!_hostHeroRendererReady && _hostHeroRenderer == null) return;
    final hero = _hostHeroRenderer;
    _hostHeroRenderer = null;
    _hostHeroRendererReady = false;
    if (hero == null) return;
    try {
      hero.srcObject = null;
      await hero.dispose();
    } catch (_) {}
  }

  Future<void> _ensureHostHeroRenderer() async {
    if (_hostHeroRendererReady) return;
    final renderer = RTCVideoRenderer();
    await renderer.initialize();
    if (!mounted) {
      await renderer.dispose();
      return;
    }
    _hostHeroRenderer = renderer;
    _hostHeroRendererReady = true;
  }

  Future<void> _syncHostHeroVideo() async {
    final room = _activeRoom;
    if (room == null || !_roomUsesVideo || !mounted) return;
    await _ensureHostHeroRenderer();
    final hero = _hostHeroRenderer;
    if (hero == null) return;
    final hostId = _resolveHostUserId(room);
    MediaStream? stream;
    if (hostId.isNotEmpty && hostId == _meId) {
      stream = ref.read(webRtcServiceProvider).localStream;
    } else if (hostId.isNotEmpty) {
      stream = _remoteRenderers[hostId]?.srcObject;
    }
    final next = stream;
    final prev = hero.srcObject;
    if (prev?.id != next?.id) {
      hero.srcObject = next;
      if (mounted) setState(() {});
    }
  }

  void _bindSocket() {
    if (_socketBound) return;
    _socketBound = true;
    _socketRef = ref.read(socketServiceProvider);
    _socket.on('live:broadcasts', _onBroadcastList);
    _socket.on('live:broadcast:update', _onBroadcastUpdate);
    _socket.on('live:comment', _onComment);
    _socket.on('live:broadcast:ended', _onBroadcastEnded);
    _socket.on('live:join-requests', _onJoinRequests);
    _socket.on('live:request:decision', _onRequestDecision);
    _socket.on('live:media:session', _onLiveMediaSession);
    _socket.on('live:rtc:offer', _onRtcOffer);
    _socket.on('live:rtc:answer', _onRtcAnswer);
    _socket.on('live:rtc:ice', _onRtcIce);
    _socket.on('live:speaking', _onSpeaking);
    _socket.on('live:speaker:mute:update', _onSpeakerMuteUpdate);
    _socket.on('live:mic:effect:update', _onMicEffectUpdate);
    _socket.on('live:reaction', _onReaction);
    _socket.on('live:notice', _onLiveNotice);
    _socket.on('live:poll:update', _onLivePollUpdate);
    _socket.on('live:guest-preview:ended', _onGuestPreviewEnded);
    unawaited(_requestBroadcasts());
  }

  void _unbindSocket() {
    if (!_socketBound) return;
    _socketBound = false;
    _socket.off('live:broadcasts', _onBroadcastList);
    _socket.off('live:broadcast:update', _onBroadcastUpdate);
    _socket.off('live:comment', _onComment);
    _socket.off('live:broadcast:ended', _onBroadcastEnded);
    _socket.off('live:join-requests', _onJoinRequests);
    _socket.off('live:request:decision', _onRequestDecision);
    _socket.off('live:media:session', _onLiveMediaSession);
    _socket.off('live:rtc:offer', _onRtcOffer);
    _socket.off('live:rtc:answer', _onRtcAnswer);
    _socket.off('live:rtc:ice', _onRtcIce);
    _socket.off('live:speaking', _onSpeaking);
    _socket.off('live:speaker:mute:update', _onSpeakerMuteUpdate);
    _socket.off('live:mic:effect:update', _onMicEffectUpdate);
    _socket.off('live:reaction', _onReaction);
    _socket.off('live:notice', _onLiveNotice);
    _socket.off('live:poll:update', _onLivePollUpdate);
    _socket.off('live:guest-preview:ended', _onGuestPreviewEnded);
  }

  void _onSpeaking(dynamic data) {
    if (data is! Map || !mounted) return;
    final payload = Map<String, dynamic>.from(data);
    final room = _activeRoom;
    if (room == null) return;
    final eventBroadcastId = '${payload['broadcastId'] ?? ''}';
    if (eventBroadcastId.isNotEmpty &&
        eventBroadcastId != '${room['id'] ?? ''}') {
      return;
    }
    final userId = '${payload['userId'] ?? ''}';
    if (userId.isEmpty) return;
    final speaking = payload['speaking'] == true;
    final incomingSpeakerVersion = _speakerVersionFrom(payload);
    if (incomingSpeakerVersion > 0 &&
        _activeSpeakerVersion > 0 &&
        incomingSpeakerVersion < _activeSpeakerVersion) {
      return;
    }
    if (incomingSpeakerVersion > _activeSpeakerVersion) {
      _activeSpeakerVersion = incomingSpeakerVersion;
    }
    final incomingSeq = (payload['speakingSeq'] as num?)?.toInt() ?? 0;
    if (incomingSeq > 0) {
      final lastSeq = _latestSpeakingSeqByUser[userId] ?? 0;
      if (incomingSeq <= lastSeq) return;
      _latestSpeakingSeqByUser[userId] = incomingSeq;
    }
    if (!_isUserOnStage(userId)) {
      _activeSpeakers.remove(userId);
      _speakingDecayTimers.remove(userId)?.cancel();
      return;
    }
    setState(() {
      if (speaking) {
        _activeSpeakers.add(userId);
        _speakingDecayTimers.remove(userId)?.cancel();
        _speakingDecayTimers[userId] = Timer(const Duration(seconds: 3), () {
          if (!mounted) return;
          setState(() {
            _activeSpeakers.remove(userId);
          });
          _speakingDecayTimers.remove(userId);
        });
      } else {
        _activeSpeakers.remove(userId);
        _speakingDecayTimers.remove(userId)?.cancel();
      }
    });
  }

  void _applySpeakerMuteStateLocally({
    required String userId,
    required bool muted,
    bool mirrorToSelfMic = false,
  }) {
    final room = _activeRoom;
    if (room == null || userId.isEmpty) {
      if (muted) _activeSpeakers.remove(userId);
      return;
    }
    final speakers = (room['speakers'] as List<dynamic>? ?? const [])
        .map<dynamic>(
          (item) => item is Map ? Map<String, dynamic>.from(item) : item,
        )
        .toList(growable: true);
    var found = false;
    for (var i = 0; i < speakers.length; i++) {
      final speaker = speakers[i];
      if (speaker is! Map) continue;
      if ('${speaker['userId'] ?? ''}' != userId) continue;
      found = true;
      final next = Map<String, dynamic>.from(speaker);
      next['muted'] = muted;
      speakers[i] = next;
      break;
    }
    if (found) {
      _activeRoom = {...room, 'speakers': speakers};
    }
    if (mirrorToSelfMic && userId == _meId) {
      _localMicEnabled = !muted;
    }
    if (muted) {
      _activeSpeakers.remove(userId);
    }
  }

  List<dynamic> _mergeSpeakerMicEffects(
    List<dynamic> incomingSpeakers,
    List<dynamic> previousSpeakers,
  ) {
    final previousByUserId = <String, String>{};
    for (final speaker in previousSpeakers) {
      if (speaker is! Map) continue;
      final userId = '${speaker['userId'] ?? ''}'.trim();
      final effect = _normalizeMicEffect('${speaker['micEffect'] ?? ''}');
      if (userId.isNotEmpty) {
        previousByUserId[userId] = effect;
      }
    }
    return incomingSpeakers
        .map<dynamic>((item) {
          if (item is! Map) return item;
          final next = Map<String, dynamic>.from(item);
          final userId = '${next['userId'] ?? ''}'.trim();
          final incomingRaw = '${next['micEffect'] ?? ''}'.trim().toLowerCase();
          if (_liveMicEffects.contains(incomingRaw)) {
            next['micEffect'] = incomingRaw;
            return next;
          }
          if (userId.isNotEmpty && previousByUserId.containsKey(userId)) {
            next['micEffect'] = previousByUserId[userId];
          }
          return next;
        })
        .toList(growable: false);
  }

  void _applyMicEffectStateLocally({
    required String userId,
    required String micEffect,
  }) {
    final room = _activeRoom;
    if (room == null || userId.isEmpty) return;
    final normalized = _normalizeMicEffect(micEffect);
    final speakers = (room['speakers'] as List<dynamic>? ?? const [])
        .map<dynamic>(
          (item) => item is Map ? Map<String, dynamic>.from(item) : item,
        )
        .toList(growable: true);
    var found = false;
    for (var i = 0; i < speakers.length; i++) {
      final speaker = speakers[i];
      if (speaker is! Map) continue;
      if ('${speaker['userId'] ?? ''}' != userId) continue;
      found = true;
      final next = Map<String, dynamic>.from(speaker);
      next['micEffect'] = normalized;
      speakers[i] = next;
      break;
    }
    if (!found) {
      final hostUserId = _resolveHostUserId(room);
      if (userId == hostUserId) {
        speakers.insert(0, <String, dynamic>{
          'userId': userId,
          'name': '${room['host'] ?? 'Host'}',
          'photo': '${room['hostPhoto'] ?? ''}',
          'role': 'Host',
          'occupied': true,
          'micEffect': normalized,
        });
        found = true;
      }
    }
    if (found) {
      _activeRoom = {...room, 'speakers': speakers};
    }
  }

  void _emitMicEffectUpdate(String micEffect) {
    final room = _activeRoom;
    if (room == null || !_socket.isConnected || _meId.isEmpty) return;
    if (!_isUserOnStage(_meId)) return;
    _socket.emit('live:mic:effect:update', <String, dynamic>{
      'broadcastId': room['id'],
      'userId': _meId,
      'micEffect': _normalizeMicEffect(micEffect),
    });
  }

  void _syncMyMicEffectToRoom() {
    if (_activeRoom == null || _meId.isEmpty || !_isUserOnStage(_meId)) return;
    final micEffect = _micEffectName;
    setState(() {
      _applyMicEffectStateLocally(userId: _meId, micEffect: micEffect);
    });
    _syncRoomChromeState();
    _emitMicEffectUpdate(micEffect);
  }

  void _onMicEffectUpdate(dynamic data) {
    if (data is! Map || !mounted || _activeRoom == null) return;
    final payload = Map<String, dynamic>.from(data);
    final broadcastId = '${payload['broadcastId'] ?? ''}';
    if ('${_activeRoom!['id']}' != broadcastId) return;
    final userId = '${payload['userId'] ?? ''}'.trim();
    if (userId.isEmpty) return;
    final micEffect = _normalizeMicEffect('${payload['micEffect'] ?? ''}');
    setState(() {
      _applyMicEffectStateLocally(userId: userId, micEffect: micEffect);
    });
    _syncRoomChromeState();
  }

  void _onSpeakerMuteUpdate(dynamic data) {
    if (data is! Map || !mounted || _activeRoom == null) return;
    final payload = Map<String, dynamic>.from(data);
    final broadcastId = '${payload['broadcastId'] ?? ''}';
    if ('${_activeRoom!['id']}' != broadcastId) return;
    final userId = '${payload['userId'] ?? ''}';
    if (userId.isEmpty) return;
    final incomingSpeakerVersion = _speakerVersionFrom(payload);
    if (incomingSpeakerVersion > 0 &&
        _activeSpeakerVersion > 0 &&
        incomingSpeakerVersion < _activeSpeakerVersion) {
      return;
    }
    final muted = payload['muted'] == true;
    setState(() {
      _activeSpeakerVersion = math.max(
        _activeSpeakerVersion,
        incomingSpeakerVersion,
      );
      _applySpeakerMuteStateLocally(
        userId: userId,
        muted: muted,
        mirrorToSelfMic: userId == _meId,
      );
    });
    _syncRoomChromeState();
    if (userId == _meId) {
      if (_usesSfuAudioPath) {
        unawaited(_liveAudioService.setMicEnabled(!muted));
      }
      _syncSpeakingProbeLifecycle();
    }
  }

  void _onReaction(dynamic data) {
    if (data is! Map) return;
    final emoji = '${data['emoji'] ?? ''}';
    if (emoji.isNotEmpty) {
      _reactionController.add(emoji);
      if (emoji.contains('❤') && _amHosting && mounted) {
        setState(() => _heartCount++);
      }
    }
  }

  void _sendReaction(String emoji) {
    final room = _activeRoom;
    if (room == null || !_socket.isConnected) return;
    _reactionController.add(emoji);
    _socket.emit('live:reaction', <String, dynamic>{
      'broadcastId': room['id'],
      'emoji': emoji,
    });
  }

  void _onBroadcastList(dynamic data) {
    if (data is! Map) return;
    final broadcasts =
        (data['broadcasts'] as List<dynamic>? ?? const [])
            .whereType<Map>()
            .map((item) => _normalizeBroadcast(Map<String, dynamic>.from(item)))
            .toList()
          ..sort(
            (a, b) => (b['createdAt'] as num? ?? 0).compareTo(
              a['createdAt'] as num? ?? 0,
            ),
          );
    if (!mounted) return;
    final activeId = '${_activeRoom?['id'] ?? ''}';
    final hasActiveInList = activeId.isEmpty
        ? true
        : broadcasts.any((item) => '${item['id'] ?? ''}' == activeId);
    setState(() {
      _broadcasts = broadcasts;
      _loadingList = false;
      if (_enrichActiveRoomFromBroadcasts()) {
        _refreshTopologyReady();
        _queueRtcSync(immediate: true);
      }
      if (activeId.isNotEmpty) {
        if (hasActiveInList) {
          _activeRoomMissingFromListCount = 0;
        } else {
          _activeRoomMissingFromListCount += 1;
        }
      }
    });
    _cacheBroadcasts(broadcasts);
    _syncBrowseListRefreshTimer();
    _queueSharedBroadcastResolution();
    if (activeId.isNotEmpty &&
        !hasActiveInList &&
        _activeRoomMissingFromListCount >= 2) {
      unawaited(_forceExitActiveRoom(showEndedCard: !_isHost));
    }
  }

  void _onBroadcastUpdate(dynamic data) {
    if (data is! Map) return;
    final broadcast = _normalizeBroadcast(
      Map<String, dynamic>.from(
        data['broadcast'] as Map? ?? const <String, dynamic>{},
      ),
    );
    if (broadcast.isEmpty || !mounted) return;
    final activeId = '${_activeRoom?['id'] ?? ''}';
    final broadcastId = '${broadcast['id'] ?? ''}';
    if (activeId.isNotEmpty &&
        broadcastId == activeId &&
        _isStaleRoomEvent(broadcast)) {
      return;
    }
    final ended =
        broadcast['ended'] == true ||
        broadcast['isEnded'] == true ||
        broadcast['isActive'] == false ||
        '${broadcast['status'] ?? ''}'.toLowerCase() == 'ended';
    if (ended) {
      final endedId = '${broadcast['id'] ?? ''}';
      setState(() {
        _broadcasts = _broadcasts
            .where((item) => '${item['id'] ?? ''}' != endedId)
            .toList();
      });
      _cacheBroadcasts(_broadcasts);
      _syncBrowseListRefreshTimer();
      if (_activeRoom != null && '${_activeRoom!['id'] ?? ''}' == endedId) {
        unawaited(_forceExitActiveRoom(showEndedCard: !_isHost));
      }
      return;
    }
    final currentHostUserId = '${_activeRoom?['hostUserId'] ?? ''}';
    if ('${broadcast['hostUserId'] ?? ''}'.isEmpty) {
      if (currentHostUserId.isNotEmpty) {
        broadcast['hostUserId'] = currentHostUserId;
      } else {
        final previous = _broadcasts.where(
          (b) => '${b['id']}' == '${broadcast['id']}',
        );
        if (previous.isNotEmpty) {
          final prevHost = '${previous.first['hostUserId'] ?? ''}';
          if (prevHost.isNotEmpty) {
            broadcast['hostUserId'] = prevHost;
          }
        }
      }
    }
    setState(() {
      _broadcasts =
          [
            ..._broadcasts.where(
              (item) => '${item['id']}' != '${broadcast['id']}',
            ),
            broadcast,
          ]..sort(
            (a, b) => (b['createdAt'] as num? ?? 0).compareTo(
              a['createdAt'] as num? ?? 0,
            ),
          );
      _loadingList = false;
      if (_activeRoom != null &&
          '${_activeRoom!['id']}' == '${broadcast['id']}') {
        final mutedSpeakerIds =
            (broadcast['speakers'] as List<dynamic>? ?? const [])
                .whereType<Map>()
                .where((item) => item['muted'] == true)
                .map((item) => '${item['userId'] ?? ''}')
                .where((id) => id.isNotEmpty);
        for (final userId in mutedSpeakerIds) {
          _activeSpeakers.remove(userId);
        }
        developer.log(
          '[LIVE] Broadcast update – '
          'hostUserId="${broadcast['hostUserId']}", '
          'meId="$_meId", '
          'match=${_meId == '${broadcast['hostUserId'] ?? ''}'}',
          name: 'live_screen',
        );
        final previousSpeakers =
            (_activeRoom?['speakers'] as List<dynamic>? ?? const []);
        broadcast['speakers'] = _mergeSpeakerMicEffects(
          broadcast['speakers'] as List<dynamic>? ?? const [],
          previousSpeakers,
        );
        _activeRoom = broadcast;
        _activeRoomVersion = math.max(
          _activeRoomVersion,
          _roomVersionFrom(broadcast),
        );
        _activeSpeakerVersion = math.max(
          _activeSpeakerVersion,
          _speakerVersionFrom(broadcast),
        );
        _refreshTopologyReady(broadcast);
        _syncLiveTransientStateFromRoom(broadcast);
        _joinRequests =
            (broadcast['joinRequests'] as List<dynamic>? ?? const [])
                .whereType<Map>()
                .map((item) => Map<String, dynamic>.from(item))
                .toList();
      }
    });
    _cacheBroadcasts(_broadcasts);
    _syncBrowseListRefreshTimer();
    _syncRoomChromeState();
    if (_activeRoom != null &&
        '${_activeRoom!['id']}' == '${broadcast['id']}') {
      if (_usesSfuAudioPath) {
        unawaited(_refreshLiveAudioPublishState());
      }
      _queueRtcSync();
      unawaited(_refreshHostFollowState(broadcast));
      if (_roomUsesVideo) {
        unawaited(_pruneOffStageVideoRenderers());
      }
    }
  }

  void _onComment(dynamic data) {
    if (data is! Map) return;
    final broadcastId = '${data['broadcastId'] ?? ''}';
    if (_activeRoom == null || '${_activeRoom!['id']}' != broadcastId) return;
    final comment = Map<String, dynamic>.from(
      data['comment'] as Map? ?? const <String, dynamic>{},
    );
    if (!mounted || comment.isEmpty) return;
    setState(() {
      _comments = [..._comments, comment];
    });
    _jumpToLatestImmersiveCommentNextFrame();
  }

  void _onLiveNotice(dynamic data) {
    if (data is! Map || !mounted) return;
    final broadcastId = '${data['broadcastId'] ?? ''}';
    if (_activeRoom == null || '${_activeRoom!['id']}' != broadcastId) return;
    final notice = Map<String, dynamic>.from(
      data['notice'] as Map? ?? const <String, dynamic>{},
    );
    if (notice.isEmpty) return;
    final hostUserId = '${notice['hostUserId'] ?? ''}'.trim();
    if (hostUserId.isNotEmpty && hostUserId == _meId) {
      _lastShownNoticeId = '${notice['id'] ?? ''}'.trim();
      return;
    }
    unawaited(_showLiveNoticeDialog(notice));
  }

  void _showSavedJoinNoticeIfNeeded(Map<String, dynamic> room) {
    if (!mounted || _isHost) return;
    final notice = room['activeNotice'] is Map
        ? Map<String, dynamic>.from(room['activeNotice'] as Map)
        : null;
    if (notice == null || notice.isEmpty) return;
    unawaited(_showLiveNoticeDialog(notice));
  }

  void _onLivePollUpdate(dynamic data) {
    if (data is! Map || !mounted) return;
    final broadcastId = '${data['broadcastId'] ?? ''}';
    if (_activeRoom == null || '${_activeRoom!['id']}' != broadcastId) return;
    if (data['poll'] == null) {
      _cancelPollClearTimer();
      setState(() {
        _activePoll = null;
        _myPollVoteOptionId = null;
      });
      return;
    }
    final poll = Map<String, dynamic>.from(
      data['poll'] as Map? ?? const <String, dynamic>{},
    );
    if (poll.isEmpty) {
      _cancelPollClearTimer();
      setState(() {
        _activePoll = null;
        _myPollVoteOptionId = null;
      });
      return;
    }
    setState(() => _activePoll = poll);
    _syncPollClearTimer(poll);
  }

  void _cancelPollClearTimer() {
    _pollClearTimer?.cancel();
    _pollClearTimer = null;
  }

  void _syncPollClearTimer(Map<String, dynamic>? poll) {
    _cancelPollClearTimer();
    if (poll == null || '${poll['status'] ?? ''}' != 'concluded') return;
    final pollId = '${poll['id'] ?? ''}';
    _pollClearTimer = Timer(const Duration(seconds: 6), () {
      if (!mounted || '${_activePoll?['id'] ?? ''}' != pollId) return;
      setState(() {
        _activePoll = null;
        _myPollVoteOptionId = null;
      });
    });
  }

  Future<void> _showLiveNoticeDialog(Map<String, dynamic> notice) async {
    final noticeId = '${notice['id'] ?? ''}'.trim();
    final text = '${notice['text'] ?? ''}'.trim();
    if (text.isEmpty ||
        noticeId == _lastShownNoticeId ||
        _liveNoticeDialogOpen ||
        !mounted) {
      return;
    }
    _lastShownNoticeId = noticeId;
    await _waitForRouteToSettle();
    if (!mounted) return;
    _liveNoticeDialogOpen = true;
    final colorScheme = Theme.of(context).colorScheme;
    try {
      await showDialog<void>(
        context: context,
        useRootNavigator: true,
        barrierDismissible: false,
        builder: (dialogContext) {
          return AlertDialog(
            title: Row(
              children: [
                Icon(Icons.campaign_outlined, color: colorScheme.primary),
                const SizedBox(width: 10),
                const Expanded(child: Text('Host notice')),
              ],
            ),
            content: Text(text),
            actions: [
              FilledButton(
                onPressed: () =>
                    Navigator.of(dialogContext, rootNavigator: true).pop(),
                child: const Text('OK'),
              ),
            ],
          );
        },
      );
    } finally {
      _liveNoticeDialogOpen = false;
    }
  }

  void _onGuestPreviewEnded(dynamic data) {
    if (!_shouldUseGuestLivePreview || !mounted) return;
    unawaited(_expireGuestLivePreview());
  }

  Future<void> _expireGuestLivePreview() async {
    _guestPreviewCountdownTimer?.cancel();
    _guestPreviewCountdownTimer = null;
    await _liveAudioService.disconnect();
    if (!mounted) return;
    setState(() {
      _guestPreviewExpired = true;
      _guestPreviewEndsAt = DateTime.now();
      _sfuConnected = false;
      _localMicEnabled = false;
    });
  }

  String _guestPreviewReturnPath() {
    final roomId =
        '${_activeRoom?['id'] ?? _pendingSharedBroadcastId ?? widget.initialBroadcastId ?? ''}'
            .trim();
    if (roomId.isEmpty) return '/app/live';
    return Uri(
      path: '/app/live',
      queryParameters: <String, String>{'broadcastId': roomId},
    ).toString();
  }

  void _openGuestPreviewSignup() {
    final next = Uri.encodeComponent(_guestPreviewReturnPath());
    context.go('/signup?next=$next');
  }

  void _openGuestPreviewLogin() {
    final next = Uri.encodeComponent(_guestPreviewReturnPath());
    context.go('/login?next=$next');
  }

  void _minimizeAudioRoom() {
    if (_activeRoom == null || _roomUsesVideo || _shouldUseGuestLivePreview) {
      return;
    }
    _syncRoomChromeState();
    ref.read(liveRoomSessionProvider.notifier).setMinimized(true);
    context.go('/app/content');
  }

  void _startGuestPreviewCountdown(DateTime endsAt) {
    _guestPreviewCountdownTimer?.cancel();
    _guestPreviewCountdownTimer = Timer.periodic(const Duration(seconds: 1), (
      _,
    ) {
      if (!mounted) return;
      if (DateTime.now().isAfter(endsAt)) {
        unawaited(_expireGuestLivePreview());
        return;
      }
      setState(() {});
    });
  }

  Future<void> _waitForRouteToSettle() async {
    await Future<void>.delayed(const Duration(milliseconds: 260));
    if (!mounted) return;
    await WidgetsBinding.instance.endOfFrame;
  }

  void _onBroadcastEnded(dynamic data) {
    if (data is! Map || !mounted) return;
    final broadcastId = '${data['broadcastId'] ?? ''}';
    final wasActive =
        _activeRoom != null && '${_activeRoom!['id']}' == broadcastId;
    setState(() {
      _broadcasts = _broadcasts
          .where((item) => '${item['id']}' != broadcastId)
          .toList();
      _loadingList = false;
      if (wasActive) {
        _activeRoom = null;
        _lastShownNoticeId = null;
        _activeRoomVersion = 0;
        _activeSpeakerVersion = 0;
        _comments = const [];
        _joinRequests = const [];
        _handRaised = false;
        _commentController.clear();
        _isFollowingHost = false;
        _followingHostBusy = false;
        _heartCount = 0;
        _amHosting = false;
        _syncLiveTransientStateFromRoom(null);
        _activeSpeakers.clear();
        _latestSpeakingSeqByUser.clear();
      }
    });
    _cacheBroadcasts(_broadcasts);
    if (wasActive) {
      unawaited(_liveAudioService.disconnect());
      unawaited(_disposeRtc());
      _syncRoomChromeState();
      unawaited(_showBroadcastEndedCard());
    }
  }

  Future<void> _forceExitActiveRoom({required bool showEndedCard}) async {
    if (_activeRoom == null || !mounted) return;
    await _liveAudioService.disconnect();
    await _disposeRtc();
    if (!mounted) return;
    setState(() {
      _activeRoom = null;
      _lastShownNoticeId = null;
      _activeRoomVersion = 0;
      _activeSpeakerVersion = 0;
      _topologyReady = false;
      _comments = const [];
      _joinRequests = const [];
      _syncLiveTransientStateFromRoom(null);
      _handRaised = false;
      _commentController.clear();
      _isFollowingHost = false;
      _followingHostBusy = false;
      _syncLiveTransientStateFromRoom(null);
      _activeSpeakers.clear();
      _activeRoomMissingFromListCount = 0;
      _sfuConnected = false;
      _latestSpeakingSeqByUser.clear();
    });
    _syncRoomChromeState();
    unawaited(Helper.setSpeakerphoneOn(false));
    if (showEndedCard) {
      await _showBroadcastEndedCard();
    }
  }

  void _onJoinRequests(dynamic data) {
    if (data is! Map) return;
    final broadcastId = '${data['broadcastId'] ?? ''}';
    if (_activeRoom == null ||
        '${_activeRoom!['id']}' != broadcastId ||
        !mounted) {
      return;
    }
    if (_isStaleRoomEvent(Map<String, dynamic>.from(data))) return;
    setState(() {
      _joinRequests = (data['requests'] as List<dynamic>? ?? const [])
          .whereType<Map>()
          .map((item) => Map<String, dynamic>.from(item))
          .toList();
    });
  }

  Future<void> _onRequestDecision(dynamic data) async {
    if (data is! Map || _activeRoom == null) return;
    final broadcastId = '${data['broadcastId'] ?? ''}';
    if ('${_activeRoom!['id']}' != broadcastId) return;
    if (_isStaleRoomEvent(Map<String, dynamic>.from(data))) return;
    final accepted = _isDecisionAccepted(data);
    _activeRoomVersion = math.max(
      _activeRoomVersion,
      _roomVersionFrom(Map<String, dynamic>.from(data)),
    );
    _activeSpeakerVersion = math.max(
      _activeSpeakerVersion,
      _speakerVersionFrom(Map<String, dynamic>.from(data)),
    );
    _recordRtcTransition(
      'request_decision accepted=$accepted stage=$_amOnStage mic=$_localMicEnabled',
    );
    if (!mounted) return;
    setState(() {
      _handRaised = false;
      if (accepted) {
        _localMicEnabled = !_usesSfuAudioPath;
        if (!_usesSfuAudioPath) {
          _optimisticallyPromoteSelfToStage();
          _syncMyMicEffectToRoom();
        }
      }
    });
    if (accepted) {
      if (_usesSfuAudioPath) {
        if (_roomUsesVideo) {
          setState(() {
            _optimisticallyPromoteSelfToStage();
            _localMicEnabled = true;
            _localVideoEnabled = true;
          });
          await _refreshLiveAudioPublishState();
          if (!mounted) return;
          ScaffoldMessenger.of(context).showSnackBar(
            const SnackBar(content: Text('You are now on stage.')),
          );
        } else {
          final joined = await _completeApprovedStageJoin();
          if (!joined || !mounted) return;
          ScaffoldMessenger.of(context).showSnackBar(
            const SnackBar(content: Text("You're now a speaker. Mic is off.")),
          );
        }
      } else {
        ScaffoldMessenger.of(
          context,
        ).showSnackBar(const SnackBar(content: Text('You are now a speaker.')));
        await _syncRtcParticipants();
        _syncStageMuteState();
      }
    } else {
      ScaffoldMessenger.of(
        context,
      ).showSnackBar(const SnackBar(content: Text('Speaker request declined')));
    }
  }

  Future<bool> _completeApprovedStageJoin() async {
    final room = _activeRoom;
    if (room == null || !_socket.isConnected) return false;
    _recordRtcTransition('stage_ready request room=${room['id'] ?? ''}');
    final payload = await _socket.emitWithAckRetry(
      'live:speaker:ready',
      <String, dynamic>{'broadcastId': room['id']},
      timeout: const Duration(seconds: 5),
      maxAttempts: 2,
    );
    if (!mounted) return false;
    if (payload is! Map || payload['ok'] != true) {
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text(
            payload is Map
                ? '${payload['message'] ?? 'Unable to join speakers right now'}'
                : 'Speaker join timed out. Please try again.',
          ),
        ),
      );
      return false;
    }
    final broadcast = _normalizeBroadcast(
      Map<String, dynamic>.from(payload['broadcast'] as Map? ?? room),
    );
    final mediaSession = payload['mediaSession'] is Map
        ? Map<String, dynamic>.from(payload['mediaSession'] as Map)
        : null;
    setState(() {
      _activeRoom = broadcast;
      _activeRoomVersion = _roomVersionFrom(broadcast);
      _activeSpeakerVersion = _speakerVersionFrom(broadcast);
      _refreshTopologyReady(broadcast);
      _joinRequests = (broadcast['joinRequests'] as List<dynamic>? ?? const [])
          .whereType<Map>()
          .map((item) => Map<String, dynamic>.from(item))
          .toList();
      _localMicEnabled = false;
    });
    _syncRoomChromeState();
    await _connectLiveAudioSfu(room: broadcast, mediaSession: mediaSession);
    await _refreshLiveAudioPublishState();
    _syncMyMicEffectToRoom();
    return true;
  }

  Future<void> _onLiveMediaSession(dynamic data) async {
    if (data is! Map || _activeRoom == null) return;
    final payload = Map<String, dynamic>.from(data);
    final roomId = '${_activeRoom!['id'] ?? ''}';
    if ('${payload['broadcastId'] ?? ''}' != roomId) {
      return;
    }
    final sessionRaw = payload['mediaSession'];
    if (sessionRaw is! Map) return;
    // Keep a single SFU session per room to avoid reconnect churn during
    // listener<->speaker transitions. Role changes should only toggle publish.
    if (_liveAudioService.isConnectedToRoom(roomId)) {
      _recordRtcTransition('sfu_media_session refresh while connected');
      final canPublish = sessionRaw['canPublish'] == true;
      await _liveAudioService.refreshStagePublish(
        shouldPublish: canPublish && _amOnStage,
        micEnabled: _localMicEnabled,
        cameraEnabled: _localVideoEnabled,
      );
      if (_roomUsesVideo && canPublish) {
        _localVideoEnabled = _liveAudioService.isLocalCameraEnabled;
      }
      await _refreshLiveAudioPublishState();
      return;
    }
    await _connectLiveAudioSfu(
      room: _activeRoom!,
      mediaSession: Map<String, dynamic>.from(sessionRaw),
    );
    await _refreshLiveAudioPublishState();
  }

  bool _isDecisionAccepted(Map data) {
    if (data['accept'] == true || data['accepted'] == true) return true;
    final decision = '${data['decision'] ?? data['status'] ?? ''}'
        .toLowerCase();
    return decision == 'accept' ||
        decision == 'accepted' ||
        decision == 'approved';
  }

  bool get _usesSfuAudioPath => AppConfig.liveUseSfuAudio;

  Future<void> _connectLiveAudioSfu({
    required Map<String, dynamic> room,
    required Map<String, dynamic>? mediaSession,
  }) async {
    if (!_usesSfuAudioPath) return;
    final roomId = '${room['id'] ?? ''}';
    if (roomId.isEmpty) return;
    if (_liveAudioService.isConnectedToRoom(roomId)) {
      _recordRtcTransition('sfu_connect skip already_connected room=$roomId');
      if (mounted) {
        setState(() {
          _sfuConnected = true;
        });
      }
      return;
    }
    if (_sfuConnectInFlight != null) {
      _recordRtcTransition('sfu_connect await_inflight room=$roomId');
      await _sfuConnectInFlight;
      return;
    }
    _recordRtcTransition('sfu_connect start room=$roomId');
    final connectFuture = () async {
      Map<String, dynamic>? session = mediaSession;
      if (session == null || '${session['token'] ?? ''}'.isEmpty) {
        _recordRtcTransition('sfu_connect requesting session:get');
        final payload = await _socket.emitWithAckRetry(
          'live:media:session:get',
          <String, dynamic>{'broadcastId': room['id']},
          timeout: const Duration(seconds: 5),
          maxAttempts: 2,
        );
        if (payload is Map &&
            payload['ok'] == true &&
            payload['mediaSession'] is Map) {
          session = Map<String, dynamic>.from(payload['mediaSession'] as Map);
        } else {
          _recordRtcTransition('sfu_connect session:get failed');
        }
      }
      if (session == null) return;
      final url = '${session['url'] ?? ''}'.trim();
      final token = '${session['token'] ?? ''}'.trim();
      if (url.isEmpty || token.isEmpty) return;
      final canPublish = session['canPublish'] == true;
      final publishVideo =
          _roomUsesVideo &&
          (session['publishVideo'] == true || canPublish);
      developer.log(
        '[LIVE][SFU] connect attempt room="${room['id']}" '
        'canPublish=$canPublish publishVideo=$publishVideo '
        'url="$url" tokenLen=${token.length}',
        name: 'live_screen',
      );
      try {
        _liveAudioService.onParticipantsChanged = () {
          if (mounted) setState(() {});
        };
        await _liveAudioService.connect(
          url: url,
          token: token,
          roomName: roomId,
          canPublish: canPublish,
          publishVideo: publishVideo,
        );
        if (_roomUsesVideo) {
          _localVideoEnabled = publishVideo
              ? _liveAudioService.isLocalCameraEnabled
              : false;
        }
        _recordRtcTransition(
          'sfu_connect ok publish=$canPublish video=$publishVideo',
        );
      } catch (error, stackTrace) {
        developer.log(
          '[LIVE][SFU] connect failed: $error',
          name: 'live_screen',
          stackTrace: stackTrace,
        );
        _recordRtcTransition('sfu_connect failed');
        if (mounted) {
          setState(() {
            _sfuConnected = false;
          });
        }
        return;
      }
      if (mounted) {
        setState(() {
          _sfuConnected = _liveAudioService.isConnected;
          if (!canPublish) {
            _localMicEnabled = false;
          }
        });
      }
    }();
    _sfuConnectInFlight = connectFuture;
    try {
      await connectFuture;
    } finally {
      if (identical(_sfuConnectInFlight, connectFuture)) {
        _sfuConnectInFlight = null;
      }
    }
  }

  Future<void> _refreshLiveAudioPublishState() async {
    if (!_usesSfuAudioPath) return;
    final shouldPublish = _amOnStage;
    final micEnabled = shouldPublish && _localMicEnabled;
    final cameraEnabled = shouldPublish && _localVideoEnabled;
    _recordRtcTransition(
      'sfu_publish mic=$micEnabled video=$cameraEnabled stage=$shouldPublish',
    );
    try {
      await _liveAudioService.refreshStagePublish(
        shouldPublish: shouldPublish,
        micEnabled: micEnabled,
        cameraEnabled: cameraEnabled,
      );
      if (_roomUsesVideo) {
        _localVideoEnabled = _liveAudioService.isLocalCameraEnabled;
      }
    } catch (error, stackTrace) {
      developer.log(
        '[LIVE][SFU] publish toggle failed: $error',
        name: 'live_screen',
        stackTrace: stackTrace,
      );
      _recordRtcTransition('sfu_publish failed');
    }
    if (!mounted) return;
    setState(() {
      _sfuConnected = _liveAudioService.isConnected;
      if (!shouldPublish) {
        _localMicEnabled = false;
      }
    });
  }

  Future<bool> _createBroadcast(
    String title, {
    required String type,
    String? description,
    required String language,
    String? secondLanguage,
    bool isPrivate = false,
  }) async {
    final me = ref.read(sessionControllerProvider).user;
    if (me == null || title.trim().isEmpty || _creating) {
      return false;
    }
    final sessionId = ref.read(sessionControllerProvider).sessionId ?? '';
    if (!await _ensureVerifiedLiveSocket()) return false;
    final allowed = type == 'video'
        ? await _permissionService.ensureCameraAndMicrophone()
        : await _permissionService.ensureMicrophone();
    if (!allowed) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text(
              type == 'video'
                  ? 'Camera and microphone access are required to go live.'
                  : 'Microphone access is required to go live.',
            ),
          ),
        );
      }
      return false;
    }

    setState(() => _creating = true);
    final payload = await _socket.emitWithAckRetry(
      'live:broadcast:create',
      <String, dynamic>{
        'type': type,
        'lang': language,
        'lang2': secondLanguage,
        'description': description,
        'isPrivate': isPrivate,
        'title': title.trim(),
        'userId': me.id,
        'expectedUserId': me.id,
        'expectedSessionId': sessionId,
        'host': me.displayName,
        'hostPhoto': me.profilePhotoUrl,
        'hostNationalityCode': me.nationalityCode,
        'micEffect': _micEffectName,
      },
      timeout: const Duration(seconds: 6),
      maxAttempts: 2,
    );
    if (!mounted) return false;
    setState(() => _creating = false);
    if (payload is Map && payload['ok'] == true) {
      final broadcast = _normalizeBroadcast(
        Map<String, dynamic>.from(
          payload['broadcast'] as Map? ?? const <String, dynamic>{},
        ),
      );
      final returnedHostUserId = '${broadcast['hostUserId'] ?? ''}'.trim();
      if (returnedHostUserId.isNotEmpty && returnedHostUserId != me.id) {
        _recoverFromLiveIdentityMismatch(
          'Realtime session mismatch detected. The room was not created.',
        );
        return false;
      }
      final mediaSession = payload['mediaSession'] is Map
          ? Map<String, dynamic>.from(payload['mediaSession'] as Map)
          : null;
      if ('${broadcast['hostUserId'] ?? ''}'.isEmpty) {
        broadcast['hostUserId'] = me.id;
      }
      developer.log(
        '[LIVE] Created broadcast – '
        'hostUserId="${broadcast['hostUserId']}", '
        'meId="$_meId", '
        'match=${_meId == '${broadcast['hostUserId'] ?? ''}'}',
        name: 'live_screen',
      );
      _upsertBroadcastLocally(broadcast);
      setState(() {
        _activeRoom = broadcast;
        _activeRoomVersion = _roomVersionFrom(broadcast);
        _activeSpeakerVersion = _speakerVersionFrom(broadcast);
        _refreshTopologyReady(broadcast);
        _browseType = '${broadcast['type'] ?? 'audio'}';
        ref.read(liveBrowseTypeProvider.notifier).state = _browseType;
        _language = language;
        _syncLiveTransientStateFromRoom(broadcast);
        _comments = (broadcast['comments'] as List<dynamic>? ?? const [])
            .whereType<Map>()
            .map((item) => Map<String, dynamic>.from(item))
            .toList();
        _joinRequests = const [];
        _commentController.clear();
        _isFollowingHost = false;
      });
      _syncRoomChromeState();
      unawaited(_refreshHostFollowState(broadcast));
      _showSavedJoinNoticeIfNeeded(broadcast);
      if (_usesSfuAudioPath) {
        await _connectLiveAudioSfu(room: broadcast, mediaSession: mediaSession);
        await _refreshLiveAudioPublishState();
      } else if (!_roomUsesVideo) {
        await _syncRtcParticipants();
      }
      _syncMyMicEffectToRoom();
      return true;
    }
    if (payload is Map && payload['code'] == 'auth_identity_mismatch') {
      _recoverFromLiveIdentityMismatch(
        '${payload['message'] ?? 'Realtime session mismatch detected.'}',
      );
      return false;
    }
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(
        content: Text(
          payload is Map
              ? '${payload['message'] ?? 'Unable to create broadcast'}'
              : 'Broadcast creation timed out. Try again.',
        ),
      ),
    );
    return false;
  }

  Future<void> _joinBroadcast(Map<String, dynamic> room) async {
    final me = ref.read(sessionControllerProvider).user;
    if (me == null) return;
    final sessionId = ref.read(sessionControllerProvider).sessionId ?? '';
    if (!await _ensureVerifiedLiveSocket()) return;
    _recordRtcTransition('join_broadcast start room=${room['id'] ?? ''}');
    final payload = await _socket.emitWithAckRetry(
      'live:broadcast:join',
      <String, dynamic>{
        'broadcastId': room['id'],
        'expectedUserId': me.id,
        'expectedSessionId': sessionId,
        'name': me.displayName,
        'photo': me.profilePhotoUrl,
      },
      timeout: const Duration(seconds: 5),
      maxAttempts: 2,
    );
    if (!mounted) return;
    if (payload is Map && payload['ok'] == true) {
      final broadcast = _normalizeBroadcast(
        Map<String, dynamic>.from(payload['broadcast'] as Map? ?? room),
      );
      final mediaSession = payload['mediaSession'] is Map
          ? Map<String, dynamic>.from(payload['mediaSession'] as Map)
          : null;
      if ('${broadcast['hostUserId'] ?? ''}'.isEmpty &&
          '${broadcast['host'] ?? ''}' == me.displayName) {
        broadcast['hostUserId'] = me.id;
      }
      _recordRtcTransition(
        'join_broadcast ok role=${_isHost ? 'host' : (_amOnStage ? 'speaker' : 'listener')}',
      );
      setState(() {
        _activeRoom = broadcast;
        _activeRoomVersion = _roomVersionFrom(broadcast);
        _activeSpeakerVersion = _speakerVersionFrom(broadcast);
        _refreshTopologyReady(broadcast);
        _browseType = '${broadcast['type'] ?? _browseType}';
        ref.read(liveBrowseTypeProvider.notifier).state = _browseType;
        _syncLiveTransientStateFromRoom(broadcast);
        _comments = const [];
        _joinRequests =
            (broadcast['joinRequests'] as List<dynamic>? ?? const [])
                .whereType<Map>()
                .map((item) => Map<String, dynamic>.from(item))
                .toList();
        _handRaised = false;
        _commentController.clear();
        _isFollowingHost = false;
        _activeSpeakers.clear();
      });
      _jumpToLatestImmersiveCommentNextFrame();
      _syncRoomChromeState();
      _syncBrowseListRefreshTimer();
      unawaited(_refreshHostFollowState(broadcast));
      if (_usesSfuAudioPath) {
        await _connectLiveAudioSfu(room: broadcast, mediaSession: mediaSession);
        await _refreshLiveAudioPublishState();
      } else {
        // Mesh audio fallback: merge list snapshot so host/speaker ids exist.
        if (_enrichActiveRoomFromBroadcasts()) {
          _refreshTopologyReady(_activeRoom);
        }
        await _syncRtcParticipants();
        unawaited(_refreshRoomTopologyAfterJoin());
      }
      _syncMyMicEffectToRoom();
      return;
    }
    if (payload is Map && payload['code'] == 'auth_identity_mismatch') {
      _recoverFromLiveIdentityMismatch(
        '${payload['message'] ?? 'Realtime session mismatch detected.'}',
      );
      _recordRtcTransition('join_broadcast identity_mismatch');
      return;
    }
    if (payload is Map && payload['code'] == 'room_full') {
      await _showRoomFullDialog(
        '${payload['message'] ?? 'Room full. Try the next broadcast.'}',
      );
      _recordRtcTransition('join_broadcast room_full');
      return;
    }
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(
        content: Text(
          payload is Map
              ? '${payload['message'] ?? 'Unable to join broadcast right now'}'
              : 'Join timed out. Please try again.',
        ),
      ),
    );
    _recordRtcTransition('join_broadcast failed');
  }

  Future<void> _showRoomFullDialog(String message) async {
    if (!mounted) return;
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;
    await showDialog<void>(
      context: context,
      barrierDismissible: true,
      builder: (dialogContext) {
        return Dialog(
          insetPadding: const EdgeInsets.symmetric(horizontal: 28),
          shape: RoundedRectangleBorder(
            borderRadius: BorderRadius.circular(28),
          ),
          child: Container(
            decoration: BoxDecoration(
              borderRadius: BorderRadius.circular(28),
              gradient: LinearGradient(
                begin: Alignment.topLeft,
                end: Alignment.bottomRight,
                colors: [
                  scheme.surface,
                  scheme.surfaceContainerHighest.withValues(alpha: 0.94),
                ],
              ),
              border: Border.all(color: scheme.primary.withValues(alpha: 0.18)),
              boxShadow: [
                BoxShadow(
                  color: scheme.primary.withValues(alpha: 0.18),
                  blurRadius: 28,
                  offset: const Offset(0, 14),
                ),
              ],
            ),
            padding: const EdgeInsets.fromLTRB(24, 24, 24, 20),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                Container(
                  width: 58,
                  height: 58,
                  decoration: BoxDecoration(
                    shape: BoxShape.circle,
                    color: scheme.primary.withValues(alpha: 0.12),
                  ),
                  child: Icon(
                    Icons.groups_2_rounded,
                    color: scheme.primary,
                    size: 30,
                  ),
                ),
                const SizedBox(height: 16),
                Text(
                  'Room is full',
                  textAlign: TextAlign.center,
                  style: theme.textTheme.titleLarge?.copyWith(
                    fontWeight: FontWeight.w900,
                  ),
                ),
                const SizedBox(height: 8),
                Text(
                  message,
                  textAlign: TextAlign.center,
                  style: theme.textTheme.bodyMedium?.copyWith(
                    color: scheme.onSurfaceVariant,
                    height: 1.35,
                    fontWeight: FontWeight.w600,
                  ),
                ),
                const SizedBox(height: 22),
                FilledButton(
                  onPressed: () => Navigator.of(dialogContext).pop(),
                  style: FilledButton.styleFrom(
                    minimumSize: const Size.fromHeight(46),
                    shape: RoundedRectangleBorder(
                      borderRadius: BorderRadius.circular(16),
                    ),
                  ),
                  child: const Text('OK'),
                ),
              ],
            ),
          ),
        );
      },
    );
  }

  Future<void> _joinGuestLivePreview(Map<String, dynamic> room) async {
    if (_guestPreviewJoinInFlight || _guestPreviewExpired) return;
    final roomId = '${room['id'] ?? ''}'.trim();
    if (roomId.isEmpty || !_socket.isConnected) return;
    _guestPreviewJoinInFlight = true;
    _recordRtcTransition('guest_preview_join start room=$roomId');
    final payload = await _socket.emitWithAckRetry(
      'live:broadcast:guest-preview:join',
      <String, dynamic>{'broadcastId': roomId},
      timeout: const Duration(seconds: 5),
      maxAttempts: 2,
    );
    _guestPreviewJoinInFlight = false;
    if (!mounted) return;
    if (payload is Map && payload['ok'] == true) {
      final broadcast = _normalizeBroadcast(
        Map<String, dynamic>.from(payload['broadcast'] as Map? ?? room),
      );
      final mediaSession = payload['mediaSession'] is Map
          ? Map<String, dynamic>.from(payload['mediaSession'] as Map)
          : null;
      final preview = payload['guestPreview'] is Map
          ? Map<String, dynamic>.from(payload['guestPreview'] as Map)
          : const <String, dynamic>{};
      final expiresAtMs = (preview['expiresAt'] as num?)?.toInt() ?? 0;
      final endsAt = expiresAtMs > 0
          ? DateTime.fromMillisecondsSinceEpoch(expiresAtMs)
          : DateTime.now().add(const Duration(seconds: 45));
      setState(() {
        _activeRoom = broadcast;
        _activeRoomVersion = _roomVersionFrom(broadcast);
        _activeSpeakerVersion = _speakerVersionFrom(broadcast);
        _refreshTopologyReady(broadcast);
        _browseType = '${broadcast['type'] ?? _browseType}';
        _syncLiveTransientStateFromRoom(broadcast);
        _comments = const [];
        _joinRequests = const [];
        _handRaised = false;
        _commentController.clear();
        _isFollowingHost = false;
        _activeSpeakers.clear();
        _guestPreviewExpired = false;
        _guestPreviewEndsAt = endsAt;
        _localMicEnabled = false;
      });
      _startGuestPreviewCountdown(endsAt);
      if (_usesSfuAudioPath) {
        await _connectLiveAudioSfu(room: broadcast, mediaSession: mediaSession);
      }
      return;
    }
    setState(() {
      _guestPreviewExpired = true;
      _guestPreviewEndsAt = DateTime.now();
    });
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(
        content: Text(
          payload is Map
              ? '${payload['message'] ?? 'Create an account to join this room.'}'
              : 'Create an account to join this room.',
        ),
      ),
    );
  }

  Future<void> _refreshRoomTopologyAfterJoin() async {
    // Some backends return a minimal join payload first, then fill speaker/host
    // topology shortly after. Refresh once to avoid silent listener joins.
    await Future<void>.delayed(const Duration(milliseconds: 320));
    if (!mounted || _activeRoom == null) return;
    await _refreshActiveRoomViaJoin();
    if (_enrichActiveRoomFromBroadcasts()) {
      _recordRtcTransition('topology_enriched_from_list');
    }
    if (!mounted || _activeRoom == null) return;
    await _syncRtcParticipants();
  }

  Future<void> _confirmLeaveBroadcast() async {
    if (!mounted || _activeRoom == null) return;
    final isHost = _isHost;
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (dialogContext) {
        return AlertDialog(
          title: Text(isHost ? 'End broadcast?' : 'Leave room?'),
          content: Text(
            isHost
                ? 'Everyone will be disconnected. This cannot be undone.'
                : 'You can join again from the live list.',
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.of(dialogContext).pop(false),
              child: const Text('Cancel'),
            ),
            FilledButton(
              style: FilledButton.styleFrom(
                backgroundColor: _liveExitRed,
                foregroundColor: Colors.white,
              ),
              onPressed: () => Navigator.of(dialogContext).pop(true),
              child: Text(isHost ? 'End broadcast' : 'Leave'),
            ),
          ],
        );
      },
    );
    if (confirmed == true && mounted) {
      await _leaveBroadcast();
    }
  }

  Future<void> _leaveBroadcast() async {
    final room = _activeRoom;
    if (room == null) return;
    _recordRtcTransition('leave_broadcast start room=${room['id'] ?? ''}');
    final wasHost = _isHost;
    final commentCount = _comments.length;
    final peakListeners = _activeAudienceCount;
    final createdAt = room['createdAt'];
    final payload = await _socket.emitWithAckRetry(
      'live:broadcast:leave',
      <String, dynamic>{'broadcastId': room['id']},
      timeout: const Duration(seconds: 5),
      maxAttempts: 2,
    );
    await _liveAudioService.disconnect();
    await _disposeRtc();
    if (!mounted) return;
    setState(() {
      _activeRoom = null;
      _resetVideoRoomChromeSession();
      _lastShownNoticeId = null;
      _activeRoomVersion = 0;
      _activeSpeakerVersion = 0;
      _topologyReady = false;
      _comments = const [];
      _joinRequests = const [];
      _handRaised = false;
      _commentController.clear();
      _isFollowingHost = false;
      _followingHostBusy = false;
      _activeSpeakers.clear();
      _activeRoomMissingFromListCount = 0;
      _sfuConnected = false;
      _latestSpeakingSeqByUser.clear();
    });
    _syncRoomChromeState();
    _syncBrowseListRefreshTimer();
    unawaited(Helper.setSpeakerphoneOn(false));
    unawaited(_requestBroadcasts());
    if (payload is Map && payload['ended'] == true) {
      _removeBroadcastLocally('${room['id']}');
      if (wasHost) {
        await _showHostEndReport(
          payload: payload,
          commentCount: commentCount,
          peakListeners: peakListeners,
          createdAt: createdAt,
        );
      } else {
        await _showBroadcastEndedCard();
      }
    }
    _recordRtcTransition(
      'leave_broadcast done ended=${payload is Map && payload['ended'] == true}',
    );
  }

  Future<void> _showHostEndReport({
    required Map payload,
    required int commentCount,
    required int peakListeners,
    dynamic createdAt,
  }) async {
    if (!mounted) return;
    Duration? duration;
    if (createdAt is num && createdAt > 0) {
      final startMs = createdAt > 1e12
          ? createdAt.toInt()
          : createdAt.toInt() * 1000;
      duration = DateTime.now().difference(
        DateTime.fromMillisecondsSinceEpoch(startMs),
      );
    }
    final durationLabel = duration != null
        ? '${duration.inMinutes}m ${duration.inSeconds % 60}s'
        : '--';
    final serverPeak = payload['peakListeners'] as int? ?? peakListeners;

    await showDialog<void>(
      context: context,
      barrierDismissible: true,
      builder: (context) {
        final theme = Theme.of(context);
        return Dialog(
          insetPadding: const EdgeInsets.symmetric(horizontal: 28),
          shape: RoundedRectangleBorder(
            borderRadius: BorderRadius.circular(28),
          ),
          child: Padding(
            padding: const EdgeInsets.fromLTRB(24, 24, 24, 20),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                Icon(
                  Icons.bar_chart_rounded,
                  size: 34,
                  color: theme.colorScheme.primary,
                ),
                const SizedBox(height: 14),
                Text(
                  'Broadcast Report',
                  textAlign: TextAlign.center,
                  style: theme.textTheme.titleLarge?.copyWith(
                    fontWeight: FontWeight.w800,
                  ),
                ),
                const SizedBox(height: 18),
                _ReportStatRow(
                  icon: Icons.timer_outlined,
                  label: 'Duration',
                  value: durationLabel,
                ),
                const SizedBox(height: 10),
                _ReportStatRow(
                  icon: Icons.headset_outlined,
                  label: 'Peak audience',
                  value: compactCount(serverPeak),
                ),
                const SizedBox(height: 10),
                _ReportStatRow(
                  icon: Icons.chat_bubble_outline,
                  label: 'Comments',
                  value: compactCount(commentCount),
                ),
                const SizedBox(height: 22),
                FilledButton(
                  onPressed: () => Navigator.of(context).pop(),
                  style: FilledButton.styleFrom(
                    minimumSize: const Size.fromHeight(48),
                  ),
                  child: const Text('Done'),
                ),
              ],
            ),
          ),
        );
      },
    );
  }

  void _refreshBroadcasts() {
    setState(() => _loadingList = true);
    unawaited(_requestBroadcasts());
  }

  Future<void> _requestBroadcasts({bool showLoadingOnFailure = true}) async {
    final token = ++_broadcastRequestToken;
    final payload = await _socket.emitWithAckRetry(
      'live:broadcasts:get',
      null,
      timeout: const Duration(seconds: 3),
      maxAttempts: 2,
    );
    if (token != _broadcastRequestToken) return;
    if (payload is Map && payload['broadcasts'] is List) {
      _onBroadcastList(payload);
    } else if (mounted && showLoadingOnFailure) {
      setState(() => _loadingList = false);
    }
    Future<void>.delayed(const Duration(seconds: 4), () {
      if (!mounted || token != _broadcastRequestToken || !_loadingList) return;
      setState(() => _loadingList = false);
    });
  }

  void _sendComment() {
    final text = _commentController.text.trim();
    final me = ref.read(sessionControllerProvider).user;
    final room = _activeRoom;
    if (text.isEmpty || me == null || room == null || !_socket.isConnected) {
      return;
    }
    _commentController.clear();
    _socket.emit(
      'live:comment',
      <String, dynamic>{
        'broadcastId': room['id'],
        'text': text,
        'author': me.displayName,
        'userId': me.id,
        'photo': me.profilePhotoUrl,
        if (me.isProLike) 'commentTheme': _myCommentTheme,
      },
      ack: (dynamic payload) {
        if (payload is Map && payload['ok'] != true && mounted) {
          ScaffoldMessenger.of(context).showSnackBar(
            const SnackBar(content: Text('Unable to send comment')),
          );
        }
      },
    );
  }

  Future<void> _sendHostNotice(String text) async {
    final room = _activeRoom;
    final clean = text.trim();
    if (room == null || clean.isEmpty || !_isHost) return;
    final payload = await _socket.emitWithAckRetry(
      'live:notice:send',
      <String, dynamic>{'broadcastId': room['id'], 'text': clean},
      timeout: const Duration(seconds: 5),
      maxAttempts: 2,
    );
    if (!mounted) return;
    final ok = payload is Map && payload['ok'] == true;
    if (!ok) {
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text(
            payload is Map
                ? '${payload['message'] ?? 'Unable to send notice'}'
                : 'Notice request timed out.',
          ),
        ),
      );
      return;
    }
    ScaffoldMessenger.of(
      context,
    ).showSnackBar(const SnackBar(content: Text('Notice sent.')));
  }

  Future<bool> _saveHostJoinNotice(String text) async {
    final room = _activeRoom;
    final clean = text.trim();
    if (room == null || clean.isEmpty || !_isHost) return false;
    final payload = await _socket.emitWithAckRetry(
      'live:notice:save',
      <String, dynamic>{'broadcastId': room['id'], 'text': clean},
      timeout: const Duration(seconds: 5),
      maxAttempts: 2,
    );
    if (!mounted) return false;
    final ok = payload is Map && payload['ok'] == true;
    if (!ok) {
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text(
            payload is Map
                ? '${payload['message'] ?? 'Unable to save join notice'}'
                : 'Join notice request timed out.',
          ),
        ),
      );
      return false;
    }
    if (payload['broadcast'] is Map) {
      _applyActiveRoomUpdateFromPayload(
        Map<String, dynamic>.from(payload['broadcast'] as Map),
      );
    }
    ScaffoldMessenger.of(
      context,
    ).showSnackBar(const SnackBar(content: Text('Join notice saved.')));
    return true;
  }

  Future<bool> _deleteHostJoinNotice() async {
    final room = _activeRoom;
    if (room == null || !_isHost) return false;
    final payload = await _socket.emitWithAckRetry(
      'live:notice:delete',
      <String, dynamic>{'broadcastId': room['id']},
      timeout: const Duration(seconds: 5),
      maxAttempts: 2,
    );
    if (!mounted) return false;
    final ok = payload is Map && payload['ok'] == true;
    if (!ok) {
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text(
            payload is Map
                ? '${payload['message'] ?? 'Unable to delete join notice'}'
                : 'Join notice delete timed out.',
          ),
        ),
      );
      return false;
    }
    if (payload['broadcast'] is Map) {
      _applyActiveRoomUpdateFromPayload(
        Map<String, dynamic>.from(payload['broadcast'] as Map),
      );
    }
    ScaffoldMessenger.of(
      context,
    ).showSnackBar(const SnackBar(content: Text('Join notice deleted.')));
    return true;
  }

  Future<void> _createHostPoll({
    required String question,
    required List<String> options,
  }) async {
    final room = _activeRoom;
    final cleanQuestion = question.trim();
    final cleanOptions = options
        .map((option) => option.trim())
        .where((option) => option.isNotEmpty)
        .toList(growable: false);
    if (room == null ||
        !_isHost ||
        cleanQuestion.isEmpty ||
        cleanOptions.length < 2) {
      return;
    }
    final payload = await _socket.emitWithAckRetry(
      'live:poll:create',
      <String, dynamic>{
        'broadcastId': room['id'],
        'question': cleanQuestion,
        'options': cleanOptions,
      },
      timeout: const Duration(seconds: 5),
      maxAttempts: 2,
    );
    if (!mounted) return;
    final ok = payload is Map && payload['ok'] == true;
    if (!ok) {
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text(
            payload is Map
                ? '${payload['message'] ?? 'Unable to create poll'}'
                : 'Poll request timed out.',
          ),
        ),
      );
      return;
    }
    if (payload['poll'] is Map) {
      setState(() {
        _activePoll = Map<String, dynamic>.from(payload['poll'] as Map);
        _myPollVoteOptionId = null;
      });
      _syncPollClearTimer(_activePoll);
    }
  }

  Future<void> _voteInLivePoll(String optionId) async {
    final room = _activeRoom;
    final poll = _currentLivePoll;
    if (room == null ||
        poll == null ||
        _pollHasConcluded(poll) ||
        optionId.trim().isEmpty) {
      return;
    }
    final payload = await _socket.emitWithAckRetry(
      'live:poll:vote',
      <String, dynamic>{
        'broadcastId': room['id'],
        'pollId': poll['id'],
        'optionId': optionId,
      },
      timeout: const Duration(seconds: 5),
      maxAttempts: 2,
    );
    if (!mounted) return;
    final ok = payload is Map && payload['ok'] == true;
    if (!ok) {
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text(
            payload is Map
                ? '${payload['message'] ?? 'Unable to submit vote'}'
                : 'Vote request timed out.',
          ),
        ),
      );
      return;
    }
    setState(() {
      _myPollVoteOptionId = '${payload['selectedOptionId'] ?? optionId}';
      if (payload['poll'] is Map) {
        _activePoll = Map<String, dynamic>.from(payload['poll'] as Map);
      }
    });
    _syncPollClearTimer(_activePoll);
  }

  bool _pollHasConcluded(Map<String, dynamic> poll) {
    final status = '${poll['status'] ?? 'active'}'.trim().toLowerCase();
    if (status == 'concluded') return true;
    final endsAt = (poll['endsAt'] as num?)?.toInt() ?? 0;
    return endsAt > 0 && DateTime.now().millisecondsSinceEpoch >= endsAt;
  }

  Future<void> _copyLiveComment(String text) async {
    final cleaned = text.trim();
    if (cleaned.isEmpty) return;
    await Clipboard.setData(ClipboardData(text: cleaned));
    if (!mounted) return;
    ScaffoldMessenger.of(
      context,
    ).showSnackBar(const SnackBar(content: Text('Comment copied')));
  }

  Future<void> _translateLiveComment(String text) async {
    final cleaned = text.trim();
    if (cleaned.isEmpty) return;
    final targetLanguage =
        ref.read(sessionControllerProvider).user?.firstLanguage ?? _language;
    try {
      final data = await ref
          .read(apiClientProvider)
          .postJson(
            '/translations/text',
            body: <String, dynamic>{
              'text': cleaned,
              'targetLanguage': targetLanguage,
              'sourceLanguage': 'auto',
              'context': 'live_comment',
            },
          );
      if (!mounted) return;
      await _showLiveTranslationSheet(
        original: cleaned,
        translated: data['translation']?.toString().trim() ?? '',
        targetLanguage: targetLanguage,
        note: data['note']?.toString().trim() ?? '',
      );
    } on ApiException catch (error) {
      if (!mounted) return;
      ScaffoldMessenger.of(
        context,
      ).showSnackBar(SnackBar(content: Text(userFriendlyMessage(error))));
    }
  }

  Future<void> _showLiveTranslationSheet({
    required String original,
    required String translated,
    required String targetLanguage,
    required String note,
  }) async {
    await showModalBottomSheet<void>(
      context: context,
      isScrollControlled: true,
      backgroundColor: Colors.transparent,
      builder: (context) {
        final theme = Theme.of(context);
        final result = translated.trim();
        final info = note.trim().isNotEmpty
            ? note.trim()
            : 'Translated to ${targetLanguage.trim().isEmpty ? 'your language' : targetLanguage.trim()}.';
        return Padding(
          padding: const EdgeInsets.fromLTRB(16, 0, 16, 16),
          child: Container(
            decoration: BoxDecoration(
              color: theme.colorScheme.surface,
              borderRadius: BorderRadius.circular(24),
            ),
            child: SafeArea(
              top: false,
              child: Padding(
                padding: const EdgeInsets.fromLTRB(16, 14, 16, 18),
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      'Translation',
                      style: theme.textTheme.titleMedium?.copyWith(
                        fontWeight: FontWeight.w800,
                      ),
                    ),
                    const SizedBox(height: 12),
                    Text(
                      'Original',
                      style: theme.textTheme.labelLarge?.copyWith(
                        fontWeight: FontWeight.w700,
                      ),
                    ),
                    const SizedBox(height: 4),
                    Text(original),
                    const SizedBox(height: 12),
                    Text(
                      'Result',
                      style: theme.textTheme.labelLarge?.copyWith(
                        fontWeight: FontWeight.w700,
                      ),
                    ),
                    const SizedBox(height: 4),
                    SelectableText(
                      result.isEmpty
                          ? 'No translation result returned.'
                          : result,
                    ),
                    const SizedBox(height: 10),
                    Text(
                      info,
                      style: theme.textTheme.bodySmall?.copyWith(
                        color: theme.colorScheme.onSurfaceVariant,
                      ),
                    ),
                  ],
                ),
              ),
            ),
          ),
        );
      },
    );
  }

  Future<void> _openLiveCommentActions({
    required String author,
    required String text,
  }) async {
    final cleaned = text.trim();
    if (cleaned.isEmpty) return;
    await showModalBottomSheet<void>(
      context: context,
      backgroundColor: Colors.transparent,
      builder: (context) {
        final theme = Theme.of(context);
        return Padding(
          padding: const EdgeInsets.fromLTRB(16, 0, 16, 16),
          child: Container(
            decoration: BoxDecoration(
              color: theme.colorScheme.surface,
              borderRadius: BorderRadius.circular(24),
            ),
            child: SafeArea(
              top: false,
              child: Column(
                mainAxisSize: MainAxisSize.min,
                children: [
                  ListTile(
                    title: Text(
                      author.isEmpty ? 'Comment' : author,
                      style: theme.textTheme.titleMedium?.copyWith(
                        fontWeight: FontWeight.w700,
                      ),
                    ),
                    subtitle: Text(
                      cleaned,
                      maxLines: 2,
                      overflow: TextOverflow.ellipsis,
                    ),
                  ),
                  ListTile(
                    leading: const Icon(Icons.content_copy_rounded),
                    title: const Text('Copy'),
                    onTap: () async {
                      Navigator.of(context).pop();
                      await _copyLiveComment(cleaned);
                    },
                  ),
                  ListTile(
                    leading: const Icon(Icons.translate_rounded),
                    title: const Text('Translate'),
                    onTap: () async {
                      Navigator.of(context).pop();
                      await _translateLiveComment(cleaned);
                    },
                  ),
                  const SizedBox(height: 8),
                ],
              ),
            ),
          ),
        );
      },
    );
  }

  Future<void> _raiseHand() async {
    final me = ref.read(sessionControllerProvider).user;
    final room = _activeRoom;
    if (me == null || room == null || _handRaised || !_socket.isConnected) {
      return;
    }
    if (_roomUsesVideo && _videoLiveParticipants.length >= 4) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(
          content: Text('This video broadcast already has 4 live users.'),
        ),
      );
      return;
    }
    if (me.isProLike != true) {
      await showProAccessSheet(
        context: context,
        ref: ref,
        featureName: 'Speaker Access',
        onUnlocked: () {
          if (mounted) unawaited(_raiseHand());
        },
      );
      return;
    }
    final payload = await _socket.emitWithAckRetry(
      'live:raise-hand',
      <String, dynamic>{
        'broadcastId': room['id'],
        'name': me.displayName,
        'photo': me.profilePhotoUrl,
      },
      timeout: const Duration(seconds: 5),
      maxAttempts: 2,
    );
    if (!mounted) return;
    if (payload is Map && payload['ok'] == true) {
      setState(() => _handRaised = true);
      return;
    }
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(
        content: Text(
          payload is Map
              ? '${payload['message'] ?? 'Unable to request speaker access right now'}'
              : 'Speaker request timed out. Try again.',
        ),
      ),
    );
  }

  void _lowerHand() {
    final room = _activeRoom;
    if (room == null || !_handRaised || !_socket.isConnected) return;
    _socket.emit('live:lower-hand', <String, dynamic>{
      'broadcastId': room['id'],
    });
    setState(() => _handRaised = false);
  }

  Map<String, dynamic> _cloneRoomSnapshot(Map<String, dynamic> room) {
    return <String, dynamic>{
      ...room,
      'speakers': (room['speakers'] as List<dynamic>? ?? const [])
          .map<dynamic>(
            (item) => item is Map ? Map<String, dynamic>.from(item) : item,
          )
          .toList(growable: true),
      'audienceMembers': (room['audienceMembers'] as List<dynamic>? ?? const [])
          .whereType<Map>()
          .map((item) => Map<String, dynamic>.from(item))
          .toList(growable: true),
      'joinRequests': (room['joinRequests'] as List<dynamic>? ?? const [])
          .whereType<Map>()
          .map((item) => Map<String, dynamic>.from(item))
          .toList(growable: true),
      'activeNotice': room['activeNotice'] is Map
          ? Map<String, dynamic>.from(room['activeNotice'] as Map)
          : null,
      'activePoll': room['activePoll'] is Map
          ? Map<String, dynamic>.from(room['activePoll'] as Map)
          : null,
    };
  }

  bool _isUserOnStage(String userId) {
    if (userId.isEmpty) return false;
    final room = _activeRoom;
    if (room == null) return false;
    final hostUserId = _resolveHostUserId(room);
    if (hostUserId.isNotEmpty && userId == hostUserId) return true;
    final speakers = (room['speakers'] as List<dynamic>? ?? const []);
    return speakers.any(
      (item) => item is Map && '${item['userId'] ?? ''}' == userId,
    );
  }

  String? _stageSeatMicEffect(Map<String, dynamic>? seat) {
    if (seat == null) return null;
    final raw = '${seat['micEffect'] ?? ''}'.trim().toLowerCase();
    if (!_liveMicEffects.contains(raw)) return null;
    return raw;
  }

  Future<void> _refreshActiveRoomViaJoin() async {
    final room = _activeRoom;
    final me = ref.read(sessionControllerProvider).user;
    if (room == null || me == null || !_socket.isConnected) return;
    final payload = await _socket.emitWithAckRetry(
      'live:broadcast:join',
      <String, dynamic>{
        'broadcastId': room['id'],
        'name': me.displayName,
        'photo': me.profilePhotoUrl,
      },
      timeout: const Duration(seconds: 4),
      maxAttempts: 2,
    );
    if (payload is! Map || payload['ok'] != true || !mounted) return;
    final broadcast = _normalizeBroadcast(
      Map<String, dynamic>.from(payload['broadcast'] as Map? ?? room),
    );
    setState(() {
      _activeRoom = broadcast;
      _activeRoomVersion = _roomVersionFrom(broadcast);
      _activeSpeakerVersion = _speakerVersionFrom(broadcast);
      _refreshTopologyReady(broadcast);
      _syncLiveTransientStateFromRoom(broadcast);
      _joinRequests = (broadcast['joinRequests'] as List<dynamic>? ?? const [])
          .whereType<Map>()
          .map((item) => Map<String, dynamic>.from(item))
          .toList();
    });
    _syncRoomChromeState();
    _queueRtcSync();
    unawaited(_refreshHostFollowState(broadcast));
  }

  Future<bool> _acceptRequest(Map<String, dynamic> request) async {
    final room = _activeRoom;
    if (room == null || !_socket.isConnected) return false;
    final userId = _requestUserId(request);
    if (userId.isEmpty) return false;
    if (_roomUsesVideo && _videoLiveParticipants.length >= 4) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(
            content: Text('This video broadcast already has 4 live users.'),
          ),
        );
      }
      return false;
    }

    final payload = await _socket.emitWithAckRetry(
      'live:request:decision',
      <String, dynamic>{
        'broadcastId': room['id'],
        'userId': userId,
        'accept': true,
      },
      timeout: const Duration(seconds: 5),
      maxAttempts: 2,
    );
    final ok = payload is Map && payload['ok'] == true;
    if (!ok && mounted) {
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text(
            payload is Map
                ? '${payload['message'] ?? 'Unable to update request'}'
                : 'Request update timed out. Try again.',
          ),
        ),
      );
      return false;
    }
    if (ok) {
      final broadcast = _normalizeBroadcast(
        Map<String, dynamic>.from(payload['broadcast'] as Map? ?? room),
      );
      setState(() {
        _activeRoom = broadcast;
        _activeRoomVersion = _roomVersionFrom(broadcast);
        _activeSpeakerVersion = _speakerVersionFrom(broadcast);
        _refreshTopologyReady(broadcast);
        _syncLiveTransientStateFromRoom(broadcast);
        _joinRequests =
            (broadcast['joinRequests'] as List<dynamic>? ?? const [])
                .whereType<Map>()
                .map((item) => Map<String, dynamic>.from(item))
                .toList();
      });
      _syncRoomChromeState();
      _queueRtcSync(immediate: true);
    }
    return ok;
  }

  String _requestUserId(Map<String, dynamic> request) {
    final direct = '${request['userId'] ?? ''}';
    if (direct.isNotEmpty) return direct;
    final alt = '${request['requesterId'] ?? ''}';
    if (alt.isNotEmpty) return alt;
    final nested = request['user'];
    if (nested is Map) {
      final nestedId = '${nested['id'] ?? nested['userId'] ?? ''}';
      if (nestedId.isNotEmpty) return nestedId;
    }
    return '';
  }

  String _resolveHostUserId(Map<String, dynamic>? room) {
    if (room == null) return '';
    final direct = '${room['hostUserId'] ?? ''}'.trim();
    if (direct.isNotEmpty) return direct;
    final hostId = '${room['hostId'] ?? ''}'.trim();
    if (hostId.isNotEmpty) return hostId;
    final ownerId = '${room['ownerUserId'] ?? room['ownerId'] ?? ''}'.trim();
    if (ownerId.isNotEmpty) return ownerId;
    final createdBy = '${room['createdBy'] ?? room['createdByUserId'] ?? ''}'
        .trim();
    if (createdBy.isNotEmpty) return createdBy;
    final host = room['host'];
    if (host is Map) {
      final nested = '${host['userId'] ?? host['id'] ?? ''}'.trim();
      if (nested.isNotEmpty) return nested;
    }
    final speakers = (room['speakers'] as List<dynamic>? ?? const [])
        .whereType<Map>()
        .map((item) => Map<String, dynamic>.from(item));
    for (final speaker in speakers) {
      final role = '${speaker['role'] ?? ''}'.toLowerCase();
      final userId = '${speaker['userId'] ?? speaker['id'] ?? ''}'.trim();
      if (userId.isEmpty) continue;
      if (role.contains('host')) return userId;
    }
    for (final speaker in speakers) {
      final occupied = speaker['occupied'] != false;
      final userId = '${speaker['userId'] ?? speaker['id'] ?? ''}'.trim();
      if (occupied && userId.isNotEmpty) return userId;
    }
    return '';
  }

  String get _meId => ref.read(sessionControllerProvider).user?.id ?? '';
  LiveRoomState get _liveRoomState => ref.read(liveRoomControllerProvider);

  bool get _isHost {
    final roomHostUserId = _resolveHostUserId(_activeRoom);
    return _liveRoomState.role == LiveRoomRole.host || roomHostUserId == _meId;
  }

  List<Map<String, dynamic>?> get _stageSlots {
    final room = _activeRoom;
    if (room == null) return const <Map<String, dynamic>?>[];
    final resolvedHostUserId = _resolveHostUserId(room);
    final hostUserId = resolvedHostUserId.isNotEmpty
        ? resolvedHostUserId
        : (_isHost ? _meId : '');
    final hostName = '${room['host'] ?? 'Host'}';
    final hostPhoto = '${room['hostPhoto'] ?? ''}';

    final rawSpeakers = (room['speakers'] as List<dynamic>? ?? const [])
        .map(
          (item) => item is Map<String, dynamic>
              ? Map<String, dynamic>.from(item)
              : (item is Map ? Map<String, dynamic>.from(item) : null),
        )
        .toList();

    Map<String, dynamic>? hostFromSpeakers;
    if (hostUserId.isNotEmpty) {
      for (final speaker in rawSpeakers) {
        if (speaker != null && '${speaker['userId'] ?? ''}' == hostUserId) {
          hostFromSpeakers = speaker;
          break;
        }
      }
    }

    final normalizedHost = <String, dynamic>{
      'id': hostFromSpeakers?['id'] ?? 'host-$hostUserId',
      'userId': hostUserId.isNotEmpty
          ? hostUserId
          : '${hostFromSpeakers?['userId'] ?? ''}',
      'name': hostName.isNotEmpty
          ? hostName
          : '${hostFromSpeakers?['name'] ?? 'Host'}',
      'photo': hostPhoto.isNotEmpty
          ? hostPhoto
          : '${hostFromSpeakers?['photo'] ?? ''}',
      'role': 'Host',
      'occupied': true,
      'muted': hostFromSpeakers?['muted'] == true,
      if (_stageSeatMicEffect(hostFromSpeakers) != null)
        'micEffect': _stageSeatMicEffect(hostFromSpeakers)!,
    };

    final normalizedSpeakers = <Map<String, dynamic>?>[];
    for (final speaker in rawSpeakers) {
      if (speaker == null) {
        normalizedSpeakers.add(null);
        continue;
      }
      final speakerUserId = '${speaker['userId'] ?? ''}';
      if (hostUserId.isNotEmpty && speakerUserId == hostUserId) {
        continue;
      }
      normalizedSpeakers.add(Map<String, dynamic>.from(speaker));
    }
    while (normalizedSpeakers.length < 11) {
      normalizedSpeakers.add(null);
    }

    return <Map<String, dynamic>?>[
      normalizedHost,
      ...normalizedSpeakers.take(11),
    ];
  }

  List<Map<String, dynamic>> get _speakers =>
      _stageSlots.whereType<Map<String, dynamic>>().toList();

  List<Map<String, dynamic>> get _videoLiveParticipants {
    final room = _activeRoom;
    if (room == null) return const <Map<String, dynamic>>[];
    final hostUserId = _resolveHostUserId(room);
    final byUserId = <String, Map<String, dynamic>>{};

    void addParticipant(Map<String, dynamic> participant) {
      final userId = '${participant['userId'] ?? participant['id'] ?? ''}'
          .trim();
      if (userId.isEmpty || byUserId.containsKey(userId)) return;
      byUserId[userId] = Map<String, dynamic>.from(participant);
    }

    if (hostUserId.isNotEmpty) {
      final hostFromSpeakers = (room['speakers'] as List<dynamic>? ?? const [])
          .whereType<Map>()
          .map((item) => Map<String, dynamic>.from(item))
          .where(
            (item) => '${item['userId'] ?? item['id'] ?? ''}' == hostUserId,
          )
          .cast<Map<String, dynamic>?>()
          .firstWhere((_) => true, orElse: () => null);
      addParticipant(<String, dynamic>{
        ...?hostFromSpeakers,
        'id': hostFromSpeakers?['id'] ?? 'host-$hostUserId',
        'userId': hostUserId,
        'name': '${room['host'] ?? hostFromSpeakers?['name'] ?? 'Host'}',
        'photo': '${room['hostPhoto'] ?? hostFromSpeakers?['photo'] ?? ''}',
        'role': 'Host',
        'occupied': true,
      });
    }

    for (final speaker
        in (room['speakers'] as List<dynamic>? ?? const [])
            .whereType<Map>()
            .map((item) => Map<String, dynamic>.from(item))) {
      if (speaker['occupied'] == false) continue;
      addParticipant(speaker);
    }

    return byUserId.values.take(4).toList(growable: false);
  }

  Set<String> get _videoOnStageUserIds {
    return _videoLiveParticipants
        .map((p) => '${p['userId'] ?? p['id'] ?? ''}'.trim())
        .where((id) => id.isNotEmpty)
        .toSet();
  }

  bool _shouldReceiveVideoFrom(String peerUserId) {
    if (!_roomUsesVideo || peerUserId.isEmpty || peerUserId == _meId) {
      return false;
    }
    return _videoOnStageUserIds.contains(peerUserId);
  }

  bool get _amOnStage =>
      _isHost ||
      _speakers.any((speaker) => '${speaker['userId'] ?? ''}' == _meId);

  bool get _roomUsesVideo => (_activeRoom?['type'] ?? 'audio') == 'video';

  int get _pendingJoinRequestCount => _joinRequests.length;

  String get _pendingJoinRequestCountLabel {
    final count = _pendingJoinRequestCount;
    if (count > 99) return '99+';
    return '$count';
  }

  bool get _roomIsPrivate => _activeRoom?['isPrivate'] == true;

  String get _backgroundThemeName {
    final theme = '${_activeRoom?['backgroundTheme'] ?? 'gold'}'
        .trim()
        .toLowerCase();
    return _liveBackgroundThemes.contains(theme) ? theme : 'gold';
  }

  String get _micEffectName =>
      _liveMicEffects.contains(_myMicEffect) ? _myMicEffect : 'pulse';

  Map<String, dynamic>? get _currentLivePoll {
    if (_activePoll != null) return _activePoll;
    final roomPoll = _activeRoom?['activePoll'];
    return roomPoll is Map ? Map<String, dynamic>.from(roomPoll) : null;
  }

  void _syncLiveTransientStateFromRoom(Map<String, dynamic>? room) {
    if (room == null) {
      _cancelPollClearTimer();
      _activePoll = null;
      _myPollVoteOptionId = null;
      _lastShownNoticeId = null;
      return;
    }
    final poll = room['activePoll'];
    final previousPollId = '${_activePoll?['id'] ?? ''}';
    _activePoll = poll is Map ? Map<String, dynamic>.from(poll) : null;
    _syncPollClearTimer(_activePoll);
    final nextPollId = '${_activePoll?['id'] ?? ''}';
    if (nextPollId.isEmpty || nextPollId != previousPollId) {
      _myPollVoteOptionId = null;
    }
  }

  List<Map<String, dynamic>> get _moderators {
    return (_activeRoom?['moderators'] as List<dynamic>? ?? const [])
        .whereType<Map>()
        .map((item) => Map<String, dynamic>.from(item))
        .toList(growable: false);
  }

  Set<String> get _moderatorIds => _moderators
      .map((item) => '${item['userId'] ?? ''}')
      .where((id) => id.isNotEmpty)
      .toSet();

  List<Map<String, dynamic>> get _roomParticipantsForModeration {
    final room = _activeRoom;
    if (room == null) return const <Map<String, dynamic>>[];
    final hostUserId = _resolveHostUserId(room);
    final seen = <String>{};
    final participants = <Map<String, dynamic>>[];

    void addAll(List<dynamic> items, {required String fallbackRole}) {
      for (final raw in items.whereType<Map>()) {
        final item = Map<String, dynamic>.from(raw);
        final userId = '${item['userId'] ?? ''}'.trim();
        if (userId.isEmpty || userId == hostUserId || !seen.add(userId)) {
          continue;
        }
        item['roomRole'] = fallbackRole;
        participants.add(item);
      }
    }

    addAll(
      room['speakers'] as List<dynamic>? ?? const [],
      fallbackRole: 'speaker',
    );
    addAll(
      room['audienceMembers'] as List<dynamic>? ?? const [],
      fallbackRole: 'listener',
    );
    addAll(
      room['joinRequests'] as List<dynamic>? ?? const [],
      fallbackRole: 'requesting',
    );
    addAll(
      room['moderators'] as List<dynamic>? ?? const [],
      fallbackRole: 'moderator',
    );
    participants.sort((a, b) {
      final aName = '${a['name'] ?? ''}'.trim().toLowerCase();
      final bName = '${b['name'] ?? ''}'.trim().toLowerCase();
      return aName.compareTo(bName);
    });
    return participants;
  }

  double? _asDouble(dynamic value) {
    if (value is num) return value.toDouble();
    if (value is String) return double.tryParse(value);
    return null;
  }

  Future<bool> _detectLocalSpeaking() async {
    if (_usesSfuAudioPath && AppConfig.liveUseSfuSpeakingIndicator) {
      final activeSpeakerIds = _liveAudioService.activeSpeakerIds;
      if (mounted) {
        setState(() {
          _activeSpeakers
            ..removeWhere((userId) => _isUserOnStage(userId))
            ..addAll(activeSpeakerIds.where(_isUserOnStage));
        });
      }
      return _liveAudioService.isLocalParticipantSpeaking;
    }
    final connection = _peerConnections.values.isNotEmpty
        ? _peerConnections.values.first
        : null;
    if (connection == null) return false;
    try {
      final stats = await connection.getStats();
      var maxAudioLevel = 0.0;
      var voiceActivity = false;
      for (final report in stats) {
        final values = report.values;
        final reportType = report.type.toLowerCase();
        final mediaType = '${values['mediaType'] ?? values['kind'] ?? ''}'
            .toLowerCase();
        if (!reportType.contains('audio') &&
            !mediaType.contains('audio') &&
            reportType != 'media-source') {
          continue;
        }
        final voiceFlag = values['voiceActivityFlag'];
        if (voiceFlag == true || '$voiceFlag'.toLowerCase() == 'true') {
          voiceActivity = true;
        }
        final rawLevel = _asDouble(values['audioLevel'] ?? values['level']);
        if (rawLevel == null) continue;
        final normalized = rawLevel > 1 ? rawLevel / 32767 : rawLevel;
        maxAudioLevel = math.max(
          maxAudioLevel,
          normalized.clamp(0.0, 1.0).toDouble(),
        );
      }
      return voiceActivity || maxAudioLevel > 0.012;
    } catch (_) {
      return false;
    }
  }

  void _setLocalSpeaking(bool speaking) {
    if (_lastLocalSpeaking == speaking) return;
    _lastLocalSpeaking = speaking;
    if (mounted) {
      setState(() {
        if (speaking) {
          _activeSpeakers.add(_meId);
        } else {
          _activeSpeakers.remove(_meId);
        }
      });
    }
    _emitLocalSpeaking(speaking);
  }

  void _emitLocalSpeaking(bool speaking, {bool force = false}) {
    final room = _activeRoom;
    if (room == null || !_socket.isConnected) return;
    final now = DateTime.now();
    if (!force && _lastSpeakingEmitAt != null) {
      final elapsed = now.difference(_lastSpeakingEmitAt!);
      if (elapsed < _speakingEmitMinInterval) {
        _pendingSpeakingEmit = speaking;
        _speakingEmitTimer?.cancel();
        _speakingEmitTimer = Timer(_speakingEmitMinInterval - elapsed, () {
          final pending = _pendingSpeakingEmit;
          _pendingSpeakingEmit = null;
          _speakingEmitTimer = null;
          if (pending != null) {
            _emitLocalSpeaking(pending, force: true);
          }
        });
        return;
      }
    }
    _lastSpeakingEmitAt = now;
    _socket.emit('live:speaking', <String, dynamic>{
      'broadcastId': room['id'],
      'speaking': speaking,
    });
  }

  Future<void> _probeLocalSpeaking() async {
    if (_activeRoom == null || !_amOnStage || !_socket.isConnected) {
      _setLocalSpeaking(false);
      return;
    }
    if (!_localMicEnabled) {
      _setLocalSpeaking(false);
      return;
    }
    final detectedSpeaking = await _detectLocalSpeaking();
    if (detectedSpeaking) {
      _speakingPositiveSamples = (_speakingPositiveSamples + 1).clamp(0, 4);
      _speakingNegativeSamples = 0;
    } else {
      _speakingNegativeSamples = (_speakingNegativeSamples + 1).clamp(0, 4);
      _speakingPositiveSamples = 0;
    }
    final stabilizedSpeaking = _lastLocalSpeaking
        ? _speakingNegativeSamples < 3
        : _speakingPositiveSamples >= 1;
    _setLocalSpeaking(stabilizedSpeaking);
  }

  void _startSpeakingProbe() {
    if (_speakingProbeTimer != null) return;
    _speakingProbeTimer = Timer.periodic(_speakingProbeInterval, (_) {
      unawaited(_probeLocalSpeaking());
    });
    unawaited(_probeLocalSpeaking());
  }

  void _stopSpeakingProbe({required bool clearSpeaking}) {
    _speakingProbeTimer?.cancel();
    _speakingProbeTimer = null;
    _speakingPositiveSamples = 0;
    _speakingNegativeSamples = 0;
    if (clearSpeaking) {
      _setLocalSpeaking(false);
    }
  }

  void _queueRtcSync({bool immediate = false}) {
    if (immediate) {
      _rtcSyncDebounceTimer?.cancel();
      _rtcSyncDebounceTimer = null;
      unawaited(_syncRtcParticipants());
      return;
    }
    _rtcSyncDebounceTimer?.cancel();
    _rtcSyncDebounceTimer = Timer(_rtcSyncDebounceWindow, () {
      _rtcSyncDebounceTimer = null;
      unawaited(_syncRtcParticipants());
    });
  }

  void _syncSpeakingProbeLifecycle() {
    final shouldRun =
        _activeRoom != null &&
        _amOnStage &&
        _socket.isConnected &&
        _localMicEnabled;
    if (shouldRun) {
      _startSpeakingProbe();
    } else {
      _stopSpeakingProbe(clearSpeaking: true);
    }
  }

  void _syncStageMuteState() {
    final room = _activeRoom;
    if (room == null || !_socket.isConnected || !_amOnStage) return;
    _socket.emit('live:speaker:mute', <String, dynamic>{
      'broadcastId': room['id'],
      'muted': !_localMicEnabled,
    });
  }

  void _jumpToLatestImmersiveCommentNextFrame() {
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted || !_immersiveCommentsController.hasClients) return;
      _immersiveCommentsController.jumpTo(0);
    });
  }

  List<Map<String, dynamic>> get _audienceMembers =>
      ((_activeRoom?['audienceMembers'] as List<dynamic>?) ?? const [])
          .whereType<Map>()
          .map((item) => Map<String, dynamic>.from(item))
          .toList();

  int get _activeAudienceCount {
    final room = _activeRoom;
    final realAudienceCount = _audienceMembers.length;
    if (room == null) return realAudienceCount;
    final serverAudienceCount = (room['audienceCount'] as num?)?.toInt() ?? 0;
    final attendeeCount = (room['attendees'] as num?)?.toInt() ?? 0;
    final speakerCount = (room['speakers'] as List<dynamic>? ?? const [])
        .where((speaker) => speaker != null)
        .length;
    final audienceFromAttendees = math.max(0, attendeeCount - speakerCount);
    return math.max(
      realAudienceCount,
      math.max(serverAudienceCount, audienceFromAttendees),
    );
  }

  void _optimisticallyPromoteSelfToStage() {
    final room = _activeRoom;
    final me = ref.read(sessionControllerProvider).user;
    if (room == null || me == null) return;

    final speakers = (room['speakers'] as List<dynamic>? ?? const [])
        .map<dynamic>((item) => item)
        .toList(growable: true);
    while (speakers.length < 4) {
      speakers.add(null);
    }

    final alreadyOnStage = speakers.any(
      (item) => item is Map && '${item['userId'] ?? ''}' == _meId,
    );
    if (alreadyOnStage) return;

    final openIndex = speakers.indexWhere((item) => item == null);
    if (openIndex <= 0) return;

    speakers[openIndex] = <String, dynamic>{
      'id': 'speaker-${me.id}',
      'userId': me.id,
      'name': me.displayName,
      'photo': me.profilePhotoUrl,
      'role': 'Speaker',
      'occupied': true,
      'muted': !_localMicEnabled,
      'micEffect': _micEffectName,
    };

    final audience = (room['audienceMembers'] as List<dynamic>? ?? const [])
        .whereType<Map>()
        .map((item) => Map<String, dynamic>.from(item))
        .where((member) => '${member['userId'] ?? ''}' != _meId)
        .toList();

    _activeRoom = {...room, 'speakers': speakers, 'audienceMembers': audience};
  }

  List<String> get _rtcTargetPeerIds {
    final room = _activeRoom;
    final ids = <String>{};
    if (room != null) {
      final rawSpeakers = (room['speakers'] as List<dynamic>? ?? const [])
          .whereType<Map>()
          .map((item) => Map<String, dynamic>.from(item));
      for (final speaker in rawSpeakers) {
        final occupied = speaker['occupied'] != false;
        final userId = '${speaker['userId'] ?? speaker['id'] ?? ''}'.trim();
        if (!occupied || userId.isEmpty || userId == _meId) continue;
        ids.add(userId);
      }
      // Mesh host must keep links to the audience so listeners can receive
      // outbound media (listeners always offer; host answers).
      if (!_usesSfuAudioPath && _isHost) {
        for (final member
            in (room['audienceMembers'] as List<dynamic>? ?? const [])) {
          if (member is! Map) continue;
          final userId = '${member['userId'] ?? member['id'] ?? ''}'.trim();
          if (userId.isEmpty || userId == _meId) continue;
          ids.add(userId);
        }
      }
    }
    final hostUserId = _resolveHostUserId(room);
    if (hostUserId.isNotEmpty && hostUserId != _meId) {
      ids.add(hostUserId);
    }
    return ids.toList();
  }

  String _meshPeerMediaSignature(
    String peerUserId, {
    required bool shouldSendAudio,
  }) {
    if (!_roomUsesVideo) {
      return 'a:${shouldSendAudio ? 1 : 0}';
    }
    final shouldSendVideo = _amOnStage && _localVideoEnabled;
    final shouldReceiveVideo = _shouldReceiveVideoFrom(peerUserId);
    return 'a:${shouldSendAudio ? 1 : 0},vs:${shouldSendVideo ? 1 : 0},vr:${shouldReceiveVideo ? 1 : 0}';
  }

  TransceiverDirection _videoTransceiverDirection({
    required bool shouldSendVideo,
    required bool shouldReceiveVideo,
  }) {
    if (shouldSendVideo && shouldReceiveVideo) {
      return TransceiverDirection.SendRecv;
    }
    if (shouldSendVideo) return TransceiverDirection.SendOnly;
    if (shouldReceiveVideo) return TransceiverDirection.RecvOnly;
    return TransceiverDirection.Inactive;
  }

  Future<void> _pruneOffStageVideoRenderers() async {
    if (!_roomUsesVideo) return;
    final onStage = _videoOnStageUserIds;
    var changed = false;
    for (final userId in _remoteRenderers.keys.toList()) {
      if (onStage.contains(userId)) continue;
      final renderer = _remoteRenderers.remove(userId);
      try {
        renderer?.srcObject = null;
        await renderer?.dispose();
      } catch (_) {}
      changed = true;
    }
    if (changed && mounted) setState(() {});
  }

  void _bindRemoteTrackLifecycle(String peerUserId, MediaStreamTrack track) {
    track.onEnded = () {
      if (!mounted) return;
      if (track.kind == 'video') {
        final renderer = _remoteRenderers[peerUserId];
        if (renderer != null) {
          renderer.srcObject = null;
          setState(() {});
        }
      }
    };
  }

  Future<void> _ensureLocalStageStream() async {
    if (!_amOnStage) return;
    if (_usesSfuAudioPath && _roomUsesVideo) {
      await _refreshLiveAudioPublishState();
      if (mounted) setState(() {});
      return;
    }
    if (_roomUsesVideo) {
      await _ensureLocalRendererReady();
    }
    final stream =
        ref.read(webRtcServiceProvider).localStream ??
        await ref
            .read(webRtcServiceProvider)
            .createLocalStream(audio: true, video: _roomUsesVideo);
    // Some devices can initialize the first stage stream with disabled mic.
    // Force-enable once to prevent silent host/speaker publish on join.
    for (final track in stream.getAudioTracks()) {
      if (!_didInitializeStageMic) {
        track.enabled = true;
      } else {
        track.enabled = _localMicEnabled;
      }
    }
    _didInitializeStageMic = true;
    _localRenderer?.srcObject = stream;
    _localMicEnabled = stream.getAudioTracks().any((track) => track.enabled);
    _localVideoEnabled = stream.getVideoTracks().any((track) => track.enabled);
    _syncStageMuteState();
    if (mounted) setState(() {});
    if (_roomUsesVideo) {
      unawaited(_syncHostHeroVideo());
    }
  }

  Future<void> _disposeLocalStageStream() async {
    if (_usesSfuAudioPath && _roomUsesVideo) {
      await _refreshLiveAudioPublishState();
      return;
    }
    _localRenderer?.srcObject = null;
    _localMicEnabled = true;
    _localVideoEnabled = false;
    _didInitializeStageMic = false;
    _wasOnStage = false;
    _stopSpeakingProbe(clearSpeaking: true);
    await ref.read(webRtcServiceProvider).disposeLocalStream();
  }

  /// Mesh WebRTC for **video** broadcasts only: explicit audio + video transceivers
  /// so listeners receive remote video and stage can publish without relying on
  /// implicit negotiation alone.
  Future<void> _ensureVideoBroadcastMeshPeerMedia(
    RTCPeerConnection connection, {
    required bool shouldSendAudio,
    required bool shouldReceiveVideo,
  }) async {
    final shouldSendVideo = _amOnStage && _localVideoEnabled;
    final videoDirection = _videoTransceiverDirection(
      shouldSendVideo: shouldSendVideo,
      shouldReceiveVideo: shouldReceiveVideo,
    );
    final transceivers = await connection.getTransceivers();

    RTCRtpTransceiver? audioTransceiver;
    for (final transceiver in transceivers) {
      if (transceiver.sender.track?.kind == 'audio' ||
          transceiver.receiver.track?.kind == 'audio') {
        audioTransceiver = transceiver;
        break;
      }
    }
    if (audioTransceiver == null) {
      audioTransceiver = await connection.addTransceiver(
        kind: RTCRtpMediaType.RTCRtpMediaTypeAudio,
        init: RTCRtpTransceiverInit(
          direction: shouldSendAudio
              ? TransceiverDirection.SendRecv
              : TransceiverDirection.RecvOnly,
        ),
      );
    } else {
      await audioTransceiver.setDirection(
        shouldSendAudio
            ? TransceiverDirection.SendRecv
            : TransceiverDirection.RecvOnly,
      );
    }

    final audioSender = audioTransceiver.sender;
    if (shouldSendAudio) {
      final stream =
          ref.read(webRtcServiceProvider).localStream ??
          await ref
              .read(webRtcServiceProvider)
              .createLocalStream(audio: true, video: true);
      final tracks = stream.getAudioTracks();
      if (tracks.isEmpty) return;
      final track = tracks.first;
      if (audioSender.track?.id != track.id) {
        await audioSender.replaceTrack(track);
      }
    } else if (audioSender.track != null) {
      await audioSender.replaceTrack(null);
    }

    final transceiversAfterAudio = await connection.getTransceivers();
    RTCRtpTransceiver? videoTransceiver;
    for (final transceiver in transceiversAfterAudio) {
      if (transceiver.sender.track?.kind == 'video' ||
          transceiver.receiver.track?.kind == 'video') {
        videoTransceiver = transceiver;
        break;
      }
    }
    if (videoTransceiver == null) {
      videoTransceiver = await connection.addTransceiver(
        kind: RTCRtpMediaType.RTCRtpMediaTypeVideo,
        init: RTCRtpTransceiverInit(direction: videoDirection),
      );
    } else {
      await videoTransceiver.setDirection(videoDirection);
    }

    final videoSender = videoTransceiver.sender;
    if (shouldSendVideo) {
      final stream = ref.read(webRtcServiceProvider).localStream;
      final videoTracks =
          stream?.getVideoTracks() ?? const <MediaStreamTrack>[];
      if (videoTracks.isEmpty) return;
      final vtrack = videoTracks.first;
      if (videoSender.track?.id != vtrack.id) {
        await videoSender.replaceTrack(vtrack);
      }
    } else if (videoSender.track != null) {
      await videoSender.replaceTrack(null);
    }
  }

  Future<void> _ensureAudioPeerMode(
    RTCPeerConnection connection, {
    required String peerUserId,
    required bool shouldSendAudio,
  }) async {
    if (_roomUsesVideo) {
      await _ensureVideoBroadcastMeshPeerMedia(
        connection,
        shouldSendAudio: shouldSendAudio,
        shouldReceiveVideo: _shouldReceiveVideoFrom(peerUserId),
      );
      return;
    }
    final transceivers = await connection.getTransceivers();
    RTCRtpTransceiver? audioTransceiver;
    for (final transceiver in transceivers) {
      if (transceiver.sender.track?.kind == 'audio' ||
          transceiver.receiver.track?.kind == 'audio') {
        audioTransceiver = transceiver;
        break;
      }
    }

    if (audioTransceiver == null) {
      audioTransceiver = await connection.addTransceiver(
        kind: RTCRtpMediaType.RTCRtpMediaTypeAudio,
        init: RTCRtpTransceiverInit(
          direction: shouldSendAudio
              ? TransceiverDirection.SendRecv
              : TransceiverDirection.RecvOnly,
        ),
      );
    } else {
      await audioTransceiver.setDirection(
        shouldSendAudio
            ? TransceiverDirection.SendRecv
            : TransceiverDirection.RecvOnly,
      );
    }

    final audioSender = audioTransceiver.sender;
    if (shouldSendAudio) {
      final stream =
          ref.read(webRtcServiceProvider).localStream ??
          await ref
              .read(webRtcServiceProvider)
              .createLocalStream(audio: true, video: false);
      final tracks = stream.getAudioTracks();
      if (tracks.isEmpty) return;
      final track = tracks.first;
      if (audioSender.track?.id != track.id) {
        await audioSender.replaceTrack(track);
      }
    } else if (audioSender.track != null) {
      await audioSender.replaceTrack(null);
    }
  }

  Future<RTCVideoRenderer> _ensureRemoteRenderer(String userId) async {
    final existing = _remoteRenderers[userId];
    if (existing != null) return existing;
    final renderer = RTCVideoRenderer();
    await renderer.initialize();
    _remoteRenderers[userId] = renderer;
    return renderer;
  }

  void _clearPeerReconnect(String peerUserId) {
    _peerReconnectTimers.remove(peerUserId)?.cancel();
    _peerReconnectAttempts.remove(peerUserId);
  }

  void _schedulePeerReconnect(String peerUserId) {
    if (!_roomUsesVideo || _activeRoom == null || peerUserId.isEmpty) return;
    if (!_rtcTargetPeerIds.contains(peerUserId)) return;
    if (_peerReconnectTimers.containsKey(peerUserId)) return;
    final attempts = (_peerReconnectAttempts[peerUserId] ?? 0) + 1;
    _peerReconnectAttempts[peerUserId] = attempts;
    final delaySeconds = math.min(8, math.max(1, attempts * 2));
    _peerReconnectTimers[peerUserId] = Timer(
      Duration(seconds: delaySeconds),
      () {
        _peerReconnectTimers.remove(peerUserId);
        if (!mounted || _activeRoom == null || !_roomUsesVideo) return;
        if (!_rtcTargetPeerIds.contains(peerUserId)) {
          _peerReconnectAttempts.remove(peerUserId);
          _peerStates.remove(peerUserId);
          if (mounted) setState(() {});
          return;
        }
        _recordRtcTransition(
          'rtc_peer_reconnect peer=$peerUserId attempt=$attempts',
        );
        _queueRtcSync(immediate: true);
      },
    );
    if (mounted) setState(() {});
  }

  Future<RTCPeerConnection> _ensurePeerConnection(String peerUserId) async {
    final existing = _peerConnections[peerUserId];
    if (existing != null) return existing;

    final connection = await createPeerConnection(
      AppConfig.rtcPeerConnectionConfig,
    );

    connection.onIceCandidate = (candidate) {
      final room = _activeRoom;
      if (room == null || candidate.candidate == null) return;
      _socket.emit('live:rtc:ice', <String, dynamic>{
        'broadcastId': room['id'],
        'toUserId': peerUserId,
        'candidate': candidate.toMap(),
      });
    };

    connection.onTrack = (event) async {
      if (!mounted) return;
      if (!_peerConnections.containsKey(peerUserId)) return;
      _bindRemoteTrackLifecycle(peerUserId, event.track);
      if (event.track.kind == 'video') {
        if (!_shouldReceiveVideoFrom(peerUserId)) {
          if (mounted) setState(() {});
          return;
        }
        final renderer = await _ensureRemoteRenderer(peerUserId);
        if (event.streams.isNotEmpty) {
          renderer.srcObject = event.streams.first;
        } else {
          final fallbackStream = await createLocalMediaStream(
            'remote-$peerUserId-${DateTime.now().millisecondsSinceEpoch}',
          );
          await fallbackStream.addTrack(event.track);
          renderer.srcObject = fallbackStream;
        }
        if (mounted) setState(() {});
        unawaited(_syncHostHeroVideo());
        return;
      }
      if (event.track.kind == 'audio') {
        _markInboundAudioDetected();
      }
      if (mounted) setState(() {});
    };

    connection.onConnectionState = (state) {
      if (!mounted) return;
      _peerStates[peerUserId] = _describeConnectionState(state);
      if (state == RTCPeerConnectionState.RTCPeerConnectionStateConnected) {
        _clearPeerReconnect(peerUserId);
      }
      setState(() {});
      if (state == RTCPeerConnectionState.RTCPeerConnectionStateDisconnected) {
        _schedulePeerReconnect(peerUserId);
      } else if (state == RTCPeerConnectionState.RTCPeerConnectionStateFailed) {
        _schedulePeerReconnect(peerUserId);
        unawaited(_removePeer(peerUserId, keepReconnectTimer: true));
      } else if (state == RTCPeerConnectionState.RTCPeerConnectionStateClosed) {
        unawaited(_removePeer(peerUserId));
      }
    };

    _peerConnections[peerUserId] = connection;
    return connection;
  }

  Future<void> _sendOffer(String peerUserId) async {
    final room = _activeRoom;
    if (room == null) return;
    final connection = await _ensurePeerConnection(peerUserId);
    final shouldSendAudio = _amOnStage;
    await _ensureAudioPeerMode(
      connection,
      peerUserId: peerUserId,
      shouldSendAudio: shouldSendAudio,
    );
    _peerMeshMediaSignatures[peerUserId] = _meshPeerMediaSignature(
      peerUserId,
      shouldSendAudio: shouldSendAudio,
    );
    final offer = await connection.createOffer(<String, dynamic>{
      'offerToReceiveAudio': true,
      'offerToReceiveVideo': _shouldReceiveVideoFrom(peerUserId),
    });
    await connection.setLocalDescription(offer);
    _socket.emit('live:rtc:offer', <String, dynamic>{
      'broadcastId': room['id'],
      'toUserId': peerUserId,
      'sdp': offer.toMap(),
    });
  }

  Future<void> _flushPendingIce(String peerUserId) async {
    final connection = _peerConnections[peerUserId];
    if (connection == null) return;
    final pending = _pendingIce[peerUserId];
    if (pending == null || pending.isEmpty) return;
    while (pending.isNotEmpty) {
      await connection.addCandidate(pending.removeAt(0));
    }
  }

  Future<void> _syncRtcParticipants() async {
    if (_usesSfuAudioPath) {
      await _refreshLiveAudioPublishState();
      return;
    }
    if (_syncingRtc) {
      _syncRtcPending = true;
      _recordRtcTransition('rtc_sync queued');
      return;
    }
    _recordRtcTransition('rtc_sync start');
    _syncingRtc = true;
    try {
      await _doSyncRtcParticipants();
    } finally {
      _syncingRtc = false;
      if (_syncRtcPending) {
        _syncRtcPending = false;
        _recordRtcTransition('rtc_sync drain_pending');
        unawaited(_syncRtcParticipants());
      }
    }
  }

  /// Mesh listeners need `hostUserId` / speakers in `_activeRoom` before
  /// `_rtcTargetPeerIds` is non-empty. Merge from the cached list or re-join
  /// once before giving up on this sync.
  Future<void> _hydrateMeshTopologyForOffStageListener() async {
    if (_usesSfuAudioPath || _activeRoom == null || _amOnStage) return;
    if (_rtcTargetPeerIds.isNotEmpty) return;
    if (_enrichActiveRoomFromBroadcasts()) {
      _refreshTopologyReady(_activeRoom);
    }
    if (_rtcTargetPeerIds.isNotEmpty) return;
    await _refreshActiveRoomViaJoin();
  }

  Future<void> _doSyncRtcParticipants() async {
    final room = _activeRoom;
    if (room == null || !mounted) return;
    _refreshTopologyReady(room);
    final onStageNow = _amOnStage;
    final transitionedToStage = onStageNow && !_wasOnStage;
    _recordRtcTransition(
      'rtc_sync_apply stage=$onStageNow transitioned=$transitionedToStage peers=${_peerConnections.length}',
    );

    if (onStageNow) {
      if (transitionedToStage) {
        await _bootstrapMicOnStageJoin();
      }
      await _ensureLocalStageStream();
    } else {
      await _disposeLocalStageStream();
    }

    if (!onStageNow && !_usesSfuAudioPath) {
      await _hydrateMeshTopologyForOffStageListener();
    }

    final peerIds = _rtcTargetPeerIds;
    _recordRtcTransition('rtc_targets count=${peerIds.length}');
    if (!onStageNow && !_topologyReady && peerIds.isEmpty) {
      _recordRtcTransition('rtc_sync blocked topology_not_ready');
      _syncSpeakingProbeLifecycle();
      _wasOnStage = onStageNow;
      if (mounted) setState(() {});
      if (_roomUsesVideo) {
        await _pruneOffStageVideoRenderers();
        unawaited(_syncHostHeroVideo());
      }
      return;
    }
    final existingIds = _peerConnections.keys.toList();
    for (final userId in existingIds) {
      if (!peerIds.contains(userId)) {
        await _removePeer(userId);
      }
    }

    final speakerVersion = _activeSpeakerVersion;
    final speakersChanged = speakerVersion != _rtcSyncedSpeakerVersion;

    for (final peerUserId in peerIds) {
      if (!mounted || _activeRoom == null) return;
      final hadConnection = _peerConnections.containsKey(peerUserId);
      final connection = await _ensurePeerConnection(peerUserId);
      final shouldSendAudio = _amOnStage;
      await _ensureAudioPeerMode(
        connection,
        peerUserId: peerUserId,
        shouldSendAudio: shouldSendAudio,
      );
      final signature = _meshPeerMediaSignature(
        peerUserId,
        shouldSendAudio: shouldSendAudio,
      );
      final priorSignature = _peerMeshMediaSignatures[peerUserId];
      _peerMeshMediaSignatures[peerUserId] = signature;
      final shouldOffer = !_amOnStage || _meId.compareTo(peerUserId) < 0;
      if (!shouldOffer) continue;
      final negotiated =
          hadConnection && _remoteDescriptionReady.contains(peerUserId);
      final mediaChanged =
          negotiated && priorSignature != null && priorSignature != signature;
      final needsOffer =
          !negotiated ||
          mediaChanged ||
          transitionedToStage ||
          (speakersChanged && negotiated);
      if (needsOffer) {
        await _sendOffer(peerUserId);
      }
    }
    _rtcSyncedSpeakerVersion = speakerVersion;

    _syncSpeakingProbeLifecycle();
    if (_shouldMonitorListenerAudio) {
      _startAudioRecoveryMonitor();
    } else {
      _stopAudioRecoveryMonitor();
    }
    _wasOnStage = onStageNow;
    if (_roomUsesVideo) {
      await _pruneOffStageVideoRenderers();
      unawaited(_syncHostHeroVideo());
    }
    if (mounted) setState(() {});
  }

  Future<void> _bootstrapMicOnStageJoin() async {
    _localMicEnabled = true;
    final stream =
        ref.read(webRtcServiceProvider).localStream ??
        await ref
            .read(webRtcServiceProvider)
            .createLocalStream(audio: true, video: _roomUsesVideo);
    for (final track in stream.getAudioTracks()) {
      track.enabled = true;
    }
    if (mounted) {
      setState(() {
        _applySpeakerMuteStateLocally(
          userId: _meId,
          muted: false,
          mirrorToSelfMic: true,
        );
      });
    }
  }

  Future<void> _removePeer(
    String peerUserId, {
    bool keepReconnectTimer = false,
  }) async {
    if (!keepReconnectTimer) {
      _peerReconnectTimers.remove(peerUserId)?.cancel();
      _peerReconnectAttempts.remove(peerUserId);
    }
    _remoteDescriptionReady.remove(peerUserId);
    _peerMeshMediaSignatures.remove(peerUserId);
    _pendingIce.remove(peerUserId);
    if (keepReconnectTimer) {
      _peerStates[peerUserId] = 'reconnecting';
    } else {
      _peerStates.remove(peerUserId);
    }
    final connection = _peerConnections.remove(peerUserId);
    final renderer = _remoteRenderers.remove(peerUserId);
    try {
      await connection?.close();
    } catch (_) {}
    try {
      renderer?.srcObject = null;
      await renderer?.dispose();
    } catch (_) {}
    if (mounted) setState(() {});
  }

  Future<void> _disposeRtc() async {
    for (final timer in _peerReconnectTimers.values) {
      timer.cancel();
    }
    _peerReconnectTimers.clear();
    _peerReconnectAttempts.clear();
    await _disposeHostHeroRenderer();
    final peerIds = _peerConnections.keys.toList();
    for (final peerUserId in peerIds) {
      await _removePeer(peerUserId);
    }
    _peerMeshMediaSignatures.clear();
    _rtcSyncedSpeakerVersion = 0;
    await _disposeLocalStageStream();
    _stopAudioRecoveryMonitor();
    for (final timer in _speakingDecayTimers.values) {
      timer.cancel();
    }
    _speakingDecayTimers.clear();
    _activeSpeakers.clear();
    if (mounted) setState(() {});
  }

  bool get _shouldMonitorListenerAudio {
    return _activeRoom != null &&
        !_usesSfuAudioPath &&
        !_amOnStage &&
        _socketStatus == 'connected';
  }

  void _markInboundAudioDetected() {
    _lastInboundAudioAt = DateTime.now();
    _audioRecoveryAttempts = 0;
  }

  void _startAudioRecoveryMonitor() {
    if (_audioRecoveryTimer != null) return;
    _audioRecoveryTimer = Timer.periodic(const Duration(seconds: 8), (_) {
      if (!_shouldMonitorListenerAudio) return;
      final now = DateTime.now();
      final lastInbound = _lastInboundAudioAt;
      if (lastInbound != null &&
          now.difference(lastInbound) < const Duration(seconds: 10)) {
        return;
      }
      if (_audioRecoveryAttempts >= 3) return;
      _audioRecoveryAttempts += 1;
      unawaited(_attemptListenerAudioRecovery());
    });
  }

  void _stopAudioRecoveryMonitor() {
    _audioRecoveryTimer?.cancel();
    _audioRecoveryTimer = null;
    _audioRecoveryAttempts = 0;
    _lastInboundAudioAt = null;
  }

  Future<void> _attemptListenerAudioRecovery() async {
    if (!_shouldMonitorListenerAudio) return;
    _recordRtcTransition('audio_recovery attempt=$_audioRecoveryAttempts');
    if (!_topologyReady) {
      await _requestBroadcasts();
    }
    if (_peerConnections.isEmpty) {
      await _refreshActiveRoomViaJoin();
      _enrichActiveRoomFromBroadcasts();
      _refreshTopologyReady();
    }
    _queueRtcSync();
    final targetPeers = _rtcTargetPeerIds;
    for (final peerUserId in targetPeers) {
      if (!_peerConnections.containsKey(peerUserId)) continue;
      try {
        await _sendOffer(peerUserId);
      } catch (_) {}
    }
    if (mounted && _audioRecoveryAttempts == 1) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(
          content: Text('Recovering room audio...'),
          duration: Duration(seconds: 2),
        ),
      );
    }
  }

  Future<void> _toggleStageMute() async {
    if (_usesSfuAudioPath) {
      if (!_canUseStageMic) {
        if (mounted) {
          ScaffoldMessenger.of(context).showSnackBar(
            const SnackBar(
              content: Text(
                'Room audio is reconnecting. Try again in a moment.',
              ),
            ),
          );
        }
        return;
      }
      final desiredEnabled = !_localMicEnabled;
      if (desiredEnabled) {
        final allowed = await _permissionService.ensureMicrophone();
        if (!allowed) {
          if (!mounted) return;
          ScaffoldMessenger.of(context).showSnackBar(
            const SnackBar(
              content: Text('Microphone access is required to speak.'),
            ),
          );
          return;
        }
      }
      await _liveAudioService.setMicEnabled(desiredEnabled);
      _localMicEnabled = desiredEnabled;
      if (mounted) {
        setState(() {
          _applySpeakerMuteStateLocally(
            userId: _meId,
            muted: !_localMicEnabled,
          );
        });
      }
      _syncRoomChromeState();
      _syncStageMuteState();
      _syncSpeakingProbeLifecycle();
      return;
    }
    final stream = ref.read(webRtcServiceProvider).localStream;
    if (stream == null) return;
    final desiredEnabled = !_localMicEnabled;
    try {
      for (final track in stream.getAudioTracks()) {
        track.enabled = desiredEnabled;
      }
      _localMicEnabled = stream.getAudioTracks().any((track) => track.enabled);
    } catch (_) {
      // Native track may be invalid (e.g. iOS simulator). Update state
      // optimistically so the UI and socket stay in sync.
      _localMicEnabled = desiredEnabled;
    }
    if (mounted) {
      setState(() {
        _applySpeakerMuteStateLocally(userId: _meId, muted: !_localMicEnabled);
      });
    }
    _syncRoomChromeState();
    _syncStageMuteState();
    _syncSpeakingProbeLifecycle();
  }

  Future<void> _toggleStageCamera() async {
    if (_usesSfuAudioPath && _roomUsesVideo) {
      final next = !_localVideoEnabled;
      await _liveAudioService.setCameraEnabled(next);
      _localVideoEnabled = _liveAudioService.isLocalCameraEnabled;
      if (mounted) setState(() {});
      return;
    }
    final stream = ref.read(webRtcServiceProvider).localStream;
    if (stream == null || stream.getVideoTracks().isEmpty) return;
    for (final track in stream.getVideoTracks()) {
      track.enabled = !track.enabled;
      _localVideoEnabled = track.enabled;
    }
    if (mounted) setState(() {});
    if (_roomUsesVideo) {
      unawaited(_syncHostHeroVideo());
      if (_amOnStage) {
        _queueRtcSync(immediate: true);
      }
    }
  }

  Future<void> _switchStageCamera() async {
    if (_usesSfuAudioPath && _roomUsesVideo) {
      final switched = await _liveAudioService.switchCamera();
      if (switched && mounted) setState(() {});
      return;
    }
    final switched = await ref.read(webRtcServiceProvider).switchCamera();
    if (switched && mounted) {
      setState(() {});
      if (_roomUsesVideo) {
        unawaited(_syncHostHeroVideo());
      }
    }
  }

  void _optimisticallyLeaveStageSelf() {
    final room = _activeRoom;
    if (room == null) return;
    final nextSpeakers = (room['speakers'] as List<dynamic>? ?? const [])
        .map<dynamic>((item) {
          if (item is! Map) return item;
          final map = Map<String, dynamic>.from(item);
          return '${map['userId'] ?? ''}' == _meId ? null : map;
        })
        .toList(growable: true);
    final nextAudience = [
      ...(room['audienceMembers'] as List<dynamic>? ?? const []),
    ];
    final alreadyInAudience = nextAudience.any(
      (item) => item is Map && '${item['userId'] ?? ''}' == _meId,
    );
    if (!alreadyInAudience) {
      final me = ref.read(sessionControllerProvider).user;
      if (me != null) {
        nextAudience.add(<String, dynamic>{
          'id': 'audience-${me.id}',
          'userId': me.id,
          'name': me.displayName,
          'photo': me.profilePhotoUrl,
        });
      }
    }
    _activeRoom = {
      ...room,
      'speakers': nextSpeakers,
      'audienceMembers': nextAudience,
    };
  }

  Future<void> _leaveStage() async {
    final room = _activeRoom;
    if (room == null || _isHost || !_amOnStage) return;
    _setLocalSpeaking(false);
    final previousRoom = _cloneRoomSnapshot(room);
    setState(() {
      _optimisticallyLeaveStageSelf();
    });
    if (_usesSfuAudioPath) {
      await _refreshLiveAudioPublishState();
    } else {
      _queueRtcSync(immediate: true);
    }
    final payload = await _socket.emitWithAckRetry(
      'live:speaker:leave-stage',
      <String, dynamic>{'broadcastId': room['id']},
      timeout: const Duration(seconds: 5),
      maxAttempts: 2,
    );
    final ok = payload is Map && payload['ok'] == true;
    if (!mounted) return;
    if (!ok) {
      setState(() {
        _activeRoom = previousRoom;
      });
      if (_usesSfuAudioPath) {
        await _refreshLiveAudioPublishState();
      } else {
        _queueRtcSync(immediate: true);
      }
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text(
            payload is Map
                ? '${payload['message'] ?? 'Unable to leave speakers right now'}'
                : 'Leave speaker timed out. Try again.',
          ),
        ),
      );
      return;
    }
    final broadcast = _normalizeBroadcast(
      Map<String, dynamic>.from(payload['broadcast'] as Map? ?? previousRoom),
    );
    setState(() {
      _activeRoom = broadcast;
      _activeRoomVersion = _roomVersionFrom(broadcast);
      _activeSpeakerVersion = _speakerVersionFrom(broadcast);
      _refreshTopologyReady(broadcast);
    });
    _syncRoomChromeState();
    _queueRtcSync(immediate: true);
    if (_roomUsesVideo) {
      unawaited(_pruneOffStageVideoRenderers());
    }
  }

  Future<void> _onRtcOffer(dynamic data) async {
    if (data is! Map || _activeRoom == null) return;
    final payload = Map<String, dynamic>.from(data);
    if ('${payload['broadcastId'] ?? ''}' != '${_activeRoom!['id']}') return;
    final fromUserId = '${payload['fromUserId'] ?? ''}';
    if (fromUserId.isEmpty || fromUserId == _meId) return;

    if (_amOnStage) {
      await _ensureLocalStageStream();
    }
    final connection = await _ensurePeerConnection(fromUserId);
    final sdp = Map<String, dynamic>.from(payload['sdp'] as Map);
    await connection.setRemoteDescription(
      RTCSessionDescription(sdp['sdp']?.toString(), sdp['type']?.toString()),
    );
    _remoteDescriptionReady.add(fromUserId);
    await _flushPendingIce(fromUserId);
    final shouldSendAudio = _amOnStage;
    await _ensureAudioPeerMode(
      connection,
      peerUserId: fromUserId,
      shouldSendAudio: shouldSendAudio,
    );
    _peerMeshMediaSignatures[fromUserId] = _meshPeerMediaSignature(
      fromUserId,
      shouldSendAudio: shouldSendAudio,
    );
    final answer = await connection.createAnswer(<String, dynamic>{
      'offerToReceiveAudio': true,
      'offerToReceiveVideo': _shouldReceiveVideoFrom(fromUserId),
    });
    await connection.setLocalDescription(answer);
    _socket.emit('live:rtc:answer', <String, dynamic>{
      'broadcastId': _activeRoom!['id'],
      'toUserId': fromUserId,
      'sdp': answer.toMap(),
    });
  }

  Future<void> _onRtcAnswer(dynamic data) async {
    if (data is! Map || _activeRoom == null) return;
    final payload = Map<String, dynamic>.from(data);
    if ('${payload['broadcastId'] ?? ''}' != '${_activeRoom!['id']}') return;
    final fromUserId = '${payload['fromUserId'] ?? ''}';
    final connection = _peerConnections[fromUserId];
    if (connection == null) return;
    final sdp = Map<String, dynamic>.from(payload['sdp'] as Map);
    await connection.setRemoteDescription(
      RTCSessionDescription(sdp['sdp']?.toString(), sdp['type']?.toString()),
    );
    _remoteDescriptionReady.add(fromUserId);
    _peerStates[fromUserId] = 'connected';
    await _flushPendingIce(fromUserId);
  }

  Future<void> _onRtcIce(dynamic data) async {
    if (data is! Map || _activeRoom == null) return;
    final payload = Map<String, dynamic>.from(data);
    if ('${payload['broadcastId'] ?? ''}' != '${_activeRoom!['id']}') return;
    final fromUserId = '${payload['fromUserId'] ?? ''}';
    if (fromUserId.isEmpty || fromUserId == _meId) return;
    final candidateData = Map<String, dynamic>.from(
      payload['candidate'] as Map,
    );
    final candidate = RTCIceCandidate(
      candidateData['candidate']?.toString(),
      candidateData['sdpMid']?.toString(),
      candidateData['sdpMLineIndex'] as int?,
    );
    if (!_remoteDescriptionReady.contains(fromUserId) ||
        !_peerConnections.containsKey(fromUserId)) {
      (_pendingIce[fromUserId] ??= <RTCIceCandidate>[]).add(candidate);
      return;
    }
    await _peerConnections[fromUserId]!.addCandidate(candidate);
  }

  String _describeConnectionState(RTCPeerConnectionState state) {
    return switch (state) {
      RTCPeerConnectionState.RTCPeerConnectionStateConnected => 'connected',
      RTCPeerConnectionState.RTCPeerConnectionStateConnecting => 'connecting',
      RTCPeerConnectionState.RTCPeerConnectionStateDisconnected =>
        'disconnected',
      RTCPeerConnectionState.RTCPeerConnectionStateFailed => 'failed',
      RTCPeerConnectionState.RTCPeerConnectionStateClosed => 'closed',
      _ => 'connecting',
    };
  }

  void _handleSocketStatusChanged() {
    unawaited(_handleSocketStatusChangedAsync());
  }

  Future<void> _handleSocketStatusChangedAsync() async {
    final nextStatus = _socket.status;
    if (nextStatus == _socketStatus || !mounted) return;
    final previousStatus = _socketStatus;
    _socketStatus = nextStatus;
    _recordRtcTransition('socket $previousStatus->$nextStatus');

    if (nextStatus == 'connected') {
      _unbindSocket();
      _bindSocket();
      unawaited(_requestBroadcasts());
      _queueSharedBroadcastResolution();
      if (_activeRoom != null && !_rejoiningRoom) {
        _rejoiningRoom = true;
        final room = _activeRoom!;
        final me = ref.read(sessionControllerProvider).user;
        if (me != null) {
          final payload = await _socket.emitWithAckRetry(
            'live:broadcast:join',
            <String, dynamic>{
              'broadcastId': room['id'],
              'name': me.displayName,
              'photo': me.profilePhotoUrl,
            },
            timeout: const Duration(seconds: 5),
            maxAttempts: 2,
          );
          _rejoiningRoom = false;
          if (!mounted) return;
          if (payload is Map && payload['ok'] == true) {
            final broadcast = _normalizeBroadcast(
              Map<String, dynamic>.from(payload['broadcast'] as Map? ?? room),
            );
            final mediaSession = payload['mediaSession'] is Map
                ? Map<String, dynamic>.from(payload['mediaSession'] as Map)
                : null;
            setState(() {
              _activeRoom = broadcast;
              _activeRoomVersion = _roomVersionFrom(broadcast);
              _activeSpeakerVersion = _speakerVersionFrom(broadcast);
              _refreshTopologyReady(broadcast);
              _syncLiveTransientStateFromRoom(broadcast);
              _handRaised = false;
            });
            _syncRoomChromeState();
            if (_usesSfuAudioPath) {
              await _connectLiveAudioSfu(
                room: broadcast,
                mediaSession: mediaSession,
              );
              await _refreshLiveAudioPublishState();
            }
            _queueRtcSync();
          } else {
            setState(() {
              _activeRoom = null;
              _lastShownNoticeId = null;
              _activeRoomVersion = 0;
              _activeSpeakerVersion = 0;
              _topologyReady = false;
              _comments = const [];
              _joinRequests = const [];
              _syncLiveTransientStateFromRoom(null);
              _handRaised = false;
              _commentController.clear();
              _isFollowingHost = false;
              _followingHostBusy = false;
              _activeSpeakers.clear();
              _latestSpeakingSeqByUser.clear();
            });
            _syncRoomChromeState();
            unawaited(_disposeRtc());
          }
        } else {
          _rejoiningRoom = false;
        }
      } else {
        setState(() {});
      }
      _syncBrowseListRefreshTimer();
      return;
    }

    if ((nextStatus == 'connecting' || nextStatus == 'disconnected') &&
        previousStatus == 'connected' &&
        _activeRoom != null) {
      unawaited(_liveAudioService.disconnect());
      unawaited(_disposeRtc());
      unawaited(Helper.setSpeakerphoneOn(false));
      setState(() {
        _comments = const [];
        _joinRequests = const [];
        _handRaised = false;
        _activeSpeakers.clear();
        _sfuConnected = false;
      });
      _syncBrowseListRefreshTimer();
      return;
    }

    setState(() {});
  }

  Future<void> _shareRoom() async {
    final room = _activeRoom;
    if (room == null) return;
    final roomId = '${room['id'] ?? ''}'.trim();
    var shareUrl = AppConfig.liveBroadcastShareUrl(roomId);
    try {
      final share = await ref
          .read(contentRepositoryProvider)
          .createLiveShareLink(
            broadcastId: roomId,
            room: <String, dynamic>{
              'title': '${room['title'] ?? ''}',
              'description': '${room['description'] ?? ''}',
              'roomType': '${room['type'] ?? ''}',
              'hostName': '${room['host'] ?? ''}',
              'hostProfilePhotoUrl': '${room['hostPhoto'] ?? ''}',
              'isPrivate': room['isPrivate'] == true,
            },
          );
      if (share.shareUrl.trim().isNotEmpty) {
        shareUrl = share.shareUrl.trim();
      }
    } catch (_) {
      // Keep the legacy broadcast URL working if share-token creation fails.
    }
    await _openLiveRoomShareSheet(shareUrl);
  }

  Future<void> _openLiveRoomShareSheet(String shareUrl) async {
    if (shareUrl.trim().isEmpty) return;
    await showModalBottomSheet<void>(
      context: context,
      backgroundColor: Colors.transparent,
      builder: (context) {
        final theme = Theme.of(context);
        return SafeArea(
          top: false,
          child: Padding(
            padding: const EdgeInsets.fromLTRB(16, 0, 16, 16),
            child: Container(
              decoration: BoxDecoration(
                color: theme.colorScheme.surface,
                borderRadius: BorderRadius.circular(28),
              ),
              padding: const EdgeInsets.fromLTRB(20, 18, 20, 20),
              child: Column(
                mainAxisSize: MainAxisSize.min,
                children: [
                  Row(
                    children: [
                      Expanded(
                        child: Text(
                          'Share room',
                          style: theme.textTheme.titleLarge?.copyWith(
                            fontWeight: FontWeight.w800,
                          ),
                        ),
                      ),
                      IconButton(
                        onPressed: () => Navigator.of(context).pop(),
                        icon: const Icon(Icons.close_rounded),
                      ),
                    ],
                  ),
                  const SizedBox(height: 8),
                  _ShareRoomActionTile(
                    icon: Icons.chat_bubble_outline_rounded,
                    title: 'Send in Talkflix',
                    subtitle: 'Choose chats from your history',
                    onTap: () {
                      Navigator.of(context).pop();
                      unawaited(_sendRoomLinkToTalkflixChats(shareUrl));
                    },
                  ),
                  _ShareRoomActionTile(
                    icon: Icons.ios_share_rounded,
                    title: 'Share externally',
                    subtitle: 'Use Messages, WhatsApp, Mail, and more',
                    onTap: () {
                      Navigator.of(context).pop();
                      unawaited(_shareRoomExternally(shareUrl));
                    },
                  ),
                ],
              ),
            ),
          ),
        );
      },
    );
  }

  Future<void> _shareRoomExternally(String shareUrl) async {
    try {
      await Share.share(
        shareUrl,
        sharePositionOrigin: _shareOriginForContext(context),
      );
    } catch (_) {
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('Could not open the share sheet.')),
      );
    }
  }

  Rect? _shareOriginForContext(BuildContext context) {
    final renderObject = context.findRenderObject();
    if (renderObject is! RenderBox || !renderObject.hasSize) return null;
    final position = renderObject.localToGlobal(Offset.zero);
    return position & renderObject.size;
  }

  Future<void> _sendRoomLinkToTalkflixChats(String shareUrl) async {
    try {
      final threads = await ref
          .read(talkRepositoryProvider)
          .fetchRecentThreads();
      if (!mounted) return;
      final selected = await showChatRecipientPicker(
        context: context,
        threads: threads,
        title: 'Send room to',
        actionLabel: 'Send',
      );
      if (selected.isEmpty || !mounted) return;
      final repository = ref.read(directChatRepositoryProvider);
      var sentCount = 0;
      for (final thread in selected) {
        await repository.sendTextMessage(
          userId: thread.partnerId,
          text: shareUrl,
        );
        sentCount += 1;
      }
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text(
            sentCount == 1
                ? 'Room link sent.'
                : 'Room link sent to $sentCount chats.',
          ),
        ),
      );
    } catch (error) {
      if (!mounted) return;
      ScaffoldMessenger.of(
        context,
      ).showSnackBar(SnackBar(content: Text(error.toString())));
    }
  }

  void _applyActiveRoomUpdateFromPayload(
    Map<String, dynamic> room, {
    bool refreshFollowState = false,
  }) {
    final broadcast = _normalizeBroadcast(room);
    final previousSpeakers =
        (_activeRoom?['speakers'] as List<dynamic>? ?? const []);
    broadcast['speakers'] = _mergeSpeakerMicEffects(
      broadcast['speakers'] as List<dynamic>? ?? const [],
      previousSpeakers,
    );
    setState(() {
      _activeRoom = broadcast;
      _activeRoomVersion = math.max(
        _activeRoomVersion,
        _roomVersionFrom(broadcast),
      );
      _activeSpeakerVersion = math.max(
        _activeSpeakerVersion,
        _speakerVersionFrom(broadcast),
      );
      _refreshTopologyReady(broadcast);
      _browseType = '${broadcast['type'] ?? _browseType}';
      _joinRequests = (broadcast['joinRequests'] as List<dynamic>? ?? const [])
          .whereType<Map>()
          .map((item) => Map<String, dynamic>.from(item))
          .toList();
    });
    _upsertBroadcastLocally(broadcast);
    _syncRoomChromeState();
    if (refreshFollowState) {
      unawaited(_refreshHostFollowState(broadcast));
    }
  }

  Future<bool> _saveRoomSettings({
    required String title,
    required String description,
    required String language,
    String? secondaryLanguage,
  }) async {
    final room = _activeRoom;
    if (room == null) return false;
    final payload = await _socket.emitWithAckRetry(
      'live:room:update',
      <String, dynamic>{
        'broadcastId': room['id'],
        'title': title.trim(),
        'description': description.trim(),
        'lang': language.trim(),
        'lang2': secondaryLanguage?.trim(),
      },
      timeout: const Duration(seconds: 5),
      maxAttempts: 2,
    );
    if (!mounted) return false;
    final ok = payload is Map && payload['ok'] == true;
    if (!ok) {
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text(
            payload is Map
                ? '${payload['message'] ?? 'Unable to update room settings'}'
                : 'Room settings update timed out.',
          ),
        ),
      );
      return false;
    }
    if (payload['broadcast'] is Map) {
      _applyActiveRoomUpdateFromPayload(
        Map<String, dynamic>.from(payload['broadcast'] as Map),
        refreshFollowState: true,
      );
    }
    return true;
  }

  Future<bool> _setParticipantModerator({
    required String userId,
    required bool isModerator,
  }) async {
    final room = _activeRoom;
    if (room == null || userId.isEmpty) return false;
    final payload = await _socket.emitWithAckRetry(
      'live:role:update',
      <String, dynamic>{
        'broadcastId': room['id'],
        'targetUserId': userId,
        'role': isModerator ? 'moderator' : 'listener',
      },
      timeout: const Duration(seconds: 5),
      maxAttempts: 2,
    );
    if (!mounted) return false;
    final ok = payload is Map && payload['ok'] == true;
    if (!ok) {
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text(
            payload is Map
                ? '${payload['message'] ?? 'Unable to update moderators'}'
                : 'Moderator update timed out.',
          ),
        ),
      );
      return false;
    }
    if (payload['broadcast'] is Map) {
      _applyActiveRoomUpdateFromPayload(
        Map<String, dynamic>.from(payload['broadcast'] as Map),
      );
    }
    return true;
  }

  Future<bool> _saveRoomAppearance({required String backgroundTheme}) async {
    final room = _activeRoom;
    if (room == null) return false;
    final payload = await _socket.emitWithAckRetry(
      'live:room:appearance:update',
      <String, dynamic>{
        'broadcastId': room['id'],
        'backgroundTheme': backgroundTheme,
      },
      timeout: const Duration(seconds: 5),
      maxAttempts: 2,
    );
    if (!mounted) return false;
    final ok = payload is Map && payload['ok'] == true;
    if (!ok) {
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text(
            payload is Map
                ? '${payload['message'] ?? 'Unable to update room appearance'}'
                : 'Appearance update timed out.',
          ),
        ),
      );
      return false;
    }
    if (payload['broadcast'] is Map) {
      _applyActiveRoomUpdateFromPayload(
        Map<String, dynamic>.from(payload['broadcast'] as Map),
      );
    }
    if (_activeRoom != null) {
      setState(() {
        _activeRoom = {
          ..._activeRoom!,
          'backgroundTheme': backgroundTheme.trim().toLowerCase(),
        };
      });
      _syncRoomChromeState();
    }
    return true;
  }

  Future<void> _openRoomSettingsScreen() async {
    final room = _activeRoom;
    if (room == null) return;
    await Navigator.of(context).push(
      MaterialPageRoute<void>(
        builder: (context) => _LiveRoomSettingsScreen(
          initialTitle: '${room['title'] ?? ''}',
          initialDescription: '${room['description'] ?? ''}',
          initialLanguage: '${room['lang'] ?? _language}',
          initialSecondaryLanguage: '${room['lang2'] ?? ''}'.trim().isEmpty
              ? null
              : '${room['lang2']}',
          isPrivate: _roomIsPrivate,
          canEdit: _isHost,
          participants: _roomParticipantsForModeration,
          moderatorIds: _moderatorIds,
          onSave: _saveRoomSettings,
          onToggleModerator: _isHost
              ? ({required String userId, required bool isModerator}) =>
                    _setParticipantModerator(
                      userId: userId,
                      isModerator: isModerator,
                    )
              : null,
        ),
        fullscreenDialog: true,
      ),
    );
  }

  Future<void> _openRoomAppearanceSheet() async {
    final room = _activeRoom;
    if (room == null) return;
    await showModalBottomSheet<void>(
      context: context,
      backgroundColor: Colors.transparent,
      isScrollControlled: true,
      builder: (context) {
        return _LiveRoomAppearanceSheet(
          initialBackgroundTheme: _backgroundThemeName,
          initialMicEffect: _micEffectName,
          initialCommentTheme: _myCommentTheme,
          canEditBackground: _isHost,
          onSave: _saveRoomAppearance,
          onSaveMicEffect: _saveMyMicEffect,
          onSaveCommentTheme: _saveMyCommentTheme,
        );
      },
    );
  }

  Future<void> _openHostNoticeSheet() async {
    if (!_isHost || _activeRoom == null) return;
    final savedNotice = _activeRoom?['activeNotice'] is Map
        ? Map<String, dynamic>.from(_activeRoom!['activeNotice'] as Map)
        : const <String, dynamic>{};
    final result = await showModalBottomSheet<_HostNoticeAction>(
      context: context,
      isScrollControlled: true,
      backgroundColor: Colors.transparent,
      builder: (context) {
        return _HostNoticeSheet(
          initialSavedText: '${savedNotice['text'] ?? ''}',
          hasSavedNotice: savedNotice.isNotEmpty,
        );
      },
    );
    if (result == null) return;
    await _waitForRouteToSettle();
    if (!mounted) return;
    if (result.type == _HostNoticeActionType.save) {
      await _saveHostJoinNotice(result.text);
    } else if (result.type == _HostNoticeActionType.delete) {
      await _deleteHostJoinNotice();
    } else if (result.type == _HostNoticeActionType.send) {
      await _sendHostNotice(result.text);
    }
  }

  Future<void> _openHostPollSheet() async {
    if (!_isHost || _activeRoom == null) return;
    final questionController = TextEditingController();
    final optionControllers = [
      TextEditingController(),
      TextEditingController(),
      TextEditingController(),
      TextEditingController(),
    ];
    final result = await showModalBottomSheet<Map<String, dynamic>>(
      context: context,
      isScrollControlled: true,
      backgroundColor: Colors.transparent,
      builder: (context) {
        final theme = Theme.of(context);
        return SafeArea(
          top: false,
          child: Padding(
            padding: EdgeInsets.fromLTRB(
              16,
              0,
              16,
              MediaQuery.viewInsetsOf(context).bottom + 16,
            ),
            child: Container(
              constraints: BoxConstraints(
                maxHeight: MediaQuery.sizeOf(context).height * 0.86,
              ),
              decoration: BoxDecoration(
                color: theme.colorScheme.surface,
                borderRadius: BorderRadius.circular(28),
              ),
              padding: const EdgeInsets.fromLTRB(20, 18, 20, 20),
              child: ListView(
                shrinkWrap: true,
                children: [
                  Text(
                    'Create poll',
                    style: theme.textTheme.titleLarge?.copyWith(
                      fontWeight: FontWeight.w800,
                    ),
                  ),
                  const SizedBox(height: 12),
                  TextField(
                    controller: questionController,
                    autofocus: true,
                    maxLength: 180,
                    textAlignVertical: TextAlignVertical.top,
                    decoration: const InputDecoration(
                      labelText: 'Question',
                      border: OutlineInputBorder(),
                    ),
                  ),
                  const SizedBox(height: 8),
                  for (var i = 0; i < optionControllers.length; i++) ...[
                    TextField(
                      controller: optionControllers[i],
                      maxLength: 80,
                      decoration: InputDecoration(
                        labelText: i < 2
                            ? 'Option ${i + 1}'
                            : 'Option ${i + 1} (optional)',
                        border: const OutlineInputBorder(),
                      ),
                    ),
                    const SizedBox(height: 8),
                  ],
                  FilledButton.icon(
                    onPressed: () {
                      Navigator.of(context).pop(<String, dynamic>{
                        'question': questionController.text.trim(),
                        'options': optionControllers
                            .map((controller) => controller.text.trim())
                            .where((text) => text.isNotEmpty)
                            .toList(),
                      });
                    },
                    icon: const Icon(Icons.poll_outlined),
                    label: const Text('Start poll'),
                  ),
                ],
              ),
            ),
          ),
        );
      },
    );
    questionController.dispose();
    for (final controller in optionControllers) {
      controller.dispose();
    }
    if (result == null) return;
    await _createHostPoll(
      question: '${result['question'] ?? ''}',
      options: (result['options'] as List<dynamic>? ?? const [])
          .map((option) => '$option')
          .toList(),
    );
  }

  String _displayNameForUser(String userId) {
    if (userId.isEmpty) return 'Participant';
    final room = _activeRoom;
    if (room == null) return 'Participant';
    if ('${room['hostUserId'] ?? ''}' == userId) {
      return '${room['host'] ?? 'Host'}';
    }
    for (final speaker in _speakers) {
      if ('${speaker['userId'] ?? ''}' == userId) {
        return '${speaker['name'] ?? 'Speaker'}';
      }
    }
    for (final audience in _audienceMembers) {
      if ('${audience['userId'] ?? ''}' == userId) {
        return '${audience['name'] ?? 'Listener'}';
      }
    }
    return 'Participant';
  }

  Future<void> _openParticipantActions(String userId) async {
    final room = _activeRoom;
    if (room == null || userId.isEmpty) return;
    final hostUserId = '${room['hostUserId'] ?? ''}';
    final canModerate =
        _isHost ||
        _liveRoomState.permissions.canModerateRoom ||
        ref
            .read(liveRoomControllerProvider.notifier)
            .canModerateTarget(
              myUserId: _meId,
              targetUserId: userId,
              hostUserId: hostUserId,
            );
    final targetOnStage = _isUserOnStage(userId);
    final targetIsHost = hostUserId.isNotEmpty && hostUserId == userId;
    final targetName = _displayNameForUser(userId);
    final targetIsModerator = _moderatorIds.contains(userId);
    final canManageStage = AppConfig.liveRequireHostModeration
        ? _isHost
        : canModerate;
    final canRemoveFromStage = ref
        .read(liveRoomControllerProvider.notifier)
        .canRemoveFromStage(
          myUserId: _meId,
          targetUserId: userId,
          hostUserId: hostUserId,
        );
    final selectedAction = await showModalBottomSheet<String>(
      context: context,
      useRootNavigator: true,
      backgroundColor: Colors.transparent,
      builder: (context) {
        final theme = Theme.of(context);
        return Padding(
          padding: const EdgeInsets.fromLTRB(16, 0, 16, 16),
          child: Container(
            decoration: BoxDecoration(
              color: theme.colorScheme.surface,
              borderRadius: BorderRadius.circular(24),
            ),
            child: SafeArea(
              top: false,
              child: Column(
                mainAxisSize: MainAxisSize.min,
                children: [
                  ListTile(
                    title: Text(
                      targetName,
                      style: theme.textTheme.titleMedium?.copyWith(
                        fontWeight: FontWeight.w700,
                      ),
                    ),
                    subtitle: const Text('Participant actions'),
                  ),
                  ListTile(
                    leading: const Icon(Icons.person_outline_rounded),
                    title: const Text('View profile'),
                    onTap: () {
                      Navigator.of(context).pop('profile');
                    },
                  ),
                  if (canModerate)
                    ListTile(
                      leading: const Icon(Icons.volume_off_rounded),
                      title: const Text('Mute participant'),
                      enabled: canManageStage,
                      onTap: !canManageStage
                          ? null
                          : () async {
                              Navigator.of(context).pop();
                              dynamic payload = const <String, dynamic>{
                                'ok': true,
                              };
                              if (AppConfig.liveUseAckModeration) {
                                payload = await _socket.emitWithAckRetry(
                                  'live:user:mute',
                                  <String, dynamic>{
                                    'broadcastId': room['id'],
                                    'targetUserId': userId,
                                    'muted': true,
                                  },
                                  timeout: const Duration(seconds: 5),
                                  maxAttempts: 2,
                                );
                              } else {
                                _socket
                                    .emit('live:user:mute', <String, dynamic>{
                                      'broadcastId': room['id'],
                                      'targetUserId': userId,
                                      'muted': true,
                                    });
                              }
                              if (!mounted) return;
                              final ok =
                                  payload is Map && payload['ok'] == true;
                              if (!ok) {
                                ScaffoldMessenger.of(this.context).showSnackBar(
                                  SnackBar(
                                    content: Text(
                                      payload is Map
                                          ? '${payload['message'] ?? 'Unable to mute participant'}'
                                          : 'Mute request timed out.',
                                    ),
                                  ),
                                );
                                return;
                              }
                              ScaffoldMessenger.of(this.context).showSnackBar(
                                const SnackBar(
                                  content: Text('Mute signal sent'),
                                ),
                              );
                            },
                    ),
                  if (canModerate)
                    ListTile(
                      leading: const Icon(Icons.vertical_align_bottom_rounded),
                      title: const Text('Remove from speakers'),
                      enabled:
                          canRemoveFromStage && targetOnStage && !targetIsHost,
                      onTap:
                          !(canRemoveFromStage &&
                              targetOnStage &&
                              !targetIsHost)
                          ? null
                          : () async {
                              Navigator.of(context).pop();
                              dynamic payload = const <String, dynamic>{
                                'ok': true,
                              };
                              if (AppConfig.liveUseAckModeration) {
                                payload = await _socket.emitWithAckRetry(
                                  'live:speaker:remove',
                                  <String, dynamic>{
                                    'broadcastId': room['id'],
                                    'targetUserId': userId,
                                  },
                                  timeout: const Duration(seconds: 5),
                                  maxAttempts: 2,
                                );
                              } else {
                                _socket.emit(
                                  'live:speaker:remove',
                                  <String, dynamic>{
                                    'broadcastId': room['id'],
                                    'targetUserId': userId,
                                  },
                                );
                              }
                              if (!mounted) return;
                              final ok =
                                  payload is Map && payload['ok'] == true;
                              if (!ok) {
                                ScaffoldMessenger.of(this.context).showSnackBar(
                                  SnackBar(
                                    content: Text(
                                      payload is Map
                                          ? '${payload['message'] ?? 'Unable to remove from speakers'}'
                                          : 'Remove-from-speakers timed out.',
                                    ),
                                  ),
                                );
                                return;
                              }
                              final broadcast = _normalizeBroadcast(
                                Map<String, dynamic>.from(
                                  payload['broadcast'] as Map? ?? room,
                                ),
                              );
                              setState(() {
                                _activeRoom = broadcast;
                                _activeRoomVersion = _roomVersionFrom(
                                  broadcast,
                                );
                                _activeSpeakerVersion = _speakerVersionFrom(
                                  broadcast,
                                );
                                _refreshTopologyReady(broadcast);
                                _syncLiveTransientStateFromRoom(broadcast);
                                _joinRequests =
                                    (broadcast['joinRequests']
                                                as List<dynamic>? ??
                                            const [])
                                        .whereType<Map>()
                                        .map(
                                          (item) =>
                                              Map<String, dynamic>.from(item),
                                        )
                                        .toList();
                              });
                              _syncRoomChromeState();
                              _queueRtcSync(immediate: true);
                              ScaffoldMessenger.of(this.context).showSnackBar(
                                const SnackBar(
                                  content: Text('Speaker removed'),
                                ),
                              );
                            },
                    ),
                  if (canModerate)
                    ListTile(
                      leading: const Icon(Icons.person_remove_outlined),
                      title: const Text('Remove from room'),
                      onTap: () {
                        Navigator.of(context).pop();
                        _socket.emit('live:user:kick', <String, dynamic>{
                          'broadcastId': room['id'],
                          'targetUserId': userId,
                        });
                        ScaffoldMessenger.of(this.context).showSnackBar(
                          const SnackBar(content: Text('Removal signal sent')),
                        );
                      },
                    ),
                  if (_liveRoomState.permissions.canPromoteModerators)
                    ListTile(
                      leading: const Icon(Icons.admin_panel_settings_outlined),
                      title: Text(
                        targetIsModerator
                            ? 'Remove moderator role'
                            : 'Make moderator',
                      ),
                      onTap: () async {
                        Navigator.of(context).pop();
                        final success = await _setParticipantModerator(
                          userId: userId,
                          isModerator: !targetIsModerator,
                        );
                        if (!mounted || !success) return;
                        ScaffoldMessenger.of(this.context).showSnackBar(
                          SnackBar(
                            content: Text(
                              targetIsModerator
                                  ? 'Moderator removed'
                                  : 'Moderator added',
                            ),
                          ),
                        );
                      },
                    ),
                  if (userId != _meId)
                    ListTile(
                      leading: Icon(
                        Icons.report_outlined,
                        color: theme.colorScheme.error,
                      ),
                      title: Text(
                        'Report participant',
                        style: TextStyle(color: theme.colorScheme.error),
                      ),
                      onTap: () {
                        Navigator.of(context).pop('report');
                      },
                    ),
                  const SizedBox(height: 8),
                ],
              ),
            ),
          ),
        );
      },
    );
    if (!mounted || selectedAction == null) return;
    await _waitForRouteToSettle();
    if (!mounted) return;
    if (selectedAction == 'profile') {
      _openProfile(userId);
    } else if (selectedAction == 'report') {
      await _openReportParticipantSheet(
        userId: userId,
        displayName: targetName,
      );
    }
  }

  void _onParticipantLongPress(String userId) {
    if (userId.isEmpty) return;
    unawaited(_openParticipantActions(userId));
  }

  Future<void> _openReportParticipantSheet({
    required String userId,
    required String displayName,
  }) async {
    final result = await showModalBottomSheet<_ParticipantReportResult>(
      context: context,
      useRootNavigator: true,
      isScrollControlled: true,
      backgroundColor: Colors.transparent,
      builder: (context) {
        return _ParticipantReportSheet(
          displayName: displayName,
          permissionService: _permissionService,
        );
      },
    );
    if (result == null) return;
    await _waitForRouteToSettle();
    if (!mounted) return;
    try {
      await ref
          .read(apiClientProvider)
          .postJson(
            '/users/$userId/report',
            body: <String, dynamic>{
              'reason': result.reason,
              'details': result.details,
              'evidence': result.proofs
                  .map(
                    (proof) => <String, dynamic>{
                      'name': proof.name,
                      'mimeType': proof.mimeType,
                      'dataUrl': proof.dataUrl,
                    },
                  )
                  .toList(),
            },
          );
      if (!mounted) return;
      ScaffoldMessenger.of(
        context,
      ).showSnackBar(const SnackBar(content: Text('Report submitted.')));
    } catch (error) {
      if (!mounted) return;
      ScaffoldMessenger.of(
        context,
      ).showSnackBar(SnackBar(content: Text(error.toString())));
    }
  }

  Future<void> _openModerationControlsSheet() async {
    final room = _activeRoom;
    if (room == null ||
        (!_isHost && !_liveRoomState.permissions.canModerateRoom)) {
      return;
    }
    final canManageRequests =
        _isHost || _liveRoomState.permissions.canManageStageRequests;
    await showModalBottomSheet<void>(
      context: context,
      backgroundColor: Colors.transparent,
      builder: (context) {
        final theme = Theme.of(context);
        return Padding(
          padding: const EdgeInsets.fromLTRB(16, 0, 16, 16),
          child: Container(
            decoration: BoxDecoration(
              color: theme.colorScheme.surface,
              borderRadius: BorderRadius.circular(24),
            ),
            child: SafeArea(
              top: false,
              child: Column(
                mainAxisSize: MainAxisSize.min,
                children: [
                  ListTile(
                    title: Text(
                      'Room controls',
                      style: theme.textTheme.titleMedium?.copyWith(
                        fontWeight: FontWeight.w800,
                      ),
                    ),
                    subtitle: Text(
                      'Role: ${_liveRoomState.role.label}',
                      style: theme.textTheme.bodySmall,
                    ),
                  ),
                  if (canManageRequests)
                    ListTile(
                      leading: const Icon(Icons.pan_tool_alt_rounded),
                      title: const Text('Review speaker requests'),
                      onTap: () {
                        Navigator.of(context).pop();
                        unawaited(_openJoinRequestsSheet());
                      },
                    ),
                  ListTile(
                    leading: const Icon(Icons.groups_rounded),
                    title: const Text('Open audience list'),
                    onTap: () {
                      Navigator.of(context).pop();
                      unawaited(_openAudienceSheet());
                    },
                  ),
                  ListTile(
                    leading: const Icon(Icons.lock_outline_rounded),
                    title: const Text('Lock speakers (signal)'),
                    onTap: () {
                      Navigator.of(context).pop();
                      _socket.emit('live:stage:lock', <String, dynamic>{
                        'broadcastId': room['id'],
                        'locked': true,
                      });
                      ScaffoldMessenger.of(this.context).showSnackBar(
                        const SnackBar(
                          content: Text('Speaker lock signal sent'),
                        ),
                      );
                    },
                  ),
                  const SizedBox(height: 8),
                ],
              ),
            ),
          ),
        );
      },
    );
  }

  void _openProfile(String userId) {
    if (userId.isEmpty) return;
    context.push('/app/profile/$userId');
  }

  Future<void> _openCreateSheet() async {
    await showModalBottomSheet<void>(
      context: context,
      isScrollControlled: true,
      backgroundColor: Colors.transparent,
      builder: (_) => _CreateBroadcastSheet(
        initialType: _browseType,
        initialLanguage: _language,
        onGoLive: _createBroadcast,
      ),
    );
  }

  Future<void> _openJoinRequestsSheet() async {
    if (!_isHost && !_liveRoomState.permissions.canManageStageRequests) return;
    var localRequests = _joinRequests
        .map((item) => Map<String, dynamic>.from(item))
        .toList();
    await showModalBottomSheet<void>(
      context: context,
      backgroundColor: Colors.transparent,
      builder: (context) {
        final theme = Theme.of(context);
        return StatefulBuilder(
          builder: (context, sheetSetState) {
            return Padding(
              padding: const EdgeInsets.all(16),
              child: Container(
                decoration: BoxDecoration(
                  color: theme.colorScheme.surface,
                  borderRadius: BorderRadius.circular(28),
                ),
                padding: const EdgeInsets.fromLTRB(20, 20, 20, 24),
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    Row(
                      children: [
                        Text(
                          'Go live requests',
                          style: theme.textTheme.titleLarge?.copyWith(
                            fontWeight: FontWeight.w700,
                          ),
                        ),
                        const Spacer(),
                        IconButton(
                          onPressed: () => Navigator.of(context).pop(),
                          icon: const Icon(Icons.close),
                        ),
                      ],
                    ),
                    if (localRequests.isEmpty)
                      const Padding(
                        padding: EdgeInsets.symmetric(vertical: 24),
                        child: Text('No pending requests right now.'),
                      )
                    else
                      ...localRequests.map(
                        (request) => Padding(
                          padding: const EdgeInsets.only(top: 12),
                          child: _JoinRequestRow(
                            name: '${request['name'] ?? 'Guest'}',
                            photoUrl: '${request['photo'] ?? ''}',
                            onAccept: () async {
                              final userId = _requestUserId(request);
                              if (userId.isEmpty) return;

                              sheetSetState(() {
                                localRequests = localRequests
                                    .where(
                                      (item) =>
                                          '${item['userId'] ?? ''}' != userId,
                                    )
                                    .toList();
                              });

                              final accepted = await _acceptRequest(request);
                              if (!accepted && context.mounted) {
                                final alreadyInList = localRequests.any(
                                  (item) => '${item['userId'] ?? ''}' == userId,
                                );
                                if (!alreadyInList) {
                                  sheetSetState(
                                    () => localRequests = [
                                      request,
                                      ...localRequests,
                                    ],
                                  );
                                }
                              }
                            },
                          ),
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
  }

  Future<void> _openAudienceSheet() async {
    if (_activeRoom == null) return;
    final listeners = _audienceMembers;
    final audienceCount = _activeAudienceCount;
    await showModalBottomSheet<void>(
      context: context,
      isScrollControlled: true,
      backgroundColor: Colors.transparent,
      builder: (context) {
        final theme = Theme.of(context);
        final maxHeight = MediaQuery.of(context).size.height * 0.72;
        return Padding(
          padding: const EdgeInsets.fromLTRB(16, 12, 16, 16),
          child: Container(
            constraints: BoxConstraints(maxHeight: maxHeight, minHeight: 220),
            decoration: BoxDecoration(
              color: theme.colorScheme.surface,
              borderRadius: BorderRadius.circular(28),
            ),
            padding: const EdgeInsets.fromLTRB(20, 20, 20, 18),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                Row(
                  children: [
                    Text(
                      'Audience',
                      style: theme.textTheme.titleLarge?.copyWith(
                        fontWeight: FontWeight.w700,
                      ),
                    ),
                    const SizedBox(width: 8),
                    Container(
                      padding: const EdgeInsets.symmetric(
                        horizontal: 8,
                        vertical: 4,
                      ),
                      decoration: BoxDecoration(
                        color: theme.colorScheme.primary.withValues(
                          alpha: 0.12,
                        ),
                        borderRadius: BorderRadius.circular(999),
                      ),
                      child: Text(
                        compactCount(audienceCount),
                        style: theme.textTheme.labelMedium?.copyWith(
                          color: theme.colorScheme.primary,
                          fontWeight: FontWeight.w800,
                        ),
                      ),
                    ),
                    const Spacer(),
                    IconButton(
                      onPressed: () => Navigator.of(context).pop(),
                      icon: const Icon(Icons.close),
                    ),
                  ],
                ),
                const SizedBox(height: 6),
                if (listeners.isEmpty)
                  const Expanded(
                    child: Center(
                      child: Text('No audience members in this room yet.'),
                    ),
                  )
                else
                  Expanded(
                    child: ListView.separated(
                      itemCount: listeners.length,
                      separatorBuilder: (_, _) => Divider(
                        height: 1,
                        color: theme.colorScheme.outlineVariant.withValues(
                          alpha: 0.45,
                        ),
                      ),
                      itemBuilder: (context, index) {
                        final listener = listeners[index];
                        final userId = '${listener['userId'] ?? ''}';
                        final listenerName =
                            '${listener['name'] ?? 'Audience member'}';
                        return ListTile(
                          contentPadding: const EdgeInsets.symmetric(
                            horizontal: 2,
                            vertical: 2,
                          ),
                          leading: ParticipantActionTarget(
                            onTap: userId.isEmpty
                                ? null
                                : () {
                                    Navigator.of(context).pop();
                                    _openProfile(userId);
                                  },
                            onLongPress: userId.isEmpty
                                ? null
                                : () => _onParticipantLongPress(userId),
                            child: _AvatarBubble(
                              photoUrl: '${listener['photo'] ?? ''}',
                              size: 40,
                              fallback: listenerName,
                            ),
                          ),
                          title: ParticipantActionTarget(
                            onTap: userId.isEmpty
                                ? null
                                : () {
                                    Navigator.of(context).pop();
                                    _openProfile(userId);
                                  },
                            onLongPress: userId.isEmpty
                                ? null
                                : () => _onParticipantLongPress(userId),
                            child: Text(
                              listenerName,
                              maxLines: 1,
                              overflow: TextOverflow.ellipsis,
                              style: theme.textTheme.titleSmall?.copyWith(
                                fontWeight: FontWeight.w700,
                              ),
                            ),
                          ),
                          subtitle: userId.isNotEmpty ? Text('@$userId') : null,
                          trailing: const Icon(Icons.chevron_right_rounded),
                          onTap: userId.isEmpty
                              ? null
                              : () {
                                  Navigator.of(context).pop();
                                  _openProfile(userId);
                                },
                          onLongPress: userId.isEmpty
                              ? null
                              : () => _onParticipantLongPress(userId),
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
  }

  List<Map<String, dynamic>> get _baseBrowseBroadcasts => _broadcasts
      .where((room) => '${room['type'] ?? 'audio'}' == _browseType)
      .where(
        (room) => room['isPrivate'] == true
            ? '${room['hostUserId'] ?? ''}' == _meId
            : true,
      )
      .toList();

  List<String> _roomBrowseLanguages(Map<String, dynamic> room) {
    final languages = <String>[];
    for (final value in [room['lang'], room['lang2']]) {
      final language = '${value ?? ''}'.trim();
      if (language.isNotEmpty && !languages.contains(language)) {
        languages.add(language);
      }
    }
    return languages;
  }

  List<String> get _availableBrowseLanguages {
    final seen = <String>{};
    final languages = <String>[];
    for (final room in _baseBrowseBroadcasts) {
      for (final language in _roomBrowseLanguages(room)) {
        final key = language.toLowerCase();
        if (seen.add(key)) {
          languages.add(language);
        }
      }
    }
    languages.sort((a, b) => a.toLowerCase().compareTo(b.toLowerCase()));
    return languages;
  }

  String? get _effectiveBrowseLanguage {
    final selected = _browseLanguage?.trim();
    if (selected == null || selected.isEmpty) return null;
    final available = _availableBrowseLanguages;
    for (final language in available) {
      if (language.toLowerCase() == selected.toLowerCase()) {
        return language;
      }
    }
    return null;
  }

  List<Map<String, dynamic>> get _filteredBroadcasts {
    final selectedLanguage = _effectiveBrowseLanguage;
    return _baseBrowseBroadcasts.where((room) {
      if (_browseType != 'audio' || selectedLanguage == null) return true;
      return _roomBrowseLanguages(room).any(
        (language) => language.toLowerCase() == selectedLanguage.toLowerCase(),
      );
    }).toList();
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final socket = ref.watch(socketServiceProvider);

    final inImmersiveBroadcastRoom = _activeRoom != null;
    final inAudioOnlyImmersiveRoom =
        inImmersiveBroadcastRoom && !_roomUsesVideo;
    final scaffold = Scaffold(
      backgroundColor: inImmersiveBroadcastRoom
          ? (inAudioOnlyImmersiveRoom ? Colors.transparent : Colors.black)
          : theme.colorScheme.surface,
      resizeToAvoidBottomInset: !inImmersiveBroadcastRoom,
      extendBodyBehindAppBar: inImmersiveBroadcastRoom,
      body: inImmersiveBroadcastRoom
          ? _buildRoom(theme, socket.status)
          : SafeArea(bottom: true, child: _buildHome(theme, socket.status)),
    );
    if (inImmersiveBroadcastRoom && _roomUsesVideo) {
      return AnnotatedRegion<SystemUiOverlayStyle>(
        value: SystemUiOverlayStyle.light.copyWith(
          statusBarColor: Colors.transparent,
        ),
        child: scaffold,
      );
    }
    return scaffold;
  }

  Widget _buildHome(ThemeData theme, String socketStatus) {
    return Column(
      children: [
        Padding(
          padding: const EdgeInsets.fromLTRB(20, 10, 20, 14),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Row(
                crossAxisAlignment: CrossAxisAlignment.center,
                children: [
                  Text(
                    'Live',
                    style: theme.textTheme.headlineSmall?.copyWith(
                      fontWeight: FontWeight.w800,
                    ),
                  ),
                  const Spacer(),
                  const SizedBox(width: 8),
                  IconButton(
                    onPressed: _refreshBroadcasts,
                    visualDensity: VisualDensity.compact,
                    icon: const Icon(Icons.refresh),
                  ),
                  FilledButton.tonal(
                    onPressed: socketStatus == 'connected' && !_creating
                        ? _openCreateSheet
                        : null,
                    style: FilledButton.styleFrom(
                      shape: const CircleBorder(),
                      padding: const EdgeInsets.all(12),
                      visualDensity: VisualDensity.compact,
                    ),
                    child: const Icon(Icons.add),
                  ),
                ],
              ),
              if (socketStatus != 'connected') ...[
                const SizedBox(height: 12),
                RealtimeWarningBanner(
                  status: socketStatus,
                  scopeLabel: 'Live',
                  connectingMessage: 'Reconnecting to broadcasts...',
                ),
              ],
              const SizedBox(height: 14),
              _buildBroadcastTypeSwitcher(theme),
              if (_browseType == 'audio' &&
                  _availableBrowseLanguages.isNotEmpty) ...[
                const SizedBox(height: 12),
                _buildBrowseLanguageDropdown(theme),
              ],
            ],
          ),
        ),
        Expanded(child: _buildBroadcastList(theme, socketStatus)),
      ],
    );
  }

  Widget _buildBroadcastTypeSwitcher(ThemeData theme) {
    return _UnderlineTabSwitch(
      tabs: const [
        _UnderlineTabData(
          value: 'audio',
          label: 'Audio Broadcast',
          icon: Icons.mic_none_rounded,
        ),
        _UnderlineTabData(
          value: 'video',
          label: 'Video Broadcast',
          icon: Icons.videocam_outlined,
        ),
      ],
      selected: _browseType,
      onChanged: (value) => setState(() {
        _browseType = value;
        _browseLanguage = null;
        ref.read(liveBrowseTypeProvider.notifier).state = value;
      }),
    );
  }

  Widget _buildBrowseLanguageDropdown(ThemeData theme) {
    final languages = _availableBrowseLanguages;
    final selectedLanguage = _effectiveBrowseLanguage;
    return DropdownButtonFormField<String>(
      initialValue: selectedLanguage,
      isExpanded: true,
      decoration: InputDecoration(
        labelText: 'Language',
        prefixIcon: const Icon(Icons.language_rounded),
        filled: true,
        fillColor: theme.colorScheme.surfaceContainerHighest.withValues(
          alpha: 0.55,
        ),
        contentPadding: const EdgeInsets.symmetric(
          horizontal: 14,
          vertical: 12,
        ),
        border: OutlineInputBorder(
          borderRadius: BorderRadius.circular(18),
          borderSide: BorderSide(color: theme.colorScheme.outlineVariant),
        ),
        enabledBorder: OutlineInputBorder(
          borderRadius: BorderRadius.circular(18),
          borderSide: BorderSide(color: theme.colorScheme.outlineVariant),
        ),
      ),
      hint: const Text('All active languages'),
      items: [
        const DropdownMenuItem<String>(
          value: '',
          child: Text('All active languages'),
        ),
        for (final language in languages)
          DropdownMenuItem<String>(value: language, child: Text(language)),
      ],
      onChanged: (value) {
        setState(() {
          final next = value?.trim();
          _browseLanguage = next == null || next.isEmpty ? null : next;
        });
      },
    );
  }

  Widget _buildBroadcastList(ThemeData theme, String socketStatus) {
    if (_loadingList) {
      return const Center(child: CircularProgressIndicator());
    }
    if (_filteredBroadcasts.isEmpty) {
      return ListView(
        padding: const EdgeInsets.fromLTRB(20, 0, 20, 24),
        children: [
          Container(
            padding: const EdgeInsets.all(24),
            decoration: BoxDecoration(
              color: theme.colorScheme.surfaceContainer,
              borderRadius: BorderRadius.circular(28),
            ),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  _browseType == 'audio'
                      ? 'No audio broadcasts right now'
                      : 'No video broadcasts right now',
                  style: theme.textTheme.titleLarge?.copyWith(
                    fontWeight: FontWeight.w800,
                  ),
                ),
                const SizedBox(height: 10),
                Text(
                  'Start one yourself with the plus button, or refresh to check for new rooms.',
                  style: theme.textTheme.bodyMedium?.copyWith(
                    color: theme.colorScheme.onSurfaceVariant,
                  ),
                ),
                const SizedBox(height: 18),
                FilledButton(
                  onPressed: socketStatus == 'connected' && !_creating
                      ? _openCreateSheet
                      : null,
                  child: const Text('Create broadcast'),
                ),
              ],
            ),
          ),
        ],
      );
    }

    return ListView.separated(
      padding: const EdgeInsets.fromLTRB(20, 0, 20, 24),
      itemBuilder: (context, index) {
        final room = _filteredBroadcasts[index];
        return _BroadcastCard(
          roomId: '${room['id'] ?? room['_id'] ?? ''}',
          title: '${room['title'] ?? 'Untitled'}',
          type: '${room['type'] ?? 'audio'}',
          language: '${room['lang'] ?? 'EN'}',
          secondaryLanguage: '${room['lang2'] ?? ''}'.trim().isEmpty
              ? null
              : '${room['lang2']}',
          description: room['description']?.toString(),
          host: '${room['host'] ?? 'Host'}',
          hostPhotoUrl: '${room['hostPhoto'] ?? ''}',
          speakers: (room['speakers'] as List<dynamic>? ?? const [])
              .whereType<Map>()
              .map((s) => Map<String, dynamic>.from(s))
              .toList(),
          audienceCount: room['audienceCount'] as int? ?? 0,
          attendeeCount: room['attendees'] as int? ?? 0,
          onJoin: socketStatus == 'connected'
              ? () => _joinBroadcast(room)
              : null,
        );
      },
      separatorBuilder: (_, _) => const SizedBox(height: 14),
      itemCount: _filteredBroadcasts.length,
    );
  }

  Widget _buildRoom(ThemeData theme, String socketStatus) {
    if (!_roomUsesVideo) {
      return _buildImmersiveAudioRoom(theme, socketStatus);
    }
    return _buildImmersiveVideoRoom(theme, socketStatus);
  }

  List<String> get _videoRtcProblemStates {
    if (!_roomUsesVideo) return const <String>[];
    return _peerStates.values
        .map((state) => state.trim().toLowerCase())
        .where(
          (state) =>
              state == 'connecting' ||
              state == 'disconnected' ||
              state == 'failed' ||
              state == 'reconnecting',
        )
        .toList(growable: false);
  }

  bool get _videoRtcNeedsAttention {
    if (!_roomUsesVideo) return false;
    if (_videoRtcProblemStates.isNotEmpty) return true;
    return _rtcTargetPeerIds.isNotEmpty && _peerConnections.isEmpty;
  }

  Widget _buildVideoRtcStatusBanner(ThemeData theme) {
    final problemCount = _videoRtcProblemStates.length;
    final reconnecting = _peerReconnectTimers.isNotEmpty;
    final message = reconnecting || problemCount > 0
        ? 'Reconnecting live video...'
        : 'Connecting live video...';
    final detail = problemCount > 1
        ? '$problemCount video links need attention'
        : reconnecting
        ? 'Trying to restore the media link'
        : 'Waiting for media negotiation';

    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 9),
      decoration: BoxDecoration(
        color: Colors.black.withValues(alpha: 0.58),
        borderRadius: BorderRadius.circular(16),
        border: Border.all(color: Colors.white.withValues(alpha: 0.14)),
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          SizedBox(
            width: 16,
            height: 16,
            child: CircularProgressIndicator(
              strokeWidth: 2,
              valueColor: AlwaysStoppedAnimation<Color>(
                Colors.white.withValues(alpha: 0.9),
              ),
            ),
          ),
          const SizedBox(width: 9),
          Flexible(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              mainAxisSize: MainAxisSize.min,
              children: [
                Text(
                  message,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: theme.textTheme.labelLarge?.copyWith(
                    color: Colors.white,
                    fontWeight: FontWeight.w900,
                  ),
                ),
                Text(
                  detail,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: theme.textTheme.labelSmall?.copyWith(
                    color: Colors.white.withValues(alpha: 0.78),
                    fontWeight: FontWeight.w700,
                  ),
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildVideoPeerStatusChip(ThemeData theme, String userId) {
    final state = _peerStates[userId]?.trim().toLowerCase() ?? '';
    if (userId == _meId || state.isEmpty || state == 'connected') {
      return const SizedBox.shrink();
    }
    final label = switch (state) {
      'reconnecting' || 'disconnected' || 'failed' => 'Reconnecting',
      'connecting' => 'Connecting',
      _ => state,
    };
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
      decoration: BoxDecoration(
        color: Colors.black.withValues(alpha: 0.54),
        borderRadius: BorderRadius.circular(999),
        border: Border.all(color: Colors.white.withValues(alpha: 0.16)),
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          Container(
            width: 6,
            height: 6,
            decoration: const BoxDecoration(
              color: Colors.amber,
              shape: BoxShape.circle,
            ),
          ),
          const SizedBox(width: 5),
          Text(
            label,
            style: theme.textTheme.labelSmall?.copyWith(
              color: Colors.white,
              fontWeight: FontWeight.w800,
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildImmersiveVideoRoom(ThemeData theme, String socketStatus) {
    final room = _activeRoom!;
    final mq = MediaQuery.of(context);
    final topInset = mq.padding.top;
    final bottomInset = mq.viewInsets.bottom;
    final safeAreaBottom = mq.padding.bottom;
    final isCommenting = _commentFocusNode.hasFocus || bottomInset > 0;
    final composerBottomPadding = bottomInset > 0 ? bottomInset : 8.0;
    final iPhoneCommentClearance =
        Theme.of(context).platform == TargetPlatform.iOS ? safeAreaBottom : 0.0;
    final composerTop = 56 + composerBottomPadding + iPhoneCommentClearance;
    final pageTop = topInset + (socketStatus == 'connected' ? 118.0 : 160.0);
    _ensureVideoRoomChromeAutoHide();
    final chromePinned = _videoRoomChromePinned(
      isCommenting: isCommenting,
      socketStatus: socketStatus,
    );
    final showChrome = chromePinned || _videoRoomChromeVisible;

    return MediaQuery.removePadding(
      context: context,
      removeTop: true,
      child: Stack(
        fit: StackFit.expand,
        children: [
          Positioned.fill(child: _buildLiveVideoGrid(theme)),
          if (!showChrome)
            Positioned.fill(
              child: GestureDetector(
                behavior: HitTestBehavior.opaque,
                onTap: _revealVideoRoomChrome,
                onPanDown: (_) => _revealVideoRoomChrome(),
              ),
            ),
          IgnorePointer(
            ignoring: !showChrome,
            child: AnimatedOpacity(
              opacity: showChrome ? 1 : 0,
              duration: const Duration(milliseconds: 220),
              curve: Curves.easeOutCubic,
              child: Listener(
                onPointerDown: (_) => _syncVideoRoomChromeWithActivity(),
                child: Stack(
                fit: StackFit.expand,
                children: [
                  Positioned(
                    left: 0,
                    right: 0,
                    top: 0,
                    height: 220,
                    child: DecoratedBox(
                      decoration: BoxDecoration(
                        gradient: LinearGradient(
                          begin: Alignment.topCenter,
                          end: Alignment.bottomCenter,
                          colors: [
                            Colors.black.withValues(alpha: 0.72),
                            Colors.black.withValues(alpha: 0.08),
                            Colors.transparent,
                          ],
                        ),
                      ),
                    ),
                  ),
                  PageView(
                    key: const PageStorageKey<String>('video-room-pages'),
                    controller: _videoRoomPageController,
                    onPageChanged: (index) {
                      setState(() => _videoRoomPageIndex = index);
                      _syncVideoRoomChromeWithActivity();
                    },
                    children: [
                      const SizedBox.expand(),
                      _buildVideoCommentsScreen(
                        theme,
                        top: pageTop,
                        bottom: composerTop,
                        isCommenting: isCommenting,
                      ),
                    ],
                  ),
                  Positioned(
                    right: 0,
                    bottom: 100,
                    width: 120,
                    height: 400,
                    child: FlyingReactions(stream: _reactionController.stream),
                  ),
                  Positioned(
                    left: 16,
                    right: 16,
                    top: topInset + 6,
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        _buildImmersiveAudioHeader(theme, room),
                        const SizedBox(height: 8),
                        _buildVideoPageIndicator(theme),
                        if (socketStatus != 'connected') ...[
                          const SizedBox(height: 8),
                          RealtimeWarningBanner(
                            status: socketStatus,
                            scopeLabel: 'Live room',
                            connectingMessage:
                                'Reconnecting to the broadcast...',
                          ),
                        ],
                        if (socketStatus == 'connected' &&
                            _videoRtcNeedsAttention) ...[
                          const SizedBox(height: 8),
                          Align(
                            alignment: Alignment.centerLeft,
                            child: _buildVideoRtcStatusBanner(theme),
                          ),
                        ],
                      ],
                    ),
                  ),
                  Positioned(
                    left: 12,
                    right: 12,
                    bottom: 64 + composerBottomPadding + iPhoneCommentClearance,
                    child: _buildVideoStageInviteDock(theme),
                  ),
                  Positioned(
                    left: 16,
                    right: 16,
                    bottom: composerBottomPadding,
                    child: _buildImmersiveComposer(
                      theme,
                      socketStatus,
                      isCommenting,
                    ),
                  ),
                ],
                ),
              ),
            ),
          ),
          Positioned(
            left: 16,
            right: 16,
            bottom: 120 + composerBottomPadding + iPhoneCommentClearance,
            child: _buildVideoRoomActionControls(theme),
          ),
        ],
      ),
    );
  }

  Widget _buildVideoCommentsScreen(
    ThemeData theme, {
    required double top,
    required double bottom,
    required bool isCommenting,
  }) {
    return ColoredBox(
      color: Colors.black.withValues(alpha: isCommenting ? 0.34 : 0.22),
      child: Padding(
        padding: EdgeInsets.fromLTRB(16, top, 16, bottom),
        child: _comments.isEmpty
            ? const _AudioEmptyPage(
                icon: Icons.chat_bubble_outline_rounded,
                title: 'No comments yet',
                subtitle: 'Live comments will appear here over the video.',
              )
            : _buildImmersiveComments(theme, condensed: isCommenting),
      ),
    );
  }

  Widget _buildVideoPageIndicator(ThemeData theme) {
    const labels = ['Live', 'Comments'];
    return SizedBox(
      height: 34,
      child: Row(
        children: List.generate(labels.length, (index) {
          final selected = _videoRoomPageIndex == index;
          return Expanded(
            child: InkWell(
              borderRadius: BorderRadius.circular(8),
              onTap: () {
                _videoRoomPageController.animateToPage(
                  index,
                  duration: const Duration(milliseconds: 220),
                  curve: Curves.easeOutCubic,
                );
              },
              child: Column(
                mainAxisAlignment: MainAxisAlignment.end,
                children: [
                  Text(
                    labels[index],
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: theme.textTheme.labelLarge?.copyWith(
                      color: selected ? Colors.white : Colors.white70,
                      fontWeight: FontWeight.w900,
                    ),
                  ),
                  const SizedBox(height: 5),
                  AnimatedContainer(
                    duration: const Duration(milliseconds: 180),
                    height: 3,
                    width: selected ? 54 : 22,
                    decoration: BoxDecoration(
                      color: selected
                          ? Colors.white
                          : Colors.white.withValues(alpha: 0.25),
                      borderRadius: BorderRadius.circular(999),
                    ),
                  ),
                ],
              ),
            ),
          );
        }),
      ),
    );
  }

  Widget _buildLiveVideoGrid(ThemeData theme) {
    final participants = _videoLiveParticipants;
    if (participants.isEmpty) {
      final room = _activeRoom;
      return ColoredBox(
        color: Colors.black,
        child: Center(
          child: _AvatarBubble(
            photoUrl: '${room?['hostPhoto'] ?? ''}',
            size: 120,
            fallback: '${room?['host'] ?? 'Host'}',
          ),
        ),
      );
    }

    if (participants.length == 1) {
      return _buildLiveVideoTile(
        theme,
        participant: participants.first,
        rounded: false,
      );
    }

    if (participants.length == 2) {
      return Column(
        children: [
          Expanded(
            child: _buildLiveVideoTile(theme, participant: participants[0]),
          ),
          Expanded(
            child: _buildLiveVideoTile(theme, participant: participants[1]),
          ),
        ],
      );
    }

    if (participants.length == 3) {
      return Column(
        children: [
          Expanded(
            child: _buildLiveVideoTile(theme, participant: participants[0]),
          ),
          Expanded(
            child: Row(
              children: [
                Expanded(
                  child: _buildLiveVideoTile(
                    theme,
                    participant: participants[1],
                  ),
                ),
                Expanded(
                  child: _buildLiveVideoTile(
                    theme,
                    participant: participants[2],
                  ),
                ),
              ],
            ),
          ),
        ],
      );
    }

    return GridView.builder(
      padding: EdgeInsets.zero,
      physics: const NeverScrollableScrollPhysics(),
      gridDelegate: const SliverGridDelegateWithFixedCrossAxisCount(
        crossAxisCount: 2,
        childAspectRatio: 1,
      ),
      itemCount: 4,
      itemBuilder: (context, index) =>
          _buildLiveVideoTile(theme, participant: participants[index]),
    );
  }

  Widget _buildLiveVideoTile(
    ThemeData theme, {
    required Map<String, dynamic> participant,
    bool rounded = false,
  }) {
    final userId = '${participant['userId'] ?? participant['id'] ?? ''}'.trim();
    final name = '${participant['name'] ?? 'Live user'}'.trim();
    final showsOnStageVideo =
        userId == _meId || _videoOnStageUserIds.contains(userId);
    final sfuTrack = _usesSfuAudioPath && _roomUsesVideo && showsOnStageVideo
        ? _liveAudioService.videoTrackForIdentity(userId)
        : null;
    final renderer = userId == _meId
        ? _localRenderer
        : _remoteRenderers[userId];
    final stream = renderer?.srcObject;
    final hasLiveVideo = sfuTrack != null
        ? true
        : showsOnStageVideo &&
              renderer != null &&
              stream != null &&
              stream.getVideoTracks().any((track) => track.enabled);
    final role = '${participant['role'] ?? ''}'.toLowerCase().contains('host')
        ? 'Host'
        : 'Live';

    return ClipRRect(
      borderRadius: rounded ? BorderRadius.circular(18) : BorderRadius.zero,
      child: Stack(
        fit: StackFit.expand,
        children: [
          ColoredBox(
            color: Colors.black,
            child: hasLiveVideo
                ? sfuTrack != null
                      ? VideoTrackRenderer(
                          sfuTrack,
                          fit: VideoViewFit.cover,
                          mirrorMode: userId == _meId
                              ? VideoViewMirrorMode.mirror
                              : VideoViewMirrorMode.auto,
                        )
                      : RTCVideoView(
                          renderer!,
                          mirror: userId == _meId,
                          objectFit:
                              RTCVideoViewObjectFit.RTCVideoViewObjectFitCover,
                        )
                : Center(
                    child: _AvatarBubble(
                      photoUrl: '${participant['photo'] ?? ''}',
                      size: 96,
                      fallback: name,
                    ),
                  ),
          ),
          Positioned(
            left: 0,
            right: 0,
            bottom: 0,
            height: 92,
            child: DecoratedBox(
              decoration: BoxDecoration(
                gradient: LinearGradient(
                  begin: Alignment.bottomCenter,
                  end: Alignment.topCenter,
                  colors: [
                    Colors.black.withValues(alpha: 0.62),
                    Colors.transparent,
                  ],
                ),
              ),
            ),
          ),
          Positioned(
            left: 12,
            top: 12,
            child: _buildVideoPeerStatusChip(theme, userId),
          ),
          Positioned(
            left: 12,
            right: 12,
            bottom: 10,
            child: Row(
              children: [
                Container(
                  padding: const EdgeInsets.symmetric(
                    horizontal: 9,
                    vertical: 5,
                  ),
                  decoration: BoxDecoration(
                    color: role == 'Host'
                        ? _audioRoomAccent
                        : Colors.black.withValues(alpha: 0.42),
                    borderRadius: BorderRadius.circular(999),
                  ),
                  child: Text(
                    role,
                    style: theme.textTheme.labelSmall?.copyWith(
                      color: Colors.white,
                      fontWeight: FontWeight.w900,
                    ),
                  ),
                ),
                const SizedBox(width: 8),
                Expanded(
                  child: Text(
                    name,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: theme.textTheme.titleSmall?.copyWith(
                      color: Colors.white,
                      fontWeight: FontWeight.w900,
                    ),
                  ),
                ),
                if (userId == _meId && !_localMicEnabled)
                  const Icon(
                    Icons.mic_off_rounded,
                    color: Colors.white,
                    size: 18,
                  )
                else if (_activeSpeakers.contains(userId))
                  const Icon(
                    Icons.graphic_eq_rounded,
                    color: Colors.white,
                    size: 18,
                  ),
              ],
            ),
          ),
        ],
      ),
    );
  }

  /// TikTok-style chip: host sees who raised their hand to go live; audience
  /// sees a lightweight “waiting” state after requesting the stage.
  Widget _buildVideoStageInviteDock(ThemeData theme) {
    final canReviewJoinRequests =
        _isHost || _liveRoomState.permissions.canManageStageRequests;
    if (canReviewJoinRequests && _joinRequests.isNotEmpty) {
      final count = _joinRequests.length;
      final firstName = '${_joinRequests.first['name'] ?? 'Someone'}'.trim();
      final subtitle = count == 1
          ? '$firstName wants to go live'
          : '$count people want to go live';
      return Align(
        alignment: Alignment.centerLeft,
        child: GestureDetector(
          onTap: _openJoinRequestsSheet,
          child: DecoratedBox(
            decoration: BoxDecoration(
              color: Colors.black.withValues(alpha: 0.45),
              borderRadius: BorderRadius.circular(26),
              border: Border.all(color: Colors.white24),
            ),
            child: Padding(
              padding: const EdgeInsets.fromLTRB(10, 8, 12, 8),
              child: Row(
                mainAxisSize: MainAxisSize.min,
                children: [
                  _videoJoinRequestAvatarStack(),
                  const SizedBox(width: 10),
                  Flexible(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        Text(
                          'Go live requests',
                          style: theme.textTheme.labelMedium?.copyWith(
                            color: Colors.white.withValues(alpha: 0.9),
                            fontWeight: FontWeight.w800,
                          ),
                        ),
                        Text(
                          subtitle,
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                          style: theme.textTheme.bodySmall?.copyWith(
                            color: Colors.white70,
                          ),
                        ),
                      ],
                    ),
                  ),
                  const SizedBox(width: 4),
                  Icon(
                    Icons.chevron_right_rounded,
                    color: Colors.white.withValues(alpha: 0.75),
                    size: 22,
                  ),
                ],
              ),
            ),
          ),
        ),
      );
    }
    if (!_isHost && !_amOnStage && _handRaised) {
      return Align(
        alignment: Alignment.centerLeft,
        child: DecoratedBox(
          decoration: BoxDecoration(
            color: Colors.black.withValues(alpha: 0.45),
            borderRadius: BorderRadius.circular(26),
            border: Border.all(color: Colors.white24),
          ),
          child: Padding(
            padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 10),
            child: Row(
              mainAxisSize: MainAxisSize.min,
              children: [
                Icon(
                  Icons.waving_hand_rounded,
                  color: theme.colorScheme.primary,
                  size: 22,
                ),
                const SizedBox(width: 10),
                Flexible(
                  child: Text(
                    'Waiting for the host to let you speak',
                    style: theme.textTheme.bodySmall?.copyWith(
                      color: Colors.white.withValues(alpha: 0.92),
                      height: 1.25,
                    ),
                  ),
                ),
              ],
            ),
          ),
        ),
      );
    }
    return const SizedBox.shrink();
  }

  Widget _videoJoinRequestAvatarStack() {
    const diameter = 34.0;
    const overlap = 20.0;
    final show = _joinRequests.take(4).toList();
    if (show.isEmpty) return const SizedBox.shrink();
    final w = diameter + (show.length - 1) * overlap;
    return SizedBox(
      width: w,
      height: diameter,
      child: Stack(
        clipBehavior: Clip.none,
        children: [
          for (var i = 0; i < show.length; i++)
            Positioned(
              left: i * overlap,
              child: Container(
                decoration: BoxDecoration(
                  shape: BoxShape.circle,
                  border: Border.all(color: Colors.white, width: 2),
                ),
                child: ClipOval(
                  child: _AvatarBubble(
                    photoUrl: '${show[i]['photo'] ?? ''}',
                    size: diameter - 4,
                    fallback: '${show[i]['name'] ?? '?'}',
                  ),
                ),
              ),
            ),
        ],
      ),
    );
  }

  Widget _buildImmersiveAudioRoom(ThemeData theme, String socketStatus) {
    final room = _activeRoom!;
    final bottomInset = MediaQuery.of(context).viewInsets.bottom;
    final topInset = MediaQuery.of(context).padding.top;
    final safeAreaBottom = MediaQuery.of(context).padding.bottom;
    final isCommenting = _commentFocusNode.hasFocus || bottomInset > 0;
    final composerBottomPadding = bottomInset > 0 ? bottomInset : 8.0;
    final iPhoneCommentClearance =
        Theme.of(context).platform == TargetPlatform.iOS ? safeAreaBottom : 0.0;
    final pageTop = topInset + (socketStatus == 'connected' ? 104.0 : 150.0);
    final pageBottom = 64 + composerBottomPadding + iPhoneCommentClearance;

    return Stack(
      children: [
        Positioned.fill(
          child: Stack(
            fit: StackFit.expand,
            children: [
              Image.asset('assets/images/live_room_bg.png', fit: BoxFit.cover),
              DecoratedBox(
                decoration: BoxDecoration(
                  gradient: _roomBackgroundGradient(_backgroundThemeName),
                ),
              ),
            ],
          ),
        ),
        Positioned(
          right: 0,
          bottom: 100,
          width: 120,
          height: 400,
          child: FlyingReactions(stream: _reactionController.stream),
        ),
        Positioned(
          left: 16,
          right: 16,
          top: topInset + 4,
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            mainAxisSize: MainAxisSize.min,
            children: [
              _buildImmersiveAudioHeader(theme, room),
              const SizedBox(height: 6),
              _buildImmersiveTopActions(theme),
              if (socketStatus != 'connected') ...[
                const SizedBox(height: 8),
                RealtimeWarningBanner(
                  status: socketStatus,
                  scopeLabel: 'Live room',
                  connectingMessage: 'Reconnecting to the broadcast...',
                ),
              ],
            ],
          ),
        ),
        Positioned(
          left: 16,
          right: 16,
          top: pageTop,
          bottom: pageBottom,
          child: _buildAudioRoomPages(theme, isCommenting: isCommenting),
        ),
        Positioned(
          left: 16,
          right: 16,
          bottom: composerBottomPadding,
          child: _shouldUseGuestLivePreview
              ? _buildGuestPreviewDock(theme)
              : _buildImmersiveComposer(theme, socketStatus, isCommenting),
        ),
        if (_shouldUseGuestLivePreview && _guestPreviewExpired)
          Positioned.fill(child: _buildGuestPreviewWall(theme)),
      ],
    );
  }

  Widget _buildGuestPreviewDock(ThemeData theme) {
    final remaining = _guestPreviewSecondsRemaining;
    return Container(
      padding: const EdgeInsets.fromLTRB(14, 12, 14, 12),
      decoration: BoxDecoration(
        color: Colors.black.withValues(alpha: 0.42),
        borderRadius: BorderRadius.circular(22),
        border: Border.all(color: Colors.white.withValues(alpha: 0.12)),
      ),
      child: Row(
        children: [
          const Icon(Icons.headphones_rounded, color: Colors.white, size: 20),
          const SizedBox(width: 10),
          Expanded(
            child: Text(
              remaining > 0
                  ? 'Guest preview ends in ${remaining}s'
                  : 'Create an account to keep listening',
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: theme.textTheme.labelLarge?.copyWith(
                color: Colors.white,
                fontWeight: FontWeight.w800,
              ),
            ),
          ),
          const SizedBox(width: 10),
          FilledButton(
            onPressed: _openGuestPreviewSignup,
            style: FilledButton.styleFrom(
              visualDensity: VisualDensity.compact,
              padding: const EdgeInsets.symmetric(horizontal: 14),
            ),
            child: const Text('Sign up'),
          ),
        ],
      ),
    );
  }

  Widget _buildGuestPreviewWall(ThemeData theme) {
    return ColoredBox(
      color: Colors.black.withValues(alpha: 0.68),
      child: Center(
        child: Container(
          constraints: const BoxConstraints(maxWidth: 360),
          margin: const EdgeInsets.all(22),
          padding: const EdgeInsets.all(22),
          decoration: BoxDecoration(
            color: theme.colorScheme.surface,
            borderRadius: BorderRadius.circular(28),
          ),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              Icon(
                Icons.lock_open_rounded,
                color: theme.colorScheme.primary,
                size: 36,
              ),
              const SizedBox(height: 14),
              Text(
                'Keep listening on Talkflix',
                textAlign: TextAlign.center,
                style: theme.textTheme.titleLarge?.copyWith(
                  fontWeight: FontWeight.w900,
                ),
              ),
              const SizedBox(height: 8),
              Text(
                'Create a free account to continue listening, join the conversation, and come back to this room.',
                textAlign: TextAlign.center,
                style: theme.textTheme.bodyMedium?.copyWith(
                  color: theme.colorScheme.onSurfaceVariant,
                  height: 1.35,
                ),
              ),
              const SizedBox(height: 18),
              FilledButton(
                onPressed: _openGuestPreviewSignup,
                style: FilledButton.styleFrom(
                  minimumSize: const Size.fromHeight(48),
                ),
                child: const Text('Create free account'),
              ),
              const SizedBox(height: 8),
              TextButton(
                onPressed: _openGuestPreviewLogin,
                child: const Text('I already have an account'),
              ),
            ],
          ),
        ),
      ),
    );
  }

  Widget _buildImmersiveAudioHeader(
    ThemeData theme,
    Map<String, dynamic> room,
  ) {
    final title = '${room['title'] ?? 'Broadcast'}';
    final hostUserId = '${room['hostUserId'] ?? ''}';
    final hostIsMe = hostUserId.isNotEmpty && hostUserId == _meId;
    final hostCanBeFollowed = hostUserId.isNotEmpty && !hostIsMe;
    final followLabel = _followingHostBusy
        ? '...'
        : (hostCanBeFollowed
              ? (_isFollowingHost ? 'Following' : 'Follow')
              : '');
    final canOpenSettings =
        _isHost || _liveRoomState.permissions.canModerateRoom;

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Row(
          children: [
            Expanded(
              child: GestureDetector(
                onTap: canOpenSettings ? _openRoomSettingsScreen : null,
                child: Row(
                  children: [
                    if (_roomIsPrivate) ...[
                      Container(
                        width: 26,
                        height: 26,
                        margin: const EdgeInsets.only(right: 8),
                        decoration: BoxDecoration(
                          color: Colors.black.withValues(alpha: 0.24),
                          borderRadius: BorderRadius.circular(999),
                        ),
                        child: const Icon(
                          Icons.lock_rounded,
                          color: Colors.white,
                          size: 15,
                        ),
                      ),
                    ],
                    Expanded(
                      child: _AutoScrollingTitle(
                        text: title,
                        style: theme.textTheme.headlineSmall?.copyWith(
                          color: Colors.white,
                          fontWeight: FontWeight.w800,
                          letterSpacing: -0.3,
                          fontSize: 20,
                        ),
                      ),
                    ),
                    if (canOpenSettings) ...[
                      const SizedBox(width: 6),
                      const Icon(
                        Icons.edit_outlined,
                        color: Colors.white70,
                        size: 18,
                      ),
                    ],
                  ],
                ),
              ),
            ),
            // Host sees a heart counter; audience sees the Follow button
            if (hostIsMe) ...[
              const SizedBox(width: 8),
              _HeartCountPill(count: _heartCount),
            ] else if (hostCanBeFollowed) ...[
              const SizedBox(width: 8),
              GestureDetector(
                onTap: _followingHostBusy || _isFollowingHost
                    ? null
                    : _followHost,
                child: Container(
                  padding: const EdgeInsets.symmetric(
                    horizontal: 16,
                    vertical: 9,
                  ),
                  decoration: BoxDecoration(
                    color: _audioRoomAccent,
                    borderRadius: BorderRadius.circular(999),
                  ),
                  child: Text(
                    followLabel,
                    style: theme.textTheme.titleSmall?.copyWith(
                      color: Colors.white,
                      fontWeight: FontWeight.w800,
                      fontSize: 13,
                    ),
                  ),
                ),
              ),
            ],
            if (!_shouldUseGuestLivePreview && !_roomUsesVideo) ...[
              const SizedBox(width: 8),
              _AudioHeaderIconButton(
                icon: Icons.keyboard_arrow_down_rounded,
                tooltip: 'Minimize room',
                onTap: _minimizeAudioRoom,
              ),
            ],
          ],
        ),
      ],
    );
  }

  Widget _buildAudioRoomPages(ThemeData theme, {required bool isCommenting}) {
    final poll = _currentLivePoll;
    final pollId = '${poll?['id'] ?? ''}'.trim();
    return Column(
      children: [
        _buildAudioPageIndicator(theme),
        const SizedBox(height: 6),
        AnimatedSwitcher(
          duration: const Duration(milliseconds: 180),
          switchInCurve: Curves.easeOutCubic,
          switchOutCurve: Curves.easeInCubic,
          child: poll == null
              ? const SizedBox.shrink(key: ValueKey<String>('no-live-poll'))
              : _LivePollCard(
                  key: ValueKey<String>('live-poll-$pollId'),
                  poll: poll,
                  selectedOptionId: _myPollVoteOptionId,
                  onVote: _voteInLivePoll,
                ),
        ),
        const SizedBox(height: 6),
        Expanded(
          child: PageView(
            key: const PageStorageKey<String>('audio-room-pages'),
            controller: _audioRoomPageController,
            onPageChanged: (index) =>
                setState(() => _audioRoomPageIndex = index),
            children: [
              _buildAudioStagePage(theme),
              _buildAudioListenersPage(theme),
              _buildAudioCommentsPage(theme, isCommenting: isCommenting),
            ],
          ),
        ),
      ],
    );
  }

  Widget _buildAudioPageIndicator(ThemeData theme) {
    const labels = ['Speakers', 'Audience', 'Comments'];
    final listenerCount = _activeAudienceCount;
    return SizedBox(
      height: 34,
      child: Row(
        children: List.generate(labels.length, (index) {
          final selected = _audioRoomPageIndex == index;
          return Expanded(
            child: InkWell(
              borderRadius: BorderRadius.circular(8),
              onTap: () {
                _audioRoomPageController.animateToPage(
                  index,
                  duration: const Duration(milliseconds: 240),
                  curve: Curves.easeOutCubic,
                );
              },
              child: Column(
                mainAxisAlignment: MainAxisAlignment.end,
                children: [
                  AnimatedDefaultTextStyle(
                    duration: const Duration(milliseconds: 180),
                    curve: Curves.easeOut,
                    style:
                        theme.textTheme.labelLarge?.copyWith(
                          color: selected
                              ? Colors.white
                              : Colors.white.withValues(alpha: 0.62),
                          fontWeight: selected
                              ? FontWeight.w900
                              : FontWeight.w700,
                        ) ??
                        TextStyle(
                          color: selected
                              ? Colors.white
                              : Colors.white.withValues(alpha: 0.62),
                          fontWeight: selected
                              ? FontWeight.w900
                              : FontWeight.w700,
                        ),
                    child: Row(
                      mainAxisAlignment: MainAxisAlignment.center,
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        Text(labels[index]),
                        if (index == 1) ...[
                          const SizedBox(width: 6),
                          _ListenerCountBadge(count: listenerCount),
                        ],
                      ],
                    ),
                  ),
                  const SizedBox(height: 6),
                  AnimatedContainer(
                    duration: const Duration(milliseconds: 220),
                    curve: Curves.easeOutCubic,
                    height: 3,
                    width: selected ? 42 : 18,
                    decoration: BoxDecoration(
                      color: selected
                          ? _audioRoomAccent
                          : Colors.white.withValues(alpha: 0.16),
                      borderRadius: BorderRadius.circular(999),
                    ),
                  ),
                ],
              ),
            ),
          );
        }),
      ),
    );
  }

  Widget _buildAudioStagePage(ThemeData theme) {
    return _buildImmersiveStage(theme);
  }

  Widget _buildAudioListenersPage(ThemeData theme) {
    final listeners = _audienceMembers;
    if (listeners.isEmpty) {
      return const _AudioEmptyPage(
        icon: Icons.groups_2_outlined,
        title: 'No audience yet',
        subtitle: 'Audience members will appear here as people join the room.',
      );
    }
    return GridView.builder(
      padding: const EdgeInsets.only(bottom: 12),
      gridDelegate: const SliverGridDelegateWithMaxCrossAxisExtent(
        maxCrossAxisExtent: 150,
        mainAxisSpacing: 12,
        crossAxisSpacing: 12,
        childAspectRatio: 0.88,
      ),
      itemCount: listeners.length,
      itemBuilder: (context, index) {
        final listener = listeners[index];
        final userId = '${listener['userId'] ?? ''}';
        return _AudioParticipantTile(
          name: '${listener['name'] ?? 'Audience member'}',
          photoUrl: '${listener['photo'] ?? ''}',
          roleLabel: _moderatorIds.contains(userId) ? 'Moderator' : 'Audience',
          muted: false,
          speaking: false,
          onTap: userId.isEmpty ? null : () => _openProfile(userId),
          onLongPress: userId.isEmpty
              ? null
              : () => _onParticipantLongPress(userId),
        );
      },
    );
  }

  Widget _buildAudioCommentsPage(
    ThemeData theme, {
    required bool isCommenting,
  }) {
    if (_comments.isEmpty) {
      return const _AudioEmptyPage(
        icon: Icons.chat_bubble_outline_rounded,
        title: 'No comments yet',
        subtitle: 'Live comments will fill this screen as the room talks.',
      );
    }
    return _buildImmersiveComments(theme, condensed: isCommenting);
  }

  Widget _buildImmersiveStage(ThemeData theme) {
    final seats = _stageSlots;

    return LayoutBuilder(
      builder: (context, constraints) {
        const columns = 3;
        const rows = 4;
        final spacing = constraints.maxHeight < 500 ? 8.0 : 10.0;
        final availableHeight = constraints.maxHeight.isFinite
            ? constraints.maxHeight
            : 520.0;
        final tileHeight = ((availableHeight - (rows - 1) * spacing) / rows)
            .clamp(92.0, 148.0);
        final tileWidth =
            (constraints.maxWidth - (columns - 1) * spacing) / columns;
        final aspectRatio = tileWidth / tileHeight;
        return GridView.builder(
          padding: EdgeInsets.zero,
          physics: const NeverScrollableScrollPhysics(),
          gridDelegate: SliverGridDelegateWithFixedCrossAxisCount(
            crossAxisCount: columns,
            mainAxisSpacing: spacing,
            crossAxisSpacing: spacing,
            childAspectRatio: aspectRatio,
          ),
          itemCount: 12,
          itemBuilder: (context, index) => _buildStageSeatTile(
            index: index,
            seat: index < seats.length ? seats[index] : null,
          ),
        );
      },
    );
  }

  Widget _buildStageSeatTile({
    required int index,
    required Map<String, dynamic>? seat,
  }) {
    final isHostSeat = index == 0;
    final occupied = seat != null && seat['occupied'] != false;
    final userId = occupied ? '${seat['userId'] ?? ''}' : '';
    final isSelfSeat = occupied && userId == _meId;
    final muted = occupied
        ? (isSelfSeat ? !_localMicEnabled : seat['muted'] == true)
        : false;
    final label = occupied
        ? '${seat['name'] ?? (isHostSeat ? 'Host' : 'Speaker')}'
        : '';
    final roleLabel = isHostSeat
        ? 'Host'
        : (_moderatorIds.contains(userId) ? 'Moderator' : 'Speaker');
    return _ImmersiveSeat(
      number: index + 1,
      label: label,
      occupied: occupied,
      photoUrl: occupied ? '${seat['photo'] ?? ''}' : '',
      isHostSeat: isHostSeat,
      accentBadge: false,
      muted: muted,
      roleLabel: occupied ? roleLabel : '',
      micEffect: _stageSeatMicEffect(seat),
      speaking: occupied && !muted && _activeSpeakers.contains(userId),
      compact: true,
      onTap: occupied && userId.isNotEmpty ? () => _openProfile(userId) : null,
      onLongPress: occupied && userId.isNotEmpty
          ? () => _onParticipantLongPress(userId)
          : null,
    );
  }

  Widget _buildImmersiveComments(ThemeData theme, {required bool condensed}) {
    if (_comments.isEmpty) {
      return const SizedBox.shrink();
    }
    final orderedComments = _comments.reversed.toList(growable: false);
    final separatorSpacing = condensed ? 6.0 : 8.0;

    return ListView.separated(
      controller: _immersiveCommentsController,
      reverse: true,
      padding: EdgeInsets.zero,
      itemCount: orderedComments.length,
      separatorBuilder: (_, _) => SizedBox(height: separatorSpacing),
      itemBuilder: (context, index) {
        final comment = orderedComments[index];
        final author = '${comment['author'] ?? 'User'}';
        final text = '${comment['text'] ?? ''}';
        final userId = '${comment['userId'] ?? ''}';
        final hostUserId = _resolveHostUserId(_activeRoom ?? {});
        final isHostComment =
            userId.isNotEmpty && hostUserId.isNotEmpty && userId == hostUserId;
        final roleLabel = '${comment['roleLabel'] ?? ''}'.trim().isNotEmpty
            ? '${comment['roleLabel']}'
            : isHostComment
            ? 'Host'
            : _moderatorIds.contains(userId)
            ? 'Moderator'
            : '';
        final rawCommentTheme = '${comment['commentTheme'] ?? 'glass'}'
            .trim()
            .toLowerCase();
        final commentTheme = _liveCommentThemes.contains(rawCommentTheme)
            ? rawCommentTheme
            : 'glass';
        return _ImmersiveCommentBubble(
          author: author,
          text: text,
          photoUrl: '${comment['photo'] ?? ''}',
          system: author == 'System',
          roleLabel: roleLabel,
          commentTheme: commentTheme,
          onAvatarTap: userId.isEmpty ? null : () => _openProfile(userId),
          onAvatarLongPress: userId.isEmpty
              ? null
              : () => _onParticipantLongPress(userId),
          onLongPress: () =>
              _openLiveCommentActions(author: author, text: text),
        );
      },
    );
  }

  List<Widget> _immersiveActionButtons(ThemeData theme) {
    final isHost = _isHost;
    final pendingJoinRequestBadge = isHost && _pendingJoinRequestCount > 0
        ? _pendingJoinRequestCountLabel
        : null;
    return <Widget>[
      _SideRailButton(icon: Icons.share_outlined, onTap: _shareRoom),
      _SideRailButton(
        icon: (!isHost && !_amOnStage && _handRaised)
            ? null
            : (!isHost && _amOnStage)
            ? Icons.keyboard_arrow_down_rounded
            : Icons.front_hand_outlined,
        iconWidget: (!isHost && !_amOnStage && _handRaised)
            ? Image.asset(
                'assets/images/icons/raise_hand_active.png',
                color: Colors.white,
                colorBlendMode: BlendMode.srcIn,
              )
            : null,
        isActive: !isHost && !_amOnStage && _handRaised,
        badgeLabel: pendingJoinRequestBadge,
        onTap: isHost
            ? _openJoinRequestsSheet
            : (_amOnStage
                  ? _leaveStage
                  : (_handRaised ? _lowerHand : _raiseHand)),
      ),
      if (_isHost)
        _SideRailButton(
          icon: Icons.campaign_outlined,
          onTap: _openHostNoticeSheet,
        ),
      if (_isHost)
        _SideRailButton(icon: Icons.poll_outlined, onTap: _openHostPollSheet),
      if (_liveRoomState.permissions.canModerateRoom)
        _SideRailButton(
          icon: Icons.admin_panel_settings_outlined,
          onTap: _openModerationControlsSheet,
        ),
      if (_amOnStage)
        _SideRailButton(
          icon: _localMicEnabled
              ? Icons.mic_none_rounded
              : Icons.mic_off_rounded,
          onTap: _canUseStageMic
              ? () {
                  unawaited(_toggleStageMute());
                }
              : null,
        ),
      if (_roomUsesVideo && _amOnStage)
        _SideRailButton(
          icon: _localVideoEnabled
              ? Icons.videocam_rounded
              : Icons.videocam_off_rounded,
          onTap: () {
            unawaited(_toggleStageCamera());
          },
        ),
      if (_roomUsesVideo && _amOnStage && _localVideoEnabled)
        _SideRailButton(
          icon: Icons.cameraswitch_outlined,
          onTap: () {
            unawaited(_switchStageCamera());
          },
        ),
      if (!isHost)
        _SideRailButton(
          icon: Icons.favorite_rounded,
          onTap: () => _sendReaction('❤️'),
        ),
    ];
  }

  Widget _buildImmersiveActionButtonRail(ThemeData theme) {
    final actions = _immersiveActionButtons(theme);
    return SizedBox(
      height: 48,
      child: ListView.separated(
        scrollDirection: Axis.horizontal,
        physics: const BouncingScrollPhysics(),
        itemCount: actions.length,
        separatorBuilder: (_, _) => const SizedBox(width: 10),
        itemBuilder: (context, index) => actions[index],
      ),
    );
  }

  Widget _buildVideoRoomActionControls(ThemeData theme) {
    final expanded = _videoRoomActionsExpanded;
    return Row(
      crossAxisAlignment: CrossAxisAlignment.center,
      children: [
        Expanded(
          child: AnimatedOpacity(
            opacity: expanded ? 1 : 0,
            duration: const Duration(milliseconds: 180),
            curve: Curves.easeOutCubic,
            child: IgnorePointer(
              ignoring: !expanded,
              child: _buildImmersiveActionButtonRail(theme),
            ),
          ),
        ),
        if (expanded) ...[
          const SizedBox(width: 12),
          _LiveExitButton(
            isHost: _isHost,
            onTap: () {
              unawaited(_confirmLeaveBroadcast());
            },
          ),
        ],
        const SizedBox(width: 8),
        _VideoRoomActionsMenuButton(
          expanded: expanded,
          onTap: _toggleVideoRoomActions,
        ),
      ],
    );
  }

  Widget _buildImmersiveTopActions(ThemeData theme) {
    return Row(
      children: [
        Expanded(child: _buildImmersiveActionButtonRail(theme)),
        const SizedBox(width: 12),
        _LiveExitButton(
          isHost: _isHost,
          onTap: () {
            unawaited(_confirmLeaveBroadcast());
          },
        ),
      ],
    );
  }

  Widget _buildImmersiveComposer(
    ThemeData theme,
    String socketStatus,
    bool isCommenting,
  ) {
    final enabled = socketStatus == 'connected';
    return SafeArea(
      top: false,
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          Container(
            padding: const EdgeInsets.fromLTRB(12, 5, 8, 5),
            decoration: BoxDecoration(
              color: isCommenting
                  ? Colors.black.withValues(alpha: 0.34)
                  : _audioRoomPanel,
              borderRadius: BorderRadius.circular(20),
            ),
            child: Row(
              children: [
                Expanded(
                  child: TextField(
                    controller: _commentController,
                    focusNode: _commentFocusNode,
                    enabled: enabled,
                    maxLines: isCommenting ? 4 : 1,
                    minLines: 1,
                    maxLength: 200,
                    style: theme.textTheme.bodyMedium?.copyWith(
                      color: Colors.white,
                      fontSize: 13,
                    ),
                    textAlignVertical: TextAlignVertical.top,
                    textInputAction: TextInputAction.send,
                    inputFormatters: [LengthLimitingTextInputFormatter(200)],
                    onSubmitted: (_) => _sendComment(),
                    decoration: const InputDecoration(
                      hintText: 'Comment...',
                      hintStyle: TextStyle(color: Colors.white54),
                      border: InputBorder.none,
                      enabledBorder: InputBorder.none,
                      focusedBorder: InputBorder.none,
                      disabledBorder: InputBorder.none,
                      filled: false,
                      fillColor: Colors.transparent,
                      isDense: true,
                      counterText: '',
                    ),
                  ),
                ),
                _ComposerDockButton(
                  icon: Icons.palette_outlined,
                  badgeLabel: null,
                  onTap: _openRoomAppearanceSheet,
                ),
                _ComposerIconButton(
                  icon: Icons.send_rounded,
                  onTap: enabled ? _sendComment : null,
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }
}

typedef _SaveRoomSettingsCallback =
    Future<bool> Function({
      required String title,
      required String description,
      required String language,
      String? secondaryLanguage,
    });

typedef _ToggleModeratorCallback =
    Future<bool> Function({required String userId, required bool isModerator});

typedef _SaveRoomAppearanceCallback =
    Future<bool> Function({required String backgroundTheme});

enum _HostNoticeActionType { save, delete, send }

class _HostNoticeAction {
  const _HostNoticeAction(this.type, [this.text = '']);

  final _HostNoticeActionType type;
  final String text;
}

class _HostNoticeSheet extends StatefulWidget {
  const _HostNoticeSheet({
    required this.initialSavedText,
    required this.hasSavedNotice,
  });

  final String initialSavedText;
  final bool hasSavedNotice;

  @override
  State<_HostNoticeSheet> createState() => _HostNoticeSheetState();
}

class _HostNoticeSheetState extends State<_HostNoticeSheet> {
  late final TextEditingController _savedController;
  late final TextEditingController _oneTimeController;

  @override
  void initState() {
    super.initState();
    _savedController = TextEditingController(text: widget.initialSavedText);
    _oneTimeController = TextEditingController();
  }

  @override
  void dispose() {
    _savedController.dispose();
    _oneTimeController.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final savedText = _savedController.text.trim();
    final oneTimeText = _oneTimeController.text.trim();

    return SafeArea(
      top: false,
      child: Padding(
        padding: EdgeInsets.fromLTRB(
          16,
          0,
          16,
          MediaQuery.viewInsetsOf(context).bottom + 16,
        ),
        child: ConstrainedBox(
          constraints: BoxConstraints(
            maxHeight: MediaQuery.sizeOf(context).height * 0.88,
          ),
          child: Container(
            decoration: BoxDecoration(
              color: theme.colorScheme.surface,
              borderRadius: BorderRadius.circular(28),
            ),
            padding: const EdgeInsets.fromLTRB(20, 18, 20, 20),
            child: SingleChildScrollView(
              child: Column(
                mainAxisSize: MainAxisSize.min,
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    'Announcements',
                    style: theme.textTheme.titleLarge?.copyWith(
                      fontWeight: FontWeight.w800,
                    ),
                  ),
                  const SizedBox(height: 6),
                  Text(
                    'Set a join notice for new members, or send a one-time notice to everyone currently in the room.',
                    style: theme.textTheme.bodySmall?.copyWith(
                      color: theme.colorScheme.onSurfaceVariant,
                    ),
                  ),
                  const SizedBox(height: 18),
                  Text(
                    'Saved join notice',
                    style: theme.textTheme.titleMedium?.copyWith(
                      fontWeight: FontWeight.w800,
                    ),
                  ),
                  const SizedBox(height: 6),
                  Text(
                    'New audience members see this first when they enter.',
                    style: theme.textTheme.bodySmall?.copyWith(
                      color: theme.colorScheme.onSurfaceVariant,
                    ),
                  ),
                  const SizedBox(height: 8),
                  TextField(
                    controller: _savedController,
                    maxLength: 360,
                    minLines: 3,
                    maxLines: 5,
                    textAlignVertical: TextAlignVertical.top,
                    onChanged: (_) => setState(() {}),
                    decoration: const InputDecoration(
                      hintText: 'Write the message new members must read',
                      border: OutlineInputBorder(),
                    ),
                  ),
                  Row(
                    children: [
                      Expanded(
                        child: FilledButton.icon(
                          onPressed: savedText.isEmpty
                              ? null
                              : () => Navigator.of(context).pop(
                                  _HostNoticeAction(
                                    _HostNoticeActionType.save,
                                    savedText,
                                  ),
                                ),
                          icon: const Icon(Icons.save_outlined),
                          label: const Text('Save'),
                        ),
                      ),
                      const SizedBox(width: 10),
                      OutlinedButton.icon(
                        onPressed: widget.hasSavedNotice
                            ? () => Navigator.of(context).pop(
                                const _HostNoticeAction(
                                  _HostNoticeActionType.delete,
                                ),
                              )
                            : null,
                        icon: const Icon(Icons.delete_outline),
                        label: const Text('Delete'),
                      ),
                    ],
                  ),
                  const SizedBox(height: 22),
                  Text(
                    'One-time notice',
                    style: theme.textTheme.titleMedium?.copyWith(
                      fontWeight: FontWeight.w800,
                    ),
                  ),
                  const SizedBox(height: 6),
                  Text(
                    'Shows now only. It is not saved for future joiners.',
                    style: theme.textTheme.bodySmall?.copyWith(
                      color: theme.colorScheme.onSurfaceVariant,
                    ),
                  ),
                  const SizedBox(height: 8),
                  TextField(
                    controller: _oneTimeController,
                    maxLength: 360,
                    minLines: 3,
                    maxLines: 5,
                    textAlignVertical: TextAlignVertical.top,
                    onChanged: (_) => setState(() {}),
                    decoration: const InputDecoration(
                      hintText: 'Write a live announcement for this moment',
                      border: OutlineInputBorder(),
                    ),
                  ),
                  FilledButton.icon(
                    onPressed: oneTimeText.isEmpty
                        ? null
                        : () => Navigator.of(context).pop(
                            _HostNoticeAction(
                              _HostNoticeActionType.send,
                              oneTimeText,
                            ),
                          ),
                    style: FilledButton.styleFrom(
                      minimumSize: const Size.fromHeight(48),
                    ),
                    icon: const Icon(Icons.campaign_outlined),
                    label: const Text('Send now'),
                  ),
                ],
              ),
            ),
          ),
        ),
      ),
    );
  }
}

class _ParticipantReportResult {
  const _ParticipantReportResult({
    required this.reason,
    required this.details,
    required this.proofs,
  });

  final String reason;
  final String details;
  final List<_LiveReportProof> proofs;
}

class _LiveReportProof {
  const _LiveReportProof({
    required this.dataUrl,
    required this.bytes,
    required this.name,
    required this.mimeType,
  });

  final String dataUrl;
  final Uint8List bytes;
  final String name;
  final String mimeType;
}

class _ParticipantReportSheet extends StatefulWidget {
  const _ParticipantReportSheet({
    required this.displayName,
    required this.permissionService,
  });

  final String displayName;
  final MediaPermissionService permissionService;

  @override
  State<_ParticipantReportSheet> createState() =>
      _ParticipantReportSheetState();
}

class _ParticipantReportSheetState extends State<_ParticipantReportSheet> {
  final _reasonController = TextEditingController();
  final _detailsController = TextEditingController();
  final _imagePicker = ImagePicker();
  final List<_LiveReportProof> _proofs = <_LiveReportProof>[];

  @override
  void initState() {
    super.initState();
    _reasonController.text = 'Harassment or abuse';
  }

  @override
  void dispose() {
    _reasonController.dispose();
    _detailsController.dispose();
    super.dispose();
  }

  Future<void> _addProof(ImageSource source) async {
    final allowed = source == ImageSource.camera
        ? await widget.permissionService.ensureCameraAndMicrophone()
        : await widget.permissionService.ensurePhotos();
    if (!allowed) {
      _showSnack('Photo permission is required for report proof.');
      return;
    }
    final file = await _imagePicker.pickImage(
      source: source,
      maxWidth: 1400,
      imageQuality: 72,
    );
    if (file == null) return;
    final bytes = await file.readAsBytes();
    if (bytes.isEmpty) return;
    if (bytes.length > 1500000) {
      _showSnack('Proof photo is too large. Choose a smaller image.');
      return;
    }
    if (!mounted) return;
    setState(() {
      _proofs.add(
        _LiveReportProof(
          dataUrl: bytesToDataUrl(bytes, file.mimeType ?? 'image/jpeg'),
          bytes: bytes,
          name: file.name,
          mimeType: file.mimeType ?? 'image/jpeg',
        ),
      );
    });
  }

  void _showSnack(String message) {
    if (!mounted) return;
    ScaffoldMessenger.of(
      context,
    ).showSnackBar(SnackBar(content: Text(message)));
  }

  void _submit() {
    final reason = _reasonController.text.trim();
    final details = _detailsController.text.trim();
    if (reason.isEmpty) {
      _showSnack('Choose a report reason.');
      return;
    }
    if (_proofs.isEmpty) {
      _showSnack('Add at least one proof photo.');
      return;
    }
    Navigator.of(context).pop(
      _ParticipantReportResult(
        reason: reason,
        details: details,
        proofs: List<_LiveReportProof>.unmodifiable(_proofs),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return SafeArea(
      top: false,
      child: Padding(
        padding: EdgeInsets.fromLTRB(
          16,
          0,
          16,
          MediaQuery.viewInsetsOf(context).bottom + 16,
        ),
        child: ConstrainedBox(
          constraints: BoxConstraints(
            maxHeight: MediaQuery.sizeOf(context).height * 0.88,
          ),
          child: Container(
            decoration: BoxDecoration(
              color: theme.colorScheme.surface,
              borderRadius: BorderRadius.circular(28),
            ),
            padding: const EdgeInsets.fromLTRB(20, 18, 20, 20),
            child: SingleChildScrollView(
              child: Column(
                mainAxisSize: MainAxisSize.min,
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    'Report ${widget.displayName}',
                    style: theme.textTheme.titleLarge?.copyWith(
                      fontWeight: FontWeight.w800,
                    ),
                  ),
                  const SizedBox(height: 6),
                  Text(
                    'Reports require at least one proof photo so moderators can review what happened.',
                    style: theme.textTheme.bodySmall?.copyWith(
                      color: theme.colorScheme.onSurfaceVariant,
                    ),
                  ),
                  const SizedBox(height: 14),
                  DropdownButtonFormField<String>(
                    initialValue: _reasonController.text,
                    decoration: const InputDecoration(labelText: 'Reason'),
                    items: const [
                      DropdownMenuItem(
                        value: 'Harassment or abuse',
                        child: Text('Harassment or abuse'),
                      ),
                      DropdownMenuItem(
                        value: 'Sexual content',
                        child: Text('Sexual content'),
                      ),
                      DropdownMenuItem(
                        value: 'Hate or discrimination',
                        child: Text('Hate or discrimination'),
                      ),
                      DropdownMenuItem(
                        value: 'Scam or spam',
                        child: Text('Scam or spam'),
                      ),
                      DropdownMenuItem(
                        value: 'Underage safety concern',
                        child: Text('Underage safety concern'),
                      ),
                      DropdownMenuItem(
                        value: 'Other safety concern',
                        child: Text('Other safety concern'),
                      ),
                    ],
                    onChanged: (value) {
                      if (value != null) _reasonController.text = value;
                    },
                  ),
                  const SizedBox(height: 12),
                  TextField(
                    controller: _detailsController,
                    minLines: 3,
                    maxLines: 5,
                    maxLength: 300,
                    textAlignVertical: TextAlignVertical.top,
                    decoration: const InputDecoration(
                      labelText: 'What happened?',
                      hintText: 'Describe the violation or abuse.',
                      border: OutlineInputBorder(),
                    ),
                  ),
                  const SizedBox(height: 12),
                  Row(
                    children: [
                      Expanded(
                        child: OutlinedButton.icon(
                          onPressed: _proofs.length >= 3
                              ? null
                              : () => _addProof(ImageSource.camera),
                          icon: const Icon(Icons.photo_camera_outlined),
                          label: const Text('Camera'),
                        ),
                      ),
                      const SizedBox(width: 10),
                      Expanded(
                        child: OutlinedButton.icon(
                          onPressed: _proofs.length >= 3
                              ? null
                              : () => _addProof(ImageSource.gallery),
                          icon: const Icon(Icons.photo_library_outlined),
                          label: const Text('Gallery'),
                        ),
                      ),
                    ],
                  ),
                  const SizedBox(height: 10),
                  if (_proofs.isEmpty)
                    Text(
                      'At least one proof photo is required.',
                      style: theme.textTheme.bodySmall?.copyWith(
                        color: theme.colorScheme.error,
                        fontWeight: FontWeight.w700,
                      ),
                    )
                  else
                    Wrap(
                      spacing: 10,
                      runSpacing: 10,
                      children: [
                        for (var i = 0; i < _proofs.length; i += 1)
                          Stack(
                            children: [
                              ClipRRect(
                                borderRadius: BorderRadius.circular(14),
                                child: Image.memory(
                                  _proofs[i].bytes,
                                  width: 72,
                                  height: 72,
                                  fit: BoxFit.cover,
                                ),
                              ),
                              Positioned(
                                top: 2,
                                right: 2,
                                child: GestureDetector(
                                  onTap: () =>
                                      setState(() => _proofs.removeAt(i)),
                                  child: const CircleAvatar(
                                    radius: 11,
                                    backgroundColor: Colors.black87,
                                    child: Icon(
                                      Icons.close,
                                      size: 14,
                                      color: Colors.white,
                                    ),
                                  ),
                                ),
                              ),
                            ],
                          ),
                      ],
                    ),
                  const SizedBox(height: 18),
                  FilledButton.icon(
                    onPressed: _submit,
                    style: FilledButton.styleFrom(
                      minimumSize: const Size.fromHeight(48),
                    ),
                    icon: const Icon(Icons.report_outlined),
                    label: const Text('Submit report'),
                  ),
                ],
              ),
            ),
          ),
        ),
      ),
    );
  }
}

class _LiveRoomSettingsScreen extends StatefulWidget {
  const _LiveRoomSettingsScreen({
    required this.initialTitle,
    required this.initialDescription,
    required this.initialLanguage,
    required this.initialSecondaryLanguage,
    required this.isPrivate,
    required this.canEdit,
    required this.participants,
    required this.moderatorIds,
    required this.onSave,
    required this.onToggleModerator,
  });

  final String initialTitle;
  final String initialDescription;
  final String initialLanguage;
  final String? initialSecondaryLanguage;
  final bool isPrivate;
  final bool canEdit;
  final List<Map<String, dynamic>> participants;
  final Set<String> moderatorIds;
  final _SaveRoomSettingsCallback onSave;
  final _ToggleModeratorCallback? onToggleModerator;

  @override
  State<_LiveRoomSettingsScreen> createState() =>
      _LiveRoomSettingsScreenState();
}

class _LiveRoomSettingsScreenState extends State<_LiveRoomSettingsScreen> {
  late final TextEditingController _titleController;
  late final TextEditingController _descriptionController;
  late String _language;
  String? _secondaryLanguage;
  late Set<String> _moderatorIds;
  final Set<String> _moderatorBusyIds = <String>{};
  bool _saving = false;

  @override
  void initState() {
    super.initState();
    _titleController = TextEditingController(text: widget.initialTitle);
    _descriptionController = TextEditingController(
      text: widget.initialDescription,
    );
    _language = widget.initialLanguage;
    _secondaryLanguage = widget.initialSecondaryLanguage;
    _moderatorIds = {...widget.moderatorIds};
  }

  @override
  void dispose() {
    _titleController.dispose();
    _descriptionController.dispose();
    super.dispose();
  }

  Future<String?> _pickLanguage({
    required String title,
    String? initialValue,
    bool allowClear = false,
  }) async {
    return showModalBottomSheet<String>(
      context: context,
      showDragHandle: true,
      builder: (context) {
        final theme = Theme.of(context);
        return SafeArea(
          child: Column(
            children: [
              Padding(
                padding: const EdgeInsets.fromLTRB(20, 8, 20, 12),
                child: Row(
                  children: [
                    Expanded(
                      child: Text(
                        title,
                        style: theme.textTheme.titleLarge?.copyWith(
                          fontWeight: FontWeight.w800,
                        ),
                      ),
                    ),
                    if (allowClear)
                      TextButton(
                        onPressed: () => Navigator.of(context).pop(''),
                        child: const Text('Clear'),
                      ),
                  ],
                ),
              ),
              Expanded(
                child: ListView.builder(
                  itemCount: languageOptions.length,
                  itemBuilder: (context, index) {
                    final option = languageOptions[index];
                    final selected = option == initialValue;
                    return ListTile(
                      title: Text(option),
                      trailing: selected
                          ? const Icon(Icons.check_rounded)
                          : null,
                      onTap: () => Navigator.of(context).pop(option),
                    );
                  },
                ),
              ),
            ],
          ),
        );
      },
    );
  }

  Future<void> _handleSave() async {
    final title = _titleController.text.trim();
    if (title.isEmpty || _saving) return;
    setState(() => _saving = true);
    final saved = await widget.onSave(
      title: title,
      description: _descriptionController.text.trim(),
      language: _language,
      secondaryLanguage: _secondaryLanguage?.trim().isEmpty ?? true
          ? null
          : _secondaryLanguage?.trim(),
    );
    if (!mounted) return;
    setState(() => _saving = false);
    if (saved) {
      Navigator.of(context).pop();
    }
  }

  Future<void> _toggleModerator(
    String userId, {
    required bool nextValue,
  }) async {
    final callback = widget.onToggleModerator;
    if (callback == null || _moderatorBusyIds.contains(userId)) return;
    setState(() => _moderatorBusyIds.add(userId));
    final success = await callback(userId: userId, isModerator: nextValue);
    if (!mounted) return;
    setState(() {
      _moderatorBusyIds.remove(userId);
      if (success) {
        if (nextValue) {
          _moderatorIds.add(userId);
        } else {
          _moderatorIds.remove(userId);
        }
      }
    });
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final canEdit = widget.canEdit;
    final participants = widget.participants;

    return Scaffold(
      appBar: AppBar(
        title: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            if (widget.isPrivate) ...[
              const Icon(Icons.lock_rounded, size: 18),
              const SizedBox(width: 6),
            ],
            const Text('Room settings'),
          ],
        ),
      ),
      body: SafeArea(
        child: ListView(
          padding: const EdgeInsets.fromLTRB(16, 12, 16, 24),
          children: [
            Container(
              padding: const EdgeInsets.all(16),
              decoration: BoxDecoration(
                color: theme.colorScheme.surfaceContainerLowest,
                borderRadius: BorderRadius.circular(24),
              ),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  TextField(
                    controller: _titleController,
                    enabled: canEdit,
                    maxLength: 55,
                    decoration: const InputDecoration(labelText: 'Title'),
                  ),
                  const SizedBox(height: 8),
                  TextField(
                    controller: _descriptionController,
                    enabled: canEdit,
                    maxLength: 160,
                    minLines: 3,
                    maxLines: 4,
                    decoration: const InputDecoration(
                      labelText: 'Description',
                      hintText: 'Tell people what this room is about',
                    ),
                  ),
                  const SizedBox(height: 8),
                  ListTile(
                    contentPadding: EdgeInsets.zero,
                    enabled: canEdit,
                    leading: const Icon(Icons.language_rounded),
                    title: const Text('Primary language'),
                    subtitle: Text(_language),
                    trailing: const Icon(Icons.chevron_right_rounded),
                    onTap: !canEdit
                        ? null
                        : () async {
                            final selected = await _pickLanguage(
                              title: 'Primary language',
                              initialValue: _language,
                            );
                            if (selected != null && mounted) {
                              setState(() => _language = selected);
                            }
                          },
                  ),
                  ListTile(
                    contentPadding: EdgeInsets.zero,
                    enabled: canEdit,
                    leading: const Icon(Icons.translate_rounded),
                    title: const Text('Second language'),
                    subtitle: Text(_secondaryLanguage ?? 'Optional'),
                    trailing: Row(
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        if (_secondaryLanguage != null && canEdit)
                          IconButton(
                            onPressed: () =>
                                setState(() => _secondaryLanguage = null),
                            icon: const Icon(Icons.close_rounded),
                          ),
                        const Icon(Icons.chevron_right_rounded),
                      ],
                    ),
                    onTap: !canEdit
                        ? null
                        : () async {
                            final selected = await _pickLanguage(
                              title: 'Second language',
                              initialValue: _secondaryLanguage,
                              allowClear: true,
                            );
                            if (selected != null && mounted) {
                              setState(() {
                                _secondaryLanguage = selected.trim().isEmpty
                                    ? null
                                    : selected;
                              });
                            }
                          },
                  ),
                ],
              ),
            ),
            const SizedBox(height: 16),
            Text(
              'Moderators',
              style: theme.textTheme.titleMedium?.copyWith(
                fontWeight: FontWeight.w800,
              ),
            ),
            const SizedBox(height: 8),
            if (_moderatorIds.isEmpty)
              Text(
                'No moderators yet.',
                style: theme.textTheme.bodyMedium?.copyWith(
                  color: theme.colorScheme.onSurfaceVariant,
                ),
              )
            else
              Wrap(
                spacing: 8,
                runSpacing: 8,
                children: participants
                    .where(
                      (participant) => _moderatorIds.contains(
                        '${participant['userId'] ?? ''}',
                      ),
                    )
                    .map(
                      (participant) => Chip(
                        avatar: CircleAvatar(
                          backgroundImage:
                              '${participant['photo'] ?? ''}'.trim().isEmpty
                              ? null
                              : NetworkImage('${participant['photo'] ?? ''}'),
                          child: '${participant['photo'] ?? ''}'.trim().isEmpty
                              ? Text(
                                  ('${participant['name'] ?? 'U'}')
                                      .trim()
                                      .characters
                                      .first
                                      .toUpperCase(),
                                )
                              : null,
                        ),
                        label: Text('${participant['name'] ?? 'Moderator'}'),
                      ),
                    )
                    .toList(),
              ),
            const SizedBox(height: 12),
            Container(
              decoration: BoxDecoration(
                color: theme.colorScheme.surfaceContainerLowest,
                borderRadius: BorderRadius.circular(24),
              ),
              child: participants.isEmpty
                  ? Padding(
                      padding: const EdgeInsets.all(16),
                      child: Text(
                        'No participants are available for moderator access yet.',
                        style: theme.textTheme.bodyMedium?.copyWith(
                          color: theme.colorScheme.onSurfaceVariant,
                        ),
                      ),
                    )
                  : Column(
                      children: [
                        for (var i = 0; i < participants.length; i++) ...[
                          if (i > 0)
                            Divider(
                              height: 1,
                              indent: 16,
                              endIndent: 16,
                              color: theme.colorScheme.outlineVariant
                                  .withValues(alpha: 0.45),
                            ),
                          SwitchListTile.adaptive(
                            value: _moderatorIds.contains(
                              '${participants[i]['userId'] ?? ''}',
                            ),
                            onChanged:
                                !canEdit || widget.onToggleModerator == null
                                ? null
                                : (nextValue) => _toggleModerator(
                                    '${participants[i]['userId'] ?? ''}',
                                    nextValue: nextValue,
                                  ),
                            secondary: CircleAvatar(
                              backgroundImage:
                                  '${participants[i]['photo'] ?? ''}'
                                      .trim()
                                      .isEmpty
                                  ? null
                                  : NetworkImage(
                                      '${participants[i]['photo'] ?? ''}',
                                    ),
                              child:
                                  '${participants[i]['photo'] ?? ''}'
                                      .trim()
                                      .isEmpty
                                  ? Text(
                                      ('${participants[i]['name'] ?? 'U'}')
                                          .trim()
                                          .characters
                                          .first
                                          .toUpperCase(),
                                    )
                                  : null,
                            ),
                            title: Text('${participants[i]['name'] ?? 'User'}'),
                            subtitle: Text(
                              '${participants[i]['roomRole'] ?? 'listener'}'
                                  .toString()
                                  .replaceAll('_', ' '),
                            ),
                          ),
                        ],
                      ],
                    ),
            ),
          ],
        ),
      ),
      bottomNavigationBar: SafeArea(
        top: false,
        child: Padding(
          padding: const EdgeInsets.fromLTRB(16, 10, 16, 16),
          child: FilledButton(
            onPressed: canEdit
                ? (_saving ? null : _handleSave)
                : () => Navigator.of(context).pop(),
            style: FilledButton.styleFrom(
              minimumSize: const Size.fromHeight(52),
            ),
            child: Text(
              _saving ? 'Saving...' : (canEdit ? 'Save changes' : 'Done'),
            ),
          ),
        ),
      ),
    );
  }
}

class _LiveRoomAppearanceSheet extends StatefulWidget {
  const _LiveRoomAppearanceSheet({
    required this.initialBackgroundTheme,
    required this.initialMicEffect,
    required this.initialCommentTheme,
    required this.canEditBackground,
    required this.onSave,
    required this.onSaveMicEffect,
    required this.onSaveCommentTheme,
  });

  final String initialBackgroundTheme;
  final String initialMicEffect;
  final String initialCommentTheme;
  final bool canEditBackground;
  final _SaveRoomAppearanceCallback onSave;
  final Future<void> Function(String value) onSaveMicEffect;
  final Future<void> Function(String value) onSaveCommentTheme;

  @override
  State<_LiveRoomAppearanceSheet> createState() =>
      _LiveRoomAppearanceSheetState();
}

class _LiveRoomAppearanceSheetState extends State<_LiveRoomAppearanceSheet> {
  late String _backgroundTheme;
  late String _micEffect;
  late String _commentTheme;
  bool _saving = false;

  @override
  void initState() {
    super.initState();
    _backgroundTheme = widget.initialBackgroundTheme;
    _micEffect = widget.initialMicEffect;
    _commentTheme = widget.initialCommentTheme;
  }

  Future<void> _handleSave() async {
    if (_saving) return;
    setState(() => _saving = true);
    final saved = widget.canEditBackground
        ? await widget.onSave(backgroundTheme: _backgroundTheme)
        : true;
    if (!mounted) return;
    setState(() => _saving = false);
    if (saved) {
      await widget.onSaveMicEffect(_micEffect);
      await widget.onSaveCommentTheme(_commentTheme);
      if (!mounted) return;
      Navigator.of(context).pop();
    }
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final previewBackground = _roomBackgroundGradient(_backgroundTheme);
    final commentPalette = _commentThemePalette(_commentTheme);
    final viewport = MediaQuery.sizeOf(context);
    final bottomInset = MediaQuery.viewInsetsOf(context).bottom;
    final maxSheetHeight = viewport.height * 0.88;

    return SafeArea(
      top: false,
      child: Padding(
        padding: EdgeInsets.fromLTRB(16, 0, 16, bottomInset + 16),
        child: Container(
          constraints: BoxConstraints(maxHeight: maxSheetHeight),
          decoration: BoxDecoration(
            color: theme.colorScheme.surface,
            borderRadius: BorderRadius.circular(28),
          ),
          child: SingleChildScrollView(
            padding: const EdgeInsets.fromLTRB(20, 20, 20, 24),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  'Room theme',
                  style: theme.textTheme.titleLarge?.copyWith(
                    fontWeight: FontWeight.w800,
                  ),
                ),
                const SizedBox(height: 12),
                if (widget.canEditBackground) ...[
                  Container(
                    height: 170,
                    decoration: BoxDecoration(
                      gradient: previewBackground,
                      borderRadius: BorderRadius.circular(24),
                    ),
                    child: Padding(
                      padding: const EdgeInsets.all(16),
                      child: Align(
                        alignment: Alignment.bottomLeft,
                        child: Container(
                          constraints: const BoxConstraints(maxWidth: 250),
                          padding: const EdgeInsets.fromLTRB(14, 10, 14, 10),
                          decoration: BoxDecoration(
                            color: Colors.black.withValues(alpha: 0.32),
                            borderRadius: BorderRadius.circular(18),
                            border: Border.all(
                              color: Colors.white.withValues(alpha: 0.16),
                            ),
                          ),
                          child: Text(
                            'Room background preview',
                            style: theme.textTheme.bodyMedium?.copyWith(
                              color: Colors.white,
                              fontWeight: FontWeight.w800,
                            ),
                          ),
                        ),
                      ),
                    ),
                  ),
                  const SizedBox(height: 16),
                ],
                Center(
                  child: _PulsingRing(
                    diameter: 66,
                    effect: _micEffect,
                    child: Container(
                      width: 54,
                      height: 54,
                      decoration: BoxDecoration(
                        shape: BoxShape.circle,
                        color: Colors.white.withValues(alpha: 0.16),
                        border: Border.all(
                          color: Colors.white.withValues(alpha: 0.25),
                          width: 1.4,
                        ),
                      ),
                      alignment: Alignment.center,
                      child: const Icon(
                        Icons.mic_rounded,
                        color: Colors.white,
                        size: 26,
                      ),
                    ),
                  ),
                ),
                const SizedBox(height: 6),
                Center(
                  child: Text(
                    _micEffectLabel(_micEffect),
                    style: theme.textTheme.labelLarge?.copyWith(
                      color: theme.colorScheme.onSurfaceVariant,
                      fontWeight: FontWeight.w700,
                    ),
                  ),
                ),
                const SizedBox(height: 18),
                if (widget.canEditBackground) ...[
                  Text(
                    'Background',
                    style: theme.textTheme.titleMedium?.copyWith(
                      fontWeight: FontWeight.w700,
                    ),
                  ),
                  const SizedBox(height: 8),
                  _SegmentedPillBar(
                    options: const ['gold', 'red', 'blue', 'black'],
                    selected: _backgroundTheme,
                    onChanged: (value) =>
                        setState(() => _backgroundTheme = value),
                    labelBuilder: _backgroundThemeLabel,
                  ),
                  const SizedBox(height: 18),
                ],
                Text(
                  'Mic effect',
                  style: theme.textTheme.titleMedium?.copyWith(
                    fontWeight: FontWeight.w700,
                  ),
                ),
                const SizedBox(height: 2),
                Text(
                  'Applies only to your seat. Everyone in the room sees your choice.',
                  style: theme.textTheme.bodySmall?.copyWith(
                    color: theme.colorScheme.onSurfaceVariant,
                  ),
                ),
                const SizedBox(height: 8),
                _SegmentedPillBar(
                  options: const ['pulse', 'halo', 'echo', 'spotlight'],
                  selected: _micEffect,
                  onChanged: (value) => setState(() => _micEffect = value),
                  labelBuilder: _micEffectLabel,
                ),
                const SizedBox(height: 18),
                Text(
                  'Comment bubble',
                  style: theme.textTheme.titleMedium?.copyWith(
                    fontWeight: FontWeight.w700,
                  ),
                ),
                const SizedBox(height: 8),
                Container(
                  width: double.infinity,
                  padding: const EdgeInsets.all(14),
                  decoration: BoxDecoration(
                    color: theme.colorScheme.surfaceContainerLowest,
                    borderRadius: BorderRadius.circular(20),
                  ),
                  child: Align(
                    alignment: Alignment.centerLeft,
                    child: Container(
                      constraints: const BoxConstraints(maxWidth: 260),
                      padding: const EdgeInsets.fromLTRB(14, 10, 14, 12),
                      decoration: BoxDecoration(
                        color: commentPalette.bubbleColor,
                        borderRadius: BorderRadius.circular(20),
                        border: Border.all(color: commentPalette.borderColor),
                      ),
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        mainAxisSize: MainAxisSize.min,
                        children: [
                          Container(
                            padding: const EdgeInsets.symmetric(
                              horizontal: 8,
                              vertical: 4,
                            ),
                            decoration: BoxDecoration(
                              color: commentPalette.chipColor,
                              borderRadius: BorderRadius.circular(999),
                            ),
                            child: Text(
                              'You',
                              style: theme.textTheme.labelSmall?.copyWith(
                                color: commentPalette.chipTextColor,
                                fontWeight: FontWeight.w800,
                              ),
                            ),
                          ),
                          const SizedBox(height: 8),
                          Text(
                            'Your comments will use this bubble style.',
                            style: theme.textTheme.bodyMedium?.copyWith(
                              color: commentPalette.textColor,
                              height: 1.3,
                            ),
                          ),
                        ],
                      ),
                    ),
                  ),
                ),
                const SizedBox(height: 8),
                _SegmentedPillBar(
                  options: const ['glass', 'soft', 'aqua', 'berry', 'mint'],
                  selected: _commentTheme,
                  onChanged: (value) => setState(() => _commentTheme = value),
                  labelBuilder: _commentThemeLabel,
                ),
                const SizedBox(height: 20),
                FilledButton(
                  onPressed: _saving ? null : _handleSave,
                  style: FilledButton.styleFrom(
                    minimumSize: const Size.fromHeight(50),
                  ),
                  child: Text(_saving ? 'Saving...' : 'Apply theme'),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}

LinearGradient _roomBackgroundGradient(String themeName) {
  switch (themeName) {
    case 'black':
      return const LinearGradient(
        begin: Alignment.topLeft,
        end: Alignment.bottomRight,
        colors: [Color(0xF2000000), Color(0xF2131316), Color(0xFF000000)],
      );
    case 'red':
      return const LinearGradient(
        begin: Alignment.topLeft,
        end: Alignment.bottomRight,
        colors: [Color(0xCCE50914), Color(0xCC7A0010), Color(0xE6111113)],
      );
    case 'blue':
      return const LinearGradient(
        begin: Alignment.topLeft,
        end: Alignment.bottomRight,
        colors: [Color(0xCC2D8CFF), Color(0xCC1847A8), Color(0xE6101524)],
      );
    case 'gold':
    default:
      return const LinearGradient(
        begin: Alignment.topLeft,
        end: Alignment.bottomRight,
        colors: [Color(0xB87C4C00), Color(0xBC3A2500), Color(0xE3111113)],
      );
  }
}

String _backgroundThemeLabel(String value) {
  switch (value) {
    case 'black':
      return 'Black';
    case 'red':
      return 'Red';
    case 'blue':
      return 'Blue';
    case 'gold':
    default:
      return 'Gold';
  }
}

String _commentThemeLabel(String value) {
  switch (value) {
    case 'soft':
      return 'Soft';
    case 'aqua':
      return 'Aqua';
    case 'berry':
      return 'Berry';
    case 'mint':
      return 'Mint';
    case 'glass':
    default:
      return 'Glass';
  }
}

String _micEffectLabel(String value) {
  switch (value) {
    case 'halo':
      return 'Halo';
    case 'echo':
      return 'Echo';
    case 'spotlight':
      return 'Spot';
    case 'pulse':
    default:
      return 'Pulse';
  }
}

Color _micEffectColor(String value) {
  switch (value) {
    case 'halo':
      return const Color(0xFF22D3EE);
    case 'echo':
      return const Color(0xFFA78BFA);
    case 'spotlight':
      return const Color(0xFFFFF2B8);
    case 'pulse':
    default:
      return const Color(0xFFFFB84D);
  }
}

_CommentThemePalette _commentThemePalette(String themeName) {
  switch (themeName) {
    case 'soft':
      return const _CommentThemePalette(
        bubbleColor: Color(0xFFF4E1D4),
        textColor: Color(0xFF231512),
        chipColor: Color(0xFFD58B66),
        chipTextColor: Colors.white,
        borderColor: Color(0x5CFFFFFF),
      );
    case 'aqua':
      return const _CommentThemePalette(
        bubbleColor: Color(0x6639D1FF),
        textColor: Colors.white,
        chipColor: Color(0xFF129BC1),
        chipTextColor: Colors.white,
        borderColor: Color(0x80B7F1FF),
      );
    case 'berry':
      return const _CommentThemePalette(
        bubbleColor: Color(0x66C03AFF),
        textColor: Colors.white,
        chipColor: Color(0xFF8F2BC4),
        chipTextColor: Colors.white,
        borderColor: Color(0x70F0C2FF),
      );
    case 'mint':
      return const _CommentThemePalette(
        bubbleColor: Color(0x664DE1B8),
        textColor: Colors.white,
        chipColor: Color(0xFF1AA37E),
        chipTextColor: Colors.white,
        borderColor: Color(0x7AE4FFF6),
      );
    case 'glass':
    default:
      return const _CommentThemePalette(
        bubbleColor: Color(0x55000000),
        textColor: Colors.white,
        chipColor: Color(0xFF8B6200),
        chipTextColor: Colors.white,
        borderColor: Color(0x14FFFFFF),
      );
  }
}

class _CommentThemePalette {
  const _CommentThemePalette({
    required this.bubbleColor,
    required this.textColor,
    required this.chipColor,
    required this.chipTextColor,
    required this.borderColor,
  });

  final Color bubbleColor;
  final Color textColor;
  final Color chipColor;
  final Color chipTextColor;
  final Color borderColor;
}

class _SegmentedPillBar extends StatelessWidget {
  const _SegmentedPillBar({
    required this.options,
    required this.selected,
    required this.onChanged,
    required this.labelBuilder,
  });

  final List<String> options;
  final String selected;
  final ValueChanged<String> onChanged;
  final String Function(String) labelBuilder;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final selectedIndex = options
        .indexOf(selected)
        .clamp(0, options.length - 1);
    const trackPadding = 3.0;
    const thumbHeight = 30.0;
    final textStyle = theme.textTheme.labelLarge;

    return Container(
      padding: const EdgeInsets.all(trackPadding),
      decoration: BoxDecoration(
        borderRadius: BorderRadius.circular(10),
        color: theme.colorScheme.surfaceContainer,
        border: Border.all(
          color: theme.colorScheme.outline.withValues(alpha: 0.16),
        ),
      ),
      child: LayoutBuilder(
        builder: (context, constraints) {
          final slotWidth = constraints.maxWidth / options.length;
          return SizedBox(
            height: thumbHeight,
            child: Stack(
              children: [
                AnimatedPositioned(
                  duration: const Duration(milliseconds: 220),
                  curve: Curves.easeOutCubic,
                  left: slotWidth * selectedIndex,
                  top: 0,
                  width: slotWidth,
                  height: thumbHeight,
                  child: Padding(
                    padding: const EdgeInsets.symmetric(horizontal: 1.5),
                    child: Container(
                      decoration: BoxDecoration(
                        borderRadius: BorderRadius.circular(7),
                        color: theme.colorScheme.primary,
                        boxShadow: [
                          BoxShadow(
                            color: theme.colorScheme.primary.withValues(
                              alpha: 0.18,
                            ),
                            blurRadius: 8,
                            offset: const Offset(0, 3),
                          ),
                        ],
                      ),
                    ),
                  ),
                ),
                Row(
                  children: options.map((option) {
                    final active = option == selected;
                    return Expanded(
                      child: InkWell(
                        borderRadius: BorderRadius.circular(7),
                        onTap: () => onChanged(option),
                        child: Center(
                          child: Padding(
                            padding: const EdgeInsets.symmetric(horizontal: 8),
                            child: Row(
                              mainAxisAlignment: MainAxisAlignment.center,
                              mainAxisSize: MainAxisSize.min,
                              children: [
                                if (active) ...[
                                  Icon(
                                    Icons.check_rounded,
                                    size: 13,
                                    color: theme.colorScheme.onPrimary,
                                  ),
                                  const SizedBox(width: 4),
                                ],
                                Flexible(
                                  child: Text(
                                    labelBuilder(option),
                                    textAlign: TextAlign.center,
                                    maxLines: 1,
                                    overflow: TextOverflow.ellipsis,
                                    style: textStyle?.copyWith(
                                      color: active
                                          ? theme.colorScheme.onPrimary
                                          : theme.colorScheme.onSurfaceVariant,
                                      fontWeight: FontWeight.w800,
                                      fontSize: 12,
                                    ),
                                  ),
                                ),
                              ],
                            ),
                          ),
                        ),
                      ),
                    );
                  }).toList(),
                ),
              ],
            ),
          );
        },
      ),
    );
  }
}

class _BroadcastCard extends StatefulWidget {
  const _BroadcastCard({
    required this.roomId,
    required this.title,
    required this.type,
    required this.language,
    required this.secondaryLanguage,
    required this.description,
    required this.host,
    required this.hostPhotoUrl,
    this.speakers = const [],
    required this.audienceCount,
    required this.attendeeCount,
    required this.onJoin,
  });

  final String roomId;
  final String title;
  final String type;
  final String language;
  final String? secondaryLanguage;
  final String? description;
  final String host;
  final String hostPhotoUrl;
  final List<Map<String, dynamic>> speakers;
  final int audienceCount;
  final int attendeeCount;
  final VoidCallback? onJoin;

  @override
  State<_BroadcastCard> createState() => _BroadcastCardState();
}

class _BroadcastCardState extends State<_BroadcastCard>
    with SingleTickerProviderStateMixin {
  static const _glowPalette = <Color>[
    Color(0xFF00E676),
    Color(0xFF2196F3),
    Color(0xFFFF2D95),
    Color(0xFFFF1744),
    Color(0xFF9C27B0),
    Color(0xFFFF9800),
    Color(0xFFFFD600),
  ];

  late final AnimationController _glowController;
  late final Animation<double> _glowPulse;
  late final Color _glowColor;

  Color _colorForRoom(String roomKey) {
    final key = roomKey.trim().isNotEmpty
        ? roomKey.trim()
        : '${widget.title}|${widget.host}|${widget.type}';
    var hash = 0;
    for (final unit in key.codeUnits) {
      hash = (hash * 31 + unit) & 0x7fffffff;
    }
    return _glowPalette[hash % _glowPalette.length];
  }

  @override
  void initState() {
    super.initState();
    _glowColor = _colorForRoom(widget.roomId);
    _glowController = AnimationController(
      vsync: this,
      duration: const Duration(milliseconds: 1250),
    )..repeat(reverse: true);
    _glowPulse = CurvedAnimation(
      parent: _glowController,
      curve: Curves.easeInOutCubic,
    );
  }

  @override
  void dispose() {
    _glowController.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final colors = theme.colorScheme;
    final isDark = theme.brightness == Brightness.dark;
    final cleanDescription = widget.description?.trim() ?? '';
    final speakerCount = widget.speakers.isEmpty ? 1 : widget.speakers.length;
    final fallbackPeopleCount = widget.audienceCount + speakerCount;
    final peopleCount = math.max(widget.attendeeCount, fallbackPeopleCount);
    final cardColor = colors.surfaceContainer;
    return AnimatedBuilder(
      animation: _glowPulse,
      builder: (context, child) {
        final pulse = _glowPulse.value;
        final glowAlpha = isDark
            ? 0.42 + (pulse * 0.34)
            : 0.28 + (pulse * 0.24);
        final borderAlpha = isDark
            ? 0.72 + (pulse * 0.24)
            : 0.5 + (pulse * 0.28);
        final borderRadius = BorderRadius.circular(28);
        return DecoratedBox(
          decoration: BoxDecoration(
            borderRadius: borderRadius,
            boxShadow: [
              BoxShadow(
                color: _glowColor.withValues(alpha: glowAlpha),
                blurRadius: 30 + (pulse * 18),
                spreadRadius: 1.2 + (pulse * 1.8),
              ),
              BoxShadow(
                color: _glowColor.withValues(alpha: isDark ? 0.16 : 0.1),
                blurRadius: 64 + (pulse * 14),
                spreadRadius: 2.5 + (pulse * 1.5),
              ),
              BoxShadow(
                color: colors.shadow.withValues(alpha: isDark ? 0.28 : 0.08),
                blurRadius: 24,
                offset: const Offset(0, 12),
              ),
            ],
          ),
          child: Material(
            color: cardColor,
            borderRadius: borderRadius,
            clipBehavior: Clip.antiAlias,
            child: InkWell(
              onTap: widget.onJoin,
              borderRadius: borderRadius,
              child: Ink(
                padding: const EdgeInsets.fromLTRB(20, 18, 20, 18),
                decoration: BoxDecoration(
                  color: cardColor,
                  borderRadius: borderRadius,
                  border: Border.all(
                    color: _glowColor.withValues(alpha: borderAlpha),
                    width: 1.4 + (pulse * 0.8),
                  ),
                ),
                child: child,
              ),
            ),
          ),
        );
      },
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Expanded(
                child: Wrap(
                  spacing: 8,
                  runSpacing: 8,
                  crossAxisAlignment: WrapCrossAlignment.center,
                  children: [
                    Container(
                      padding: const EdgeInsets.symmetric(
                        horizontal: 9,
                        vertical: 5,
                      ),
                      decoration: BoxDecoration(
                        color: const Color(
                          0xFFFF3B30,
                        ).withValues(alpha: isDark ? 0.18 : 0.12),
                        borderRadius: BorderRadius.circular(999),
                      ),
                      child: Row(
                        mainAxisSize: MainAxisSize.min,
                        children: [
                          const _LivePulseDot(),
                          const SizedBox(width: 5),
                          Text(
                            'LIVE',
                            style: theme.textTheme.labelSmall?.copyWith(
                              color: const Color(0xFFFF3B30),
                              fontWeight: FontWeight.w900,
                              fontSize: 10,
                              letterSpacing: 0.5,
                            ),
                          ),
                        ],
                      ),
                    ),
                    _RoomTagPill(label: widget.language),
                    if (widget.secondaryLanguage != null)
                      _RoomTagPill(label: widget.secondaryLanguage!),
                  ],
                ),
              ),
            ],
          ),
          const SizedBox(height: 10),
          Text(
            widget.title,
            maxLines: 2,
            overflow: TextOverflow.ellipsis,
            style: theme.textTheme.titleLarge?.copyWith(
              color: colors.onSurface,
              fontWeight: FontWeight.w900,
              height: 1.08,
              fontSize: 22,
            ),
          ),
          if (cleanDescription.isNotEmpty) ...[
            const SizedBox(height: 7),
            Text(
              cleanDescription,
              maxLines: 2,
              overflow: TextOverflow.ellipsis,
              style: theme.textTheme.bodyMedium?.copyWith(
                color: colors.onSurfaceVariant,
                height: 1.25,
              ),
            ),
          ],
          const SizedBox(height: 16),
          Row(
            children: [
              _AvatarBubble(
                photoUrl: widget.hostPhotoUrl,
                size: 56,
                fallback: widget.host,
              ),
              const SizedBox(width: 14),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      widget.host,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: theme.textTheme.titleSmall?.copyWith(
                        color: colors.onSurface,
                        fontWeight: FontWeight.w800,
                      ),
                    ),
                    const SizedBox(height: 3),
                    Text(
                      widget.type == 'audio' ? 'Audio room' : 'Video room',
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: theme.textTheme.bodySmall?.copyWith(
                        color: colors.onSurfaceVariant,
                        fontWeight: FontWeight.w600,
                      ),
                    ),
                  ],
                ),
              ),
              const SizedBox(width: 12),
              _BroadcastMetric(
                icon: Icons.groups_2_outlined,
                value: compactCount(peopleCount),
              ),
            ],
          ),
        ],
      ),
    );
  }
}

class _BroadcastMetric extends StatelessWidget {
  const _BroadcastMetric({required this.icon, required this.value});

  final IconData icon;
  final String value;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Row(
      mainAxisSize: MainAxisSize.min,
      children: [
        Icon(icon, size: 16, color: theme.colorScheme.onSurfaceVariant),
        const SizedBox(width: 4),
        Text(
          value,
          style: theme.textTheme.labelLarge?.copyWith(
            color: theme.colorScheme.onSurfaceVariant,
            fontWeight: FontWeight.w800,
          ),
        ),
      ],
    );
  }
}

class _RoomTagPill extends StatelessWidget {
  const _RoomTagPill({required this.label});

  final String label;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 9, vertical: 5),
      decoration: BoxDecoration(
        color: theme.colorScheme.primary.withValues(alpha: 0.12),
        borderRadius: BorderRadius.circular(999),
      ),
      child: Text(
        label,
        maxLines: 1,
        overflow: TextOverflow.ellipsis,
        style: theme.textTheme.labelSmall?.copyWith(
          color: theme.colorScheme.primary,
          fontWeight: FontWeight.w800,
          fontSize: 10,
          letterSpacing: 0.3,
        ),
      ),
    );
  }
}

class _AudioHeaderIconButton extends StatelessWidget {
  const _AudioHeaderIconButton({
    required this.icon,
    required this.tooltip,
    required this.onTap,
  });

  final IconData icon;
  final String tooltip;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    return Tooltip(
      message: tooltip,
      child: Material(
        color: Colors.black.withValues(alpha: 0.28),
        borderRadius: BorderRadius.circular(999),
        child: InkWell(
          onTap: onTap,
          borderRadius: BorderRadius.circular(999),
          child: SizedBox(
            width: 36,
            height: 36,
            child: Icon(icon, color: Colors.white, size: 24),
          ),
        ),
      ),
    );
  }
}

class _ImmersiveSeat extends StatelessWidget {
  const _ImmersiveSeat({
    required this.number,
    required this.label,
    required this.occupied,
    required this.photoUrl,
    required this.isHostSeat,
    required this.accentBadge,
    this.roleLabel = '',
    this.speaking = false,
    this.muted = false,
    this.micEffect,
    this.compact = false,
    this.onTap,
    this.onLongPress,
  });

  final int number;
  final String label;
  final bool occupied;
  final String photoUrl;
  final bool isHostSeat;
  final bool accentBadge;
  final String roleLabel;
  final bool speaking;
  final bool muted;
  final String? micEffect;
  final bool compact;
  final VoidCallback? onTap;
  final VoidCallback? onLongPress;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final hasCustomEffect =
        micEffect != null && _liveMicEffects.contains(micEffect);
    final effectColor = hasCustomEffect ? _micEffectColor(micEffect!) : null;
    final idleBorderColor = Colors.white.withValues(alpha: 0.12);
    final activeBorderColor = speaking
        ? (effectColor ?? Colors.white.withValues(alpha: 0.78))
        : occupied
        ? (effectColor?.withValues(alpha: 0.42) ?? idleBorderColor)
        : idleBorderColor;
    final card = Container(
      padding: EdgeInsets.all(compact ? 6 : 8),
      decoration: BoxDecoration(
        color: Colors.black.withValues(alpha: occupied ? 0.22 : 0.14),
        borderRadius: BorderRadius.circular(compact ? 18 : 22),
        border: Border.all(
          color: activeBorderColor,
          width: speaking ? 2.2 : 1,
        ),
        boxShadow: occupied && hasCustomEffect
            ? [
                BoxShadow(
                  color: effectColor!.withValues(
                    alpha: speaking ? 0.32 : 0.12,
                  ),
                  blurRadius: speaking ? 24 : 14,
                  spreadRadius: speaking ? 1.4 : 0.2,
                ),
              ]
            : null,
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Expanded(
            child: Stack(
              fit: StackFit.expand,
              children: [
                ClipRRect(
                  borderRadius: BorderRadius.circular(compact ? 13 : 17),
                  child: DecoratedBox(
                    decoration: BoxDecoration(
                      color: Colors.white.withValues(alpha: 0.11),
                    ),
                    child: occupied
                        ? _SquareAvatar(
                            photoUrl: photoUrl,
                            fallback: label.isEmpty ? '$number' : label,
                          )
                        : Icon(
                            Icons.record_voice_over_rounded,
                            color: Colors.white.withValues(alpha: 0.82),
                            size: compact ? 26 : 34,
                          ),
                  ),
                ),
                Positioned(
                  left: 8,
                  top: 8,
                  child: Container(
                    padding: EdgeInsets.symmetric(
                      horizontal: compact ? 6 : 7,
                      vertical: compact ? 2 : 3,
                    ),
                    decoration: BoxDecoration(
                      color: Colors.black.withValues(alpha: 0.38),
                      borderRadius: BorderRadius.circular(999),
                    ),
                    child: Text(
                      occupied ? roleLabel : '$number',
                      style: theme.textTheme.labelSmall?.copyWith(
                        color: Colors.white,
                        fontWeight: FontWeight.w800,
                        fontSize: compact ? 8.5 : 9.5,
                      ),
                    ),
                  ),
                ),
                if (occupied)
                  Positioned(
                    right: 8,
                    top: 8,
                    child: Container(
                      width: compact ? 24 : 28,
                      height: compact ? 24 : 28,
                      decoration: BoxDecoration(
                        color: muted
                            ? const Color(0xFFB3261E)
                            : hasCustomEffect
                            ? effectColor!.withValues(alpha: 0.78)
                            : Colors.white.withValues(alpha: 0.18),
                        borderRadius: BorderRadius.circular(10),
                        boxShadow: muted || !hasCustomEffect
                            ? null
                            : [
                                BoxShadow(
                                  color: effectColor!.withValues(alpha: 0.38),
                                  blurRadius: 12,
                                  spreadRadius: 0.8,
                                ),
                              ],
                      ),
                      child: Icon(
                        muted ? Icons.mic_off_rounded : Icons.mic_rounded,
                        color: Colors.white,
                        size: compact ? 13 : 15,
                      ),
                    ),
                  ),
              ],
            ),
          ),
          SizedBox(height: compact ? 4 : 7),
          Text(
            occupied && label.isNotEmpty ? label : 'Seat $number',
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
            textAlign: TextAlign.center,
            style: theme.textTheme.labelLarge?.copyWith(
              color: Colors.white,
              fontWeight: FontWeight.w800,
              fontSize: compact ? 10.5 : 12,
            ),
          ),
        ],
      ),
    );

    if (onTap == null && onLongPress == null) return card;
    return GestureDetector(onTap: onTap, onLongPress: onLongPress, child: card);
  }
}

class _AudioParticipantTile extends StatelessWidget {
  const _AudioParticipantTile({
    required this.name,
    required this.photoUrl,
    required this.roleLabel,
    required this.muted,
    required this.speaking,
    this.onTap,
    this.onLongPress,
  });

  final String name;
  final String photoUrl;
  final String roleLabel;
  final bool muted;
  final bool speaking;
  final VoidCallback? onTap;
  final VoidCallback? onLongPress;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final card = Container(
      padding: const EdgeInsets.all(8),
      decoration: BoxDecoration(
        color: Colors.black.withValues(alpha: 0.18),
        borderRadius: BorderRadius.circular(22),
        border: Border.all(
          color: speaking
              ? _LiveScreenState._audioRoomAccent
              : Colors.white.withValues(alpha: 0.12),
          width: speaking ? 2 : 1,
        ),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Expanded(
            child: Stack(
              fit: StackFit.expand,
              children: [
                _SquareAvatar(photoUrl: photoUrl, fallback: name),
                Positioned(
                  left: 8,
                  top: 8,
                  child: Container(
                    padding: const EdgeInsets.symmetric(
                      horizontal: 7,
                      vertical: 3,
                    ),
                    decoration: BoxDecoration(
                      color: Colors.black.withValues(alpha: 0.38),
                      borderRadius: BorderRadius.circular(999),
                    ),
                    child: Text(
                      roleLabel,
                      style: theme.textTheme.labelSmall?.copyWith(
                        color: Colors.white,
                        fontWeight: FontWeight.w800,
                        fontSize: 9.5,
                      ),
                    ),
                  ),
                ),
                if (muted)
                  Positioned(
                    right: 8,
                    top: 8,
                    child: Container(
                      width: 28,
                      height: 28,
                      decoration: BoxDecoration(
                        color: const Color(0xFFB3261E),
                        borderRadius: BorderRadius.circular(10),
                      ),
                      child: const Icon(
                        Icons.mic_off_rounded,
                        color: Colors.white,
                        size: 15,
                      ),
                    ),
                  ),
              ],
            ),
          ),
          const SizedBox(height: 7),
          Text(
            name,
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
            textAlign: TextAlign.center,
            style: theme.textTheme.labelLarge?.copyWith(
              color: Colors.white,
              fontWeight: FontWeight.w800,
              fontSize: 12,
            ),
          ),
        ],
      ),
    );

    if (onTap == null && onLongPress == null) return card;
    return GestureDetector(onTap: onTap, onLongPress: onLongPress, child: card);
  }
}

class _SquareAvatar extends StatelessWidget {
  const _SquareAvatar({required this.photoUrl, required this.fallback});

  final String photoUrl;
  final String fallback;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final initials = fallback.isEmpty
        ? '?'
        : fallback
              .trim()
              .split(RegExp(r'\s+'))
              .take(2)
              .map((part) => part.isEmpty ? '' : part[0])
              .join();
    return ClipRRect(
      borderRadius: BorderRadius.circular(17),
      child: Container(
        color: Colors.white.withValues(alpha: 0.11),
        alignment: Alignment.center,
        child: photoUrl.trim().isEmpty
            ? Text(
                initials.toUpperCase(),
                style: theme.textTheme.headlineMedium?.copyWith(
                  color: Colors.white,
                  fontWeight: FontWeight.w900,
                ),
              )
            : Image.network(
                resolveMediaUrl(photoUrl),
                fit: BoxFit.cover,
                width: double.infinity,
                height: double.infinity,
                errorBuilder: (_, _, _) => Center(
                  child: Text(
                    initials.toUpperCase(),
                    style: theme.textTheme.headlineMedium?.copyWith(
                      color: Colors.white,
                      fontWeight: FontWeight.w900,
                    ),
                  ),
                ),
              ),
      ),
    );
  }
}

class _AudioEmptyPage extends StatelessWidget {
  const _AudioEmptyPage({
    required this.icon,
    required this.title,
    required this.subtitle,
  });

  final IconData icon;
  final String title;
  final String subtitle;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Center(
      child: Container(
        constraints: const BoxConstraints(maxWidth: 340),
        padding: const EdgeInsets.all(18),
        decoration: BoxDecoration(
          color: Colors.black.withValues(alpha: 0.22),
          borderRadius: BorderRadius.circular(24),
          border: Border.all(color: Colors.white.withValues(alpha: 0.1)),
        ),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(icon, color: Colors.white, size: 34),
            const SizedBox(height: 12),
            Text(
              title,
              textAlign: TextAlign.center,
              style: theme.textTheme.titleMedium?.copyWith(
                color: Colors.white,
                fontWeight: FontWeight.w900,
              ),
            ),
            const SizedBox(height: 6),
            Text(
              subtitle,
              textAlign: TextAlign.center,
              style: theme.textTheme.bodySmall?.copyWith(
                color: Colors.white70,
                height: 1.35,
              ),
            ),
          ],
        ),
      ),
    );
  }
}

class _ImmersiveCommentBubble extends StatelessWidget {
  const _ImmersiveCommentBubble({
    required this.author,
    required this.text,
    required this.photoUrl,
    required this.system,
    required this.commentTheme,
    this.roleLabel = '',
    this.onAvatarTap,
    this.onAvatarLongPress,
    this.onLongPress,
  });

  final String author;
  final String text;
  final String photoUrl;
  final bool system;
  final String commentTheme;
  final String roleLabel;
  final VoidCallback? onAvatarTap;
  final VoidCallback? onAvatarLongPress;
  final VoidCallback? onLongPress;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final palette = _commentThemePalette(commentTheme);
    final bubbleColor = palette.bubbleColor;
    final authorChipColor = palette.chipColor;
    final bodyTextColor = palette.textColor;
    final authorTextColor = palette.chipTextColor;
    final bubble = GestureDetector(
      onLongPress: onLongPress,
      child: Container(
        constraints: const BoxConstraints(maxWidth: 520),
        padding: const EdgeInsets.fromLTRB(14, 10, 14, 12),
        decoration: BoxDecoration(
          color: bubbleColor,
          borderRadius: BorderRadius.circular(20),
          border: Border.all(color: palette.borderColor),
        ),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Wrap(
              spacing: 6,
              runSpacing: 6,
              crossAxisAlignment: WrapCrossAlignment.center,
              children: [
                Container(
                  padding: const EdgeInsets.symmetric(
                    horizontal: 8,
                    vertical: 4,
                  ),
                  decoration: BoxDecoration(
                    color: authorChipColor,
                    borderRadius: BorderRadius.circular(999),
                  ),
                  child: Text(
                    system ? 'Notice' : author,
                    style: theme.textTheme.titleSmall?.copyWith(
                      color: authorTextColor,
                      fontWeight: FontWeight.w700,
                      fontSize: 11,
                    ),
                  ),
                ),
                if (!system && roleLabel.trim().isNotEmpty)
                  Container(
                    padding: const EdgeInsets.symmetric(
                      horizontal: 8,
                      vertical: 4,
                    ),
                    decoration: BoxDecoration(
                      color: Colors.white.withValues(alpha: 0.16),
                      borderRadius: BorderRadius.circular(999),
                      border: Border.all(
                        color: Colors.white.withValues(alpha: 0.18),
                      ),
                    ),
                    child: Text(
                      roleLabel,
                      style: theme.textTheme.titleSmall?.copyWith(
                        color: bodyTextColor,
                        fontWeight: FontWeight.w800,
                        fontSize: 10,
                      ),
                    ),
                  ),
              ],
            ),
            const SizedBox(height: 6),
            Text(
              text,
              style: theme.textTheme.titleLarge?.copyWith(
                color: bodyTextColor,
                height: 1.32,
                fontWeight: FontWeight.w400,
                fontSize: 13,
              ),
            ),
          ],
        ),
      ),
    );

    if (system) {
      return Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Container(
            width: 40,
            height: 40,
            margin: const EdgeInsets.only(top: 8),
            decoration: const BoxDecoration(
              color: _LiveScreenState._audioRoomAccent,
              shape: BoxShape.circle,
            ),
            child: const Icon(
              Icons.campaign_rounded,
              color: Colors.white,
              size: 22,
            ),
          ),
          const SizedBox(width: 8),
          Flexible(child: bubble),
        ],
      );
    }

    return Row(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        ParticipantActionTarget(
          onTap: onAvatarTap,
          onLongPress: onAvatarLongPress,
          child: _AvatarBubble(photoUrl: photoUrl, size: 32, fallback: author),
        ),
        const SizedBox(width: 8),
        Flexible(child: bubble),
      ],
    );
  }
}

class _VideoRoomActionsMenuButton extends StatelessWidget {
  const _VideoRoomActionsMenuButton({
    required this.expanded,
    required this.onTap,
  });

  final bool expanded;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    return Material(
      color: Colors.transparent,
      child: InkWell(
        onTap: () {
          HapticFeedback.selectionClick();
          onTap();
        },
        borderRadius: BorderRadius.circular(12),
        child: AnimatedContainer(
          duration: const Duration(milliseconds: 180),
          curve: Curves.easeOutCubic,
          width: 36,
          height: 36,
          decoration: BoxDecoration(
            color: expanded
                ? Colors.white.withValues(alpha: 0.14)
                : Colors.white.withValues(alpha: 0.06),
            borderRadius: BorderRadius.circular(12),
            border: Border.all(
              color: expanded
                  ? Colors.white.withValues(alpha: 0.22)
                  : Colors.white.withValues(alpha: 0.1),
            ),
          ),
          alignment: Alignment.center,
          child: Icon(
            Icons.apps_rounded,
            size: 20,
            color: Colors.white.withValues(alpha: expanded ? 0.92 : 0.62),
          ),
        ),
      ),
    );
  }
}

class _LiveExitButton extends StatelessWidget {
  const _LiveExitButton({required this.isHost, required this.onTap});

  final bool isHost;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final label = isHost ? 'End' : 'Leave';
    final icon = isHost ? Icons.stop_rounded : Icons.logout_rounded;
    return Material(
      color: Colors.transparent,
      child: InkWell(
        onTap: () {
          HapticFeedback.mediumImpact();
          onTap();
        },
        borderRadius: BorderRadius.circular(14),
        child: Ink(
          height: 48,
          padding: const EdgeInsets.symmetric(horizontal: 14),
          decoration: BoxDecoration(
            gradient: const LinearGradient(
              begin: Alignment.topCenter,
              end: Alignment.bottomCenter,
              colors: [
                _LiveScreenState._liveExitRedBright,
                _LiveScreenState._liveExitRed,
              ],
            ),
            borderRadius: BorderRadius.circular(14),
            border: Border.all(color: Colors.white.withValues(alpha: 0.22)),
            boxShadow: [
              BoxShadow(
                color: _LiveScreenState._liveExitRed.withValues(alpha: 0.45),
                blurRadius: 12,
                offset: const Offset(0, 4),
              ),
            ],
          ),
          child: Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              Icon(icon, color: Colors.white, size: 20),
              const SizedBox(width: 6),
              Text(
                label,
                style: const TextStyle(
                  color: Colors.white,
                  fontWeight: FontWeight.w700,
                  fontSize: 13,
                  letterSpacing: 0.2,
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

class _SideRailButton extends StatelessWidget {
  const _SideRailButton({
    this.icon,
    this.iconWidget,
    this.onTap,
    this.badgeLabel,
    this.isActive = false,
  }) : assert(
         icon != null || iconWidget != null,
         '_SideRailButton requires icon or iconWidget',
       );

  final IconData? icon;

  /// Optional custom widget rendered instead of [icon]. Wrap in [Opacity] for
  /// disabled appearance — the button handles it automatically.
  final Widget? iconWidget;
  final VoidCallback? onTap;
  final String? badgeLabel;
  final bool isActive;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final enabled = onTap != null;
    return Material(
      color: Colors.transparent,
      child: Stack(
        clipBehavior: Clip.none,
        children: [
          InkWell(
            onTap: onTap == null
                ? null
                : () {
                    HapticFeedback.selectionClick();
                    onTap?.call();
                  },
            borderRadius: BorderRadius.circular(14),
            child: AnimatedScale(
              duration: const Duration(milliseconds: 180),
              curve: Curves.easeOutCubic,
              scale: isActive ? 1 : 0.96,
              child: AnimatedContainer(
                duration: const Duration(milliseconds: 180),
                curve: Curves.easeOut,
                width: 48,
                height: 48,
                decoration: BoxDecoration(
                  color: isActive
                      ? _LiveScreenState._audioRoomAccent
                      : Colors.white12,
                  borderRadius: BorderRadius.circular(14),
                  border: Border.all(
                    color: isActive ? Colors.white24 : Colors.white10,
                  ),
                  boxShadow: isActive
                      ? [
                          BoxShadow(
                            color: _LiveScreenState._audioRoomAccent.withValues(
                              alpha: 0.35,
                            ),
                            blurRadius: 14,
                            offset: const Offset(0, 6),
                          ),
                        ]
                      : null,
                ),
                alignment: Alignment.center,
                child: iconWidget != null
                    ? Opacity(
                        opacity: enabled ? 1.0 : 0.38,
                        child: SizedBox(
                          width: 24,
                          height: 24,
                          child: iconWidget,
                        ),
                      )
                    : Icon(
                        icon!,
                        color: enabled ? Colors.white : Colors.white54,
                        size: 22,
                      ),
              ),
            ),
          ),
          if (badgeLabel != null)
            Positioned(
              right: -2,
              top: -2,
              child: Container(
                padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 2),
                constraints: const BoxConstraints(minWidth: 18),
                decoration: BoxDecoration(
                  color: theme.colorScheme.primary,
                  borderRadius: BorderRadius.circular(999),
                ),
                alignment: Alignment.center,
                child: Text(
                  badgeLabel!,
                  style: theme.textTheme.labelSmall?.copyWith(
                    color: theme.colorScheme.onPrimary,
                    fontWeight: FontWeight.w800,
                    fontSize: 10,
                  ),
                ),
              ),
            ),
        ],
      ),
    );
  }
}

class _ComposerIconButton extends StatelessWidget {
  const _ComposerIconButton({required this.icon, this.onTap});

  final IconData icon;
  final VoidCallback? onTap;

  @override
  Widget build(BuildContext context) {
    return IconButton(
      onPressed: onTap,
      visualDensity: VisualDensity.compact,
      icon: Icon(icon, color: Colors.white, size: 24),
    );
  }
}

class _ComposerDockButton extends StatelessWidget {
  const _ComposerDockButton({
    required this.icon,
    required this.onTap,
    this.badgeLabel,
  });

  final IconData icon;
  final VoidCallback? onTap;
  final String? badgeLabel;

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.only(left: 10),
      child: Stack(
        clipBehavior: Clip.none,
        children: [
          GestureDetector(
            onTap: onTap == null
                ? null
                : () {
                    HapticFeedback.selectionClick();
                    onTap?.call();
                  },
            child: AnimatedScale(
              duration: const Duration(milliseconds: 160),
              curve: Curves.easeOutCubic,
              scale: onTap == null ? 0.95 : 1,
              child: Container(
                width: 46,
                height: 46,
                decoration: BoxDecoration(
                  color: Colors.black.withValues(alpha: 0.3),
                  shape: BoxShape.circle,
                ),
                alignment: Alignment.center,
                child: Icon(icon, color: Colors.white, size: 24),
              ),
            ),
          ),
          if (badgeLabel != null)
            Positioned(
              right: -3,
              top: -3,
              child: Container(
                padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 2),
                decoration: const BoxDecoration(
                  color: Color(0xFFFF3B77),
                  borderRadius: BorderRadius.all(Radius.circular(999)),
                ),
                child: Text(
                  badgeLabel!,
                  style: Theme.of(context).textTheme.labelSmall?.copyWith(
                    color: Colors.white,
                    fontWeight: FontWeight.w800,
                    fontSize: 9,
                  ),
                ),
              ),
            ),
        ],
      ),
    );
  }
}

class _JoinRequestRow extends StatelessWidget {
  const _JoinRequestRow({
    required this.name,
    required this.photoUrl,
    required this.onAccept,
  });

  final String name;
  final String photoUrl;
  final VoidCallback onAccept;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Container(
      padding: const EdgeInsets.all(14),
      decoration: BoxDecoration(
        color: theme.colorScheme.surfaceContainerHighest,
        borderRadius: BorderRadius.circular(22),
      ),
      child: Row(
        children: [
          _AvatarBubble(photoUrl: photoUrl, size: 42, fallback: name),
          const SizedBox(width: 12),
          Expanded(
            child: Text(
              name,
              style: theme.textTheme.titleSmall?.copyWith(
                fontWeight: FontWeight.w700,
              ),
            ),
          ),
          FilledButton(onPressed: onAccept, child: const Text('Accept')),
        ],
      ),
    );
  }
}

class _ShareRoomActionTile extends StatelessWidget {
  const _ShareRoomActionTile({
    required this.icon,
    required this.title,
    required this.subtitle,
    required this.onTap,
  });

  final IconData icon;
  final String title;
  final String subtitle;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return ListTile(
      contentPadding: EdgeInsets.zero,
      leading: Container(
        width: 46,
        height: 46,
        decoration: BoxDecoration(
          color: theme.colorScheme.primary.withValues(alpha: 0.12),
          borderRadius: BorderRadius.circular(16),
        ),
        child: Icon(icon, color: theme.colorScheme.primary),
      ),
      title: Text(
        title,
        style: theme.textTheme.titleMedium?.copyWith(
          fontWeight: FontWeight.w800,
        ),
      ),
      subtitle: Text(subtitle),
      trailing: const Icon(Icons.chevron_right_rounded),
      onTap: onTap,
    );
  }
}

class _ListenerCountBadge extends StatelessWidget {
  const _ListenerCountBadge({required this.count});

  final int count;

  @override
  Widget build(BuildContext context) {
    final label = compactCount(count);
    return Container(
      constraints: const BoxConstraints(minWidth: 22),
      padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 2),
      decoration: BoxDecoration(
        color: Colors.white.withValues(alpha: 0.16),
        borderRadius: BorderRadius.circular(999),
        border: Border.all(color: Colors.white.withValues(alpha: 0.12)),
      ),
      alignment: Alignment.center,
      child: Text(
        label,
        style: const TextStyle(
          color: Colors.white,
          fontWeight: FontWeight.w900,
          fontSize: 10,
          height: 1,
        ),
      ),
    );
  }
}

class _LivePollCard extends StatelessWidget {
  const _LivePollCard({
    super.key,
    required this.poll,
    required this.selectedOptionId,
    required this.onVote,
  });

  final Map<String, dynamic> poll;
  final String? selectedOptionId;
  final ValueChanged<String> onVote;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final question = '${poll['question'] ?? ''}'.trim();
    final options = (poll['options'] as List<dynamic>? ?? const [])
        .whereType<Map>()
        .map((item) => Map<String, dynamic>.from(item))
        .toList(growable: false);
    final totalVotes =
        (poll['totalVotes'] as num?)?.toInt() ??
        options.fold<int>(
          0,
          (sum, option) => sum + ((option['votes'] as num?)?.toInt() ?? 0),
        );
    final concluded =
        '${poll['status'] ?? 'active'}'.trim().toLowerCase() == 'concluded';
    if (question.isEmpty || options.isEmpty) return const SizedBox.shrink();

    return Container(
      padding: const EdgeInsets.all(12),
      decoration: BoxDecoration(
        color: Colors.black.withValues(alpha: 0.32),
        borderRadius: BorderRadius.circular(18),
        border: Border.all(color: Colors.white.withValues(alpha: 0.12)),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        mainAxisSize: MainAxisSize.min,
        children: [
          Row(
            children: [
              const Icon(Icons.poll_outlined, color: Colors.white, size: 18),
              const SizedBox(width: 8),
              Expanded(
                child: Text(
                  question,
                  maxLines: 2,
                  overflow: TextOverflow.ellipsis,
                  style: theme.textTheme.titleSmall?.copyWith(
                    color: Colors.white,
                    fontWeight: FontWeight.w900,
                  ),
                ),
              ),
              Container(
                padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
                decoration: BoxDecoration(
                  color: concluded
                      ? _LiveScreenState._audioRoomAccent.withValues(
                          alpha: 0.24,
                        )
                      : Colors.white.withValues(alpha: 0.12),
                  borderRadius: BorderRadius.circular(999),
                ),
                child: Text(
                  concluded ? 'Final result' : '$totalVotes votes',
                  style: theme.textTheme.labelSmall?.copyWith(
                    color: Colors.white,
                    fontWeight: FontWeight.w800,
                  ),
                ),
              ),
            ],
          ),
          const SizedBox(height: 10),
          for (final option in options) ...[
            _LivePollOptionRow(
              option: option,
              totalVotes: totalVotes,
              selected: '${option['id'] ?? ''}' == selectedOptionId,
              enabled: !concluded,
              onTap: concluded ? null : () => onVote('${option['id'] ?? ''}'),
            ),
            const SizedBox(height: 8),
          ],
        ],
      ),
    );
  }
}

class _LivePollOptionRow extends StatelessWidget {
  const _LivePollOptionRow({
    required this.option,
    required this.totalVotes,
    required this.selected,
    required this.enabled,
    required this.onTap,
  });

  final Map<String, dynamic> option;
  final int totalVotes;
  final bool selected;
  final bool enabled;
  final VoidCallback? onTap;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final text = '${option['text'] ?? ''}'.trim();
    final votes = (option['votes'] as num?)?.toInt() ?? 0;
    final percent = totalVotes <= 0 ? 0.0 : votes / totalVotes;
    return InkWell(
      onTap: enabled ? onTap : null,
      borderRadius: BorderRadius.circular(12),
      child: Stack(
        children: [
          Positioned.fill(
            child: ClipRRect(
              borderRadius: BorderRadius.circular(12),
              child: FractionallySizedBox(
                alignment: Alignment.centerLeft,
                widthFactor: percent.clamp(0.0, 1.0),
                child: ColoredBox(
                  color: _LiveScreenState._audioRoomAccent.withValues(
                    alpha: selected ? 0.46 : 0.26,
                  ),
                ),
              ),
            ),
          ),
          Container(
            padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 9),
            decoration: BoxDecoration(
              borderRadius: BorderRadius.circular(12),
              border: Border.all(
                color: selected
                    ? _LiveScreenState._audioRoomAccent
                    : Colors.white.withValues(alpha: 0.12),
              ),
            ),
            child: Row(
              children: [
                Icon(
                  selected
                      ? Icons.check_circle_rounded
                      : Icons.radio_button_unchecked_rounded,
                  color: Colors.white,
                  size: 18,
                ),
                const SizedBox(width: 8),
                Expanded(
                  child: Text(
                    text,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: theme.textTheme.labelLarge?.copyWith(
                      color: Colors.white,
                      fontWeight: FontWeight.w800,
                    ),
                  ),
                ),
                const SizedBox(width: 8),
                Text(
                  '${(percent * 100).round()}%',
                  style: theme.textTheme.labelMedium?.copyWith(
                    color: Colors.white,
                    fontWeight: FontWeight.w900,
                  ),
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }
}

class _UnderlineTabData {
  const _UnderlineTabData({
    required this.value,
    required this.label,
    required this.icon,
  });

  final String value;
  final String label;
  final IconData icon;
}

class _UnderlineTabSwitch extends StatelessWidget {
  const _UnderlineTabSwitch({
    required this.tabs,
    required this.selected,
    required this.onChanged,
  });

  final List<_UnderlineTabData> tabs;
  final String selected;
  final ValueChanged<String> onChanged;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Row(
      children: tabs.map((tab) {
        final active = tab.value == selected;
        return Expanded(
          child: InkWell(
            onTap: () => onChanged(tab.value),
            borderRadius: BorderRadius.circular(12),
            child: Padding(
              padding: const EdgeInsets.only(bottom: 2),
              child: Column(
                mainAxisSize: MainAxisSize.min,
                children: [
                  Row(
                    mainAxisAlignment: MainAxisAlignment.center,
                    children: [
                      Icon(
                        tab.icon,
                        size: 18,
                        color: active
                            ? theme.colorScheme.onSurface
                            : theme.colorScheme.onSurfaceVariant,
                      ),
                      const SizedBox(width: 8),
                      Flexible(
                        child: Text(
                          tab.label,
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                          style: theme.textTheme.titleSmall?.copyWith(
                            color: active
                                ? theme.colorScheme.onSurface
                                : theme.colorScheme.onSurfaceVariant,
                            fontWeight: FontWeight.w800,
                          ),
                        ),
                      ),
                    ],
                  ),
                  const SizedBox(height: 10),
                  AnimatedContainer(
                    duration: const Duration(milliseconds: 180),
                    curve: Curves.easeOut,
                    height: 3,
                    width: active ? 64 : 24,
                    decoration: BoxDecoration(
                      color: active
                          ? theme.colorScheme.primary
                          : theme.colorScheme.outline.withValues(alpha: 0.18),
                      borderRadius: BorderRadius.circular(999),
                    ),
                  ),
                ],
              ),
            ),
          ),
        );
      }).toList(),
    );
  }
}

class _AvatarBubble extends StatelessWidget {
  const _AvatarBubble({
    required this.photoUrl,
    required this.size,
    required this.fallback,
  });

  final String photoUrl;
  final double size;
  final String fallback;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final initials = fallback.isEmpty
        ? '?'
        : fallback
              .trim()
              .split(RegExp(r'\s+'))
              .take(2)
              .map((part) => part[0])
              .join();
    return Container(
      width: size,
      height: size,
      decoration: BoxDecoration(
        color: theme.colorScheme.surfaceContainerHighest,
        shape: BoxShape.circle,
        image: photoUrl.isNotEmpty
            ? DecorationImage(
                image: NetworkImage(resolveMediaUrl(photoUrl)),
                fit: BoxFit.cover,
              )
            : null,
      ),
      alignment: Alignment.center,
      child: photoUrl.isNotEmpty
          ? null
          : Text(
              initials.toUpperCase(),
              style: theme.textTheme.titleMedium?.copyWith(
                fontWeight: FontWeight.w800,
              ),
            ),
    );
  }
}

class _PulsingRing extends StatefulWidget {
  const _PulsingRing({
    required this.child,
    this.diameter = 80,
    this.effect = 'pulse',
  });

  final Widget child;
  final double diameter;
  final String effect;

  @override
  State<_PulsingRing> createState() => _PulsingRingState();
}

class _PulsingRingState extends State<_PulsingRing>
    with SingleTickerProviderStateMixin {
  late final AnimationController _controller;
  late final Animation<double> _scale;
  late final Animation<double> _opacity;

  @override
  void initState() {
    super.initState();
    _controller = AnimationController(
      vsync: this,
      duration: const Duration(milliseconds: 1200),
    )..repeat(reverse: true);
    _scale = Tween<double>(
      begin: 1.0,
      end: 1.15,
    ).animate(CurvedAnimation(parent: _controller, curve: Curves.easeInOut));
    _opacity = Tween<double>(
      begin: 0.7,
      end: 0.0,
    ).animate(CurvedAnimation(parent: _controller, curve: Curves.easeInOut));
  }

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return AnimatedBuilder(
      animation: _controller,
      builder: (context, child) {
        final effectColor = _micEffectColor(widget.effect);
        final pulse = _controller.value;
        final glowAlpha = 0.34 + (pulse * 0.28);
        final borderAlpha = 0.62 + (pulse * 0.28);
        final ringColor = effectColor.withValues(alpha: borderAlpha);
        final baseScale = widget.effect == 'halo' ? 1.0 : _scale.value;
        return Stack(
          alignment: Alignment.center,
          children: [
            Transform.scale(
              scale: 1.1 + (pulse * 0.1),
              child: Container(
                width: widget.diameter,
                height: widget.diameter,
                decoration: BoxDecoration(
                  shape: BoxShape.circle,
                  boxShadow: [
                    BoxShadow(
                      color: effectColor.withValues(alpha: glowAlpha),
                      blurRadius: 28 + (pulse * 18),
                      spreadRadius: 1.4 + (pulse * 2.4),
                    ),
                    BoxShadow(
                      color: effectColor.withValues(alpha: 0.16 + pulse * 0.1),
                      blurRadius: 66 + (pulse * 18),
                      spreadRadius: 4 + (pulse * 3),
                    ),
                  ],
                ),
              ),
            ),
            if (widget.effect == 'spotlight')
              Opacity(
                opacity: 0.48 + (pulse * 0.24),
                child: Container(
                  width: widget.diameter * 1.56,
                  height: widget.diameter * 1.56,
                  decoration: BoxDecoration(
                    shape: BoxShape.circle,
                    gradient: RadialGradient(
                      colors: [
                        effectColor.withValues(alpha: 0.48),
                        effectColor.withValues(alpha: 0.16),
                        Colors.transparent,
                      ],
                    ),
                  ),
                ),
              ),
            Transform.scale(
              scale: baseScale,
              child: Container(
                width: widget.diameter,
                height: widget.diameter,
                decoration: BoxDecoration(
                  shape: BoxShape.circle,
                  border: Border.all(
                    color: ringColor,
                    width: widget.effect == 'halo' ? 4.6 : 3.2,
                  ),
                  boxShadow: [
                    BoxShadow(
                      color: effectColor.withValues(alpha: 0.48 + pulse * 0.2),
                      blurRadius: 16 + (pulse * 10),
                      spreadRadius: widget.effect == 'halo' ? 2.5 : 0.8,
                    ),
                  ],
                ),
              ),
            ),
            if (widget.effect == 'echo')
              Transform.scale(
                scale: 1.08 + (_scale.value - 1.0) * 1.3,
                child: Opacity(
                  opacity: (_opacity.value * 0.55).clamp(0.0, 1.0),
                  child: Container(
                    width: widget.diameter,
                    height: widget.diameter,
                    decoration: BoxDecoration(
                      shape: BoxShape.circle,
                      border: Border.all(
                        color: effectColor.withValues(
                          alpha: (0.42 + pulse * 0.28).clamp(0.0, 1.0),
                        ),
                        width: 2.4,
                      ),
                      boxShadow: [
                        BoxShadow(
                          color: effectColor.withValues(alpha: 0.28),
                          blurRadius: 28,
                          spreadRadius: 1.5,
                        ),
                      ],
                    ),
                  ),
                ),
              ),
            child!,
          ],
        );
      },
      child: widget.child,
    );
  }
}

class _ReportStatRow extends StatelessWidget {
  const _ReportStatRow({
    required this.icon,
    required this.label,
    required this.value,
  });

  final IconData icon;
  final String label;
  final String value;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 12),
      decoration: BoxDecoration(
        color: theme.colorScheme.surfaceContainerHighest,
        borderRadius: BorderRadius.circular(16),
      ),
      child: Row(
        children: [
          Icon(icon, size: 20, color: theme.colorScheme.primary),
          const SizedBox(width: 12),
          Text(
            label,
            style: theme.textTheme.bodyMedium?.copyWith(
              color: theme.colorScheme.onSurfaceVariant,
            ),
          ),
          const Spacer(),
          Text(
            value,
            style: theme.textTheme.titleMedium?.copyWith(
              fontWeight: FontWeight.w800,
            ),
          ),
        ],
      ),
    );
  }
}

// ---------------------------------------------------------------------------
// Create Broadcast Sheet
// ---------------------------------------------------------------------------

class _CreateBroadcastSheet extends ConsumerStatefulWidget {
  const _CreateBroadcastSheet({
    required this.initialType,
    required this.initialLanguage,
    required this.onGoLive,
  });

  final String initialType;
  final String initialLanguage;
  final Future<bool> Function(
    String title, {
    required String type,
    String? description,
    required String language,
    String? secondLanguage,
    bool isPrivate,
  })
  onGoLive;

  @override
  ConsumerState<_CreateBroadcastSheet> createState() =>
      _CreateBroadcastSheetState();
}

class _CreateBroadcastSheetState extends ConsumerState<_CreateBroadcastSheet> {
  late final TextEditingController _titleController;
  late final TextEditingController _descriptionController;
  late String _type;
  late String _language;
  String? _secondLanguage;
  bool _private = false;
  bool _submitting = false;

  static const int _titleMax = 55;

  @override
  void initState() {
    super.initState();
    _titleController = TextEditingController();
    _descriptionController = TextEditingController();
    _type = widget.initialType;
    _language = widget.initialLanguage;
    _titleController.addListener(() => setState(() {}));
  }

  @override
  void dispose() {
    _titleController.dispose();
    _descriptionController.dispose();
    super.dispose();
  }

  Future<String?> _pickLanguage({
    required String title,
    String? initialValue,
  }) async {
    final searchController = TextEditingController();
    var query = '';
    var selected = initialValue ?? '';

    final result = await showModalBottomSheet<String>(
      context: context,
      isScrollControlled: true,
      backgroundColor: Colors.transparent,
      builder: (sheetCtx) {
        final theme = Theme.of(sheetCtx);
        return StatefulBuilder(
          builder: (ctx, localSetState) {
            final filtered = languageOptions
                .where(
                  (lang) =>
                      query.isEmpty ||
                      lang.toLowerCase().contains(query.toLowerCase()),
                )
                .toList();
            return Padding(
              padding: EdgeInsets.fromLTRB(
                16,
                16,
                16,
                MediaQuery.of(ctx).viewInsets.bottom + 16,
              ),
              child: Container(
                height: MediaQuery.of(ctx).size.height * 0.72,
                decoration: BoxDecoration(
                  color: theme.colorScheme.surface,
                  borderRadius: BorderRadius.circular(30),
                ),
                padding: const EdgeInsets.fromLTRB(18, 18, 18, 12),
                child: Column(
                  children: [
                    Row(
                      children: [
                        Text(
                          title,
                          style: theme.textTheme.titleLarge?.copyWith(
                            fontWeight: FontWeight.w800,
                          ),
                        ),
                        const Spacer(),
                        IconButton(
                          onPressed: () => Navigator.of(
                            ctx,
                          ).pop(selected.isEmpty ? null : selected),
                          icon: const Icon(Icons.close),
                        ),
                      ],
                    ),
                    TextField(
                      controller: searchController,
                      onChanged: (value) => localSetState(() => query = value),
                      decoration: const InputDecoration(
                        hintText: 'Search language',
                        prefixIcon: Icon(Icons.search),
                      ),
                    ),
                    const SizedBox(height: 12),
                    Expanded(
                      child: ListView.builder(
                        itemCount: filtered.length,
                        itemBuilder: (ctx, index) {
                          final lang = filtered[index];
                          final active = lang == selected;
                          return ListTile(
                            onTap: () => localSetState(() => selected = lang),
                            title: Text(lang),
                            trailing: active
                                ? Icon(
                                    Icons.check_circle,
                                    color: theme.colorScheme.primary,
                                  )
                                : null,
                          );
                        },
                      ),
                    ),
                    const SizedBox(height: 8),
                    FilledButton(
                      onPressed: selected.isEmpty
                          ? null
                          : () => Navigator.of(ctx).pop(selected),
                      style: FilledButton.styleFrom(
                        minimumSize: const Size.fromHeight(52),
                      ),
                      child: const Text('Done'),
                    ),
                  ],
                ),
              ),
            );
          },
        );
      },
    );

    searchController.dispose();
    return result;
  }

  Future<void> _submit() async {
    final title = _titleController.text.trim();
    if (_submitting || title.isEmpty) return;
    setState(() => _submitting = true);
    final success = await widget.onGoLive(
      _titleController.text,
      type: _type,
      description: _descriptionController.text.trim().isEmpty
          ? null
          : _descriptionController.text.trim(),
      language: _language,
      secondLanguage: _secondLanguage,
      isPrivate: _private,
    );
    if (!mounted) return;
    setState(() => _submitting = false);
    if (success) Navigator.of(context).pop();
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final me = ref.read(sessionControllerProvider).user;
    final isProLike = me?.isProLike == true;
    final titleLength = _titleController.text.length;

    return Padding(
      padding: EdgeInsets.fromLTRB(
        16,
        16,
        16,
        MediaQuery.of(context).viewInsets.bottom + 16,
      ),
      child: ConstrainedBox(
        constraints: BoxConstraints(
          maxHeight: MediaQuery.of(context).size.height * 0.88,
        ),
        child: Container(
          decoration: BoxDecoration(
            color: theme.colorScheme.surface,
            borderRadius: BorderRadius.circular(32),
            boxShadow: [
              BoxShadow(
                color: Colors.black.withValues(alpha: 0.18),
                blurRadius: 24,
                offset: const Offset(0, 12),
              ),
            ],
          ),
          padding: const EdgeInsets.fromLTRB(20, 20, 20, 24),
          child: SingleChildScrollView(
            child: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                // Header
                Row(
                  children: [
                    Container(
                      width: 40,
                      height: 40,
                      decoration: BoxDecoration(
                        color: theme.colorScheme.primaryContainer,
                        borderRadius: BorderRadius.circular(12),
                      ),
                      child: Icon(
                        _type == 'audio'
                            ? Icons.mic_rounded
                            : Icons.videocam_rounded,
                        color: theme.colorScheme.primary,
                        size: 20,
                      ),
                    ),
                    const SizedBox(width: 12),
                    Text(
                      'Create Broadcast',
                      style: theme.textTheme.headlineSmall?.copyWith(
                        fontWeight: FontWeight.w700,
                      ),
                    ),
                    const Spacer(),
                    IconButton(
                      onPressed: () => Navigator.of(context).pop(),
                      icon: const Icon(Icons.close),
                    ),
                  ],
                ),
                const SizedBox(height: 16),
                // Type selector
                _SegmentedPillBar(
                  options: const ['audio', 'video'],
                  selected: _type,
                  onChanged: (value) => setState(() => _type = value),
                  labelBuilder: (value) => value == 'audio' ? 'Audio' : 'Video',
                ),
                const SizedBox(height: 16),
                // Title + description
                Container(
                  width: double.infinity,
                  padding: const EdgeInsets.fromLTRB(14, 14, 14, 8),
                  decoration: BoxDecoration(
                    color: theme.colorScheme.surfaceContainerLowest,
                    borderRadius: BorderRadius.circular(24),
                  ),
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      TextField(
                        controller: _titleController,
                        maxLength: _titleMax,
                        textInputAction: TextInputAction.next,
                        style: theme.textTheme.bodyMedium?.copyWith(
                          fontSize: 14,
                        ),
                        decoration: InputDecoration(
                          labelText: 'Broadcast title',
                          hintText: 'Give your room a title',
                          counterText: '',
                          labelStyle: theme.textTheme.bodySmall?.copyWith(
                            fontSize: 12.5,
                          ),
                          hintStyle: theme.textTheme.bodySmall?.copyWith(
                            fontSize: 12.5,
                            color: theme.colorScheme.onSurfaceVariant,
                          ),
                        ),
                      ),
                      Padding(
                        padding: const EdgeInsets.only(top: 6, bottom: 4),
                        child: Row(
                          children: [
                            Expanded(
                              child: ClipRRect(
                                borderRadius: BorderRadius.circular(2),
                                child: LinearProgressIndicator(
                                  value: titleLength / _titleMax,
                                  minHeight: 3,
                                  backgroundColor: theme
                                      .colorScheme
                                      .outlineVariant
                                      .withValues(alpha: 0.4),
                                  valueColor: AlwaysStoppedAnimation(
                                    titleLength > _titleMax * 0.9
                                        ? theme.colorScheme.error
                                        : theme.colorScheme.primary,
                                  ),
                                ),
                              ),
                            ),
                            const SizedBox(width: 8),
                            Text(
                              '$titleLength/$_titleMax',
                              style: theme.textTheme.labelSmall?.copyWith(
                                fontSize: 10.5,
                                color: titleLength > _titleMax * 0.9
                                    ? theme.colorScheme.error
                                    : theme.colorScheme.onSurfaceVariant,
                              ),
                            ),
                          ],
                        ),
                      ),
                      const SizedBox(height: 4),
                      TextField(
                        controller: _descriptionController,
                        maxLength: 160,
                        textInputAction: TextInputAction.done,
                        maxLines: 3,
                        minLines: 2,
                        style: theme.textTheme.bodyMedium?.copyWith(
                          fontSize: 13.5,
                        ),
                        decoration: InputDecoration(
                          labelText: 'Description (Optional)',
                          hintText: 'Tell people what this broadcast is about',
                          labelStyle: theme.textTheme.bodySmall?.copyWith(
                            fontSize: 12.5,
                          ),
                          hintStyle: theme.textTheme.bodySmall?.copyWith(
                            fontSize: 12.25,
                            color: theme.colorScheme.onSurfaceVariant,
                          ),
                          counterStyle: theme.textTheme.labelSmall?.copyWith(
                            fontSize: 10.5,
                          ),
                        ),
                      ),
                    ],
                  ),
                ),
                const SizedBox(height: 12),
                // Language section
                Container(
                  width: double.infinity,
                  padding: const EdgeInsets.symmetric(
                    horizontal: 14,
                    vertical: 4,
                  ),
                  decoration: BoxDecoration(
                    color: theme.colorScheme.surfaceContainerLowest,
                    borderRadius: BorderRadius.circular(24),
                  ),
                  child: Column(
                    children: [
                      ListTile(
                        contentPadding: EdgeInsets.zero,
                        dense: true,
                        visualDensity: const VisualDensity(
                          horizontal: -1,
                          vertical: -2.5,
                        ),
                        onTap: () async {
                          final selected = await _pickLanguage(
                            title: 'Primary language',
                            initialValue: _language,
                          );
                          if (selected != null && mounted) {
                            setState(() => _language = selected);
                          }
                        },
                        leading: Container(
                          padding: const EdgeInsets.all(6),
                          decoration: BoxDecoration(
                            color: theme.colorScheme.primaryContainer,
                            borderRadius: BorderRadius.circular(8),
                          ),
                          child: Icon(
                            Icons.language_rounded,
                            size: 16,
                            color: theme.colorScheme.primary,
                          ),
                        ),
                        title: Text(
                          'Primary language',
                          style: theme.textTheme.bodySmall?.copyWith(
                            fontSize: 11,
                            color: theme.colorScheme.onSurfaceVariant,
                          ),
                        ),
                        subtitle: Text(
                          _language,
                          style: theme.textTheme.bodyMedium?.copyWith(
                            fontSize: 13.5,
                            fontWeight: FontWeight.w600,
                          ),
                        ),
                        trailing: const Icon(Icons.chevron_right, size: 20),
                      ),
                      Divider(
                        height: 1,
                        color: theme.colorScheme.outlineVariant.withValues(
                          alpha: 0.5,
                        ),
                      ),
                      ListTile(
                        contentPadding: EdgeInsets.zero,
                        dense: true,
                        visualDensity: const VisualDensity(
                          horizontal: -1,
                          vertical: -2.5,
                        ),
                        onTap: () async {
                          final selected = await _pickLanguage(
                            title: 'Second language',
                            initialValue: _secondLanguage,
                          );
                          if (mounted) {
                            setState(() => _secondLanguage = selected);
                          }
                        },
                        leading: Container(
                          padding: const EdgeInsets.all(6),
                          decoration: BoxDecoration(
                            color: _secondLanguage != null
                                ? theme.colorScheme.secondaryContainer
                                : theme.colorScheme.surfaceContainerHigh,
                            borderRadius: BorderRadius.circular(8),
                          ),
                          child: Icon(
                            Icons.translate_rounded,
                            size: 16,
                            color: _secondLanguage != null
                                ? theme.colorScheme.secondary
                                : theme.colorScheme.onSurfaceVariant,
                          ),
                        ),
                        title: Text(
                          'Second language',
                          style: theme.textTheme.bodySmall?.copyWith(
                            fontSize: 11,
                            color: theme.colorScheme.onSurfaceVariant,
                          ),
                        ),
                        subtitle: Text(
                          _secondLanguage ?? 'Optional — tap to add',
                          style: theme.textTheme.bodyMedium?.copyWith(
                            fontSize: 13.5,
                            fontWeight: _secondLanguage != null
                                ? FontWeight.w600
                                : FontWeight.w400,
                            color: _secondLanguage != null
                                ? null
                                : theme.colorScheme.onSurfaceVariant,
                            fontStyle: _secondLanguage != null
                                ? FontStyle.normal
                                : FontStyle.italic,
                          ),
                        ),
                        trailing: _secondLanguage != null
                            ? IconButton(
                                onPressed: () =>
                                    setState(() => _secondLanguage = null),
                                icon: Icon(
                                  Icons.cancel_rounded,
                                  color: theme.colorScheme.onSurfaceVariant,
                                  size: 20,
                                ),
                              )
                            : const Icon(Icons.chevron_right, size: 20),
                      ),
                    ],
                  ),
                ),
                const SizedBox(height: 12),
                // Private broadcast toggle
                Container(
                  width: double.infinity,
                  padding: const EdgeInsets.symmetric(
                    horizontal: 14,
                    vertical: 4,
                  ),
                  decoration: BoxDecoration(
                    color: theme.colorScheme.surfaceContainerLowest,
                    borderRadius: BorderRadius.circular(24),
                  ),
                  child: InkWell(
                    borderRadius: BorderRadius.circular(20),
                    onTap: isProLike
                        ? () => setState(() => _private = !_private)
                        : () async {
                            await showProAccessSheet(
                              context: context,
                              ref: ref,
                              featureName: 'Private Broadcast',
                              onUnlocked: () {
                                if (mounted) {
                                  setState(() => _private = true);
                                }
                              },
                            );
                          },
                    child: Padding(
                      padding: const EdgeInsets.symmetric(vertical: 8),
                      child: Row(
                        children: [
                          Expanded(
                            child: Column(
                              crossAxisAlignment: CrossAxisAlignment.start,
                              children: [
                                Row(
                                  children: [
                                    Text(
                                      'Private broadcast',
                                      style: theme.textTheme.titleSmall
                                          ?.copyWith(
                                            fontSize: 13.5,
                                            fontWeight: FontWeight.w700,
                                          ),
                                    ),
                                    const SizedBox(width: 8),
                                    const ProFeatureBadge(compact: true),
                                  ],
                                ),
                                const SizedBox(height: 4),
                                Text(
                                  'Only Pro hosts can turn on private rooms.',
                                  style: theme.textTheme.bodySmall?.copyWith(
                                    fontSize: 11.75,
                                    color: theme.colorScheme.onSurfaceVariant,
                                  ),
                                ),
                              ],
                            ),
                          ),
                          const SizedBox(width: 12),
                          IgnorePointer(
                            child: SizedBox(
                              height: 30,
                              child: Transform.scale(
                                scale: 0.82,
                                child: Switch(
                                  value: _private,
                                  onChanged: (_) {},
                                  materialTapTargetSize:
                                      MaterialTapTargetSize.shrinkWrap,
                                  thumbIcon:
                                      WidgetStateProperty.resolveWith<Icon?>((
                                        states,
                                      ) {
                                        if (states.contains(
                                          WidgetState.selected,
                                        )) {
                                          return const Icon(
                                            Icons.check_rounded,
                                            size: 14,
                                          );
                                        }
                                        return null;
                                      }),
                                ),
                              ),
                            ),
                          ),
                        ],
                      ),
                    ),
                  ),
                ),
                const SizedBox(height: 20),
                // Go live button
                FilledButton.icon(
                  onPressed: _submitting || _titleController.text.trim().isEmpty
                      ? null
                      : _submit,
                  style: FilledButton.styleFrom(
                    minimumSize: const Size.fromHeight(52),
                    textStyle: theme.textTheme.labelLarge?.copyWith(
                      fontSize: 15,
                      fontWeight: FontWeight.w700,
                    ),
                  ),
                  icon: _submitting
                      ? const SizedBox(
                          width: 18,
                          height: 18,
                          child: CircularProgressIndicator(
                            strokeWidth: 2,
                            color: Colors.white,
                          ),
                        )
                      : Icon(
                          _type == 'audio'
                              ? Icons.mic_rounded
                              : Icons.videocam_rounded,
                          size: 18,
                        ),
                  label: Text(_submitting ? 'Going live...' : 'Go live'),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}

class _AutoScrollingTitle extends StatefulWidget {
  const _AutoScrollingTitle({required this.text, this.style});

  final String text;
  final TextStyle? style;

  @override
  State<_AutoScrollingTitle> createState() => _AutoScrollingTitleState();
}

class _AutoScrollingTitleState extends State<_AutoScrollingTitle>
    with SingleTickerProviderStateMixin {
  static const _gap = 36.0;
  static const _pixelsPerSecond = 38.0;
  static const _initialDelay = Duration(milliseconds: 650);

  late final AnimationController _controller;
  Timer? _startTimer;
  bool _overflowing = false;
  double _cycleDistance = 0;

  @override
  void initState() {
    super.initState();
    _controller = AnimationController(vsync: this);
  }

  @override
  void didUpdateWidget(covariant _AutoScrollingTitle oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.text != widget.text || oldWidget.style != widget.style) {
      _overflowing = false;
      _startTimer?.cancel();
      _controller
        ..stop()
        ..value = 0;
    }
  }

  @override
  void dispose() {
    _startTimer?.cancel();
    _controller.dispose();
    super.dispose();
  }

  Size _measureTextSize(
    String text,
    TextStyle style,
    TextDirection direction,
    TextScaler scaler,
  ) {
    final painter = TextPainter(
      text: TextSpan(text: text, style: style),
      textDirection: direction,
      textScaler: scaler,
      maxLines: 1,
    )..layout(minWidth: 0, maxWidth: double.infinity);
    return painter.size;
  }

  void _updateAnimation({
    required bool overflowing,
    required double cycleDistance,
  }) {
    if (!overflowing) {
      _startTimer?.cancel();
      if (_overflowing || _controller.isAnimating || _controller.value != 0) {
        _controller
          ..stop()
          ..value = 0;
      }
      _overflowing = false;
      return;
    }

    final needsRestart =
        !_overflowing || (_cycleDistance - cycleDistance).abs() > 0.5;
    _overflowing = true;
    _cycleDistance = cycleDistance;
    if (!needsRestart) return;

    final durationMs = ((cycleDistance / _pixelsPerSecond) * 1000)
        .round()
        .clamp(1200, 240000);
    _controller.duration = Duration(milliseconds: durationMs);
    _controller
      ..stop()
      ..value = 0;

    _startTimer?.cancel();
    _startTimer = Timer(_initialDelay, () {
      if (!mounted || !_overflowing || _controller.duration == null) return;
      _controller.repeat();
    });
  }

  @override
  Widget build(BuildContext context) {
    final baseStyle = DefaultTextStyle.of(context).style;
    final style = baseStyle.merge(widget.style);
    final direction = Directionality.of(context);
    final scaler = MediaQuery.textScalerOf(context);

    return LayoutBuilder(
      builder: (context, constraints) {
        if (!constraints.maxWidth.isFinite || constraints.maxWidth <= 0) {
          return Text(
            widget.text,
            style: style,
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
          );
        }

        final textSize = _measureTextSize(
          widget.text,
          style,
          direction,
          scaler,
        );
        final textWidth = textSize.width;
        final titleHeight = textSize.height.ceilToDouble();
        final overflowing = textWidth > constraints.maxWidth + 1;
        final cycleDistance = textWidth + _gap;
        final repeatedTrackWidth = (textWidth * 2) + _gap;
        _updateAnimation(
          overflowing: overflowing,
          cycleDistance: cycleDistance,
        );

        if (!overflowing) {
          return SizedBox(
            width: constraints.maxWidth,
            height: titleHeight,
            child: Text(
              widget.text,
              style: style,
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              softWrap: false,
            ),
          );
        }

        return SizedBox(
          width: constraints.maxWidth,
          height: titleHeight,
          child: ClipRect(
            child: AnimatedBuilder(
              animation: _controller,
              child: SizedBox(
                width: repeatedTrackWidth,
                height: titleHeight,
                child: Row(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    Text(
                      widget.text,
                      style: style,
                      maxLines: 1,
                      softWrap: false,
                      overflow: TextOverflow.visible,
                    ),
                    const SizedBox(width: _gap),
                    Text(
                      widget.text,
                      style: style,
                      maxLines: 1,
                      softWrap: false,
                      overflow: TextOverflow.visible,
                    ),
                  ],
                ),
              ),
              builder: (context, child) {
                final dx = -_controller.value * cycleDistance;
                return Stack(
                  clipBehavior: Clip.hardEdge,
                  children: [
                    Positioned(
                      left: dx,
                      top: 0,
                      width: repeatedTrackWidth,
                      height: titleHeight,
                      child: child!,
                    ),
                  ],
                );
              },
            ),
          ),
        );
      },
    );
  }
}

class _LivePulseDot extends StatefulWidget {
  const _LivePulseDot();

  @override
  State<_LivePulseDot> createState() => _LivePulseDotState();
}

class _LivePulseDotState extends State<_LivePulseDot>
    with SingleTickerProviderStateMixin {
  late final AnimationController _controller;

  @override
  void initState() {
    super.initState();
    _controller = AnimationController(
      vsync: this,
      duration: const Duration(milliseconds: 1000),
    )..repeat(reverse: true);
  }

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return AnimatedBuilder(
      animation: _controller,
      builder: (context, _) {
        return Container(
          width: 8,
          height: 8,
          decoration: BoxDecoration(
            shape: BoxShape.circle,
            color: const Color(
              0xFFFF3B30,
            ).withValues(alpha: 0.4 + 0.6 * _controller.value),
          ),
        );
      },
    );
  }
}

/// Animated pill that shows the host's cumulative heart count.
class _HeartCountPill extends StatefulWidget {
  const _HeartCountPill({required this.count});
  final int count;

  @override
  State<_HeartCountPill> createState() => _HeartCountPillState();
}

class _HeartCountPillState extends State<_HeartCountPill>
    with SingleTickerProviderStateMixin {
  late final AnimationController _ctrl;
  late final Animation<double> _scale;

  @override
  void initState() {
    super.initState();
    _ctrl = AnimationController(
      vsync: this,
      duration: const Duration(milliseconds: 220),
    );
    _scale = TweenSequence<double>([
      TweenSequenceItem(tween: Tween(begin: 1.0, end: 1.28), weight: 40),
      TweenSequenceItem(tween: Tween(begin: 1.28, end: 1.0), weight: 60),
    ]).animate(CurvedAnimation(parent: _ctrl, curve: Curves.easeOut));
  }

  @override
  void didUpdateWidget(_HeartCountPill old) {
    super.didUpdateWidget(old);
    if (widget.count != old.count && widget.count > 0) {
      _ctrl.forward(from: 0);
    }
  }

  @override
  void dispose() {
    _ctrl.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final label = widget.count >= 1000
        ? '${(widget.count / 1000).toStringAsFixed(1)}k'
        : '${widget.count}';
    return ScaleTransition(
      scale: _scale,
      child: Container(
        padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
        decoration: BoxDecoration(
          color: Colors.black.withValues(alpha: 0.35),
          borderRadius: BorderRadius.circular(999),
        ),
        child: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            const Icon(Icons.favorite_rounded, color: Colors.white, size: 16),
            const SizedBox(width: 5),
            Text(
              label,
              style: const TextStyle(
                color: Colors.white,
                fontWeight: FontWeight.w800,
                fontSize: 13,
              ),
            ),
          ],
        ),
      ),
    );
  }
}
