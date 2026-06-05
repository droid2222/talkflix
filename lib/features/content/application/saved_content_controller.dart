import 'dart:async';

import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../core/auth/session_controller.dart';
import '../../../core/config/storage_keys.dart';
import '../data/content_repository.dart';

final savedContentIdsProvider =
    StateNotifierProvider<SavedContentIdsController, SavedContentState>((ref) {
      ref.watch(sessionControllerProvider.select((state) => state.user?.id));
      return SavedContentIdsController(ref);
    });

class SavedContentState {
  const SavedContentState({this.ids = const <String>{}, this.loaded = false});

  final Set<String> ids;
  final bool loaded;

  SavedContentState copyWith({Set<String>? ids, bool? loaded}) {
    return SavedContentState(
      ids: ids ?? this.ids,
      loaded: loaded ?? this.loaded,
    );
  }
}

class SavedContentIdsController extends StateNotifier<SavedContentState> {
  SavedContentIdsController(this._ref) : super(const SavedContentState()) {
    unawaited(_load());
  }

  final Ref _ref;

  Future<void> _load() async {
    try {
      final ids = await _ref
          .read(contentRepositoryProvider)
          .fetchSavedContentIds();
      state = SavedContentState(ids: ids, loaded: true);
      await _persistLocal(ids);
    } catch (_) {
      final prefs = await _ref.read(sharedPreferencesProvider.future);
      final ids =
          prefs
              .getStringList(_storageKey())
              ?.map((item) => item.trim())
              .where((item) => item.isNotEmpty)
              .toSet() ??
          const <String>{};
      state = SavedContentState(ids: ids, loaded: true);
    }
  }

  Future<void> setSaved({
    required String contentId,
    required bool saved,
  }) async {
    final normalized = contentId.trim();
    if (normalized.isEmpty) return;

    final next = Set<String>.from(state.ids);
    if (saved) {
      next.add(normalized);
    } else {
      next.remove(normalized);
    }
    state = state.copyWith(ids: next, loaded: true);

    try {
      if (saved) {
        await _ref.read(contentRepositoryProvider).saveContent(normalized);
      } else {
        await _ref.read(contentRepositoryProvider).unsaveContent(normalized);
      }
      await _persistLocal(next);
    } catch (_) {
      final rollback = Set<String>.from(state.ids);
      if (saved) {
        rollback.remove(normalized);
      } else {
        rollback.add(normalized);
      }
      state = state.copyWith(ids: rollback, loaded: true);
      rethrow;
    }
  }

  Future<void> _persistLocal(Set<String> ids) async {
    final prefs = await _ref.read(sharedPreferencesProvider.future);
    final ordered = ids.toList()..sort();
    await prefs.setStringList(_storageKey(), ordered);
  }

  String _storageKey() {
    final userId = _ref.read(sessionControllerProvider).user?.id.trim() ?? '';
    return '${StorageKeys.contentSavedItemIdsPrefix}${userId.isEmpty ? 'anon' : userId}';
  }
}
