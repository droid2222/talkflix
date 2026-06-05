import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:talkflix_flutter/features/talk/data/direct_call_log_entry.dart';
import 'package:talkflix_flutter/features/talk/data/direct_chat_repository.dart';
import 'package:talkflix_flutter/features/talk/presentation/direct_call_log_controller.dart';

void main() {
  test('loads initial call logs and paginates', () async {
    final repository = _FakeDirectChatRepository(
      pages: <String, DirectCallLogPage>{
        '': DirectCallLogPage(
          entries: [
            DirectCallLogEntry.fromJson({
              'callId': 'call-2',
              'threadId': '1__42',
              'partnerId': '42',
              'partnerDisplayName': 'Ava',
              'direction': 'incoming',
              'mode': 'voice',
              'outcome': 'answered',
              'requestedAt': '2026-05-15T18:20:00.000Z',
              'durationSeconds': 60,
            }),
          ],
          nextCursor: 'cursor-2',
        ),
        'cursor-2': DirectCallLogPage(
          entries: [
            DirectCallLogEntry.fromJson({
              'callId': 'call-1',
              'threadId': '1__42',
              'partnerId': '42',
              'partnerDisplayName': 'Ava',
              'direction': 'outgoing',
              'mode': 'video',
              'outcome': 'missed',
              'requestedAt': '2026-05-14T18:20:00.000Z',
              'durationSeconds': 0,
            }),
          ],
          nextCursor: '',
        ),
      },
    );

    final container = ProviderContainer(
      overrides: [
        directChatRepositoryProvider.overrideWith((ref) => repository),
      ],
    );
    addTearDown(container.dispose);

    final subscription = container.listen<DirectCallLogState>(
      directCallLogControllerProvider,
      (previous, next) {},
      fireImmediately: true,
    );
    addTearDown(subscription.close);

    await _settle();

    final initial = container.read(directCallLogControllerProvider);
    expect(initial.entries, hasLength(1));
    expect(initial.entries.single.callId, 'call-2');
    expect(initial.hasMore, isTrue);

    await container.read(directCallLogControllerProvider.notifier).loadMore();
    await _settle();

    final next = container.read(directCallLogControllerProvider);
    expect(next.entries, hasLength(2));
    expect(next.entries.first.callId, 'call-2');
    expect(next.entries.last.callId, 'call-1');
    expect(next.hasMore, isFalse);
    expect(repository.requestedCursors, ['', 'cursor-2']);
  });
}

Future<void> _settle() async {
  await Future<void>.delayed(const Duration(milliseconds: 20));
}

class _FakeDirectChatRepository extends DirectChatRepository {
  _FakeDirectChatRepository({required this.pages}) : super(_DummyRef());

  final Map<String, DirectCallLogPage> pages;
  final List<String> requestedCursors = <String>[];

  @override
  Future<DirectCallLogPage> fetchAllCallLogs({
    String? cursor,
    int limit = 40,
  }) async {
    final normalizedCursor = (cursor ?? '').trim();
    requestedCursors.add(normalizedCursor);
    return pages[normalizedCursor] ??
        const DirectCallLogPage(entries: [], nextCursor: '');
  }
}

class _DummyRef implements Ref {
  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}
