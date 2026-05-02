import 'package:flutter_test/flutter_test.dart';
import 'package:talkflix_flutter/features/talk/data/direct_chat_repository.dart';

void main() {
  group('DirectChatThread.fromPayload', () {
    test('parses replies, block flags, and capabilities', () {
      final thread = DirectChatThread.fromPayload({
        'threadId': '1__2',
        'blocked': true,
        'youBlockedUser': true,
        'blockedByUser': false,
        'supportsTranslation': false,
        'supportsCorrection': false,
        'messages': [
          {
            'id': '42',
            'threadId': '1__2',
            'fromUserId': '1',
            'toUserId': '2',
            'type': 'text',
            'text': 'Replying',
            'replyToMessageId': '41',
            'createdAt': 1736898600000,
          },
        ],
      });

      expect(thread.threadId, '1__2');
      expect(thread.blocked, isTrue);
      expect(thread.youBlockedUser, isTrue);
      expect(thread.blockedByUser, isFalse);
      expect(thread.supportsTranslation, isFalse);
      expect(thread.supportsCorrection, isFalse);
      expect(thread.messages, hasLength(1));
      expect(thread.messages.first.replyToMessageId, '41');
    });

    test(
      'treats directional block flags as blocked even without blocked bool',
      () {
        final thread = DirectChatThread.fromPayload({
          'threadId': '2__3',
          'blockedByUser': true,
          'messages': const [],
        });

        expect(thread.blocked, isTrue);
        expect(thread.youBlockedUser, isFalse);
        expect(thread.blockedByUser, isTrue);
      },
    );
  });
}
