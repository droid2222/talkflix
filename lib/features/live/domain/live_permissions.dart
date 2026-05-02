import 'live_role.dart';

class LiveRoomPermissions {
  const LiveRoomPermissions({
    required this.canManageStageRequests,
    required this.canModerateRoom,
    required this.canMuteParticipants,
    required this.canKickParticipants,
    required this.canPromoteModerators,
  });

  final bool canManageStageRequests;
  final bool canModerateRoom;
  final bool canMuteParticipants;
  final bool canKickParticipants;
  final bool canPromoteModerators;

  factory LiveRoomPermissions.fromRole(LiveRoomRole role) {
    switch (role) {
      case LiveRoomRole.host:
        return const LiveRoomPermissions(
          canManageStageRequests: true,
          canModerateRoom: true,
          canMuteParticipants: true,
          canKickParticipants: true,
          canPromoteModerators: true,
        );
      case LiveRoomRole.moderator:
        return const LiveRoomPermissions(
          canManageStageRequests: true,
          canModerateRoom: true,
          canMuteParticipants: true,
          canKickParticipants: true,
          canPromoteModerators: false,
        );
      case LiveRoomRole.speaker:
      case LiveRoomRole.listener:
        return const LiveRoomPermissions(
          canManageStageRequests: false,
          canModerateRoom: false,
          canMuteParticipants: false,
          canKickParticipants: false,
          canPromoteModerators: false,
        );
    }
  }
}
