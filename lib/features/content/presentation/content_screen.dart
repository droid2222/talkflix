import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../../../core/auth/session_controller.dart';
import '../../../core/widgets/feature_scaffold.dart';
import '../data/content_repository.dart';

class ContentScreen extends ConsumerWidget {
  const ContentScreen({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final session = ref.watch(sessionControllerProvider);
    final publishedVideos = ref.watch(publishedVideosProvider);
    final userPosts = ref.watch(userPostsProvider);
    final user = session.user;
    final canPublishVideo = user?.canPublishVideo == true;

    return FeatureScaffold(
      title: 'Content',
      actions: [
        IconButton(
          onPressed: () => _showCreateSheet(
            context: context,
            canPublishVideo: canPublishVideo,
          ),
          icon: const Icon(Icons.add),
          tooltip: 'Create post',
        ),
      ],
      onRefresh: () async {
        ref.invalidate(publishedVideosProvider);
        ref.invalidate(userPostsProvider);
        await Future.wait<void>([
          ref.read(publishedVideosProvider.future),
          ref.read(userPostsProvider.future),
        ]);
      },
      children: [
        SectionCard(
          title: 'Users Posts',
          subtitle: 'Latest text, audio, and image posts from users.',
          child: userPosts.when(
            data: (items) {
              if (items.isEmpty) return const Text('No user posts yet.');
              return Column(
                children: items.take(10).map((item) {
                  final media = item.mediaUrl.isNotEmpty ? ' • media attached' : '';
                  return ListTile(
                    contentPadding: EdgeInsets.zero,
                    leading: Icon(
                      item.kind == 'audio'
                          ? Icons.graphic_eq_rounded
                          : item.kind == 'image'
                          ? Icons.photo_outlined
                          : Icons.article_outlined,
                    ),
                    title: Text(item.title.isEmpty ? 'Untitled ${item.kind} post' : item.title),
                    subtitle: Text(
                      '${item.authorName} • ${item.kind}$media${item.summary.isNotEmpty ? ' • ${item.summary}' : ''}',
                      maxLines: 2,
                      overflow: TextOverflow.ellipsis,
                    ),
                  );
                }).toList(),
              );
            },
            error: (error, stackTrace) => Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(error.toString()),
                const SizedBox(height: 12),
                OutlinedButton(
                  onPressed: () => ref.invalidate(userPostsProvider),
                  child: const Text('Retry'),
                ),
              ],
            ),
            loading: () => const Center(child: CircularProgressIndicator()),
          ),
        ),
        SectionCard(
          title: 'Creator Videos',
          subtitle: 'Published videos from creator accounts.',
          child: publishedVideos.when(
            data: (items) {
              if (items.isEmpty) {
                return const Text(
                  'No published creator videos yet.',
                );
              }
              return Column(
                children: items.take(6).map((item) {
                  final publishedLabel = item.publishedAt == null
                      ? 'Draft'
                      : '${item.publishedAt!.year}-${item.publishedAt!.month.toString().padLeft(2, '0')}-${item.publishedAt!.day.toString().padLeft(2, '0')}';
                  return ListTile(
                    contentPadding: EdgeInsets.zero,
                    leading: const Icon(Icons.play_circle_outline_rounded),
                    title: Text(item.title.isEmpty ? 'Untitled video' : item.title),
                    subtitle: Text(
                      '${item.sourceLocale.toUpperCase()} • $publishedLabel${item.summary.isNotEmpty ? ' • ${item.summary}' : ''}',
                      maxLines: 2,
                      overflow: TextOverflow.ellipsis,
                    ),
                  );
                }).toList(),
              );
            },
            error: (error, stackTrace) => Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(error.toString()),
                const SizedBox(height: 12),
                OutlinedButton(
                  onPressed: () => ref.invalidate(publishedVideosProvider),
                  child: const Text('Retry'),
                ),
              ],
            ),
            loading: () => const Center(child: CircularProgressIndicator()),
          ),
        ),
      ],
    );
  }
  
  void _showCreateSheet({
    required BuildContext context,
    required bool canPublishVideo,
  }) {
    showModalBottomSheet<void>(
      context: context,
      showDragHandle: true,
      builder: (sheetContext) {
        return SafeArea(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              ListTile(
                leading: const Icon(Icons.notes_rounded),
                title: const Text('Text post'),
                onTap: () {
                  Navigator.of(sheetContext).pop();
                  context.go('/app/content/compose/text');
                },
              ),
              ListTile(
                leading: const Icon(Icons.image_outlined),
                title: const Text('Image post'),
                onTap: () {
                  Navigator.of(sheetContext).pop();
                  context.go('/app/content/compose/image');
                },
              ),
              ListTile(
                leading: const Icon(Icons.mic_rounded),
                title: const Text('Audio post'),
                onTap: () {
                  Navigator.of(sheetContext).pop();
                  context.go('/app/content/compose/audio');
                },
              ),
              if (canPublishVideo)
                ListTile(
                  leading: const Icon(Icons.video_call_outlined),
                  title: const Text('Video post'),
                  onTap: () {
                    Navigator.of(sheetContext).pop();
                    context.go('/app/content/creator-studio');
                  },
                ),
            ],
          ),
        );
      },
    );
  }
}
