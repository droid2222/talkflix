import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../../../app/theme/app_theme.dart';
import '../../../core/auth/session_controller.dart';
import '../../../core/realtime/socket_service.dart';
import '../../../core/widgets/app_avatar.dart';
import '../../../core/widgets/realtime_status_banner.dart';
import '../data/chat_thread.dart';
import '../data/talk_repository.dart';

final recentThreadsProvider = FutureProvider<List<ChatThread>>((ref) async {
  final userId = ref.watch(sessionControllerProvider.select((s) => s.user?.id));
  if (userId == null || userId.isEmpty) {
    return const <ChatThread>[];
  }
  return ref.read(talkRepositoryProvider).fetchRecentThreads();
});

class TalkInboxScreen extends ConsumerStatefulWidget {
  const TalkInboxScreen({super.key});

  @override
  ConsumerState<TalkInboxScreen> createState() => _TalkInboxScreenState();
}

class _TalkInboxScreenState extends ConsumerState<TalkInboxScreen> {
  final _searchController = TextEditingController();
  final Map<String, bool> _typingByThread = <String, bool>{};
  final Set<String> _joinedTypingRooms = <String>{};
  final Map<String, DateTime> _typingSeenAt = <String, DateTime>{};
  late final void Function(dynamic data) _typingHandler;
  late final void Function(dynamic data) _messageHandler;

  String _searchQuery = '';
  bool _notificationsMuted = false;
  bool _socketBound = false;

  static const _notificationPrefKey = 'talkflix_inbox_notifications_muted';

  @override
  void initState() {
    super.initState();
    _typingHandler = _handleTyping;
    _messageHandler = _handleMessage;
    _bindSocket();
    _searchController.addListener(_handleSearchChanged);
    Future<void>.microtask(_loadPrefs);
  }

  @override
  void dispose() {
    _unbindSocket();
    _leaveAllTypingRooms();
    _searchController.removeListener(_handleSearchChanged);
    _searchController.dispose();
    super.dispose();
  }

  void _bindSocket() {
    if (_socketBound) return;
    final socket = ref.read(socketServiceProvider);
    socket.off('dm:typing', _typingHandler);
    socket.off('dm:message', _messageHandler);
    socket.on('dm:typing', _typingHandler);
    socket.on('dm:message', _messageHandler);
    _socketBound = true;
  }

  void _unbindSocket() {
    if (!_socketBound) return;
    final socket = ref.read(socketServiceProvider);
    socket.off('dm:typing', _typingHandler);
    socket.off('dm:message', _messageHandler);
    _socketBound = false;
  }

  void _handleTyping(dynamic data) {
    if (data is! Map) return;
    final payload = Map<String, dynamic>.from(data);
    final threadId = payload['threadId']?.toString() ?? '';
    if (threadId.isEmpty || !_joinedTypingRooms.contains(threadId)) return;
    _setTypingState(threadId: threadId, typing: payload['typing'] == true);
  }

  void _handleMessage(dynamic data) {
    if (data is! Map) return;
    final payload = Map<String, dynamic>.from(data);
    final threadId = payload['threadId']?.toString() ?? '';
    if (threadId.isEmpty) return;
    if (_typingByThread.containsKey(threadId)) {
      _setTypingState(threadId: threadId, typing: false);
    }
  }

  void _setTypingState({required String threadId, required bool typing}) {
    if (!mounted) return;
    if (typing) {
      _typingSeenAt[threadId] = DateTime.now();
      setState(() => _typingByThread[threadId] = true);
      Future<void>.delayed(const Duration(milliseconds: 2600), () {
        if (!mounted) return;
        final seenAt = _typingSeenAt[threadId];
        if (seenAt == null) return;
        final elapsed = DateTime.now().difference(seenAt);
        if (elapsed >= const Duration(milliseconds: 2550)) {
          setState(() => _typingByThread.remove(threadId));
        }
      });
      return;
    }
    _typingSeenAt.remove(threadId);
    setState(() => _typingByThread.remove(threadId));
  }

  void _syncTypingRooms(List<ChatThread> threads) {
    final socket = ref.read(socketServiceProvider);
    final threadIds = threads
        .map((thread) => thread.threadId)
        .where((threadId) => threadId.isNotEmpty)
        .toSet();

    final toJoin = threadIds.difference(_joinedTypingRooms);
    for (final threadId in toJoin) {
      socket.emit('dm:join', <String, dynamic>{'threadId': threadId});
      _joinedTypingRooms.add(threadId);
    }

    final toLeave = _joinedTypingRooms.difference(threadIds).toList();
    for (final threadId in toLeave) {
      socket.emit('dm:leave', <String, dynamic>{'threadId': threadId});
      _joinedTypingRooms.remove(threadId);
      _typingSeenAt.remove(threadId);
      _typingByThread.remove(threadId);
    }
  }

  void _leaveAllTypingRooms() {
    final socket = ref.read(socketServiceProvider);
    for (final threadId in _joinedTypingRooms.toList()) {
      socket.emit('dm:leave', <String, dynamic>{'threadId': threadId});
      _joinedTypingRooms.remove(threadId);
    }
    _typingSeenAt.clear();
    _typingByThread.clear();
  }

  Future<void> _loadPrefs() async {
    final prefs = await ref.read(sharedPreferencesProvider.future);
    if (!mounted) return;
    setState(() {
      _notificationsMuted = prefs.getBool(_notificationPrefKey) ?? false;
    });
  }

  void _handleSearchChanged() {
    if (!mounted) return;
    setState(() {
      _searchQuery = _searchController.text.trim().toLowerCase();
    });
  }

  Future<void> _toggleNotifications() async {
    final next = !_notificationsMuted;
    final prefs = await ref.read(sharedPreferencesProvider.future);
    await prefs.setBool(_notificationPrefKey, next);
    if (!mounted) return;
    setState(() => _notificationsMuted = next);
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(
        content: Text(
          next ? 'Chat notifications muted.' : 'Chat notifications enabled.',
        ),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final threads = ref.watch(recentThreadsProvider);
    final scheme = Theme.of(context).colorScheme;
    final isDark = Theme.of(context).brightness == Brightness.dark;
    final searchFill = isDark
        ? const Color(0xFF232428)
        : const Color(0xFFF2F3F5);

    return Scaffold(
      backgroundColor: scheme.surface,
      body: SafeArea(
        bottom: false,
        child: Column(
          children: [
            const RealtimeStatusBanner(compactLabel: 'Chat service'),
            Padding(
              padding: const EdgeInsets.fromLTRB(16, 10, 16, 12),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    'Messages',
                    style: Theme.of(context).textTheme.headlineSmall?.copyWith(
                      fontWeight: FontWeight.w800,
                    ),
                  ),
                  const SizedBox(height: 12),
                  Row(
                    children: [
                      Expanded(
                        child: Container(
                          height: 44,
                          decoration: BoxDecoration(
                            color: searchFill,
                            borderRadius: BorderRadius.circular(14),
                          ),
                          child: TextField(
                            controller: _searchController,
                            decoration: InputDecoration(
                              hintText: 'Search chats',
                              prefixIcon: const Icon(Icons.search_rounded),
                              border: InputBorder.none,
                              contentPadding: const EdgeInsets.symmetric(
                                horizontal: 14,
                                vertical: 10,
                              ),
                              hintStyle: TextStyle(
                                color: scheme.onSurfaceVariant,
                              ),
                            ),
                          ),
                        ),
                      ),
                      const SizedBox(width: 10),
                      Material(
                        color: searchFill,
                        borderRadius: BorderRadius.circular(14),
                        child: InkWell(
                          borderRadius: BorderRadius.circular(14),
                          onTap: _toggleNotifications,
                          child: SizedBox(
                            width: 46,
                            height: 44,
                            child: Icon(
                              _notificationsMuted
                                  ? Icons.notifications_off_outlined
                                  : Icons.notifications_none_rounded,
                              color: _notificationsMuted
                                  ? talkflixPrimary
                                  : scheme.onSurface,
                            ),
                          ),
                        ),
                      ),
                    ],
                  ),
                ],
              ),
            ),
            Expanded(
              child: threads.when(
                data: (items) {
                  _syncTypingRooms(items);
                  final filteredItems = _searchQuery.isEmpty
                      ? items
                      : items.where((thread) {
                          final haystack = [
                            thread.displayName,
                            thread.username,
                            thread.lastMessageText,
                            thread.country,
                          ].join(' ').toLowerCase();
                          return haystack.contains(_searchQuery);
                        }).toList();
                  return RefreshIndicator(
                    onRefresh: () => ref.refresh(recentThreadsProvider.future),
                    child: filteredItems.isEmpty
                        ? ListView(
                            physics: const AlwaysScrollableScrollPhysics(),
                            padding: const EdgeInsets.fromLTRB(18, 72, 18, 18),
                            children: [
                              Center(
                                child: Text(
                                  items.isEmpty
                                      ? 'No recent chats yet.'
                                      : 'No chats match your search.',
                                  style: Theme.of(context).textTheme.bodyLarge
                                      ?.copyWith(
                                        color: scheme.onSurfaceVariant,
                                      ),
                                ),
                              ),
                            ],
                          )
                        : ListView.separated(
                            physics: const AlwaysScrollableScrollPhysics(),
                            padding: const EdgeInsets.fromLTRB(16, 4, 16, 24),
                            itemCount: filteredItems.length,
                            separatorBuilder: (_, _) => Divider(
                              color: scheme.outlineVariant,
                              height: 1,
                            ),
                            itemBuilder: (context, index) {
                              final thread = filteredItems[index];
                              return _InboxThreadTile(
                                thread: thread,
                                isTyping:
                                    _typingByThread[thread.threadId] ?? false,
                              );
                            },
                          ),
                  );
                },
                error: (error, stackTrace) => Padding(
                  padding: const EdgeInsets.all(16),
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(error.toString()),
                      const SizedBox(height: 12),
                      OutlinedButton(
                        onPressed: () => ref.refresh(recentThreadsProvider),
                        child: const Text('Retry'),
                      ),
                    ],
                  ),
                ),
                loading: () => const Center(child: CircularProgressIndicator()),
              ),
            ),
          ],
        ),
      ),
    );
  }
}

class _InboxThreadTile extends StatelessWidget {
  const _InboxThreadTile({required this.thread, required this.isTyping});

  final ChatThread thread;
  final bool isTyping;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return InkWell(
      onTap: () => context.go('/app/talk/${thread.partnerId}'),
      child: Padding(
        padding: const EdgeInsets.symmetric(vertical: 12),
        child: Row(
          children: [
            AppAvatar(
              label: thread.displayName,
              imageUrl: thread.profilePhotoUrl,
              radius: 26,
            ),
            const SizedBox(width: 12),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    thread.displayName,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: Theme.of(context).textTheme.titleMedium?.copyWith(
                      fontWeight: thread.unreadCount > 0
                          ? FontWeight.w900
                          : FontWeight.w700,
                    ),
                  ),
                  const SizedBox(height: 3),
                  Text(
                    isTyping
                        ? 'typing...'
                        : (thread.lastMessageText.isEmpty
                              ? 'Start chatting'
                              : thread.lastMessageText),
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: Theme.of(context).textTheme.bodyMedium?.copyWith(
                      color: isTyping
                          ? talkflixPrimary
                          : (thread.unreadCount > 0
                                ? scheme.onSurface
                                : scheme.onSurfaceVariant),
                      fontStyle: isTyping ? FontStyle.italic : FontStyle.normal,
                      fontWeight: isTyping
                          ? FontWeight.w600
                          : (thread.unreadCount > 0
                                ? FontWeight.w600
                                : FontWeight.w400),
                    ),
                  ),
                ],
              ),
            ),
            const SizedBox(width: 12),
            if (thread.unreadCount > 0)
              Container(
                padding: const EdgeInsets.symmetric(horizontal: 7, vertical: 3),
                decoration: BoxDecoration(
                  color: talkflixPrimary,
                  borderRadius: BorderRadius.circular(999),
                ),
                child: Text(
                  thread.unreadCount > 99 ? '99+' : '${thread.unreadCount}',
                  style: Theme.of(context).textTheme.labelSmall?.copyWith(
                    color: Colors.white,
                    fontWeight: FontWeight.w800,
                    fontSize: 11,
                  ),
                ),
              )
            else
              Icon(Icons.chevron_right_rounded, color: scheme.onSurfaceVariant),
          ],
        ),
      ),
    );
  }
}
