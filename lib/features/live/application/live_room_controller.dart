import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../domain/live_permissions.dart';
import '../domain/live_role.dart';
import '../domain/live_stage_state.dart';

final liveRoomControllerProvider =
    StateNotifierProvider.autoDispose<LiveRoomController, LiveRoomState>((ref) {
      return LiveRoomController();
    });

class LiveRoomController extends StateNotifier<LiveRoomState> {
  LiveRoomController() : super(LiveRoomState.initial());

  void hydrate({
    required Map<String, dynamic>? room,
    required String meId,
    bool localMicEnabled = false,
  }) {
    if (room == null || meId.isEmpty) {
      state = LiveRoomState.initial();
      return;
    }
    final role = _resolveRole(room: room, meId: meId);
    final stageState = _resolveStageState(
      room: room,
      meId: meId,
      role: role,
      localMicEnabled: localMicEnabled,
    );
    state = LiveRoomState(
      role: role,
      stageState: stageState,
      permissions: LiveRoomPermissions.fromRole(role),
    );
  }

  bool canModerateTarget({
    required String myUserId,
    required String targetUserId,
    required String hostUserId,
  }) {
    if (targetUserId.isEmpty || targetUserId == myUserId) return false;
    if (!state.permissions.canModerateRoom) return false;
    if (state.role != LiveRoomRole.host && targetUserId == hostUserId) {
      return false;
    }
    return true;
  }

  bool canRemoveFromStage({
    required String myUserId,
    required String targetUserId,
    required String hostUserId,
  }) {
    if (targetUserId.isEmpty || targetUserId == myUserId) return false;
    if (hostUserId.isEmpty || myUserId != hostUserId) return false;
    return targetUserId != hostUserId;
  }

  LiveRoomRole _resolveRole({
    required Map<String, dynamic> room,
    required String meId,
  }) {
    final hostUserId = _resolveHostUserId(room);
    if (hostUserId == meId) return LiveRoomRole.host;

    final moderators = (room['moderators'] as List<dynamic>? ?? const [])
        .whereType<Map>()
        .map((item) => '${item['userId'] ?? ''}')
        .where((id) => id.isNotEmpty)
        .toSet();
    if (moderators.contains(meId)) return LiveRoomRole.moderator;

    final speakers = (room['speakers'] as List<dynamic>? ?? const [])
        .whereType<Map>()
        .map((item) => '${item['userId'] ?? ''}')
        .where((id) => id.isNotEmpty)
        .toSet();
    if (speakers.contains(meId)) return LiveRoomRole.speaker;

    return LiveRoomRole.listener;
  }

  LiveStageState _resolveStageState({
    required Map<String, dynamic> room,
    required String meId,
    required LiveRoomRole role,
    required bool localMicEnabled,
  }) {
    if (role == LiveRoomRole.listener) return LiveStageState.listener;
    final speakers = (room['speakers'] as List<dynamic>? ?? const [])
        .whereType<Map>()
        .map((item) => Map<String, dynamic>.from(item));
    final selfSpeaker = speakers.firstWhere(
      (item) => '${item['userId'] ?? ''}' == meId,
      orElse: () => const <String, dynamic>{},
    );
    if (selfSpeaker.isEmpty) return LiveStageState.listener;
    final muted = selfSpeaker['muted'] == true || !localMicEnabled;
    return muted
        ? LiveStageState.speakerMuted
        : LiveStageState.speakerUnmuted;
  }

  String _resolveHostUserId(Map<String, dynamic> room) {
    final direct = '${room['hostUserId'] ?? ''}'.trim();
    if (direct.isNotEmpty) return direct;
    final hostId = '${room['hostId'] ?? ''}'.trim();
    if (hostId.isNotEmpty) return hostId;
    final ownerId = '${room['ownerUserId'] ?? room['ownerId'] ?? ''}'.trim();
    if (ownerId.isNotEmpty) return ownerId;
    final createdBy = '${room['createdBy'] ?? room['createdByUserId'] ?? ''}'.trim();
    if (createdBy.isNotEmpty) return createdBy;
    final host = room['host'];
    if (host is Map) {
      final nested = '${host['userId'] ?? host['id'] ?? ''}'.trim();
      if (nested.isNotEmpty) return nested;
    }
    return '';
  }
}

class LiveRoomState {
  const LiveRoomState({
    required this.role,
    required this.stageState,
    required this.permissions,
  });

  factory LiveRoomState.initial() {
    return LiveRoomState(
      role: LiveRoomRole.listener,
      stageState: LiveStageState.listener,
      permissions: LiveRoomPermissions.fromRole(LiveRoomRole.listener),
    );
  }

  final LiveRoomRole role;
  final LiveStageState stageState;
  final LiveRoomPermissions permissions;
}
