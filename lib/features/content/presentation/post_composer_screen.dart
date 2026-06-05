// ignore_for_file: use_build_context_synchronously
import 'dart:async';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:image_picker/image_picker.dart';

import '../../../app/theme/app_theme.dart';
import '../../../core/network/api_exception.dart';
import '../data/content_repository.dart';

class _MediaItem {
  _MediaItem({required this.file, required this.isVideo});

  final XFile file;
  final bool isVideo;
}

const int _maxMedia = 6;

class PostComposerScreen extends ConsumerStatefulWidget {
  const PostComposerScreen({super.key, this.canPublishVideo = false});

  final bool canPublishVideo;

  @override
  ConsumerState<PostComposerScreen> createState() => _PostComposerScreenState();
}

class _PostComposerScreenState extends ConsumerState<PostComposerScreen> {
  final _textController = TextEditingController();
  final _pageController = PageController();
  final List<_MediaItem> _media = [];

  int _currentPage = 0;
  bool _submitting = false;

  @override
  void initState() {
    super.initState();
    _textController.addListener(() => setState(() {}));
  }

  @override
  void dispose() {
    _textController.dispose();
    _pageController.dispose();
    super.dispose();
  }

  bool get _canPost =>
      _textController.text.trim().isNotEmpty || _media.isNotEmpty;

  Future<void> _pickPhotos() async {
    final remaining = _maxMedia - _media.length;
    if (remaining <= 0) return;
    ref.read(contentCommentsActiveProvider.notifier).state = true;
    try {
      final picked = await ImagePicker().pickMultiImage();
      if (!mounted || picked.isEmpty) return;
      setState(() {
        for (final file in picked.take(remaining)) {
          _media.add(_MediaItem(file: file, isVideo: false));
        }
      });
      _jumpToLastPage();
    } finally {
      if (mounted) {
        ref.read(contentCommentsActiveProvider.notifier).state = false;
      }
    }
  }

  Future<void> _pickVideo() async {
    if (!widget.canPublishVideo) {
      _showCreatorGate();
      return;
    }
    final remaining = _maxMedia - _media.length;
    if (remaining <= 0) return;
    ref.read(contentCommentsActiveProvider.notifier).state = true;
    try {
      final picked = await ImagePicker().pickVideo(source: ImageSource.gallery);
      if (!mounted || picked == null) return;
      setState(() => _media.add(_MediaItem(file: picked, isVideo: true)));
      _jumpToLastPage();
    } finally {
      if (mounted) {
        ref.read(contentCommentsActiveProvider.notifier).state = false;
      }
    }
  }

  void _removeMedia(int index) {
    setState(() {
      _media.removeAt(index);
      if (_currentPage >= _media.length && _currentPage > 0) {
        _currentPage = _media.length - 1;
      }
    });
  }

  void _jumpToLastPage() {
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!_pageController.hasClients || _media.isEmpty) return;
      _pageController.animateToPage(
        _media.length - 1,
        duration: const Duration(milliseconds: 280),
        curve: Curves.easeOutCubic,
      );
    });
  }

  void _showCreatorGate() {
    final scheme = Theme.of(context).colorScheme;
    showModalBottomSheet<void>(
      context: context,
      backgroundColor: Colors.transparent,
      builder: (_) => Container(
        margin: const EdgeInsets.all(16),
        padding: const EdgeInsets.fromLTRB(24, 28, 24, 32),
        decoration: BoxDecoration(
          color: scheme.surface,
          borderRadius: BorderRadius.circular(28),
        ),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Container(
              width: 56,
              height: 56,
              decoration: BoxDecoration(
                color: talkflixPrimary.withValues(alpha: 0.12),
                shape: BoxShape.circle,
              ),
              child: const Icon(
                Icons.videocam_rounded,
                color: talkflixPrimary,
                size: 28,
              ),
            ),
            const SizedBox(height: 16),
            Text(
              'Creator Account Required',
              style: Theme.of(
                context,
              ).textTheme.titleMedium?.copyWith(fontWeight: FontWeight.w800),
            ),
            const SizedBox(height: 8),
            Text(
              'Video posts are available exclusively to Creator accounts. Upgrade to unlock video publishing.',
              textAlign: TextAlign.center,
              style: Theme.of(
                context,
              ).textTheme.bodyMedium?.copyWith(color: scheme.onSurfaceVariant),
            ),
            const SizedBox(height: 24),
            FilledButton(
              style: FilledButton.styleFrom(
                backgroundColor: talkflixPrimary,
                minimumSize: const Size(double.infinity, 48),
                shape: RoundedRectangleBorder(
                  borderRadius: BorderRadius.circular(14),
                ),
              ),
              onPressed: () => Navigator.of(context).pop(),
              child: const Text('Got it'),
            ),
          ],
        ),
      ),
    );
  }

  Future<void> _submit() async {
    if (!_canPost || _submitting) return;
    final hasVideo = _media.any((item) => item.isVideo);
    final hasImages = _media.any((item) => !item.isVideo);

    unawaited(HapticFeedback.mediumImpact());
    setState(() => _submitting = true);
    try {
      final repo = ref.read(contentRepositoryProvider);
      final kind = hasVideo
          ? 'video'
          : hasImages
          ? 'image'
          : 'text';

      final bodyText = _textController.text.trim();
      final firstLine = bodyText
          .split('\n')
          .map((line) => line.trim())
          .firstWhere((line) => line.isNotEmpty, orElse: () => '');
      final derivedTitle = firstLine.isNotEmpty
          ? (firstLine.length > 120
                ? '${firstLine.substring(0, 120)}…'
                : firstLine)
          : switch (kind) {
              'video' => 'Video post',
              'image' => 'Photo post',
              _ => 'Post',
            };

      final postId = await repo.createUserPost(
        kind: kind,
        title: derivedTitle,
        body: bodyText,
      );

      for (var i = 0; i < _media.length; i++) {
        await repo.uploadPostMedia(
          postId: postId,
          mediaFile: _media[i].file,
          order: i,
        );
      }

      ref.invalidate(userPostsProvider);
      if (!mounted) return;
      Navigator.of(context).pop();
      ScaffoldMessenger.of(
        context,
      ).showSnackBar(const SnackBar(content: Text('Post published.')));
    } on ApiException catch (e) {
      if (!mounted) return;
      ScaffoldMessenger.of(
        context,
      ).showSnackBar(SnackBar(content: Text(userFriendlyMessage(e))));
    } catch (e) {
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text(
            e.toString().replaceFirst('Exception: ', '').trim().isEmpty
                ? 'Could not publish. Please try again.'
                : e.toString().replaceFirst('Exception: ', ''),
          ),
        ),
      );
    } finally {
      if (mounted) {
        setState(() => _submitting = false);
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final isDark = Theme.of(context).brightness == Brightness.dark;
    final canAddMore = _media.length < _maxMedia;

    return Scaffold(
      backgroundColor: isDark ? const Color(0xFF0D0D0D) : scheme.surface,
      appBar: AppBar(
        backgroundColor: Colors.transparent,
        elevation: 0,
        surfaceTintColor: Colors.transparent,
        leading: IconButton(
          icon: const Icon(Icons.close_rounded),
          onPressed: () => Navigator.of(context).pop(),
        ),
        title: const Text(
          'New Post',
          style: TextStyle(fontWeight: FontWeight.w800),
        ),
        centerTitle: true,
        actions: [
          Padding(
            padding: const EdgeInsets.only(right: 12),
            child: _submitting
                ? const SizedBox(
                    width: 22,
                    height: 22,
                    child: CircularProgressIndicator(strokeWidth: 2.5),
                  )
                : FilledButton(
                    onPressed: _canPost ? _submit : null,
                    style: FilledButton.styleFrom(
                      backgroundColor: talkflixPrimary,
                      disabledBackgroundColor: talkflixPrimary.withValues(
                        alpha: 0.28,
                      ),
                      shape: RoundedRectangleBorder(
                        borderRadius: BorderRadius.circular(20),
                      ),
                      padding: const EdgeInsets.symmetric(
                        horizontal: 22,
                        vertical: 8,
                      ),
                      textStyle: const TextStyle(
                        fontWeight: FontWeight.w800,
                        fontSize: 14,
                      ),
                    ),
                    child: const Text('Post'),
                  ),
          ),
        ],
      ),
      body: Column(
        children: [
          Expanded(
            child: Padding(
              padding: const EdgeInsets.fromLTRB(20, 8, 20, 4),
              child: TextField(
                controller: _textController,
                maxLines: null,
                expands: true,
                textAlignVertical: TextAlignVertical.top,
                style: const TextStyle(
                  fontSize: 17,
                  height: 1.55,
                  fontWeight: FontWeight.w500,
                ),
                decoration: InputDecoration(
                  hintText: "What's on your mind?",
                  hintStyle: TextStyle(
                    fontSize: 17,
                    fontWeight: FontWeight.w400,
                    color: isDark
                        ? Colors.white.withValues(alpha: 0.22)
                        : Colors.black.withValues(alpha: 0.22),
                  ),
                  border: InputBorder.none,
                  enabledBorder: InputBorder.none,
                  focusedBorder: InputBorder.none,
                  contentPadding: EdgeInsets.zero,
                ),
              ),
            ),
          ),
          if (_media.isNotEmpty)
            _MediaSlider(
              items: _media,
              pageController: _pageController,
              currentPage: _currentPage,
              canAddMore: canAddMore,
              canVideo: widget.canPublishVideo,
              onPageChanged: (index) => setState(() => _currentPage = index),
              onRemove: _removeMedia,
              onAddPhoto: _pickPhotos,
              onAddVideo: _pickVideo,
            ),
          _ComposerToolbar(
            mediaCount: _media.length,
            canAddMore: canAddMore,
            canVideo: widget.canPublishVideo,
            onPhoto: _pickPhotos,
            onVideo: _pickVideo,
          ),
        ],
      ),
    );
  }
}

class _MediaSlider extends StatelessWidget {
  const _MediaSlider({
    required this.items,
    required this.pageController,
    required this.currentPage,
    required this.canAddMore,
    required this.canVideo,
    required this.onPageChanged,
    required this.onRemove,
    required this.onAddPhoto,
    required this.onAddVideo,
  });

  final List<_MediaItem> items;
  final PageController pageController;
  final int currentPage;
  final bool canAddMore;
  final bool canVideo;
  final ValueChanged<int> onPageChanged;
  final ValueChanged<int> onRemove;
  final VoidCallback onAddPhoto;
  final VoidCallback onAddVideo;

  @override
  Widget build(BuildContext context) {
    final isDark = Theme.of(context).brightness == Brightness.dark;
    final scheme = Theme.of(context).colorScheme;
    final totalPages = items.length + (canAddMore ? 1 : 0);

    return Column(
      mainAxisSize: MainAxisSize.min,
      children: [
        SizedBox(
          height: 300,
          child: PageView.builder(
            controller: pageController,
            itemCount: totalPages,
            onPageChanged: onPageChanged,
            itemBuilder: (context, index) {
              if (index == items.length) {
                return _AddMorePage(
                  isDark: isDark,
                  canVideo: canVideo,
                  onPhoto: onAddPhoto,
                  onVideo: onAddVideo,
                );
              }

              final item = items[index];
              return Stack(
                fit: StackFit.expand,
                children: [
                  item.isVideo
                      ? _VideoPlaceholder(file: item.file)
                      : _ImagePreview(file: item.file),
                  Positioned(
                    top: 10,
                    right: 10,
                    child: GestureDetector(
                      onTap: () => onRemove(index),
                      child: Container(
                        width: 30,
                        height: 30,
                        decoration: BoxDecoration(
                          color: Colors.black.withValues(alpha: 0.6),
                          shape: BoxShape.circle,
                        ),
                        child: const Icon(
                          Icons.close_rounded,
                          color: Colors.white,
                          size: 18,
                        ),
                      ),
                    ),
                  ),
                  if (items.length > 1)
                    Positioned(
                      top: 10,
                      left: 10,
                      child: Container(
                        padding: const EdgeInsets.symmetric(
                          horizontal: 9,
                          vertical: 4,
                        ),
                        decoration: BoxDecoration(
                          color: Colors.black.withValues(alpha: 0.55),
                          borderRadius: BorderRadius.circular(20),
                        ),
                        child: Text(
                          '${index + 1} / ${items.length}',
                          style: const TextStyle(
                            color: Colors.white,
                            fontSize: 12,
                            fontWeight: FontWeight.w700,
                          ),
                        ),
                      ),
                    ),
                ],
              );
            },
          ),
        ),
        if (totalPages > 1)
          Padding(
            padding: const EdgeInsets.only(top: 8, bottom: 2),
            child: Row(
              mainAxisAlignment: MainAxisAlignment.center,
              children: List.generate(totalPages, (index) {
                final active = index == currentPage;
                final isAddPage = index == items.length;
                return AnimatedContainer(
                  duration: const Duration(milliseconds: 220),
                  curve: Curves.easeOutCubic,
                  margin: const EdgeInsets.symmetric(horizontal: 3),
                  width: active ? 20 : 7,
                  height: 7,
                  decoration: BoxDecoration(
                    borderRadius: BorderRadius.circular(99),
                    color: isAddPage
                        ? scheme.outlineVariant
                        : active
                        ? talkflixPrimary
                        : (isDark
                              ? Colors.white.withValues(alpha: 0.3)
                              : Colors.black.withValues(alpha: 0.2)),
                  ),
                );
              }),
            ),
          ),
      ],
    );
  }
}

class _ImagePreview extends StatelessWidget {
  const _ImagePreview({required this.file});

  final XFile file;

  @override
  Widget build(BuildContext context) {
    return Image.file(
      File(file.path),
      fit: BoxFit.cover,
      errorBuilder: (context, error, stackTrace) =>
          const Center(child: Icon(Icons.broken_image_rounded, size: 48)),
    );
  }
}

class _VideoPlaceholder extends StatelessWidget {
  const _VideoPlaceholder({required this.file});

  final XFile file;

  @override
  Widget build(BuildContext context) {
    final name = file.name.isEmpty ? file.path.split('/').last : file.name;
    return Container(
      color: Colors.black,
      child: Stack(
        alignment: Alignment.center,
        children: [
          Opacity(
            opacity: 0.08,
            child: GridView.count(
              crossAxisCount: 8,
              children: List.generate(
                64,
                (_) => const DecoratedBox(
                  decoration: BoxDecoration(
                    border: Border(
                      right: BorderSide(color: Colors.white, width: 0.5),
                      bottom: BorderSide(color: Colors.white, width: 0.5),
                    ),
                  ),
                ),
              ),
            ),
          ),
          Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              Container(
                width: 64,
                height: 64,
                decoration: BoxDecoration(
                  shape: BoxShape.circle,
                  color: Colors.white.withValues(alpha: 0.12),
                  border: Border.all(
                    color: Colors.white.withValues(alpha: 0.3),
                    width: 1.5,
                  ),
                ),
                child: const Icon(
                  Icons.play_arrow_rounded,
                  color: Colors.white,
                  size: 36,
                ),
              ),
              const SizedBox(height: 10),
              Text(
                name,
                style: TextStyle(
                  color: Colors.white.withValues(alpha: 0.7),
                  fontSize: 12,
                  fontWeight: FontWeight.w500,
                ),
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
              ),
            ],
          ),
        ],
      ),
    );
  }
}

class _AddMorePage extends StatelessWidget {
  const _AddMorePage({
    required this.isDark,
    required this.canVideo,
    required this.onPhoto,
    required this.onVideo,
  });

  final bool isDark;
  final bool canVideo;
  final VoidCallback onPhoto;
  final VoidCallback onVideo;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return Container(
      margin: const EdgeInsets.symmetric(horizontal: 20),
      decoration: BoxDecoration(
        color: isDark
            ? Colors.white.withValues(alpha: 0.05)
            : scheme.surfaceContainerLow,
        borderRadius: BorderRadius.circular(28),
        border: Border.all(color: scheme.outlineVariant),
      ),
      child: Center(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Text(
              'Add more',
              style: Theme.of(
                context,
              ).textTheme.titleMedium?.copyWith(fontWeight: FontWeight.w800),
            ),
            const SizedBox(height: 16),
            Wrap(
              spacing: 12,
              runSpacing: 12,
              children: [
                _RoundAction(
                  icon: Icons.photo_library_outlined,
                  label: 'Photos',
                  onTap: onPhoto,
                ),
                _RoundAction(
                  icon: Icons.videocam_outlined,
                  label: 'Video',
                  onTap: canVideo ? onVideo : null,
                ),
              ],
            ),
          ],
        ),
      ),
    );
  }
}

class _ComposerToolbar extends StatelessWidget {
  const _ComposerToolbar({
    required this.mediaCount,
    required this.canAddMore,
    required this.canVideo,
    required this.onPhoto,
    required this.onVideo,
  });

  final int mediaCount;
  final bool canAddMore;
  final bool canVideo;
  final VoidCallback onPhoto;
  final VoidCallback onVideo;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return Container(
      padding: const EdgeInsets.fromLTRB(16, 10, 16, 18),
      decoration: BoxDecoration(
        color: scheme.surface,
        border: Border(top: BorderSide(color: scheme.outlineVariant)),
      ),
      child: Row(
        children: [
          _RoundAction(
            icon: Icons.photo_library_outlined,
            label: mediaCount == 0 ? 'Photos' : '$mediaCount media',
            onTap: canAddMore ? onPhoto : null,
          ),
          const SizedBox(width: 12),
          _RoundAction(
            icon: Icons.videocam_outlined,
            label: 'Video',
            onTap: canAddMore ? onVideo : null,
          ),
        ],
      ),
    );
  }
}

class _RoundAction extends StatelessWidget {
  const _RoundAction({
    required this.icon,
    required this.label,
    required this.onTap,
  });

  final IconData icon;
  final String label;
  final VoidCallback? onTap;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return InkWell(
      borderRadius: BorderRadius.circular(24),
      onTap: onTap,
      child: Opacity(
        opacity: onTap == null ? 0.45 : 1,
        child: Container(
          padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 10),
          decoration: BoxDecoration(
            color: scheme.surfaceContainerHighest,
            borderRadius: BorderRadius.circular(24),
          ),
          child: Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              Icon(icon, size: 18),
              const SizedBox(width: 8),
              Text(
                label,
                style: Theme.of(
                  context,
                ).textTheme.labelLarge?.copyWith(fontWeight: FontWeight.w700),
              ),
            ],
          ),
        ),
      ),
    );
  }
}
