import 'dart:async';

import 'package:livekit_client/livekit_client.dart';

class LiveAudioService {
  Room? _room;
  bool _canPublish = false;
  String _connectedRoomName = '';
  bool? _lastAppliedMicEnabled;

  bool get isConnected => _room?.connectionState == ConnectionState.connected;
  bool get canPublish => _canPublish;
  bool isConnectedToRoom(String roomName) =>
      isConnected && _connectedRoomName == roomName;
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
  }) async {
    if (isConnectedToRoom(roomName)) {
      _canPublish = canPublish;
      await setPublishing(canPublish);
      return;
    }
    await disconnect();
    final room = Room(
      roomOptions: const RoomOptions(
        adaptiveStream: false,
        dynacast: false,
        stopLocalTrackOnUnpublish: true,
      ),
    );
    await room.connect(
      url,
      token,
      fastConnectOptions: FastConnectOptions(
        microphone: TrackOption(enabled: canPublish),
      ),
    );
    _room = room;
    _canPublish = canPublish;
    _connectedRoomName = roomName;
    _lastAppliedMicEnabled = room.localParticipant?.isMicrophoneEnabled();
    await setPublishing(canPublish);
  }

  Future<void> setPublishing(bool enabled) async {
    _canPublish = enabled;
    final room = _room;
    if (room == null || room.connectionState != ConnectionState.connected) {
      return;
    }
    final local = room.localParticipant;
    if (local == null) return;
    final current = local.isMicrophoneEnabled();
    if (_lastAppliedMicEnabled == enabled && current == enabled) {
      return;
    }
    if (current == enabled) {
      _lastAppliedMicEnabled = enabled;
      return;
    }
    await local.setMicrophoneEnabled(enabled);
    _lastAppliedMicEnabled = enabled;
  }

  Future<void> setMicEnabled(bool enabled) async {
    final room = _room;
    if (room == null || room.connectionState != ConnectionState.connected) {
      return;
    }
    final local = room.localParticipant;
    if (local == null) return;
    final current = local.isMicrophoneEnabled();
    if (_lastAppliedMicEnabled == enabled && current == enabled) {
      return;
    }
    if (current == enabled) {
      _lastAppliedMicEnabled = enabled;
      return;
    }
    await local.setMicrophoneEnabled(enabled);
    _lastAppliedMicEnabled = enabled;
  }

  Future<void> disconnect() async {
    final room = _room;
    _room = null;
    _canPublish = false;
    _connectedRoomName = '';
    _lastAppliedMicEnabled = null;
    if (room != null) {
      await room.disconnect();
      await room.dispose();
    }
  }
}
