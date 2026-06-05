import 'package:flutter_test/flutter_test.dart';
import 'package:talkflix_flutter/features/talk/data/direct_call_log_entry.dart';

void main() {
  test('parses direct call log entry payloads', () {
    final entry = DirectCallLogEntry.fromJson({
      'callId': 'call-1',
      'threadId': '1__2',
      'partnerId': '2',
      'partnerDisplayName': 'Mila',
      'partnerUsername': 'mila',
      'partnerPhotoUrl': '/uploads/mila.png',
      'direction': 'incoming',
      'mode': 'video',
      'outcome': 'missed',
      'requestedAt': '2026-05-15T18:20:00.000Z',
      'durationSeconds': 0,
      'endedByUserId': '1',
    });

    expect(entry.callId, 'call-1');
    expect(entry.threadId, '1__2');
    expect(entry.partnerId, '2');
    expect(entry.partnerDisplayName, 'Mila');
    expect(entry.partnerUsername, 'mila');
    expect(entry.partnerPhotoUrl, '/uploads/mila.png');
    expect(entry.isIncoming, isTrue);
    expect(entry.isVideo, isTrue);
    expect(entry.outcome, 'missed');
    expect(entry.durationSeconds, 0);
    expect(entry.endedByUserId, '1');
  });

  test('parses pages and next cursor', () {
    final page = DirectCallLogPage.fromJson({
      'logs': [
        {
          'callId': 'call-2',
          'threadId': '1__2',
          'partnerId': '2',
          'partnerDisplayName': 'Mila',
          'direction': 'outgoing',
          'mode': 'voice',
          'outcome': 'answered',
          'requestedAt': '2026-05-15T18:20:00.000Z',
          'durationSeconds': 164,
        },
      ],
      'nextCursor': '1715797200000:8',
    });

    expect(page.entries, hasLength(1));
    expect(page.entries.single.mode, 'voice');
    expect(page.entries.single.outcome, 'answered');
    expect(page.nextCursor, '1715797200000:8');
    expect(page.hasMore, isTrue);
  });
}
