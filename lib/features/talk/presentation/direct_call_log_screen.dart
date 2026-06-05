import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';
import 'package:intl/intl.dart';

import '../../../core/widgets/app_avatar.dart';
import '../data/direct_call_log_entry.dart';
import 'direct_call_log_controller.dart';

class DirectCallLogScreen extends ConsumerStatefulWidget {
  const DirectCallLogScreen({super.key});

  @override
  ConsumerState<DirectCallLogScreen> createState() =>
      _DirectCallLogScreenState();
}

class _DirectCallLogScreenState extends ConsumerState<DirectCallLogScreen> {
  final ScrollController _scrollController = ScrollController();
  final DateFormat _timeFormat = DateFormat.jm();
  final DateFormat _dayFormat = DateFormat('MMM d, y');

  @override
  void initState() {
    super.initState();
    _scrollController.addListener(_handleScroll);
  }

  @override
  void dispose() {
    _scrollController
      ..removeListener(_handleScroll)
      ..dispose();
    super.dispose();
  }

  void _handleScroll() {
    if (!_scrollController.hasClients) return;
    if (_scrollController.position.extentAfter > 320) return;
    ref.read(directCallLogControllerProvider.notifier).loadMore();
  }

  @override
  Widget build(BuildContext context) {
    ref.listen<DirectCallLogState>(directCallLogControllerProvider, (
      previous,
      next,
    ) {
      final message = next.deleteErrorMessage;
      if (message == null || message == previous?.deleteErrorMessage) return;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text(message.replaceFirst('Exception: ', ''))),
      );
    });
    final state = ref.watch(directCallLogControllerProvider);
    final items = _buildListItems(state.entries);

    return Scaffold(
      appBar: AppBar(
        title: const Text('Call logs'),
        actions: [
          PopupMenuButton<_CallLogMenuAction>(
            enabled: state.entries.isNotEmpty && !state.isClearingLogs,
            onSelected: (action) {
              switch (action) {
                case _CallLogMenuAction.clearAll:
                  unawaited(_clearAllCallLogs());
              }
            },
            itemBuilder: (context) => [
              const PopupMenuItem(
                value: _CallLogMenuAction.clearAll,
                child: Text('Clear all logs'),
              ),
            ],
          ),
        ],
      ),
      body: RefreshIndicator(
        onRefresh: () =>
            ref.read(directCallLogControllerProvider.notifier).refresh(),
        child: _buildBody(context, state, items),
      ),
    );
  }

  Widget _buildBody(
    BuildContext context,
    DirectCallLogState state,
    List<Object> items,
  ) {
    final scheme = Theme.of(context).colorScheme;
    if (state.isLoading && state.entries.isEmpty) {
      return const Center(child: CircularProgressIndicator());
    }
    if (state.errorMessage != null && state.entries.isEmpty) {
      return ListView(
        physics: const AlwaysScrollableScrollPhysics(),
        children: [
          SizedBox(
            height: MediaQuery.sizeOf(context).height * 0.55,
            child: Center(
              child: Padding(
                padding: const EdgeInsets.symmetric(horizontal: 24),
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    Icon(
                      Icons.history_toggle_off_rounded,
                      size: 42,
                      color: scheme.onSurfaceVariant,
                    ),
                    const SizedBox(height: 12),
                    Text(
                      'Could not load call logs.',
                      style: Theme.of(context).textTheme.titleMedium?.copyWith(
                        fontWeight: FontWeight.w700,
                      ),
                    ),
                    const SizedBox(height: 8),
                    Text(
                      state.errorMessage!.replaceFirst('Exception: ', ''),
                      textAlign: TextAlign.center,
                      style: Theme.of(context).textTheme.bodyMedium?.copyWith(
                        color: scheme.onSurfaceVariant,
                      ),
                    ),
                    const SizedBox(height: 16),
                    FilledButton(
                      onPressed: () => ref
                          .read(directCallLogControllerProvider.notifier)
                          .refresh(),
                      child: const Text('Retry'),
                    ),
                  ],
                ),
              ),
            ),
          ),
        ],
      );
    }
    if (state.entries.isEmpty) {
      return ListView(
        physics: const AlwaysScrollableScrollPhysics(),
        children: [
          SizedBox(
            height: MediaQuery.sizeOf(context).height * 0.55,
            child: Center(
              child: Padding(
                padding: const EdgeInsets.symmetric(horizontal: 24),
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    Icon(
                      Icons.phone_disabled_outlined,
                      size: 42,
                      color: scheme.onSurfaceVariant,
                    ),
                    const SizedBox(height: 12),
                    Text(
                      'No calls yet',
                      style: Theme.of(context).textTheme.titleMedium?.copyWith(
                        fontWeight: FontWeight.w700,
                      ),
                    ),
                    const SizedBox(height: 8),
                    Text(
                      'Your voice and video calls across direct chats will appear here.',
                      textAlign: TextAlign.center,
                      style: Theme.of(context).textTheme.bodyMedium?.copyWith(
                        color: scheme.onSurfaceVariant,
                      ),
                    ),
                  ],
                ),
              ),
            ),
          ),
        ],
      );
    }

    return ListView.builder(
      controller: _scrollController,
      physics: const AlwaysScrollableScrollPhysics(),
      itemCount: items.length + 1,
      itemBuilder: (context, index) {
        if (index == items.length) {
          return _CallLogFooter(
            isLoadingMore: state.isLoadingMore,
            loadMoreErrorMessage: state.loadMoreErrorMessage,
            hasMore: state.hasMore,
            onRetry: () =>
                ref.read(directCallLogControllerProvider.notifier).loadMore(),
          );
        }
        final item = items[index];
        if (item is _CallLogDateHeader) {
          return Padding(
            padding: const EdgeInsets.fromLTRB(16, 16, 16, 6),
            child: Text(
              item.label,
              style: Theme.of(context).textTheme.labelLarge?.copyWith(
                color: scheme.onSurfaceVariant,
                fontWeight: FontWeight.w700,
              ),
            ),
          );
        }
        final entry = item as DirectCallLogEntry;
        final isDeleting = state.deletingCallIds.contains(entry.callId);
        return _CallLogTile(
          entry: entry,
          title: _partnerLabelFor(entry),
          subtitle: _subtitleFor(entry),
          isDeleting: isDeleting,
          onTap: () => context.push('/app/talk/${entry.partnerId}'),
          onRedial: () =>
              context.push('/app/talk/${entry.partnerId}?call=${entry.mode}'),
          onDelete: isDeleting ? null : () => _deleteCallLog(entry),
        );
      },
    );
  }

  Future<void> _deleteCallLog(DirectCallLogEntry entry) async {
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('Delete call log?'),
        content: const Text('This removes the call from your call logs only.'),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(context).pop(false),
            child: const Text('Cancel'),
          ),
          FilledButton(
            onPressed: () => Navigator.of(context).pop(true),
            child: const Text('Delete'),
          ),
        ],
      ),
    );
    if (confirmed != true || !mounted) return;
    final deleted = await ref
        .read(directCallLogControllerProvider.notifier)
        .deleteEntry(entry);
    if (!mounted || !deleted) return;
    ScaffoldMessenger.of(
      context,
    ).showSnackBar(const SnackBar(content: Text('Call log deleted.')));
  }

  Future<void> _clearAllCallLogs() async {
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('Clear all call logs?'),
        content: const Text('This removes all calls from your call logs only.'),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(context).pop(false),
            child: const Text('Cancel'),
          ),
          FilledButton(
            onPressed: () => Navigator.of(context).pop(true),
            child: const Text('Clear all'),
          ),
        ],
      ),
    );
    if (confirmed != true || !mounted) return;
    final cleared = await ref
        .read(directCallLogControllerProvider.notifier)
        .clearAll();
    if (!mounted || !cleared) return;
    ScaffoldMessenger.of(
      context,
    ).showSnackBar(const SnackBar(content: Text('Call logs cleared.')));
  }

  List<Object> _buildListItems(List<DirectCallLogEntry> entries) {
    final items = <Object>[];
    String lastKey = '';
    for (final entry in entries) {
      final currentKey = DateFormat('yyyy-MM-dd').format(entry.requestedAt);
      if (currentKey != lastKey) {
        items.add(_CallLogDateHeader(_dateLabelFor(entry.requestedAt)));
        lastKey = currentKey;
      }
      items.add(entry);
    }
    return items;
  }

  String _dateLabelFor(DateTime value) {
    final now = DateTime.now();
    final today = DateTime(now.year, now.month, now.day);
    final date = DateTime(value.year, value.month, value.day);
    final diffDays = today.difference(date).inDays;
    if (diffDays == 0) return 'Today';
    if (diffDays == 1) return 'Yesterday';
    return _dayFormat.format(value);
  }

  String _partnerLabelFor(DirectCallLogEntry entry) {
    final displayName = entry.partnerDisplayName.trim();
    if (displayName.isNotEmpty) return displayName;
    final username = entry.partnerUsername.trim();
    if (username.isNotEmpty) return '@$username';
    return 'User';
  }

  String _subtitleFor(DirectCallLogEntry entry) {
    final parts = <String>[
      _titleFor(entry),
      _timeFormat.format(entry.requestedAt),
    ];
    if (entry.durationSeconds > 0) {
      parts.add(_formatDuration(entry.durationSeconds));
    }
    return parts.join('  •  ');
  }

  String _titleFor(DirectCallLogEntry entry) {
    final mode = entry.isVideo ? 'video call' : 'voice call';
    switch (entry.outcome) {
      case 'ongoing':
        return 'Ongoing $mode';
      case 'missed':
        return 'Missed $mode';
      case 'unanswered':
        return 'Unanswered $mode';
      case 'declined':
        return 'Declined $mode';
      case 'cancelled':
        return 'Cancelled $mode';
      case 'answered':
      default:
        return entry.isIncoming ? 'Incoming $mode' : 'Outgoing $mode';
    }
  }

  String _formatDuration(int durationSeconds) {
    final hours = durationSeconds ~/ 3600;
    final minutes = (durationSeconds % 3600) ~/ 60;
    final seconds = durationSeconds % 60;
    if (hours > 0) {
      return '$hours:${minutes.toString().padLeft(2, '0')}:${seconds.toString().padLeft(2, '0')}';
    }
    return '$minutes:${seconds.toString().padLeft(2, '0')}';
  }
}

class _CallLogTile extends StatelessWidget {
  const _CallLogTile({
    required this.entry,
    required this.title,
    required this.subtitle,
    required this.isDeleting,
    required this.onTap,
    required this.onRedial,
    required this.onDelete,
  });

  final DirectCallLogEntry entry;
  final String title;
  final String subtitle;
  final bool isDeleting;
  final VoidCallback onTap;
  final VoidCallback onRedial;
  final VoidCallback? onDelete;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final accent = entry.isNegativeOutcome
        ? scheme.error
        : const Color(0xFF22A06B);
    final directionIcon = entry.isIncoming
        ? Icons.call_received_rounded
        : Icons.call_made_rounded;
    final modeIcon = entry.isVideo
        ? Icons.videocam_rounded
        : Icons.call_rounded;

    return ListTile(
      contentPadding: const EdgeInsets.symmetric(horizontal: 16, vertical: 4),
      leading: Stack(
        clipBehavior: Clip.none,
        children: [
          AppAvatar(label: title, imageUrl: entry.partnerPhotoUrl, radius: 24),
          Positioned(
            right: -2,
            bottom: -2,
            child: Container(
              width: 22,
              height: 22,
              decoration: BoxDecoration(
                color: accent,
                shape: BoxShape.circle,
                border: Border.all(color: scheme.surface, width: 2),
              ),
              child: Icon(directionIcon, color: Colors.white, size: 12),
            ),
          ),
        ],
      ),
      title: Text(
        title,
        maxLines: 1,
        overflow: TextOverflow.ellipsis,
        style: Theme.of(
          context,
        ).textTheme.titleSmall?.copyWith(fontWeight: FontWeight.w700),
      ),
      subtitle: Text(subtitle, maxLines: 2, overflow: TextOverflow.ellipsis),
      onTap: onTap,
      trailing: SizedBox(
        width: 96,
        child: Row(
          mainAxisAlignment: MainAxisAlignment.end,
          children: [
            IconButton(
              tooltip: entry.isVideo ? 'Start video call' : 'Start voice call',
              onPressed: isDeleting ? null : onRedial,
              icon: Icon(modeIcon, color: scheme.primary),
            ),
            IconButton(
              tooltip: 'Delete call log',
              onPressed: onDelete,
              icon: isDeleting
                  ? SizedBox(
                      width: 18,
                      height: 18,
                      child: CircularProgressIndicator(
                        strokeWidth: 2,
                        color: scheme.onSurfaceVariant,
                      ),
                    )
                  : Icon(Icons.delete_outline_rounded, color: scheme.error),
            ),
          ],
        ),
      ),
    );
  }
}

class _CallLogFooter extends StatelessWidget {
  const _CallLogFooter({
    required this.isLoadingMore,
    required this.loadMoreErrorMessage,
    required this.hasMore,
    required this.onRetry,
  });

  final bool isLoadingMore;
  final String? loadMoreErrorMessage;
  final bool hasMore;
  final VoidCallback onRetry;

  @override
  Widget build(BuildContext context) {
    if (isLoadingMore) {
      return const Padding(
        padding: EdgeInsets.symmetric(vertical: 16),
        child: Center(child: CircularProgressIndicator()),
      );
    }
    if (loadMoreErrorMessage != null) {
      return Padding(
        padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 12),
        child: Column(
          children: [
            Text(
              loadMoreErrorMessage!.replaceFirst('Exception: ', ''),
              textAlign: TextAlign.center,
            ),
            const SizedBox(height: 8),
            TextButton(onPressed: onRetry, child: const Text('Retry')),
          ],
        ),
      );
    }
    return SizedBox(height: hasMore ? 24 : 12);
  }
}

class _CallLogDateHeader {
  const _CallLogDateHeader(this.label);

  final String label;
}

enum _CallLogMenuAction { clearAll }
