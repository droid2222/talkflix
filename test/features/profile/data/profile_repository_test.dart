import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:talkflix_flutter/features/profile/data/profile_repository.dart';

void main() {
  test('ProfilePrivacyPayload parses nested privacy payloads', () {
    final payload = ProfilePrivacyPayload.fromJson({
      'privacy': {
        'ageVisible': true,
        'countryVisible': false,
        'flagVisible': true,
        'followStatsVisible': false,
      },
    });

    expect(payload.showAge, isTrue);
    expect(payload.showCountry, isFalse);
    expect(payload.showFlag, isTrue);
    expect(payload.showFollowStats, isFalse);
  });

  test('ProfileMediaPayload parses quota-managed profile media', () {
    final payload = ProfileMediaPayload.fromJson({
      'profileMedia': {
        'maxPhotos': 4,
        'maxVideos': 1,
        'photos': [
          {
            'id': 'photo-1',
            'url': 'https://example.com/photo.jpg',
            'mimeType': 'image/jpeg',
            'order': 0,
          },
        ],
        'video': {
          'id': 'video-1',
          'url': 'https://example.com/video.mp4',
          'thumbnailUrl': 'https://example.com/video.jpg',
          'mimeType': 'video/mp4',
          'durationSeconds': 42,
        },
      },
    });

    expect(payload.maxPhotos, 4);
    expect(payload.maxVideos, 1);
    expect(payload.photos, hasLength(1));
    expect(payload.photos.single.isImage, isTrue);
    expect(payload.video?.isVideo, isTrue);
    expect(payload.video?.durationSeconds, 42);
    expect(payload.remainingPhotoSlots, 3);
    expect(payload.canAddPhoto, isTrue);
    expect(payload.canAddVideo, isFalse);
  });

  test(
    'blockedUsersProvider refetches when the screen listens again',
    () async {
      final repository = _FakeProfileRepository();
      final container = ProviderContainer(
        overrides: [
          profileRepositoryProvider.overrideWith((ref) => repository),
        ],
      );
      addTearDown(container.dispose);

      final firstSubscription = container.listen(
        blockedUsersProvider,
        (previous, next) {},
      );
      await container.read(blockedUsersProvider.future);
      expect(repository.fetchBlockedUsersCalls, 1);

      firstSubscription.close();
      await Future<void>.delayed(Duration.zero);

      final secondSubscription = container.listen(
        blockedUsersProvider,
        (previous, next) {},
      );
      await container.read(blockedUsersProvider.future);
      expect(repository.fetchBlockedUsersCalls, 2);

      secondSubscription.close();
    },
  );
}

class _FakeProfileRepository extends ProfileRepository {
  _FakeProfileRepository() : super(_DummyRef());

  int fetchBlockedUsersCalls = 0;

  @override
  Future<List<BlockedUserEntry>> fetchBlockedUsers() async {
    fetchBlockedUsersCalls += 1;
    return const <BlockedUserEntry>[];
  }
}

class _DummyRef implements Ref {
  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}
