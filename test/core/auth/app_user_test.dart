import 'package:flutter_test/flutter_test.dart';
import 'package:talkflix_flutter/core/auth/app_user.dart';

void main() {
  group('AppUser.fromJson', () {
    test('parses complete JSON correctly', () {
      final user = AppUser.fromJson({
        'id': '42',
        'email': 'alice@test.com',
        'displayName': 'Alice',
        'username': 'alice',
        'firstLanguage': 'English',
        'learnLanguage': 'Spanish',
        'role': 'user',
        'plan': 'free',
        'trialUsed': false,
        'meetLanguages': ['English', 'Spanish'],
        'city': 'NYC',
        'country': 'USA',
        'countryCode': 'US',
        'nationalityCode': 'US',
        'nationalityName': 'American',
        'profilePhotoUrl': 'https://img.test/a.jpg',
        'followersCount': 10,
        'followingCount': 5,
        'postsCount': 3,
        'isFollowing': true,
      });
      expect(user.id, '42');
      expect(user.email, 'alice@test.com');
      expect(user.displayName, 'Alice');
      expect(user.meetLanguages, ['English', 'Spanish']);
      expect(user.followersCount, 10);
      expect(user.isFollowing, isTrue);
    });

    test('provides defaults for missing fields', () {
      final user = AppUser.fromJson({});
      expect(user.id, '');
      expect(user.displayName, 'User');
      expect(user.username, 'user');
      expect(user.role, 'user');
      expect(user.plan, 'free');
      expect(user.trialUsed, isFalse);
      expect(user.meetLanguages, isEmpty);
      expect(user.followersCount, 0);
      expect(user.isFollowing, isFalse);
    });

    test('handles numeric id gracefully', () {
      final user = AppUser.fromJson({'id': 123});
      expect(user.id, '123');
    });

    test('parses age visibility from showAge and ageVisible', () {
      final showAgeUser = AppUser.fromJson({'showAge': true, 'age': 29});
      final ageVisibleUser = AppUser.fromJson({'ageVisible': true, 'age': 31});

      expect(showAgeUser.showAge, isTrue);
      expect(showAgeUser.age, 29);
      expect(ageVisibleUser.showAge, isTrue);
      expect(ageVisibleUser.age, 31);
    });

    test('parses privacy flags from nested privacy payloads', () {
      final user = AppUser.fromJson({
        'age': 28,
        'privacy': {
          'ageVisible': true,
          'flagVisible': true,
          'countryVisible': false,
        },
      });

      expect(user.showAge, isTrue);
      expect(user.showFlag, isTrue);
      expect(user.showCountry, isFalse);
      expect(user.showFollowStats, isTrue);
      expect(user.age, 28);
    });

    test('parses follow stats visibility from showFollowStats', () {
      final hidden = AppUser.fromJson({'showFollowStats': false});
      final visible = AppUser.fromJson({'followStatsVisible': true});

      expect(hidden.showFollowStats, isFalse);
      expect(visible.showFollowStats, isTrue);
    });
  });

  group('isProLike', () {
    AppUser makeUser({String role = 'user', String plan = 'free'}) {
      return AppUser.fromJson({'role': role, 'plan': plan});
    }

    test('returns true for admin role', () {
      expect(makeUser(role: 'admin').isProLike, isTrue);
    });

    test('returns true for pro plan', () {
      expect(makeUser(plan: 'pro').isProLike, isTrue);
    });

    test('returns true for trial plan', () {
      expect(makeUser(plan: 'trial').isProLike, isTrue);
    });

    test('returns false for free plan regular user', () {
      expect(makeUser().isProLike, isFalse);
    });
  });

  group('canPublishToTalkiz', () {
    test('returns true for creator permission sources', () {
      expect(AppUser.fromJson({'role': 'creator'}).canPublishToTalkiz, isTrue);
      expect(
        AppUser.fromJson({'canPublishVideo': true}).canPublishToTalkiz,
        isTrue,
      );
    });

    test('returns false for regular users without permission', () {
      expect(AppUser.fromJson({'role': 'user'}).canPublishToTalkiz, isFalse);
      expect(AppUser.fromJson({'role': 'admin'}).canPublishToTalkiz, isFalse);
    });
  });

  test('copyWith overrides cover photo fields', () {
    final base = AppUser.fromJson({
      'id': '42',
      'displayName': 'Alice',
      'coverPhotoUrls': ['/uploads/one.jpg'],
      'coverPhotosLocked': true,
    });

    final next = base.copyWith(
      coverPhotoUrls: const ['/uploads/two.jpg', '/uploads/three.jpg'],
      coverPhotosLocked: false,
    );

    expect(next.id, '42');
    expect(next.coverPhotoUrls, const [
      '/uploads/two.jpg',
      '/uploads/three.jpg',
    ]);
    expect(next.coverPhotosLocked, isFalse);
  });
}
