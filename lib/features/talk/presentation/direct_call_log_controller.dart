import 'dart:async';

import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../data/direct_call_log_entry.dart';
import '../data/direct_chat_repository.dart';

final directCallLogControllerProvider =
    StateNotifierProvider.autoDispose<
      DirectCallLogController,
      DirectCallLogState
    >((ref) {
      return DirectCallLogController(ref);
    });

class DirectCallLogController extends StateNotifier<DirectCallLogState> {
  DirectCallLogController(this._ref) : super(const DirectCallLogState()) {
    Future<void>.microtask(refresh);
  }

  final Ref _ref;

  Future<void> refresh() async {
    state = state.copyWith(
      isLoading: true,
      errorMessage: null,
      loadMoreErrorMessage: null,
      clearEntries: true,
      nextCursor: '',
    );
    try {
      final page = await _ref
          .read(directChatRepositoryProvider)
          .fetchAllCallLogs();
      if (!mounted) return;
      state = state.copyWith(
        isLoading: false,
        entries: _dedupeEntries(page.entries),
        nextCursor: page.nextCursor,
      );
    } catch (error) {
      if (!mounted) return;
      state = state.copyWith(isLoading: false, errorMessage: error.toString());
    }
  }

  Future<void> loadMore() async {
    if (state.isLoading ||
        state.isLoadingMore ||
        state.nextCursor.trim().isEmpty) {
      return;
    }
    state = state.copyWith(isLoadingMore: true, loadMoreErrorMessage: null);
    try {
      final page = await _ref
          .read(directChatRepositoryProvider)
          .fetchAllCallLogs(cursor: state.nextCursor);
      if (!mounted) return;
      state = state.copyWith(
        isLoadingMore: false,
        entries: _dedupeEntries([...state.entries, ...page.entries]),
        nextCursor: page.nextCursor,
      );
    } catch (error) {
      if (!mounted) return;
      state = state.copyWith(
        isLoadingMore: false,
        loadMoreErrorMessage: error.toString(),
      );
    }
  }

  Future<bool> deleteEntry(DirectCallLogEntry entry) async {
    final callId = entry.callId.trim();
    if (callId.isEmpty || state.deletingCallIds.contains(callId)) {
      return false;
    }
    final previousEntries = state.entries;
    state = state.copyWith(
      entries: previousEntries
          .where((candidate) => candidate.callId != callId)
          .toList(),
      deletingCallIds: {...state.deletingCallIds, callId},
      deleteErrorMessage: null,
    );
    try {
      await _ref.read(directChatRepositoryProvider).deleteCallLog(callId);
      if (!mounted) return true;
      final nextDeleting = state.deletingCallIds.toSet()..remove(callId);
      state = state.copyWith(deletingCallIds: nextDeleting);
      return true;
    } catch (error) {
      if (!mounted) return false;
      final nextDeleting = state.deletingCallIds.toSet()..remove(callId);
      state = state.copyWith(
        entries: previousEntries,
        deletingCallIds: nextDeleting,
        deleteErrorMessage: error.toString(),
      );
      return false;
    }
  }

  Future<bool> clearAll() async {
    if (state.isClearingLogs || state.entries.isEmpty) return false;
    final previousEntries = state.entries;
    state = state.copyWith(
      entries: const <DirectCallLogEntry>[],
      isClearingLogs: true,
      deleteErrorMessage: null,
    );
    try {
      await _ref.read(directChatRepositoryProvider).clearCallLogs();
      if (!mounted) return true;
      state = state.copyWith(
        isClearingLogs: false,
        nextCursor: '',
        deletingCallIds: const <String>{},
      );
      return true;
    } catch (error) {
      if (!mounted) return false;
      state = state.copyWith(
        entries: previousEntries,
        isClearingLogs: false,
        deleteErrorMessage: error.toString(),
      );
      return false;
    }
  }

  List<DirectCallLogEntry> _dedupeEntries(List<DirectCallLogEntry> entries) {
    final byCallId = <String, DirectCallLogEntry>{};
    for (final entry in entries) {
      final key = entry.callId.trim();
      if (key.isEmpty) continue;
      byCallId[key] = entry;
    }
    final unique = byCallId.values.toList()
      ..sort((a, b) => b.requestedAt.compareTo(a.requestedAt));
    return unique;
  }
}

class DirectCallLogState {
  const DirectCallLogState({
    this.entries = const <DirectCallLogEntry>[],
    this.isLoading = false,
    this.isLoadingMore = false,
    this.isClearingLogs = false,
    this.deletingCallIds = const <String>{},
    this.errorMessage,
    this.loadMoreErrorMessage,
    this.deleteErrorMessage,
    this.nextCursor = '',
  });

  final List<DirectCallLogEntry> entries;
  final bool isLoading;
  final bool isLoadingMore;
  final bool isClearingLogs;
  final Set<String> deletingCallIds;
  final String? errorMessage;
  final String? loadMoreErrorMessage;
  final String? deleteErrorMessage;
  final String nextCursor;

  bool get hasMore => nextCursor.trim().isNotEmpty;

  DirectCallLogState copyWith({
    List<DirectCallLogEntry>? entries,
    bool? isLoading,
    bool? isLoadingMore,
    bool? isClearingLogs,
    Set<String>? deletingCallIds,
    String? errorMessage,
    String? loadMoreErrorMessage,
    String? deleteErrorMessage,
    String? nextCursor,
    bool clearEntries = false,
  }) {
    return DirectCallLogState(
      entries: clearEntries
          ? const <DirectCallLogEntry>[]
          : (entries ?? this.entries),
      isLoading: isLoading ?? this.isLoading,
      isLoadingMore: isLoadingMore ?? this.isLoadingMore,
      isClearingLogs: isClearingLogs ?? this.isClearingLogs,
      deletingCallIds: deletingCallIds ?? this.deletingCallIds,
      errorMessage: errorMessage,
      loadMoreErrorMessage: loadMoreErrorMessage,
      deleteErrorMessage: deleteErrorMessage,
      nextCursor: nextCursor ?? this.nextCursor,
    );
  }
}
