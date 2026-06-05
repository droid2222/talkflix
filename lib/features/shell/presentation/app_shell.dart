import 'dart:async';
import 'dart:math' as math;

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../../../app/localization/talkflix_localizations.dart';
import '../../../app/theme/app_theme.dart';
import '../../../core/auth/app_user.dart';
import '../../../core/config/app_config.dart';
import '../../../core/config/talkflix_icons.dart';
import '../../../core/media/dm_incoming_ringtone.dart';
import '../../../core/realtime/dm_callkit_bridge.dart';
import '../../../core/realtime/direct_call_controller.dart';
import '../../../core/realtime/socket_service.dart';
import '../../content/data/content_repository.dart';
import '../../live/application/live_room_session_controller.dart';
import '../../live/data/live_audio_service.dart';
import '../../live/presentation/live_screen.dart';
import '../../talk/data/direct_chat_repository.dart';
import '../../talk/presentation/talk_inbox_screen.dart';

class AppShell extends ConsumerStatefulWidget {
  const AppShell({super.key, required this.child});

  final Widget child;

  @override
  ConsumerState<AppShell> createState() => _AppShellState();
}

class _AppShellState extends ConsumerState<AppShell> {
  Offset? _minimizedLiveRoomOffset;
  ProviderSubscription<DirectCallState>? _directCallStateSubscription;

  @override
  void initState() {
    super.initState();
    Future<void>.microtask(_bindGlobalCallHandlers);
    if (AppConfig.directCallsEnabled) {
      _directCallStateSubscription = ref.listenManual<DirectCallState>(
        directCallControllerProvider,
        _handleDirectCallStateChanged,
      );
    }
  }

  @override
  void dispose() {
    final socket = ref.read(socketServiceProvider);
    socket.off('dm:call:request:global', _onGlobalCall);
    socket.off('dm:call:end', _clearForThread);
    socket.off('dm:call:cancel', _clearForThread);
    socket.off('dm:call:accept', _clearForThread);
    socket.off('dm:call:missed', _clearForThread);
    socket.off('dm:inbox-update', _handleInboxUpdate);
    socket.off('live:broadcast:ended', _handleLiveBroadcastEnded);
    _directCallStateSubscription?.close();
    unawaited(_stopIncomingRingtone());
    super.dispose();
  }

  void _bindGlobalCallHandlers() {
    final socket = ref.read(socketServiceProvider);
    socket.on('dm:inbox-update', _handleInboxUpdate);
    socket.on('live:broadcast:ended', _handleLiveBroadcastEnded);
    if (!AppConfig.directCallsEnabled) return;
    socket.on('dm:call:request:global', _onGlobalCall);
    socket.on('dm:call:end', _clearForThread);
    socket.on('dm:call:cancel', _clearForThread);
    socket.on('dm:call:accept', _clearForThread);
    socket.on('dm:call:missed', _clearForThread);
  }

  Future<void> _stopIncomingRingtone() async {
    await DmIncomingRingtone.stop();
  }

  void _handleInboxUpdate(dynamic _) {
    if (!mounted) return;
    ref.invalidate(recentThreadsProvider);
  }

  Future<void> _onGlobalCall(dynamic data) async {
    if (!AppConfig.directCallsEnabled) return;
    if (data is! Map || !mounted) return;
    final payload = Map<String, dynamic>.from(data);
    final threadId = payload['threadId']?.toString() ?? '';
    final fromUserId = payload['fromUserId']?.toString() ?? '';
    final callId = payload['callId']?.toString() ?? '';
    if (threadId.isEmpty || fromUserId.isEmpty) return;
    final video = payload['video'] == true;
    final location = GoRouterState.of(context).uri.toString();
    final alreadyOnThread = location.startsWith('/app/talk/$fromUserId');
    final thread = ref
        .read(recentThreadsProvider)
        .maybeWhen(
          data: (threads) {
            for (final thread in threads) {
              if (thread.partnerId == fromUserId) return thread;
            }
            return null;
          },
          orElse: () => null,
        );
    final callerName = thread?.displayName.trim() ?? '';
    final avatarUrl = thread?.profilePhotoUrl.trim() ?? '';
    final caller = callerName.isEmpty && avatarUrl.isEmpty
        ? null
        : AppUser(
            id: fromUserId,
            email: '',
            displayName: callerName.isEmpty ? 'Talkflix' : callerName,
            username: '',
            firstLanguage: '',
            learnLanguage: '',
            role: 'user',
            plan: 'free',
            trialUsed: false,
            meetLanguages: const [],
            city: '',
            country: '',
            countryCode: '',
            nationalityCode: '',
            nationalityName: '',
            profilePhotoUrl: avatarUrl,
            bioText: '',
            bioAudioUrl: '',
            bioAudioDuration: 0,
            followersCount: 0,
            followingCount: 0,
            postsCount: 0,
            isFollowing: false,
          );
    ref
        .read(directCallControllerProvider.notifier)
        .showIncoming(
          threadId: threadId,
          fromUserId: fromUserId,
          callId: callId,
          video: video,
          caller: caller,
        );
    if (!alreadyOnThread) {
      await ref
          .read(directChatRepositoryProvider)
          .appendCachedLocalCallEvent(
            userId: fromUserId,
            threadId: threadId,
            callId: callId,
            eventKey: 'incoming',
            text: video ? 'Incoming video call' : 'Incoming voice call',
          );
    }
    if (DmCallKitBridge.enabled) {
      await ref
          .read(dmCallKitBridgeProvider)
          .showIncomingDmCall(
            callId: callId,
            threadId: threadId,
            fromUserId: fromUserId,
            video: video,
            callerName: caller?.displayName ?? 'Talkflix',
            avatarUrl: avatarUrl.isEmpty ? null : avatarUrl,
          );
    }
  }

  void _clearForThread(dynamic data) {
    if (!AppConfig.directCallsEnabled) return;
    if (data is! Map || !mounted) return;
    final threadId = data['threadId']?.toString();
    if (threadId == null || threadId.isEmpty) return;
    unawaited(_stopIncomingRingtone());
    unawaited(ref.read(dmCallKitBridgeProvider).endCallForThread(threadId));
    ref
        .read(directCallControllerProvider.notifier)
        .clearCallForThread(threadId);
  }

  void _handleDirectCallStateChanged(
    DirectCallState? previous,
    DirectCallState next,
  ) {
    if (!AppConfig.directCallsEnabled) return;
    final pending = next.pendingAccepted;
    if (pending == null || !mounted) return;
    final previousPending = previous?.pendingAccepted;
    final isSamePending =
        previousPending != null &&
        previousPending.threadId == pending.threadId &&
        previousPending.partnerId == pending.partnerId &&
        previousPending.callId == pending.callId;
    if (isSamePending) return;
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted) return;
      final location = GoRouterState.of(context).uri.toString();
      final target = '/app/talk/${pending.partnerId}';
      if (location == target) return;
      context.go(target);
    });
  }

  void _handleLiveBroadcastEnded(dynamic data) {
    if (data is! Map || !mounted) return;
    final endedBroadcastId = data['broadcastId']?.toString() ?? '';
    final session = ref.read(liveRoomSessionProvider);
    if (endedBroadcastId.isEmpty || endedBroadcastId != session.roomId) {
      return;
    }
    ref.read(liveRoomSessionProvider.notifier).clear();
    unawaited(ref.read(liveAudioServiceProvider).disconnect());
  }

  void _respondToIncomingCall(bool accept) {
    if (!AppConfig.directCallsEnabled) return;
    final incoming = ref.read(directCallControllerProvider).incoming;
    if (incoming == null) return;
    unawaited(_stopIncomingRingtone());
    if (accept) {
      unawaited(
        ref
            .read(dmCallKitBridgeProvider)
            .dismissIncomingUiForAcceptedCall(
              threadId: incoming.threadId,
              callId: incoming.callId,
            ),
      );
      ref.read(directCallControllerProvider.notifier).acceptIncoming();
      return;
    }
    final socket = ref.read(socketServiceProvider);
    unawaited(
      socket.emitWithAckFuture('dm:call:accept', <String, dynamic>{
        'threadId': incoming.threadId,
        'callId': incoming.callId,
        'accept': false,
      }, timeout: const Duration(seconds: 2)),
    );
    ref
        .read(directCallControllerProvider.notifier)
        .clearCallForThread(incoming.threadId);
  }

  void _resumeMinimizedLiveRoom() {
    ref.read(liveRoomSessionProvider.notifier).setMinimized(false);
    context.go('/app/live');
  }

  Offset _defaultMinimizedLiveRoomOffset({
    required Size viewport,
    required EdgeInsets padding,
    required bool hideBottomNav,
  }) {
    final left = (viewport.width - _MinimizedLiveRoomBox.boxSize.width) / 2;
    final top =
        viewport.height -
        padding.bottom -
        (hideBottomNav ? 22 : 76) -
        _MinimizedLiveRoomBox.boxSize.height;
    return _clampMinimizedLiveRoomOffset(
      Offset(left, top),
      viewport: viewport,
      padding: padding,
      hideBottomNav: hideBottomNav,
    );
  }

  Offset _clampMinimizedLiveRoomOffset(
    Offset raw, {
    required Size viewport,
    required EdgeInsets padding,
    required bool hideBottomNav,
  }) {
    const horizontalMargin = 12.0;
    const topMargin = 12.0;
    final bottomClearance = hideBottomNav ? 12.0 : 72.0;
    final maxX = math.max(
      horizontalMargin,
      viewport.width - _MinimizedLiveRoomBox.boxSize.width - horizontalMargin,
    );
    final maxY = math.max(
      padding.top + topMargin,
      viewport.height -
          padding.bottom -
          _MinimizedLiveRoomBox.boxSize.height -
          bottomClearance,
    );
    return Offset(
      raw.dx.clamp(horizontalMargin, maxX),
      raw.dy.clamp(padding.top + topMargin, maxY),
    );
  }

  void _updateMinimizedLiveRoomOffset(
    Offset raw, {
    required Size viewport,
    required EdgeInsets padding,
    required bool hideBottomNav,
  }) {
    final clamped = _clampMinimizedLiveRoomOffset(
      raw,
      viewport: viewport,
      padding: padding,
      hideBottomNav: hideBottomNav,
    );
    setState(() {
      _minimizedLiveRoomOffset = clamped;
    });
  }

  @override
  Widget build(BuildContext context) {
    final l10n = context.l10n;
    final incomingCall = AppConfig.directCallsEnabled
        ? ref.watch(directCallControllerProvider).incoming
        : null;
    final recentThreads = ref.watch(recentThreadsProvider);
    final liveBroadcastRoomActive = ref.watch(liveAudioRoomActiveProvider);
    final contentCommentsOpen = ref.watch(contentCommentsActiveProvider);
    final liveRoomSession = ref.watch(liveRoomSessionProvider);
    final location = GoRouterState.of(context).uri.toString();
    final tabs = <_ShellTab>[
      _ShellTab(
        location: '/app/content',
        icon: Icons.play_circle_outline,
        label: l10n.contentTab,
      ),
      _ShellTab(
        location: '/app/live',
        icon: Icons.mic_none_outlined,
        label: l10n.liveTab,
      ),
      _ShellTab(
        location: '/app/meet',
        icon: Icons.people_outline,
        label: l10n.meetTab,
      ),
      _ShellTab(
        location: '/app/talk',
        icon: TalkflixIcons.talks,
        label: l10n.talkTab,
      ),
    ];
    final selectedIndex = tabs.indexWhere(
      (tab) => location.startsWith(tab.location),
    );
    final unreadTalkCount = recentThreads.maybeWhen(
      data: (threads) =>
          threads.fold<int>(0, (total, thread) => total + thread.unreadCount),
      orElse: () => 0,
    );
    final hideBottomNav =
        location.startsWith('/app/meet/anon') ||
        location.startsWith('/app/meet/filters') ||
        (location.startsWith('/app/talk/') && location != '/app/talk') ||
        location.startsWith('/app/profile') ||
        (location.startsWith('/app/live') && liveBroadcastRoomActive) ||
        contentCommentsOpen;
    final hideDesktopChrome =
        location.startsWith('/app/meet/anon') ||
        (location.startsWith('/app/live') && liveBroadcastRoomActive) ||
        contentCommentsOpen;
    final showMinimizedLiveRoom =
        liveRoomSession.minimized &&
        liveRoomSession.hasActiveRoom &&
        liveRoomSession.isAudioRoom &&
        !location.startsWith('/app/live');

    // Use MediaQuery instead of LayoutBuilder so provider-driven conditional
    // children are resolved during build, never during layout. A LayoutBuilder
    // re-runs its builder during performLayout; if watched providers changed
    // between build and layout phases, the builder produces a different Stack
    // child count, causing markNeedsLayout on a RenderStack mid-layout → crash.
    final viewport = MediaQuery.sizeOf(context);
    final padding = MediaQuery.paddingOf(context);
    final useDesktopChrome = viewport.width >= 720 && !hideDesktopChrome;
    final minimizedOffset = _clampMinimizedLiveRoomOffset(
      _minimizedLiveRoomOffset ??
          _defaultMinimizedLiveRoomOffset(
            viewport: viewport,
            padding: padding,
            hideBottomNav: hideBottomNav && !useDesktopChrome,
          ),
      viewport: viewport,
      padding: padding,
      hideBottomNav: hideBottomNav && !useDesktopChrome,
    );

    return Scaffold(
      body: Stack(
        children: [
          _ShellBodyFrame(
            useDesktopChrome: useDesktopChrome,
            extendedNavigation: viewport.width >= 1120,
            tabs: tabs,
            selectedIndex: selectedIndex < 0 ? 0 : selectedIndex,
            unreadTalkCount: unreadTalkCount,
            onDestinationSelected: (index) {
              context.go(tabs[index].location);
            },
            child: widget.child,
          ),
          if (showMinimizedLiveRoom)
            Positioned(
              left: minimizedOffset.dx,
              top: minimizedOffset.dy,
              child: _MinimizedLiveRoomBox(
                hostPhotoUrl: liveRoomSession.hostPhotoUrl,
                title: liveRoomSession.title,
                onTap: _resumeMinimizedLiveRoom,
                onDragUpdate: (delta) {
                  _updateMinimizedLiveRoomOffset(
                    minimizedOffset + delta,
                    viewport: viewport,
                    padding: padding,
                    hideBottomNav: hideBottomNav,
                  );
                },
              ),
            ),
          if (incomingCall != null && !DmCallKitBridge.enabled)
            Positioned.fill(
              child: ColoredBox(
                color: Colors.black.withValues(alpha: 0.48),
                child: Center(
                  child: ConstrainedBox(
                    constraints: const BoxConstraints(maxWidth: 320),
                    child: Card(
                      child: Padding(
                        padding: const EdgeInsets.all(20),
                        child: Column(
                          mainAxisSize: MainAxisSize.min,
                          children: [
                            Text(
                              incomingCall.video
                                  ? l10n.incomingVideoCall
                                  : l10n.incomingCall,
                              style: Theme.of(context).textTheme.titleMedium,
                            ),
                            const SizedBox(height: 12),
                            CircleAvatar(
                              radius: 28,
                              child: Text(
                                (incomingCall.caller?.displayName ?? 'U')
                                    .trim()
                                    .characters
                                    .first
                                    .toUpperCase(),
                              ),
                            ),
                            const SizedBox(height: 12),
                            Text(
                              incomingCall.caller?.displayName ?? l10n.someone,
                              style: Theme.of(context).textTheme.titleLarge,
                            ),
                            const SizedBox(height: 16),
                            Row(
                              children: [
                                Expanded(
                                  child: OutlinedButton(
                                    onPressed: () =>
                                        _respondToIncomingCall(false),
                                    child: Text(l10n.decline),
                                  ),
                                ),
                                const SizedBox(width: 12),
                                Expanded(
                                  child: FilledButton(
                                    onPressed: () =>
                                        _respondToIncomingCall(true),
                                    child: Text(l10n.accept),
                                  ),
                                ),
                              ],
                            ),
                          ],
                        ),
                      ),
                    ),
                  ),
                ),
              ),
            ),
        ],
      ),
      bottomNavigationBar: hideBottomNav || useDesktopChrome
          ? null
          : NavigationBar(
              height: 64,
              selectedIndex: selectedIndex < 0 ? 0 : selectedIndex,
              onDestinationSelected: (index) {
                context.go(tabs[index].location);
              },
              destinations: tabs
                  .map(
                    (tab) => NavigationDestination(
                      icon: _ShellNavIcon(
                        icon: tab.icon,
                        badgeCount: tab.location == '/app/talk'
                            ? unreadTalkCount
                            : 0,
                      ),
                      label: tab.label,
                    ),
                  )
                  .toList(),
            ),
    );
  }
}

class _ShellNavIcon extends StatelessWidget {
  const _ShellNavIcon({required this.icon, required this.badgeCount});

  final IconData icon;
  final int badgeCount;

  @override
  Widget build(BuildContext context) {
    return Stack(
      clipBehavior: Clip.none,
      children: [
        Icon(icon),
        if (badgeCount > 0)
          Positioned(
            right: -8,
            top: -6,
            child: Container(
              constraints: const BoxConstraints(minWidth: 18, minHeight: 18),
              padding: const EdgeInsets.symmetric(horizontal: 5, vertical: 1),
              decoration: const BoxDecoration(
                color: talkflixPrimary,
                shape: BoxShape.circle,
              ),
              child: Center(
                child: Text(
                  badgeCount > 99 ? '99+' : '$badgeCount',
                  style: Theme.of(context).textTheme.labelSmall?.copyWith(
                    color: Colors.white,
                    fontWeight: FontWeight.w800,
                    fontSize: 10,
                  ),
                ),
              ),
            ),
          ),
      ],
    );
  }
}

class _ShellBodyFrame extends StatelessWidget {
  const _ShellBodyFrame({
    required this.useDesktopChrome,
    required this.extendedNavigation,
    required this.tabs,
    required this.selectedIndex,
    required this.unreadTalkCount,
    required this.onDestinationSelected,
    required this.child,
  });

  final bool useDesktopChrome;
  final bool extendedNavigation;
  final List<_ShellTab> tabs;
  final int selectedIndex;
  final int unreadTalkCount;
  final ValueChanged<int> onDestinationSelected;
  final Widget child;

  @override
  Widget build(BuildContext context) {
    if (!useDesktopChrome) return child;

    final scheme = Theme.of(context).colorScheme;
    final isDark = Theme.of(context).brightness == Brightness.dark;
    final background = isDark
        ? const Color(0xFF111113)
        : const Color(0xFFF5F5F7);
    final contentColor = isDark ? scheme.surface : Colors.white;

    return ColoredBox(
      color: background,
      child: SafeArea(
        child: Row(
          children: [
            _DesktopShellNavigation(
              tabs: tabs,
              selectedIndex: selectedIndex,
              unreadTalkCount: unreadTalkCount,
              extended: extendedNavigation,
              onDestinationSelected: onDestinationSelected,
            ),
            Expanded(
              child: Padding(
                padding: EdgeInsets.fromLTRB(
                  extendedNavigation ? 0 : 8,
                  12,
                  12,
                  12,
                ),
                child: DecoratedBox(
                  decoration: BoxDecoration(
                    color: contentColor,
                    borderRadius: BorderRadius.circular(28),
                    border: Border.all(color: scheme.outlineVariant),
                    boxShadow: [
                      BoxShadow(
                        color: Colors.black.withValues(
                          alpha: isDark ? 0.22 : 0.06,
                        ),
                        blurRadius: 28,
                        offset: const Offset(0, 18),
                      ),
                    ],
                  ),
                  child: ClipRRect(
                    borderRadius: BorderRadius.circular(27),
                    child: child,
                  ),
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }
}

class _DesktopShellNavigation extends StatelessWidget {
  const _DesktopShellNavigation({
    required this.tabs,
    required this.selectedIndex,
    required this.unreadTalkCount,
    required this.extended,
    required this.onDestinationSelected,
  });

  final List<_ShellTab> tabs;
  final int selectedIndex;
  final int unreadTalkCount;
  final bool extended;
  final ValueChanged<int> onDestinationSelected;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final width = extended ? 236.0 : 88.0;

    return SizedBox(
      width: width,
      child: Padding(
        padding: const EdgeInsets.fromLTRB(12, 12, 12, 12),
        child: Column(
          crossAxisAlignment: extended
              ? CrossAxisAlignment.stretch
              : CrossAxisAlignment.center,
          children: [
            _DesktopBrand(extended: extended),
            const SizedBox(height: 28),
            for (var index = 0; index < tabs.length; index++) ...[
              _DesktopNavItem(
                tab: tabs[index],
                selected: index == selectedIndex,
                extended: extended,
                badgeCount: tabs[index].location == '/app/talk'
                    ? unreadTalkCount
                    : 0,
                onTap: () => onDestinationSelected(index),
              ),
              const SizedBox(height: 8),
            ],
            const Spacer(),
            Container(
              width: extended ? double.infinity : 44,
              height: extended ? null : 44,
              padding: EdgeInsets.symmetric(
                horizontal: extended ? 14 : 0,
                vertical: extended ? 12 : 0,
              ),
              decoration: BoxDecoration(
                color: scheme.surfaceContainerHighest.withValues(alpha: 0.62),
                borderRadius: BorderRadius.circular(18),
                border: Border.all(color: scheme.outlineVariant),
              ),
              child: extended
                  ? Row(
                      children: [
                        const Icon(
                          Icons.verified_rounded,
                          color: talkflixPrimary,
                          size: 20,
                        ),
                        const SizedBox(width: 10),
                        Expanded(
                          child: Text(
                            'Talkflix',
                            maxLines: 1,
                            overflow: TextOverflow.ellipsis,
                            style: Theme.of(context).textTheme.labelLarge
                                ?.copyWith(fontWeight: FontWeight.w800),
                          ),
                        ),
                      ],
                    )
                  : const Icon(
                      Icons.verified_rounded,
                      color: talkflixPrimary,
                      size: 20,
                    ),
            ),
          ],
        ),
      ),
    );
  }
}

class _DesktopBrand extends StatelessWidget {
  const _DesktopBrand({required this.extended});

  final bool extended;

  @override
  Widget build(BuildContext context) {
    final mark = Container(
      width: 44,
      height: 44,
      decoration: BoxDecoration(
        color: Theme.of(context).colorScheme.surface,
        borderRadius: BorderRadius.circular(14),
        border: Border.all(color: Theme.of(context).colorScheme.outlineVariant),
      ),
      clipBehavior: Clip.antiAlias,
      child: Padding(
        padding: const EdgeInsets.all(6),
        child: Image.asset(
          'assets/images/talkflix_logo.png',
          fit: BoxFit.contain,
        ),
      ),
    );

    if (!extended) return Center(child: mark);

    return Row(
      children: [
        mark,
        const SizedBox(width: 12),
        Expanded(
          child: Text(
            'Talkflix',
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
            style: Theme.of(
              context,
            ).textTheme.titleLarge?.copyWith(fontWeight: FontWeight.w900),
          ),
        ),
      ],
    );
  }
}

class _DesktopNavItem extends StatelessWidget {
  const _DesktopNavItem({
    required this.tab,
    required this.selected,
    required this.extended,
    required this.badgeCount,
    required this.onTap,
  });

  final _ShellTab tab;
  final bool selected;
  final bool extended;
  final int badgeCount;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final foreground = selected ? Colors.white : scheme.onSurfaceVariant;
    final background = selected ? talkflixPrimary : Colors.transparent;
    final hoverColor = selected
        ? Colors.transparent
        : scheme.surfaceContainerHighest.withValues(alpha: 0.7);

    return Material(
      color: background,
      borderRadius: BorderRadius.circular(18),
      child: InkWell(
        borderRadius: BorderRadius.circular(18),
        hoverColor: hoverColor,
        onTap: onTap,
        child: SizedBox(
          height: 52,
          child: Padding(
            padding: EdgeInsets.symmetric(horizontal: extended ? 14 : 0),
            child: Row(
              mainAxisAlignment: extended
                  ? MainAxisAlignment.start
                  : MainAxisAlignment.center,
              children: [
                IconTheme(
                  data: IconThemeData(color: foreground),
                  child: _ShellNavIcon(icon: tab.icon, badgeCount: badgeCount),
                ),
                if (extended) ...[
                  const SizedBox(width: 12),
                  Expanded(
                    child: Text(
                      tab.label,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: Theme.of(context).textTheme.labelLarge?.copyWith(
                        color: foreground,
                        fontWeight: selected
                            ? FontWeight.w900
                            : FontWeight.w700,
                      ),
                    ),
                  ),
                ],
              ],
            ),
          ),
        ),
      ),
    );
  }
}

class _ShellTab {
  const _ShellTab({
    required this.location,
    required this.icon,
    required this.label,
  });

  final String location;
  final IconData icon;
  final String label;
}

class _MinimizedLiveRoomBox extends StatelessWidget {
  const _MinimizedLiveRoomBox({
    required this.hostPhotoUrl,
    required this.title,
    required this.onTap,
    required this.onDragUpdate,
  });

  static const boxSize = Size(108, 112);

  final String hostPhotoUrl;
  final String title;
  final VoidCallback onTap;
  final ValueChanged<Offset> onDragUpdate;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Material(
      color: Colors.transparent,
      child: GestureDetector(
        onPanUpdate: (details) => onDragUpdate(details.delta),
        child: InkWell(
          borderRadius: BorderRadius.circular(28),
          onTap: onTap,
          child: Ink(
            width: boxSize.width,
            padding: const EdgeInsets.fromLTRB(12, 12, 12, 10),
            decoration: BoxDecoration(
              color: const Color(0xCC101114),
              borderRadius: BorderRadius.circular(28),
              border: Border.all(color: Colors.white.withValues(alpha: 0.08)),
              boxShadow: const [
                BoxShadow(
                  color: Color(0x55000000),
                  blurRadius: 18,
                  offset: Offset(0, 8),
                ),
              ],
            ),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                Stack(
                  clipBehavior: Clip.none,
                  alignment: Alignment.center,
                  children: [
                    CircleAvatar(
                      radius: 28,
                      backgroundColor: Colors.white.withValues(alpha: 0.12),
                      backgroundImage: hostPhotoUrl.trim().isEmpty
                          ? null
                          : NetworkImage(hostPhotoUrl),
                      child: hostPhotoUrl.trim().isEmpty
                          ? const Icon(
                              Icons.graphic_eq_rounded,
                              color: Colors.white,
                              size: 24,
                            )
                          : null,
                    ),
                    Positioned(
                      right: -2,
                      bottom: -2,
                      child: Container(
                        width: 18,
                        height: 18,
                        decoration: BoxDecoration(
                          color: talkflixPrimary,
                          shape: BoxShape.circle,
                          border: Border.all(color: const Color(0xCC101114)),
                        ),
                        child: const Icon(
                          Icons.volume_up_rounded,
                          color: Colors.white,
                          size: 10,
                        ),
                      ),
                    ),
                  ],
                ),
                const SizedBox(height: 10),
                Text(
                  title,
                  maxLines: 2,
                  overflow: TextOverflow.ellipsis,
                  textAlign: TextAlign.center,
                  style: theme.textTheme.labelLarge?.copyWith(
                    color: Colors.white,
                    fontWeight: FontWeight.w700,
                    height: 1.15,
                  ),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}
