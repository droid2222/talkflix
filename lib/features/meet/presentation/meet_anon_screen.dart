import 'dart:async';
import 'dart:io';
import 'dart:math';
import 'dart:ui';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_webrtc/flutter_webrtc.dart';
import 'package:image_picker/image_picker.dart';
import 'package:just_audio/just_audio.dart';
import 'package:record/record.dart';

import '../../../app/theme/app_theme.dart';
import '../../../core/network/api_client.dart';
import '../../../core/auth/app_user.dart';
import '../../../core/auth/session_controller.dart';
import '../../../core/config/app_config.dart';
import '../../../core/media/audio_message_player.dart';
import '../../../core/media/media_permission_service.dart';
import '../../../core/media/media_utils.dart';
import '../../../core/realtime/socket_service.dart';
import '../../../core/realtime/webrtc_service.dart';
import '../../../core/widgets/realtime_warning_banner.dart';

class MeetAnonScreen extends ConsumerStatefulWidget {
  const MeetAnonScreen({super.key});

  @override
  ConsumerState<MeetAnonScreen> createState() => _MeetAnonScreenState();
}

class _MeetAnonScreenState extends ConsumerState<MeetAnonScreen> {
  final _draftController = TextEditingController();
  final _scrollController = ScrollController();
  final _imagePicker = ImagePicker();
  final _audioRecorder = AudioRecorder();
  final _ringtonePlayer = AudioPlayer();
  final _permissionService = MediaPermissionService();
  final _localRenderer = RTCVideoRenderer();
  final _remoteRenderer = RTCVideoRenderer();

  Timer? _typingTimer;
  Timer? _countdownTimer;
  Timer? _recordingTimer;
  Timer? _callTimeoutTimer;
  Timer? _callDurationTimer;
  Timer? _autoRejoinTimer;

  RTCPeerConnection? _peerConnection;
  final List<RTCIceCandidate> _pendingRemoteCandidates = [];

  String _phase = 'criteria';
  String _language = 'English';
  String _gender = 'any';
  double _ageMin = 18;
  double _ageMax = 35;
  String? _matchId;
  final List<_AnonMessage> _messages = [];
  bool _theirTyping = false;
  bool _allowFollow = false;
  bool _partnerAllowsFollow = false;
  String? _partnerId;
  bool _followBusy = false;
  bool _followed = false;
  int _secondsRemaining = 0;
  bool _callIncoming = false;
  bool _callRequesting = false;
  bool _callAccepted = false;
  bool _callConnected = false;
  bool _callInitiator = false;
  bool _callOpen = false;
  bool _localVideoEnabled = false;
  bool _remoteVideoEnabled = false;
  bool _cameraBusy = false;
  bool _localVideoMirrored = true;
  bool _micEnabled = true;
  bool _speakerOn = false;
  bool _recording = false;
  int _recordingSeconds = 0;
  String? _pendingAudioUrl;
  int _pendingAudioDuration = 0;
  String _pendingAudioMimeType = 'audio/m4a';
  bool _composerActionBusy = false;
  int _callSeconds = 0;
  bool _remoteDescriptionReady = false;
  bool _shouldRequeueOnReconnect = false;
  bool _rejoiningAfterReconnect = false;
  bool _ignoreNextLeftEvent = false;
  int _searchIntentToken = 0;
  String _socketStatus = 'disconnected';
  String? _status;
  Future<void>? _callPreparationFuture;

  String get _meId => ref.read(sessionControllerProvider).user?.id ?? '';
  SocketService get _socket => ref.read(socketServiceProvider);

  @override
  void initState() {
    super.initState();
    _socketStatus = _socket.status;
    _socket.addListener(_handleSocketStatusChanged);
    unawaited(_configureRingtone());
    Future<void>.microtask(_initialize);
  }

  Future<void> _initialize() async {
    _socket.on('match:found', _onMatchFound);
    _socket.on('match:ended', _onMatchEnded);
    _socket.on('chat:message', _onChatMessage);
    _socket.on('chat:typing', _onTyping);
    _socket.on('follow:allow', _onFollowAllow);
    _socket.on('call:request', _onCallRequest);
    _socket.on('call:accept', _onCallAccept);
    _socket.on('call:missed', _onCallMissed);
    _socket.on('call:cancel', _onCallCancel);
    _socket.on('call:end', _onCallEnd);
    _socket.on('call:camera-state', _onCameraState);
    _socket.on('rtc:offer', _onRtcOffer);
    _socket.on('rtc:answer', _onRtcAnswer);
    _socket.on('rtc:ice', _onRtcIce);
    await _localRenderer.initialize();
    await _remoteRenderer.initialize();
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

  @override
  void dispose() {
    _typingTimer?.cancel();
    _countdownTimer?.cancel();
    _recordingTimer?.cancel();
    _callTimeoutTimer?.cancel();
    _callDurationTimer?.cancel();
    _autoRejoinTimer?.cancel();
    _draftController.dispose();
    _scrollController.dispose();
    _audioRecorder.dispose();
    _ringtonePlayer.dispose();
    _socket.off('match:found', _onMatchFound);
    _socket.off('match:ended', _onMatchEnded);
    _socket.off('chat:message', _onChatMessage);
    _socket.off('chat:typing', _onTyping);
    _socket.off('follow:allow', _onFollowAllow);
    _socket.off('call:request', _onCallRequest);
    _socket.off('call:accept', _onCallAccept);
    _socket.off('call:missed', _onCallMissed);
    _socket.off('call:cancel', _onCallCancel);
    _socket.off('call:end', _onCallEnd);
    _socket.off('call:camera-state', _onCameraState);
    _socket.off('rtc:offer', _onRtcOffer);
    _socket.off('rtc:answer', _onRtcAnswer);
    _socket.off('rtc:ice', _onRtcIce);
    _socket.removeListener(_handleSocketStatusChanged);
    unawaited(_cleanupCall(sendSignal: false));
    if (_phase == 'searching' || _matchId != null) {
      _socket.emit('match:leave', null);
    }
    _localRenderer.dispose();
    _remoteRenderer.dispose();
    super.dispose();
  }

  Future<void> _joinQueue() async {
    _autoRejoinTimer?.cancel();
    final me = ref.read(sessionControllerProvider).user;
    if (me == null) return;
    if (!me.isProLike) {
      setState(
        () => _status = 'Anonymous matching currently requires Pro or Trial.',
      );
      return;
    }
    setState(() {
      _phase = 'searching';
      _status = 'Searching for a partner...';
      _messages.clear();
      _matchId = null;
      _partnerId = null;
      _allowFollow = false;
      _partnerAllowsFollow = false;
      _followBusy = false;
      _followed = false;
      _shouldRequeueOnReconnect = false;
      _callAccepted = false;
    });
    final payload = await _socket.emitWithAckRetry(
      'match:join',
      <String, dynamic>{
        'language': _language,
        'gender': _gender,
        'ageMin': _ageMin.round(),
        'ageMax': _ageMax.round(),
      },
      timeout: const Duration(seconds: 5),
      maxAttempts: 2,
    );
    if (payload is Map && payload['ok'] != true && mounted) {
      setState(() {
        _phase = 'criteria';
        _status = payload['message']?.toString() ?? 'Could not join queue.';
      });
    } else if (payload == null && mounted) {
      setState(() {
        _phase = 'criteria';
        _status = 'Queue join timed out. Please try again.';
      });
    }
  }

  void _cancelSearch() {
    _autoRejoinTimer?.cancel();
    _searchIntentToken += 1;
    _socket.emit('match:leave', null);
    setState(() {
      _phase = 'criteria';
      _status = null;
      _shouldRequeueOnReconnect = false;
      _callAccepted = false;
      _callOpen = false;
    });
  }

  void _skipMatch() {
    if (_matchId == null) return;
    _socket.emit('match:skip', null);
  }

  Future<void> _closeMatch() async {
    final matchId = _matchId;
    if (matchId == null) {
      if (mounted) {
        setState(() {
          _phase = 'criteria';
          _status = null;
        });
      }
      return;
    }
    _countdownTimer?.cancel();
    await _cleanupCall(sendSignal: false);
    if (!mounted) return;
    _ignoreNextLeftEvent = true;
    setState(() {
      _phase = 'criteria';
      _matchId = null;
      _partnerId = null;
      _theirTyping = false;
      _secondsRemaining = 0;
      _followBusy = false;
      _followed = false;
      _allowFollow = false;
      _partnerAllowsFollow = false;
      _callAccepted = false;
      _status = null;
      _messages.clear();
    });
    _socket.emit('match:leave', null);
  }

  void _onMatchFound(dynamic data) {
    if (data is! Map || !mounted) return;
    final payload = Map<String, dynamic>.from(data);
    final endsAt = (payload['endsAt'] as num?)?.toInt() ?? 0;
    setState(() {
      _ignoreNextLeftEvent = false;
      _phase = 'chat';
      _matchId = payload['matchId']?.toString();
      _partnerId = payload['partnerId']?.toString();
      _messages
        ..clear()
        ..add(_AnonMessage.system('Matched! Say hi 👋'));
      _theirTyping = false;
      _followBusy = false;
      _followed = false;
      _allowFollow = false;
      _partnerAllowsFollow = false;
      _callAccepted = false;
      _callOpen = false;
      _status = null;
    });
    _startCountdown(endsAt);
    unawaited(_refreshPartnerFollowState());
  }

  void _onMatchEnded(dynamic data) {
    if (data is! Map || !mounted) return;
    final reason = data['reason']?.toString() ?? 'ended';
    final eventMatchId = data['matchId']?.toString();
    if (reason == 'left' && _ignoreNextLeftEvent) {
      _ignoreNextLeftEvent = false;
      return;
    }
    if (_matchId != null && eventMatchId != _matchId) {
      return;
    }
    _countdownTimer?.cancel();
    unawaited(_cleanupCall(sendSignal: false));
    setState(() {
      _matchId = null;
      _partnerId = null;
      _theirTyping = false;
      _secondsRemaining = 0;
      _followBusy = false;
      _followed = false;
      _allowFollow = false;
      _partnerAllowsFollow = false;
      _callAccepted = false;
      _callOpen = false;
      _shouldRequeueOnReconnect = false;
    });
    if (reason == 'skipped' || reason == 'disconnect' || reason == 'left') {
      setState(() {
        _phase = 'searching';
      });
      final token = ++_searchIntentToken;
      _autoRejoinTimer?.cancel();
      _autoRejoinTimer = Timer(const Duration(milliseconds: 100), () {
        if (!mounted) return;
        if (_searchIntentToken != token) return;
        if (_phase != 'searching') return;
        _joinQueue();
      });
      return;
    }
    setState(() {
      _phase = 'ended';
    });
  }

  void _onChatMessage(dynamic data) {
    if (data is! Map || !mounted) return;
    final payload = Map<String, dynamic>.from(data);
    if (payload['matchId']?.toString() != _matchId) return;
    final message = _AnonMessage.fromSocket(payload, _meId);
    setState(() {
      if (!_messages.any((item) => item.id == message.id)) {
        _messages.add(message);
      }
    });
    _scrollToBottom();
  }

  void _onTyping(dynamic data) {
    if (data is! Map || !mounted) return;
    final payload = Map<String, dynamic>.from(data);
    if (payload['matchId']?.toString() != _matchId) return;
    if (payload['from']?.toString() == _meId) return;
    setState(() => _theirTyping = payload['typing'] == true);
  }

  void _onFollowAllow(dynamic data) {
    if (data is! Map || !mounted) return;
    final payload = Map<String, dynamic>.from(data);
    if (payload['matchId']?.toString() != _matchId) return;
    if (payload['from']?.toString() == _meId) return;
    setState(() => _partnerAllowsFollow = payload['allow'] == true);
  }

  Future<void> _sendText() async {
    final text = _draftController.text.trim();
    if (text.isEmpty || _matchId == null) return;
    if (!_socket.isConnected) {
      _showSnack('You are offline. Reconnect to keep chatting.');
      return;
    }
    _draftController.clear();
    _socket.emit('chat:typing', <String, dynamic>{
      'matchId': _matchId,
      'typing': false,
    });
    unawaited(_sendStructuredMessage(type: 'text', text: text));
    FocusScope.of(context).unfocus();
    _scrollToBottom();
  }

  Future<void> _sendStructuredMessage({
    required String type,
    String text = '',
    String? imageUrl,
    String? audioUrl,
    int audioDuration = 0,
    String? mimeType,
  }) async {
    final matchId = _matchId;
    if (matchId == null) return;
    final clientId = _randomId();
    setState(() {
      _messages.add(
        _AnonMessage(
          id: clientId,
          mine: true,
          type: type,
          text: text,
          imageBytes: imageUrl != null ? tryDecodeDataUrl(imageUrl) : null,
          imageUrl: imageUrl,
          audioUrl: audioUrl,
          audioDuration: audioDuration,
          createdAt: DateTime.now(),
        ),
      );
    });
    final payload = await _socket.emitWithAckRetry(
      'chat:message',
      <String, dynamic>{
        'matchId': matchId,
        'type': type,
        'text': text,
        'imageUrl': imageUrl,
        'audioUrl': audioUrl,
        'audioDuration': audioDuration,
        'mimeType': mimeType,
        'clientMessageId': clientId,
      },
      timeout: const Duration(seconds: 4),
      maxAttempts: 2,
    );
    if (!mounted) return;
    if (payload is Map && payload['ok'] == false) {
      _showSnack('That message could not be sent.');
    } else if (payload == null) {
      _showSnack('Message send timed out. Check your connection.');
    }
  }

  Future<void> _sendImage() async {
    if (_matchId == null) return;
    if (!_socket.isConnected) {
      _showSnack('You are offline. Reconnect to send media.');
      return;
    }
    final allowed = await _permissionService.ensurePhotos();
    if (!allowed) return;
    try {
      final file = await _imagePicker.pickImage(
        source: ImageSource.gallery,
        maxWidth: 1080,
        maxHeight: 1080,
        imageQuality: 68,
      );
      if (file == null) return;
      final bytes = await file.readAsBytes();
      if (bytes.isEmpty) {
        _showSnack('That image could not be loaded.');
        return;
      }
      if (bytes.length > 4 * 1024 * 1024) {
        _showSnack('That image is still too large. Choose a smaller one.');
        return;
      }
      final dataUrl = bytesToDataUrl(bytes, file.mimeType ?? 'image/jpeg');
      unawaited(
        _sendStructuredMessage(type: 'image', imageUrl: dataUrl, text: file.name),
      );
      _scrollToBottom();
    } catch (_) {
      _showSnack('Could not share that image right now.');
    }
  }

  Future<void> _toggleRecording() async {
    if (_matchId == null) return;
    if (_composerActionBusy) return;
    if (!_socket.isConnected && !_recording) {
      _showSnack('You are offline. Reconnect to record and send audio.');
      return;
    }
    _composerActionBusy = true;
    if (_recording) {
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
      } catch (_) {
        _showSnack('Could not finish that recording.');
        setState(() {
          _recording = false;
          _recordingSeconds = 0;
        });
      } finally {
        _composerActionBusy = false;
      }
      return;
    }
    try {
      final hasPermission = await _audioRecorder.hasPermission();
      final allowed = hasPermission || await _permissionService.ensureMicrophone();
      final recorderAllowed = allowed && await _audioRecorder.hasPermission();
      if (!recorderAllowed) {
        _showSnack('Microphone permission is required to record voice notes.');
        _composerActionBusy = false;
        return;
      }
      final tempDir = Directory.systemTemp;
      final path =
          '${tempDir.path}/anon_${DateTime.now().millisecondsSinceEpoch}.m4a';
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
        _composerActionBusy = false;
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
    } catch (_) {
      _showSnack('Could not start recording right now.');
    } finally {
      _composerActionBusy = false;
    }
  }

  void _handleComposerPrimaryAction() {
    if (_draftController.text.trim().isNotEmpty) {
      unawaited(_sendText());
      return;
    }
    if (_pendingAudioUrl != null) {
      _sendPendingAudio();
      return;
    }
    unawaited(_toggleRecording());
  }

  void _sendPendingAudio() {
    final audioUrl = _pendingAudioUrl;
    if (audioUrl == null || audioUrl.isEmpty) return;
    unawaited(
      _sendStructuredMessage(
        type: 'audio',
        audioUrl: audioUrl,
        audioDuration: _pendingAudioDuration,
        mimeType: _pendingAudioMimeType,
      ),
    );
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
    if (_matchId == null) return;
    if (mounted) setState(() {});
    _socket.emit('chat:typing', <String, dynamic>{
      'matchId': _matchId,
      'typing': value.trim().isNotEmpty,
    });
    _typingTimer?.cancel();
    _typingTimer = Timer(const Duration(milliseconds: 1500), () {
      _socket.emit('chat:typing', <String, dynamic>{
        'matchId': _matchId,
        'typing': false,
      });
    });
  }

  void _toggleAllowFollow() {
    if (_matchId == null) return;
    if (!_socket.isConnected) {
      _showSnack('You are offline. Reconnect to update follow access.');
      return;
    }
    final next = !_allowFollow;
    setState(() => _allowFollow = next);
    _socket.emit('follow:allow', <String, dynamic>{
      'matchId': _matchId,
      'allow': next,
    });
  }

  Future<void> _followMatchedUser() async {
    final partnerId = _partnerId;
    if (partnerId == null || partnerId.isEmpty || _followBusy || _followed) {
      return;
    }
    setState(() => _followBusy = true);
    try {
      final data = await ref
          .read(apiClientProvider)
          .postJson('/users/$partnerId/follow');
      if (!mounted) return;
      setState(() => _followed = data['following'] != false);
    } catch (_) {
      if (!mounted) return;
      _showSnack('Could not follow this user right now.');
    } finally {
      if (mounted) {
        setState(() => _followBusy = false);
      }
    }
  }

  Future<void> _refreshPartnerFollowState() async {
    final partnerId = _partnerId;
    if (partnerId == null || partnerId.isEmpty) return;
    try {
      final data = await ref
          .read(apiClientProvider)
          .getJson('/users/$partnerId');
      if (!mounted) return;
      final user = AppUser.fromJson(
        data['user'] as Map<String, dynamic>? ?? const <String, dynamic>{},
      );
      setState(() => _followed = user.isFollowing);
    } catch (_) {
      // Keep current local state if the follow relationship check fails.
    }
  }

  void _handleMoreTap() {
    showModalBottomSheet<void>(
      context: context,
      backgroundColor: const Color(0xFF171717),
      shape: const RoundedRectangleBorder(
        borderRadius: BorderRadius.vertical(top: Radius.circular(28)),
      ),
      builder: (context) {
        return SafeArea(
          child: Padding(
            padding: const EdgeInsets.fromLTRB(20, 16, 20, 24),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                Container(
                  width: 42,
                  height: 4,
                  decoration: BoxDecoration(
                    color: const Color(0xFF4A4A4A),
                    borderRadius: BorderRadius.circular(999),
                  ),
                ),
                const SizedBox(height: 20),
                ListTile(
                  onTap: () {
                    Navigator.of(context).pop();
                    _showSnack('User blocked for this anonymous session.');
                    _skipMatch();
                  },
                  leading: const Icon(
                    Icons.block_outlined,
                    color: Colors.white,
                  ),
                  title: const Text(
                    'Block',
                    style: TextStyle(color: Colors.white),
                  ),
                ),
                ListTile(
                  onTap: () {
                    Navigator.of(context).pop();
                    _showSnack('Report received. We will review this session.');
                  },
                  leading: const Icon(Icons.flag_outlined, color: Colors.white),
                  title: const Text(
                    'Report',
                    style: TextStyle(color: Colors.white),
                  ),
                ),
              ],
            ),
          ),
        );
      },
    );
  }

  Widget _buildAllowFollowToggle() {
    final theme = Theme.of(context);
    final isDark = theme.brightness == Brightness.dark;
    final pillBackground = isDark
        ? const Color(0xFF202020)
        : const Color(0xFFF2F2F2);
    final pillBorder = isDark
        ? const Color(0xFF3B3B3B)
        : const Color(0xFFD8D8D8);
    final pillText = isDark ? Colors.white : Colors.black;
    final switchTrack = _allowFollow
        ? talkflixPrimary
        : (isDark ? const Color(0xFF4A4A4A) : const Color(0xFFD5D5D5));
    return Container(
      height: 52,
      padding: const EdgeInsets.symmetric(horizontal: 12),
      decoration: BoxDecoration(
        color: pillBackground,
        borderRadius: BorderRadius.circular(999),
        border: Border.all(color: pillBorder),
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          Text(
            'Allow Follow',
            style: TextStyle(
              color: pillText,
              fontSize: 13,
              fontWeight: FontWeight.w800,
            ),
          ),
          const SizedBox(width: 8),
          GestureDetector(
            onTap: _toggleAllowFollow,
            child: Container(
              width: 54,
              height: 30,
              padding: const EdgeInsets.all(4),
              decoration: BoxDecoration(
                color: switchTrack,
                borderRadius: BorderRadius.circular(999),
              ),
              alignment: _allowFollow
                  ? Alignment.centerRight
                  : Alignment.centerLeft,
              child: Container(
                width: 22,
                height: 22,
                decoration: const BoxDecoration(
                  color: Colors.white,
                  shape: BoxShape.circle,
                ),
              ),
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildFollowActionChip() {
    final theme = Theme.of(context);
    final isDark = theme.brightness == Brightness.dark;
    final background = isDark ? Colors.white : const Color(0xFF111111);
    final foreground = isDark ? const Color(0xFF111111) : Colors.white;
    final label = _followed
        ? 'Following'
        : _followBusy
        ? 'Following...'
        : 'Follow';
    return FilledButton(
      onPressed: (_followBusy || _followed) ? null : _followMatchedUser,
      style: FilledButton.styleFrom(
        backgroundColor: background,
        foregroundColor: foreground,
        disabledBackgroundColor: background.withValues(alpha: 0.92),
        disabledForegroundColor: foreground,
        elevation: 0,
        minimumSize: const Size(0, 46),
        padding: const EdgeInsets.symmetric(horizontal: 14),
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(999)),
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          Icon(Icons.person_add_alt_1_rounded, size: 18, color: foreground),
          const SizedBox(width: 6),
          Text(
            label,
            style: TextStyle(
              color: foreground,
              fontSize: 13,
              fontWeight: FontWeight.w800,
            ),
          ),
        ],
      ),
    );
  }

  Future<void> _requestCall() async {
    if (_matchId == null || _callRequesting || _callConnected) return;
    if (!_socket.isConnected) {
      _showSnack('You are offline. Reconnect before placing a call.');
      return;
    }
    final payload = await _socket.emitWithAckRetry(
      'call:request',
      <String, dynamic>{'matchId': _matchId},
      timeout: const Duration(seconds: 5),
      maxAttempts: 2,
    );
    if (!mounted || payload is! Map || payload['ok'] != true) {
      if (!mounted) return;
      setState(() {
        _callAccepted = false;
        _callRequesting = false;
        _callInitiator = false;
        _callIncoming = false;
        _callOpen = false;
        _status = null;
      });
      if (payload == null) {
        _showSnack('Call request timed out. Please try again.');
      }
      return;
    }
    setState(() {
      _callAccepted = false;
      _callRequesting = true;
      _callInitiator = true;
      _callIncoming = false;
      _callOpen = true;
      _status = 'Ringing...';
    });
    _startCallTimeout(
      'No answer yet. You can try calling again or continue chatting.',
    );
    try {
      await _ensurePreparedCall(video: false);
    } catch (_) {
      if (!mounted) return;
      // Keep the caller UI open like the PWA; signaling can still proceed.
    }
  }

  Future<void> _acceptCall() async {
    if (_matchId == null) return;
    if (!_socket.isConnected) {
      _showSnack('You are offline. Reconnect before accepting the call.');
      return;
    }
    await _stopIncomingRingtone();
    setState(() {
      _callIncoming = false;
      _callRequesting = false;
      _callAccepted = true;
      _callInitiator = false;
      _callOpen = true;
      _status = 'Connecting...';
    });
    final matchId = _matchId;
    if (matchId != null) {
      unawaited(
        _socket.emitWithAckFuture(
          'call:accept',
          <String, dynamic>{'matchId': matchId, 'accept': true},
          timeout: const Duration(seconds: 2),
        ),
      );
    }
    _clearCallTimeout();
    _startCallDuration();
    try {
      await _ensurePreparedCall(video: false);
    } catch (_) {
      if (!mounted) return;
      // Match the web flow: keep the call UI open and wait for signaling.
    }
  }

  void _declineCall() {
    if (_matchId == null) return;
    unawaited(_stopIncomingRingtone());
    final matchId = _matchId;
    if (matchId != null) {
      unawaited(
        _socket.emitWithAckFuture(
          'call:accept',
          <String, dynamic>{'matchId': matchId, 'accept': false},
          timeout: const Duration(seconds: 2),
        ),
      );
    }
    setState(() {
      _callIncoming = false;
      _callAccepted = false;
      _callRequesting = false;
      _callOpen = false;
      _status = null;
    });
  }

  Future<void> _ensurePreparedCall({required bool video}) {
    final existing = _callPreparationFuture;
    if (existing != null) return existing;
    final future = _prepareCall(video: video);
    _callPreparationFuture = future.whenComplete(() {
      if (identical(_callPreparationFuture, future)) {
        _callPreparationFuture = null;
      }
    });
    return _callPreparationFuture!;
  }

  Future<void> _prepareCall({required bool video}) async {
    final stream =
        _webRtc.localStream ??
        await _webRtc.createLocalStream(audio: true, video: video);
    _localRenderer.srcObject = stream;
    _localVideoEnabled = stream.getVideoTracks().any((track) => track.enabled);
    _micEnabled = stream.getAudioTracks().any((track) => track.enabled);
    if (_peerConnection == null) {
      _peerConnection = await createPeerConnection(
        AppConfig.rtcPeerConnectionConfig,
      );
      _peerConnection!.onIceCandidate = (candidate) {
        if (_matchId == null || candidate.candidate == null) return;
        _socket.emit('rtc:ice', <String, dynamic>{
          'matchId': _matchId,
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
          setState(() {
            _callConnected = true;
            _callRequesting = false;
            _callOpen = true;
            _status = 'Audio call';
          });
        } else if (state ==
            RTCPeerConnectionState.RTCPeerConnectionStateClosed) {
          unawaited(_cleanupCall(sendSignal: false));
        }
      };
    }
    final senders = await _peerConnection!.getSenders();
    for (final track in stream.getTracks()) {
      if (!senders.any((sender) => sender.track?.id == track.id)) {
        await _peerConnection!.addTrack(track, stream);
      }
    }
    if (mounted) setState(() {});
  }

  WebRtcService get _webRtc => ref.read(webRtcServiceProvider);

  Future<void> _createAndSendOffer() async {
    if (_peerConnection == null || _matchId == null) return;
    final offer = await _peerConnection!.createOffer();
    await _peerConnection!.setLocalDescription(offer);
    _socket.emit('rtc:offer', <String, dynamic>{
      'matchId': _matchId,
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
    if (data is! Map || !mounted) return;
    final payload = Map<String, dynamic>.from(data);
    if (payload['matchId']?.toString() != _matchId) return;
    if (payload['from']?.toString() == _meId) return;
    _callTimeoutTimer?.cancel();
    unawaited(_stopIncomingRingtone());
    setState(() {
      _callIncoming = true;
      _callAccepted = false;
      _callRequesting = false;
      _status = 'Incoming anonymous call';
    });
    _callTimeoutTimer = Timer(const Duration(seconds: 30), () {
      if (!mounted || !_callIncoming) return;
      setState(() {
        _callIncoming = false;
      });
    });
    unawaited(_playIncomingRingtone());
  }

  Future<void> _onCallAccept(dynamic data) async {
    if (data is! Map) return;
    final payload = Map<String, dynamic>.from(data);
    if (payload['matchId']?.toString() != _matchId) return;
    if (payload['from']?.toString() == _meId) return;
    if (payload['accept'] != true) {
      if (!mounted) return;
      await _stopIncomingRingtone();
      setState(() {
        _callAccepted = false;
        _callRequesting = false;
        _callOpen = false;
        _status = 'Call declined.';
      });
      await _cleanupCall(sendSignal: false);
      if (mounted) {
        setState(() {
          _messages.add(_AnonMessage.system('Call declined'));
        });
      }
      return;
    }
    if (mounted) {
      await _stopIncomingRingtone();
      setState(() {
        _callAccepted = true;
        _callOpen = true;
        _callRequesting = false;
        _status = 'Connecting...';
      });
    }
    _clearCallTimeout();
    _startCallDuration();
    if (_callInitiator) {
      await _ensurePreparedCall(video: false);
      await _createAndSendOffer();
    }
  }

  Future<void> _onRtcOffer(dynamic data) async {
    if (data is! Map) return;
    final payload = Map<String, dynamic>.from(data);
    if (payload['from']?.toString() == _meId) return;
    await _stopIncomingRingtone();
    if (mounted && !_callAccepted) {
      setState(() {
        _callAccepted = true;
        _callOpen = true;
        _callRequesting = false;
        _status = 'Connecting...';
      });
      _clearCallTimeout();
      _startCallDuration();
    }
    await _ensurePreparedCall(video: false);
    final sdp = Map<String, dynamic>.from(payload['sdp'] as Map);
    await _peerConnection!.setRemoteDescription(
      RTCSessionDescription(sdp['sdp']?.toString(), sdp['type']?.toString()),
    );
    _remoteDescriptionReady = true;
    await _flushPendingIce();
    final answer = await _peerConnection!.createAnswer();
    await _peerConnection!.setLocalDescription(answer);
    _socket.emit('rtc:answer', <String, dynamic>{
      'matchId': _matchId,
      'sdp': answer.toMap(),
    });
  }

  Future<void> _onRtcAnswer(dynamic data) async {
    if (data is! Map) return;
    final payload = Map<String, dynamic>.from(data);
    if (payload['from']?.toString() == _meId) return;
    await _stopIncomingRingtone();
    final sdp = Map<String, dynamic>.from(payload['sdp'] as Map);
    await _peerConnection?.setRemoteDescription(
      RTCSessionDescription(sdp['sdp']?.toString(), sdp['type']?.toString()),
    );
    _remoteDescriptionReady = true;
    await _flushPendingIce();
  }

  Future<void> _onRtcIce(dynamic data) async {
    if (data is! Map) return;
    final payload = Map<String, dynamic>.from(data);
    if (payload['from']?.toString() == _meId) return;
    final candidateData = Map<String, dynamic>.from(
      payload['candidate'] as Map,
    );
    final candidate = RTCIceCandidate(
      candidateData['candidate']?.toString(),
      candidateData['sdpMid']?.toString(),
      candidateData['sdpMLineIndex'] as int?,
    );
    if (_peerConnection == null || !_remoteDescriptionReady) {
      _pendingRemoteCandidates.add(candidate);
      return;
    }
    await _peerConnection!.addCandidate(candidate);
  }

  Future<void> _onCallMissed(dynamic data) async {
    if (data is! Map) return;
    if (data['matchId']?.toString() != _matchId) return;
    if (!mounted) return;
    await _stopIncomingRingtone();
    setState(() => _status = 'Call missed.');
    await _cleanupCall(sendSignal: false);
    if (!mounted) return;
    setState(() {
      _messages.add(_AnonMessage.system('Missed call'));
    });
  }

  Future<void> _onCallCancel(dynamic data) async {
    if (data is! Map) return;
    if (data['matchId']?.toString() != _matchId) return;
    if (!mounted) return;
    await _stopIncomingRingtone();
    setState(() => _status = 'Call cancelled.');
    await _cleanupCall(sendSignal: false);
    if (!mounted) return;
    setState(() {
      _messages.add(_AnonMessage.system('Call canceled'));
    });
  }

  Future<void> _onCallEnd(dynamic data) async {
    if (data is! Map) return;
    if (data['matchId']?.toString() != _matchId) return;
    await _stopIncomingRingtone();
    await _cleanupCall(sendSignal: false);
    if (!mounted) return;
    setState(() {
      _messages.add(_AnonMessage.system('Call ended'));
    });
  }

  void _onCameraState(dynamic data) {
    if (data is! Map || !mounted) return;
    if (data['matchId']?.toString() != _matchId) return;
    if (data['from']?.toString() == _meId) return;
    setState(() => _remoteVideoEnabled = data['enabled'] == true);
  }

  Future<void> _endCall() => _cleanupCall(sendSignal: true);

  Future<void> _toggleCamera() async {
    if (_peerConnection == null || _matchId == null || _cameraBusy) return;
    final local = _webRtc.localStream;
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
        });
        await _createAndSendOffer();
        _socket.emit('call:camera-state', {
          'matchId': _matchId,
          'enabled': true,
        });
        return;
      }

      // Update UI immediately so the toggle feels instant.
      setState(() {
        _localVideoEnabled = false;
        _localVideoMirrored = true;
      });
      _socket.emit('call:camera-state', {
        'matchId': _matchId,
        'enabled': false,
      });
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
      await _createAndSendOffer();
    } finally {
      if (mounted) {
        setState(() => _cameraBusy = false);
      }
    }
  }

  Future<void> _toggleSpeaker() async {
    final next = !_speakerOn;
    await Helper.setSpeakerphoneOn(next);
    if (!mounted) return;
    setState(() => _speakerOn = next);
  }

  Future<void> _cleanupCall({required bool sendSignal}) async {
    _clearCallTimeout();
    _stopCallDuration();
    await _stopIncomingRingtone();
    if (sendSignal && _matchId != null) {
      _socket.emitRedundant(
        _callConnected ? 'call:end' : 'call:cancel',
        <String, dynamic>{'matchId': _matchId},
      );
    }
    await _peerConnection?.close();
    _peerConnection = null;
    _callPreparationFuture = null;
    _pendingRemoteCandidates.clear();
    _remoteDescriptionReady = false;
    _localRenderer.srcObject = null;
    _remoteRenderer.srcObject = null;
    await _webRtc.disposeLocalStream();
    if (!mounted) return;
    setState(() {
      _callIncoming = false;
      _callRequesting = false;
      _callAccepted = false;
      _callConnected = false;
      _callInitiator = false;
      _callOpen = false;
      _localVideoEnabled = false;
      _remoteVideoEnabled = false;
      _cameraBusy = false;
      _localVideoMirrored = true;
      _micEnabled = true;
      _speakerOn = false;
      _callSeconds = 0;
    });
  }

  void _handleSocketStatusChanged() {
    final nextStatus = _socket.status;
    if (nextStatus == _socketStatus || !mounted) return;
    final previousStatus = _socketStatus;
    _socketStatus = nextStatus;

    if (nextStatus == 'connected') {
      if (_shouldRequeueOnReconnect &&
          _phase == 'searching' &&
          !_rejoiningAfterReconnect) {
        _rejoiningAfterReconnect = true;
        unawaited(_rejoinQueueAfterReconnect());
      } else {
        setState(() {});
      }
      return;
    }

    if (nextStatus == 'connecting' || nextStatus == 'disconnected') {
      if (_phase == 'searching') {
        _shouldRequeueOnReconnect = true;
        setState(() {
          _status = previousStatus == 'connected'
              ? 'Connection lost. Reconnecting to the anonymous queue...'
              : 'Connecting to anonymous match...';
        });
      } else if (_phase == 'chat') {
        _countdownTimer?.cancel();
        unawaited(_cleanupCall(sendSignal: false));
        setState(() {
          _phase = 'criteria';
          _matchId = null;
          _partnerId = null;
          _theirTyping = false;
          _secondsRemaining = 0;
          _shouldRequeueOnReconnect = false;
          _status =
              'Connection changed and the anonymous match ended. Start again when you are ready.';
        });
      } else {
        setState(() {
          _status = nextStatus == 'connecting'
              ? 'Connecting to anonymous match...'
              : _status;
        });
      }
      return;
    }

    if (nextStatus == 'error') {
      setState(() {
        _status =
            'Realtime connection failed. Check the backend and try again.';
      });
    }
  }

  Future<void> _rejoinQueueAfterReconnect() async {
    try {
      await _joinQueue();
    } finally {
      _rejoiningAfterReconnect = false;
    }
  }

  void _startCallTimeout(String message) {
    _callTimeoutTimer?.cancel();
    _callTimeoutTimer = Timer(const Duration(seconds: 30), () async {
      if (!mounted || !_callRequesting || _callConnected || _callAccepted) {
        return;
      }
      setState(() => _status = message);
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

  Future<void> _toggleMute() async {
    final stream = _webRtc.localStream;
    if (stream == null) return;
    for (final track in stream.getAudioTracks()) {
      track.enabled = !track.enabled;
      _micEnabled = track.enabled;
    }
    if (mounted) setState(() {});
  }

  Future<void> _switchCamera() async {
    final switched = await _webRtc.switchCamera();
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

  void _startCountdown(int endsAtMs) {
    _countdownTimer?.cancel();
    void tick() {
      final remaining = max(
        0,
        ((endsAtMs - DateTime.now().millisecondsSinceEpoch) / 1000).ceil(),
      );
      if (!mounted) return;
      setState(() => _secondsRemaining = remaining);
      if (remaining == 0) {
        _countdownTimer?.cancel();
      }
    }

    tick();
    _countdownTimer = Timer.periodic(const Duration(seconds: 1), (_) => tick());
  }

  void _scrollToBottom() {
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!_scrollController.hasClients) return;
      _scrollController.animateTo(
        _scrollController.position.maxScrollExtent + 120,
        duration: const Duration(milliseconds: 220),
        curve: Curves.easeOut,
      );
    });
  }

  void _showSnack(String message) {
    if (!mounted) return;
    ScaffoldMessenger.of(
      context,
    ).showSnackBar(SnackBar(content: Text(message)));
  }

  @override
  Widget build(BuildContext context) {
    final me = ref.watch(sessionControllerProvider).user;
    final socketStatus = ref.watch(socketServiceProvider).status;
    final canFollow = _allowFollow && _partnerAllowsFollow;
    final theme = Theme.of(context);
    final isDark = theme.brightness == Brightness.dark;
    final chatBackdrop = isDark
        ? const Color(0xFF111111)
        : const Color(0xFFF6F6F6);
    final chatSurface = isDark
        ? const Color(0xFF171717)
        : const Color(0xFFFFFFFF);
    final chatSurfaceAlt = isDark
        ? const Color(0xFF232323)
        : const Color(0xFFF0F0F0);
    final chatBorder = isDark
        ? const Color(0xFF3A3A3A)
        : const Color(0xFFDADADA);
    final headerText = isDark ? Colors.white : Colors.black;
    final subText = isDark ? const Color(0xFF9B9B9B) : const Color(0xFF6B6B6B);
    final incomingBubble = isDark ? const Color(0xFF4A4A4A) : Colors.white;
    final incomingText = isDark ? Colors.white : Colors.black;
    final composerHint = isDark
        ? const Color(0xFF7C7C7C)
        : const Color(0xFF8A8A8A);

    return Scaffold(
      backgroundColor: Colors.transparent,
      body: Stack(
        children: [
          if (_phase == 'criteria')
            Center(
              child: ConstrainedBox(
                constraints: const BoxConstraints(maxWidth: 480),
                child: Container(
                  margin: const EdgeInsets.symmetric(horizontal: 20),
                  padding: const EdgeInsets.fromLTRB(22, 26, 22, 22),
                  decoration: BoxDecoration(
                    color: theme.scaffoldBackgroundColor,
                    borderRadius: BorderRadius.circular(30),
                    border: Border.all(color: theme.dividerColor),
                    boxShadow: const [
                      BoxShadow(
                        color: Color(0x40000000),
                        blurRadius: 28,
                        offset: Offset(0, 18),
                      ),
                    ],
                  ),
                  child: SingleChildScrollView(
                    child: Column(
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        Align(
                          alignment: Alignment.topRight,
                          child: IconButton(
                            onPressed: () => Navigator.of(context).pop(),
                            icon: const Icon(Icons.close_rounded),
                          ),
                        ),
                        if (socketStatus != 'connected') ...[
                          RealtimeWarningBanner(
                            status: socketStatus,
                            scopeLabel: 'Realtime',
                            connectingMessage:
                                'Connecting to realtime services...',
                          ),
                          const SizedBox(height: 16),
                        ],
                        Text(
                          'Anonymous Partner Match',
                          textAlign: TextAlign.center,
                          style: theme.textTheme.headlineSmall?.copyWith(
                            fontWeight: FontWeight.w900,
                          ),
                        ),
                        const SizedBox(height: 8),
                        Text(
                          'Choose who you want to meet.',
                          textAlign: TextAlign.center,
                          style: theme.textTheme.bodyLarge,
                        ),
                        const SizedBox(height: 22),
                        DropdownButtonFormField<String>(
                          initialValue: _language,
                          items: const [
                            DropdownMenuItem(
                              value: 'English',
                              child: Text('English'),
                            ),
                            DropdownMenuItem(
                              value: 'Arabic',
                              child: Text('Arabic'),
                            ),
                            DropdownMenuItem(
                              value: 'Spanish',
                              child: Text('Spanish'),
                            ),
                            DropdownMenuItem(
                              value: 'French',
                              child: Text('French'),
                            ),
                          ],
                          onChanged: (value) =>
                              setState(() => _language = value ?? 'English'),
                          decoration: const InputDecoration(
                            labelText: 'Language',
                          ),
                        ),
                        const SizedBox(height: 16),
                        SegmentedButton<String>(
                          segments: const [
                            ButtonSegment(value: 'any', label: Text('Any')),
                            ButtonSegment(
                              value: 'female',
                              label: Text('Female'),
                            ),
                            ButtonSegment(value: 'male', label: Text('Male')),
                          ],
                          selected: {_gender},
                          onSelectionChanged: (value) {
                            setState(() => _gender = value.first);
                          },
                        ),
                        const SizedBox(height: 16),
                        Text(
                          'Age range: ${_ageMin.round()} - ${_ageMax.round()}',
                        ),
                        RangeSlider(
                          values: RangeValues(_ageMin, _ageMax),
                          min: 18,
                          max: 90,
                          divisions: 72,
                          labels: RangeLabels(
                            _ageMin.round().toString(),
                            _ageMax.round().toString(),
                          ),
                          onChanged: (value) {
                            setState(() {
                              _ageMin = min(value.start, value.end);
                              _ageMax = max(value.start, value.end);
                            });
                          },
                        ),
                        if (_status != null) ...[
                          const SizedBox(height: 12),
                          Text(
                            _status!,
                            textAlign: TextAlign.center,
                            style: TextStyle(color: theme.colorScheme.error),
                          ),
                        ],
                        const SizedBox(height: 20),
                        SizedBox(
                          width: double.infinity,
                          child: FilledButton(
                            onPressed: me == null ? null : _joinQueue,
                            child: const Text('Find match'),
                          ),
                        ),
                      ],
                    ),
                  ),
                ),
              ),
            ),
          if (_phase == 'searching')
            Center(
              child: ConstrainedBox(
                constraints: const BoxConstraints(maxWidth: 420),
                child: Container(
                  margin: const EdgeInsets.symmetric(horizontal: 20),
                  padding: const EdgeInsets.fromLTRB(24, 28, 24, 24),
                  decoration: BoxDecoration(
                    color: theme.scaffoldBackgroundColor,
                    borderRadius: BorderRadius.circular(30),
                    border: Border.all(color: theme.dividerColor),
                    boxShadow: const [
                      BoxShadow(
                        color: Color(0x40000000),
                        blurRadius: 28,
                        offset: Offset(0, 18),
                      ),
                    ],
                  ),
                  child: Column(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      if (socketStatus != 'connected') ...[
                        RealtimeWarningBanner(
                          status: socketStatus,
                          scopeLabel: 'Realtime',
                          connectingMessage:
                              'Connecting to realtime services...',
                        ),
                        const SizedBox(height: 20),
                      ],
                      const CircularProgressIndicator(),
                      const SizedBox(height: 16),
                      Text(
                        'Finding a match...',
                        textAlign: TextAlign.center,
                        style: theme.textTheme.titleLarge?.copyWith(
                          fontWeight: FontWeight.w900,
                        ),
                      ),
                      const SizedBox(height: 8),
                      Text(
                        'Language: $_language • Gender: $_gender • Age: ${_ageMin.round()}-${_ageMax.round()}',
                        textAlign: TextAlign.center,
                      ),
                      if (_status != null) ...[
                        const SizedBox(height: 12),
                        Text(_status!, textAlign: TextAlign.center),
                      ],
                      const SizedBox(height: 20),
                      OutlinedButton(
                        onPressed: _cancelSearch,
                        child: const Text('Cancel'),
                      ),
                    ],
                  ),
                ),
              ),
            ),
          if (_phase == 'chat')
            Container(
              color: chatBackdrop,
              child: LayoutBuilder(
                builder: (context, constraints) {
                  final viewPadding = MediaQuery.viewPaddingOf(context);
                  final topInset = viewPadding.top + 6;
                  final bottomInset = viewPadding.bottom + 8;
                  return ColoredBox(
                    color: chatSurface,
                    child: Column(
                      children: [
                        Padding(
                          padding: EdgeInsets.fromLTRB(18, topInset, 18, 0),
                          child: Column(
                            children: [
                              Row(
                                crossAxisAlignment: CrossAxisAlignment.start,
                                children: [
                                  Container(
                                    width: 60,
                                    height: 60,
                                    decoration: BoxDecoration(
                                      shape: BoxShape.circle,
                                      border: Border.all(color: chatBorder),
                                    ),
                                    child: IconButton(
                                      onPressed: _closeMatch,
                                      icon: Icon(
                                        Icons.close_rounded,
                                        color: headerText,
                                        size: 22,
                                      ),
                                    ),
                                  ),
                                  const SizedBox(width: 12),
                                  Expanded(
                                    child: Padding(
                                      padding: const EdgeInsets.only(top: 4),
                                      child: Column(
                                        crossAxisAlignment:
                                            CrossAxisAlignment.start,
                                        children: [
                                          Text(
                                            'Anonymous',
                                            style: theme
                                                .textTheme
                                                .headlineMedium
                                                ?.copyWith(
                                                  color: headerText,
                                                  fontWeight: FontWeight.w900,
                                                  fontSize: 23,
                                                  height: 1,
                                                ),
                                          ),
                                          const SizedBox(height: 6),
                                          Text(
                                            _secondsRemaining > 0
                                                ? 'Time left ${_formatCountdown(_secondsRemaining)}'
                                                : 'Matched now',
                                            style: TextStyle(
                                              color: subText,
                                              fontSize: 15,
                                              fontWeight: FontWeight.w500,
                                            ),
                                          ),
                                        ],
                                      ),
                                    ),
                                  ),
                                  const SizedBox(width: 8),
                                  _ChatActionCircle(
                                    size: 50,
                                    iconSize: 18,
                                    icon: Icons.more_horiz_rounded,
                                    onTap: _handleMoreTap,
                                  ),
                                ],
                              ),
                              const SizedBox(height: 14),
                              Row(
                                children: [
                                  if (canFollow)
                                    _buildFollowActionChip()
                                  else
                                    _buildAllowFollowToggle(),
                                  const SizedBox(width: 10),
                                  const Spacer(),
                                  if (_callAccepted)
                                    FilledButton.icon(
                                      onPressed: () =>
                                          setState(() => _callOpen = true),
                                      style: FilledButton.styleFrom(
                                        backgroundColor: const Color(
                                          0xFF202020,
                                        ),
                                        foregroundColor: Colors.white,
                                        elevation: 0,
                                        padding: const EdgeInsets.symmetric(
                                          horizontal: 14,
                                          vertical: 0,
                                        ),
                                        minimumSize: const Size(0, 46),
                                        shape: RoundedRectangleBorder(
                                          borderRadius: BorderRadius.circular(
                                            999,
                                          ),
                                          side: const BorderSide(
                                            color: Color(0xFF3B3B3B),
                                          ),
                                        ),
                                      ),
                                      icon: const Icon(
                                        Icons.call_rounded,
                                        size: 18,
                                      ),
                                      label: const Text(
                                        'Return to call',
                                        style: TextStyle(
                                          fontSize: 13,
                                          fontWeight: FontWeight.w800,
                                        ),
                                      ),
                                    )
                                  else
                                    _ChatActionCircle(
                                      size: 50,
                                      iconSize: 18,
                                      icon: Icons.call_outlined,
                                      onTap: (_callRequesting || _callIncoming)
                                          ? null
                                          : _requestCall,
                                    ),
                                  const SizedBox(width: 8),
                                  _ChatActionCircle(
                                    size: 50,
                                    iconSize: 18,
                                    icon: Icons.skip_next_rounded,
                                    onTap: _skipMatch,
                                  ),
                                ],
                              ),
                            ],
                          ),
                        ),
                        if (_callIncoming)
                          Padding(
                            padding: const EdgeInsets.fromLTRB(18, 8, 18, 0),
                            child: Container(
                              padding: const EdgeInsets.fromLTRB(
                                28,
                                28,
                                28,
                                26,
                              ),
                              decoration: BoxDecoration(
                                color: chatSurface,
                                borderRadius: BorderRadius.circular(28),
                                border: Border.all(color: chatBorder),
                              ),
                              child: LayoutBuilder(
                                builder: (context, innerConstraints) {
                                  final stackButtons =
                                      innerConstraints.maxWidth < 560;
                                  return stackButtons
                                      ? Column(
                                          crossAxisAlignment:
                                              CrossAxisAlignment.stretch,
                                          children: [
                                            Text(
                                              'Incoming anonymous call',
                                              textAlign: TextAlign.center,
                                              style: TextStyle(
                                                color: headerText,
                                                fontWeight: FontWeight.w900,
                                                fontSize: 18,
                                              ),
                                            ),
                                            const SizedBox(height: 18),
                                            Row(
                                              children: [
                                                Expanded(
                                                  child: OutlinedButton(
                                                    onPressed: _declineCall,
                                                    style: OutlinedButton.styleFrom(
                                                      foregroundColor:
                                                          headerText,
                                                      side: BorderSide(
                                                        color: chatBorder,
                                                      ),
                                                      shape: RoundedRectangleBorder(
                                                        borderRadius:
                                                            BorderRadius.circular(
                                                              22,
                                                            ),
                                                      ),
                                                      padding:
                                                          const EdgeInsets.symmetric(
                                                            horizontal: 26,
                                                            vertical: 18,
                                                          ),
                                                    ),
                                                    child: const Text(
                                                      'Decline',
                                                      style: TextStyle(
                                                        fontWeight:
                                                            FontWeight.w800,
                                                      ),
                                                    ),
                                                  ),
                                                ),
                                                const SizedBox(width: 12),
                                                Expanded(
                                                  child: FilledButton(
                                                    onPressed: _acceptCall,
                                                    style: FilledButton.styleFrom(
                                                      backgroundColor:
                                                          const Color(
                                                            0xFFE50914,
                                                          ),
                                                      foregroundColor:
                                                          Colors.white,
                                                      shape: RoundedRectangleBorder(
                                                        borderRadius:
                                                            BorderRadius.circular(
                                                              22,
                                                            ),
                                                      ),
                                                      padding:
                                                          const EdgeInsets.symmetric(
                                                            horizontal: 26,
                                                            vertical: 18,
                                                          ),
                                                    ),
                                                    child: const Text(
                                                      'Accept',
                                                      style: TextStyle(
                                                        fontWeight:
                                                            FontWeight.w800,
                                                      ),
                                                    ),
                                                  ),
                                                ),
                                              ],
                                            ),
                                          ],
                                        )
                                      : Row(
                                          children: [
                                            Expanded(
                                              child: Text(
                                                'Incoming anonymous call',
                                                textAlign: TextAlign.center,
                                                style: TextStyle(
                                                  color: headerText,
                                                  fontWeight: FontWeight.w900,
                                                  fontSize: 18,
                                                ),
                                              ),
                                            ),
                                            OutlinedButton(
                                              onPressed: _declineCall,
                                              style: OutlinedButton.styleFrom(
                                                foregroundColor: headerText,
                                                side: BorderSide(
                                                  color: chatBorder,
                                                ),
                                                shape: RoundedRectangleBorder(
                                                  borderRadius:
                                                      BorderRadius.circular(22),
                                                ),
                                                padding:
                                                    const EdgeInsets.symmetric(
                                                      horizontal: 26,
                                                      vertical: 18,
                                                    ),
                                              ),
                                              child: const Text(
                                                'Decline',
                                                style: TextStyle(
                                                  fontWeight: FontWeight.w800,
                                                ),
                                              ),
                                            ),
                                            const SizedBox(width: 12),
                                            FilledButton(
                                              onPressed: _acceptCall,
                                              style: FilledButton.styleFrom(
                                                backgroundColor: const Color(
                                                  0xFFE50914,
                                                ),
                                                foregroundColor: Colors.white,
                                                shape: RoundedRectangleBorder(
                                                  borderRadius:
                                                      BorderRadius.circular(22),
                                                ),
                                                padding:
                                                    const EdgeInsets.symmetric(
                                                      horizontal: 26,
                                                      vertical: 18,
                                                    ),
                                              ),
                                              child: const Text(
                                                'Accept',
                                                style: TextStyle(
                                                  fontWeight: FontWeight.w800,
                                                ),
                                              ),
                                            ),
                                          ],
                                        );
                                },
                              ),
                            ),
                          ),
                        Expanded(
                          child: ListView.separated(
                            controller: _scrollController,
                            padding: const EdgeInsets.fromLTRB(18, 18, 18, 8),
                            itemCount:
                                _messages.length + (_theirTyping ? 1 : 0),
                            separatorBuilder: (context, index) =>
                                const SizedBox(height: 26),
                            itemBuilder: (context, index) {
                              if (_theirTyping && index == _messages.length) {
                                return const Align(
                                  alignment: Alignment.centerLeft,
                                  child: Padding(
                                    padding: EdgeInsets.only(left: 54),
                                    child: Text(
                                      'Typing...',
                                      style: TextStyle(
                                        color: Color(0xFF8E8E8E),
                                        fontSize: 15,
                                      ),
                                    ),
                                  ),
                                );
                              }
                              final message = _messages[index];
                              if (message.system) {
                                return Center(
                                  child: Container(
                                    padding: const EdgeInsets.symmetric(
                                      horizontal: 18,
                                      vertical: 16,
                                    ),
                                    decoration: BoxDecoration(
                                      color: chatSurfaceAlt,
                                      borderRadius: BorderRadius.circular(28),
                                    ),
                                    child: Text(
                                      message.text,
                                      style: TextStyle(
                                        color: headerText,
                                        fontSize: 18,
                                        fontWeight: FontWeight.w500,
                                      ),
                                    ),
                                  ),
                                );
                              }
                              if (message.mine) {
                                final isImageMessage =
                                    message.type == 'image' &&
                                    (message.imageUrl ?? '').isNotEmpty;
                                return Align(
                                  alignment: Alignment.centerRight,
                                  child: Container(
                                    constraints: const BoxConstraints(
                                      maxWidth: 268,
                                    ),
                                    padding: isImageMessage
                                        ? EdgeInsets.zero
                                        : const EdgeInsets.symmetric(
                                            horizontal: 18,
                                            vertical: 12,
                                          ),
                                    decoration: const BoxDecoration(
                                      color: talkflixPrimary,
                                      borderRadius: BorderRadius.all(
                                        Radius.circular(22),
                                      ),
                                    ),
                                    child: DefaultTextStyle.merge(
                                      style: const TextStyle(
                                        color: Colors.white,
                                        fontSize: 16,
                                        fontWeight: FontWeight.w800,
                                      ),
                                      child: _AnonMessageBody(message: message),
                                    ),
                                  ),
                                );
                              }
                              final isImageMessage =
                                  message.type == 'image' &&
                                  (message.imageUrl ?? '').isNotEmpty;
                              return Align(
                                alignment: Alignment.centerLeft,
                                child: Row(
                                  mainAxisSize: MainAxisSize.min,
                                  crossAxisAlignment: CrossAxisAlignment.end,
                                  children: [
                                    Container(
                                      width: 36,
                                      height: 36,
                                      margin: const EdgeInsets.only(
                                        right: 16,
                                        bottom: 2,
                                      ),
                                      decoration: BoxDecoration(
                                        color: chatSurfaceAlt,
                                        borderRadius: BorderRadius.circular(16),
                                        border: Border.all(color: chatBorder),
                                      ),
                                      alignment: Alignment.center,
                                      child: Text(
                                        '?',
                                        style: TextStyle(
                                          color: headerText,
                                          fontWeight: FontWeight.w900,
                                          fontSize: 18,
                                        ),
                                      ),
                                    ),
                                    Container(
                                      constraints: const BoxConstraints(
                                        maxWidth: 268,
                                      ),
                                      padding: isImageMessage
                                          ? EdgeInsets.zero
                                          : const EdgeInsets.symmetric(
                                              horizontal: 18,
                                              vertical: 12,
                                            ),
                                      decoration: BoxDecoration(
                                        color: incomingBubble,
                                        borderRadius: BorderRadius.circular(22),
                                        border: Border.all(color: chatBorder),
                                      ),
                                      child: DefaultTextStyle.merge(
                                        style: TextStyle(
                                          color: incomingText,
                                          fontSize: 16,
                                          fontWeight: FontWeight.w700,
                                        ),
                                        child: _AnonMessageBody(
                                          message: message,
                                        ),
                                      ),
                                    ),
                                  ],
                                ),
                              );
                            },
                          ),
                        ),
                        Padding(
                          padding: EdgeInsets.fromLTRB(18, 8, 18, bottomInset),
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
                                    color: chatSurface,
                                    borderRadius: BorderRadius.circular(24),
                                    border: Border.all(color: chatBorder),
                                  ),
                                  child: Row(
                                    children: [
                                      Expanded(
                                        child: AudioMessagePlayer(
                                          source: _pendingAudioUrl!,
                                          durationSeconds:
                                              _pendingAudioDuration,
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
                              if (_recording)
                                Container(
                                  width: double.infinity,
                                  margin: const EdgeInsets.only(bottom: 10),
                                  padding: const EdgeInsets.symmetric(
                                    horizontal: 16,
                                    vertical: 12,
                                  ),
                                  decoration: BoxDecoration(
                                    color: chatSurface,
                                    borderRadius: BorderRadius.circular(24),
                                    border: Border.all(color: chatBorder),
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
                                          style: TextStyle(
                                            color: headerText,
                                            fontSize: 15,
                                            fontWeight: FontWeight.w700,
                                          ),
                                        ),
                                      ),
                                      TextButton(
                                        onPressed: _toggleRecording,
                                        child: const Text('Stop'),
                                      ),
                                    ],
                                  ),
                                ),
                              Container(
                                padding: const EdgeInsets.fromLTRB(
                                  12,
                                  10,
                                  10,
                                  10,
                                ),
                                decoration: BoxDecoration(
                                  color: chatSurface,
                                  borderRadius: BorderRadius.circular(28),
                                  border: Border.all(color: chatBorder),
                                ),
                                child: Row(
                                  children: [
                                    Container(
                                      width: 42,
                                      height: 42,
                                      decoration: BoxDecoration(
                                        color: chatSurfaceAlt,
                                        shape: BoxShape.circle,
                                        border: Border.all(color: chatBorder),
                                      ),
                                      child: IconButton(
                                        onPressed: _sendImage,
                                        padding: EdgeInsets.zero,
                                        icon: Icon(
                                          Icons.image_outlined,
                                          color: headerText,
                                          size: 20,
                                        ),
                                      ),
                                    ),
                                    const SizedBox(width: 10),
                                    Expanded(
                                      child: TextField(
                                        controller: _draftController,
                                        keyboardType: TextInputType.multiline,
                                        textInputAction:
                                            TextInputAction.newline,
                                        textCapitalization:
                                            TextCapitalization.sentences,
                                        minLines: 1,
                                        maxLines: 5,
                                        enabled: socketStatus == 'connected',
                                        onChanged: _handleDraftChanged,
                                        style: TextStyle(
                                          color: headerText,
                                          fontSize: 17,
                                          height: 1.3,
                                        ),
                                        decoration: InputDecoration(
                                          hintText: 'Type a message...',
                                          hintStyle: TextStyle(
                                            color: composerHint,
                                            fontSize: 17,
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
                                              _draftController.text
                                                  .trim()
                                                  .isNotEmpty
                                              ? talkflixPrimary
                                              : _pendingAudioUrl != null
                                              ? talkflixPrimary
                                              : chatSurfaceAlt,
                                          shape: BoxShape.circle,
                                          border: Border.all(
                                            color:
                                                _draftController.text
                                                    .trim()
                                                    .isNotEmpty
                                                ? talkflixPrimary
                                                : _pendingAudioUrl != null
                                                ? talkflixPrimary
                                                : chatBorder,
                                          ),
                                        ),
                                        child: IconButton(
                                          onPressed: _handleComposerPrimaryAction,
                                          padding: EdgeInsets.zero,
                                          icon: Icon(
                                            _draftController.text
                                                    .trim()
                                                    .isNotEmpty
                                                ? Icons.send_rounded
                                                : _pendingAudioUrl != null
                                                ? Icons.send_rounded
                                                : _recording
                                                ? Icons.stop_circle_outlined
                                                : Icons.mic_none_outlined,
                                            color:
                                                _draftController.text
                                                    .trim()
                                                    .isNotEmpty
                                                ? Colors.white
                                                : _pendingAudioUrl != null
                                                ? Colors.white
                                                : headerText,
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
                      ],
                    ),
                  );
                },
              ),
            ),
          if (_phase == 'ended')
            Center(
              child: Padding(
                padding: const EdgeInsets.all(28),
                child: Container(
                  width: double.infinity,
                  constraints: const BoxConstraints(maxWidth: 420),
                  padding: const EdgeInsets.fromLTRB(24, 28, 24, 24),
                  decoration: BoxDecoration(
                    color: chatSurface,
                    borderRadius: BorderRadius.circular(28),
                    border: Border.all(color: chatBorder),
                    boxShadow: [
                      BoxShadow(
                        color: Colors.black.withValues(alpha: 0.18),
                        blurRadius: 24,
                        offset: const Offset(0, 10),
                      ),
                    ],
                  ),
                  child: Column(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      Text(
                        'Session ended',
                        style: theme.textTheme.headlineSmall?.copyWith(
                          fontWeight: FontWeight.w900,
                        ),
                      ),
                      const SizedBox(height: 8),
                      Text(
                        'Your 10-minute chat is over.',
                        style: theme.textTheme.bodyLarge,
                        textAlign: TextAlign.center,
                      ),
                      const SizedBox(height: 20),
                      FilledButton(
                        onPressed: _joinQueue,
                        child: const Text('Match again'),
                      ),
                    ],
                  ),
                ),
              ),
            ),
          if (_callOpen)
            Positioned.fill(
              child: _AnonCallOverlay(
                incoming: _callIncoming,
                accepted: _callAccepted,
                connected: _callConnected,
                status: _status,
                localRenderer: _localRenderer,
                remoteRenderer: _remoteRenderer,
                remoteVideoEnabled: _remoteVideoEnabled,
                localVideoEnabled: _localVideoEnabled,
                localVideoMirrored: _localVideoMirrored,
                micEnabled: _micEnabled,
                speakerOn: _speakerOn,
                onAccept: _acceptCall,
                onDecline: _declineCall,
                onEnd: _endCall,
                onSkip: _skipMatch,
                onToggleMute: _toggleMute,
                onToggleCamera: _toggleCamera,
                onToggleSpeaker: () => _toggleSpeaker(),
                onClose: () => setState(() => _callOpen = false),
                onSwitchCamera: _switchCamera,
                callSeconds: _callSeconds,
              ),
            ),
        ],
      ),
    );
  }

  String _randomId() =>
      '${DateTime.now().millisecondsSinceEpoch}_${Random().nextInt(999999)}';

  String _formatCountdown(int totalSeconds) {
    final minutes = (totalSeconds ~/ 60).toString().padLeft(2, '0');
    final seconds = (totalSeconds % 60).toString().padLeft(2, '0');
    return '$minutes:$seconds';
  }
}

class _AnonMessage {
  _AnonMessage({
    required this.id,
    required this.mine,
    required this.type,
    required this.text,
    required this.createdAt,
    this.imageUrl,
    this.imageBytes,
    this.audioUrl,
    this.audioDuration = 0,
    this.system = false,
  });

  final String id;
  final bool mine;
  final String type;
  final String text;
  final DateTime createdAt;
  final String? imageUrl;
  final Uint8List? imageBytes;
  final String? audioUrl;
  final int audioDuration;
  final bool system;

  factory _AnonMessage.system(String text) => _AnonMessage(
    id: 'sys_${DateTime.now().millisecondsSinceEpoch}',
    mine: false,
    type: 'system',
    text: text,
    createdAt: DateTime.now(),
    system: true,
  );

  factory _AnonMessage.fromSocket(Map<String, dynamic> json, String meId) {
    final ts =
        (json['ts'] as num?)?.toInt() ?? DateTime.now().millisecondsSinceEpoch;
    return _AnonMessage(
      id: json['clientMessageId']?.toString() ?? '${json['from'] ?? 'msg'}_$ts',
      mine: json['from']?.toString() == meId,
      type: json['type']?.toString() ?? 'text',
      text: json['text']?.toString() ?? '',
      createdAt: DateTime.fromMillisecondsSinceEpoch(ts),
      imageUrl: json['imageUrl']?.toString(),
      imageBytes: tryDecodeDataUrl(json['imageUrl']?.toString() ?? ''),
      audioUrl: json['audioUrl']?.toString(),
      audioDuration: (json['audioDuration'] as num?)?.toInt() ?? 0,
    );
  }
}

class _AnonMessageBody extends StatelessWidget {
  const _AnonMessageBody({required this.message});

  final _AnonMessage message;

  @override
  Widget build(BuildContext context) {
    if (message.type == 'image' && (message.imageUrl ?? '').isNotEmpty) {
      return _AnonImageBubble(message: message);
    }
    if (message.type == 'audio') {
      return AudioMessagePlayer(
        source: message.audioUrl ?? '',
        durationSeconds: message.audioDuration,
        mine: message.mine,
      );
    }
    return Text(message.text);
  }
}

class _AnonImageBubble extends StatelessWidget {
  const _AnonImageBubble({required this.message});

  final _AnonMessage message;

  @override
  Widget build(BuildContext context) {
    final provider = message.imageBytes != null
        ? MemoryImage(message.imageBytes!)
        : NetworkImage(resolveMediaUrl(message.imageUrl!)) as ImageProvider;
    return GestureDetector(
      onTap: () {
        Navigator.of(context).push(
          PageRouteBuilder<void>(
            opaque: false,
            pageBuilder: (context, animation, secondaryAnimation) => _AnonFullscreenImageView(
              provider: provider,
              heroTag: message.id,
            ),
          ),
        );
      },
      child: Hero(
        tag: message.id,
        child: ClipRRect(
          borderRadius: BorderRadius.circular(14),
          child: SizedBox(
            width: 224,
            height: 280,
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

class _AnonFullscreenImageView extends StatelessWidget {
  const _AnonFullscreenImageView({
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

class _ChatActionCircle extends StatelessWidget {
  const _ChatActionCircle({
    required this.icon,
    this.onTap,
    this.size = 88,
    this.iconSize = 30,
  });

  final IconData icon;
  final VoidCallback? onTap;
  final double size;
  final double iconSize;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final isDark = theme.brightness == Brightness.dark;
    return Material(
      color: isDark ? const Color(0xFF171717) : const Color(0xFFF7F7F7),
      shape: CircleBorder(
        side: BorderSide(
          color: isDark ? const Color(0xFF3A3A3A) : const Color(0xFFDADADA),
        ),
      ),
      child: InkWell(
        customBorder: const CircleBorder(),
        onTap: onTap,
        child: SizedBox(
          width: size,
          height: size,
          child: Icon(
            icon,
            color: isDark ? Colors.white : Colors.black87,
            size: iconSize,
          ),
        ),
      ),
    );
  }
}

class _AnonCallOverlay extends StatefulWidget {
  const _AnonCallOverlay({
    required this.incoming,
    required this.accepted,
    required this.connected,
    required this.status,
    required this.localRenderer,
    required this.remoteRenderer,
    required this.remoteVideoEnabled,
    required this.localVideoEnabled,
    required this.localVideoMirrored,
    required this.micEnabled,
    required this.speakerOn,
    required this.onAccept,
    required this.onDecline,
    required this.onEnd,
    required this.onSkip,
    required this.onToggleMute,
    required this.onToggleCamera,
    required this.onToggleSpeaker,
    required this.onClose,
    required this.onSwitchCamera,
    required this.callSeconds,
  });

  final bool incoming;
  final bool accepted;
  final bool connected;
  final String? status;
  final RTCVideoRenderer localRenderer;
  final RTCVideoRenderer remoteRenderer;
  final bool remoteVideoEnabled;
  final bool localVideoEnabled;
  final bool localVideoMirrored;
  final bool micEnabled;
  final bool speakerOn;
  final VoidCallback onAccept;
  final VoidCallback onDecline;
  final VoidCallback onEnd;
  final VoidCallback onSkip;
  final VoidCallback onToggleMute;
  final VoidCallback onToggleCamera;
  final VoidCallback onToggleSpeaker;
  final VoidCallback onClose;
  final VoidCallback onSwitchCamera;
  final int callSeconds;

  @override
  State<_AnonCallOverlay> createState() => _AnonCallOverlayState();
}

class _AnonCallOverlayState extends State<_AnonCallOverlay> {
  Offset _previewOffset = const Offset(18, 110);
  bool _primaryVideoRemote = true;
  bool _previewMoved = false;

  VoidCallback? _withHaptic(
    VoidCallback? action, {
    bool strong = false,
  }) {
    if (action == null) return null;
    return () {
      if (strong) {
        HapticFeedback.mediumImpact();
      } else {
        HapticFeedback.selectionClick();
      }
      action();
    };
  }

  @override
  void didUpdateWidget(covariant _AnonCallOverlay oldWidget) {
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
            // Full-screen video or avatar fallback
            Positioned.fill(
              child: showAnyVideo
                  ? RTCVideoView(
                      primaryRenderer,
                      mirror: primaryMirror,
                      objectFit:
                          RTCVideoViewObjectFit.RTCVideoViewObjectFitCover,
                    )
                  : DecoratedBox(
                      decoration: const BoxDecoration(
                        color: Color(0xFF111111),
                      ),
                      child: Center(
                        child: Column(
                          mainAxisSize: MainAxisSize.min,
                          children: [
                            const CircleAvatar(
                              radius: 54,
                              backgroundColor: Colors.white12,
                              child: Text(
                                '?',
                                style: TextStyle(
                                  color: Colors.white,
                                  fontSize: 36,
                                  fontWeight: FontWeight.w900,
                                ),
                              ),
                            ),
                            const SizedBox(height: 18),
                            Text(
                              'Anonymous',
                              style: Theme.of(context)
                                  .textTheme
                                  .headlineSmall
                                  ?.copyWith(
                                    color: Colors.white,
                                    fontWeight: FontWeight.w800,
                                  ),
                            ),
                            const SizedBox(height: 8),
                            AnimatedSwitcher(
                              duration: const Duration(milliseconds: 220),
                              switchInCurve: Curves.easeOutCubic,
                              switchOutCurve: Curves.easeInCubic,
                              child: Text(
                                widget.status ??
                                    (widget.connected
                                        ? 'Connected'
                                        : 'Calling'),
                                key: ValueKey<String>(
                                  widget.status ??
                                      (widget.connected
                                          ? 'Connected'
                                          : 'Calling'),
                                ),
                                style: Theme.of(context)
                                    .textTheme
                                    .titleMedium
                                    ?.copyWith(color: Colors.white70),
                              ),
                            ),
                          ],
                        ),
                      ),
                    ),
            ),
            // Top status pill
            Positioned(
              top: topInset + 18,
              left: 0,
              right: 0,
              child: Center(
                child: AnimatedSwitcher(
                  duration: const Duration(milliseconds: 220),
                  switchInCurve: Curves.easeOutCubic,
                  switchOutCurve: Curves.easeInCubic,
                  child: _AnonCallMetaPill(
                    key: ValueKey<String>(
                      widget.connected
                          ? _formatCallTime(widget.callSeconds)
                          : (widget.status ?? 'Calling'),
                    ),
                    label: widget.connected
                        ? _formatCallTime(widget.callSeconds)
                        : (widget.status ?? 'Calling'),
                  ),
                ),
              ),
            ),
            // Draggable PiP preview
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
            // Bottom control bar
            Positioned(
              left: 20,
              right: 20,
              bottom: bottomInset + 24,
              child: ClipRRect(
                borderRadius: BorderRadius.circular(24),
                child: BackdropFilter(
                  filter: ImageFilter.blur(sigmaX: 14, sigmaY: 14),
                  child: Container(
                    padding: const EdgeInsets.fromLTRB(14, 12, 14, 12),
                    decoration: BoxDecoration(
                      color: Colors.black.withValues(alpha: 0.28),
                      borderRadius: BorderRadius.circular(24),
                      border: Border.all(color: Colors.white24),
                    ),
                    child: Column(
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        if (widget.incoming)
                          Row(
                            mainAxisAlignment: MainAxisAlignment.center,
                            children: [
                              FilledButton.icon(
                                onPressed: _withHaptic(widget.onAccept),
                                icon: const Icon(Icons.call_rounded),
                                label: const Text('Answer'),
                              ),
                              const SizedBox(width: 12),
                              OutlinedButton.icon(
                                onPressed: _withHaptic(
                                  widget.onDecline,
                                  strong: true,
                                ),
                                style: OutlinedButton.styleFrom(
                                  foregroundColor: Colors.white,
                                  side: const BorderSide(color: Colors.white30),
                                ),
                                icon: const Icon(Icons.call_end_rounded),
                                label: const Text('Decline'),
                              ),
                            ],
                          )
                        else
                          Wrap(
                            alignment: WrapAlignment.center,
                            spacing: 6,
                            runSpacing: 10,
                            children: [
                              IconButton.filledTonal(
                                style: IconButton.styleFrom(
                                  backgroundColor: Colors.white12,
                                  foregroundColor: Colors.white,
                                ),
                                onPressed: widget.connected
                                    ? _withHaptic(widget.onToggleMute)
                                    : null,
                                icon: Icon(
                                  widget.micEnabled
                                      ? Icons.mic_none
                                      : Icons.mic_off_outlined,
                                ),
                              ),
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
                                    ? _withHaptic(widget.onToggleCamera)
                                    : null,
                                icon: Icon(
                                  widget.localVideoEnabled
                                      ? Icons.videocam_outlined
                                      : Icons.videocam_off_outlined,
                                ),
                              ),
                              IconButton.filledTonal(
                                style: IconButton.styleFrom(
                                  backgroundColor: widget.speakerOn
                                      ? const Color(0x33FFFFFF)
                                      : Colors.white12,
                                  foregroundColor: Colors.white,
                                ),
                                onPressed: widget.connected
                                    ? _withHaptic(widget.onToggleSpeaker)
                                    : null,
                                icon: Icon(
                                  widget.speakerOn
                                      ? Icons.volume_up_outlined
                                      : Icons.volume_off_outlined,
                                ),
                              ),
                              IconButton.filledTonal(
                                style: IconButton.styleFrom(
                                  backgroundColor: Colors.white12,
                                  foregroundColor: Colors.white,
                                ),
                                onPressed:
                                    widget.connected && widget.localVideoEnabled
                                    ? _withHaptic(widget.onSwitchCamera)
                                    : null,
                                icon: const Icon(Icons.cameraswitch_outlined),
                              ),
                              IconButton.filledTonal(
                                style: IconButton.styleFrom(
                                  backgroundColor: Colors.white12,
                                  foregroundColor: Colors.white,
                                ),
                                onPressed: _withHaptic(widget.onClose),
                                icon: const Icon(Icons.chat_bubble_outline_rounded),
                              ),
                              IconButton.filledTonal(
                                style: IconButton.styleFrom(
                                  backgroundColor: Colors.white12,
                                  foregroundColor: Colors.white,
                                ),
                                onPressed: _withHaptic(widget.onSkip),
                                icon: const Icon(Icons.skip_next_rounded),
                              ),
                              IconButton.filled(
                                style: IconButton.styleFrom(
                                  backgroundColor: talkflixPrimary,
                                  foregroundColor: Colors.white,
                                ),
                                onPressed: _withHaptic(
                                  widget.onEnd,
                                  strong: true,
                                ),
                                icon: const Icon(Icons.call_end),
                              ),
                            ],
                          ),
                      ],
                    ),
                  ),
                ),
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

class _AnonCallMetaPill extends StatelessWidget {
  const _AnonCallMetaPill({super.key, required this.label});

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
