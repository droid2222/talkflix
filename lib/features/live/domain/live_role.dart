enum LiveRoomRole { host, moderator, speaker, listener }

extension LiveRoomRoleLabel on LiveRoomRole {
  String get label {
    switch (this) {
      case LiveRoomRole.host:
        return 'Host';
      case LiveRoomRole.moderator:
        return 'Moderator';
      case LiveRoomRole.speaker:
        return 'Speaker';
      case LiveRoomRole.listener:
        return 'Listener';
    }
  }
}
