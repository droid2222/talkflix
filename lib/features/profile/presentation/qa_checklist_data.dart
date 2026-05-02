import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../core/auth/session_controller.dart';

const qaChecklistPrefix = 'qa_checklist_';

const qaSections = <QaSection>[
  QaSection(
    title: 'Startup',
    items: [
      'Confirm the API base URL matches the current simulator, emulator, or device setup.',
      'Check backend health before testing realtime flows.',
      'Verify session and socket status look sane in Diagnostics.',
      'Open media preview from Diagnostics and confirm camera/microphone permissions and local preview work.',
    ],
  ),
  QaSection(
    title: 'Direct chat and calls',
    items: [
      'Load a thread and confirm message history appears.',
      'Send text, image, and voice-note messages across two clients.',
      'Place both voice and video calls and verify accept, timeout, and end states.',
      'Confirm incoming calls still surface outside the chat screen.',
      'Use the session bar to copy the thread ID when comparing two devices or backend logs.',
    ],
  ),
  QaSection(
    title: 'Anonymous match',
    items: [
      'Join the anonymous queue on two clients and confirm a match forms.',
      'Test text chat, follow permissions, and skip/reset behavior.',
      'Start an anonymous call and verify reconnect, timeout, and cleanup states.',
      'Copy the match ID from the session bar when validating anonymous state across clients.',
    ],
  ),
  QaSection(
    title: 'Live rooms',
    items: [
      'Create a room and verify it appears for another client.',
      'Join as listener, raise hand, accept speaker access, and confirm stage sync.',
      'Check mute, camera, leave-stage, rejoin-room, and reconnect behavior.',
      'Copy the room ID from the live status bar when checking logs or room resync behavior.',
    ],
  ),
  QaSection(
    title: 'Profile and discovery',
    items: [
      'Verify profile, followers/following, and follow-unfollow actions.',
      'Check meet discovery refresh, filters, and talk handoff.',
      'Confirm content shortcuts and upgrade state still reflect the current account.',
    ],
  ),
];

final qaChecklistProgressProvider = FutureProvider<QaChecklistProgressSummary>((
  ref,
) async {
  final prefs = await ref.read(sharedPreferencesProvider.future);
  var completed = 0;
  for (var sectionIndex = 0; sectionIndex < qaSections.length; sectionIndex++) {
    final section = qaSections[sectionIndex];
    for (var itemIndex = 0; itemIndex < section.items.length; itemIndex++) {
      if (prefs.getBool(qaChecklistItemKey(sectionIndex, itemIndex)) == true) {
        completed += 1;
      }
    }
  }
  return QaChecklistProgressSummary(
    completedCount: completed,
    totalCount: qaChecklistTotalItems,
  );
});

int get qaChecklistTotalItems =>
    qaSections.fold<int>(0, (count, section) => count + section.items.length);

String qaChecklistItemKey(int sectionIndex, int itemIndex) {
  return '$qaChecklistPrefix${sectionIndex}_$itemIndex';
}

class QaSection {
  const QaSection({required this.title, required this.items});

  final String title;
  final List<String> items;
}

class QaChecklistProgressSummary {
  const QaChecklistProgressSummary({
    required this.completedCount,
    required this.totalCount,
  });

  final int completedCount;
  final int totalCount;
}
