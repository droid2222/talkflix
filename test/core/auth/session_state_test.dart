import 'package:flutter_test/flutter_test.dart';
import 'package:talkflix_flutter/core/auth/app_user.dart';
import 'package:talkflix_flutter/core/auth/session_state.dart';

void main() {
  group('SessionState', () {
    test('loading state has correct status', () {
      const state = SessionState.loading();
      expect(state.isLoading, isTrue);
      expect(state.isAuthenticated, isFalse);
      expect(state.token, isNull);
      expect(state.user, isNull);
    });

    test('unauthenticated state with no error', () {
      const state = SessionState.unauthenticated();
      expect(state.isLoading, isFalse);
      expect(state.isAuthenticated, isFalse);
      expect(state.errorMessage, isNull);
    });

    test('unauthenticated state with error message', () {
      const state = SessionState.unauthenticated(errorMessage: 'Bad creds');
      expect(state.errorMessage, 'Bad creds');
      expect(state.isAuthenticated, isFalse);
    });

    test('authenticated state has token and user', () {
      final user = AppUser.fromJson({'id': '1', 'email': 'test@test.com'});
      final state = SessionState.authenticated(
        token: 'tok_123',
        sessionId: 'sid_123',
        user: user,
      );
      expect(state.isAuthenticated, isTrue);
      expect(state.isLoading, isFalse);
      expect(state.token, 'tok_123');
      expect(state.sessionId, 'sid_123');
      expect(state.hasVerifiedSessionIdentity, isTrue);
      expect(state.user, isNotNull);
      expect(state.user!.id, '1');
    });
  });
}
