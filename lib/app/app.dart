import 'dart:async';
import 'dart:io' show Platform;

import 'package:flutter/foundation.dart' show kIsWeb;
import 'package:flutter/material.dart';
import 'package:flutter_localizations/flutter_localizations.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import 'localization/app_language_controller.dart';
import 'localization/talkflix_localizations.dart';
import '../core/auth/session_controller.dart';
import '../core/auth/session_state.dart';
import '../core/config/app_config.dart';
import '../core/realtime/dm_callkit_bridge.dart';
import '../core/realtime/direct_call_controller.dart';
import '../core/realtime/direct_call_push_service.dart';
import '../core/realtime/direct_call_readiness_controller.dart';
import '../core/realtime/direct_call_registration_controller.dart';
import '../core/realtime/general_notification_push_service.dart';
import '../core/realtime/socket_service.dart';
import '../features/live/application/live_room_session_controller.dart';
import '../features/live/data/live_audio_service.dart';
import '../features/live/presentation/live_screen.dart';
import '../features/meet/presentation/meet_filters_controller.dart';
import '../features/meet/presentation/meet_results_screen.dart';
import '../features/meet/presentation/meet_screen.dart';
import '../features/notifications/application/notification_preferences_controller.dart';
import '../features/notifications/presentation/notifications_controller.dart';
import '../features/profile/application/profile_cover_controller.dart';
import '../features/profile/presentation/profile_screen.dart';
import '../features/splash/presentation/splash_screen.dart';
import '../features/talk/presentation/talk_inbox_screen.dart';
import '../features/upgrade/presentation/pro_purchase_controller.dart';
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
    ref.invalidate(profileBaseProvider);
    ref.invalidate(profileProvider);
    ref.invalidate(profileCoverOverridesProvider);
    ref.invalidate(notificationsControllerProvider);
    ref.invalidate(directCallServerReadinessProvider);

    ref.read(unreadNotificationCountProvider.notifier).state = 0;
    ref.read(meetFeedLanguageProvider.notifier).state = 'Any';
    ref.read(liveAudioRoomActiveProvider.notifier).state = false;
    ref.read(liveBrowseTypeProvider.notifier).state = 'audio';
    ref.read(liveBroadcastCacheProvider.notifier).state = const [];
    ref.invalidate(liveRoomSessionProvider);
    unawaited(ref.read(liveAudioServiceProvider).disconnect());
    if (AppConfig.directCallsEnabled) {
      ref.read(directCallControllerProvider.notifier).reset();
      unawaited(ref.read(dmCallKitBridgeProvider).onSessionReset());
    }
  }

  void _maybeSyncDirectCallDeviceRegistration(WidgetRef ref) {
    if (!AppConfig.directCallsEnabled || kIsWeb) return;
    ref.invalidate(directCallServerReadinessProvider);
    unawaited(
      ref
          .read(directCallRegistrationControllerProvider.notifier)
          .sync(force: true),
    );
  }

  void _maybeSyncGeneralNotificationDeviceRegistration(WidgetRef ref) {
    if (kIsWeb) return;
    unawaited(
      ref
          .read(generalNotificationPushServiceProvider)
          .syncDeviceRegistration(force: true),
    );
  }

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    ref.listen<SessionState>(sessionControllerProvider, (previous, next) {
      final previousUserId = previous?.user?.id ?? '';
      final nextUserId = next.user?.id ?? '';
      final previousToken = previous?.token ?? '';
      final nextToken = next.token ?? '';
      final previousSessionId = previous?.sessionId ?? '';
      final nextSessionId = next.sessionId ?? '';
      final sessionIdentityChanged =
          previousUserId != nextUserId ||
          previousSessionId != nextSessionId ||
          previousToken != nextToken ||
          previous?.isAuthenticated != next.isAuthenticated;

      if (sessionIdentityChanged) {
        _resetSessionScopedState(ref);
      }

      final liveSocket = ref.read(socketServiceProvider);
      if (next.isAuthenticated &&
          next.token != null &&
          next.user != null &&
          next.sessionId != null &&
          next.sessionId!.isNotEmpty) {
        liveSocket.connect(
          next.token!,
          expectedUserId: next.user!.id,
          expectedSessionId: next.sessionId!,
        );
        if (sessionIdentityChanged) {
          _maybeSyncDirectCallDeviceRegistration(ref);
          _maybeSyncGeneralNotificationDeviceRegistration(ref);
        }
      } else {
        if (!liveSocket.isGuestPreviewMode) {
          liveSocket.disconnect();
        }
      }
    });

    final router = ref.watch(appRouterProvider);
    final themeMode = ref.watch(themeModeControllerProvider);
    final locale = ref.watch(appLocaleProvider);
    final session = ref.watch(sessionControllerProvider);

    if (session.isAuthenticated) {
      ref.watch(notificationPreferencesControllerProvider);
      ref.watch(notificationsControllerProvider);
      if (AppConfig.paidUpgradeEnabled &&
          !kIsWeb &&
          (Platform.isIOS || Platform.isAndroid)) {
        ref.watch(proPurchaseControllerProvider);
      }
    }

    if (AppConfig.directCallsEnabled &&
        !kIsWeb &&
        (Platform.isIOS || Platform.isAndroid)) {
      ref.watch(dmCallKitBridgeProvider);
      ref.watch(directCallRegistrationControllerProvider);
      ref.watch(directCallReadinessProvider);
      ref.watch(generalNotificationPushServiceProvider);
      if (Platform.isAndroid) {
        ref.watch(directCallPushServiceProvider);
      }
    }

    return MaterialApp.router(
      debugShowCheckedModeBanner: false,
      title: 'Talkflix',
      theme: buildTalkflixLightTheme(),
      darkTheme: buildTalkflixDarkTheme(),
      themeMode: themeMode,
      locale: locale,
      supportedLocales: supportedAppLocales,
      localeResolutionCallback: resolveTalkflixLocale,
      localizationsDelegates: const [
        TalkflixLocalizations.delegate,
        ...GlobalMaterialLocalizations.delegates,
      ],
      builder: (context, child) => _AndroidIncomingCallPermissionGate(
        child: _DirectCallRegistrationGate(
          child: kIsWeb
              ? child ?? const SizedBox.shrink()
              : TalkflixSplashGate(child: child ?? const SizedBox.shrink()),
        ),
      ),
      routerConfig: router,
    );
  }
}

class _DirectCallRegistrationGate extends ConsumerStatefulWidget {
  const _DirectCallRegistrationGate({required this.child});

  final Widget child;

  @override
  ConsumerState<_DirectCallRegistrationGate> createState() =>
      _DirectCallRegistrationGateState();
}

class _DirectCallRegistrationGateState
    extends ConsumerState<_DirectCallRegistrationGate>
    with WidgetsBindingObserver {
  ProviderSubscription<SessionState>? _sessionSubscription;

  @override
  void initState() {
    super.initState();
    if (!AppConfig.directCallsEnabled) return;
    WidgetsBinding.instance.addObserver(this);
    _sessionSubscription = ref.listenManual<SessionState>(
      sessionControllerProvider,
      (previous, next) {
        if (!next.isAuthenticated || next.user == null) return;
        ref.invalidate(directCallServerReadinessProvider);
        unawaited(
          ref
              .read(directCallRegistrationControllerProvider.notifier)
              .sync(force: true),
        );
      },
      fireImmediately: true,
    );
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (!AppConfig.directCallsEnabled) return;
    if (state != AppLifecycleState.resumed) return;
    final session = ref.read(sessionControllerProvider);
    if (!session.isAuthenticated || session.user == null) return;
    ref.invalidate(directCallServerReadinessProvider);
    unawaited(
      ref.read(directCallRegistrationControllerProvider.notifier).sync(),
    );
  }

  @override
  void dispose() {
    if (AppConfig.directCallsEnabled) {
      WidgetsBinding.instance.removeObserver(this);
    }
    _sessionSubscription?.close();
    _sessionSubscription = null;
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => widget.child;
}

class _AndroidIncomingCallPermissionGate extends ConsumerStatefulWidget {
  const _AndroidIncomingCallPermissionGate({required this.child});

  final Widget child;

  @override
  ConsumerState<_AndroidIncomingCallPermissionGate> createState() =>
      _AndroidIncomingCallPermissionGateState();
}

class _AndroidIncomingCallPermissionGateState
    extends ConsumerState<_AndroidIncomingCallPermissionGate> {
  static const String _educationSeenKey =
      'android_incoming_call_permission_education_seen_v1';

  bool _checking = false;
  ProviderSubscription<SessionState>? _sessionSubscription;

  @override
  void initState() {
    super.initState();
    if (!AppConfig.directCallsEnabled) return;
    _sessionSubscription = ref.listenManual<SessionState>(
      sessionControllerProvider,
      (previous, next) {
        if (!next.isAuthenticated || next.user == null) return;
        unawaited(_maybeShowPermissionEducation());
      },
      fireImmediately: true,
    );
  }

  @override
  void dispose() {
    _sessionSubscription?.close();
    _sessionSubscription = null;
    super.dispose();
  }

  Future<void> _maybeShowPermissionEducation() async {
    if (!AppConfig.directCallsEnabled) return;
    if (_checking || kIsWeb || !Platform.isAndroid || !mounted) return;
    final session = ref.read(sessionControllerProvider);
    if (!session.isAuthenticated || session.user == null) return;
    _checking = true;
    try {
      final prefs = await ref.read(sharedPreferencesProvider.future);
      final alreadySeen = prefs.getBool(_educationSeenKey) ?? false;
      if (alreadySeen || !mounted) return;
      final shouldContinue = await showDialog<bool>(
        context: context,
        barrierDismissible: true,
        builder: (context) {
          final l10n = context.l10n;
          return AlertDialog(
            title: Text(l10n.incomingCallSetup),
            content: Text(l10n.incomingCallSetupBody),
            actions: [
              TextButton(
                onPressed: () => Navigator.of(context).pop(false),
                child: Text(l10n.notNow),
              ),
              FilledButton(
                onPressed: () => Navigator.of(context).pop(true),
                child: Text(l10n.continueAction),
              ),
            ],
          );
        },
      );
      await prefs.setBool(_educationSeenKey, true);
      if (shouldContinue == true) {
        await DmCallKitBridge.prepareAndroidIncomingCallPermissions();
      }
    } finally {
      _checking = false;
    }
  }

  @override
  Widget build(BuildContext context) => widget.child;
}
