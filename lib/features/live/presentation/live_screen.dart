import 'dart:async';
import 'dart:developer' as developer;
import 'dart:math' as math;

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_webrtc/flutter_webrtc.dart';
import 'package:go_router/go_router.dart';

import '../../../app/theme/app_theme.dart';
import '../../../core/auth/session_controller.dart';
import '../../../core/config/app_config.dart';
import '../../../core/media/media_permission_service.dart';
import '../../../core/media/media_utils.dart';
import '../../../core/network/api_client.dart';
import '../../../core/realtime/socket_service.dart';
import '../../../core/realtime/webrtc_service.dart';
import '../../../core/widgets/participant_action_target.dart';
import '../../../core/widgets/realtime_warning_banner.dart';
import '../data/live_audio_service.dart';
import '../application/live_room_controller.dart';
import '../domain/live_role.dart';
import '../../auth/data/signup_options.dart';
import '../../upgrade/presentation/pro_access_sheet.dart';
import 'flying_reactions.dart';

final liveAudioRoomActiveProvider = StateProvider<bool>((ref) => false);
final liveModeProvider = StateProvider<String>((ref) => 'broadcast');
final liveBrowseTypeProvider = StateProvider<String>((ref) => 'audio');
final liveBroadcastCacheProvider = StateProvider<List<Map<String, dynamic>>>(
  (ref) => const [],
);

class LiveScreen extends ConsumerStatefulWidget {
  const LiveScreen({super.key});

  @override
  ConsumerState<LiveScreen> createState() => _LiveScreenState();
}

class _LiveScreenState extends ConsumerState<LiveScreen> {
  final _permissionService = MediaPermissionService();
  final _liveAudioService = LiveAudioService();
  final _commentController = TextEditingController();
  final _commentFocusNode = FocusNode();
  final _immersiveCommentsController = ScrollController();
  final _reactionController = StreamController<String>.broadcast();
  static const _audioRoomBackground = Color(0xFF111315);
  static const _audioRoomPanel = Color(0xFF1A1D21);
  static const _audioRoomBubble = Color(0xFF1C1F24);
  static const _audioRoomAccent = talkflixPrimary;
  static const _audioRoomChip = Color(0xFF93000A);
  RTCVideoRenderer? _localRenderer;
  final Map<String, RTCVideoRenderer> _remoteRenderers = {};
  final Map<String, RTCPeerConnection> _peerConnections = {};
  final Map<String, String> _peerStates = {};
  final Map<String, List<RTCIceCandidate>> _pendingIce = {};
  final Set<String> _remoteDescriptionReady = <String>{};
  bool _syncingRtc = false;
  bool _syncRtcPending = false;
  Timer? _rtcSyncDebounceTimer;
  Timer? _speakingProbeTimer;
  Timer? _speakingEmitTimer;
  Timer? _audioRecoveryTimer;
  Timer? _roomHealthTimer;
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
  static const int _rtcTransitionLogLimit = 20;
  static const _rtcSyncDebounceWindow = Duration(milliseconds: 180);
  static const _speakingEmitMinInterval = Duration(milliseconds: 850);
  static const _speakingProbeInterval = Duration(milliseconds: 700);

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
  bool _loadingList = true;
  bool _creating = false;
  bool _handRaised = false;
  bool _rejoiningRoom = false;
  bool _localRendererReady = false;
  bool _socketBound = false;
  // Stored during _bindSocket so dispose() can clean up without touching ref.
  SocketService? _socketRef;
  int _broadcastRequestToken = 0;
  bool _localMicEnabled = true;
  bool _localVideoEnabled = false;
  bool _didInitializeStageMic = false;
  bool _wasOnStage = false;
  bool _isFollowingHost = false;
  bool _followingHostBusy = false;
  String _socketStatus = 'disconnected';
  String _liveMode = 'broadcast';
  String _browseType = 'audio';
  String _language = 'English';
  final Set<String> _activeSpeakers = {};

  @override
  void initState() {
    super.initState();
    _liveMode = ref.read(liveModeProvider);
    _browseType = ref.read(liveBrowseTypeProvider);
    final cached = ref.read(liveBroadcastCacheProvider);
    if (cached.isNotEmpty) {
      _broadcasts = cached;
      _loadingList = false;
    }
    _socketStatus = _socket.status;
    _socket.addListener(_handleSocketStatusChanged);
    _commentFocusNode.addListener(_handleCommentFocusChanged);
    _bindSocket();
  }

  @override
  void dispose() {
    ref.read(liveAudioRoomActiveProvider.notifier).state = false;
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
    for (final timer in _speakingDecayTimers.values) {
      timer.cancel();
    }
    _speakingDecayTimers.clear();
    _commentController.dispose();
    _immersiveCommentsController.dispose();
    unawaited(_reactionController.close());
    unawaited(_liveAudioService.disconnect());
    unawaited(_disposeRtc());
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
    if (mounted) setState(() {});
  }

  void _syncRoomChromeState() {
    ref.read(liveAudioRoomActiveProvider.notifier).state =
        _activeRoom != null && '${_activeRoom?['type'] ?? 'audio'}' == 'audio';
    ref
        .read(liveRoomControllerProvider.notifier)
        .hydrate(
          room: _activeRoom,
          meId: _meId,
          localMicEnabled: _localMicEnabled,
        );
    _syncRoomHealthMonitor();
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
    return normalized;
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

  Future<bool> _ensureVerifiedLiveSocket({
    bool showError = true,
  }) async {
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
    _socket.on('live:reaction', _onReaction);
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
    _socket.off('live:reaction', _onReaction);
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
    if (emoji.isNotEmpty) _reactionController.add(emoji);
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
        _joinRequests =
            (broadcast['joinRequests'] as List<dynamic>? ?? const [])
                .whereType<Map>()
                .map((item) => Map<String, dynamic>.from(item))
                .toList();
      }
    });
    _cacheBroadcasts(_broadcasts);
    _syncRoomChromeState();
    if (_activeRoom != null &&
        '${_activeRoom!['id']}' == '${broadcast['id']}') {
      if (_usesSfuAudioPath) {
        unawaited(_refreshLiveAudioPublishState());
      }
      _queueRtcSync();
      unawaited(_refreshHostFollowState(broadcast));
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
        _activeRoomVersion = 0;
        _activeSpeakerVersion = 0;
        _comments = const [];
        _joinRequests = const [];
        _handRaised = false;
        _commentController.clear();
        _isFollowingHost = false;
        _followingHostBusy = false;
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
        }
      }
    });
    if (accepted) {
      if (_usesSfuAudioPath) {
        final joined = await _completeApprovedStageJoin();
        if (!joined || !mounted) return;
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(content: Text("You're on stage. Mic is off.")),
        );
      } else {
        ScaffoldMessenger.of(
          context,
        ).showSnackBar(const SnackBar(content: Text('You are now on stage')));
        await _syncRtcParticipants();
        _syncStageMuteState();
      }
    } else {
      ScaffoldMessenger.of(
        context,
      ).showSnackBar(const SnackBar(content: Text('Stage request declined')));
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
                ? '${payload['message'] ?? 'Unable to join stage right now'}'
                : 'Stage join timed out. Please try again.',
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
      _recordRtcTransition('sfu_media_session ignored (already connected)');
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

  bool get _usesSfuAudioPath => !_roomUsesVideo && AppConfig.liveUseSfuAudio;

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
      developer.log(
        '[LIVE][SFU] connect attempt room="${room['id']}" canPublish=$canPublish url="$url" tokenLen=${token.length}',
        name: 'live_screen',
      );
      try {
        await _liveAudioService.connect(
          url: url,
          token: token,
          roomName: roomId,
          canPublish: canPublish,
        );
        _recordRtcTransition('sfu_connect ok publish=$canPublish');
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
    _recordRtcTransition('sfu_publish set=$micEnabled');
    try {
      await _liveAudioService.setPublishing(micEnabled);
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
    if (me == null ||
        title.trim().isEmpty ||
        _creating) {
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
      if ('${broadcast['type'] ?? 'audio'}' == 'audio') {
        unawaited(Helper.setSpeakerphoneOn(true));
      }
      if (_usesSfuAudioPath) {
        await _connectLiveAudioSfu(room: broadcast, mediaSession: mediaSession);
        await _refreshLiveAudioPublishState();
      } else {
        await _syncRtcParticipants();
      }
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
      unawaited(_refreshHostFollowState(broadcast));
      if ('${broadcast['type'] ?? 'audio'}' == 'audio') {
        unawaited(Helper.setSpeakerphoneOn(true));
      }
      if (_usesSfuAudioPath) {
        await _connectLiveAudioSfu(room: broadcast, mediaSession: mediaSession);
        await _refreshLiveAudioPublishState();
      } else {
        await _syncRtcParticipants();
        unawaited(_refreshRoomTopologyAfterJoin());
      }
      return;
    }
    if (payload is Map && payload['code'] == 'auth_identity_mismatch') {
      _recoverFromLiveIdentityMismatch(
        '${payload['message'] ?? 'Realtime session mismatch detected.'}',
      );
      _recordRtcTransition('join_broadcast identity_mismatch');
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

  Future<void> _refreshRoomTopologyAfterJoin() async {
    // Some backends return a minimal join payload first, then fill speaker/host
    // topology shortly after. Refresh once to avoid silent listener joins.
    await Future<void>.delayed(const Duration(milliseconds: 900));
    if (!mounted || _activeRoom == null) return;
    await _refreshActiveRoomViaJoin();
    if (_enrichActiveRoomFromBroadcasts()) {
      _recordRtcTransition('topology_enriched_from_list');
    }
    if (!mounted || _activeRoom == null) return;
    await _syncRtcParticipants();
  }

  Future<void> _leaveBroadcast() async {
    final room = _activeRoom;
    if (room == null) return;
    _recordRtcTransition('leave_broadcast start room=${room['id'] ?? ''}');
    final wasHost = _isHost;
    final commentCount = _comments.length;
    final peakListeners = room['audienceCount'] as int? ?? 0;
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
                  label: 'Peak listeners',
                  value: '$serverPeak',
                ),
                const SizedBox(height: 10),
                _ReportStatRow(
                  icon: Icons.chat_bubble_outline,
                  label: 'Comments',
                  value: '$commentCount',
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

  Future<void> _requestBroadcasts() async {
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
    } else if (mounted) {
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

  Future<void> _copyLiveComment(String text) async {
    final cleaned = text.trim();
    if (cleaned.isEmpty) return;
    await Clipboard.setData(ClipboardData(text: cleaned));
    if (!mounted) return;
    ScaffoldMessenger.of(
      context,
    ).showSnackBar(const SnackBar(content: Text('Comment copied')));
  }

  void _showPlaceholderAction(String label) {
    ScaffoldMessenger.of(
      context,
    ).showSnackBar(SnackBar(content: Text('$label is coming next')));
  }

  Future<void> _raiseHand() async {
    final me = ref.read(sessionControllerProvider).user;
    final room = _activeRoom;
    if (me == null || room == null || _handRaised || !_socket.isConnected) {
      return;
    }
    if (me.isProLike != true) {
      await showProAccessSheet(
        context: context,
        ref: ref,
        featureName: 'Stage Access',
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
              ? '${payload['message'] ?? 'Unable to request stage right now'}'
              : 'Stage request timed out. Try again.',
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
    };
  }

  bool _isUserOnStage(String userId) {
    if (userId.isEmpty) return false;
    final room = _activeRoom;
    if (room == null) return false;
    final speakers = (room['speakers'] as List<dynamic>? ?? const []);
    return speakers.any(
      (item) => item is Map && '${item['userId'] ?? ''}' == userId,
    );
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
    while (normalizedSpeakers.length < 3) {
      normalizedSpeakers.add(null);
    }

    return <Map<String, dynamic>?>[
      normalizedHost,
      ...normalizedSpeakers.take(3),
    ];
  }

  List<Map<String, dynamic>> get _speakers =>
      _stageSlots.whereType<Map<String, dynamic>>().toList();

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
      return voiceActivity || maxAudioLevel > 0.025;
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
        ? _speakingNegativeSamples < 2
        : _speakingPositiveSamples >= 2;
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
    }
    final hostUserId = _resolveHostUserId(room);
    if (hostUserId.isNotEmpty && hostUserId != _meId) {
      ids.add(hostUserId);
    }
    return ids.toList();
  }

  Future<void> _ensureLocalStageStream() async {
    if (!_amOnStage) return;
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
  }

  Future<void> _disposeLocalStageStream() async {
    _localRenderer?.srcObject = null;
    _localMicEnabled = true;
    _localVideoEnabled = false;
    _didInitializeStageMic = false;
    _wasOnStage = false;
    _stopSpeakingProbe(clearSpeaking: true);
    await ref.read(webRtcServiceProvider).disposeLocalStream();
  }

  Future<RTCRtpSender?> _findAudioSender(RTCPeerConnection connection) async {
    final senders = await connection.getSenders();
    for (final sender in senders) {
      if (sender.track?.kind == 'audio') return sender;
    }
    return null;
  }

  Future<void> _ensureAudioPeerMode(
    RTCPeerConnection connection, {
    required bool shouldSendAudio,
  }) async {
    if (_roomUsesVideo) return;
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
      await connection.addTransceiver(
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

    final audioSender = await _findAudioSender(connection);
    if (shouldSendAudio) {
      final stream =
          ref.read(webRtcServiceProvider).localStream ??
          await ref
              .read(webRtcServiceProvider)
              .createLocalStream(audio: true, video: false);
      final tracks = stream.getAudioTracks();
      if (tracks.isEmpty) return;
      final track = tracks.first;
      if (audioSender != null) {
        if (audioSender.track?.id != track.id) {
          await audioSender.replaceTrack(track);
        }
      } else {
        await connection.addTrack(track, stream);
      }
    } else if (audioSender != null && audioSender.track != null) {
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
      if (event.track.kind == 'audio') {
        _markInboundAudioDetected();
      }
      if (mounted) setState(() {});
    };

    connection.onConnectionState = (state) {
      if (!mounted) return;
      _peerStates[peerUserId] = _describeConnectionState(state);
      setState(() {});
      if (state == RTCPeerConnectionState.RTCPeerConnectionStateClosed ||
          state == RTCPeerConnectionState.RTCPeerConnectionStateFailed) {
        unawaited(_removePeer(peerUserId));
      }
    };

    _peerConnections[peerUserId] = connection;
    final stream = ref.read(webRtcServiceProvider).localStream;
    if (stream != null) {
      for (final track in stream.getTracks()) {
        await connection.addTrack(track, stream);
      }
    }
    return connection;
  }

  Future<void> _sendOffer(String peerUserId) async {
    final room = _activeRoom;
    if (room == null) return;
    final connection = await _ensurePeerConnection(peerUserId);
    final offer = await connection.createOffer(<String, dynamic>{
      'offerToReceiveAudio': true,
      'offerToReceiveVideo': _roomUsesVideo,
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

    final peerIds = _rtcTargetPeerIds;
    _recordRtcTransition('rtc_targets count=${peerIds.length}');
    if (!onStageNow && !_topologyReady && peerIds.isEmpty) {
      _recordRtcTransition('rtc_sync blocked topology_not_ready');
      return;
    }
    final existingIds = _peerConnections.keys.toList();
    for (final userId in existingIds) {
      if (!peerIds.contains(userId)) {
        await _removePeer(userId);
      }
    }

    for (final peerUserId in peerIds) {
      if (!mounted || _activeRoom == null) return;
      final hadConnection = _peerConnections.containsKey(peerUserId);
      final connection = await _ensurePeerConnection(peerUserId);
      await _ensureAudioPeerMode(connection, shouldSendAudio: _amOnStage);
      final shouldOffer = !_amOnStage || _meId.compareTo(peerUserId) < 0;
      if (!shouldOffer) continue;
      if (!hadConnection || !_remoteDescriptionReady.contains(peerUserId)) {
        await _sendOffer(peerUserId);
      }
    }

    _syncSpeakingProbeLifecycle();
    if (_shouldMonitorListenerAudio) {
      _startAudioRecoveryMonitor();
    } else {
      _stopAudioRecoveryMonitor();
    }
    _wasOnStage = onStageNow;
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

  Future<void> _removePeer(String peerUserId) async {
    _remoteDescriptionReady.remove(peerUserId);
    _pendingIce.remove(peerUserId);
    _peerStates.remove(peerUserId);
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
    final peerIds = _peerConnections.keys.toList();
    for (final peerUserId in peerIds) {
      await _removePeer(peerUserId);
    }
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
        !_roomUsesVideo &&
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
              content: Text('Microphone access is required to speak on stage.'),
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
    final stream = ref.read(webRtcServiceProvider).localStream;
    if (stream == null || stream.getVideoTracks().isEmpty) return;
    for (final track in stream.getVideoTracks()) {
      track.enabled = !track.enabled;
      _localVideoEnabled = track.enabled;
    }
    if (mounted) setState(() {});
  }

  Future<void> _switchStageCamera() async {
    final switched = await ref.read(webRtcServiceProvider).switchCamera();
    if (switched && mounted) {
      setState(() {});
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
                ? '${payload['message'] ?? 'Unable to leave stage right now'}'
                : 'Leave stage timed out. Try again.',
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
    await _ensureAudioPeerMode(connection, shouldSendAudio: _amOnStage);
    final sdp = Map<String, dynamic>.from(payload['sdp'] as Map);
    await connection.setRemoteDescription(
      RTCSessionDescription(sdp['sdp']?.toString(), sdp['type']?.toString()),
    );
    _remoteDescriptionReady.add(fromUserId);
    await _flushPendingIce(fromUserId);
    final answer = await connection.createAnswer(<String, dynamic>{
      'offerToReceiveAudio': true,
      'offerToReceiveVideo': _roomUsesVideo,
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
      return;
    }

    setState(() {});
  }

  Future<void> _copyRoomId() async {
    final room = _activeRoom;
    if (room == null) return;
    await Clipboard.setData(ClipboardData(text: '${room['id'] ?? ''}'));
    if (!mounted) return;
    ScaffoldMessenger.of(
      context,
    ).showSnackBar(const SnackBar(content: Text('Broadcast ID copied')));
  }

  Future<void> _openRoomMenu() async {
    final room = _activeRoom;
    if (room == null) return;
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
              borderRadius: BorderRadius.circular(28),
            ),
            padding: const EdgeInsets.fromLTRB(20, 18, 20, 20),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Row(
                  children: [
                    Text(
                      'Broadcast menu',
                      style: theme.textTheme.titleLarge?.copyWith(
                        fontWeight: FontWeight.w800,
                      ),
                    ),
                    const Spacer(),
                    IconButton(
                      onPressed: () => Navigator.of(context).pop(),
                      icon: const Icon(Icons.close),
                    ),
                  ],
                ),
                _MenuActionTile(
                  icon: Icons.copy_rounded,
                  label: 'Copy broadcast ID',
                  onTap: () async {
                    Navigator.of(context).pop();
                    await _copyRoomId();
                  },
                ),
                if (_isHost || _liveRoomState.permissions.canModerateRoom)
                  _MenuActionTile(
                    icon: Icons.bug_report_outlined,
                    label: 'RTC debug',
                    onTap: () {
                      Navigator.of(context).pop();
                      _openRtcDebugSheet();
                    },
                  ),
                _MenuActionTile(
                  icon: _isHost
                      ? Icons.stop_circle_outlined
                      : Icons.logout_rounded,
                  label: _isHost ? 'End broadcast' : 'Leave room',
                  destructive: true,
                  onTap: () {
                    Navigator.of(context).pop();
                    _leaveBroadcast();
                  },
                ),
              ],
            ),
          ),
        );
      },
    );
  }

  Future<void> _openRtcDebugSheet() async {
    final room = _activeRoom;
    if (room == null) return;
    final peerIds = _peerConnections.keys.toList()..sort();
    final localStream = ref.read(webRtcServiceProvider).localStream;
    final localAudioTracks = localStream?.getAudioTracks() ?? const [];
    final hasLocalAudioTrack = localAudioTracks.isNotEmpty;
    final localAudioTrackEnabled = hasLocalAudioTrack
        ? localAudioTracks.any((track) => track.enabled)
        : false;
    final localAudioTrackIds = hasLocalAudioTrack
        ? localAudioTracks.map((track) => track.id).toSet()
        : const <String>{};
    var audioSenderAttachedPeers = 0;
    for (final connection in _peerConnections.values) {
      try {
        final senders = await connection.getSenders();
        final hasAttachedAudioSender = senders.any((sender) {
          final track = sender.track;
          if (track == null || track.kind != 'audio') return false;
          if (localAudioTrackIds.isEmpty) return true;
          return localAudioTrackIds.contains(track.id);
        });
        if (hasAttachedAudioSender) {
          audioSenderAttachedPeers += 1;
        }
      } catch (_) {}
    }
    if (!mounted) return;
    await showModalBottomSheet<void>(
      context: context,
      showDragHandle: true,
      builder: (context) {
        final theme = Theme.of(context);
        return SafeArea(
          child: Padding(
            padding: const EdgeInsets.fromLTRB(16, 8, 16, 20),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  'RTC debug',
                  style: theme.textTheme.titleLarge?.copyWith(
                    fontWeight: FontWeight.w800,
                  ),
                ),
                const SizedBox(height: 8),
                Text('Room: ${room['id'] ?? ''}'),
                Text(
                  'Role: ${_isHost ? LiveRoomRole.host.label : (_amOnStage ? LiveRoomRole.speaker.label : _liveRoomState.role.label)}',
                ),
                Text('On stage: $_amOnStage'),
                Text('Socket: $_socketStatus'),
                Text('SFU connected: $_sfuConnected'),
                Text('Topology ready: $_topologyReady'),
                Text('Room version: $_activeRoomVersion'),
                Text('Peers: ${peerIds.length}'),
                Text(
                  'Self publish track: ${hasLocalAudioTrack ? (localAudioTrackEnabled ? 'enabled' : 'disabled') : 'missing'}',
                ),
                Text(
                  'Audio sender attached peers: $audioSenderAttachedPeers/${peerIds.length}',
                ),
                Text('Audio recovery attempts: $_audioRecoveryAttempts'),
                const SizedBox(height: 10),
                Text(
                  'Recent transitions',
                  style: theme.textTheme.titleSmall?.copyWith(
                    fontWeight: FontWeight.w700,
                  ),
                ),
                const SizedBox(height: 6),
                if (_rtcTransitionLog.isEmpty)
                  const Text('No transitions yet.')
                else
                  ..._rtcTransitionLog.reversed.map(
                    (entry) => Padding(
                      padding: const EdgeInsets.only(bottom: 2),
                      child: Text('- $entry', style: theme.textTheme.bodySmall),
                    ),
                  ),
                const SizedBox(height: 8),
                if (peerIds.isEmpty)
                  const Text('No peers connected.')
                else
                  ...peerIds.map((id) {
                    final state = _peerStates[id] ?? 'unknown';
                    return Padding(
                      padding: const EdgeInsets.only(bottom: 4),
                      child: Text('- $id: $state'),
                    );
                  }),
              ],
            ),
          ),
        );
      },
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
    if (!canModerate) {
      _openProfile(userId);
      return;
    }
    final targetOnStage = _isUserOnStage(userId);
    final targetIsHost = hostUserId.isNotEmpty && hostUserId == userId;
    final targetName = _displayNameForUser(userId);
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
                      targetName,
                      style: theme.textTheme.titleMedium?.copyWith(
                        fontWeight: FontWeight.w700,
                      ),
                    ),
                    subtitle: const Text('Participant actions'),
                  ),
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
                              _socket.emit('live:user:mute', <String, dynamic>{
                                'broadcastId': room['id'],
                                'targetUserId': userId,
                                'muted': true,
                              });
                            }
                            if (!mounted) return;
                            final ok = payload is Map && payload['ok'] == true;
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
                              const SnackBar(content: Text('Mute signal sent')),
                            );
                          },
                  ),
                  ListTile(
                    leading: const Icon(Icons.vertical_align_bottom_rounded),
                    title: const Text('Remove from stage'),
                    enabled:
                        canRemoveFromStage && targetOnStage && !targetIsHost,
                    onTap:
                        !(canRemoveFromStage && targetOnStage && !targetIsHost)
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
                            final ok = payload is Map && payload['ok'] == true;
                            if (!ok) {
                              ScaffoldMessenger.of(this.context).showSnackBar(
                                SnackBar(
                                  content: Text(
                                    payload is Map
                                        ? '${payload['message'] ?? 'Unable to remove from stage'}'
                                        : 'Remove-from-stage timed out.',
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
                              _activeRoomVersion = _roomVersionFrom(broadcast);
                              _activeSpeakerVersion = _speakerVersionFrom(
                                broadcast,
                              );
                              _refreshTopologyReady(broadcast);
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
                              const SnackBar(content: Text('Speaker removed')),
                            );
                          },
                  ),
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
                      title: const Text('Promote to moderator'),
                      onTap: () {
                        Navigator.of(context).pop();
                        _socket.emit('live:role:update', <String, dynamic>{
                          'broadcastId': room['id'],
                          'targetUserId': userId,
                          'role': 'moderator',
                        });
                        ScaffoldMessenger.of(this.context).showSnackBar(
                          const SnackBar(
                            content: Text('Role update signal sent'),
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

  void _onParticipantLongPress(String userId) {
    if (userId.isEmpty) return;
    unawaited(_openParticipantActions(userId));
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
                      title: const Text('Review stage requests'),
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
                    title: const Text('Lock stage (signal)'),
                    onTap: () {
                      Navigator.of(context).pop();
                      _socket.emit('live:stage:lock', <String, dynamic>{
                        'broadcastId': room['id'],
                        'locked': true,
                      });
                      ScaffoldMessenger.of(this.context).showSnackBar(
                        const SnackBar(content: Text('Stage lock signal sent')),
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
                          'Stage Requests',
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
                      'Listeners',
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
                        '${listeners.length}',
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
                      child: Text('No listeners in this room yet.'),
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
                            '${listener['name'] ?? 'Listener'}';
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

  List<Map<String, dynamic>> get _filteredBroadcasts => _broadcasts
      .where((room) => '${room['type'] ?? 'audio'}' == _browseType)
      .where(
        (room) => room['isPrivate'] == true
            ? '${room['hostUserId'] ?? ''}' == _meId
            : true,
      )
      .toList();

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final socket = ref.watch(socketServiceProvider);

    return Scaffold(
      backgroundColor: _activeRoom != null && !_roomUsesVideo
          ? _audioRoomBackground
          : theme.colorScheme.surface,
      body: SafeArea(
        bottom: _activeRoom == null,
        child: _activeRoom == null
            ? _buildHome(theme, socket.status)
            : _buildRoom(theme, socket.status),
      ),
    );
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
                  const SizedBox(width: 12),
                  Expanded(
                    child: _MiniModeSwitch(
                      leftLabel: 'Broadcast',
                      rightLabel: 'Groups',
                      value: _liveMode,
                      onChanged: (value) => setState(() {
                        _liveMode = value;
                        ref.read(liveModeProvider.notifier).state = value;
                      }),
                    ),
                  ),
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
              if (_liveMode == 'broadcast') ...[
                _buildHeroCard(theme),
                const SizedBox(height: 14),
                _buildBroadcastTypeSwitcher(theme),
              ],
            ],
          ),
        ),
        Expanded(
          child: _liveMode == 'groups'
              ? _buildGroupsPlaceholder(theme)
              : _buildBroadcastList(theme, socketStatus),
        ),
      ],
    );
  }

  Widget _buildHeroCard(ThemeData theme) {
    final activeCount = _filteredBroadcasts.length;
    return Container(
      width: double.infinity,
      padding: const EdgeInsets.all(18),
      decoration: BoxDecoration(
        borderRadius: BorderRadius.circular(26),
        gradient: LinearGradient(
          colors: [
            theme.colorScheme.primary.withValues(alpha: 0.16),
            theme.colorScheme.surfaceContainerHighest,
          ],
          begin: Alignment.topLeft,
          end: Alignment.bottomRight,
        ),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Container(
                padding: const EdgeInsets.symmetric(
                  horizontal: 11,
                  vertical: 7,
                ),
                decoration: BoxDecoration(
                  color: theme.colorScheme.primary,
                  borderRadius: BorderRadius.circular(999),
                ),
                child: Text(
                  _browseType == 'audio'
                      ? 'Broadcast / Audio'
                      : 'Broadcast / Video',
                  style: theme.textTheme.labelMedium?.copyWith(
                    color: theme.colorScheme.onPrimary,
                    fontWeight: FontWeight.w700,
                  ),
                ),
              ),
              const Spacer(),
              Text(
                '$activeCount live now',
                style: theme.textTheme.titleSmall?.copyWith(
                  fontWeight: FontWeight.w700,
                ),
              ),
            ],
          ),
          const SizedBox(height: 14),
          Text(
            _browseType == 'audio'
                ? 'Listen to live audio rooms, jump into the comments, and request a speaker slot when the conversation fits.'
                : 'Join live video broadcasts with a host, three stage speakers, and a room full of listeners.',
            style: theme.textTheme.bodyMedium?.copyWith(height: 1.35),
          ),
        ],
      ),
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
        ref.read(liveBrowseTypeProvider.notifier).state = value;
      }),
    );
  }

  Widget _buildGroupsPlaceholder(ThemeData theme) {
    return ListView(
      padding: const EdgeInsets.fromLTRB(20, 0, 20, 24),
      children: [
        Container(
          padding: const EdgeInsets.all(24),
          decoration: BoxDecoration(
            color: theme.colorScheme.surfaceContainer,
            borderRadius: BorderRadius.circular(30),
          ),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(
                'Groups are coming next',
                style: theme.textTheme.headlineSmall?.copyWith(
                  fontWeight: FontWeight.w800,
                ),
              ),
              const SizedBox(height: 10),
              Text(
                'Broadcast is the default live mode for now. Group rooms will plug into this screen later without changing the navigation pattern.',
                style: theme.textTheme.bodyMedium?.copyWith(
                  color: theme.colorScheme.onSurfaceVariant,
                  height: 1.4,
                ),
              ),
            ],
          ),
        ),
      ],
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
          title: '${room['title'] ?? 'Untitled'}',
          type: '${room['type'] ?? 'audio'}',
          language: '${room['lang'] ?? 'EN'}',
          secondaryLanguage: room['lang2']?.toString(),
          description: room['description']?.toString(),
          host: '${room['host'] ?? 'Host'}',
          hostPhotoUrl: '${room['hostPhoto'] ?? ''}',
          hostFlagCode: _flagCode('${room['hostNationalityCode'] ?? ''}'),
          speakers: (room['speakers'] as List<dynamic>? ?? const [])
              .whereType<Map>()
              .map((s) => Map<String, dynamic>.from(s))
              .toList(),
          audienceCount: room['audienceCount'] as int? ?? 0,
          attendeeCount: room['attendees'] as int? ?? 0,
          commentsCount: (room['comments'] as List<dynamic>?)?.length ?? 0,
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
    final room = _activeRoom!;
    final listenerCount = room['audienceCount'] as int? ?? 0;

    if (!_roomUsesVideo) {
      return _buildImmersiveAudioRoom(theme, socketStatus);
    }

    return Column(
      children: [
        Padding(
          padding: const EdgeInsets.fromLTRB(18, 8, 18, 14),
          child: Column(
            children: [
              Row(
                children: [
                  IconButton(
                    onPressed: _openRoomMenu,
                    icon: const Icon(Icons.menu_rounded),
                  ),
                  Expanded(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        _AutoScrollingTitle(
                          text: '${room['title'] ?? 'Broadcast'}',
                          style: theme.textTheme.titleLarge?.copyWith(
                            fontWeight: FontWeight.w800,
                          ),
                        ),
                        const SizedBox(height: 2),
                        Text(
                          '${room['host'] ?? 'Host'} • ${_roomUsesVideo ? 'Video' : 'Audio'} broadcast',
                          style: theme.textTheme.bodyMedium?.copyWith(
                            color: theme.colorScheme.onSurfaceVariant,
                          ),
                        ),
                      ],
                    ),
                  ),
                  if (_isHost)
                    Stack(
                      clipBehavior: Clip.none,
                      children: [
                        IconButton(
                          onPressed: _openJoinRequestsSheet,
                          tooltip: 'Raised hands',
                          icon: Icon(
                            _pendingJoinRequestCount > 0
                                ? Icons.pan_tool_alt_rounded
                                : Icons.front_hand_outlined,
                          ),
                        ),
                        if (_joinRequests.isNotEmpty)
                          Positioned(
                            right: 6,
                            top: 6,
                            child: Container(
                              width: 18,
                              height: 18,
                              decoration: BoxDecoration(
                                color: theme.colorScheme.primary,
                                shape: BoxShape.circle,
                              ),
                              alignment: Alignment.center,
                              child: Text(
                                _pendingJoinRequestCountLabel,
                                style: theme.textTheme.labelSmall?.copyWith(
                                  color: theme.colorScheme.onPrimary,
                                  fontWeight: FontWeight.w700,
                                  fontSize: 10,
                                ),
                              ),
                            ),
                          ),
                      ],
                    ),
                  IconButton(
                    onPressed: _openRoomMenu,
                    icon: const Icon(Icons.more_horiz),
                  ),
                ],
              ),
              if (socketStatus != 'connected') ...[
                const SizedBox(height: 10),
                RealtimeWarningBanner(
                  status: socketStatus,
                  scopeLabel: 'Live room',
                  connectingMessage: 'Reconnecting to the broadcast...',
                ),
              ],
            ],
          ),
        ),
        Expanded(
          child: Container(
            margin: const EdgeInsets.fromLTRB(12, 0, 12, 12),
            decoration: BoxDecoration(
              color: theme.colorScheme.surfaceContainerLow,
              borderRadius: BorderRadius.circular(32),
            ),
            child: Column(
              children: [
                Padding(
                  padding: const EdgeInsets.fromLTRB(18, 18, 18, 10),
                  child: Row(
                    children: [
                      _MetricChip(
                        icon: Icons.graphic_eq,
                        label: _roomUsesVideo ? 'Video room' : 'Audio room',
                      ),
                      const SizedBox(width: 10),
                      _MetricChip(
                        icon: Icons.headset,
                        label: '$listenerCount listening',
                      ),
                      const SizedBox(width: 10),
                      _MetricChip(
                        icon: Icons.chat_bubble_outline,
                        label: '${_comments.length} comments',
                      ),
                    ],
                  ),
                ),
                Expanded(
                  child: Padding(
                    padding: const EdgeInsets.fromLTRB(16, 4, 16, 0),
                    child: Column(
                      children: [
                        _buildStageGrid(theme),
                        const SizedBox(height: 14),
                        _buildRoomControls(theme),
                        const SizedBox(height: 14),
                        Expanded(child: _buildComments(theme)),
                      ],
                    ),
                  ),
                ),
                _buildCommentComposer(theme, socketStatus),
              ],
            ),
          ),
        ),
      ],
    );
  }

  Widget _buildImmersiveAudioRoom(ThemeData theme, String socketStatus) {
    final room = _activeRoom!;
    final bottomInset = MediaQuery.of(context).viewInsets.bottom;
    final safeAreaBottom = MediaQuery.of(context).padding.bottom;
    final isCommenting = _commentFocusNode.hasFocus || bottomInset > 0;
    final composerBottomPadding = bottomInset > 0 ? bottomInset : 18.0;
    const sideRailBottomPadding = 18.0;
    final iPhoneCommentClearance =
        Theme.of(context).platform == TargetPlatform.iOS ? safeAreaBottom : 0.0;
    const stageHeight = 150.0;
    final stageTop = socketStatus == 'connected' ? 138.0 : 178.0;
    final commentsTop = stageTop + stageHeight + 6;

    return Stack(
      children: [
        Positioned.fill(
          child: DecoratedBox(
            decoration: const BoxDecoration(color: _audioRoomBackground),
            child: SafeArea(
              bottom: false,
              child: SingleChildScrollView(
                padding: EdgeInsets.fromLTRB(
                  16,
                  6,
                  16,
                  (isCommenting ? 118 : 138) + composerBottomPadding,
                ),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    _buildImmersiveAudioHeader(theme, room),
                    if (socketStatus != 'connected') ...[
                      const SizedBox(height: 8),
                      RealtimeWarningBanner(
                        status: socketStatus,
                        scopeLabel: 'Live room',
                        connectingMessage: 'Reconnecting to the broadcast...',
                      ),
                    ],
                    const SizedBox(height: 14),
                    const SizedBox(height: stageHeight + 12),
                  ],
                ),
              ),
            ),
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
          right: 70,
          top: commentsTop,
          bottom: 72 + composerBottomPadding + iPhoneCommentClearance,
          child: _buildImmersiveComments(theme, condensed: isCommenting),
        ),
        Positioned(
          left: 16,
          right: 16,
          top: stageTop,
          height: stageHeight,
          child: _buildImmersiveStage(theme),
        ),
        Positioned(
          right: 16,
          bottom: 124 + sideRailBottomPadding,
          child: _buildImmersiveSideRail(theme),
        ),
        Positioned(
          left: 16,
          right: 16,
          bottom: composerBottomPadding,
          child: _buildImmersiveComposer(theme, socketStatus, isCommenting),
        ),
      ],
    );
  }

  Widget _buildImmersiveAudioHeader(
    ThemeData theme,
    Map<String, dynamic> room,
  ) {
    final title = '${room['title'] ?? 'Broadcast'}';
    final language = '${room['lang'] ?? _language}';
    final secondary = room['lang2']?.toString();
    final hostUserId = '${room['hostUserId'] ?? ''}';
    final hostIsMe = hostUserId.isNotEmpty && hostUserId == _meId;
    final hostCanBeFollowed = hostUserId.isNotEmpty && !hostIsMe;
    final followLabel = _followingHostBusy
        ? '...'
        : (hostCanBeFollowed
              ? (_isFollowingHost ? 'Following' : 'Follow')
              : '');

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Row(
          children: [
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
            if (hostCanBeFollowed) ...[
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
            const SizedBox(width: 10),
            GestureDetector(
              onTap: _openRoomMenu,
              child: Container(
                width: 48,
                height: 48,
                decoration: BoxDecoration(
                  color: Colors.black.withValues(alpha: 0.2),
                  shape: BoxShape.circle,
                ),
                alignment: Alignment.center,
                child: const Icon(
                  Icons.more_horiz_rounded,
                  color: Colors.white,
                  size: 24,
                ),
              ),
            ),
          ],
        ),
        const SizedBox(height: 10),
        Row(
          children: [
            _ImmersivePill(label: language, filled: false, leading: null),
            if (secondary?.isNotEmpty == true) ...[
              const SizedBox(width: 10),
              _ImmersivePill(label: secondary!, filled: false, leading: null),
            ],
          ],
        ),
      ],
    );
  }

  Widget _buildImmersiveStage(ThemeData theme) {
    final seats = _stageSlots;

    return LayoutBuilder(
      builder: (context, constraints) {
        const idealSeatWidth = 96.0;
        final slotWidth = constraints.maxWidth / 4;
        final seatScale = (slotWidth / idealSeatWidth)
            .clamp(0.72, 1.0)
            .toDouble();

        return Row(
          children: List<Widget>.generate(4, (index) {
            final seat = seats[index];
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
            return SizedBox(
              width: slotWidth,
              child: Align(
                alignment: Alignment.topCenter,
                child: _ImmersiveSeat(
                  number: index + 1,
                  label: label,
                  occupied: occupied,
                  photoUrl: occupied ? '${seat['photo'] ?? ''}' : '',
                  isHostSeat: isHostSeat,
                  accentBadge: false,
                  scale: seatScale,
                  muted: muted,
                  speaking:
                      occupied && !muted && _activeSpeakers.contains(userId),
                  onTap: occupied && userId.isNotEmpty
                      ? () => _openProfile(userId)
                      : null,
                  onLongPress: occupied && userId.isNotEmpty
                      ? () => _onParticipantLongPress(userId)
                      : null,
                ),
              ),
            );
          }),
        );
      },
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
        return _ImmersiveCommentBubble(
          author: author,
          text: text,
          photoUrl: '${comment['photo'] ?? ''}',
          system: author == 'System',
          onAvatarTap: userId.isEmpty ? null : () => _openProfile(userId),
          onAvatarLongPress: userId.isEmpty
              ? null
              : () => _onParticipantLongPress(userId),
          onLongPress: () => _copyLiveComment(text),
        );
      },
    );
  }

  Widget _buildImmersiveSideRail(ThemeData theme) {
    final isHost = _isHost;
    final audienceCount = _audienceMembers.length;
    final audienceBadge = audienceCount > 99 ? '99+' : '$audienceCount';
    return Column(
      mainAxisSize: MainAxisSize.min,
      children: [
        _SideRailButton(
          icon: Icons.groups_rounded,
          badgeLabel: audienceCount > 0 ? audienceBadge : null,
          onTap: _openAudienceSheet,
        ),
        const SizedBox(height: 14),
        _SideRailButton(
          icon: isHost
              ? (_pendingJoinRequestCount > 0
                    ? Icons.pan_tool_alt_rounded
                    : Icons.front_hand_outlined)
              : (_amOnStage ? Icons.logout_rounded : Icons.front_hand_outlined),
          isActive: !isHost && !_amOnStage && _handRaised,
          badgeLabel: isHost && _pendingJoinRequestCount > 0
              ? _pendingJoinRequestCountLabel
              : null,
          onTap: isHost
              ? _openJoinRequestsSheet
              : (_amOnStage
                    ? _leaveStage
                    : (_handRaised ? _lowerHand : _raiseHand)),
        ),
        if (_liveRoomState.permissions.canModerateRoom) ...[
          const SizedBox(height: 14),
          _SideRailButton(
            icon: Icons.admin_panel_settings_outlined,
            onTap: _openModerationControlsSheet,
          ),
        ],
        if (_amOnStage) ...[
          const SizedBox(height: 14),
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
        ],
        const SizedBox(height: 14),
        _SideRailButton(
          icon: Icons.favorite_rounded,
          onTap: () => _sendReaction('❤️'),
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
            padding: const EdgeInsets.fromLTRB(12, 7, 8, 7),
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
                    style: theme.textTheme.bodyLarge?.copyWith(
                      color: Colors.white,
                      fontSize: 15,
                    ),
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
                if (isCommenting) ...[
                  _ComposerIconButton(
                    icon: Icons.send_rounded,
                    onTap: enabled ? _sendComment : null,
                  ),
                ] else ...[
                  _ComposerDockButton(
                    icon: Icons.card_giftcard_rounded,
                    badgeLabel: null,
                    onTap: () => _showPlaceholderAction('Gifts'),
                  ),
                ],
              ],
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildStageGrid(ThemeData theme) {
    final slots = _stageSlots;
    return Container(
      padding: const EdgeInsets.all(14),
      decoration: BoxDecoration(
        color: theme.colorScheme.surface,
        borderRadius: BorderRadius.circular(28),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(
            'Stage',
            style: theme.textTheme.titleMedium?.copyWith(
              fontWeight: FontWeight.w800,
            ),
          ),
          const SizedBox(height: 6),
          Text(
            '1 host + 3 speakers. Listeners stay in the audience and can request the stage.',
            style: theme.textTheme.bodySmall?.copyWith(
              color: theme.colorScheme.onSurfaceVariant,
            ),
          ),
          const SizedBox(height: 14),
          GridView.builder(
            shrinkWrap: true,
            physics: const NeverScrollableScrollPhysics(),
            itemCount: 4,
            gridDelegate: const SliverGridDelegateWithFixedCrossAxisCount(
              crossAxisCount: 2,
              crossAxisSpacing: 12,
              mainAxisSpacing: 12,
              childAspectRatio: 0.92,
            ),
            itemBuilder: (context, index) {
              final slot = slots[index];
              final isSelf = slot != null && '${slot['userId'] ?? ''}' == _meId;
              final peerUserId = slot == null ? '' : '${slot['userId'] ?? ''}';
              final renderer = isSelf
                  ? _localRenderer
                  : _remoteRenderers[peerUserId];
              final role = slot == null
                  ? (index == 0 ? 'Host' : 'Speaker')
                  : '${slot['role'] ?? 'Speaker'}';
              final connected = isSelf || renderer?.srcObject != null;
              return _StageSeatCard(
                name: slot == null
                    ? (index == 0 ? 'Waiting for host' : 'Open speaker slot')
                    : '${slot['name'] ?? 'Speaker'}',
                role: role,
                photoUrl: slot == null ? '' : '${slot['photo'] ?? ''}',
                renderer: renderer,
                isVideoRoom: _roomUsesVideo,
                localVideoEnabled: isSelf ? _localVideoEnabled : true,
                connected: connected,
                muted: isSelf ? !_localMicEnabled : (slot?['muted'] == true),
                statusLabel: slot == null
                    ? null
                    : (isSelf ? 'live' : _peerStates[peerUserId] ?? 'live'),
                highlighted: isSelf,
                empty: slot == null,
                onAvatarTap: slot == null || peerUserId.isEmpty
                    ? null
                    : () => _openProfile(peerUserId),
                onLongPress: slot == null || peerUserId.isEmpty
                    ? null
                    : () => _onParticipantLongPress(peerUserId),
              );
            },
          ),
        ],
      ),
    );
  }

  Widget _buildRoomControls(ThemeData theme) {
    return Container(
      padding: const EdgeInsets.all(16),
      decoration: BoxDecoration(
        color: theme.colorScheme.surface,
        borderRadius: BorderRadius.circular(24),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(
            _amOnStage ? 'Stage controls' : 'Audience controls',
            style: theme.textTheme.titleSmall?.copyWith(
              fontWeight: FontWeight.w800,
            ),
          ),
          const SizedBox(height: 12),
          Wrap(
            spacing: 10,
            runSpacing: 10,
            children: [
              if (_amOnStage)
                _ControlChip(
                  icon: _localMicEnabled ? Icons.mic : Icons.mic_off,
                  label: _localMicEnabled ? 'Mute mic' : 'Unmute mic',
                  onTap: _toggleStageMute,
                ),
              if (_amOnStage && _roomUsesVideo)
                _ControlChip(
                  icon: _localVideoEnabled
                      ? Icons.videocam
                      : Icons.videocam_off,
                  label: _localVideoEnabled ? 'Stop camera' : 'Start camera',
                  onTap: _toggleStageCamera,
                ),
              if (_amOnStage && _roomUsesVideo && _localVideoEnabled)
                _ControlChip(
                  icon: Icons.cameraswitch_outlined,
                  label: 'Switch camera',
                  onTap: _switchStageCamera,
                ),
              if (!_isHost)
                _ControlChip(
                  icon: _amOnStage
                      ? Icons.logout_rounded
                      : (_handRaised
                            ? Icons.pan_tool_alt
                            : Icons.record_voice_over),
                  label: _amOnStage
                      ? 'Leave stage'
                      : _handRaised
                      ? 'Requested'
                      : 'Request stage',
                  onTap: _amOnStage
                      ? _leaveStage
                      : (_handRaised ? _lowerHand : _raiseHand),
                ),
              if (_isHost)
                _ControlChip(
                  icon: _pendingJoinRequestCount > 0
                      ? Icons.pan_tool_alt_rounded
                      : Icons.front_hand_outlined,
                  label: _pendingJoinRequestCount > 0
                      ? 'Raised hands ($_pendingJoinRequestCountLabel)'
                      : 'Raised hands',
                  onTap: _openJoinRequestsSheet,
                ),
              _ControlChip(
                icon: _isHost ? Icons.stop_circle_outlined : Icons.logout,
                label: _isHost ? 'End room' : 'Leave room',
                destructive: true,
                onTap: _leaveBroadcast,
              ),
            ],
          ),
        ],
      ),
    );
  }

  Widget _buildComments(ThemeData theme) {
    if (_comments.isEmpty) {
      return Container(
        width: double.infinity,
        decoration: BoxDecoration(
          color: theme.colorScheme.surface,
          borderRadius: BorderRadius.circular(24),
        ),
        alignment: Alignment.center,
        child: Text(
          'Comments will appear here as the room comes alive.',
          style: theme.textTheme.bodyMedium?.copyWith(
            color: theme.colorScheme.onSurfaceVariant,
          ),
        ),
      );
    }

    return Container(
      decoration: BoxDecoration(
        color: theme.colorScheme.surface,
        borderRadius: BorderRadius.circular(24),
      ),
      child: ListView.separated(
        padding: const EdgeInsets.all(14),
        itemBuilder: (context, index) {
          final comment = _comments[index];
          final text = '${comment['text'] ?? ''}';
          final userId = '${comment['userId'] ?? ''}';
          return _CommentTile(
            author: '${comment['author'] ?? 'User'}',
            text: text,
            photoUrl: '${comment['photo'] ?? ''}',
            system: '${comment['author'] ?? ''}' == 'System',
            mine: '${comment['userId'] ?? ''}' == _meId,
            onAvatarTap: userId.isEmpty ? null : () => _openProfile(userId),
            onAvatarLongPress: userId.isEmpty
                ? null
                : () => _onParticipantLongPress(userId),
            onLongPress: () => _copyLiveComment(text),
          );
        },
        separatorBuilder: (_, _) => const SizedBox(height: 10),
        itemCount: _comments.length,
      ),
    );
  }

  Widget _buildCommentComposer(ThemeData theme, String socketStatus) {
    return Padding(
      padding: const EdgeInsets.fromLTRB(16, 12, 16, 16),
      child: Container(
        padding: const EdgeInsets.fromLTRB(14, 10, 10, 10),
        decoration: BoxDecoration(
          color: theme.colorScheme.surface,
          borderRadius: BorderRadius.circular(24),
        ),
        child: Row(
          children: [
            Expanded(
              child: TextField(
                controller: _commentController,
                enabled: socketStatus == 'connected',
                maxLines: 4,
                minLines: 1,
                maxLength: 200,
                textInputAction: TextInputAction.send,
                inputFormatters: [LengthLimitingTextInputFormatter(200)],
                onSubmitted: (_) => _sendComment(),
                decoration: const InputDecoration(
                  hintText: 'Comment...',
                  border: InputBorder.none,
                  isDense: true,
                  counterText: '',
                ),
              ),
            ),
            const SizedBox(width: 8),
            FilledButton(
              onPressed: socketStatus == 'connected' ? _sendComment : null,
              style: FilledButton.styleFrom(
                minimumSize: const Size(54, 54),
                padding: EdgeInsets.zero,
                shape: const CircleBorder(),
              ),
              child: const Icon(Icons.arrow_upward_rounded),
            ),
          ],
        ),
      ),
    );
  }
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

class _BroadcastCard extends StatelessWidget {
  const _BroadcastCard({
    required this.title,
    required this.type,
    required this.language,
    required this.secondaryLanguage,
    required this.description,
    required this.host,
    required this.hostPhotoUrl,
    required this.hostFlagCode,
    this.speakers = const [],
    required this.audienceCount,
    required this.attendeeCount,
    required this.commentsCount,
    required this.onJoin,
  });

  final String title;
  final String type;
  final String language;
  final String? secondaryLanguage;
  final String? description;
  final String host;
  final String hostPhotoUrl;
  final String hostFlagCode;
  final List<Map<String, dynamic>> speakers;
  final int audienceCount;
  final int attendeeCount;
  final int commentsCount;
  final VoidCallback? onJoin;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Material(
      color: Colors.transparent,
      child: InkWell(
        onTap: onJoin,
        borderRadius: BorderRadius.circular(24),
        child: Ink(
          padding: const EdgeInsets.fromLTRB(14, 12, 14, 10),
          decoration: BoxDecoration(
            color: theme.colorScheme.surfaceContainer,
            borderRadius: BorderRadius.circular(24),
            border: Border.all(
              color: theme.colorScheme.outline.withValues(alpha: 0.14),
            ),
            gradient: LinearGradient(
              colors: [
                const Color(0xFF583EA4).withValues(alpha: 0.16),
                const Color(0xFF583EA4).withValues(alpha: 0.06),
              ],
              begin: Alignment.topCenter,
              end: Alignment.bottomCenter,
            ),
            boxShadow: [
              BoxShadow(
                color: Colors.black.withValues(alpha: 0.12),
                blurRadius: 22,
                offset: const Offset(0, 10),
              ),
            ],
          ),
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
                            horizontal: 8,
                            vertical: 4,
                          ),
                          decoration: BoxDecoration(
                            color: const Color(
                              0xFFFF3B30,
                            ).withValues(alpha: 0.15),
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
                        _RoomTagPill(label: language),
                        if (secondaryLanguage != null &&
                            secondaryLanguage!.isNotEmpty)
                          _RoomTagPill(label: secondaryLanguage!),
                      ],
                    ),
                  ),
                  const SizedBox(width: 8),
                  _LiveRoomMenuButton(title: title),
                ],
              ),
              const SizedBox(height: 6),
              Text(
                title,
                maxLines: 2,
                overflow: TextOverflow.ellipsis,
                style: theme.textTheme.titleMedium?.copyWith(
                  fontWeight: FontWeight.w800,
                  height: 1.05,
                ),
              ),
              const SizedBox(height: 8),
              Row(
                children: [
                  _AvatarBubble(
                    photoUrl: hostPhotoUrl,
                    size: 36,
                    fallback: host,
                  ),
                  const SizedBox(width: 10),
                  Expanded(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Row(
                          children: [
                            Flexible(
                              child: Text(
                                host,
                                maxLines: 1,
                                overflow: TextOverflow.ellipsis,
                                style: theme.textTheme.labelLarge?.copyWith(
                                  fontWeight: FontWeight.w700,
                                ),
                              ),
                            ),
                            if (hostFlagCode.isNotEmpty) ...[
                              const SizedBox(width: 6),
                              _HostFlagBadge(code: hostFlagCode),
                            ],
                          ],
                        ),
                      ],
                    ),
                  ),
                  Column(
                    crossAxisAlignment: CrossAxisAlignment.end,
                    children: [
                      Row(
                        mainAxisSize: MainAxisSize.min,
                        children: [
                          Icon(
                            Icons.headset_outlined,
                            size: 16,
                            color: theme.colorScheme.onSurfaceVariant,
                          ),
                          const SizedBox(width: 4),
                          Text(
                            '$audienceCount',
                            style: theme.textTheme.labelLarge?.copyWith(
                              color: theme.colorScheme.onSurfaceVariant,
                              fontWeight: FontWeight.w800,
                            ),
                          ),
                        ],
                      ),
                      if (speakers.isNotEmpty) ...[
                        const SizedBox(height: 4),
                        Row(
                          mainAxisSize: MainAxisSize.min,
                          children: [
                            Icon(
                              Icons.record_voice_over_rounded,
                              size: 14,
                              color: theme.colorScheme.onSurfaceVariant,
                            ),
                            const SizedBox(width: 4),
                            Text(
                              '${speakers.length}',
                              style: theme.textTheme.labelSmall?.copyWith(
                                color: theme.colorScheme.onSurfaceVariant,
                                fontWeight: FontWeight.w800,
                              ),
                            ),
                          ],
                        ),
                      ],
                    ],
                  ),
                ],
              ),
            ],
          ),
        ),
      ),
    );
  }
}

class _StageSeatCard extends StatelessWidget {
  const _StageSeatCard({
    required this.name,
    required this.role,
    required this.photoUrl,
    required this.renderer,
    required this.isVideoRoom,
    required this.localVideoEnabled,
    required this.connected,
    required this.muted,
    required this.highlighted,
    required this.empty,
    this.statusLabel,
    this.onAvatarTap,
    this.onLongPress,
  });

  final String name;
  final String role;
  final String photoUrl;
  final RTCVideoRenderer? renderer;
  final bool isVideoRoom;
  final bool localVideoEnabled;
  final bool connected;
  final bool muted;
  final bool highlighted;
  final bool empty;
  final String? statusLabel;
  final VoidCallback? onAvatarTap;
  final VoidCallback? onLongPress;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final showVideo =
        isVideoRoom && renderer != null && connected && localVideoEnabled;
    return AnimatedContainer(
      duration: const Duration(milliseconds: 220),
      curve: Curves.easeOutCubic,
      padding: const EdgeInsets.all(12),
      decoration: BoxDecoration(
        color: theme.colorScheme.surfaceContainerHighest,
        borderRadius: BorderRadius.circular(24),
        border: highlighted
            ? Border.all(color: theme.colorScheme.primary, width: 1.5)
            : null,
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Expanded(
            child: ClipRRect(
              borderRadius: BorderRadius.circular(18),
              child: DecoratedBox(
                decoration: BoxDecoration(color: theme.colorScheme.surface),
                child: showVideo
                    ? RTCVideoView(renderer!, mirror: highlighted)
                    : Center(
                        child: ParticipantActionTarget(
                          onTap: onAvatarTap,
                          onLongPress: onLongPress,
                          child: _AvatarBubble(
                            photoUrl: photoUrl,
                            size: 72,
                            fallback: name,
                            icon: empty
                                ? Icons.mic_none_outlined
                                : Icons.person_outline,
                          ),
                        ),
                      ),
              ),
            ),
          ),
          const SizedBox(height: 10),
          ParticipantActionTarget(
            onTap: onAvatarTap,
            onLongPress: onLongPress,
            child: Text(
              name,
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: theme.textTheme.titleSmall?.copyWith(
                fontWeight: FontWeight.w800,
              ),
            ),
          ),
          const SizedBox(height: 4),
          AnimatedSwitcher(
            duration: const Duration(milliseconds: 220),
            switchInCurve: Curves.easeOutCubic,
            switchOutCurve: Curves.easeInCubic,
            child: Row(
              key: ValueKey<String>('$role|${statusLabel ?? ''}|$muted'),
              children: [
                _TinyPill(label: role),
                if (statusLabel != null) ...[
                  const SizedBox(width: 6),
                  _TinyPill(label: statusLabel!),
                ],
                if (muted) ...[
                  const SizedBox(width: 6),
                  const _TinyPill(label: 'Muted'),
                ],
              ],
            ),
          ),
        ],
      ),
    );
  }
}

class _CommentTile extends StatelessWidget {
  const _CommentTile({
    required this.author,
    required this.text,
    required this.photoUrl,
    required this.system,
    required this.mine,
    this.onAvatarTap,
    this.onAvatarLongPress,
    this.onLongPress,
  });

  final String author;
  final String text;
  final String photoUrl;
  final bool system;
  final bool mine;
  final VoidCallback? onAvatarTap;
  final VoidCallback? onAvatarLongPress;
  final VoidCallback? onLongPress;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    if (system) {
      return Center(
        child: GestureDetector(
          onLongPress: onLongPress,
          child: Container(
            padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 10),
            decoration: BoxDecoration(
              color: theme.colorScheme.surfaceContainerHighest,
              borderRadius: BorderRadius.circular(999),
            ),
            child: Text(
              text,
              style: theme.textTheme.bodyMedium?.copyWith(
                color: theme.colorScheme.onSurfaceVariant,
                fontWeight: FontWeight.w600,
              ),
            ),
          ),
        ),
      );
    }

    return Row(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        if (!mine) ...[
          ParticipantActionTarget(
            onTap: onAvatarTap,
            onLongPress: onAvatarLongPress,
            child: _AvatarBubble(
              photoUrl: photoUrl,
              size: 34,
              fallback: author,
            ),
          ),
          const SizedBox(width: 10),
        ],
        Expanded(
          child: Column(
            crossAxisAlignment: mine
                ? CrossAxisAlignment.end
                : CrossAxisAlignment.start,
            children: [
              if (!mine)
                Padding(
                  padding: const EdgeInsets.only(bottom: 4),
                  child: ParticipantActionTarget(
                    onTap: onAvatarTap,
                    onLongPress: onAvatarLongPress,
                    child: Text(
                      author,
                      style: theme.textTheme.labelMedium?.copyWith(
                        color: theme.colorScheme.onSurfaceVariant,
                      ),
                    ),
                  ),
                ),
              GestureDetector(
                onLongPress: onLongPress,
                child: Container(
                  padding: const EdgeInsets.symmetric(
                    horizontal: 14,
                    vertical: 11,
                  ),
                  decoration: BoxDecoration(
                    color: mine
                        ? theme.colorScheme.primary
                        : theme.colorScheme.surfaceContainerHighest,
                    borderRadius: BorderRadius.circular(18),
                  ),
                  child: Text(
                    text,
                    style: theme.textTheme.bodyMedium?.copyWith(
                      color: mine
                          ? theme.colorScheme.onPrimary
                          : theme.colorScheme.onSurface,
                      height: 1.35,
                    ),
                  ),
                ),
              ),
            ],
          ),
        ),
      ],
    );
  }
}

class _ImmersivePill extends StatelessWidget {
  const _ImmersivePill({
    required this.label,
    required this.filled,
    this.leading,
  });

  final String label;
  final bool filled;
  final String? leading;

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 6),
      decoration: BoxDecoration(
        color: filled ? _LiveScreenState._audioRoomAccent : Colors.white12,
        borderRadius: BorderRadius.circular(999),
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          if (leading != null) ...[
            Text(leading!, style: const TextStyle(fontSize: 15)),
            const SizedBox(width: 6),
          ],
          Text(
            label,
            style: Theme.of(context).textTheme.titleSmall?.copyWith(
              color: Colors.white,
              fontWeight: FontWeight.w700,
              fontSize: 12,
            ),
          ),
        ],
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
    this.scale = 1,
    this.speaking = false,
    this.muted = false,
    this.onTap,
    this.onLongPress,
  });

  final int number;
  final String label;
  final bool occupied;
  final String photoUrl;
  final bool isHostSeat;
  final bool accentBadge;
  final double scale;
  final bool speaking;
  final bool muted;
  final VoidCallback? onTap;
  final VoidCallback? onLongPress;

  @override
  Widget build(BuildContext context) {
    final seatWidth = 96.0 * scale;
    final avatarOuter = 72.0 * scale;
    final avatarInner = 68.0 * scale;
    final badgeSize = 24.0 * scale;
    final placeholderIconSize = 32.0 * scale;
    final badgeBorder = 2.4 * scale;
    final labelFontSize = 12.0 * scale;
    final indexFontSize = 16.0 * scale;

    final circle = Container(
      width: seatWidth,
      alignment: Alignment.topCenter,
      child: Column(
        children: [
          Stack(
            clipBehavior: Clip.none,
            children: [
              if (speaking && occupied)
                _PulsingRing(
                  diameter: 80 * scale,
                  child: Container(
                    width: avatarOuter,
                    height: avatarOuter,
                    decoration: BoxDecoration(
                      shape: BoxShape.circle,
                      color: Colors.white12,
                      border: Border.all(color: Colors.white24, width: 1.6),
                    ),
                    child: ClipOval(
                      child: _AvatarBubble(
                        photoUrl: photoUrl,
                        size: avatarInner,
                        fallback: label.isEmpty ? '$number' : label,
                      ),
                    ),
                  ),
                )
              else
                Container(
                  width: avatarOuter,
                  height: avatarOuter,
                  decoration: BoxDecoration(
                    shape: BoxShape.circle,
                    color: Colors.white12,
                    border: Border.all(color: Colors.white24, width: 1.6),
                  ),
                  child: occupied
                      ? ClipOval(
                          child: _AvatarBubble(
                            photoUrl: photoUrl,
                            size: avatarInner,
                            fallback: label.isEmpty ? '$number' : label,
                          ),
                        )
                      : Icon(
                          Icons.record_voice_over_rounded,
                          color: Colors.white,
                          size: placeholderIconSize,
                        ),
                ),
              if (accentBadge)
                Positioned(
                  left: -2,
                  bottom: -2,
                  child: Container(
                    width: badgeSize,
                    height: badgeSize,
                    decoration: BoxDecoration(
                      color: _LiveScreenState._audioRoomAccent,
                      shape: BoxShape.circle,
                      border: Border.all(
                        color: _LiveScreenState._audioRoomBackground,
                        width: badgeBorder,
                      ),
                    ),
                    child: Icon(
                      Icons.home_rounded,
                      color: Colors.white,
                      size: 13 * scale,
                    ),
                  ),
                ),
              if (occupied && muted)
                Positioned(
                  right: -2,
                  top: -2,
                  child: Container(
                    width: badgeSize,
                    height: badgeSize,
                    decoration: BoxDecoration(
                      color: const Color(0xFFB3261E),
                      shape: BoxShape.circle,
                      border: Border.all(
                        color: _LiveScreenState._audioRoomBackground,
                        width: badgeBorder,
                      ),
                    ),
                    child: Icon(
                      Icons.mic_off_rounded,
                      color: Colors.white,
                      size: 12 * scale,
                    ),
                  ),
                ),
            ],
          ),
          SizedBox(height: 8 * scale),
          if (label.isNotEmpty)
            Text(
              label,
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: Theme.of(context).textTheme.titleMedium?.copyWith(
                color: Colors.white,
                fontWeight: FontWeight.w500,
                fontSize: labelFontSize,
              ),
            ),
          Text(
            '$number',
            style: Theme.of(context).textTheme.headlineSmall?.copyWith(
              color: Colors.white70,
              fontWeight: FontWeight.w400,
              fontSize: indexFontSize,
            ),
          ),
        ],
      ),
    );

    if (onTap == null && onLongPress == null) return circle;
    return GestureDetector(
      onTap: onTap,
      onLongPress: onLongPress,
      child: circle,
    );
  }
}

class _ImmersiveCommentBubble extends StatelessWidget {
  const _ImmersiveCommentBubble({
    required this.author,
    required this.text,
    required this.photoUrl,
    required this.system,
    this.onAvatarTap,
    this.onAvatarLongPress,
    this.onLongPress,
  });

  final String author;
  final String text;
  final String photoUrl;
  final bool system;
  final VoidCallback? onAvatarTap;
  final VoidCallback? onAvatarLongPress;
  final VoidCallback? onLongPress;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final bubble = GestureDetector(
      onLongPress: onLongPress,
      child: Container(
        constraints: const BoxConstraints(maxWidth: 520),
        padding: const EdgeInsets.fromLTRB(14, 10, 14, 12),
        decoration: BoxDecoration(
          color: _LiveScreenState._audioRoomBubble,
          borderRadius: BorderRadius.circular(18),
        ),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              mainAxisSize: MainAxisSize.min,
              children: [
                Container(
                  padding: const EdgeInsets.symmetric(
                    horizontal: 8,
                    vertical: 4,
                  ),
                  decoration: BoxDecoration(
                    color: _LiveScreenState._audioRoomChip,
                    borderRadius: BorderRadius.circular(999),
                  ),
                  child: Text(
                    system ? 'Notice' : author,
                    style: theme.textTheme.titleSmall?.copyWith(
                      color: Colors.white,
                      fontWeight: FontWeight.w700,
                      fontSize: 11,
                    ),
                  ),
                ),
              ],
            ),
            const SizedBox(height: 6),
            Text(
              text,
              style: theme.textTheme.titleLarge?.copyWith(
                color: Colors.white,
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

class _SideRailButton extends StatelessWidget {
  const _SideRailButton({
    required this.icon,
    this.onTap,
    this.badgeLabel,
    this.isActive = false,
  });

  final IconData icon;
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
                child: Icon(
                  icon,
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
                  border: Border.all(
                    color: _LiveScreenState._audioRoomBackground,
                    width: 1.2,
                  ),
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

class _MenuActionTile extends StatelessWidget {
  const _MenuActionTile({
    required this.icon,
    required this.label,
    required this.onTap,
    this.destructive = false,
  });

  final IconData icon;
  final String label;
  final VoidCallback onTap;
  final bool destructive;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final color = destructive
        ? theme.colorScheme.error
        : theme.colorScheme.onSurface;
    return InkWell(
      onTap: onTap,
      borderRadius: BorderRadius.circular(20),
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 4, vertical: 14),
        child: Row(
          children: [
            Icon(icon, color: color),
            const SizedBox(width: 12),
            Text(
              label,
              style: theme.textTheme.titleMedium?.copyWith(
                color: color,
                fontWeight: FontWeight.w700,
              ),
            ),
          ],
        ),
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

class _MiniModeSwitch extends StatelessWidget {
  const _MiniModeSwitch({
    required this.leftLabel,
    required this.rightLabel,
    required this.value,
    required this.onChanged,
  });

  final String leftLabel;
  final String rightLabel;
  final String value;
  final ValueChanged<String> onChanged;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    Widget item(String itemValue, String label) {
      final active = value == itemValue;
      return InkWell(
        onTap: () => onChanged(itemValue),
        borderRadius: BorderRadius.circular(10),
        child: Padding(
          padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 6),
          child: AnimatedDefaultTextStyle(
            duration: const Duration(milliseconds: 180),
            style: theme.textTheme.labelLarge!.copyWith(
              color: active
                  ? theme.colorScheme.onSurface
                  : theme.colorScheme.onSurfaceVariant,
              fontWeight: active ? FontWeight.w800 : FontWeight.w700,
            ),
            child: Text(label),
          ),
        ),
      );
    }

    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 4, vertical: 4),
      decoration: BoxDecoration(
        color: theme.colorScheme.surfaceContainerLow,
        borderRadius: BorderRadius.circular(14),
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          item('broadcast', leftLabel),
          const SizedBox(width: 2),
          item('groups', rightLabel),
        ],
      ),
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
      padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 6),
      decoration: BoxDecoration(
        color: Colors.black.withValues(alpha: 0.18),
        borderRadius: BorderRadius.circular(999),
      ),
      child: Text(
        label,
        style: theme.textTheme.labelMedium?.copyWith(
          color: Colors.white,
          fontWeight: FontWeight.w800,
        ),
      ),
    );
  }
}

class _HostFlagBadge extends StatelessWidget {
  const _HostFlagBadge({required this.code});

  final String code;

  @override
  Widget build(BuildContext context) {
    return SizedBox(
      width: 22,
      height: 14,
      child: Image.network(
        'https://flagcdn.com/w40/${code.toLowerCase()}.png',
        fit: BoxFit.cover,
        errorBuilder: (context, error, stackTrace) => const SizedBox.shrink(),
      ),
    );
  }
}

class _LiveRoomMenuButton extends StatelessWidget {
  const _LiveRoomMenuButton({required this.title});

  final String title;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return PopupMenuButton<String>(
      tooltip: 'Room menu',
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(16)),
      color: theme.colorScheme.surface,
      onSelected: (value) {
        if (value == 'report') {
          ScaffoldMessenger.of(context).showSnackBar(
            SnackBar(content: Text('Report for "$title" is coming next')),
          );
        }
      },
      itemBuilder: (context) => const [
        PopupMenuItem<String>(
          value: 'report',
          child: Row(
            children: [
              Icon(Icons.flag_outlined),
              SizedBox(width: 10),
              Text('Report'),
            ],
          ),
        ),
      ],
      child: Container(
        width: 40,
        height: 40,
        decoration: BoxDecoration(
          color: theme.colorScheme.surface.withValues(alpha: 0.9),
          shape: BoxShape.circle,
          border: Border.all(
            color: theme.colorScheme.outline.withValues(alpha: 0.12),
          ),
        ),
        alignment: Alignment.center,
        child: Icon(
          Icons.more_horiz_rounded,
          color: theme.colorScheme.onSurfaceVariant,
        ),
      ),
    );
  }
}

class _ControlChip extends StatelessWidget {
  const _ControlChip({
    required this.icon,
    required this.label,
    required this.onTap,
    this.destructive = false,
  });

  final IconData icon;
  final String label;
  final VoidCallback onTap;
  final bool destructive;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final background = destructive
        ? theme.colorScheme.errorContainer
        : theme.colorScheme.surfaceContainerHighest;
    final foreground = destructive
        ? theme.colorScheme.onErrorContainer
        : theme.colorScheme.onSurface;

    return InkWell(
      onTap: onTap,
      borderRadius: BorderRadius.circular(999),
      child: Container(
        padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 12),
        decoration: BoxDecoration(
          color: background,
          borderRadius: BorderRadius.circular(999),
        ),
        child: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(icon, size: 18, color: foreground),
            const SizedBox(width: 8),
            Text(
              label,
              style: theme.textTheme.labelLarge?.copyWith(
                color: foreground,
                fontWeight: FontWeight.w700,
              ),
            ),
          ],
        ),
      ),
    );
  }
}

class _MetricChip extends StatelessWidget {
  const _MetricChip({required this.icon, required this.label});

  final IconData icon;
  final String label;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 9),
      decoration: BoxDecoration(
        color: theme.colorScheme.surfaceContainerHighest,
        borderRadius: BorderRadius.circular(999),
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          Icon(icon, size: 16, color: theme.colorScheme.onSurfaceVariant),
          const SizedBox(width: 7),
          Text(
            label,
            style: theme.textTheme.labelLarge?.copyWith(
              fontWeight: FontWeight.w700,
            ),
          ),
        ],
      ),
    );
  }
}

class _AvatarBubble extends StatelessWidget {
  const _AvatarBubble({
    required this.photoUrl,
    required this.size,
    required this.fallback,
    this.icon,
  });

  final String photoUrl;
  final double size;
  final String fallback;
  final IconData? icon;

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
          : icon != null
          ? Icon(
              icon,
              size: size * 0.44,
              color: theme.colorScheme.onSurfaceVariant,
            )
          : Text(
              initials.toUpperCase(),
              style: theme.textTheme.titleMedium?.copyWith(
                fontWeight: FontWeight.w800,
              ),
            ),
    );
  }
}

String _flagCode(String code) {
  final normalized = code.trim().toUpperCase();
  if (normalized.length != 2) return '';
  final first = normalized.codeUnitAt(0);
  final second = normalized.codeUnitAt(1);
  if (first < 0x41 || first > 0x5A || second < 0x41 || second > 0x5A) {
    return '';
  }
  return normalized;
}

class _TinyPill extends StatelessWidget {
  const _TinyPill({required this.label});

  final String label;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
      decoration: BoxDecoration(
        color: theme.colorScheme.primary.withValues(alpha: 0.12),
        borderRadius: BorderRadius.circular(999),
      ),
      child: Text(
        label,
        style: theme.textTheme.labelSmall?.copyWith(
          color: theme.colorScheme.primary,
          fontWeight: FontWeight.w700,
        ),
      ),
    );
  }
}

class _PulsingRing extends StatefulWidget {
  const _PulsingRing({required this.child, this.diameter = 80});

  final Widget child;
  final double diameter;

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
        return Stack(
          alignment: Alignment.center,
          children: [
            Transform.scale(
              scale: _scale.value,
              child: Container(
                width: widget.diameter,
                height: widget.diameter,
                decoration: BoxDecoration(
                  shape: BoxShape.circle,
                  border: Border.all(
                    color: _LiveScreenState._audioRoomAccent.withValues(
                      alpha: _opacity.value,
                    ),
                    width: 3,
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
      _controller
        ..stop()
        ..value = 0;
    }
  }

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  double _measureTextWidth(
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
    return painter.width;
  }

  void _updateAnimation({
    required bool overflowing,
    required double cycleDistance,
  }) {
    if (!overflowing) {
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

    Future<void>.delayed(_initialDelay, () {
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

        final textWidth = _measureTextWidth(
          widget.text,
          style,
          direction,
          scaler,
        );
        final overflowing = textWidth > constraints.maxWidth + 1;
        final cycleDistance = textWidth + _gap;
        final repeatedTrackWidth = (textWidth * 2) + _gap;
        _updateAnimation(
          overflowing: overflowing,
          cycleDistance: cycleDistance,
        );

        if (!overflowing) {
          return Text(
            widget.text,
            style: style,
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
          );
        }

        return ClipRect(
          child: AnimatedBuilder(
            animation: _controller,
            builder: (context, child) {
              final dx = -_controller.value * cycleDistance;
              return Transform.translate(
                offset: Offset(dx, 0),
                child: OverflowBox(
                  alignment: Alignment.centerLeft,
                  minWidth: 0,
                  maxWidth: repeatedTrackWidth,
                  child: SizedBox(
                    width: repeatedTrackWidth,
                    child: Row(
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        Text(
                          widget.text,
                          style: style,
                          maxLines: 1,
                          softWrap: false,
                        ),
                        const SizedBox(width: _gap),
                        Text(
                          widget.text,
                          style: style,
                          maxLines: 1,
                          softWrap: false,
                        ),
                      ],
                    ),
                  ),
                ),
              );
            },
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
