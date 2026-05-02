import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../../features/auth/data/auth_repository.dart';
import '../config/storage_keys.dart';
import '../network/api_exception.dart';
import 'session_state.dart';

final sharedPreferencesProvider = FutureProvider<SharedPreferences>(
  (ref) => SharedPreferences.getInstance(),
);

final sessionControllerProvider =
    StateNotifierProvider<SessionController, SessionState>((ref) {
      return SessionController(ref);
    });

class SessionController extends StateNotifier<SessionState> {
  SessionController(this._ref) : super(const SessionState.loading()) {
    Future<void>.microtask(bootstrap);
  }

  final Ref _ref;

  Future<void> bootstrap() async {
    state = const SessionState.loading();
    final prefs = await _ref.read(sharedPreferencesProvider.future);
    final token = prefs.getString(StorageKeys.token);

    if (token == null || token.isEmpty) {
      state = const SessionState.unauthenticated();
      return;
    }

    final repository = _ref.read(authRepositoryProvider);

    try {
      final user = await repository.fetchMe(tokenOverride: token);
      state = SessionState.authenticated(token: token, user: user);
    } on ApiException catch (error) {
      if (error.isUnauthorized) {
        await prefs.remove(StorageKeys.token);
        state = const SessionState.unauthenticated();
      } else {
        await prefs.remove(StorageKeys.token);
        state = SessionState.unauthenticated(
          errorMessage: userFriendlyMessage(error),
        );
      }
    } catch (error) {
      await prefs.remove(StorageKeys.token);
      state = const SessionState.unauthenticated(
        errorMessage: 'Could not restore your session. Please sign in again.',
      );
    }
  }

  Future<void> signIn({required String email, required String password}) async {
    final repository = _ref.read(authRepositoryProvider);
    try {
      final result = await repository.login(email: email, password: password);
      final prefs = await _ref.read(sharedPreferencesProvider.future);
      await prefs.setString(StorageKeys.token, result.token);
      state = SessionState.authenticated(token: result.token, user: result.user);
    } catch (error) {
      final message = error is ApiException
          ? userFriendlyMessage(error)
          : 'We could not sign you in right now. Please try again.';
      state = SessionState.unauthenticated(errorMessage: message);
      rethrow;
    }
  }

  Future<void> refreshProfile() async {
    if (state.token == null || state.token!.isEmpty) {
      state = const SessionState.unauthenticated();
      return;
    }

    final user = await _ref
        .read(authRepositoryProvider)
        .fetchMe(tokenOverride: state.token);
    state = SessionState.authenticated(token: state.token!, user: user);
  }

  Future<void> signOut() async {
    final prefs = await _ref.read(sharedPreferencesProvider.future);
    await prefs.remove(StorageKeys.token);
    state = const SessionState.unauthenticated();
  }

  Future<void> setAuthenticated({required String token, required user}) async {
    final prefs = await _ref.read(sharedPreferencesProvider.future);
    await prefs.setString(StorageKeys.token, token);
    state = SessionState.authenticated(token: token, user: user);
  }
}
