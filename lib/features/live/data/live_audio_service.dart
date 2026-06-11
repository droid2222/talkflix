import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_webrtc/flutter_webrtc.dart' show Helper;
import 'package:livekit_client/livekit_client.dart';

final liveAudioServiceProvider = Provider<LiveAudioService>((ref) {
  return LiveAudioService();
});

/// LiveKit SFU wrapper for audio rooms and video broadcasts.
class LiveAudioService {
  Room? _room;
  bool _canPublish = false;
  bool _publishVideoRoom = false;
  String _connectedRoomName = '';
  bool? _lastAppliedMicEnabled;
  bool? _lastAppliedCameraEnabled;
  EventsListener<RoomEvent>? _roomListener;
  VoidCallback? onParticipantsChanged;

  Room? get room => _room;
  bool get isConnected => _room?.connectionState == ConnectionState.connected;
  bool get canPublish => _canPublish;
  bool get publishVideoRoom => _publishVideoRoom;
  bool get canPlaybackAudio => _room?.canPlaybackAudio ?? false;
  bool isConnectedToRoom(String roomName) =>
      isConnected && _connectedRoomName == roomName;
  bool get isLocalCameraEnabled =>
      _room?.localParticipant?.isCameraEnabled() ?? false;

  Set<String> get activeSpeakerIds {
    final room = _room;
    if (room == null || room.connectionState != ConnectionState.connected) {
      return const <String>{};
    }
    final speakers = room.activeSpeakers;
    return speakers
        .map((participant) => participant.identity)
        .whereType<String>()
        .where((identity) => identity.trim().isNotEmpty)
        .toSet();
  }

  bool get isLocalParticipantSpeaking {
    final room = _room;
    final local = room?.localParticipant;
    if (room == null ||
        local == null ||
        room.connectionState != ConnectionState.connected) {
      return false;
    }
    final identity = local.identity;
    if (identity.trim().isEmpty) return false;
    return activeSpeakerIds.contains(identity);
  }

  Future<void> connect({
    required String url,
    required String token,
    required String roomName,
    required bool canPublish,
    bool publishVideo = false,
  }) async {
    _publishVideoRoom = publishVideo;
    if (isConnectedToRoom(roomName)) {
      _canPublish = canPublish;
      await refreshStagePublish(
        shouldPublish: canPublish,
        micEnabled: true,
        cameraEnabled: publishVideo,
      );
      return;
    }
    await disconnect();
    final room = Room(
      roomOptions: const RoomOptions(
        adaptiveStream: true,
        dynacast: true,
        stopLocalTrackOnUnpublish: true,
      ),
    );
    await room.connect(
      url,
      token,
      connectOptions: const ConnectOptions(autoSubscribe: true),
      fastConnectOptions: FastConnectOptions(
        microphone: TrackOption(enabled: canPublish),
        camera: TrackOption(enabled: canPublish && publishVideo),
      ),
    );
    _room = room;
    _canPublish = canPublish;
    _connectedRoomName = roomName;
    _lastAppliedMicEnabled = room.localParticipant?.isMicrophoneEnabled();
    _lastAppliedCameraEnabled = room.localParticipant?.isCameraEnabled();
    _bindRoomListener(room);
    await startPlayback();
    await refreshStagePublish(
      shouldPublish: canPublish,
      micEnabled: true,
      cameraEnabled: publishVideo,
    );
  }

  void _bindRoomListener(Room room) {
    _roomListener?.dispose();
    final listener = room.createListener();
    void notify() => onParticipantsChanged?.call();
    listener
      ..on<TrackSubscribedEvent>((_) => notify())
      ..on<TrackUnsubscribedEvent>((_) => notify())
      ..on<TrackPublishedEvent>((_) => notify())
      ..on<TrackUnpublishedEvent>((_) => notify())
      ..on<ParticipantConnectedEvent>((_) => notify())
      ..on<ParticipantDisconnectedEvent>((_) => notify())
      ..on<LocalTrackPublishedEvent>((_) => notify())
      ..on<LocalTrackUnpublishedEvent>((_) => notify());
    _roomListener = listener;
  }

  Future<bool> startPlayback() async {
    final room = _room;
    if (room == null || room.connectionState != ConnectionState.connected) {
      return false;
    }
    if (room.canPlaybackAudio) {
      return true;
    }
    await room.startAudio();
    return room.canPlaybackAudio;
  }

  Future<void> refreshStagePublish({
    required bool shouldPublish,
    required bool micEnabled,
    required bool cameraEnabled,
  }) async {
    _canPublish = shouldPublish;
    final room = _room;
    if (room == null || room.connectionState != ConnectionState.connected) {
      return;
    }
    final local = room.localParticipant;
    if (local == null) return;

    final micOn = shouldPublish && micEnabled;
    final currentMic = local.isMicrophoneEnabled();
    if (_lastAppliedMicEnabled != micOn || currentMic != micOn) {
      await local.setMicrophoneEnabled(micOn);
      _lastAppliedMicEnabled = micOn;
    }

    if (_publishVideoRoom) {
      final camOn = shouldPublish && cameraEnabled;
      final currentCam = local.isCameraEnabled();
      if (_lastAppliedCameraEnabled != camOn || currentCam != camOn) {
        await local.setCameraEnabled(camOn);
        _lastAppliedCameraEnabled = camOn;
      }
    }
  }

  /// Back-compat for audio-only publish toggles.
  Future<void> setPublishing(bool enabled) async {
    await refreshStagePublish(
      shouldPublish: enabled,
      micEnabled: enabled,
      cameraEnabled: enabled,
    );
  }

  Future<void> setMicEnabled(bool enabled) async {
    await refreshStagePublish(
      shouldPublish: _canPublish,
      micEnabled: enabled,
      cameraEnabled: _lastAppliedCameraEnabled ?? false,
    );
  }

  Future<void> setCameraEnabled(bool enabled) async {
    await refreshStagePublish(
      shouldPublish: _canPublish,
      micEnabled: _lastAppliedMicEnabled ?? false,
      cameraEnabled: enabled,
    );
  }

  VideoTrack? videoTrackForIdentity(String identity) {
    final room = _room;
    if (room == null || !isConnected) return null;
    final trimmed = identity.trim();
    if (trimmed.isEmpty) return null;

    final local = room.localParticipant;
    if (local != null && local.identity == trimmed) {
      return _cameraVideoTrack(local);
    }

    for (final participant in room.remoteParticipants.values) {
      if (participant.identity != trimmed) continue;
      return _cameraVideoTrack(participant);
    }
    return null;
  }

  VideoTrack? _cameraVideoTrack(Participant participant) {
    final direct = participant.getTrackPublicationBySource(TrackSource.camera);
    final directTrack = direct?.track;
    if (directTrack is VideoTrack && directTrack.muted != true) {
      return directTrack;
    }
    if (participant is RemoteParticipant) {
      for (final publication in participant.videoTrackPublications) {
        if (!publication.subscribed || publication.muted) continue;
        final videoTrack = publication.track;
        if (videoTrack is VideoTrack) {
          return videoTrack;
        }
      }
    }
    return null;
  }

  Future<bool> switchCamera() async {
    final local = _room?.localParticipant;
    if (local == null) return false;
    final publication = local.getTrackPublicationBySource(TrackSource.camera);
    final track = publication?.track;
    if (track is! LocalVideoTrack) return false;
    await Helper.switchCamera(track.mediaStreamTrack);
    return true;
  }

  Future<void> disconnect() async {
    await _roomListener?.dispose();
    _roomListener = null;
    onParticipantsChanged = null;
    final room = _room;
    _room = null;
    _canPublish = false;
    _publishVideoRoom = false;
    _connectedRoomName = '';
    _lastAppliedMicEnabled = null;
    _lastAppliedCameraEnabled = null;
    if (room != null) {
      await room.disconnect();
      await room.dispose();
    }
  }
}
