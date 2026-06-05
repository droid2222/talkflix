import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../core/auth/session_controller.dart';
import '../data/profile_repository.dart';

final profileCoverControllerProvider = Provider<ProfileCoverController>((ref) {
  return ProfileCoverController(ref);
});

final profileCoverOverridesProvider =
    StateProvider<Map<String, ProfileCoverOverride>>((ref) {
      return const <String, ProfileCoverOverride>{};
    });

final profileCoverOverrideProvider =
    Provider.family<ProfileCoverOverride?, String>((ref, userId) {
      return ref.watch(
        profileCoverOverridesProvider.select((value) => value[userId]),
      );
    });

final profileCoverBusyProvider = StateProvider.family<bool, String>((
  ref,
  userId,
) {
  return false;
});

class ProfileCoverController {
  const ProfileCoverController(this._ref);

  final Ref _ref;

  Future<void> upload({
    required String userId,
    required String imagePath,
    required int slot,
  }) async {
    final busy = _ref.read(profileCoverBusyProvider(userId));
    if (busy) return;
    _ref.read(profileCoverBusyProvider(userId).notifier).state = true;
    try {
      final coverPhotoUrls = await _ref
          .read(profileRepositoryProvider)
          .uploadCoverPhoto(imagePath: imagePath, slot: slot);
      _applyServerState(
        userId: userId,
        coverPhotoUrls: coverPhotoUrls.coverPhotoUrls,
        coverPhotoThumbUrls: coverPhotoUrls.coverPhotoThumbUrls,
        coverPhotosLocked: false,
      );
    } finally {
      _ref.read(profileCoverBusyProvider(userId).notifier).state = false;
    }
  }

  Future<void> remove({required String userId, required int slot}) async {
    final busy = _ref.read(profileCoverBusyProvider(userId));
    if (busy) return;
    _ref.read(profileCoverBusyProvider(userId).notifier).state = true;
    try {
      final coverPhotoUrls = await _ref
          .read(profileRepositoryProvider)
          .removeCoverPhoto(slot: slot);
      _applyServerState(
        userId: userId,
        coverPhotoUrls: coverPhotoUrls.coverPhotoUrls,
        coverPhotoThumbUrls: coverPhotoUrls.coverPhotoThumbUrls,
        coverPhotosLocked: false,
      );
    } finally {
      _ref.read(profileCoverBusyProvider(userId).notifier).state = false;
    }
  }

  void clear({required String userId}) {
    final overrides = Map<String, ProfileCoverOverride>.from(
      _ref.read(profileCoverOverridesProvider),
    );
    if (overrides.remove(userId) == null) return;
    _ref.read(profileCoverOverridesProvider.notifier).state = overrides;
  }

  void _applyServerState({
    required String userId,
    required List<String> coverPhotoUrls,
    required List<String> coverPhotoThumbUrls,
    required bool coverPhotosLocked,
  }) {
    final overrides = Map<String, ProfileCoverOverride>.from(
      _ref.read(profileCoverOverridesProvider),
    );
    overrides[userId] = ProfileCoverOverride(
      coverPhotoUrls: List<String>.unmodifiable(coverPhotoUrls),
      coverPhotoThumbUrls: List<String>.unmodifiable(coverPhotoThumbUrls),
      coverPhotosLocked: coverPhotosLocked,
    );
    _ref.read(profileCoverOverridesProvider.notifier).state = overrides;

    final sessionUser = _ref.read(sessionControllerProvider).user;
    if (sessionUser != null && sessionUser.id == userId) {
      _ref
          .read(sessionControllerProvider.notifier)
          .updateCoverPhotos(
            coverPhotoUrls: coverPhotoUrls,
            coverPhotoThumbUrls: coverPhotoThumbUrls,
            coverPhotosLocked: coverPhotosLocked,
          );
    }
  }
}

class ProfileCoverOverride {
  const ProfileCoverOverride({
    required this.coverPhotoUrls,
    required this.coverPhotoThumbUrls,
    required this.coverPhotosLocked,
  });

  final List<String> coverPhotoUrls;
  final List<String> coverPhotoThumbUrls;
  final bool coverPhotosLocked;
}
