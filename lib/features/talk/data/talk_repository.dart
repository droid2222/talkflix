import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../core/network/api_client.dart';
import 'chat_thread.dart';

final talkRepositoryProvider = Provider<TalkRepository>((ref) {
  return TalkRepository(ref);
});

class TalkRepository {
  const TalkRepository(this._ref);

  final Ref _ref;

  Future<List<ChatThread>> fetchRecentThreads() async {
    final data = await _ref.read(apiClientProvider).getJson('/me/recent-chats');
    final threads = data['threads'] as List<dynamic>? ?? const [];
    return threads
        .whereType<Map<String, dynamic>>()
        .map(ChatThread.fromJson)
        .toList();
  }
}
