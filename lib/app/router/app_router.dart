import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../../core/auth/session_controller.dart';
import '../../core/config/app_config.dart';
import '../../features/auth/presentation/forgot_password_screen.dart';
import '../../features/auth/presentation/login_screen.dart';
import '../../features/auth/presentation/reset_password_screen.dart';
import '../../features/auth/presentation/signup_screen.dart';
import '../../features/content/presentation/content_screen.dart';
import '../../features/content/presentation/content_video_screen.dart';
import '../../features/content/presentation/creator_studio_screen.dart';
import '../../features/content/presentation/podcast_composer_screen.dart';
import '../../features/content/presentation/post_composer_screen.dart';
import '../../features/content/presentation/shared_content_link_screen.dart';
import '../../features/content/presentation/user_post_composer_screen.dart';
import '../../features/home/presentation/public_home_screen.dart';
import '../../features/legal/presentation/legal_policy_screen.dart';
import '../../features/live/presentation/live_screen.dart';
import '../../features/meet/presentation/meet_anon_screen.dart';
import '../../features/meet/presentation/meet_filters_screen.dart';
import '../../features/meet/presentation/meet_results_screen.dart';
import '../../features/meet/presentation/meet_screen.dart';
import '../../features/profile/presentation/diagnostics_screen.dart';
import '../../features/profile/presentation/edit_profile_screen.dart';
import '../../features/profile/presentation/media_preview_screen.dart';
import '../../features/profile/presentation/profile_qr_screen.dart';
import '../../features/profile/presentation/profile_screen.dart';
import '../../features/profile/presentation/profile_settings_screen.dart';
import '../../features/profile/presentation/qa_checklist_screen.dart';
import '../../features/profile/presentation/follow_list_screen.dart';
import '../../features/shell/presentation/app_shell.dart';
import '../../features/talk/presentation/direct_chat_screen.dart';
import '../../features/talk/presentation/direct_call_log_screen.dart';
import '../../features/talk/presentation/talk_inbox_screen.dart';
import '../../features/notifications/presentation/notifications_screen.dart';
import '../../features/upgrade/presentation/upgrade_screen.dart';

final _rootNavigatorKey = GlobalKey<NavigatorState>();
final _shellNavigatorKey = GlobalKey<NavigatorState>();

String? _encodedLoginRedirectTarget(String location) {
  final trimmed = location.trim();
  if (trimmed.isEmpty || trimmed == '/login') {
    return null;
  }
  return Uri.encodeComponent(trimmed);
}

final appRouterProvider = Provider<GoRouter>((ref) {
  final isLoading = ref.watch(
    sessionControllerProvider.select((session) => session.isLoading),
  );
  final isAuthenticated = ref.watch(
    sessionControllerProvider.select((session) => session.isAuthenticated),
  );

  return GoRouter(
    navigatorKey: _rootNavigatorKey,
    initialLocation: kIsWeb ? '/' : '/loading',
    redirect: (context, state) {
      final location = state.matchedLocation;
      final fullLocation = state.uri.toString();
      const publicLocations = <String>{
        '/login',
        '/signup',
        '/terms-of-service',
        '/privacy-policy',
        '/forgot-password',
        '/reset-password',
      };
      const authenticatedEntryLocations = <String>{
        '/login',
        '/signup',
        '/forgot-password',
        '/reset-password',
      };
      final isSharedContentRoute =
          location.startsWith('/s/') || location.startsWith('/w/');
      final isSharedLiveRoute =
          location == '/app/live' &&
          (state.uri.queryParameters['broadcastId']?.trim().isNotEmpty ??
              false);
      final isPublicHomeRoute = kIsWeb && location == '/';

      if (isLoading) {
        if (location == '/loading' ||
            isPublicHomeRoute ||
            publicLocations.contains(location) ||
            isSharedContentRoute ||
            isSharedLiveRoute) {
          return null;
        }
        return '/loading';
      }

      if (!isAuthenticated) {
        if (location == '/loading') {
          return kIsWeb ? '/' : '/login';
        }
        if (isPublicHomeRoute ||
            publicLocations.contains(location) ||
            isSharedContentRoute ||
            isSharedLiveRoute) {
          return null;
        }
        final encodedTarget = _encodedLoginRedirectTarget(fullLocation);
        if (encodedTarget == null) {
          return '/login';
        }
        return '/login?next=$encodedTarget';
      }

      if (location == '/') {
        return '/app/content';
      }

      if (location == '/loading' ||
          authenticatedEntryLocations.contains(location)) {
        final next = state.uri.queryParameters['next']?.trim() ?? '';
        if (next.isNotEmpty) {
          return Uri.decodeComponent(next);
        }
        return '/app/content';
      }

      if (!AppConfig.directCallsEnabled && location == '/app/talk/call-logs') {
        return '/app/talk';
      }

      return null;
    },
    routes: [
      GoRoute(path: '/', builder: (context, state) => const PublicHomeScreen()),
      GoRoute(
        path: '/terms-of-service',
        builder: (context, state) =>
            const LegalPolicyScreen(type: LegalPolicyType.terms),
      ),
      GoRoute(
        path: '/privacy-policy',
        builder: (context, state) =>
            const LegalPolicyScreen(type: LegalPolicyType.privacy),
      ),
      GoRoute(
        path: '/s/:token',
        builder: (context, state) =>
            SharedContentLinkScreen(token: state.pathParameters['token'] ?? ''),
      ),
      GoRoute(
        path: '/w/:token',
        builder: (context, state) => SharedContentLinkScreen(
          token: state.pathParameters['token'] ?? '',
          forceWebPreview: true,
        ),
      ),
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
                path: 'call-logs',
                builder: (context, state) => const DirectCallLogScreen(),
              ),
              GoRoute(
                path: ':userId',
                builder: (context, state) => DirectChatScreen(
                  userId: state.pathParameters['userId'] ?? '',
                  initialCallMode: state.uri.queryParameters['call'],
                ),
              ),
            ],
          ),
          GoRoute(
            path: '/app/live',
            builder: (context, state) => LiveScreen(
              initialBroadcastId: state.uri.queryParameters['broadcastId']
                  ?.trim(),
            ),
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
                  transitionsBuilder:
                      (context, animation, secondaryAnimation, child) {
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
                path: 'videos/:id',
                builder: (context, state) => ContentVideoScreen(
                  videoId: state.pathParameters['id'] ?? '',
                ),
              ),
              GoRoute(
                path: 'creator-studio',
                builder: (context, state) => const CreatorStudioScreen(),
              ),
              // New unified composer — receives canPublishVideo via GoRouter extra
              GoRoute(
                path: 'compose',
                builder: (context, state) =>
                    PostComposerScreen(canPublishVideo: state.extra == true),
              ),
              GoRoute(
                path: 'podcasts/compose',
                builder: (context, state) => const PodcastComposerScreen(),
              ),
              // Legacy route kept for backward compatibility
              GoRoute(
                path: 'compose/:kind',
                builder: (context, state) {
                  final kind = state.pathParameters['kind'] ?? 'text';
                  if (kind == 'audio' || kind == 'podcast') {
                    return const PodcastComposerScreen();
                  }
                  return UserPostComposerScreen(kind: kind);
                },
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
                path: 'edit',
                builder: (context, state) => const EditProfileScreen(),
              ),
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
                    path: 'privacy',
                    builder: (context, state) =>
                        const ProfileSettingsScreen(section: 'privacy'),
                  ),
                  GoRoute(
                    path: 'notifications',
                    builder: (context, state) =>
                        const ProfileSettingsScreen(section: 'notifications'),
                  ),
                  GoRoute(
                    path: 'chat',
                    builder: (context, state) =>
                        const ProfileSettingsScreen(section: 'chat'),
                  ),
                  GoRoute(
                    path: 'language',
                    builder: (context, state) =>
                        const ProfileSettingsScreen(section: 'language'),
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
              if (AppConfig.localQaToolsEnabled) ...[
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
              ],
              GoRoute(
                path: 'qr/:userId',
                builder: (context, state) => ProfileQrScreen(
                  userId: state.pathParameters['userId'] ?? '',
                ),
              ),
              GoRoute(
                path: 'qr-scan',
                builder: (context, state) => const ProfileQrScannerScreen(),
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
                builder: (context, state) => ProfileScreen(
                  userId: state.pathParameters['userId'],
                  previewMode: state.uri.queryParameters['preview'] == '1',
                ),
                routes: [
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
