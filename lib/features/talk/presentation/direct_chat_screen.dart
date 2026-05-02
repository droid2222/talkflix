import 'dart:async';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_webrtc/flutter_webrtc.dart';
import 'package:go_router/go_router.dart';
import 'package:image_picker/image_picker.dart';
import 'package:just_audio/just_audio.dart';
import 'package:record/record.dart';

import '../../../app/theme/app_theme.dart';
import '../../../core/auth/session_controller.dart';
import '../../../core/config/storage_keys.dart';
import '../../../core/media/audio_message_player.dart';
import '../../../core/media/media_permission_service.dart';
import '../../../core/media/media_utils.dart';
import '../../../core/realtime/direct_call_controller.dart';
import '../../../core/realtime/socket_service.dart';
import '../../../core/realtime/webrtc_service.dart';
import '../../../core/widgets/app_avatar.dart';
import '../../../core/widgets/participant_action_target.dart';
import '../../../core/widgets/realtime_warning_banner.dart';
import '../../profile/presentation/profile_screen.dart';
import '../data/chat_message.dart';
import 'direct_chat_controller.dart';

class DirectChatScreen extends ConsumerStatefulWidget {
  const DirectChatScreen({super.key, required this.userId});

  final String userId;

  @override
  ConsumerState<DirectChatScreen> createState() => _DirectChatScreenState();
}

class _DirectChatScreenState extends ConsumerState<DirectChatScreen> {
  final _composerController = TextEditingController();
  final _scrollController = ScrollController();
  final _picker = ImagePicker();
  final _audioRecorder = AudioRecorder();
  final _ringtonePlayer = AudioPlayer();
  final _permissionService = MediaPermissionService();
  final _webRtcService = WebRtcService();
  final _localRenderer = RTCVideoRenderer();
  final _remoteRenderer = RTCVideoRenderer();

  Timer? _typingTimer;
  Timer? _recordingTimer;
  Timer? _callTimeoutTimer;
  Timer? _callDurationTimer;
  Timer? _replyHighlightTimer;
  Future<void>? _callPreparationFuture;
  DateTime? _lastSafetyRefreshAt;

  RTCPeerConnection? _peerConnection;
  final List<RTCIceCandidate> _pendingRemoteCandidates = [];

  int _recordingSeconds = 0;
  int _callSeconds = 0;
  bool _recording = false;
  bool _composerActionBusy = false;
  bool _renderersReady = false;
  bool _callIncoming = false;
  bool _callDialing = false;
  bool _callConnected = false;
  bool _callMinimized = false;
  bool _callInitiator = false;
  bool _callVideoPreferred = false;
  bool _localVideoEnabled = false;
  bool _remoteVideoEnabled = false;
  bool _cameraBusy = false;
  bool _localVideoMirrored = true;
  bool _micEnabled = true;
  bool _speakerOn = false;
  bool _remoteDescriptionReady = false;
  bool _threadNotificationsMuted = false;
  bool _autoTranslateIncoming = false;
  bool _autoPlayReceivedVoiceNotes = false;
  bool _showTranslateAction = false;
  bool _enableCorrectionAction = false;
  String _correctionTone = 'friendly';
  final Map<String, String> _translatedMessageById = <String, String>{};
  final Map<String, int> _autoPlayTokenByMessageId = <String, int>{};
  final Map<String, bool> _autoPlayBadgeVisibleByMessageId = <String, bool>{};
  int _nextAutoPlayToken = 1;
  String _socketStatus = 'disconnected';
  String? _callStatus;
  String? _pendingAudioUrl;
  int _pendingAudioDuration = 0;
  String _pendingAudioMimeType = 'audio/m4a';
  String? _highlightedMessageId;

  String get _meId => ref.read(sessionControllerProvider).user?.id ?? '';

  String get _threadId =>
      ref.read(directChatControllerProvider(widget.userId)).threadId;

  SocketService get _socket => ref.read(socketServiceProvider);
  String get _threadNotificationPrefKey =>
      'talkflix_thread_muted_${widget.userId}';
  bool get _hasActiveCallSession =>
      _callIncoming || _callDialing || _callConnected;

  @override
  void initState() {
    super.initState();
    _socketStatus = _socket.status;
    _socket.addListener(_handleSocketStatusChanged);
    _composerController.addListener(_handleComposerTextChanged);
    unawaited(_configureRingtone());
    Future<void>.microtask(_loadThreadPrefs);
    Future<void>.microtask(_initializeRealtimeBits);
  }

  Future<void> _configureRingtone() async {
    try {
      await _ringtonePlayer.setAsset('assets/audio/anon-ringtone.wav');
      await _ringtonePlayer.setLoopMode(LoopMode.one);
    } catch (_) {}
  }

  Future<void> _playIncomingRingtone() async {
    try {
      await _ringtonePlayer.seek(Duration.zero);
      await _ringtonePlayer.play();
    } catch (_) {}
  }

  Future<void> _stopIncomingRingtone() async {
    try {
      await _ringtonePlayer.stop();
    } catch (_) {}
  }

  Future<void> _loadThreadPrefs() async {
    final prefs = await ref.read(sharedPreferencesProvider.future);
    if (!mounted) return;
    setState(() {
      _threadNotificationsMuted =
          prefs.getBool(_threadNotificationPrefKey) ?? false;
      _autoTranslateIncoming =
          prefs.getBool(StorageKeys.chatAutoTranslateIncoming) ?? false;
      _autoPlayReceivedVoiceNotes =
          prefs.getBool(StorageKeys.chatPlayVoiceNotesAuto) ?? false;
      _showTranslateAction =
          prefs.getBool(StorageKeys.chatShowTranslationOnLongPress) ?? false;
      _enableCorrectionAction =
          prefs.getBool(StorageKeys.chatEnableWritingCorrections) ?? false;
      _correctionTone =
          prefs.getString(StorageKeys.chatCorrectionTone) ?? 'friendly';
    });
  }

  Future<void> _maybeAutoTranslateMessages(List<ChatMessage> messages) async {
    if (!_autoTranslateIncoming) return;
    final chatState = ref.read(directChatControllerProvider(widget.userId));
    if (!chatState.supportsTranslation) return;
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
    final controller = ref.read(
      directChatControllerProvider(widget.userId).notifier,
    );
    for (final message in targets) {
      final result = await controller.translateMessage(message);
      if (!mounted) return;
      final translated = result.output.trim();
      if (translated.isEmpty) continue;
      setState(() {
        _translatedMessageById[message.id] = translated;
      });
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
    await _remoteRenderer.initialize();
    _socket.on('dm:call:request', _onCallRequest);
    _socket.on('dm:call:accept', _onCallAccept);
    _socket.on('dm:rtc:offer', _onRtcOffer);
    _socket.on('dm:rtc:answer', _onRtcAnswer);
    _socket.on('dm:rtc:ice', _onRtcIce);
    _socket.on('dm:call:end', _onCallEnded);
    _socket.on('dm:call:cancel', _onCallCancelled);
    _socket.on('dm:call:missed', _onCallMissed);
    _socket.on('dm:call:camera-state', _onRemoteCameraState);
    if (mounted) {
      setState(() => _renderersReady = true);
    }
    await _resumeAcceptedGlobalCallIfNeeded();
  }

  Future<void> _resumeAcceptedGlobalCallIfNeeded() async {
    final pending = ref
        .read(directCallControllerProvider.notifier)
        .consumePendingForPartner(widget.userId);
    if (pending == null) return;
    _callVideoPreferred = pending.video;
    await _prepareCallSession(video: pending.video);
    if (!mounted) return;
    setState(() {
      _callMinimized = false;
      _callIncoming = false;
      _callDialing = true;
      _callInitiator = false;
      _callStatus = 'Connecting...';
    });
    _startCallTimeout('Connection took too long. Try calling again.');
  }

  @override
  void dispose() {
    _typingTimer?.cancel();
    _recordingTimer?.cancel();
    _callDurationTimer?.cancel();
    _replyHighlightTimer?.cancel();
    _composerController.dispose();
    _scrollController.dispose();
    _audioRecorder.dispose();
    _ringtonePlayer.dispose();
    _socket.off('dm:call:request', _onCallRequest);
    _socket.off('dm:call:accept', _onCallAccept);
    _socket.off('dm:rtc:offer', _onRtcOffer);
    _socket.off('dm:rtc:answer', _onRtcAnswer);
    _socket.off('dm:rtc:ice', _onRtcIce);
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
    ref
        .read(directChatControllerProvider(widget.userId).notifier)
        .sendTyping(false);
    await ref
        .read(directChatControllerProvider(widget.userId).notifier)
        .sendTextMessage(text);
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
    await ref
        .read(directChatControllerProvider(widget.userId).notifier)
        .sendImageMessage(
          bytes: bytes,
          mimeType: file.mimeType ?? 'image/jpeg',
        );
    _scrollToBottom();
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
    await ref
        .read(directChatControllerProvider(widget.userId).notifier)
        .sendAudioMessage(
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

  void _handleDraftChanged(String value) {
    if (mounted) setState(() {});
    if (!_socket.isConnected) return;
    final controller = ref.read(
      directChatControllerProvider(widget.userId).notifier,
    );
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

  Future<void> _startCall({required bool video}) async {
    if (_threadId.isEmpty || _callDialing || _callConnected) return;
    if (!_socket.isConnected) {
      _showSnack('You are offline. Reconnect before starting a call.');
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
    final chatState = ref.read(directChatControllerProvider(widget.userId));
    if (chatState.blocked) {
      _showSnack(
        chatState.youBlockedUser
            ? 'This user is blocked. Unblock to accept calls.'
            : 'This chat is unavailable for calls right now.',
      );
      _declineIncomingCall();
      return;
    }
    if (!_socket.isConnected) {
      _showSnack('You are offline. Reconnect before accepting the call.');
      return;
    }
    await _stopIncomingRingtone();
    final threadId = _threadId;
    if (threadId.isNotEmpty) {
      unawaited(
        _socket.emitWithAckFuture('dm:call:accept', <String, dynamic>{
          'threadId': threadId,
          'accept': true,
        }, timeout: const Duration(seconds: 2)),
      );
    }
    setState(() {
      _callMinimized = false;
      _callIncoming = false;
      _callDialing = true;
      _callInitiator = false;
      _callStatus = 'Connecting...';
    });
    try {
      await _ensurePreparedCall(video: _callVideoPreferred);
      _startCallTimeout('Connection took too long. Try calling again.');
    } catch (_) {
      _showSnack('Could not accept call.');
      await _cleanupCall(sendSignal: false);
    }
  }

  void _declineIncomingCall() {
    unawaited(_stopIncomingRingtone());
    final threadId = _threadId;
    if (threadId.isNotEmpty) {
      unawaited(
        _socket.emitWithAckFuture('dm:call:accept', <String, dynamic>{
          'threadId': threadId,
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

    _localRenderer.srcObject = stream;
    _localVideoEnabled = stream.getVideoTracks().any((track) => track.enabled);
    _localVideoMirrored = _localVideoEnabled;
    _micEnabled = stream.getAudioTracks().any((track) => track.enabled);

    if (_peerConnection == null) {
      _peerConnection = await createPeerConnection({
        'iceServers': [
          {'urls': 'stun:stun.l.google.com:19302'},
          {'urls': 'stun:stun1.l.google.com:19302'},
        ],
      });

      _peerConnection!.onIceCandidate = (candidate) {
        if (candidate.candidate == null || _threadId.isEmpty) return;
        _socket.emit('dm:rtc:ice', <String, dynamic>{
          'threadId': _threadId,
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
          _clearCallTimeout();
          _startCallDuration();
          unawaited(_stopIncomingRingtone());
          setState(() {
            _callConnected = true;
            _callDialing = false;
            _callStatus = 'Connected';
          });
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
        await _peerConnection!.addTrack(track, stream);
      }
    }

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

  Future<void> _createAndSendOffer() async {
    if (_peerConnection == null) return;
    final offer = await _peerConnection!.createOffer();
    await _peerConnection!.setLocalDescription(offer);
    _socket.emit('dm:rtc:offer', <String, dynamic>{
      'threadId': _threadId,
      'sdp': offer.toMap(),
    });
  }

  Future<void> _flushPendingIce() async {
    if (_peerConnection == null) return;
    while (_pendingRemoteCandidates.isNotEmpty) {
      final candidate = _pendingRemoteCandidates.removeAt(0);
      await _peerConnection!.addCandidate(candidate);
    }
  }

  void _onCallRequest(dynamic data) {
    if (data is! Map) return;
    final payload = Map<String, dynamic>.from(data);
    if (payload['threadId']?.toString() != _threadId) return;
    if (payload['fromUserId']?.toString() == _meId) return;
    final chatState = ref.read(directChatControllerProvider(widget.userId));
    if (chatState.blocked) {
      final threadId = _threadId;
      if (threadId.isNotEmpty) {
        unawaited(
          _socket.emitWithAckFuture('dm:call:accept', <String, dynamic>{
            'threadId': threadId,
            'accept': false,
          }, timeout: const Duration(seconds: 2)),
        );
      }
      return;
    }
    if (!mounted) return;
    setState(() {
      _callMinimized = false;
      _callIncoming = true;
      _callDialing = false;
      _callInitiator = false;
      _callVideoPreferred = payload['video'] == true;
      _callStatus = _callVideoPreferred
          ? 'Incoming video call'
          : 'Incoming call';
    });
    unawaited(_playIncomingRingtone());
  }

  Future<void> _onCallAccept(dynamic data) async {
    if (data is! Map) return;
    final payload = Map<String, dynamic>.from(data);
    if (payload['threadId']?.toString() != _threadId) return;
    if (payload['fromUserId']?.toString() == _meId) return;

    if (payload['accept'] != true) {
      _showSnack('Call declined.');
      await _cleanupCall(sendSignal: false);
      return;
    }

    await _stopIncomingRingtone();
    _callVideoPreferred = payload['video'] == true || _callVideoPreferred;
    if (!mounted) return;
    setState(() {
      _callMinimized = false;
      _callIncoming = false;
      _callDialing = true;
      _callStatus = 'Connecting...';
    });
    try {
      await _ensurePreparedCall(video: _callVideoPreferred);
      _startCallTimeout('Connection took too long. Try calling again.');
      if (_callInitiator) {
        await _createAndSendOffer();
      }
    } catch (_) {
      _showSnack('Could not connect call.');
      await _cleanupCall(sendSignal: false);
    }
  }

  Future<void> _onRtcOffer(dynamic data) async {
    if (data is! Map) return;
    final payload = Map<String, dynamic>.from(data);
    if (payload['threadId']?.toString() != _threadId) return;
    if (payload['fromUserId']?.toString() == _meId) return;

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
      'sdp': answer.toMap(),
    });
    if (!mounted) return;
    setState(() => _callStatus = 'Connecting...');
  }

  Future<void> _onRtcAnswer(dynamic data) async {
    if (data is! Map) return;
    final payload = Map<String, dynamic>.from(data);
    if (payload['threadId']?.toString() != _threadId) return;
    if (payload['fromUserId']?.toString() == _meId) return;
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
    if (data is! Map) return;
    final payload = Map<String, dynamic>.from(data);
    if (payload['threadId']?.toString() != _threadId) return;
    if (payload['fromUserId']?.toString() == _meId) return;
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
    if (data is! Map) return;
    final payload = Map<String, dynamic>.from(data);
    if (payload['threadId']?.toString() != _threadId) return;
    if (payload['fromUserId']?.toString() == _meId) return;
    if (!mounted) return;
    setState(() => _remoteVideoEnabled = payload['enabled'] == true);
  }

  Future<void> _onCallEnded(dynamic data) async {
    if (data is! Map) return;
    final payload = Map<String, dynamic>.from(data);
    if (payload['threadId']?.toString() != _threadId) return;
    await _stopIncomingRingtone();
    await _cleanupCall(sendSignal: false);
  }

  Future<void> _onCallCancelled(dynamic data) async {
    if (data is! Map) return;
    final payload = Map<String, dynamic>.from(data);
    if (payload['threadId']?.toString() != _threadId) return;
    await _stopIncomingRingtone();
    _showSnack('Call cancelled.');
    await _cleanupCall(sendSignal: false);
  }

  Future<void> _onCallMissed(dynamic data) async {
    if (data is! Map) return;
    final payload = Map<String, dynamic>.from(data);
    if (payload['threadId']?.toString() != _threadId) return;
    await _stopIncomingRingtone();
    _showSnack('Missed call.');
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
        MediaStream camStream;
        try {
          camStream = await navigator.mediaDevices.getUserMedia({
            'audio': false,
            'video': {'facingMode': 'user'},
          });
        } catch (_) {
          _showSnack('Camera permission is required to turn on video.');
          return;
        }
        final newVideoTrack = camStream.getVideoTracks().isNotEmpty
            ? camStream.getVideoTracks().first
            : null;
        if (newVideoTrack == null) return;

        unawaited(local.addTrack(newVideoTrack));
        final senders = await _peerConnection!.getSenders();
        final existingVideoSender = senders.cast<RTCRtpSender?>().firstWhere(
          (sender) => sender?.track?.kind == 'video',
          orElse: () => null,
        );
        if (existingVideoSender != null) {
          await existingVideoSender.replaceTrack(newVideoTrack);
        } else {
          await _peerConnection!.addTrack(newVideoTrack, local);
        }
        _localRenderer.srcObject = local;
        setState(() {
          _localVideoEnabled = true;
          _localVideoMirrored = true;
          _callVideoPreferred = true;
        });
        await _createAndSendOffer();
        _socket.emit('dm:call:camera-state', <String, dynamic>{
          'threadId': _threadId,
          'enabled': true,
        });
        return;
      }

      for (final track in local.getVideoTracks()) {
        await track.stop();
        unawaited(local.removeTrack(track));
      }
      final senders = await _peerConnection!.getSenders();
      for (final sender in senders) {
        if (sender.track?.kind == 'video') {
          await sender.replaceTrack(null);
        }
      }
      _localRenderer.srcObject = local;
      setState(() {
        _localVideoEnabled = false;
        _localVideoMirrored = true;
      });
      await _createAndSendOffer();
      _socket.emit('dm:call:camera-state', <String, dynamic>{
        'threadId': _threadId,
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
    _stopCallDuration();
    await _stopIncomingRingtone();
    if (sendSignal && _threadId.isNotEmpty) {
      if (_callConnected) {
        _socket.emitRedundant('dm:call:end', <String, dynamic>{
          'threadId': _threadId,
        });
      } else if (_callDialing || _callIncoming) {
        _socket.emitRedundant('dm:call:cancel', <String, dynamic>{
          'threadId': _threadId,
        });
      }
    }
    await _peerConnection?.close();
    _peerConnection = null;
    _pendingRemoteCandidates.clear();
    _remoteDescriptionReady = false;
    _callPreparationFuture = null;
    _localRenderer.srcObject = null;
    _remoteRenderer.srcObject = null;
    await _webRtcService.disposeLocalStream();
    if (!mounted) return;
    setState(() {
      _callMinimized = false;
      _callIncoming = false;
      _callDialing = false;
      _callConnected = false;
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
    final nextStatus = _socket.status;
    if (nextStatus == _socketStatus || !mounted) return;
    _socketStatus = nextStatus;

    if ((_callIncoming || _callDialing || _callConnected) &&
        (nextStatus == 'connecting' ||
            nextStatus == 'disconnected' ||
            nextStatus == 'error')) {
      setState(() {
        _callStatus = 'Connection changed. Ending call session...';
      });
      unawaited(_cleanupCall(sendSignal: false));
      return;
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
    ref.read(directChatControllerProvider(widget.userId).notifier).reload();
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

  Future<void> _openMessageActions(ChatMessage message) async {
    final chatState = ref.read(directChatControllerProvider(widget.userId));
    final canTranslate = _showTranslateAction && chatState.supportsTranslation;
    final canCorrect = _enableCorrectionAction && chatState.supportsCorrection;
    await showModalBottomSheet<void>(
      context: context,
      builder: (context) {
        return SafeArea(
          child: Wrap(
            children: [
              ListTile(
                leading: const Icon(Icons.reply_rounded),
                title: const Text('Reply'),
                onTap: () {
                  Navigator.of(context).pop();
                  ref
                      .read(
                        directChatControllerProvider(widget.userId).notifier,
                      )
                      .setReplyTarget(message);
                },
              ),
              if (canTranslate)
                ListTile(
                  leading: const Icon(Icons.translate_rounded),
                  title: const Text('Translate'),
                  onTap: () async {
                    Navigator.of(context).pop();
                    await _runTranslate(message);
                  },
                ),
              if (canCorrect)
                ListTile(
                  leading: const Icon(Icons.spellcheck_rounded),
                  title: Text('Correct (${_correctionTone.toLowerCase()})'),
                  onTap: () async {
                    Navigator.of(context).pop();
                    await _runCorrection(message);
                  },
                ),
              if (message.canRetry)
                ListTile(
                  leading: const Icon(Icons.refresh_rounded),
                  title: const Text('Retry send'),
                  onTap: () {
                    Navigator.of(context).pop();
                    ref
                        .read(
                          directChatControllerProvider(widget.userId).notifier,
                        )
                        .retryFailedMessage(message.id);
                  },
                ),
              ListTile(
                leading: const Icon(Icons.copy_rounded),
                title: const Text('Copy text'),
                onTap: () {
                  Navigator.of(context).pop();
                  final text = message.text.trim();
                  if (text.isNotEmpty) {
                    Clipboard.setData(ClipboardData(text: text));
                    _showSnack('Copied');
                  }
                },
              ),
              ListTile(
                leading: const Icon(Icons.flag_outlined),
                title: const Text('Report'),
                onTap: () async {
                  Navigator.of(context).pop();
                  final reason = await _pickReportReason();
                  if (reason == null) return;
                  final ok = await ref
                      .read(
                        directChatControllerProvider(widget.userId).notifier,
                      )
                      .reportMessage(messageId: message.id, reason: reason);
                  _showSnack(
                    ok
                        ? 'Thanks. Your message report was submitted.'
                        : 'Could not submit report right now.',
                  );
                },
              ),
            ],
          ),
        );
      },
    );
  }

  Future<void> _runTranslate(ChatMessage message) async {
    final controller = ref.read(
      directChatControllerProvider(widget.userId).notifier,
    );
    final result = await controller.translateMessage(message);
    if (!mounted) return;
    await _showLearningResultSheet(
      title: 'Translation',
      original: message.text.trim(),
      output: result.output,
      note: result.note,
      emptyFallback: 'No translation result returned.',
    );
  }

  Future<void> _runCorrection(ChatMessage message) async {
    final controller = ref.read(
      directChatControllerProvider(widget.userId).notifier,
    );
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

  Future<void> _showChatMenu() async {
    final scheme = Theme.of(context).colorScheme;
    final chatState = ref.read(directChatControllerProvider(widget.userId));
    final youBlockedUser = chatState.youBlockedUser;
    await showModalBottomSheet<void>(
      context: context,
      backgroundColor: Theme.of(context).colorScheme.surface,
      shape: const RoundedRectangleBorder(
        borderRadius: BorderRadius.vertical(top: Radius.circular(28)),
      ),
      builder: (context) {
        return SafeArea(
          top: false,
          child: Padding(
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
                    Navigator.of(context).pop();
                    this.context.push('/app/profile/${widget.userId}');
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
                    Navigator.of(context).pop();
                    final prefs = await ref.read(
                      sharedPreferencesProvider.future,
                    );
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
                ListTile(
                  leading: const Icon(Icons.refresh_rounded),
                  title: const Text('Refresh chat'),
                  onTap: () {
                    Navigator.of(context).pop();
                    ref
                        .read(
                          directChatControllerProvider(widget.userId).notifier,
                        )
                        .reload();
                  },
                ),
                ListTile(
                  leading: const Icon(Icons.flag_outlined),
                  title: const Text('Report user'),
                  onTap: () async {
                    Navigator.of(context).pop();
                    final reason = await _pickReportReason();
                    if (reason == null) return;
                    final ok = await ref
                        .read(
                          directChatControllerProvider(widget.userId).notifier,
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
                  title: Text(youBlockedUser ? 'Unblock user' : 'Block user'),
                  onTap: () async {
                    Navigator.of(context).pop();
                    final confirmed = await _confirmBlockToggle(
                      currentlyBlocked: youBlockedUser,
                    );
                    if (!confirmed) return;
                    final notifier = ref.read(
                      directChatControllerProvider(widget.userId).notifier,
                    );
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
        );
      },
    );
  }

  void _scrollToBottom() {
    WidgetsBinding.instance.addPostFrameCallback((_) {
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
    ref.listen<DirectChatState>(directChatControllerProvider(widget.userId), (
      previous,
      next,
    ) {
      if (previous?.messages.length != next.messages.length) {
        _scrollToBottom();
      }
      _maybeAutoPlayIncomingVoiceNotes(next.messages);
      unawaited(_maybeAutoTranslateMessages(next.messages));
    });

    final chatState = ref.watch(directChatControllerProvider(widget.userId));
    final me = ref.watch(sessionControllerProvider).user;
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
        _callVideoPreferred || _localVideoEnabled || _remoteVideoEnabled;
    final subtitle = chatState.theirTyping
        ? 'typing...'
        : socketStatus != 'connected'
        ? 'reconnecting...'
        : chatState.partnerOnline
        ? 'online'
        : 'offline';
    final isDark = Theme.of(context).brightness == Brightness.dark;
    final scheme = Theme.of(context).colorScheme;
    final headerSurface = isDark ? const Color(0xFF111214) : Colors.white;
    final incomingBubble = isDark ? const Color(0xFF292A2E) : Colors.white;
    final incomingText = isDark ? Colors.white : Colors.black;
    final replyTarget = chatState.replyTargetMessage;
    final youBlockedUser = chatState.youBlockedUser;

    return Focus(
      onFocusChange: (hasFocus) {
        if (!hasFocus || !mounted) return;
        _refreshSafetyStateIfNeeded();
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
                  child: Column(
                    children: [
                      Row(
                        children: [
                          IconButton(
                            onPressed: () => Navigator.of(context).maybePop(),
                            icon: const Icon(Icons.arrow_back_ios_new_rounded),
                          ),
                          Expanded(
                            child: partner.when(
                              data: (user) => ParticipantActionTarget(
                                onTap: () => context.push(
                                  '/app/profile/${widget.userId}',
                                ),
                                child: Row(
                                  children: [
                                    AppAvatar(
                                      label: user.displayName,
                                      imageUrl: user.profilePhotoUrl,
                                      radius: 20,
                                    ),
                                    const SizedBox(width: 10),
                                    Expanded(
                                      child: Column(
                                        crossAxisAlignment:
                                            CrossAxisAlignment.start,
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
                                                  fontWeight:
                                                      chatState.theirTyping
                                                      ? FontWeight.w600
                                                      : null,
                                                ),
                                          ),
                                        ],
                                      ),
                                    ),
                                  ],
                                ),
                              ),
                              error: (error, stackTrace) =>
                                  Text('User ${widget.userId}'),
                              loading: () => const Text('Direct chat'),
                            ),
                          ),
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
                          IconButton(
                            onPressed: _showChatMenu,
                            icon: const Icon(Icons.more_horiz_rounded),
                          ),
                        ],
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
                  child: Padding(
                    padding: const EdgeInsets.fromLTRB(16, 8, 16, 14),
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
                          padding: const EdgeInsets.fromLTRB(12, 10, 10, 10),
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
                                      : _pickAndSendImage,
                                  padding: EdgeInsets.zero,
                                  icon: Icon(
                                    Icons.image_outlined,
                                    color: scheme.onSurface,
                                    size: 20,
                                  ),
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
                                      !chatState.blocked,
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
                              const SizedBox(width: 10),
                              Container(
                                width: 46,
                                height: 46,
                                decoration: BoxDecoration(
                                  color:
                                      _composerController.text
                                              .trim()
                                              .isNotEmpty ||
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
                                          chatState.blocked
                                      ? null
                                      : _handleComposerPrimaryAction,
                                  padding: EdgeInsets.zero,
                                  icon: Icon(
                                    _composerController.text
                                                .trim()
                                                .isNotEmpty ||
                                            _pendingAudioUrl != null
                                        ? Icons.send_rounded
                                        : _recording
                                        ? Icons.stop_circle_outlined
                                        : Icons.mic_none_outlined,
                                    color:
                                        _composerController.text
                                                .trim()
                                                .isNotEmpty ||
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
                  localVideoEnabled: _localVideoEnabled,
                  localVideoMirrored: _localVideoMirrored,
                  micEnabled: _micEnabled,
                  speakerOn: _speakerOn,
                  status: _callStatus,
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
    required this.onMessageLongPress,
    required this.onRetryMessage,
    required this.onReplyPreviewTap,
    required this.translatedByMessageId,
    required this.autoplayTokenByMessageId,
    required this.autoPlayEnabled,
    required this.autoPlayBadgeVisibleByMessageId,
    required this.onIncomingAudioPlaybackStarted,
    required this.onIncomingAudioPlaybackCompleted,
    this.highlightedMessageId,
  });

  final ScrollController scrollController;
  final List<ChatMessage> messages;
  final String currentUserId;
  final Color incomingBubble;
  final Color incomingText;
  final ValueChanged<ChatMessage> onMessageLongPress;
  final ValueChanged<String> onRetryMessage;
  final ValueChanged<String> onReplyPreviewTap;
  final Map<String, String> translatedByMessageId;
  final Map<String, int> autoplayTokenByMessageId;
  final bool autoPlayEnabled;
  final Map<String, bool> autoPlayBadgeVisibleByMessageId;
  final ValueChanged<String> onIncomingAudioPlaybackStarted;
  final ValueChanged<String> onIncomingAudioPlaybackCompleted;
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
        return Padding(
          padding: const EdgeInsets.only(bottom: 10),
          child: Align(
            alignment: isMine ? Alignment.centerRight : Alignment.centerLeft,
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
                      GestureDetector(
                        onLongPress: () => onMessageLongPress(message),
                        child: DefaultTextStyle.merge(
                          style: TextStyle(
                            color: message.isFailed
                                ? Theme.of(context).colorScheme.onErrorContainer
                                : (isMine ? Colors.white : incomingText),
                            fontSize: 16,
                            fontWeight: FontWeight.w600,
                          ),
                          child: _MessageBody(
                            message: message,
                            mine: isMine,
                            messagesById: messagesById,
                            onReplyPreviewTap: onReplyPreviewTap,
                            translatedText: translatedByMessageId[message.id],
                            autoplayToken:
                                autoplayTokenByMessageId[message.id] ?? 0,
                            showAutoplayBadge:
                                autoPlayEnabled &&
                                !isMine &&
                                message.type == 'audio' &&
                                (autoPlayBadgeVisibleByMessageId[message.id] ??
                                    false),
                            onAudioPlaybackStarted: () =>
                                onIncomingAudioPlaybackStarted(message.id),
                            onAudioPlaybackCompleted: () =>
                                onIncomingAudioPlaybackCompleted(message.id),
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
                                  color: Theme.of(context).colorScheme.error,
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
                                        ? Colors.white.withValues(alpha: 0.78)
                                        : Theme.of(
                                            context,
                                          ).colorScheme.onSurfaceVariant,
                                  ),
                            ),
                            if (isLastMine) ...[
                              const SizedBox(width: 8),
                              Text(
                                _formatMessageStatus(message.status),
                                style: Theme.of(context).textTheme.bodySmall
                                    ?.copyWith(
                                      color: isMine
                                          ? Colors.white.withValues(alpha: 0.86)
                                          : Theme.of(
                                              context,
                                            ).colorScheme.onSurfaceVariant,
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

class _MessageBody extends StatelessWidget {
  const _MessageBody({
    required this.message,
    required this.mine,
    required this.messagesById,
    required this.onReplyPreviewTap,
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
  return '[${message.type}]';
}

class _MessageBodyContent extends StatelessWidget {
  const _MessageBodyContent({
    required this.message,
    required this.mine,
    this.translatedText,
    this.autoplayToken = 0,
    this.showAutoplayBadge = false,
    this.onAudioPlaybackStarted,
    this.onAudioPlaybackCompleted,
  });

  final ChatMessage message;
  final bool mine;
  final String? translatedText;
  final int autoplayToken;
  final bool showAutoplayBadge;
  final VoidCallback? onAudioPlaybackStarted;
  final VoidCallback? onAudioPlaybackCompleted;

  @override
  Widget build(BuildContext context) {
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

    final text = message.text.isEmpty ? '[${message.type}]' : message.text;
    if (!mine &&
        message.type == 'text' &&
        (translatedText?.trim().isNotEmpty ?? false)) {
      return Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(text),
          const SizedBox(height: 4),
          Text(
            translatedText!,
            style: Theme.of(context).textTheme.bodySmall?.copyWith(
              fontStyle: FontStyle.italic,
              color: Theme.of(context).colorScheme.onSurfaceVariant,
              fontWeight: FontWeight.w600,
            ),
          ),
        ],
      );
    }
    return Text(text);
  }
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
    final primaryMirror = !_primaryVideoRemote && widget.localVideoMirrored;
    final previewMirror = _primaryVideoRemote && widget.localVideoMirrored;

    return ColoredBox(
      color: Colors.black,
      child: LayoutBuilder(
        builder: (context, constraints) => Stack(
          children: [
            Positioned.fill(
              child: showAnyVideo
                  ? RTCVideoView(
                      primaryRenderer,
                      mirror: primaryMirror,
                      objectFit:
                          RTCVideoViewObjectFit.RTCVideoViewObjectFitCover,
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
                      child: RTCVideoView(
                        previewRenderer,
                        mirror: previewMirror,
                        objectFit:
                            RTCVideoViewObjectFit.RTCVideoViewObjectFitCover,
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
