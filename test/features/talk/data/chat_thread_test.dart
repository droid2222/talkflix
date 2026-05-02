import 'package:flutter_test/flutter_test.dart';
import 'package:talkflix_flutter/features/talk/data/chat_thread.dart';

void main() {
  group('ChatThread.fromJson', () {
    test('parses complete thread', () {
      final thread = ChatThread.fromJson({
        'threadId': 't-1',
        'partnerId': 'p-1',
        'displayName': 'Bob',
        'username': 'bob',
        'lastMessageText': 'Hey!',
        'unreadCount': 3,
        'country': 'UK',
        'profilePhotoUrl': 'https://img.test/b.jpg',
      });
      expect(thread.threadId, 't-1');
      expect(thread.displayName, 'Bob');
      expect(thread.unreadCount, 3);
    });

    test('defaults for empty JSON', () {
      final thread = ChatThread.fromJson({});
      expect(thread.threadId, '');
      expect(thread.displayName, 'User');
      expect(thread.unreadCount, 0);
    });
  });
}
