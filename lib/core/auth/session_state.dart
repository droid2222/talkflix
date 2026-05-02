import 'app_user.dart';

enum SessionStatus { loading, unauthenticated, authenticated }

class SessionState {
  const SessionState({
    required this.status,
    this.token,
    this.sessionId,
    this.user,
    this.errorMessage,
  });

  const SessionState.loading() : this(status: SessionStatus.loading);

  const SessionState.unauthenticated({String? errorMessage})
    : this(status: SessionStatus.unauthenticated, errorMessage: errorMessage);

  const SessionState.authenticated({
    required String token,
    required String sessionId,
    required AppUser user,
  }) : this(
         status: SessionStatus.authenticated,
         token: token,
         sessionId: sessionId,
         user: user,
       );

  final SessionStatus status;
  final String? token;
  final String? sessionId;
  final AppUser? user;
  final String? errorMessage;

  bool get isLoading => status == SessionStatus.loading;
  bool get isAuthenticated => status == SessionStatus.authenticated;
  bool get hasVerifiedSessionIdentity =>
      isAuthenticated && (sessionId?.isNotEmpty ?? false);
}
