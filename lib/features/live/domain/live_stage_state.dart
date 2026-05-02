enum LiveStageState { listener, speakerMuted, speakerUnmuted }

extension LiveStageStateLabel on LiveStageState {
  String get label {
    switch (this) {
      case LiveStageState.listener:
        return 'Listener';
      case LiveStageState.speakerMuted:
        return 'Speaker (Muted)';
      case LiveStageState.speakerUnmuted:
        return 'Speaker (Live)';
    }
  }
}
