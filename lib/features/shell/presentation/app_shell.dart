import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';
import 'package:just_audio/just_audio.dart';

import '../../../app/theme/app_theme.dart';
import '../../../core/network/api_client.dart';
import '../../../core/realtime/direct_call_controller.dart';
import '../../../core/realtime/socket_service.dart';
import '../../../core/auth/app_user.dart';
import '../../live/presentation/live_screen.dart';
import '../../talk/presentation/talk_inbox_screen.dart';

class AppShell extends ConsumerStatefulWidget {
  const AppShell({super.key, required this.child});

  final Widget child;

  @override
  ConsumerState<AppShell> createState() => _AppShellState();
}

class _AppShellState extends ConsumerState<AppShell> {
  final AudioPlayer _ringtonePlayer = AudioPlayer();

  @override
  void initState() {
    super.initState();
    unawaited(_configureRingtone());
    Future<void>.microtask(_bindGlobalCallHandlers);
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
    unawaited(_stopIncomingRingtone());
    _ringtonePlayer.dispose();
    super.dispose();
  }

  static const _tabs = <_ShellTab>[
    _ShellTab(
      location: '/app/talk',
      icon: Icons.chat_bubble_outline,
      label: 'Talk',
    ),
    _ShellTab(
      location: '/app/live',
      icon: Icons.mic_none_outlined,
      label: 'Live',
    ),
    _ShellTab(location: '/app/meet', icon: Icons.people_outline, label: 'Meet'),
    _ShellTab(
      location: '/app/content',
      icon: Icons.play_circle_outline,
      label: 'Content',
    ),
    _ShellTab(
      location: '/app/profile',
      icon: Icons.person_outline,
      label: 'Profile',
    ),
  ];

  void _bindGlobalCallHandlers() {
    final socket = ref.read(socketServiceProvider);
    socket.on('dm:call:request:global', _onGlobalCall);
    socket.on('dm:call:end', _clearForThread);
    socket.on('dm:call:cancel', _clearForThread);
    socket.on('dm:call:accept', _clearForThread);
    socket.on('dm:call:missed', _clearForThread);
    socket.on('dm:inbox-update', _handleInboxUpdate);
  }

  Future<void> _configureRingtone() async {
    try {
      await _ringtonePlayer.setAsset('assets/audio/anon-ringtone.wav');
      await _ringtonePlayer.setLoopMode(LoopMode.one);
    } catch (_) {}
  }

  Future<void> _playIncomingRingtone() async {
    try {
      await _ringtonePlayer.seek(Duration.zero);
      await _ringtonePlayer.play();
    } catch (_) {}
  }

  Future<void> _stopIncomingRingtone() async {
    try {
      await _ringtonePlayer.stop();
    } catch (_) {}
  }

  void _handleInboxUpdate(dynamic _) {
    ref.invalidate(recentThreadsProvider);
  }

  Future<void> _onGlobalCall(dynamic data) async {
    if (data is! Map || !mounted) return;
    final payload = Map<String, dynamic>.from(data);
    final threadId = payload['threadId']?.toString() ?? '';
    final fromUserId = payload['fromUserId']?.toString() ?? '';
    if (threadId.isEmpty || fromUserId.isEmpty) return;
    final location = GoRouterState.of(context).uri.toString();
    if (location.startsWith('/app/talk/$fromUserId')) return;

    AppUser? caller;
    try {
      final response = await ref
          .read(apiClientProvider)
          .getJson('/users/$fromUserId');
      final userJson = response['user'] as Map<String, dynamic>? ?? const {};
      caller = AppUser.fromJson(userJson);
    } catch (_) {}

    ref
        .read(directCallControllerProvider.notifier)
        .showIncoming(
          threadId: threadId,
          fromUserId: fromUserId,
          video: payload['video'] == true,
          caller: caller,
        );
    unawaited(_playIncomingRingtone());
  }

  void _clearForThread(dynamic data) {
    if (data is! Map) return;
    final threadId = data['threadId']?.toString();
    if (threadId == null || threadId.isEmpty) return;
    unawaited(_stopIncomingRingtone());
    ref
        .read(directCallControllerProvider.notifier)
        .clearIncomingForThread(threadId);
  }

  void _respondToIncomingCall(bool accept) {
    final incoming = ref.read(directCallControllerProvider).incoming;
    if (incoming == null) return;
    unawaited(_stopIncomingRingtone());
    final socket = ref.read(socketServiceProvider);
    unawaited(
      socket.emitWithAckFuture('dm:call:accept', <String, dynamic>{
        'threadId': incoming.threadId,
        'accept': accept,
      }, timeout: const Duration(seconds: 2)),
    );
    if (accept) {
      ref.read(directCallControllerProvider.notifier).acceptIncoming();
      context.go('/app/talk/${incoming.fromUserId}');
      return;
    }
    ref.read(directCallControllerProvider.notifier).declineIncoming();
  }

  @override
  Widget build(BuildContext context) {
    final incomingCall = ref.watch(directCallControllerProvider).incoming;
    final recentThreads = ref.watch(recentThreadsProvider);
    final liveAudioRoomActive = ref.watch(liveAudioRoomActiveProvider);
    final location = GoRouterState.of(context).uri.toString();
    final selectedIndex = _tabs.indexWhere(
      (tab) => location.startsWith(tab.location),
    );
    final unreadTalkCount = recentThreads.maybeWhen(
      data: (threads) =>
          threads.fold<int>(0, (total, thread) => total + thread.unreadCount),
      orElse: () => 0,
    );
    final hideBottomNav =
        location.startsWith('/app/meet/anon') ||
        (location.startsWith('/app/talk/') && location != '/app/talk') ||
        location.startsWith('/app/profile/') ||
        (location.startsWith('/app/live') && liveAudioRoomActive);

    return Scaffold(
      body: Stack(
        children: [
          widget.child,
          if (incomingCall != null)
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
                                  ? 'Incoming video call'
                                  : 'Incoming call',
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
                              incomingCall.caller?.displayName ?? 'Someone',
                              style: Theme.of(context).textTheme.titleLarge,
                            ),
                            const SizedBox(height: 16),
                            Row(
                              children: [
                                Expanded(
                                  child: OutlinedButton(
                                    onPressed: () =>
                                        _respondToIncomingCall(false),
                                    child: const Text('Decline'),
                                  ),
                                ),
                                const SizedBox(width: 12),
                                Expanded(
                                  child: FilledButton(
                                    onPressed: () =>
                                        _respondToIncomingCall(true),
                                    child: const Text('Accept'),
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
      bottomNavigationBar: hideBottomNav
          ? null
          : NavigationBar(
              selectedIndex: selectedIndex < 0 ? 0 : selectedIndex,
              onDestinationSelected: (index) {
                context.go(_tabs[index].location);
              },
              destinations: _tabs
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
