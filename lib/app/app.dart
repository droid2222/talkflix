import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../core/auth/session_controller.dart';
import '../core/auth/session_state.dart';
import '../core/realtime/direct_call_controller.dart';
import '../core/realtime/socket_service.dart';
import '../features/live/presentation/live_screen.dart';
import '../features/meet/presentation/meet_filters_controller.dart';
import '../features/meet/presentation/meet_results_screen.dart';
import '../features/meet/presentation/meet_screen.dart';
import '../features/notifications/presentation/notifications_controller.dart';
import '../features/profile/presentation/profile_screen.dart';
import '../features/splash/presentation/splash_screen.dart';
import '../features/talk/presentation/talk_inbox_screen.dart';
import 'router/app_router.dart';
import 'theme/app_theme.dart';
import 'theme/theme_mode_controller.dart';

class TalkflixApp extends ConsumerWidget {
  const TalkflixApp({super.key});

  void _resetSessionScopedState(WidgetRef ref) {
    ref.invalidate(recentThreadsProvider);
    ref.invalidate(meetUsersProvider);
    ref.invalidate(meetResultsProvider);
    ref.invalidate(meetFiltersProvider);
    ref.invalidate(profileProvider);
    ref.invalidate(notificationsControllerProvider);

    ref.read(unreadNotificationCountProvider.notifier).state = 0;
    ref.read(meetFeedLanguageProvider.notifier).state = 'Any';
    ref.read(liveAudioRoomActiveProvider.notifier).state = false;
    ref.read(liveModeProvider.notifier).state = 'broadcast';
    ref.read(liveBrowseTypeProvider.notifier).state = 'audio';
    ref.read(liveBroadcastCacheProvider.notifier).state = const [];
    ref.read(directCallControllerProvider.notifier).reset();
  }

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    ref.listen<SessionState>(sessionControllerProvider, (previous, next) {
      final previousUserId = previous?.user?.id ?? '';
      final nextUserId = next.user?.id ?? '';
      final previousToken = previous?.token ?? '';
      final nextToken = next.token ?? '';
      final sessionIdentityChanged =
          previousUserId != nextUserId ||
          previousToken != nextToken ||
          previous?.isAuthenticated != next.isAuthenticated;

      if (sessionIdentityChanged) {
        _resetSessionScopedState(ref);
      }

      final liveSocket = ref.read(socketServiceProvider);
      if (next.isAuthenticated && next.token != null) {
        liveSocket.connect(next.token!);
      } else {
        liveSocket.disconnect();
      }
    });

    final router = ref.watch(appRouterProvider);
    final themeMode = ref.watch(themeModeControllerProvider);

    return MaterialApp.router(
      debugShowCheckedModeBanner: false,
      title: 'Talkflix',
      theme: buildTalkflixLightTheme(),
      darkTheme: buildTalkflixDarkTheme(),
      themeMode: themeMode,
      builder: (context, child) =>
          TalkflixSplashGate(child: child ?? const SizedBox.shrink()),
      routerConfig: router,
    );
  }
}
