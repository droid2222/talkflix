import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../../core/auth/session_controller.dart';
import '../../features/auth/presentation/forgot_password_screen.dart';
import '../../features/auth/presentation/login_screen.dart';
import '../../features/auth/presentation/reset_password_screen.dart';
import '../../features/auth/presentation/signup_screen.dart';
import '../../features/content/presentation/content_screen.dart';
import '../../features/content/presentation/creator_studio_screen.dart';
import '../../features/content/presentation/user_post_composer_screen.dart';
import '../../features/live/presentation/live_screen.dart';
import '../../features/meet/presentation/meet_anon_screen.dart';
import '../../features/meet/presentation/meet_filters_screen.dart';
import '../../features/meet/presentation/meet_results_screen.dart';
import '../../features/meet/presentation/meet_screen.dart';
import '../../features/profile/presentation/diagnostics_screen.dart';
import '../../features/profile/presentation/media_preview_screen.dart';
import '../../features/profile/presentation/profile_screen.dart';
import '../../features/profile/presentation/profile_settings_screen.dart';
import '../../features/profile/presentation/qa_checklist_screen.dart';
import '../../features/profile/presentation/follow_list_screen.dart';
import '../../features/shell/presentation/app_shell.dart';
import '../../features/talk/presentation/direct_chat_screen.dart';
import '../../features/talk/presentation/talk_inbox_screen.dart';
import '../../features/notifications/presentation/notifications_screen.dart';
import '../../features/upgrade/presentation/upgrade_screen.dart';

final _rootNavigatorKey = GlobalKey<NavigatorState>();
final _shellNavigatorKey = GlobalKey<NavigatorState>();

final appRouterProvider = Provider<GoRouter>((ref) {
  final session = ref.watch(sessionControllerProvider);

  return GoRouter(
    navigatorKey: _rootNavigatorKey,
    initialLocation: '/loading',
    redirect: (context, state) {
      final location = state.matchedLocation;
      const publicLocations = <String>{
        '/login',
        '/signup',
        '/forgot-password',
        '/reset-password',
      };

      if (session.isLoading) {
        return location == '/loading' ? null : '/loading';
      }

      if (!session.isAuthenticated) {
        if (location == '/loading') {
          return '/login';
        }
        return publicLocations.contains(location) ? null : '/login';
      }

      if (location == '/loading' ||
          publicLocations.contains(location) ||
          location == '/') {
        return '/app/talk';
      }

      return null;
    },
    routes: [
      GoRoute(
        path: '/loading',
        builder: (context, state) => const _LoadingScreen(),
      ),
      GoRoute(path: '/login', builder: (context, state) => const LoginScreen()),
      GoRoute(
        path: '/signup',
        builder: (context, state) => const SignupScreen(),
      ),
      GoRoute(
        path: '/forgot-password',
        builder: (context, state) => const ForgotPasswordScreen(),
      ),
      GoRoute(
        path: '/reset-password',
        builder: (context, state) =>
            ResetPasswordScreen(token: state.uri.queryParameters['token']),
      ),
      ShellRoute(
        navigatorKey: _shellNavigatorKey,
        builder: (context, state, child) => AppShell(child: child),
        routes: [
          GoRoute(
            path: '/app/talk',
            builder: (context, state) => const TalkInboxScreen(),
            routes: [
              GoRoute(
                path: ':userId',
                builder: (context, state) => DirectChatScreen(
                  userId: state.pathParameters['userId'] ?? '',
                ),
              ),
            ],
          ),
          GoRoute(
            path: '/app/live',
            builder: (context, state) => const LiveScreen(),
          ),
          GoRoute(
            path: '/app/meet',
            builder: (context, state) => const MeetScreen(),
            routes: [
              GoRoute(
                path: 'filters',
                builder: (context, state) => const MeetFiltersScreen(),
              ),
              GoRoute(
                path: 'results',
                builder: (context, state) => const MeetResultsScreen(),
              ),
              GoRoute(
                path: 'anon',
                pageBuilder: (context, state) => CustomTransitionPage<void>(
                  key: state.pageKey,
                  opaque: false,
                  barrierDismissible: false,
                  barrierColor: const Color(0x66000000),
                  child: const MeetAnonScreen(),
                  transitionsBuilder: (
                    context,
                    animation,
                    secondaryAnimation,
                    child,
                  ) {
                    return FadeTransition(
                      opacity: CurvedAnimation(
                        parent: animation,
                        curve: Curves.easeOut,
                      ),
                      child: child,
                    );
                  },
                ),
              ),
            ],
          ),
          GoRoute(
            path: '/app/content',
            builder: (context, state) => const ContentScreen(),
            routes: [
              GoRoute(
                path: 'creator-studio',
                builder: (context, state) => const CreatorStudioScreen(),
              ),
              GoRoute(
                path: 'compose/:kind',
                builder: (context, state) => UserPostComposerScreen(
                  kind: state.pathParameters['kind'] ?? 'text',
                ),
              ),
            ],
          ),
          GoRoute(
            path: '/app/notifications',
            builder: (context, state) => const NotificationsScreen(),
          ),
          GoRoute(
            path: '/app/upgrade',
            builder: (context, state) => const UpgradeScreen(),
          ),
          GoRoute(
            path: '/app/profile',
            builder: (context, state) => const ProfileScreen(),
            routes: [
              GoRoute(
                path: 'settings',
                builder: (context, state) => const ProfileSettingsScreen(),
                routes: [
                  GoRoute(
                    path: 'account',
                    builder: (context, state) =>
                        const ProfileSettingsScreen(section: 'account'),
                  ),
                  GoRoute(
                    path: 'chat',
                    builder: (context, state) =>
                        const ProfileSettingsScreen(section: 'chat'),
                  ),
                  GoRoute(
                    path: 'learning',
                    builder: (context, state) =>
                        const ProfileSettingsScreen(section: 'learning'),
                  ),
                  GoRoute(
                    path: 'appearance',
                    builder: (context, state) =>
                        const ProfileSettingsScreen(section: 'appearance'),
                  ),
                  GoRoute(
                    path: 'about',
                    builder: (context, state) =>
                        const ProfileSettingsScreen(section: 'about'),
                  ),
                  GoRoute(
                    path: 'help',
                    builder: (context, state) =>
                        const ProfileSettingsScreen(section: 'help'),
                  ),
                ],
              ),
              GoRoute(
                path: 'diagnostics',
                builder: (context, state) => const DiagnosticsScreen(),
              ),
              GoRoute(
                path: 'qa-checklist',
                builder: (context, state) => const QaChecklistScreen(),
              ),
              GoRoute(
                path: 'media-preview',
                builder: (context, state) => const MediaPreviewScreen(),
              ),
              GoRoute(
                path: 'list/:listType',
                builder: (context, state) => FollowListScreen(
                  userId: state.uri.queryParameters['userId'] ?? '',
                  titleName: state.uri.queryParameters['name'],
                  type: (state.pathParameters['listType'] ?? '') == 'following'
                      ? FollowListType.following
                      : FollowListType.followers,
                ),
              ),
              GoRoute(
                path: ':userId',
                builder: (context, state) =>
                    ProfileScreen(userId: state.pathParameters['userId']),
                routes: [
                  GoRoute(
                    path: 'diagnostics',
                    builder: (context, state) => const DiagnosticsScreen(),
                  ),
                  GoRoute(
                    path: 'qa-checklist',
                    builder: (context, state) => const QaChecklistScreen(),
                  ),
                  GoRoute(
                    path: 'media-preview',
                    builder: (context, state) => const MediaPreviewScreen(),
                  ),
                  GoRoute(
                    path: 'list/:listType',
                    builder: (context, state) => FollowListScreen(
                      userId: state.pathParameters['userId'] ?? '',
                      titleName: state.uri.queryParameters['name'],
                      type:
                          (state.pathParameters['listType'] ?? '') ==
                              'following'
                          ? FollowListType.following
                          : FollowListType.followers,
                    ),
                  ),
                ],
              ),
            ],
          ),
        ],
      ),
    ],
  );
});

class _LoadingScreen extends StatelessWidget {
  const _LoadingScreen();

  @override
  Widget build(BuildContext context) {
    return const Scaffold(body: Center(child: CircularProgressIndicator()));
  }
}
