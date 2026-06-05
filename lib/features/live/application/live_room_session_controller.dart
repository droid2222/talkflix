import 'package:flutter_riverpod/flutter_riverpod.dart';

final liveRoomSessionProvider =
    StateNotifierProvider<LiveRoomSessionController, LiveRoomSessionState>((
      ref,
    ) {
      return LiveRoomSessionController();
    });

class LiveRoomSessionController extends StateNotifier<LiveRoomSessionState> {
  LiveRoomSessionController() : super(const LiveRoomSessionState());

  void sync({
    required Map<String, dynamic>? room,
    required bool localMicEnabled,
    required bool handRaised,
    required String browseType,
  }) {
    if (room == null) {
      state = LiveRoomSessionState(minimized: state.minimized);
      return;
    }
    state = state.copyWith(
      room: _cloneRoom(room),
      localMicEnabled: localMicEnabled,
      handRaised: handRaised,
      browseType: browseType,
    );
  }

  void setMinimized(bool minimized) {
    if (state.minimized == minimized) return;
    state = state.copyWith(minimized: minimized);
  }

  void clear() {
    state = const LiveRoomSessionState();
  }

  Map<String, dynamic> _cloneRoom(Map<String, dynamic> room) {
    return <String, dynamic>{
      ...room,
      'speakers': (room['speakers'] as List<dynamic>? ?? const [])
          .map<dynamic>(
            (item) => item is Map ? Map<String, dynamic>.from(item) : item,
          )
          .toList(growable: false),
      'audienceMembers': (room['audienceMembers'] as List<dynamic>? ?? const [])
          .map<dynamic>(
            (item) => item is Map ? Map<String, dynamic>.from(item) : item,
          )
          .toList(growable: false),
      'joinRequests': (room['joinRequests'] as List<dynamic>? ?? const [])
          .map<dynamic>(
            (item) => item is Map ? Map<String, dynamic>.from(item) : item,
          )
          .toList(growable: false),
      'moderators': (room['moderators'] as List<dynamic>? ?? const [])
          .map<dynamic>(
            (item) => item is Map ? Map<String, dynamic>.from(item) : item,
          )
          .toList(growable: false),
    };
  }
}

class LiveRoomSessionState {
  const LiveRoomSessionState({
    this.room,
    this.minimized = false,
    this.localMicEnabled = false,
    this.handRaised = false,
    this.browseType = 'audio',
  });

  final Map<String, dynamic>? room;
  final bool minimized;
  final bool localMicEnabled;
  final bool handRaised;
  final String browseType;

  bool get hasActiveRoom => room != null;
  bool get isAudioRoom => '${room?['type'] ?? 'audio'}' == 'audio';
  String get title => '${room?['title'] ?? 'Broadcast'}';
  String get hostPhotoUrl => '${room?['hostPhoto'] ?? ''}';
  String get hostUserId => '${room?['hostUserId'] ?? ''}';
  String get roomId => '${room?['id'] ?? ''}';

  LiveRoomSessionState copyWith({
    Object? room = _sentinel,
    bool? minimized,
    bool? localMicEnabled,
    bool? handRaised,
    String? browseType,
  }) {
    return LiveRoomSessionState(
      room: room == _sentinel ? this.room : room as Map<String, dynamic>?,
      minimized: minimized ?? this.minimized,
      localMicEnabled: localMicEnabled ?? this.localMicEnabled,
      handRaised: handRaised ?? this.handRaised,
      browseType: browseType ?? this.browseType,
    );
  }
}

const Object _sentinel = Object();
