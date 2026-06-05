import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../auth/app_user.dart';

enum AcceptedDirectCallStage {
  pendingNavigation,
  permissions,
  transportPreparing,
  transportReady,
  mediaPreparing,
  mediaReady,
  readyEmitting,
  ready,
  active,
  failed,
}

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
    String callId = '',
    required bool video,
    AppUser? caller,
  }) {
    final existing = state.incoming;
    if (existing != null &&
        existing.threadId == threadId &&
        existing.fromUserId == fromUserId &&
        existing.callId == callId &&
        existing.video == video) {
      return;
    }
    state = state.copyWith(
      incoming: GlobalIncomingDirectCall(
        threadId: threadId,
        fromUserId: fromUserId,
        callId: callId,
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
    startAcceptedHandoff(
      threadId: incoming.threadId,
      partnerId: incoming.fromUserId,
      callId: incoming.callId,
      video: incoming.video,
    );
  }

  void startAcceptedHandoff({
    required String threadId,
    required String partnerId,
    String callId = '',
    required bool video,
  }) {
    final existing = state.acceptedHandoff;
    if (existing != null &&
        existing.threadId == threadId &&
        existing.partnerId == partnerId &&
        existing.callId == callId &&
        existing.video == video) {
      return;
    }
    final handoff = AcceptedDirectCallHandoff(
      threadId: threadId,
      partnerId: partnerId,
      callId: callId,
      video: video,
      acceptedAt: DateTime.now(),
      stage: AcceptedDirectCallStage.pendingNavigation,
    );
    state = state.copyWith(
      clearIncoming: true,
      acceptedHandoff: handoff,
      pendingAccepted: PendingAcceptedDirectCall(
        threadId: threadId,
        partnerId: partnerId,
        callId: callId,
        video: video,
      ),
    );
  }

  /// Same pending handoff as [acceptIncoming], for CallKit accept without prior overlay state.
  void stageCalleeAcceptedFromCallKit({
    required String threadId,
    required String partnerId,
    String callId = '',
    required bool video,
  }) {
    startAcceptedHandoff(
      threadId: threadId,
      partnerId: partnerId,
      callId: callId,
      video: video,
    );
  }

  bool hasAcceptedHandoffFor({required String threadId, String callId = ''}) {
    final handoff = state.acceptedHandoff;
    if (handoff == null || handoff.threadId != threadId) return false;
    final normalizedCallId = callId.trim();
    if (normalizedCallId.isEmpty || handoff.callId.trim().isEmpty) return true;
    return handoff.callId.trim() == normalizedCallId;
  }

  void updateAcceptedHandoffStage({
    required String threadId,
    required AcceptedDirectCallStage stage,
    String? errorMessage,
    bool clearError = false,
    bool? serverAccepted,
  }) {
    final handoff = state.acceptedHandoff;
    if (handoff == null || handoff.threadId != threadId) return;
    state = state.copyWith(
      acceptedHandoff: handoff.copyWith(
        stage: stage,
        errorMessage: clearError
            ? null
            : (errorMessage ?? handoff.errorMessage),
        serverAccepted: serverAccepted ?? handoff.serverAccepted,
      ),
    );
  }

  void clearCallForThread(String threadId) {
    if (threadId.trim().isEmpty) return;
    final clearIncoming = state.incoming?.threadId == threadId;
    final clearPendingAccepted = state.pendingAccepted?.threadId == threadId;
    final clearAcceptedHandoff = state.acceptedHandoff?.threadId == threadId;
    if (!clearIncoming && !clearPendingAccepted && !clearAcceptedHandoff) {
      return;
    }
    state = state.copyWith(
      clearIncoming: clearIncoming,
      clearPendingAccepted: clearPendingAccepted,
      clearAcceptedHandoff: clearAcceptedHandoff,
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

  void clearPendingAcceptedForThread(String threadId) {
    final pending = state.pendingAccepted;
    if (pending == null || pending.threadId != threadId) return;
    state = state.copyWith(clearPendingAccepted: true);
  }
}

class DirectCallState {
  const DirectCallState({
    this.incoming,
    this.pendingAccepted,
    this.acceptedHandoff,
  });

  final GlobalIncomingDirectCall? incoming;
  final PendingAcceptedDirectCall? pendingAccepted;
  final AcceptedDirectCallHandoff? acceptedHandoff;

  DirectCallState copyWith({
    GlobalIncomingDirectCall? incoming,
    PendingAcceptedDirectCall? pendingAccepted,
    AcceptedDirectCallHandoff? acceptedHandoff,
    bool clearIncoming = false,
    bool clearPendingAccepted = false,
    bool clearAcceptedHandoff = false,
  }) {
    return DirectCallState(
      incoming: clearIncoming ? null : (incoming ?? this.incoming),
      pendingAccepted: clearPendingAccepted
          ? null
          : (pendingAccepted ?? this.pendingAccepted),
      acceptedHandoff: clearAcceptedHandoff
          ? null
          : (acceptedHandoff ?? this.acceptedHandoff),
    );
  }
}

class GlobalIncomingDirectCall {
  const GlobalIncomingDirectCall({
    required this.threadId,
    required this.fromUserId,
    required this.callId,
    required this.video,
    this.caller,
  });

  final String threadId;
  final String fromUserId;
  final String callId;
  final bool video;
  final AppUser? caller;
}

class PendingAcceptedDirectCall {
  const PendingAcceptedDirectCall({
    required this.threadId,
    required this.partnerId,
    required this.callId,
    required this.video,
  });

  final String threadId;
  final String partnerId;
  final String callId;
  final bool video;
}

class AcceptedDirectCallHandoff {
  const AcceptedDirectCallHandoff({
    required this.threadId,
    required this.partnerId,
    required this.callId,
    required this.video,
    required this.acceptedAt,
    required this.stage,
    this.errorMessage,
    this.serverAccepted = false,
  });

  final String threadId;
  final String partnerId;
  final String callId;
  final bool video;
  final DateTime acceptedAt;
  final AcceptedDirectCallStage stage;
  final String? errorMessage;
  final bool serverAccepted;

  AcceptedDirectCallHandoff copyWith({
    AcceptedDirectCallStage? stage,
    String? errorMessage,
    bool? serverAccepted,
  }) {
    return AcceptedDirectCallHandoff(
      threadId: threadId,
      partnerId: partnerId,
      callId: callId,
      video: video,
      acceptedAt: acceptedAt,
      stage: stage ?? this.stage,
      errorMessage: errorMessage ?? this.errorMessage,
      serverAccepted: serverAccepted ?? this.serverAccepted,
    );
  }
}
