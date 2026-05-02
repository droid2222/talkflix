import 'package:flutter_test/flutter_test.dart';
import 'package:talkflix_flutter/features/talk/data/chat_message.dart';

void main() {
  group('ChatMessage.fromJson', () {
    test('parses complete message', () {
      final msg = ChatMessage.fromJson({
        'id': 'msg-1',
        'clientMessageId': 'client-1',
        'threadId': 'thread-1',
        'fromUserId': 'user-a',
        'toUserId': 'user-b',
        'type': 'text',
        'text': 'Hello!',
        'imageUrl': '',
        'audioUrl': '',
        'audioDuration': 0,
        'mimeType': '',
        'status': 'delivered',
        'createdAt': '2025-01-15T10:30:00Z',
        'replyToMessageId': 'msg-0',
      });
      expect(msg.id, 'msg-1');
      expect(msg.clientMessageId, 'client-1');
      expect(msg.isText, isTrue);
      expect(msg.text, 'Hello!');
      expect(msg.replyToMessageId, 'msg-0');
      expect(msg.status, 'delivered');
      expect(msg.createdAt.year, 2025);
    });

    test('defaults for empty JSON', () {
      final msg = ChatMessage.fromJson({});
      expect(msg.id, '');
      expect(msg.type, 'text');
      expect(msg.status, 'sent');
      expect(msg.audioDuration, 0);
    });

    test('parses int createdAt as milliseconds', () {
      final ms = DateTime(2024, 6, 1).millisecondsSinceEpoch;
      final msg = ChatMessage.fromJson({'createdAt': ms});
      expect(msg.createdAt.year, 2024);
      expect(msg.createdAt.month, 6);
    });

    test('parses num createdAt', () {
      final ms = DateTime(2024, 3, 15).millisecondsSinceEpoch;
      final msg = ChatMessage.fromJson({'createdAt': ms.toDouble()});
      expect(msg.createdAt.year, 2024);
    });

    test('falls back to now for invalid createdAt', () {
      final msg = ChatMessage.fromJson({'createdAt': true});
      expect(msg.createdAt.year, DateTime.now().year);
    });

    test('isText returns false for image type', () {
      final msg = ChatMessage.fromJson({'type': 'image'});
      expect(msg.isText, isFalse);
    });
  });
}
