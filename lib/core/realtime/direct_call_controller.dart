import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../auth/app_user.dart';

final directCallControllerProvider =
    StateNotifierProvider<DirectCallController, DirectCallState>((ref) {
      return DirectCallController();
    });

class DirectCallController extends StateNotifier<DirectCallState> {
  DirectCallController() : super(const DirectCallState());

  void reset() {
    state = const DirectCallState();
  }

  void showIncoming({
    required String threadId,
    required String fromUserId,
    required bool video,
    AppUser? caller,
  }) {
    state = state.copyWith(
      incoming: GlobalIncomingDirectCall(
        threadId: threadId,
        fromUserId: fromUserId,
        video: video,
        caller: caller,
      ),
    );
  }

  void clearIncomingForThread(String threadId) {
    if (state.incoming?.threadId != threadId) return;
    state = state.copyWith(clearIncoming: true);
  }

  void acceptIncoming() {
    final incoming = state.incoming;
    if (incoming == null) return;
    state = state.copyWith(
      clearIncoming: true,
      pendingAccepted: PendingAcceptedDirectCall(
        threadId: incoming.threadId,
        partnerId: incoming.fromUserId,
        video: incoming.video,
      ),
    );
  }

  void declineIncoming() {
    state = state.copyWith(clearIncoming: true);
  }

  PendingAcceptedDirectCall? consumePendingForPartner(String partnerId) {
    final pending = state.pendingAccepted;
    if (pending == null || pending.partnerId != partnerId) return null;
    state = state.copyWith(clearPendingAccepted: true);
    return pending;
  }
}

class DirectCallState {
  const DirectCallState({this.incoming, this.pendingAccepted});

  final GlobalIncomingDirectCall? incoming;
  final PendingAcceptedDirectCall? pendingAccepted;

  DirectCallState copyWith({
    GlobalIncomingDirectCall? incoming,
    PendingAcceptedDirectCall? pendingAccepted,
    bool clearIncoming = false,
    bool clearPendingAccepted = false,
  }) {
    return DirectCallState(
      incoming: clearIncoming ? null : (incoming ?? this.incoming),
      pendingAccepted: clearPendingAccepted
          ? null
          : (pendingAccepted ?? this.pendingAccepted),
    );
  }
}

class GlobalIncomingDirectCall {
  const GlobalIncomingDirectCall({
    required this.threadId,
    required this.fromUserId,
    required this.video,
    this.caller,
  });

  final String threadId;
  final String fromUserId;
  final bool video;
  final AppUser? caller;
}

class PendingAcceptedDirectCall {
  const PendingAcceptedDirectCall({
    required this.threadId,
    required this.partnerId,
    required this.video,
  });

  final String threadId;
  final String partnerId;
  final bool video;
}
