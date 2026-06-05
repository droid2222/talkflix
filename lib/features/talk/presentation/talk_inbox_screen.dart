import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../../../app/localization/talkflix_localizations.dart';
import '../../../app/theme/app_theme.dart';
import '../../../core/auth/session_controller.dart';
import '../../../core/config/app_config.dart';
import '../../../core/config/storage_keys.dart';
import '../../../core/config/talkflix_icons.dart';
import '../../../core/contacts/talkflix_contacts_actions.dart';
import '../../../core/realtime/socket_service.dart';
import '../../../core/widgets/app_avatar.dart';
import '../../../core/widgets/realtime_status_banner.dart';
import '../../notifications/presentation/notifications_controller.dart';
import '../data/chat_thread.dart';
import '../data/direct_chat_repository.dart';
import '../data/talk_repository.dart';
import 'chat_recipient_picker.dart';

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
  final Set<String> _pinnedThreadIds = <String>{};
  final Set<String> _deletedThreadIds = <String>{};
  final Set<String> _mutedPartnerIds = <String>{};
  late final void Function(dynamic data) _typingHandler;
  late final void Function(dynamic data) _messageHandler;

  // Stored during _bindSocket so dispose() can clean up without touching ref.
  SocketService? _socket;

  String _searchQuery = '';
  String _handledSharedText = '';
  bool _socketBound = false;
  bool _handlingSharedText = false;

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
    _socket = ref.read(socketServiceProvider);
    _socket!.off('dm:typing', _typingHandler);
    _socket!.off('dm:message', _messageHandler);
    _socket!.on('dm:typing', _typingHandler);
    _socket!.on('dm:message', _messageHandler);
    _socketBound = true;
  }

  void _unbindSocket() {
    if (!_socketBound) return;
    _socket?.off('dm:typing', _typingHandler);
    _socket?.off('dm:message', _messageHandler);
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
    final socket = _socket;
    if (socket == null) return;
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
      _pinnedThreadIds
        ..clear()
        ..addAll(
          prefs.getStringList(StorageKeys.talkPinnedThreadIds) ?? const [],
        );
      _deletedThreadIds
        ..clear()
        ..addAll(
          prefs.getStringList(StorageKeys.talkDeletedThreadIds) ?? const [],
        );
      _mutedPartnerIds
        ..clear()
        ..addAll(_readMutedPartnerIds(prefs));
    });
  }

  Set<String> _readMutedPartnerIds(SharedPreferences prefs) {
    return prefs
        .getKeys()
        .where(
          (key) =>
              key.startsWith(StorageKeys.talkThreadMutedPrefix) &&
              prefs.getBool(key) == true,
        )
        .map((key) => key.substring(StorageKeys.talkThreadMutedPrefix.length))
        .where((partnerId) => partnerId.isNotEmpty)
        .toSet();
  }

  String _threadNotificationPrefKey(String partnerId) =>
      '${StorageKeys.talkThreadMutedPrefix}$partnerId';

  void _showSnack(String message) {
    if (!mounted) return;
    ScaffoldMessenger.of(
      context,
    ).showSnackBar(SnackBar(content: Text(message)));
  }

  List<ChatThread> _orderedVisibleThreads(List<ChatThread> threads) {
    final visible = threads
        .where((thread) => !_deletedThreadIds.contains(thread.threadId))
        .toList(growable: false);
    if (visible.isEmpty) return visible;
    final pinned = <ChatThread>[];
    final others = <ChatThread>[];
    for (final thread in visible) {
      if (_pinnedThreadIds.contains(thread.threadId)) {
        pinned.add(thread);
      } else {
        others.add(thread);
      }
    }
    return <ChatThread>[...pinned, ...others];
  }

  Future<void> _restoreDeletedThreadsWithUnread(
    List<ChatThread> threads,
  ) async {
    final restoredIds = threads
        .where(
          (thread) =>
              _deletedThreadIds.contains(thread.threadId) &&
              thread.unreadCount > 0,
        )
        .map((thread) => thread.threadId)
        .where((threadId) => threadId.isNotEmpty)
        .toSet();
    if (restoredIds.isEmpty) return;
    final prefs = await ref.read(sharedPreferencesProvider.future);
    final nextDeleted = _deletedThreadIds.toSet()..removeAll(restoredIds);
    await prefs.setStringList(
      StorageKeys.talkDeletedThreadIds,
      nextDeleted.toList()..sort(),
    );
    if (!mounted) return;
    setState(() {
      _deletedThreadIds
        ..clear()
        ..addAll(nextDeleted);
    });
  }

  Future<void> _togglePinnedThread(ChatThread thread) async {
    final prefs = await ref.read(sharedPreferencesProvider.future);
    final nextPinned = _pinnedThreadIds.toSet();
    final isPinned = nextPinned.contains(thread.threadId);
    if (isPinned) {
      nextPinned.remove(thread.threadId);
    } else {
      nextPinned.add(thread.threadId);
    }
    await prefs.setStringList(
      StorageKeys.talkPinnedThreadIds,
      nextPinned.toList()..sort(),
    );
    if (!mounted) return;
    setState(() {
      _pinnedThreadIds
        ..clear()
        ..addAll(nextPinned);
    });
    _showSnack(isPinned ? 'Chat unpinned.' : 'Chat pinned to the top.');
  }

  Future<void> _toggleThreadMuted(ChatThread thread) async {
    final prefs = await ref.read(sharedPreferencesProvider.future);
    final key = _threadNotificationPrefKey(thread.partnerId);
    final nextMuted = !_mutedPartnerIds.contains(thread.partnerId);
    await prefs.setBool(key, nextMuted);
    if (!mounted) return;
    setState(() {
      if (nextMuted) {
        _mutedPartnerIds.add(thread.partnerId);
      } else {
        _mutedPartnerIds.remove(thread.partnerId);
      }
    });
    _showSnack(
      nextMuted ? 'Notifications muted for this chat.' : 'Chat unmuted.',
    );
  }

  Future<bool> _confirmDeleteThread(ChatThread thread) async {
    final confirmed = await showDialog<bool>(
      context: context,
      useRootNavigator: true,
      builder: (dialogContext) => AlertDialog(
        title: const Text('Delete chat?'),
        content: Text(
          'This removes ${thread.displayName} from your chat list on this device.',
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(dialogContext).pop(false),
            child: const Text('Cancel'),
          ),
          FilledButton(
            onPressed: () => Navigator.of(dialogContext).pop(true),
            child: const Text('Delete'),
          ),
        ],
      ),
    );
    return confirmed == true;
  }

  Future<void> _deleteThread(ChatThread thread) async {
    final confirmed = await _confirmDeleteThread(thread);
    if (!confirmed) return;
    final prefs = await ref.read(sharedPreferencesProvider.future);
    final nextDeleted = _deletedThreadIds.toSet()..add(thread.threadId);
    final nextPinned = _pinnedThreadIds.toSet()..remove(thread.threadId);
    await prefs.setStringList(
      StorageKeys.talkDeletedThreadIds,
      nextDeleted.toList()..sort(),
    );
    await prefs.setStringList(
      StorageKeys.talkPinnedThreadIds,
      nextPinned.toList()..sort(),
    );
    await prefs.remove(
      '${StorageKeys.directChatCachePrefix}${thread.partnerId}',
    );
    await prefs.remove(
      '${StorageKeys.directChatCachePrefix}${thread.partnerId}_translations',
    );
    await prefs.remove(
      '${StorageKeys.directChatCachePrefix}${thread.partnerId}_reactions',
    );
    if (_joinedTypingRooms.remove(thread.threadId)) {
      ref.read(socketServiceProvider).emit('dm:leave', <String, dynamic>{
        'threadId': thread.threadId,
      });
    }
    if (!mounted) return;
    setState(() {
      _deletedThreadIds
        ..clear()
        ..addAll(nextDeleted);
      _pinnedThreadIds
        ..clear()
        ..addAll(nextPinned);
      _typingSeenAt.remove(thread.threadId);
      _typingByThread.remove(thread.threadId);
    });
    _showSnack('Chat deleted from your inbox.');
  }

  Future<void> _showThreadMenu(ChatThread thread) async {
    final scheme = Theme.of(context).colorScheme;
    final isPinned = _pinnedThreadIds.contains(thread.threadId);
    final isMuted = _mutedPartnerIds.contains(thread.partnerId);
    final selection = await showModalBottomSheet<_InboxThreadAction>(
      context: context,
      useRootNavigator: true,
      backgroundColor: scheme.surface,
      shape: const RoundedRectangleBorder(
        borderRadius: BorderRadius.vertical(top: Radius.circular(28)),
      ),
      builder: (sheetContext) {
        return SafeArea(
          top: false,
          child: Padding(
            padding: const EdgeInsets.fromLTRB(12, 12, 12, 18),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                Container(
                  width: 42,
                  height: 4,
                  margin: const EdgeInsets.only(bottom: 12),
                  decoration: BoxDecoration(
                    color: scheme.outlineVariant,
                    borderRadius: BorderRadius.circular(999),
                  ),
                ),
                ListTile(
                  leading: AppAvatar(
                    label: thread.displayName,
                    imageUrl: thread.profilePhotoUrl,
                    radius: 22,
                  ),
                  title: Text(
                    thread.displayName,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                  ),
                  subtitle: Text('@${thread.username}'),
                ),
                ListTile(
                  leading: Icon(
                    isPinned ? Icons.push_pin_rounded : Icons.push_pin_outlined,
                  ),
                  title: Text(isPinned ? 'Unpin chat' : 'Pin chat'),
                  onTap: () =>
                      Navigator.of(sheetContext).pop(_InboxThreadAction.pin),
                ),
                ListTile(
                  leading: Icon(
                    isMuted
                        ? Icons.notifications_active_outlined
                        : Icons.notifications_off_outlined,
                  ),
                  title: Text(
                    isMuted ? 'Unmute notifications' : 'Mute notifications',
                  ),
                  onTap: () =>
                      Navigator.of(sheetContext).pop(_InboxThreadAction.mute),
                ),
                ListTile(
                  leading: const Icon(Icons.person_outline_rounded),
                  title: const Text('View profile'),
                  onTap: () => Navigator.of(
                    sheetContext,
                  ).pop(_InboxThreadAction.viewProfile),
                ),
                ListTile(
                  leading: Icon(
                    Icons.delete_outline_rounded,
                    color: scheme.error,
                  ),
                  title: Text(
                    'Delete',
                    style: TextStyle(
                      color: scheme.error,
                      fontWeight: FontWeight.w600,
                    ),
                  ),
                  onTap: () =>
                      Navigator.of(sheetContext).pop(_InboxThreadAction.delete),
                ),
              ],
            ),
          ),
        );
      },
    );
    if (!mounted || selection == null) return;
    switch (selection) {
      case _InboxThreadAction.pin:
        await _togglePinnedThread(thread);
        return;
      case _InboxThreadAction.mute:
        await _toggleThreadMuted(thread);
        return;
      case _InboxThreadAction.viewProfile:
        if (!mounted) return;
        unawaited(context.push('/app/profile/${thread.partnerId}'));
        return;
      case _InboxThreadAction.delete:
        await _deleteThread(thread);
        return;
    }
  }

  void _handleSearchChanged() {
    if (!mounted) return;
    setState(() {
      _searchQuery = _searchController.text.trim().toLowerCase();
    });
  }

  Future<void> _openContactsInviteSheet() async {
    if (!TalkflixContactsActions.supported) {
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(
          content: Text('Contacts invites work on Android and iOS phones.'),
        ),
      );
      return;
    }
    final scheme = Theme.of(context).colorScheme;
    await showModalBottomSheet<void>(
      context: context,
      backgroundColor: scheme.surface,
      shape: const RoundedRectangleBorder(
        borderRadius: BorderRadius.vertical(top: Radius.circular(28)),
      ),
      builder: (context) {
        return SafeArea(
          top: false,
          child: Padding(
            padding: const EdgeInsets.fromLTRB(12, 12, 12, 18),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Center(
                  child: Container(
                    width: 42,
                    height: 4,
                    margin: const EdgeInsets.only(bottom: 12),
                    decoration: BoxDecoration(
                      color: scheme.outlineVariant,
                      borderRadius: BorderRadius.circular(999),
                    ),
                  ),
                ),
                Text(
                  'Contacts',
                  style: Theme.of(context).textTheme.titleMedium?.copyWith(
                    fontWeight: FontWeight.w800,
                  ),
                ),
                const SizedBox(height: 8),
                ListTile(
                  leading: const Icon(Icons.sms_outlined),
                  title: const Text('Invite via SMS'),
                  subtitle: const Text(
                    'Choose someone from your address book. We only open your SMS app with a Talkflix invite — nothing is uploaded.',
                  ),
                  onTap: () {
                    Navigator.of(context).pop();
                    final host = this.context;
                    WidgetsBinding.instance.addPostFrameCallback((_) {
                      if (!mounted) return;
                      unawaited(
                        TalkflixContactsActions.inviteFromNativePicker(host),
                      );
                    });
                  },
                ),
              ],
            ),
          ),
        );
      },
    );
  }

  Future<void> _handleSharedText(String text, List<ChatThread> threads) async {
    final normalizedText = text.trim();
    if (normalizedText.isEmpty ||
        _handlingSharedText ||
        _handledSharedText == normalizedText) {
      return;
    }
    _handledSharedText = normalizedText;
    _handlingSharedText = true;
    try {
      final selected = await showChatRecipientPicker(
        context: context,
        threads: threads,
        title: 'Share to chat',
        actionLabel: 'Share',
      );
      if (selected.isEmpty || !mounted) return;
      final repository = ref.read(directChatRepositoryProvider);
      var sentCount = 0;
      for (final thread in selected) {
        await repository.sendTextMessage(
          userId: thread.partnerId,
          text: normalizedText,
        );
        sentCount += 1;
      }
      if (!mounted) return;
      ref.invalidate(recentThreadsProvider);
      _showSnack(
        sentCount == 1
            ? 'Link shared.'
            : sentCount > 1
            ? 'Link shared to $sentCount chats.'
            : 'No chats selected.',
      );
    } catch (error) {
      if (mounted) _showSnack(error.toString());
    } finally {
      _handlingSharedText = false;
      if (mounted) {
        context.go('/app/talk');
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    final threads = ref.watch(recentThreadsProvider);
    final sharedText =
        GoRouterState.of(context).uri.queryParameters['share']?.trim() ?? '';
    final l10n = context.l10n;
    final scheme = Theme.of(context).colorScheme;
    final currentUser = ref.watch(
      sessionControllerProvider.select((state) => state.user),
    );
    final unreadNotificationCount = ref.watch(unreadNotificationCountProvider);
    final isDark = Theme.of(context).brightness == Brightness.dark;
    final searchFill = isDark
        ? const Color(0xFF232428)
        : const Color(0xFFF2F3F5);

    return Scaffold(
      backgroundColor: scheme.surface,
      body: SafeArea(
        bottom: false,
        child: Center(
          child: ConstrainedBox(
            constraints: const BoxConstraints(maxWidth: 1180),
            child: Column(
              children: [
                const RealtimeStatusBanner(compactLabel: 'Chat service'),
                Padding(
                  padding: const EdgeInsets.fromLTRB(16, 10, 16, 12),
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Row(
                        children: [
                          Expanded(
                            child: Text(
                              l10n.talksTitle,
                              style: Theme.of(context).textTheme.headlineSmall
                                  ?.copyWith(fontWeight: FontWeight.w800),
                            ),
                          ),
                          const SizedBox(width: 12),
                          InkWell(
                            borderRadius: BorderRadius.circular(24),
                            onTap: () => context.push('/app/profile'),
                            child: AppAvatar(
                              label: currentUser?.displayName ?? 'You',
                              imageUrl: currentUser?.profilePhotoUrl,
                              radius: 22,
                            ),
                          ),
                        ],
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
                              onTap: () => context.push('/app/profile/qr-scan'),
                              child: SizedBox(
                                width: 46,
                                height: 44,
                                child: Icon(
                                  Icons.qr_code_scanner_rounded,
                                  color: scheme.onSurface,
                                ),
                              ),
                            ),
                          ),
                          if (TalkflixContactsActions.supported) ...[
                            const SizedBox(width: 10),
                            Material(
                              color: searchFill,
                              borderRadius: BorderRadius.circular(14),
                              child: InkWell(
                                borderRadius: BorderRadius.circular(14),
                                onTap: _openContactsInviteSheet,
                                child: SizedBox(
                                  width: 46,
                                  height: 44,
                                  child: Icon(
                                    Icons.contacts_outlined,
                                    color: scheme.onSurface,
                                  ),
                                ),
                              ),
                            ),
                          ],
                          const SizedBox(width: 10),
                          Material(
                            color: searchFill,
                            borderRadius: BorderRadius.circular(14),
                            child: InkWell(
                              borderRadius: BorderRadius.circular(14),
                              onTap: () => context.push('/app/notifications'),
                              child: SizedBox(
                                width: 46,
                                height: 44,
                                child: _InboxNotificationButtonIcon(
                                  unreadCount: unreadNotificationCount,
                                  color: scheme.onSurface,
                                ),
                              ),
                            ),
                          ),
                        ],
                      ),
                      if (AppConfig.directCallsEnabled) ...[
                        const SizedBox(height: 12),
                        Material(
                          color: searchFill,
                          borderRadius: BorderRadius.circular(18),
                          child: InkWell(
                            borderRadius: BorderRadius.circular(18),
                            onTap: () => context.push('/app/talk/call-logs'),
                            child: Padding(
                              padding: const EdgeInsets.symmetric(
                                horizontal: 14,
                                vertical: 12,
                              ),
                              child: Row(
                                children: [
                                  Container(
                                    width: 40,
                                    height: 40,
                                    decoration: BoxDecoration(
                                      color: scheme.primary.withValues(
                                        alpha: 0.12,
                                      ),
                                      shape: BoxShape.circle,
                                    ),
                                    child: Icon(
                                      Icons.history_rounded,
                                      color: scheme.primary,
                                    ),
                                  ),
                                  const SizedBox(width: 12),
                                  Expanded(
                                    child: Column(
                                      crossAxisAlignment:
                                          CrossAxisAlignment.start,
                                      mainAxisSize: MainAxisSize.min,
                                      children: [
                                        Text(
                                          'Call logs',
                                          style: Theme.of(context)
                                              .textTheme
                                              .titleSmall
                                              ?.copyWith(
                                                fontWeight: FontWeight.w700,
                                              ),
                                        ),
                                        Text(
                                          'View voice and video calls from all direct chats.',
                                          maxLines: 2,
                                          overflow: TextOverflow.ellipsis,
                                          style: Theme.of(context)
                                              .textTheme
                                              .bodySmall
                                              ?.copyWith(
                                                color: scheme.onSurfaceVariant,
                                              ),
                                        ),
                                      ],
                                    ),
                                  ),
                                  const SizedBox(width: 12),
                                  Icon(
                                    Icons.chevron_right_rounded,
                                    color: scheme.onSurfaceVariant,
                                  ),
                                ],
                              ),
                            ),
                          ),
                        ),
                      ],
                    ],
                  ),
                ),
                Expanded(
                  child: threads.when(
                    data: (items) {
                      if (sharedText.isNotEmpty &&
                          sharedText != _handledSharedText) {
                        WidgetsBinding.instance.addPostFrameCallback((_) {
                          if (!mounted) return;
                          unawaited(_handleSharedText(sharedText, items));
                        });
                      }
                      unawaited(_restoreDeletedThreadsWithUnread(items));
                      final visibleItems = _orderedVisibleThreads(items);
                      _syncTypingRooms(visibleItems);
                      final filteredItems = _searchQuery.isEmpty
                          ? visibleItems
                          : visibleItems.where((thread) {
                              final haystack = [
                                thread.displayName,
                                thread.username,
                                thread.lastMessageText,
                                thread.country,
                              ].join(' ').toLowerCase();
                              return haystack.contains(_searchQuery);
                            }).toList();
                      final list = RefreshIndicator(
                        onRefresh: () =>
                            ref.refresh(recentThreadsProvider.future),
                        child: filteredItems.isEmpty
                            ? ListView(
                                physics: const AlwaysScrollableScrollPhysics(),
                                padding: const EdgeInsets.fromLTRB(
                                  18,
                                  72,
                                  18,
                                  18,
                                ),
                                children: [
                                  Center(
                                    child: Text(
                                      _searchQuery.isNotEmpty
                                          ? 'No chats match your search.'
                                          : visibleItems.isEmpty
                                          ? 'No recent chats yet.'
                                          : 'No chats match your search.',
                                      style: Theme.of(context)
                                          .textTheme
                                          .bodyLarge
                                          ?.copyWith(
                                            color: scheme.onSurfaceVariant,
                                          ),
                                    ),
                                  ),
                                ],
                              )
                            : ListView.separated(
                                physics: const AlwaysScrollableScrollPhysics(),
                                padding: const EdgeInsets.fromLTRB(
                                  16,
                                  4,
                                  16,
                                  24,
                                ),
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
                                        _typingByThread[thread.threadId] ??
                                        false,
                                    isPinned: _pinnedThreadIds.contains(
                                      thread.threadId,
                                    ),
                                    isMuted: _mutedPartnerIds.contains(
                                      thread.partnerId,
                                    ),
                                    onLongPress: () => _showThreadMenu(thread),
                                  );
                                },
                              ),
                      );
                      if (MediaQuery.sizeOf(context).width < 1040) {
                        return list;
                      }
                      return Padding(
                        padding: const EdgeInsets.fromLTRB(16, 0, 16, 20),
                        child: Row(
                          children: [
                            SizedBox(width: 440, child: list),
                            const SizedBox(width: 18),
                            Expanded(
                              child: _InboxDesktopPreview(
                                totalChats: visibleItems.length,
                                unreadChats: visibleItems
                                    .where((thread) => thread.unreadCount > 0)
                                    .length,
                                mutedChats: _mutedPartnerIds.length,
                                onCallLogs: AppConfig.directCallsEnabled
                                    ? () => context.push('/app/talk/call-logs')
                                    : null,
                              ),
                            ),
                          ],
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
                    loading: () =>
                        const Center(child: CircularProgressIndicator()),
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

class _InboxThreadTile extends StatelessWidget {
  const _InboxThreadTile({
    required this.thread,
    required this.isTyping,
    required this.isPinned,
    required this.isMuted,
    required this.onLongPress,
  });

  final ChatThread thread;
  final bool isTyping;
  final bool isPinned;
  final bool isMuted;
  final VoidCallback onLongPress;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return InkWell(
      onTap: () => context.go('/app/talk/${thread.partnerId}'),
      onLongPress: onLongPress,
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
                  Row(
                    children: [
                      Expanded(
                        child: Text(
                          thread.displayName,
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                          style: Theme.of(context).textTheme.titleMedium
                              ?.copyWith(
                                fontWeight: thread.unreadCount > 0
                                    ? FontWeight.w900
                                    : FontWeight.w700,
                              ),
                        ),
                      ),
                      if (isPinned) ...[
                        const SizedBox(width: 6),
                        const Icon(
                          Icons.push_pin_rounded,
                          size: 16,
                          color: talkflixPrimary,
                        ),
                      ],
                      if (isMuted) ...[
                        const SizedBox(width: 6),
                        Icon(
                          Icons.notifications_off_outlined,
                          size: 16,
                          color: scheme.onSurfaceVariant,
                        ),
                      ],
                    ],
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

class _InboxDesktopPreview extends StatelessWidget {
  const _InboxDesktopPreview({
    required this.totalChats,
    required this.unreadChats,
    required this.mutedChats,
    this.onCallLogs,
  });

  final int totalChats;
  final int unreadChats;
  final int mutedChats;
  final VoidCallback? onCallLogs;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;

    return Container(
      height: double.infinity,
      padding: const EdgeInsets.all(24),
      decoration: BoxDecoration(
        color: scheme.surfaceContainerLowest,
        borderRadius: BorderRadius.circular(24),
        border: Border.all(color: scheme.outlineVariant),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Container(
            width: 56,
            height: 56,
            decoration: BoxDecoration(
              color: talkflixPrimary.withValues(alpha: 0.12),
              borderRadius: BorderRadius.circular(18),
            ),
            child: const Icon(TalkflixIcons.talks, color: talkflixPrimary),
          ),
          const SizedBox(height: 18),
          Text(
            'Talk dashboard',
            style: theme.textTheme.headlineSmall?.copyWith(
              fontWeight: FontWeight.w900,
            ),
          ),
          const SizedBox(height: 8),
          Text(
            onCallLogs == null
                ? 'Open a conversation from the inbox or manage muted and pinned chats from the thread menu.'
                : 'Open a conversation from the inbox, review call history, or manage muted and pinned chats from the thread menu.',
            style: theme.textTheme.bodyMedium?.copyWith(
              color: scheme.onSurfaceVariant,
              height: 1.4,
            ),
          ),
          const SizedBox(height: 24),
          Wrap(
            spacing: 12,
            runSpacing: 12,
            children: [
              _InboxMetric(label: 'Chats', value: '$totalChats'),
              _InboxMetric(label: 'Unread', value: '$unreadChats'),
              _InboxMetric(label: 'Muted', value: '$mutedChats'),
            ],
          ),
          const Spacer(),
          if (onCallLogs != null)
            FilledButton.icon(
              onPressed: onCallLogs,
              icon: const Icon(Icons.history_rounded),
              label: const Text('Open call logs'),
            ),
        ],
      ),
    );
  }
}

class _InboxNotificationButtonIcon extends StatelessWidget {
  const _InboxNotificationButtonIcon({
    required this.unreadCount,
    required this.color,
  });

  final int unreadCount;
  final Color color;

  @override
  Widget build(BuildContext context) {
    final count = unreadCount < 0 ? 0 : unreadCount;
    return Stack(
      alignment: Alignment.center,
      clipBehavior: Clip.none,
      children: [
        Icon(Icons.notifications_none_rounded, color: color),
        if (count > 0)
          Positioned(
            right: 8,
            top: 7,
            child: Container(
              constraints: const BoxConstraints(minWidth: 17, minHeight: 17),
              padding: const EdgeInsets.symmetric(horizontal: 4),
              decoration: BoxDecoration(
                color: talkflixPrimary,
                borderRadius: BorderRadius.circular(999),
                border: Border.all(
                  color: Theme.of(context).colorScheme.surface,
                  width: 1.5,
                ),
              ),
              alignment: Alignment.center,
              child: Text(
                count > 99 ? '99+' : '$count',
                style: Theme.of(context).textTheme.labelSmall?.copyWith(
                  color: Colors.white,
                  fontSize: count > 99 ? 8 : 9,
                  fontWeight: FontWeight.w900,
                  height: 1,
                ),
              ),
            ),
          ),
      ],
    );
  }
}

class _InboxMetric extends StatelessWidget {
  const _InboxMetric({required this.label, required this.value});

  final String label;
  final String value;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return Container(
      width: 132,
      padding: const EdgeInsets.all(14),
      decoration: BoxDecoration(
        color: scheme.surface,
        borderRadius: BorderRadius.circular(18),
        border: Border.all(color: scheme.outlineVariant),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(
            value,
            style: Theme.of(
              context,
            ).textTheme.titleLarge?.copyWith(fontWeight: FontWeight.w900),
          ),
          const SizedBox(height: 4),
          Text(
            label,
            style: Theme.of(context).textTheme.labelMedium?.copyWith(
              color: scheme.onSurfaceVariant,
              fontWeight: FontWeight.w700,
            ),
          ),
        ],
      ),
    );
  }
}

enum _InboxThreadAction { pin, mute, viewProfile, delete }
