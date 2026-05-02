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
}
