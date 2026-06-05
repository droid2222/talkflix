import 'package:flutter_test/flutter_test.dart';
import 'package:talkflix_flutter/features/content/data/content_repository.dart';

void main() {
  group('ContentCommentItem.fromJson', () {
    test('parses reply metadata', () {
      final comment = ContentCommentItem.fromJson(const <String, dynamic>{
        'id': '11',
        'userId': '7',
        'authorName': 'Leyla',
        'body': 'Reply body',
        'createdAt': '2026-05-06T18:20:00.000Z',
        'likeCount': 3,
        'likedByMe': true,
        'parentId': '5',
        'replyToName': 'Omar',
      });

      expect(comment.id, '11');
      expect(comment.userId, '7');
      expect(comment.authorName, 'Leyla');
      expect(comment.body, 'Reply body');
      expect(comment.likeCount, 3);
      expect(comment.likedByMe, isTrue);
      expect(comment.parentId, '5');
      expect(comment.replyToName, 'Omar');
      expect(comment.isReply, isTrue);
      expect(comment.createdAt, isNotNull);
    });

    test('treats top-level comment as non-reply', () {
      final comment = ContentCommentItem.fromJson(const <String, dynamic>{
        'id': '12',
        'userId': '8',
        'authorName': 'Amira',
        'body': 'Top-level',
      });

      expect(comment.parentId, isNull);
      expect(comment.replyToName, isNull);
      expect(comment.isReply, isFalse);
    });
  });

  group('shared link parsing', () {
    test('ContentShareLink parses canonical and native URLs', () {
      final share = ContentShareLink.fromJson(const <String, dynamic>{
        'token': 'abc123',
        'entityType': 'live',
        'entityId': 'live_room_1',
        'shareKind': 'live',
        'shareUrl': 'https://www.talkflix.cc/s/abc123',
        'webPreviewUrl': 'https://www.talkflix.cc/w/abc123',
        'appShareUrl': 'https://www.talkflix.cc/s/abc123',
        'nativeAppUrl': 'talkflix://app/s/abc123',
        'canonicalRoute': '/app/live?broadcastId=live_room_1',
        'previewSeconds': 8,
        'expiresAt': '2026-06-05T12:00:00.000Z',
      });

      expect(share.token, 'abc123');
      expect(share.entityType, 'live');
      expect(share.entityId, 'live_room_1');
      expect(share.shareUrl, 'https://www.talkflix.cc/s/abc123');
      expect(share.nativeAppUrl, 'talkflix://app/s/abc123');
      expect(share.canonicalRoute, '/app/live?broadcastId=live_room_1');
      expect(share.expiresAt, isNotNull);
    });

    test('SharedLinkResolveResult parses full-access resolution', () {
      final result = SharedLinkResolveResult.fromJson(const <String, dynamic>{
        'resolution': <String, dynamic>{
          'mode': 'full_access',
          'entityType': 'profile',
          'entityId': '42',
          'shareKind': 'profile',
          'canonicalRoute': '/app/profile/42',
          'shareUrl': 'https://www.talkflix.cc/s/profile42',
        },
      });

      expect(result.resolution.isFullAccess, isTrue);
      expect(result.resolution.entityType, 'profile');
      expect(result.resolution.entityId, '42');
      expect(result.resolution.canonicalRoute, '/app/profile/42');
      expect(result.item, isNull);
    });

    test('PublicSharedContentItem detects live and profile shares', () {
      final live = PublicSharedContentItem.fromJson(const <String, dynamic>{
        'shareToken': 'live1',
        'entityType': 'live',
        'entityId': 'broadcast_1',
        'shareKind': 'live',
        'title': 'Language room',
        'broadcastId': 'broadcast_1',
        'roomType': 'audio',
        'hostName': 'Mina',
        'isPrivate': true,
      });
      final profile = PublicSharedContentItem.fromJson(const <String, dynamic>{
        'shareToken': 'profile1',
        'entityType': 'profile',
        'entityId': '7',
        'shareKind': 'profile',
        'profileId': '7',
        'profileName': 'Omar',
        'profileUsername': 'omar',
      });

      expect(live.isLive, isTrue);
      expect(live.broadcastId, 'broadcast_1');
      expect(live.isPrivate, isTrue);
      expect(profile.isProfile, isTrue);
      expect(profile.profileUsername, 'omar');
    });
  });
}
