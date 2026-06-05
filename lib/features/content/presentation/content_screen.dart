import 'dart:async';
import 'dart:math' as math;

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter/services.dart';
import 'package:go_router/go_router.dart';
import 'package:just_audio/just_audio.dart';
import 'package:share_plus/share_plus.dart';
import 'package:video_player/video_player.dart';
import 'package:visibility_detector/visibility_detector.dart';

import '../../../app/localization/app_language_controller.dart';
import '../../../core/auth/app_user.dart';
import '../../../core/auth/session_controller.dart';
import '../../../core/config/storage_keys.dart';
import '../../../core/formatters/compact_count_formatter.dart';
import '../../../core/media/media_utils.dart';
import '../../../core/media/shared_video_player_pool.dart';
import '../../../core/network/api_client.dart';
import '../../../core/widgets/app_avatar.dart';
import '../../profile/presentation/profile_screen.dart'
    show profileBaseProvider;
import '../application/saved_content_controller.dart';
import '../data/content_repository.dart';
import 'content_text_widgets.dart';
import 'content_ui_utils.dart';
import 'content_video_screen.dart';

const int _subtitleAdvanceLeadMs = 140;

int _subtitleMatchPositionMs(int positionMs) {
  return positionMs + _subtitleAdvanceLeadMs;
}

AppLanguageOption? _languageOptionForCode(String code) {
  final normalized = code.trim().toLowerCase();
  for (final option in appLanguageOptions) {
    final locale = option.locale;
    if (locale == null) continue;
    if (locale.languageCode.toLowerCase() == normalized) {
      return option;
    }
  }
  return null;
}

String _languageLabel(String code) {
  return _languageOptionForCode(code)?.label ?? code.toUpperCase();
}

enum _ContentSegment { talk, podcasts }

enum _CardMenuAction { edit, delete, hide }

const double _talkizWebFeedMaxWidth = 1240;
const double _talkizWebSheetMaxWidth = 760;

class _TalkizWebFrame extends StatelessWidget {
  const _TalkizWebFrame({
    required this.child,
    required this.maxWidth,
    this.expandHeight = false,
  });

  final Widget child;
  final double maxWidth;
  final bool expandHeight;

  @override
  Widget build(BuildContext context) {
    return LayoutBuilder(
      builder: (context, constraints) {
        final width = !kIsWeb
            ? constraints.maxWidth
            : math.min(constraints.maxWidth, maxWidth);
        return Align(
          alignment: Alignment.topCenter,
          child: SizedBox(
            width: width,
            height: expandHeight && constraints.hasBoundedHeight
                ? constraints.maxHeight
                : null,
            child: child,
          ),
        );
      },
    );
  }
}

Future<void> _openCommentsFullScreen({
  required BuildContext context,
  required WidgetRef ref,
  required String contentId,
  required ValueChanged<int> onCommentCountChanged,
}) async {
  ref.read(contentCommentsActiveProvider.notifier).state = true;
  try {
    await showModalBottomSheet<void>(
      context: context,
      useRootNavigator: true,
      isScrollControlled: true,
      enableDrag: true,
      showDragHandle: true,
      useSafeArea: true,
      backgroundColor: Theme.of(context).colorScheme.surface,
      builder: (context) => FractionallySizedBox(
        heightFactor: 0.94,
        child: _CommentsSheet(
          contentId: contentId,
          onCommentCountChanged: onCommentCountChanged,
        ),
      ),
    );
  } finally {
    ref.read(contentCommentsActiveProvider.notifier).state = false;
  }
}

Rect? _shareOriginForContext(BuildContext context) {
  final renderObject = context.findRenderObject();
  if (renderObject is! RenderBox || !renderObject.hasSize) {
    return null;
  }
  return renderObject.localToGlobal(Offset.zero) & renderObject.size;
}

Future<void> _shareTextFromAnchor({
  required BuildContext context,
  required String text,
}) async {
  try {
    await Share.share(
      text,
      sharePositionOrigin: _shareOriginForContext(context),
    );
  } catch (_) {
    if (!context.mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(
      const SnackBar(content: Text('Could not open the share sheet.')),
    );
  }
}

Future<void> openTalkizVideoFullscreen({
  required BuildContext context,
  required String contentId,
  required String title,
  required String source,
  String posterUrl = '',
}) async {
  await Navigator.of(context, rootNavigator: true).push(
    PageRouteBuilder<void>(
      opaque: true,
      transitionDuration: const Duration(milliseconds: 220),
      reverseTransitionDuration: const Duration(milliseconds: 180),
      pageBuilder: (context, animation, secondaryAnimation) =>
          _VideoPreviewSheet(
            contentId: contentId,
            title: title,
            source: source,
            posterUrl: posterUrl,
          ),
      transitionsBuilder: (context, animation, secondaryAnimation, child) {
        final curved = CurvedAnimation(
          parent: animation,
          curve: Curves.easeOutCubic,
          reverseCurve: Curves.easeInCubic,
        );
        return FadeTransition(opacity: curved, child: child);
      },
    ),
  );
}

class ContentScreen extends ConsumerStatefulWidget {
  const ContentScreen({super.key});

  @override
  ConsumerState<ContentScreen> createState() => _ContentScreenState();
}

class _ContentScreenState extends ConsumerState<ContentScreen> {
  _ContentSegment _segment = _ContentSegment.talk;

  Future<void> _refresh() async {
    if (_segment == _ContentSegment.talk) {
      ref.invalidate(userPostsProvider);
      await ref.read(userPostsProvider.future);
      return;
    }
    ref.invalidate(podcastEpisodesProvider);
    await ref.read(podcastEpisodesProvider.future);
  }

  void _openComposer(bool canPublishToTalkiz) {
    if (_segment == _ContentSegment.talk) {
      if (!canPublishToTalkiz) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(
            content: Text('Only creator accounts can post to Talkiz.'),
          ),
        );
        return;
      }
      context.push('/app/content/compose', extra: canPublishToTalkiz);
      return;
    }
    context.push('/app/content/podcasts/compose');
  }

  @override
  Widget build(BuildContext context) {
    final session = ref.watch(sessionControllerProvider);
    final user = session.user;
    final canPublishToTalkiz = user?.canPublishToTalkiz == true;
    final posts = ref.watch(userPostsProvider);
    final podcasts = ref.watch(podcastEpisodesProvider);

    return Scaffold(
      body: _TalkizWebFrame(
        maxWidth: _talkizWebFeedMaxWidth,
        expandHeight: true,
        child: Column(
          children: [
            _TalkizHeader(
              segment: _segment,
              canPublishToTalkiz: canPublishToTalkiz,
              onCreate: () => _openComposer(canPublishToTalkiz),
            ),
            Padding(
              padding: const EdgeInsets.fromLTRB(16, 6, 16, 8),
              child: _ContentTabSwitch(
                tabs: const [
                  _ContentTabData(
                    value: _ContentSegment.talk,
                    label: 'Talkiz',
                    icon: Icons.auto_awesome_mosaic_rounded,
                  ),
                  _ContentTabData(
                    value: _ContentSegment.podcasts,
                    label: 'Podcast',
                    icon: Icons.podcasts_rounded,
                  ),
                ],
                selected: _segment,
                onChanged: (value) => setState(() => _segment = value),
              ),
            ),
            Expanded(
              child: RefreshIndicator(
                onRefresh: _refresh,
                child: switch (_segment) {
                  _ContentSegment.talk => _GeneralFeed(
                    posts: posts,
                    currentUser: user,
                  ),
                  _ContentSegment.podcasts => _PodcastFeed(
                    podcasts: podcasts,
                    currentUser: user,
                  ),
                },
              ),
            ),
          ],
        ),
      ),
    );
  }
}

class _TalkizHeader extends StatelessWidget {
  const _TalkizHeader({
    required this.segment,
    required this.canPublishToTalkiz,
    required this.onCreate,
  });

  final _ContentSegment segment;
  final bool canPublishToTalkiz;
  final VoidCallback onCreate;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final textTheme = Theme.of(context).textTheme;
    final isPodcast = segment == _ContentSegment.podcasts;
    return LayoutBuilder(
      builder: (context, constraints) {
        final isWide = constraints.maxWidth >= 760;
        return Padding(
          padding: EdgeInsets.fromLTRB(16, isWide ? 14 : 6, 16, 6),
          child: DecoratedBox(
            decoration: BoxDecoration(
              color: scheme.surfaceContainerLowest,
              borderRadius: BorderRadius.circular(20),
              border: Border.all(color: scheme.outlineVariant),
            ),
            child: Padding(
              padding: EdgeInsets.symmetric(
                horizontal: isWide ? 18 : 14,
                vertical: isWide ? 16 : 14,
              ),
              child: Row(
                children: [
                  Container(
                    width: 44,
                    height: 44,
                    decoration: BoxDecoration(
                      color: scheme.primaryContainer,
                      borderRadius: BorderRadius.circular(14),
                    ),
                    child: Icon(
                      isPodcast
                          ? Icons.podcasts_rounded
                          : Icons.auto_awesome_mosaic_rounded,
                      color: scheme.onPrimaryContainer,
                    ),
                  ),
                  const SizedBox(width: 14),
                  Expanded(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Text(
                          isPodcast ? 'Podcasts' : 'Talkiz',
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                          style: textTheme.titleLarge?.copyWith(
                            fontWeight: FontWeight.w900,
                          ),
                        ),
                        const SizedBox(height: 3),
                        Text(
                          isPodcast
                              ? 'Long-form language audio from creators.'
                              : 'Language posts, clips, subtitles, and conversations.',
                          maxLines: isWide ? 1 : 2,
                          overflow: TextOverflow.ellipsis,
                          style: textTheme.bodyMedium?.copyWith(
                            color: scheme.onSurfaceVariant,
                            fontWeight: FontWeight.w600,
                          ),
                        ),
                      ],
                    ),
                  ),
                  if (canPublishToTalkiz) ...[
                    const SizedBox(width: 12),
                    if (isWide)
                      FilledButton.icon(
                        onPressed: onCreate,
                        icon: const Icon(Icons.add_rounded),
                        label: const Text('Create'),
                      )
                    else
                      IconButton.filled(
                        onPressed: onCreate,
                        tooltip: isPodcast
                            ? 'Create podcast'
                            : 'Create Talkiz post',
                        icon: const Icon(Icons.add_rounded),
                      ),
                  ],
                ],
              ),
            ),
          ),
        );
      },
    );
  }
}

class _GeneralFeed extends ConsumerStatefulWidget {
  const _GeneralFeed({required this.posts, required this.currentUser});

  final AsyncValue<ContentFeedPage<UserPostItem>> posts;
  final AppUser? currentUser;

  @override
  ConsumerState<_GeneralFeed> createState() => _GeneralFeedState();
}

class _GeneralFeedState extends ConsumerState<_GeneralFeed> {
  final List<UserPostItem> _items = <UserPostItem>[];
  String? _nextCursor;
  bool _hasMore = false;
  bool _loadingMore = false;
  bool _awaitingFreshPage = false;
  String _seedSignature = '';

  String _signatureFor(ContentFeedPage<UserPostItem> page) {
    final first = page.items.isEmpty ? '' : page.items.first.id;
    final last = page.items.isEmpty ? '' : page.items.last.id;
    return '${page.nextCursor}|${page.hasMore}|${page.items.length}|$first|$last';
  }

  void _seedFromPage(ContentFeedPage<UserPostItem> page, {bool force = false}) {
    final signature = _signatureFor(page);
    if (!force && signature == _seedSignature) return;
    _seedSignature = signature;
    _items
      ..clear()
      ..addAll(page.items);
    _nextCursor = page.nextCursor;
    _hasMore = page.hasMore;
    _awaitingFreshPage = false;
  }

  Future<void> _loadMore() async {
    if (_loadingMore || !_hasMore) return;
    setState(() => _loadingMore = true);
    try {
      final page = await ref
          .read(contentRepositoryProvider)
          .fetchUserPosts(cursor: _nextCursor);
      if (!mounted) return;
      setState(() {
        _items.addAll(page.items);
        _nextCursor = page.nextCursor;
        _hasMore = page.hasMore;
        _loadingMore = false;
      });
    } catch (error) {
      if (!mounted) return;
      setState(() => _loadingMore = false);
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text(userFriendlyMessageFromObject(error))),
      );
    }
  }

  @override
  Widget build(BuildContext context) {
    if (widget.posts.isLoading) {
      _awaitingFreshPage = true;
    }
    return widget.posts.when(
      loading: () => const _FeedLoadingList(),
      error: (error, _) => ListView(
        physics: const AlwaysScrollableScrollPhysics(),
        padding: const EdgeInsets.fromLTRB(20, 32, 20, 32),
        children: [
          _ContentEmptyState(
            icon: Icons.error_outline_rounded,
            title: 'Could not load posts',
            subtitle: error.toString(),
          ),
          const SizedBox(height: 16),
          FilledButton.icon(
            onPressed: () => ref.invalidate(userPostsProvider),
            icon: const Icon(Icons.refresh_rounded),
            label: const Text('Try again'),
          ),
        ],
      ),
      data: (page) {
        _seedFromPage(page, force: _awaitingFreshPage);
        if (_items.isEmpty) {
          return ListView(
            physics: const AlwaysScrollableScrollPhysics(),
            padding: const EdgeInsets.fromLTRB(20, 32, 20, 32),
            children: const [
              _ContentEmptyState(
                icon: Icons.auto_awesome_mosaic_rounded,
                title: 'No posts yet',
                subtitle: 'Talk posts are text, photos, and videos.',
              ),
            ],
          );
        }
        return _ProgressiveFeedList<UserPostItem>(
          storageKey: 'talkiz-post-feed',
          items: _items,
          padding: const EdgeInsets.fromLTRB(14, 14, 14, 24),
          endLabel: 'You’re all caught up on Talkiz posts.',
          hasMore: _hasMore,
          loadingMore: _loadingMore,
          onLoadMore: _loadMore,
          sideRail: const _TalkizDesktopRail(segment: _ContentSegment.talk),
          itemBuilder: (context, item) =>
              _PostCard(post: item, currentUser: widget.currentUser),
        );
      },
    );
  }
}

class _PodcastFeed extends ConsumerStatefulWidget {
  const _PodcastFeed({required this.podcasts, required this.currentUser});

  final AsyncValue<ContentFeedPage<PodcastEpisodeItem>> podcasts;
  final AppUser? currentUser;

  @override
  ConsumerState<_PodcastFeed> createState() => _PodcastFeedState();
}

class _PodcastFeedState extends ConsumerState<_PodcastFeed> {
  final List<PodcastEpisodeItem> _items = <PodcastEpisodeItem>[];
  String? _nextCursor;
  bool _hasMore = false;
  bool _loadingMore = false;
  bool _awaitingFreshPage = false;
  String _seedSignature = '';

  String _signatureFor(ContentFeedPage<PodcastEpisodeItem> page) {
    final first = page.items.isEmpty ? '' : page.items.first.id;
    final last = page.items.isEmpty ? '' : page.items.last.id;
    return '${page.nextCursor}|${page.hasMore}|${page.items.length}|$first|$last';
  }

  void _seedFromPage(
    ContentFeedPage<PodcastEpisodeItem> page, {
    bool force = false,
  }) {
    final signature = _signatureFor(page);
    if (!force && signature == _seedSignature) return;
    _seedSignature = signature;
    _items
      ..clear()
      ..addAll(page.items);
    _nextCursor = page.nextCursor;
    _hasMore = page.hasMore;
    _awaitingFreshPage = false;
  }

  Future<void> _loadMore() async {
    if (_loadingMore || !_hasMore) return;
    setState(() => _loadingMore = true);
    try {
      final page = await ref
          .read(contentRepositoryProvider)
          .fetchPodcastEpisodes(cursor: _nextCursor);
      if (!mounted) return;
      setState(() {
        _items.addAll(page.items);
        _nextCursor = page.nextCursor;
        _hasMore = page.hasMore;
        _loadingMore = false;
      });
    } catch (error) {
      if (!mounted) return;
      setState(() => _loadingMore = false);
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text(userFriendlyMessageFromObject(error))),
      );
    }
  }

  @override
  Widget build(BuildContext context) {
    if (widget.podcasts.isLoading) {
      _awaitingFreshPage = true;
    }
    return widget.podcasts.when(
      loading: () => const _FeedLoadingList(),
      error: (error, _) => ListView(
        physics: const AlwaysScrollableScrollPhysics(),
        padding: const EdgeInsets.fromLTRB(20, 32, 20, 32),
        children: [
          _ContentEmptyState(
            icon: Icons.error_outline_rounded,
            title: 'Could not load podcasts',
            subtitle: error.toString(),
          ),
          const SizedBox(height: 16),
          FilledButton.icon(
            onPressed: () => ref.invalidate(podcastEpisodesProvider),
            icon: const Icon(Icons.refresh_rounded),
            label: const Text('Try again'),
          ),
        ],
      ),
      data: (page) {
        _seedFromPage(page, force: _awaitingFreshPage);
        if (_items.isEmpty) {
          return ListView(
            physics: const AlwaysScrollableScrollPhysics(),
            padding: const EdgeInsets.fromLTRB(20, 32, 20, 32),
            children: const [
              _ContentEmptyState(
                icon: Icons.podcasts_rounded,
                title: 'No podcasts yet',
                subtitle:
                    'Podcasts are long-form audio episodes with a cover and short description.',
              ),
            ],
          );
        }
        return _ProgressiveFeedList<PodcastEpisodeItem>(
          storageKey: 'talkiz-podcast-feed',
          items: _items,
          padding: const EdgeInsets.fromLTRB(14, 14, 14, 24),
          endLabel: 'You’re all caught up on podcasts.',
          hasMore: _hasMore,
          loadingMore: _loadingMore,
          onLoadMore: _loadMore,
          sideRail: const _TalkizDesktopRail(segment: _ContentSegment.podcasts),
          itemBuilder: (context, item) =>
              _PodcastCard(item: item, currentUser: widget.currentUser),
        );
      },
    );
  }
}

class _ContentEmptyState extends StatelessWidget {
  const _ContentEmptyState({
    required this.icon,
    required this.title,
    required this.subtitle,
  });

  final IconData icon;
  final String title;
  final String subtitle;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return Container(
      padding: const EdgeInsets.all(24),
      decoration: BoxDecoration(
        color: scheme.surfaceContainerLow,
        borderRadius: BorderRadius.circular(20),
      ),
      child: Column(
        children: [
          Icon(icon, size: 38, color: scheme.primary),
          const SizedBox(height: 12),
          Text(
            title,
            textAlign: TextAlign.center,
            style: Theme.of(
              context,
            ).textTheme.titleMedium?.copyWith(fontWeight: FontWeight.w800),
          ),
          const SizedBox(height: 8),
          Text(
            subtitle,
            textAlign: TextAlign.center,
            style: Theme.of(
              context,
            ).textTheme.bodyMedium?.copyWith(color: scheme.onSurfaceVariant),
          ),
        ],
      ),
    );
  }
}

class _ProgressiveFeedList<T> extends StatefulWidget {
  const _ProgressiveFeedList({
    required this.storageKey,
    required this.items,
    required this.itemBuilder,
    required this.padding,
    required this.endLabel,
    this.hasMore = false,
    this.loadingMore = false,
    this.onLoadMore,
    this.sideRail,
  });

  final String storageKey;
  final List<T> items;
  final Widget Function(BuildContext context, T item) itemBuilder;
  final EdgeInsets padding;
  final String endLabel;
  final bool hasMore;
  final bool loadingMore;
  final Future<void> Function()? onLoadMore;
  final Widget? sideRail;

  @override
  State<_ProgressiveFeedList<T>> createState() =>
      _ProgressiveFeedListState<T>();
}

class _ProgressiveFeedListState<T> extends State<_ProgressiveFeedList<T>> {
  static const _initialBatchSize = 6;
  static const _batchSize = 8;

  final _scrollController = ScrollController();
  late int _visibleCount;

  @override
  void initState() {
    super.initState();
    _visibleCount = math.min(_initialBatchSize, widget.items.length);
    _scrollController.addListener(_handleScroll);
  }

  @override
  void didUpdateWidget(covariant _ProgressiveFeedList<T> oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.storageKey != widget.storageKey ||
        oldWidget.items.length != widget.items.length) {
      final grew = widget.items.length > oldWidget.items.length;
      if (grew && _visibleCount >= oldWidget.items.length) {
        _visibleCount = math.min(
          widget.items.length,
          _visibleCount + _batchSize,
        );
      } else {
        _visibleCount = math.min(
          math.max(_visibleCount, _initialBatchSize),
          widget.items.length,
        );
      }
    }
  }

  @override
  void dispose() {
    _scrollController
      ..removeListener(_handleScroll)
      ..dispose();
    super.dispose();
  }

  void _handleScroll() {
    if (!_scrollController.hasClients) {
      return;
    }
    final remaining =
        _scrollController.position.maxScrollExtent -
        _scrollController.position.pixels;
    if (remaining <= 640) {
      if (_visibleCount < widget.items.length) {
        setState(() {
          _visibleCount = math.min(
            widget.items.length,
            _visibleCount + _batchSize,
          );
        });
        return;
      }
      if (widget.hasMore && !widget.loadingMore) {
        unawaited(widget.onLoadMore?.call() ?? Future<void>.value());
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    final visibleItems = widget.items
        .take(_visibleCount)
        .toList(growable: false);
    final showLoader = widget.loadingMore;
    final showEndCap =
        !showLoader && !widget.hasMore && _visibleCount >= widget.items.length;

    return LayoutBuilder(
      builder: (context, constraints) {
        final useDesktopLayout = constraints.maxWidth >= 980;
        if (!useDesktopLayout) {
          return ListView.separated(
            controller: _scrollController,
            physics: const AlwaysScrollableScrollPhysics(),
            padding: widget.padding,
            itemCount:
                visibleItems.length +
                (showLoader ? 1 : 0) +
                (showEndCap ? 1 : 0),
            separatorBuilder: (context, index) => const SizedBox(height: 14),
            itemBuilder: (context, index) {
              if (index >= visibleItems.length) {
                if (showLoader) {
                  return const _FeedLoadMoreRow();
                }
                return _FeedEndCap(label: widget.endLabel);
              }
              return widget.itemBuilder(context, visibleItems[index]);
            },
          );
        }

        final sideRail = widget.sideRail;
        final availableWidth = constraints.maxWidth - widget.padding.horizontal;
        final railWidth = sideRail == null ? 0.0 : 300.0;
        final gap = sideRail == null ? 0.0 : 22.0;
        final feedWidth = math.min(720.0, availableWidth - railWidth - gap);

        return ListView(
          controller: _scrollController,
          physics: const AlwaysScrollableScrollPhysics(),
          padding: widget.padding,
          children: [
            Align(
              alignment: Alignment.topCenter,
              child: Row(
                mainAxisSize: MainAxisSize.min,
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  SizedBox(
                    width: feedWidth,
                    child: Column(
                      children: [
                        for (
                          var index = 0;
                          index < visibleItems.length;
                          index++
                        )
                          Padding(
                            padding: EdgeInsets.only(
                              bottom: index == visibleItems.length - 1 ? 0 : 16,
                            ),
                            child: widget.itemBuilder(
                              context,
                              visibleItems[index],
                            ),
                          ),
                      ],
                    ),
                  ),
                  if (sideRail != null) ...[
                    SizedBox(width: gap),
                    SizedBox(width: railWidth, child: sideRail),
                  ],
                ],
              ),
            ),
            if (showLoader) ...[
              const SizedBox(height: 18),
              const _FeedLoadMoreRow(),
            ],
            if (showEndCap) ...[
              const SizedBox(height: 18),
              _FeedEndCap(label: widget.endLabel),
            ],
          ],
        );
      },
    );
  }
}

class _TalkizDesktopRail extends StatelessWidget {
  const _TalkizDesktopRail({required this.segment});

  final _ContentSegment segment;

  @override
  Widget build(BuildContext context) {
    final isPodcast = segment == _ContentSegment.podcasts;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        _RailPanel(
          icon: isPodcast ? Icons.headphones_rounded : Icons.subtitles_rounded,
          title: isPodcast ? 'Podcast focus' : 'Language focus',
          lines: isPodcast
              ? const [
                  'Use episodes for deeper listening practice.',
                  'Save useful conversations and replay them later.',
                ]
              : const [
                  'Look for clips with subtitles and clear speech.',
                  'Open a video to read transcripts beside playback.',
                ],
        ),
        const SizedBox(height: 14),
        _RailPanel(
          icon: Icons.tune_rounded,
          title: 'Browse signals',
          chips: isPodcast
              ? const ['Listening', 'Stories', 'Interviews', 'Saved']
              : const ['Videos', 'Photos', 'Text', 'Comments'],
        ),
        const SizedBox(height: 14),
        const _RailPanel(
          icon: Icons.bookmark_rounded,
          title: 'Keep practicing',
          lines: [
            'Save content you want to review.',
            'Use comments for questions and corrections.',
          ],
        ),
      ],
    );
  }
}

class _RailPanel extends StatelessWidget {
  const _RailPanel({
    required this.icon,
    required this.title,
    this.lines = const [],
    this.chips = const [],
  });

  final IconData icon;
  final String title;
  final List<String> lines;
  final List<String> chips;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final textTheme = Theme.of(context).textTheme;
    return DecoratedBox(
      decoration: BoxDecoration(
        color: scheme.surfaceContainerLow,
        borderRadius: BorderRadius.circular(18),
        border: Border.all(color: scheme.outlineVariant),
      ),
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                Icon(icon, size: 20, color: scheme.primary),
                const SizedBox(width: 8),
                Expanded(
                  child: Text(
                    title,
                    style: textTheme.titleSmall?.copyWith(
                      fontWeight: FontWeight.w900,
                    ),
                  ),
                ),
              ],
            ),
            if (lines.isNotEmpty) ...[
              const SizedBox(height: 12),
              for (final line in lines)
                Padding(
                  padding: const EdgeInsets.only(bottom: 8),
                  child: Text(
                    line,
                    style: textTheme.bodySmall?.copyWith(
                      color: scheme.onSurfaceVariant,
                      height: 1.35,
                      fontWeight: FontWeight.w600,
                    ),
                  ),
                ),
            ],
            if (chips.isNotEmpty) ...[
              const SizedBox(height: 12),
              Wrap(
                spacing: 8,
                runSpacing: 8,
                children: [
                  for (final chip in chips)
                    DecoratedBox(
                      decoration: BoxDecoration(
                        color: scheme.surfaceContainerHighest,
                        borderRadius: BorderRadius.circular(999),
                      ),
                      child: Padding(
                        padding: const EdgeInsets.symmetric(
                          horizontal: 10,
                          vertical: 6,
                        ),
                        child: Text(
                          chip,
                          style: textTheme.labelSmall?.copyWith(
                            color: scheme.onSurfaceVariant,
                            fontWeight: FontWeight.w800,
                          ),
                        ),
                      ),
                    ),
                ],
              ),
            ],
          ],
        ),
      ),
    );
  }
}

class _FeedLoadMoreRow extends StatelessWidget {
  const _FeedLoadMoreRow();

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 6),
      child: Row(
        mainAxisAlignment: MainAxisAlignment.center,
        children: [
          SizedBox(
            width: 18,
            height: 18,
            child: CircularProgressIndicator(
              strokeWidth: 2.2,
              color: scheme.primary,
            ),
          ),
          const SizedBox(width: 10),
          Text(
            'Loading more…',
            style: Theme.of(context).textTheme.bodySmall?.copyWith(
              color: scheme.onSurfaceVariant,
              fontWeight: FontWeight.w700,
            ),
          ),
        ],
      ),
    );
  }
}

class _FeedEndCap extends StatelessWidget {
  const _FeedEndCap({required this.label});

  final String label;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return Padding(
      padding: const EdgeInsets.fromLTRB(4, 8, 4, 12),
      child: Column(
        children: [
          Container(
            width: 48,
            height: 4,
            decoration: BoxDecoration(
              color: scheme.outlineVariant,
              borderRadius: BorderRadius.circular(999),
            ),
          ),
          const SizedBox(height: 12),
          Text(
            label,
            textAlign: TextAlign.center,
            style: Theme.of(context).textTheme.bodySmall?.copyWith(
              color: scheme.onSurfaceVariant,
              fontWeight: FontWeight.w700,
            ),
          ),
        ],
      ),
    );
  }
}

class _FeedLoadingList extends StatelessWidget {
  const _FeedLoadingList();

  @override
  Widget build(BuildContext context) {
    return ListView.separated(
      physics: const AlwaysScrollableScrollPhysics(),
      padding: const EdgeInsets.fromLTRB(14, 14, 14, 24),
      itemCount: 4,
      separatorBuilder: (context, index) => const SizedBox(height: 14),
      itemBuilder: (context, index) => const _FeedSkeletonCard(),
    );
  }
}

class _FeedSkeletonCard extends StatelessWidget {
  const _FeedSkeletonCard();

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final shimmer = scheme.surfaceContainerHighest;
    return Container(
      padding: const EdgeInsets.fromLTRB(16, 16, 16, 18),
      decoration: BoxDecoration(
        color: scheme.surface,
        borderRadius: BorderRadius.circular(28),
        border: Border.all(color: scheme.outlineVariant),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              CircleAvatar(radius: 22, backgroundColor: shimmer),
              const SizedBox(width: 12),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    _SkeletonBar(width: 132, color: shimmer),
                    const SizedBox(height: 8),
                    _SkeletonBar(width: 94, height: 10, color: shimmer),
                  ],
                ),
              ),
            ],
          ),
          const SizedBox(height: 16),
          _SkeletonBar(width: double.infinity, height: 18, color: shimmer),
          const SizedBox(height: 10),
          _SkeletonBar(width: 220, color: shimmer),
          const SizedBox(height: 14),
          Container(
            height: 320,
            decoration: BoxDecoration(
              color: shimmer,
              borderRadius: BorderRadius.circular(24),
            ),
          ),
          const SizedBox(height: 14),
          Row(
            children: [
              _SkeletonBar(width: 34, height: 12, color: shimmer),
              const SizedBox(width: 18),
              _SkeletonBar(width: 34, height: 12, color: shimmer),
              const SizedBox(width: 18),
              _SkeletonBar(width: 34, height: 12, color: shimmer),
            ],
          ),
        ],
      ),
    );
  }
}

class _SkeletonBar extends StatelessWidget {
  const _SkeletonBar({
    required this.width,
    required this.color,
    this.height = 14,
  });

  final double width;
  final double height;
  final Color color;

  @override
  Widget build(BuildContext context) {
    return Container(
      width: width,
      height: height,
      decoration: BoxDecoration(
        color: color,
        borderRadius: BorderRadius.circular(999),
      ),
    );
  }
}

class _PostCard extends ConsumerStatefulWidget {
  const _PostCard({
    required this.post,
    required this.currentUser,
    this.openDetailEnabled = true,
  });

  final UserPostItem post;
  final AppUser? currentUser;
  final bool openDetailEnabled;

  @override
  ConsumerState<_PostCard> createState() => _PostCardState();
}

class _PostCardState extends ConsumerState<_PostCard> {
  late int _likeCount;
  late int _commentCount;
  late int _viewCount;
  late bool _likedByMe;
  bool _viewSynced = false;
  bool _likeBusy = false;

  @override
  void initState() {
    super.initState();
    _likeCount = widget.post.likeCount;
    _commentCount = widget.post.commentCount;
    _viewCount = widget.post.viewCount;
    _likedByMe = widget.post.likedByMe;
    WidgetsBinding.instance.addPostFrameCallback((_) {
      unawaited(_recordViewOnce());
    });
  }

  Future<void> _recordViewOnce() async {
    if (!mounted || _viewSynced) return;
    _viewSynced = true;
    try {
      final state = await ref
          .read(contentRepositoryProvider)
          .recordView(widget.post.id);
      if (!mounted) return;
      setState(() => _viewCount = state.viewCount);
    } catch (_) {}
  }

  Future<void> _toggleLike() async {
    if (_likeBusy) return;
    setState(() => _likeBusy = true);
    try {
      final repo = ref.read(contentRepositoryProvider);
      final state = _likedByMe
          ? await repo.unlikeContent(widget.post.id)
          : await repo.likeContent(widget.post.id);
      if (!mounted) return;
      setState(() {
        _likedByMe = state.likedByMe;
        _likeCount = state.likeCount;
      });
    } catch (e) {
      if (!mounted) return;
      ScaffoldMessenger.of(
        context,
      ).showSnackBar(SnackBar(content: Text(userFriendlyMessageFromObject(e))));
    } finally {
      if (mounted) setState(() => _likeBusy = false);
    }
  }

  Future<void> _handleMediaDoubleTapLike() async {
    if (_likedByMe || _likeBusy) return;
    await _toggleLike();
  }

  Future<void> _openComments() async {
    await _openCommentsFullScreen(
      context: context,
      ref: ref,
      contentId: widget.post.id,
      onCommentCountChanged: (count) {
        if (!mounted) return;
        setState(() => _commentCount = count);
      },
    );
  }

  Future<void> _share(BuildContext anchorContext) async {
    try {
      final share = await ref
          .read(contentRepositoryProvider)
          .createContentShareLink(widget.post.id);
      if (!mounted || !anchorContext.mounted) return;
      await _shareTextFromAnchor(
        context: anchorContext,
        text: share.shareUrl.trim(),
      );
    } catch (error) {
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text(userFriendlyMessageFromObject(error))),
      );
    }
  }

  Future<void> _toggleSaved() async {
    final savedState = ref.read(savedContentIdsProvider);
    final currentlySaved = savedState.loaded
        ? savedState.ids.contains(widget.post.id)
        : widget.post.savedByMe;
    await ref
        .read(savedContentIdsProvider.notifier)
        .setSaved(contentId: widget.post.id, saved: !currentlySaved);
    if (!mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(
        content: Text(
          currentlySaved ? 'Post removed from saved.' : 'Post saved.',
        ),
      ),
    );
  }

  Future<void> _openDetail() async {
    if (!widget.openDetailEnabled) return;
    await Navigator.of(context, rootNavigator: true).push(
      MaterialPageRoute<void>(
        builder: (context) => TalkizPostDetailScreen(
          post: widget.post,
          currentUser: widget.currentUser,
        ),
      ),
    );
  }

  Future<void> _openVideoAsset(ContentAssetItem asset) async {
    await openTalkizVideoFullscreen(
      context: context,
      contentId: widget.post.id,
      title: widget.post.title,
      source: asset.url,
      posterUrl: asset.posterUrl,
    );
  }

  Future<void> _handleMenu(_CardMenuAction action) async {
    switch (action) {
      case _CardMenuAction.edit:
        await _editContent(
          context: context,
          ref: ref,
          contentId: widget.post.id,
          title: widget.post.title,
          summary: widget.post.summary,
          body: widget.post.body,
          isPodcast: false,
          onUpdated: () => ref.invalidate(userPostsProvider),
        );
        break;
      case _CardMenuAction.delete:
        await _deleteContent(
          context: context,
          ref: ref,
          contentId: widget.post.id,
          onUpdated: () => ref.invalidate(userPostsProvider),
        );
        break;
      case _CardMenuAction.hide:
        await _hideContent(
          context: context,
          ref: ref,
          contentId: widget.post.id,
          onUpdated: () => ref.invalidate(userPostsProvider),
        );
        break;
    }
  }

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final textTheme = Theme.of(context).textTheme;
    final hasAssets = widget.post.assets.isNotEmpty;
    final hasSummary =
        widget.post.summary.trim().isNotEmpty &&
        widget.post.summary.trim() != widget.post.body.trim();
    final showBody = widget.post.body.trim().isNotEmpty;
    final isOwner = widget.currentUser?.id == widget.post.userId;
    final savedState = ref.watch(savedContentIdsProvider);
    final saved = savedState.loaded
        ? savedState.ids.contains(widget.post.id)
        : widget.post.savedByMe;
    return Container(
      decoration: BoxDecoration(
        color: scheme.surface,
        borderRadius: BorderRadius.circular(18),
        border: Border.all(color: scheme.outlineVariant),
      ),
      child: Padding(
        padding: const EdgeInsets.fromLTRB(14, 14, 14, 16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            _AuthorHeader(
              userId: widget.post.userId,
              fallbackName: widget.post.authorName,
              fallbackUsername: widget.post.authorUsername,
              fallbackProfilePhotoUrl: widget.post.authorProfilePhotoUrl,
              meta: _postMeta(widget.post),
              isOwner: isOwner,
              menuActions: isOwner
                  ? const [_CardMenuAction.edit, _CardMenuAction.delete]
                  : const [_CardMenuAction.hide],
              onMenuSelected: _handleMenu,
            ),
            const SizedBox(height: 12),
            GestureDetector(
              behavior: HitTestBehavior.opaque,
              onTap: _openDetail,
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  if (hasSummary)
                    ContentLinkText(
                      text: widget.post.summary.trim(),
                      style: textTheme.bodyMedium?.copyWith(
                        color: scheme.onSurfaceVariant,
                        height: 1.35,
                        fontWeight: FontWeight.w500,
                      ),
                    ),
                  if (hasSummary && showBody) const SizedBox(height: 10),
                  if (showBody)
                    hasAssets
                        ? ExpandableContentLinkText(
                            text: widget.post.body,
                            style: textTheme.bodyMedium?.copyWith(height: 1.45),
                          )
                        : ContentLinkText(
                            text: widget.post.body,
                            style: textTheme.bodyMedium?.copyWith(height: 1.45),
                          ),
                ],
              ),
            ),
            if (hasAssets) ...[
              const SizedBox(height: 14),
              _PostAssetCarousel(
                assets: widget.post.assets,
                onOpenDetail: _openDetail,
                onOpenVideo: _openVideoAsset,
                onDoubleTapLike: _handleMediaDoubleTapLike,
              ),
            ],
            const SizedBox(height: 14),
            _EngagementBar(
              likedByMe: _likedByMe,
              likeCount: _likeCount,
              commentCount: _commentCount,
              viewCount: _viewCount,
              likeBusy: _likeBusy,
              saved: saved,
              onLike: _toggleLike,
              onComments: _openComments,
              onShare: _share,
              onSave: _toggleSaved,
            ),
          ],
        ),
      ),
    );
  }
}

class _PodcastCard extends ConsumerStatefulWidget {
  const _PodcastCard({
    required this.item,
    required this.currentUser,
    this.openDetailEnabled = true,
  });

  final PodcastEpisodeItem item;
  final AppUser? currentUser;
  final bool openDetailEnabled;

  @override
  ConsumerState<_PodcastCard> createState() => _PodcastCardState();
}

class _PodcastCardState extends ConsumerState<_PodcastCard> {
  late int _likeCount;
  late int _commentCount;
  late int _viewCount;
  late bool _likedByMe;
  bool _viewSynced = false;
  bool _likeBusy = false;

  @override
  void initState() {
    super.initState();
    _likeCount = widget.item.likeCount;
    _commentCount = widget.item.commentCount;
    _viewCount = widget.item.viewCount;
    _likedByMe = widget.item.likedByMe;
    WidgetsBinding.instance.addPostFrameCallback((_) {
      unawaited(_recordViewOnce());
    });
  }

  Future<void> _recordViewOnce() async {
    if (!mounted || _viewSynced) return;
    _viewSynced = true;
    try {
      final state = await ref
          .read(contentRepositoryProvider)
          .recordView(widget.item.id);
      if (!mounted) return;
      setState(() => _viewCount = state.viewCount);
    } catch (_) {}
  }

  Future<void> _toggleLike() async {
    if (_likeBusy) return;
    setState(() => _likeBusy = true);
    try {
      final repo = ref.read(contentRepositoryProvider);
      final state = _likedByMe
          ? await repo.unlikeContent(widget.item.id)
          : await repo.likeContent(widget.item.id);
      if (!mounted) return;
      setState(() {
        _likedByMe = state.likedByMe;
        _likeCount = state.likeCount;
      });
    } catch (e) {
      if (!mounted) return;
      ScaffoldMessenger.of(
        context,
      ).showSnackBar(SnackBar(content: Text(userFriendlyMessageFromObject(e))));
    } finally {
      if (mounted) setState(() => _likeBusy = false);
    }
  }

  Future<void> _openComments() async {
    await _openCommentsFullScreen(
      context: context,
      ref: ref,
      contentId: widget.item.id,
      onCommentCountChanged: (count) {
        if (!mounted) return;
        setState(() => _commentCount = count);
      },
    );
  }

  Future<void> _share(BuildContext anchorContext) async {
    try {
      final share = await ref
          .read(contentRepositoryProvider)
          .createContentShareLink(widget.item.id);
      if (!mounted || !anchorContext.mounted) return;
      await _shareTextFromAnchor(
        context: anchorContext,
        text: share.shareUrl.trim(),
      );
    } catch (error) {
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text(userFriendlyMessageFromObject(error))),
      );
    }
  }

  Future<void> _toggleSaved() async {
    final savedState = ref.read(savedContentIdsProvider);
    final currentlySaved = savedState.loaded
        ? savedState.ids.contains(widget.item.id)
        : widget.item.savedByMe;
    await ref
        .read(savedContentIdsProvider.notifier)
        .setSaved(contentId: widget.item.id, saved: !currentlySaved);
    if (!mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(
        content: Text(
          currentlySaved ? 'Podcast removed from saved.' : 'Podcast saved.',
        ),
      ),
    );
  }

  Future<void> _openDetail() async {
    if (!widget.openDetailEnabled) return;
    await Navigator.of(context, rootNavigator: true).push(
      MaterialPageRoute<void>(
        builder: (context) => TalkizPodcastDetailScreen(
          item: widget.item,
          currentUser: widget.currentUser,
        ),
      ),
    );
  }

  Future<void> _handleMenu(_CardMenuAction action) async {
    switch (action) {
      case _CardMenuAction.edit:
        await _editContent(
          context: context,
          ref: ref,
          contentId: widget.item.id,
          title: widget.item.title,
          summary: widget.item.summary,
          body: widget.item.body,
          isPodcast: true,
          onUpdated: () => ref.invalidate(podcastEpisodesProvider),
        );
        break;
      case _CardMenuAction.delete:
        await _deleteContent(
          context: context,
          ref: ref,
          contentId: widget.item.id,
          onUpdated: () => ref.invalidate(podcastEpisodesProvider),
        );
        break;
      case _CardMenuAction.hide:
        await _hideContent(
          context: context,
          ref: ref,
          contentId: widget.item.id,
          onUpdated: () => ref.invalidate(podcastEpisodesProvider),
        );
        break;
    }
  }

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final textTheme = Theme.of(context).textTheme;
    final showDescription =
        widget.item.summary.trim().isNotEmpty ||
        widget.item.body.trim().isNotEmpty;
    final description = widget.item.summary.trim().isNotEmpty
        ? widget.item.summary.trim()
        : widget.item.body.trim();
    final isOwner = widget.currentUser?.id == widget.item.userId;
    final savedState = ref.watch(savedContentIdsProvider);
    final saved = savedState.loaded
        ? savedState.ids.contains(widget.item.id)
        : widget.item.savedByMe;
    return Container(
      decoration: BoxDecoration(
        color: scheme.surface,
        borderRadius: BorderRadius.circular(18),
        border: Border.all(color: scheme.outlineVariant),
      ),
      child: Padding(
        padding: const EdgeInsets.fromLTRB(14, 14, 14, 16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            _AuthorHeader(
              userId: widget.item.userId,
              fallbackName: widget.item.authorName,
              fallbackUsername: widget.item.authorUsername,
              fallbackProfilePhotoUrl: widget.item.authorProfilePhotoUrl,
              meta: _podcastMeta(widget.item),
              isOwner: isOwner,
              menuActions: isOwner
                  ? const [_CardMenuAction.edit, _CardMenuAction.delete]
                  : const [_CardMenuAction.hide],
              onMenuSelected: _handleMenu,
            ),
            const SizedBox(height: 12),
            GestureDetector(
              behavior: HitTestBehavior.opaque,
              onTap: _openDetail,
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  ClipRRect(
                    borderRadius: BorderRadius.circular(16),
                    child: AspectRatio(
                      aspectRatio: 16 / 9,
                      child: widget.item.coverUrl.isEmpty
                          ? _PodcastCoverFallback(title: widget.item.title)
                          : Image.network(
                              resolveMediaUrl(widget.item.coverUrl),
                              fit: BoxFit.cover,
                              loadingBuilder:
                                  (context, child, loadingProgress) =>
                                      loadingProgress == null
                                      ? child
                                      : const _MediaLoadingPlaceholder(),
                              errorBuilder: (context, error, stackTrace) =>
                                  _PodcastCoverFallback(
                                    title: widget.item.title,
                                  ),
                            ),
                    ),
                  ),
                  const SizedBox(height: 14),
                  Text(
                    widget.item.title,
                    style: textTheme.titleMedium?.copyWith(
                      fontWeight: FontWeight.w800,
                    ),
                  ),
                  if (showDescription) ...[
                    const SizedBox(height: 8),
                    ContentLinkText(
                      text: description,
                      style: textTheme.bodyMedium?.copyWith(height: 1.45),
                    ),
                  ],
                ],
              ),
            ),
            if (widget.item.audioUrl.isNotEmpty) ...[
              const SizedBox(height: 14),
              _PodcastCaptionPlayer(item: widget.item, isOwner: isOwner),
            ],
            const SizedBox(height: 14),
            _EngagementBar(
              likedByMe: _likedByMe,
              likeCount: _likeCount,
              commentCount: _commentCount,
              viewCount: _viewCount,
              likeBusy: _likeBusy,
              saved: saved,
              onLike: _toggleLike,
              onComments: _openComments,
              onShare: _share,
              onSave: _toggleSaved,
            ),
          ],
        ),
      ),
    );
  }
}

class _PodcastCaptionPlayer extends ConsumerStatefulWidget {
  const _PodcastCaptionPlayer({required this.item, required this.isOwner});

  final PodcastEpisodeItem item;
  final bool isOwner;

  @override
  ConsumerState<_PodcastCaptionPlayer> createState() =>
      _PodcastCaptionPlayerState();
}

class _PodcastCaptionPlayerState extends ConsumerState<_PodcastCaptionPlayer> {
  final AudioPlayer _player = AudioPlayer();
  List<ContentTranscriptTrack> _trackMetas = const <ContentTranscriptTrack>[];
  ContentTranscriptTrack? _activeTrack;
  Timer? _pollTimer;
  Duration _position = Duration.zero;
  Duration _duration = Duration.zero;
  bool _loadingAudio = true;
  bool _playing = false;
  bool _loadingTranscript = false;
  bool _translating = false;
  String _transcriptStatus = 'none';
  String _transcriptErrorMessage = '';

  bool get _isTranscriptProcessing =>
      _transcriptStatus == 'pending' || _transcriptStatus == 'processing';

  @override
  void initState() {
    super.initState();
    _trackMetas = widget.item.transcripts;
    _transcriptStatus = widget.item.transcriptStatus;
    _transcriptErrorMessage = widget.item.transcriptErrorMessage;
    _bindPlayer();
    unawaited(_loadAudio());
    unawaited(_loadTranscript());
  }

  @override
  void didUpdateWidget(covariant _PodcastCaptionPlayer oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.item.audioUrl != widget.item.audioUrl) {
      unawaited(_loadAudio());
    }
    if (oldWidget.item.id != widget.item.id) {
      _trackMetas = widget.item.transcripts;
      _activeTrack = null;
      _transcriptStatus = widget.item.transcriptStatus;
      _transcriptErrorMessage = widget.item.transcriptErrorMessage;
      unawaited(_loadTranscript());
    }
  }

  @override
  void dispose() {
    _pollTimer?.cancel();
    unawaited(_player.dispose());
    super.dispose();
  }

  void _bindPlayer() {
    _player.positionStream.listen((position) {
      if (!mounted) return;
      setState(() => _position = position);
    });
    _player.durationStream.listen((duration) {
      if (!mounted || duration == null) return;
      setState(() => _duration = duration);
    });
    _player.playerStateStream.listen((state) {
      if (!mounted) return;
      setState(() {
        _playing = state.playing;
        if (state.processingState == ProcessingState.completed) {
          _position = Duration.zero;
          _playing = false;
        }
      });
    });
  }

  Future<void> _loadAudio() async {
    setState(() {
      _loadingAudio = true;
      _position = Duration.zero;
      _duration = Duration.zero;
    });
    try {
      await _player.setUrl(resolveMediaUrl(widget.item.audioUrl));
      if (!mounted) return;
      setState(() {
        _duration = _player.duration ?? Duration.zero;
        _loadingAudio = false;
      });
    } catch (_) {
      if (!mounted) return;
      setState(() => _loadingAudio = false);
    }
  }

  ContentTranscriptTrack? _preferredTrackMeta({String? preferredLanguageCode}) {
    final preferredCode = preferredLanguageCode?.trim() ?? '';
    if (preferredCode.isNotEmpty) {
      for (final track in _trackMetas) {
        if (track.languageCode == preferredCode) return track;
      }
    }
    return _trackMetas.cast<ContentTranscriptTrack?>().firstWhere(
      (track) => track?.isSource == true,
      orElse: () => _trackMetas.isEmpty ? null : _trackMetas.first,
    );
  }

  Future<void> _loadTranscript({String? preferredLanguageCode}) async {
    final contentId = widget.item.id.trim();
    if (contentId.isEmpty) return;
    setState(() => _loadingTranscript = true);
    try {
      final repo = ref.read(contentRepositoryProvider);
      final metas = _trackMetas.isEmpty
          ? await repo.fetchPodcastTranscripts(contentId)
          : _trackMetas;
      _trackMetas = metas;
      final preferred = _preferredTrackMeta(
        preferredLanguageCode:
            preferredLanguageCode ?? _activeTrack?.languageCode,
      );
      ContentTranscriptTrack? loadedTrack = _activeTrack;
      if (preferred != null) {
        loadedTrack = await repo.fetchPodcastTranscriptTrack(
          contentId: contentId,
          languageCode: preferred.languageCode,
        );
      }
      if (!mounted) return;
      setState(() {
        _activeTrack = loadedTrack;
        _transcriptStatus = loadedTrack == null ? _transcriptStatus : 'ready';
        _transcriptErrorMessage = loadedTrack == null
            ? _transcriptErrorMessage
            : '';
        _loadingTranscript = false;
      });
      if (_trackMetas.isEmpty && _transcriptStatus == 'none') {
        unawaited(_requestTranscriptGeneration());
      } else {
        _syncPolling();
      }
    } catch (error) {
      if (!mounted) return;
      setState(() {
        _loadingTranscript = false;
        _transcriptErrorMessage = userFriendlyMessageFromObject(error);
      });
    }
  }

  void _syncPolling() {
    final shouldPoll = _activeTrack == null && _isTranscriptProcessing;
    if (!shouldPoll) {
      _pollTimer?.cancel();
      _pollTimer = null;
      return;
    }
    _pollTimer ??= Timer(const Duration(seconds: 3), () {
      _pollTimer = null;
      unawaited(_pollTranscriptState());
    });
  }

  Future<void> _pollTranscriptState() async {
    try {
      final repo = ref.read(contentRepositoryProvider);
      final metas = await repo.fetchPodcastTranscripts(widget.item.id);
      if (metas.isNotEmpty) {
        _trackMetas = metas;
        await _loadTranscript(
          preferredLanguageCode: _activeTrack?.languageCode,
        );
        return;
      }
      final result = await repo.generatePodcastTranscript(widget.item.id);
      if (!mounted) return;
      setState(() {
        _transcriptStatus = result.status;
        _loadingTranscript = false;
        if (result.track != null) {
          _activeTrack = result.track;
          _trackMetas = <ContentTranscriptTrack>[result.track!];
          _transcriptStatus = 'ready';
          _transcriptErrorMessage = '';
        }
      });
      _syncPolling();
    } catch (error) {
      if (!mounted) return;
      setState(() {
        _loadingTranscript = false;
        _transcriptErrorMessage = userFriendlyMessageFromObject(error);
      });
    }
  }

  Future<void> _requestTranscriptGeneration() async {
    if (_loadingTranscript && _isTranscriptProcessing) return;
    setState(() => _loadingTranscript = true);
    try {
      final result = await ref
          .read(contentRepositoryProvider)
          .generatePodcastTranscript(widget.item.id);
      if (!mounted) return;
      setState(() {
        _transcriptStatus = result.status;
        _loadingTranscript = false;
        if (result.track != null) {
          _activeTrack = result.track;
          _trackMetas = <ContentTranscriptTrack>[result.track!];
          _transcriptStatus = 'ready';
          _transcriptErrorMessage = '';
        }
      });
      _syncPolling();
    } catch (error) {
      if (!mounted) return;
      setState(() {
        _loadingTranscript = false;
        _transcriptErrorMessage = userFriendlyMessageFromObject(error);
      });
    }
  }

  Future<void> _togglePlayback() async {
    if (_loadingAudio) return;
    if (_player.playing) {
      await _player.pause();
      return;
    }
    if (_player.processingState == ProcessingState.completed) {
      await _player.seek(Duration.zero);
    }
    await _player.play();
  }

  Future<void> _seekToMilliseconds(int milliseconds) async {
    await _player.seek(Duration(milliseconds: milliseconds));
    if (!_player.playing) {
      await _player.play();
    }
  }

  Future<void> _selectTrackLanguage(String languageCode) async {
    setState(() => _loadingTranscript = true);
    try {
      final track = await ref
          .read(contentRepositoryProvider)
          .fetchPodcastTranscriptTrack(
            contentId: widget.item.id,
            languageCode: languageCode,
          );
      if (!mounted) return;
      setState(() {
        _activeTrack = track;
        _transcriptStatus = 'ready';
        _transcriptErrorMessage = '';
        _loadingTranscript = false;
      });
    } catch (error) {
      if (!mounted) return;
      setState(() {
        _loadingTranscript = false;
        _transcriptErrorMessage = userFriendlyMessageFromObject(error);
      });
    }
  }

  Future<void> _translateTranscript() async {
    if (_translating || _activeTrack == null) return;
    final choice = await showModalBottomSheet<String>(
      context: context,
      showDragHandle: true,
      builder: (context) {
        final existingLanguages = {
          for (final track in _trackMetas) track.languageCode,
          if (_activeTrack != null) _activeTrack!.languageCode,
        };
        return _TalkizWebFrame(
          maxWidth: _talkizWebSheetMaxWidth,
          child: SafeArea(
            child: ListView(
              shrinkWrap: true,
              children: [
                for (final option in appLanguageOptions)
                  if (option.locale != null)
                    ListTile(
                      title: Text(option.label),
                      trailing:
                          existingLanguages.contains(
                            option.locale!.languageCode,
                          )
                          ? const Icon(Icons.check_circle_outline)
                          : null,
                      onTap: () => Navigator.of(
                        context,
                      ).pop(option.locale!.languageCode),
                    ),
              ],
            ),
          ),
        );
      },
    );
    if (choice == null || choice.isEmpty) return;
    setState(() => _translating = true);
    try {
      final track = await ref
          .read(contentRepositoryProvider)
          .translatePodcastTranscript(
            contentId: widget.item.id,
            languageCode: choice,
          );
      if (!mounted) return;
      setState(() {
        _activeTrack = track;
        _trackMetas = [
          ..._trackMetas.where(
            (meta) => meta.languageCode != track.languageCode,
          ),
          track,
        ];
        _transcriptStatus = 'ready';
        _transcriptErrorMessage = '';
      });
    } catch (error) {
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text(userFriendlyMessageFromObject(error))),
      );
    } finally {
      if (mounted) setState(() => _translating = false);
    }
  }

  Future<void> _editTranscript() async {
    final track = _activeTrack;
    if (!widget.isOwner || track == null) return;
    final updated = await Navigator.of(context).push<ContentTranscriptTrack>(
      MaterialPageRoute<ContentTranscriptTrack>(
        builder: (context) => ContentTranscriptEditorScreen(
          videoId: widget.item.id,
          title: widget.item.title,
          track: track,
          contentKind: 'podcast',
        ),
      ),
    );
    if (!mounted || updated == null) return;
    setState(() {
      _activeTrack = updated;
      _trackMetas = [
        ..._trackMetas.where(
          (meta) => meta.languageCode != updated.languageCode,
        ),
        updated,
      ];
      _transcriptStatus = 'ready';
      _transcriptErrorMessage = '';
    });
  }

  ContentTranscriptSegment? _captionAtMilliseconds(int positionMs) {
    final track = _activeTrack;
    if (track == null || track.segments.isEmpty) return null;
    final effectivePositionMs = _subtitleMatchPositionMs(positionMs);
    for (final segment in track.segments) {
      if (effectivePositionMs >= segment.startMs &&
          effectivePositionMs <= segment.endMs) {
        return segment;
      }
    }
    return null;
  }

  String _formatDuration(Duration value) {
    final totalSeconds = value.inSeconds;
    final hours = totalSeconds ~/ 3600;
    final minutes = (totalSeconds % 3600) ~/ 60;
    final seconds = totalSeconds % 60;
    if (hours > 0) {
      return '${hours.toString()}:${minutes.toString().padLeft(2, '0')}:${seconds.toString().padLeft(2, '0')}';
    }
    return '${minutes.toString()}:${seconds.toString().padLeft(2, '0')}';
  }

  Future<void> _openFullTranscript() async {
    await showModalBottomSheet<void>(
      context: context,
      isScrollControlled: true,
      showDragHandle: true,
      useSafeArea: true,
      backgroundColor: Theme.of(context).colorScheme.surface,
      builder: (context) => FractionallySizedBox(
        heightFactor: 0.92,
        child: _PodcastTranscriptSheet(
          title: widget.item.title,
          track: _activeTrack,
          trackMetas: _trackMetas,
          status: _transcriptStatus,
          errorMessage: _transcriptErrorMessage,
          isOwner: widget.isOwner,
          positionStream: _player.positionStream,
          onSelectTrack: _selectTrackLanguage,
          onTranslate: _translateTranscript,
          onEdit: _editTranscript,
          onSeek: _seekToMilliseconds,
        ),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final duration = _duration;
    final durationMs = duration.inMilliseconds;
    final sliderMax = durationMs <= 0 ? 1.0 : durationMs.toDouble();
    final sliderValue = _position.inMilliseconds
        .clamp(0, durationMs <= 0 ? 0 : durationMs)
        .toDouble();
    final caption = _captionAtMilliseconds(_position.inMilliseconds);
    final subtitleText = caption?.text.trim() ?? '';
    final showSubtitleText = subtitleText.isNotEmpty;
    final languages = {
      for (final track in _trackMetas) track.languageCode,
      if (_activeTrack != null) _activeTrack!.languageCode,
    }.toList()..sort();

    return DecoratedBox(
      decoration: BoxDecoration(
        color: scheme.surfaceContainerHighest.withValues(alpha: 0.72),
        borderRadius: BorderRadius.circular(18),
        border: Border.all(color: scheme.outlineVariant),
      ),
      child: Padding(
        padding: const EdgeInsets.fromLTRB(12, 12, 12, 14),
        child: Column(
          children: [
            Row(
              children: [
                IconButton.filledTonal(
                  onPressed: _togglePlayback,
                  icon: Icon(
                    _loadingAudio
                        ? Icons.hourglass_empty_outlined
                        : _playing
                        ? Icons.pause_rounded
                        : Icons.play_arrow_rounded,
                  ),
                ),
                const SizedBox(width: 10),
                Expanded(
                  child: Column(
                    children: [
                      Slider(
                        value: sliderValue.clamp(0, sliderMax),
                        min: 0,
                        max: sliderMax,
                        onChanged: durationMs <= 0
                            ? null
                            : (value) => unawaited(
                                _player.seek(
                                  Duration(milliseconds: value.round()),
                                ),
                              ),
                      ),
                      Row(
                        children: [
                          Text(
                            _formatDuration(_position),
                            style: Theme.of(context).textTheme.bodySmall,
                          ),
                          const Spacer(),
                          Text(
                            _formatDuration(duration),
                            style: Theme.of(context).textTheme.bodySmall,
                          ),
                        ],
                      ),
                    ],
                  ),
                ),
              ],
            ),
            const SizedBox(height: 8),
            AnimatedSwitcher(
              duration: const Duration(milliseconds: 180),
              child: showSubtitleText
                  ? Container(
                      key: ValueKey<String>(
                        '${caption!.startMs}:${caption.text}',
                      ),
                      width: double.infinity,
                      padding: const EdgeInsets.symmetric(
                        horizontal: 12,
                        vertical: 10,
                      ),
                      decoration: BoxDecoration(
                        color: scheme.primaryContainer.withValues(alpha: 0.45),
                        borderRadius: BorderRadius.circular(14),
                      ),
                      child: Text(
                        subtitleText,
                        textAlign: TextAlign.center,
                        style: Theme.of(context).textTheme.bodyLarge?.copyWith(
                          fontWeight: FontWeight.w800,
                          height: 1.35,
                        ),
                      ),
                    )
                  : Text(
                      _loadingTranscript || _isTranscriptProcessing
                          ? 'Generating subtitles…'
                          : _activeTrack == null
                          ? (_transcriptErrorMessage.trim().isNotEmpty
                                ? _transcriptErrorMessage.trim()
                                : 'Subtitles unavailable')
                          : 'No subtitle at this point.',
                      key: ValueKey<String>(
                        'podcast-subtitle-$_transcriptStatus-${_activeTrack?.id ?? ''}',
                      ),
                      textAlign: TextAlign.center,
                      style: Theme.of(context).textTheme.bodyMedium?.copyWith(
                        color: scheme.onSurfaceVariant,
                        fontWeight: FontWeight.w700,
                      ),
                    ),
            ),
            const SizedBox(height: 12),
            Row(
              children: [
                if (languages.isNotEmpty)
                  Expanded(
                    child: DropdownButtonFormField<String>(
                      key: ValueKey<String?>(_activeTrack?.languageCode),
                      initialValue:
                          languages.contains(_activeTrack?.languageCode)
                          ? _activeTrack?.languageCode
                          : null,
                      isExpanded: true,
                      decoration: const InputDecoration(
                        labelText: 'Subtitle language',
                        border: OutlineInputBorder(),
                        isDense: true,
                      ),
                      items: [
                        for (final language in languages)
                          DropdownMenuItem<String>(
                            value: language,
                            child: Text(_languageLabel(language)),
                          ),
                      ],
                      onChanged: _loadingTranscript
                          ? null
                          : (language) {
                              if (language == null) return;
                              unawaited(_selectTrackLanguage(language));
                            },
                    ),
                  )
                else
                  const Spacer(),
                const SizedBox(width: 10),
                OutlinedButton.icon(
                  onPressed: _openFullTranscript,
                  icon: const Icon(Icons.subtitles_rounded),
                  label: const Text('Full subtitles'),
                ),
              ],
            ),
          ],
        ),
      ),
    );
  }
}

class _PodcastTranscriptSheet extends StatelessWidget {
  const _PodcastTranscriptSheet({
    required this.title,
    required this.track,
    required this.trackMetas,
    required this.status,
    required this.errorMessage,
    required this.isOwner,
    required this.positionStream,
    required this.onSelectTrack,
    required this.onTranslate,
    required this.onEdit,
    required this.onSeek,
  });

  final String title;
  final ContentTranscriptTrack? track;
  final List<ContentTranscriptTrack> trackMetas;
  final String status;
  final String errorMessage;
  final bool isOwner;
  final Stream<Duration> positionStream;
  final Future<void> Function(String languageCode) onSelectTrack;
  final Future<void> Function() onTranslate;
  final Future<void> Function() onEdit;
  final Future<void> Function(int milliseconds) onSeek;

  int _activeSegmentIndexAtMilliseconds(int positionMs) {
    final activeTrack = track;
    if (activeTrack == null || activeTrack.segments.isEmpty) return -1;
    final effectivePositionMs = _subtitleMatchPositionMs(positionMs);
    for (var i = 0; i < activeTrack.segments.length; i++) {
      final segment = activeTrack.segments[i];
      if (effectivePositionMs >= segment.startMs &&
          effectivePositionMs <= segment.endMs) {
        return i;
      }
    }
    return -1;
  }

  String _formatMs(int ms) {
    final totalSeconds = ms ~/ 1000;
    final minutes = totalSeconds ~/ 60;
    final seconds = totalSeconds % 60;
    return '${minutes.toString().padLeft(2, '0')}:${seconds.toString().padLeft(2, '0')}';
  }

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final languages = {
      for (final meta in trackMetas) meta.languageCode,
      if (track != null) track!.languageCode,
    }.toList()..sort();
    return _TalkizWebFrame(
      maxWidth: _talkizWebSheetMaxWidth,
      expandHeight: true,
      child: Scaffold(
        backgroundColor: scheme.surface,
        body: SafeArea(
          child: Column(
            children: [
              Padding(
                padding: const EdgeInsets.fromLTRB(20, 8, 20, 8),
                child: Row(
                  children: [
                    Expanded(
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Text(
                            'Subtitles',
                            style: Theme.of(context).textTheme.titleLarge
                                ?.copyWith(fontWeight: FontWeight.w800),
                          ),
                          if (title.trim().isNotEmpty)
                            Text(
                              title.trim(),
                              maxLines: 1,
                              overflow: TextOverflow.ellipsis,
                              style: Theme.of(context).textTheme.bodySmall
                                  ?.copyWith(
                                    color: scheme.onSurfaceVariant,
                                    fontWeight: FontWeight.w600,
                                  ),
                            ),
                        ],
                      ),
                    ),
                    if (isOwner && track != null)
                      TextButton.icon(
                        onPressed: () => unawaited(onEdit()),
                        icon: const Icon(Icons.edit_note_rounded),
                        label: const Text('Edit'),
                      ),
                    IconButton(
                      onPressed: () => Navigator.of(context).pop(),
                      icon: const Icon(Icons.keyboard_arrow_down_rounded),
                    ),
                  ],
                ),
              ),
              if (languages.isNotEmpty)
                Padding(
                  padding: const EdgeInsets.fromLTRB(16, 0, 16, 12),
                  child: Row(
                    children: [
                      Expanded(
                        child: DropdownButtonFormField<String>(
                          key: ValueKey<String?>(track?.languageCode),
                          initialValue: languages.contains(track?.languageCode)
                              ? track?.languageCode
                              : null,
                          isExpanded: true,
                          decoration: const InputDecoration(
                            labelText: 'Subtitle language',
                            border: OutlineInputBorder(),
                            isDense: true,
                          ),
                          items: [
                            for (final language in languages)
                              DropdownMenuItem<String>(
                                value: language,
                                child: Text(_languageLabel(language)),
                              ),
                          ],
                          onChanged: (language) {
                            if (language == null) return;
                            unawaited(onSelectTrack(language));
                          },
                        ),
                      ),
                      if (isOwner) ...[
                        const SizedBox(width: 10),
                        OutlinedButton.icon(
                          onPressed: track == null
                              ? null
                              : () => unawaited(onTranslate()),
                          icon: const Icon(Icons.add_circle_outline_rounded),
                          label: const Text('Add language'),
                        ),
                      ],
                    ],
                  ),
                ),
              Expanded(
                child: track == null
                    ? Center(
                        child: Padding(
                          padding: const EdgeInsets.all(24),
                          child: Text(
                            status == 'pending' || status == 'processing'
                                ? 'Generating subtitles…'
                                : errorMessage.trim().isNotEmpty
                                ? errorMessage.trim()
                                : 'No transcript yet.',
                            textAlign: TextAlign.center,
                            style: Theme.of(context).textTheme.bodyMedium
                                ?.copyWith(color: scheme.onSurfaceVariant),
                          ),
                        ),
                      )
                    : StreamBuilder<Duration>(
                        stream: positionStream,
                        initialData: Duration.zero,
                        builder: (context, snapshot) {
                          final activeIndex = _activeSegmentIndexAtMilliseconds(
                            snapshot.data?.inMilliseconds ?? 0,
                          );
                          return ListView.builder(
                            padding: const EdgeInsets.fromLTRB(16, 8, 16, 24),
                            itemCount: track!.segments.length,
                            itemBuilder: (context, index) {
                              final segment = track!.segments[index];
                              final active = index == activeIndex;
                              return Padding(
                                padding: const EdgeInsets.only(bottom: 10),
                                child: Material(
                                  color: active
                                      ? scheme.primaryContainer
                                      : scheme.surfaceContainerLow,
                                  borderRadius: BorderRadius.circular(16),
                                  child: InkWell(
                                    borderRadius: BorderRadius.circular(16),
                                    onTap: () =>
                                        unawaited(onSeek(segment.startMs)),
                                    child: Padding(
                                      padding: const EdgeInsets.fromLTRB(
                                        14,
                                        12,
                                        14,
                                        12,
                                      ),
                                      child: Row(
                                        crossAxisAlignment:
                                            CrossAxisAlignment.start,
                                        children: [
                                          Text(
                                            _formatMs(segment.startMs),
                                            style: Theme.of(context)
                                                .textTheme
                                                .labelLarge
                                                ?.copyWith(
                                                  color: active
                                                      ? scheme
                                                            .onPrimaryContainer
                                                      : scheme.primary,
                                                  fontWeight: FontWeight.w800,
                                                ),
                                          ),
                                          const SizedBox(width: 12),
                                          Expanded(
                                            child: Text(
                                              segment.text,
                                              style: Theme.of(context)
                                                  .textTheme
                                                  .bodyMedium
                                                  ?.copyWith(
                                                    height: 1.4,
                                                    fontWeight: active
                                                        ? FontWeight.w800
                                                        : FontWeight.w600,
                                                  ),
                                            ),
                                          ),
                                        ],
                                      ),
                                    ),
                                  ),
                                ),
                              );
                            },
                          );
                        },
                      ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

class _AuthorHeader extends ConsumerStatefulWidget {
  const _AuthorHeader({
    required this.userId,
    required this.fallbackName,
    required this.fallbackUsername,
    required this.fallbackProfilePhotoUrl,
    required this.meta,
    required this.isOwner,
    required this.menuActions,
    required this.onMenuSelected,
  });

  final String userId;
  final String fallbackName;
  final String fallbackUsername;
  final String fallbackProfilePhotoUrl;
  final String meta;
  final bool isOwner;
  final List<_CardMenuAction> menuActions;
  final ValueChanged<_CardMenuAction> onMenuSelected;

  @override
  ConsumerState<_AuthorHeader> createState() => _AuthorHeaderState();
}

class _AuthorHeaderState extends ConsumerState<_AuthorHeader> {
  bool? _followingOverride;
  bool _followBusy = false;

  Future<void> _openProfile() async {
    final userId = widget.userId.trim();
    if (userId.isEmpty) return;
    await context.push('/app/profile/$userId');
  }

  Future<void> _toggleFollow() async {
    final userId = widget.userId.trim();
    if (widget.isOwner || userId.isEmpty || _followBusy) return;
    setState(() => _followBusy = true);
    try {
      final data = await ref
          .read(apiClientProvider)
          .postJson('/users/$userId/follow');
      if (!mounted) return;
      setState(() => _followingOverride = data['following'] == true);
      ref.invalidate(profileBaseProvider(userId));
    } catch (error) {
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text(userFriendlyMessageFromObject(error))),
      );
    } finally {
      if (mounted) {
        setState(() => _followBusy = false);
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final profile = ref.watch(profileBaseProvider(widget.userId));
    final user = profile.valueOrNull;
    final displayName = user?.displayName.trim().isNotEmpty == true
        ? user!.displayName.trim()
        : widget.fallbackName;
    final username = user?.username.trim().isNotEmpty == true
        ? user!.username.trim()
        : widget.fallbackUsername;
    final profilePhotoUrl = user?.profilePhotoUrl.trim().isNotEmpty == true
        ? user!.profilePhotoUrl.trim()
        : widget.fallbackProfilePhotoUrl;
    final following = _followingOverride ?? user?.isFollowing ?? false;

    return Row(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Expanded(
          child: InkWell(
            onTap: widget.userId.trim().isEmpty ? null : _openProfile,
            borderRadius: BorderRadius.circular(18),
            child: Padding(
              padding: const EdgeInsets.symmetric(vertical: 2),
              child: Row(
                children: [
                  AppAvatar(
                    label: displayName,
                    imageUrl: profilePhotoUrl,
                    radius: 22,
                  ),
                  const SizedBox(width: 12),
                  Expanded(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Text(
                          displayName,
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                          style: Theme.of(context).textTheme.titleSmall
                              ?.copyWith(fontWeight: FontWeight.w800),
                        ),
                        const SizedBox(height: 2),
                        Text(
                          [
                            if (username.isNotEmpty) '@$username',
                            widget.meta,
                          ].join(' · '),
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                          style: Theme.of(context).textTheme.bodySmall
                              ?.copyWith(
                                color: scheme.onSurfaceVariant,
                                fontWeight: FontWeight.w600,
                              ),
                        ),
                      ],
                    ),
                  ),
                ],
              ),
            ),
          ),
        ),
        if (!widget.isOwner && widget.userId.trim().isNotEmpty) ...[
          const SizedBox(width: 8),
          FilledButton.tonal(
            onPressed: _followBusy ? null : _toggleFollow,
            style: FilledButton.styleFrom(
              minimumSize: const Size(0, 36),
              padding: const EdgeInsets.symmetric(horizontal: 14),
            ),
            child: Text(following ? 'Following' : 'Follow'),
          ),
        ],
        PopupMenuButton<_CardMenuAction>(
          onSelected: widget.onMenuSelected,
          itemBuilder: (context) => [
            for (final action in widget.menuActions)
              PopupMenuItem<_CardMenuAction>(
                value: action,
                child: Text(switch (action) {
                  _CardMenuAction.edit => 'Edit post',
                  _CardMenuAction.delete => 'Delete post',
                  _CardMenuAction.hide => 'Hide post',
                }),
              ),
          ],
        ),
      ],
    );
  }
}

class _EngagementBar extends StatelessWidget {
  const _EngagementBar({
    required this.likedByMe,
    required this.likeCount,
    required this.commentCount,
    required this.viewCount,
    required this.likeBusy,
    required this.saved,
    required this.onLike,
    required this.onComments,
    required this.onShare,
    required this.onSave,
  });

  final bool likedByMe;
  final int likeCount;
  final int commentCount;
  final int viewCount;
  final bool likeBusy;
  final bool saved;
  final VoidCallback onLike;
  final VoidCallback onComments;
  final Future<void> Function(BuildContext context) onShare;
  final VoidCallback onSave;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final labelStyle = Theme.of(
      context,
    ).textTheme.labelLarge?.copyWith(fontWeight: FontWeight.w800);
    return Wrap(
      spacing: 12,
      runSpacing: 8,
      crossAxisAlignment: WrapCrossAlignment.center,
      children: [
        _MetricAction(
          icon: likedByMe
              ? Icons.favorite_rounded
              : Icons.favorite_border_rounded,
          label: _compactCount(likeCount),
          tooltip: likedByMe ? 'Unlike' : 'Like',
          activeColor: Colors.redAccent,
          active: likedByMe,
          disabled: likeBusy,
          onTap: onLike,
        ),
        _MetricAction(
          icon: Icons.mode_comment_outlined,
          label: _compactCount(commentCount),
          tooltip: 'Comments',
          onTap: onComments,
        ),
        Builder(
          builder: (buttonContext) => _MetricAction(
            icon: Icons.share_outlined,
            label: 'Share',
            tooltip: 'Share',
            onTap: () => unawaited(onShare(buttonContext)),
          ),
        ),
        _MetricAction(
          icon: saved ? Icons.bookmark_rounded : Icons.bookmark_border_rounded,
          label: saved ? 'Saved' : 'Save',
          tooltip: saved ? 'Remove from saved' : 'Save',
          active: saved,
          onTap: onSave,
        ),
        Text(
          '${_compactCount(viewCount)} views',
          style: labelStyle?.copyWith(color: scheme.onSurfaceVariant),
        ),
      ],
    );
  }
}

class _MetricAction extends StatelessWidget {
  const _MetricAction({
    required this.icon,
    required this.label,
    required this.tooltip,
    required this.onTap,
    this.active = false,
    this.disabled = false,
    this.activeColor,
  });

  final IconData icon;
  final String label;
  final String tooltip;
  final VoidCallback onTap;
  final bool active;
  final bool disabled;
  final Color? activeColor;

  @override
  Widget build(BuildContext context) {
    final color = active
        ? (activeColor ?? Theme.of(context).colorScheme.primary)
        : null;
    return Tooltip(
      message: tooltip,
      child: InkWell(
        onTap: disabled ? null : onTap,
        borderRadius: BorderRadius.circular(999),
        child: Padding(
          padding: const EdgeInsets.symmetric(horizontal: 2, vertical: 4),
          child: Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              Icon(icon, size: 22, color: color),
              const SizedBox(width: 5),
              Text(
                label,
                style: Theme.of(context).textTheme.labelLarge?.copyWith(
                  color: active ? color : null,
                  fontWeight: FontWeight.w800,
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

class _CommentsSheet extends ConsumerStatefulWidget {
  const _CommentsSheet({
    required this.contentId,
    required this.onCommentCountChanged,
  });

  final String contentId;
  final ValueChanged<int> onCommentCountChanged;

  @override
  ConsumerState<_CommentsSheet> createState() => _CommentsSheetState();
}

class _CommentsSheetState extends ConsumerState<_CommentsSheet> {
  final _controller = TextEditingController();
  final _focusNode = FocusNode();
  final List<ContentCommentItem> _comments = [];
  final Set<String> _expandedReplyParentIds = <String>{};
  ContentCommentItem? _replyingTo;
  bool _loading = true;
  bool _submitting = false;

  @override
  void initState() {
    super.initState();
    Future<void>.microtask(_loadComments);
  }

  @override
  void dispose() {
    _controller.dispose();
    _focusNode.dispose();
    super.dispose();
  }

  Future<void> _loadComments() async {
    try {
      final items = await ref
          .read(contentRepositoryProvider)
          .fetchComments(widget.contentId);
      if (!mounted) return;
      setState(() {
        _comments
          ..clear()
          ..addAll(items);
        _loading = false;
      });
      widget.onCommentCountChanged(_comments.length);
    } catch (e) {
      if (!mounted) return;
      setState(() => _loading = false);
      ScaffoldMessenger.of(
        context,
      ).showSnackBar(SnackBar(content: Text(userFriendlyMessageFromObject(e))));
    }
  }

  Future<void> _submitComment() async {
    final body = _controller.text.trim();
    if (body.isEmpty || _submitting) return;
    setState(() => _submitting = true);
    final replyTarget = _replyingTo;
    try {
      final result = await ref
          .read(contentRepositoryProvider)
          .addComment(
            contentId: widget.contentId,
            body: body,
            parentId: _replyingTo?.id,
          );
      if (!mounted) return;
      _controller.clear();
      setState(() {
        _comments.add(result.comment);
        if (replyTarget != null) {
          _expandedReplyParentIds.add(replyTarget.id);
        }
        _replyingTo = null;
      });
      widget.onCommentCountChanged(result.commentCount);
    } catch (e) {
      if (!mounted) return;
      ScaffoldMessenger.of(
        context,
      ).showSnackBar(SnackBar(content: Text(userFriendlyMessageFromObject(e))));
    } finally {
      if (mounted) setState(() => _submitting = false);
    }
  }

  void _startReply(ContentCommentItem comment) {
    setState(() => _replyingTo = comment);
    _focusNode.requestFocus();
  }

  void _toggleReplies(String commentId) {
    setState(() {
      if (!_expandedReplyParentIds.remove(commentId)) {
        _expandedReplyParentIds.add(commentId);
      }
    });
  }

  List<_ThreadedCommentNode> _flattenComments() {
    final byId = <String, ContentCommentItem>{
      for (final comment in _comments) comment.id: comment,
    };
    final childrenByParent = <String, List<ContentCommentItem>>{};
    final roots = <ContentCommentItem>[];
    for (final comment in _comments) {
      final parentId = comment.parentId?.trim() ?? '';
      if (parentId.isEmpty || !byId.containsKey(parentId)) {
        roots.add(comment);
        continue;
      }
      childrenByParent
          .putIfAbsent(parentId, () => <ContentCommentItem>[])
          .add(comment);
    }

    final flattened = <_ThreadedCommentNode>[];
    void visit(ContentCommentItem comment, int depth) {
      final replies =
          childrenByParent[comment.id] ?? const <ContentCommentItem>[];
      final repliesExpanded = _expandedReplyParentIds.contains(comment.id);
      flattened.add(
        _ThreadedCommentNode(
          comment: comment,
          depth: depth,
          replyCount: replies.length,
          repliesExpanded: repliesExpanded,
        ),
      );
      if (!repliesExpanded) {
        return;
      }
      for (final child in replies) {
        visit(child, depth + 1);
      }
    }

    for (final root in roots) {
      visit(root, 0);
    }
    return flattened;
  }

  Widget _buildThreadedList() {
    final nodes = _flattenComments();
    return RefreshIndicator(
      onRefresh: _loadComments,
      child: ListView.separated(
        padding: const EdgeInsets.fromLTRB(16, 4, 16, 12),
        itemCount: nodes.length,
        separatorBuilder: (context, index) => const SizedBox(height: 10),
        itemBuilder: (context, index) {
          final node = nodes[index];
          final indent = (node.depth * 18).clamp(0, 54).toDouble();
          return Padding(
            padding: EdgeInsets.only(left: indent),
            child: _CommentTile(
              comment: node.comment,
              depth: node.depth,
              replyCount: node.replyCount,
              repliesExpanded: node.repliesExpanded,
              onReply: () => _startReply(node.comment),
              onToggleReplies: node.replyCount == 0
                  ? null
                  : () => _toggleReplies(node.comment.id),
            ),
          );
        },
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final currentUser = ref.watch(sessionControllerProvider).user;
    final keyboardInset = MediaQuery.of(context).viewInsets.bottom;
    return _TalkizWebFrame(
      maxWidth: _talkizWebSheetMaxWidth,
      expandHeight: true,
      child: Scaffold(
        resizeToAvoidBottomInset: false,
        backgroundColor: scheme.surface,
        body: SafeArea(
          bottom: false,
          child: Column(
            children: [
              Padding(
                padding: const EdgeInsets.fromLTRB(20, 8, 20, 8),
                child: Row(
                  children: [
                    Text(
                      'Comments',
                      style: Theme.of(context).textTheme.titleLarge?.copyWith(
                        fontWeight: FontWeight.w800,
                      ),
                    ),
                    const SizedBox(width: 8),
                    if (!_loading && _comments.isNotEmpty)
                      Text(
                        _compactCount(_comments.length),
                        style: Theme.of(context).textTheme.titleMedium
                            ?.copyWith(
                              color: scheme.onSurfaceVariant,
                              fontWeight: FontWeight.w700,
                            ),
                      ),
                    const Spacer(),
                    IconButton(
                      onPressed: _loading
                          ? null
                          : () => unawaited(_loadComments()),
                      icon: const Icon(Icons.refresh_rounded),
                    ),
                    IconButton(
                      onPressed: () => Navigator.of(context).pop(),
                      icon: const Icon(Icons.keyboard_arrow_down_rounded),
                    ),
                  ],
                ),
              ),
              Expanded(
                child: _loading
                    ? const Center(child: CircularProgressIndicator())
                    : _comments.isEmpty
                    ? Center(
                        child: Text(
                          'No comments yet',
                          style: Theme.of(context).textTheme.titleMedium
                              ?.copyWith(
                                color: scheme.onSurfaceVariant,
                                fontWeight: FontWeight.w700,
                              ),
                        ),
                      )
                    : _buildThreadedList(),
              ),
              AnimatedPadding(
                duration: const Duration(milliseconds: 180),
                curve: Curves.easeOutCubic,
                padding: EdgeInsets.only(bottom: keyboardInset),
                child: DecoratedBox(
                  decoration: BoxDecoration(
                    color: scheme.surface,
                    border: Border(
                      top: BorderSide(color: scheme.outlineVariant),
                    ),
                  ),
                  child: SafeArea(
                    top: false,
                    minimum: const EdgeInsets.fromLTRB(16, 8, 16, 12),
                    child: Column(
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        if (_replyingTo != null)
                          Padding(
                            padding: const EdgeInsets.fromLTRB(4, 0, 0, 6),
                            child: Row(
                              children: [
                                Text(
                                  'Replying to ${_replyingTo!.authorName}',
                                  style: Theme.of(context).textTheme.bodySmall
                                      ?.copyWith(
                                        color: scheme.primary,
                                        fontWeight: FontWeight.w600,
                                      ),
                                ),
                                const Spacer(),
                                GestureDetector(
                                  onTap: () =>
                                      setState(() => _replyingTo = null),
                                  child: Icon(
                                    Icons.close,
                                    size: 16,
                                    color: scheme.onSurfaceVariant,
                                  ),
                                ),
                              ],
                            ),
                          ),
                        Row(
                          children: [
                            AppAvatar(
                              label: currentUser?.displayName ?? 'You',
                              imageUrl: currentUser?.profilePhotoUrl,
                              radius: 18,
                            ),
                            const SizedBox(width: 10),
                            Expanded(
                              child: TextField(
                                controller: _controller,
                                focusNode: _focusNode,
                                minLines: 1,
                                maxLines: 4,
                                textCapitalization:
                                    TextCapitalization.sentences,
                                decoration: const InputDecoration(
                                  hintText: 'Add a comment',
                                  border: OutlineInputBorder(),
                                ),
                              ),
                            ),
                            const SizedBox(width: 10),
                            FilledButton(
                              onPressed: _submitting ? null : _submitComment,
                              child: Text(_submitting ? '...' : 'Post'),
                            ),
                          ],
                        ),
                      ],
                    ),
                  ),
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

class _TranscriptSheetResult {
  const _TranscriptSheetResult({
    required this.track,
    required this.status,
    required this.errorMessage,
  });

  final ContentTranscriptTrack? track;
  final String status;
  final String errorMessage;
}

class _TranscriptSheet extends ConsumerStatefulWidget {
  const _TranscriptSheet({
    required this.contentId,
    required this.title,
    required this.initialTrack,
    required this.initialStatus,
    required this.initialErrorMessage,
    required this.videoController,
    this.onChanged,
  });

  final String contentId;
  final String title;
  final ContentTranscriptTrack? initialTrack;
  final String initialStatus;
  final String initialErrorMessage;
  final VideoPlayerController? videoController;
  final ValueChanged<_TranscriptSheetResult>? onChanged;

  @override
  ConsumerState<_TranscriptSheet> createState() => _TranscriptSheetState();
}

class _TranscriptSheetState extends ConsumerState<_TranscriptSheet> {
  ContentTranscriptTrack? _activeTrack;
  ContentVideoDetail? _detail;
  final ScrollController _scrollController = ScrollController();
  List<GlobalKey> _segmentKeys = const <GlobalKey>[];
  Timer? _pollTimer;
  Timer? _resumeAutoFollowTimer;
  int? _lastAutoFollowIndex;
  bool _loading = true;
  bool _loadingTrack = false;
  bool _suspendAutoFollow = false;
  bool _translating = false;
  String _status = 'none';
  String _errorMessage = '';

  bool get _isOwner {
    final userId = ref.read(sessionControllerProvider).user?.id;
    return userId != null && userId.isNotEmpty && userId == _detail?.userId;
  }

  bool get _isProcessing => _status == 'pending' || _status == 'processing';

  AppLanguageOption? _languageOptionForCode(String code) {
    final normalized = code.trim().toLowerCase();
    for (final option in appLanguageOptions) {
      final locale = option.locale;
      if (locale == null) continue;
      if (locale.languageCode.toLowerCase() == normalized) {
        return option;
      }
    }
    return null;
  }

  String _languageLabel(String code) {
    return _languageOptionForCode(code)?.label ?? code.toUpperCase();
  }

  void _notifyParent() {
    widget.onChanged?.call(
      _TranscriptSheetResult(
        track: _activeTrack,
        status: _status,
        errorMessage: _errorMessage,
      ),
    );
  }

  @override
  void initState() {
    super.initState();
    _activeTrack = widget.initialTrack;
    _status = widget.initialStatus;
    _errorMessage = widget.initialErrorMessage;
    unawaited(_load());
  }

  @override
  void dispose() {
    _pollTimer?.cancel();
    _resumeAutoFollowTimer?.cancel();
    _scrollController.dispose();
    super.dispose();
  }

  void _ensureSegmentKeys(int count) {
    if (_segmentKeys.length == count) return;
    _segmentKeys = List<GlobalKey>.generate(
      count,
      (index) => GlobalKey(debugLabel: 'transcript-sheet-segment-$index'),
    );
  }

  int _activeSegmentIndexAtMilliseconds(int positionMs) {
    final track = _activeTrack;
    if (track == null || track.segments.isEmpty) return -1;
    final effectivePositionMs = _subtitleMatchPositionMs(positionMs);
    for (var i = 0; i < track.segments.length; i++) {
      final segment = track.segments[i];
      if (effectivePositionMs >= segment.startMs &&
          effectivePositionMs <= segment.endMs) {
        return i;
      }
    }
    return -1;
  }

  bool _isRowWithinReadingBand(BuildContext rowContext) {
    final rowBox = rowContext.findRenderObject() as RenderBox?;
    final scrollBox =
        _scrollController.position.context.storageContext.findRenderObject()
            as RenderBox?;
    if (rowBox == null || scrollBox == null) return false;
    final top = rowBox.localToGlobal(Offset.zero, ancestor: scrollBox).dy;
    final bottom = top + rowBox.size.height;
    final viewportHeight = scrollBox.size.height;
    final minBand = viewportHeight * 0.18;
    final maxBand = viewportHeight * 0.62;
    return top >= minBand && bottom <= maxBand;
  }

  void _scrollActiveSegmentIntoView(int index) {
    if (!mounted ||
        _suspendAutoFollow ||
        !_scrollController.hasClients ||
        index < 0 ||
        index >= _segmentKeys.length) {
      return;
    }
    final rowContext = _segmentKeys[index].currentContext;
    if (rowContext == null) return;
    if (_isRowWithinReadingBand(rowContext)) return;
    unawaited(
      Scrollable.ensureVisible(
        rowContext,
        alignment: 0.28,
        duration: const Duration(milliseconds: 260),
        curve: Curves.easeOutCubic,
      ),
    );
  }

  void _handleActiveSegmentChanged(int index) {
    if (index < 0 || _lastAutoFollowIndex == index) return;
    _lastAutoFollowIndex = index;
    WidgetsBinding.instance.addPostFrameCallback((_) {
      _scrollActiveSegmentIntoView(index);
    });
  }

  bool _handleTranscriptScrollNotification(ScrollNotification notification) {
    if (notification is ScrollStartNotification &&
        notification.dragDetails != null) {
      _resumeAutoFollowTimer?.cancel();
      _suspendAutoFollow = true;
    } else if (notification is ScrollUpdateNotification &&
        notification.dragDetails != null) {
      _resumeAutoFollowTimer?.cancel();
      _suspendAutoFollow = true;
    } else if (notification is ScrollEndNotification && _suspendAutoFollow) {
      _resumeAutoFollowTimer?.cancel();
      _resumeAutoFollowTimer = Timer(const Duration(milliseconds: 1400), () {
        if (!mounted) return;
        _suspendAutoFollow = false;
        final controller = widget.videoController;
        final positionMs = controller?.value.position.inMilliseconds ?? 0;
        final activeIndex = _activeSegmentIndexAtMilliseconds(positionMs);
        if (activeIndex >= 0) {
          _lastAutoFollowIndex = activeIndex;
          WidgetsBinding.instance.addPostFrameCallback((_) {
            _scrollActiveSegmentIntoView(activeIndex);
          });
        }
      });
    }
    return false;
  }

  ContentTranscriptTrack? _preferredTrackMeta(
    ContentVideoDetail detail, {
    String? preferredLanguageCode,
  }) {
    final preferredCode = preferredLanguageCode?.trim() ?? '';
    if (preferredCode.isNotEmpty) {
      for (final track in detail.transcripts) {
        if (track.languageCode == preferredCode) {
          return track;
        }
      }
    }
    return detail.transcripts.cast<ContentTranscriptTrack?>().firstWhere(
      (track) => track?.isSource == true,
      orElse: () =>
          detail.transcripts.isEmpty ? null : detail.transcripts.first,
    );
  }

  void _syncPolling(ContentVideoDetail detail) {
    final shouldPoll =
        detail.transcripts.isEmpty &&
        (detail.transcriptStatus == 'pending' ||
            detail.transcriptStatus == 'processing');
    if (!shouldPoll) {
      _pollTimer?.cancel();
      _pollTimer = null;
      return;
    }
    _pollTimer ??= Timer(const Duration(seconds: 3), () {
      _pollTimer = null;
      unawaited(_load(preferredLanguageCode: _activeTrack?.languageCode));
    });
  }

  Future<void> _load({String? preferredLanguageCode}) async {
    try {
      final repo = ref.read(contentRepositoryProvider);
      final detail = await repo.fetchVideoDetail(widget.contentId);
      final preferred = _preferredTrackMeta(
        detail,
        preferredLanguageCode:
            preferredLanguageCode ?? _activeTrack?.languageCode,
      );
      ContentTranscriptTrack? loadedTrack = _activeTrack;
      if (preferred != null) {
        loadedTrack = await repo.fetchVideoTranscriptTrack(
          contentId: widget.contentId,
          languageCode: preferred.languageCode,
        );
      }
      if (!mounted) return;
      setState(() {
        _detail = detail;
        _activeTrack = loadedTrack;
        _status = detail.transcriptStatus;
        _errorMessage = detail.transcriptErrorMessage;
        _loading = false;
      });
      _notifyParent();
      _syncPolling(detail);
    } catch (error) {
      if (!mounted) return;
      setState(() {
        _loading = false;
        _errorMessage = userFriendlyMessageFromObject(error);
      });
    }
  }

  Future<void> _selectTrackLanguage(String languageCode) async {
    if (_loadingTrack) return;
    setState(() => _loadingTrack = true);
    try {
      final track = await ref
          .read(contentRepositoryProvider)
          .fetchVideoTranscriptTrack(
            contentId: widget.contentId,
            languageCode: languageCode,
          );
      if (!mounted) return;
      setState(() => _activeTrack = track);
      _notifyParent();
    } catch (error) {
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text(userFriendlyMessageFromObject(error))),
      );
    } finally {
      if (mounted) setState(() => _loadingTrack = false);
    }
  }

  Future<void> _translateTranscript() async {
    if (_translating || _detail == null) return;
    final choice = await showModalBottomSheet<String>(
      context: context,
      showDragHandle: true,
      builder: (context) {
        final existingLanguages = {
          for (final track
              in _detail?.transcripts ?? const <ContentTranscriptTrack>[])
            track.languageCode,
        };
        return _TalkizWebFrame(
          maxWidth: _talkizWebSheetMaxWidth,
          child: SafeArea(
            child: ListView(
              shrinkWrap: true,
              children: [
                for (final option in appLanguageOptions)
                  if (option.locale != null)
                    ListTile(
                      title: Text(option.label),
                      trailing:
                          existingLanguages.contains(
                            option.locale!.languageCode,
                          )
                          ? const Icon(Icons.check_circle_outline)
                          : null,
                      onTap: () => Navigator.of(
                        context,
                      ).pop(option.locale!.languageCode),
                    ),
              ],
            ),
          ),
        );
      },
    );
    if (choice == null || choice.isEmpty) return;
    setState(() => _translating = true);
    try {
      final track = await ref
          .read(contentRepositoryProvider)
          .translateVideoTranscript(
            contentId: widget.contentId,
            languageCode: choice,
          );
      if (!mounted) return;
      setState(() => _activeTrack = track);
      _notifyParent();
      await _load(preferredLanguageCode: track.languageCode);
    } catch (error) {
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text(userFriendlyMessageFromObject(error))),
      );
    } finally {
      if (mounted) setState(() => _translating = false);
    }
  }

  Future<void> _editTranscript() async {
    final track = _activeTrack;
    if (!_isOwner || track == null) return;
    final updated = await Navigator.of(context).push<ContentTranscriptTrack>(
      MaterialPageRoute<ContentTranscriptTrack>(
        builder: (context) => ContentTranscriptEditorScreen(
          videoId: widget.contentId,
          title: widget.title,
          track: track,
        ),
      ),
    );
    if (!mounted || updated == null) return;
    setState(() => _activeTrack = updated);
    _notifyParent();
    await _load(preferredLanguageCode: updated.languageCode);
  }

  Future<void> _seekToSegment(ContentTranscriptSegment segment) async {
    final controller = widget.videoController;
    if (controller == null) return;
    await controller.seekTo(Duration(milliseconds: segment.startMs));
    if (!controller.value.isPlaying) {
      await controller.play();
    }
    if (mounted) setState(() {});
  }

  String _formatMs(int ms) {
    final totalSeconds = ms ~/ 1000;
    final minutes = totalSeconds ~/ 60;
    final seconds = totalSeconds % 60;
    return '${minutes.toString().padLeft(2, '0')}:${seconds.toString().padLeft(2, '0')}';
  }

  void _close() {
    Navigator.of(context).pop(
      _TranscriptSheetResult(
        track: _activeTrack,
        status: _status,
        errorMessage: _errorMessage,
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final transcriptLanguages = {
      for (final track
          in _detail?.transcripts ?? const <ContentTranscriptTrack>[])
        track.languageCode,
      if (_activeTrack != null) _activeTrack!.languageCode,
    }.toList()..sort();
    return _TalkizWebFrame(
      maxWidth: _talkizWebSheetMaxWidth,
      expandHeight: true,
      child: Scaffold(
        backgroundColor: scheme.surface,
        body: SafeArea(
          child: Column(
            children: [
              Padding(
                padding: const EdgeInsets.fromLTRB(20, 8, 20, 8),
                child: Row(
                  children: [
                    Expanded(
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Text(
                            'Subtitles',
                            style: Theme.of(context).textTheme.titleLarge
                                ?.copyWith(fontWeight: FontWeight.w800),
                          ),
                          if (widget.title.trim().isNotEmpty)
                            Text(
                              widget.title.trim(),
                              maxLines: 1,
                              overflow: TextOverflow.ellipsis,
                              style: Theme.of(context).textTheme.bodySmall
                                  ?.copyWith(
                                    color: scheme.onSurfaceVariant,
                                    fontWeight: FontWeight.w600,
                                  ),
                            ),
                        ],
                      ),
                    ),
                    if (_isOwner && _activeTrack != null)
                      TextButton.icon(
                        onPressed: _editTranscript,
                        icon: const Icon(Icons.edit_note_rounded),
                        label: const Text('Edit'),
                      ),
                    IconButton(
                      onPressed: _close,
                      icon: const Icon(Icons.keyboard_arrow_down_rounded),
                    ),
                  ],
                ),
              ),
              if (transcriptLanguages.isNotEmpty)
                Padding(
                  padding: const EdgeInsets.fromLTRB(16, 0, 16, 12),
                  child: Row(
                    children: [
                      Expanded(
                        child: DropdownButtonFormField<String>(
                          key: ValueKey<String?>(_activeTrack?.languageCode),
                          initialValue:
                              transcriptLanguages.contains(
                                _activeTrack?.languageCode,
                              )
                              ? _activeTrack?.languageCode
                              : null,
                          isExpanded: true,
                          decoration: const InputDecoration(
                            labelText: 'Subtitle language',
                            border: OutlineInputBorder(),
                            isDense: true,
                          ),
                          items: [
                            for (final language in transcriptLanguages)
                              DropdownMenuItem<String>(
                                value: language,
                                child: Text(_languageLabel(language)),
                              ),
                          ],
                          onChanged: _loadingTrack
                              ? null
                              : (language) {
                                  if (language == null) return;
                                  unawaited(_selectTrackLanguage(language));
                                },
                        ),
                      ),
                      if (_isOwner)
                        OutlinedButton.icon(
                          onPressed: _activeTrack == null || _translating
                              ? null
                              : _translateTranscript,
                          icon: const Icon(Icons.add_circle_outline_rounded),
                          label: Text(
                            _translating ? 'Adding…' : 'Add language',
                          ),
                        ),
                    ],
                  ),
                ),
              Expanded(
                child: _loading
                    ? const Center(child: CircularProgressIndicator())
                    : _activeTrack == null
                    ? Center(
                        child: Padding(
                          padding: const EdgeInsets.all(24),
                          child: Text(
                            _isProcessing
                                ? 'Generating subtitles…'
                                : _errorMessage.trim().isNotEmpty
                                ? _errorMessage.trim()
                                : 'No transcript yet.',
                            textAlign: TextAlign.center,
                            style: Theme.of(context).textTheme.bodyMedium
                                ?.copyWith(color: scheme.onSurfaceVariant),
                          ),
                        ),
                      )
                    : ValueListenableBuilder<VideoPlayerValue>(
                        valueListenable:
                            widget.videoController ??
                            ValueNotifier(
                              const VideoPlayerValue(duration: Duration.zero),
                            ),
                        builder: (context, value, _) {
                          final positionMs = value.position.inMilliseconds;
                          final activeIndex = _activeSegmentIndexAtMilliseconds(
                            positionMs,
                          );
                          _ensureSegmentKeys(_activeTrack!.segments.length);
                          _handleActiveSegmentChanged(activeIndex);
                          return NotificationListener<ScrollNotification>(
                            onNotification: _handleTranscriptScrollNotification,
                            child: ListView(
                              controller: _scrollController,
                              padding: const EdgeInsets.fromLTRB(16, 8, 16, 24),
                              children: [
                                for (
                                  var index = 0;
                                  index < _activeTrack!.segments.length;
                                  index++
                                ) ...[
                                  if (index > 0) const SizedBox(height: 8),
                                  KeyedSubtree(
                                    key: _segmentKeys[index],
                                    child: Builder(
                                      builder: (context) {
                                        final segment =
                                            _activeTrack!.segments[index];
                                        final active = index == activeIndex;
                                        return Material(
                                          color: active
                                              ? scheme.primaryContainer
                                              : scheme.surfaceContainerLow,
                                          borderRadius: BorderRadius.circular(
                                            18,
                                          ),
                                          child: InkWell(
                                            borderRadius: BorderRadius.circular(
                                              18,
                                            ),
                                            onTap: () =>
                                                _seekToSegment(segment),
                                            child: Padding(
                                              padding:
                                                  const EdgeInsets.fromLTRB(
                                                    14,
                                                    12,
                                                    14,
                                                    12,
                                                  ),
                                              child: Row(
                                                crossAxisAlignment:
                                                    CrossAxisAlignment.start,
                                                children: [
                                                  Container(
                                                    width: 4,
                                                    height: 44,
                                                    margin:
                                                        const EdgeInsets.only(
                                                          top: 2,
                                                        ),
                                                    decoration: BoxDecoration(
                                                      color: active
                                                          ? scheme.primary
                                                          : Colors.transparent,
                                                      borderRadius:
                                                          BorderRadius.circular(
                                                            999,
                                                          ),
                                                    ),
                                                  ),
                                                  const SizedBox(width: 12),
                                                  SizedBox(
                                                    width: 56,
                                                    child: Text(
                                                      _formatMs(
                                                        segment.startMs,
                                                      ),
                                                      style: Theme.of(context)
                                                          .textTheme
                                                          .labelMedium
                                                          ?.copyWith(
                                                            color: active
                                                                ? scheme
                                                                      .onPrimaryContainer
                                                                : scheme
                                                                      .onSurfaceVariant,
                                                            fontWeight:
                                                                FontWeight.w700,
                                                          ),
                                                    ),
                                                  ),
                                                  const SizedBox(width: 12),
                                                  Expanded(
                                                    child: Text(
                                                      segment.text,
                                                      style: Theme.of(context)
                                                          .textTheme
                                                          .bodyMedium
                                                          ?.copyWith(
                                                            color: active
                                                                ? scheme
                                                                      .onPrimaryContainer
                                                                : null,
                                                            fontWeight: active
                                                                ? FontWeight
                                                                      .w800
                                                                : FontWeight
                                                                      .w500,
                                                            height: 1.35,
                                                          ),
                                                    ),
                                                  ),
                                                ],
                                              ),
                                            ),
                                          ),
                                        );
                                      },
                                    ),
                                  ),
                                ],
                              ],
                            ),
                          );
                        },
                      ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

class _CommentTile extends ConsumerStatefulWidget {
  const _CommentTile({
    required this.comment,
    required this.onReply,
    required this.replyCount,
    required this.repliesExpanded,
    this.depth = 0,
    this.onToggleReplies,
  });

  final ContentCommentItem comment;
  final VoidCallback onReply;
  final int replyCount;
  final bool repliesExpanded;
  final int depth;
  final VoidCallback? onToggleReplies;

  @override
  ConsumerState<_CommentTile> createState() => _CommentTileState();
}

class _CommentTileState extends ConsumerState<_CommentTile> {
  late int _likeCount;
  late bool _likedByMe;
  bool _busy = false;

  @override
  void initState() {
    super.initState();
    _likeCount = widget.comment.likeCount;
    _likedByMe = widget.comment.likedByMe;
  }

  Future<void> _toggleLike() async {
    if (_busy) return;
    setState(() => _busy = true);
    try {
      final repo = ref.read(contentRepositoryProvider);
      final state = _likedByMe
          ? await repo.unlikeComment(widget.comment.id)
          : await repo.likeComment(widget.comment.id);
      if (mounted) {
        setState(() {
          _likeCount = state.likeCount;
          _likedByMe = state.likedByMe;
        });
      }
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final profile = ref.watch(profileBaseProvider(widget.comment.userId));
    final user = profile.valueOrNull;
    final displayName = user?.displayName.trim().isNotEmpty == true
        ? user!.displayName.trim()
        : widget.comment.authorName;
    final username = user?.username.trim() ?? '';
    return Row(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        AppAvatar(
          label: displayName,
          imageUrl: user?.profilePhotoUrl,
          radius: 18,
        ),
        const SizedBox(width: 12),
        Expanded(
          child: Container(
            padding: const EdgeInsets.fromLTRB(14, 12, 14, 10),
            decoration: BoxDecoration(
              color: widget.depth == 0
                  ? scheme.surfaceContainerLow
                  : scheme.surfaceContainerHighest,
              borderRadius: BorderRadius.circular(18),
            ),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  displayName,
                  style: Theme.of(
                    context,
                  ).textTheme.labelLarge?.copyWith(fontWeight: FontWeight.w800),
                ),
                if (username.isNotEmpty) ...[
                  const SizedBox(height: 2),
                  Text(
                    '@$username',
                    style: Theme.of(context).textTheme.labelSmall?.copyWith(
                      color: scheme.onSurfaceVariant,
                      fontWeight: FontWeight.w600,
                    ),
                  ),
                ],
                const SizedBox(height: 4),
                if (widget.comment.replyToName?.trim().isNotEmpty == true) ...[
                  Text(
                    'Replying to ${widget.comment.replyToName!.trim()}',
                    style: Theme.of(context).textTheme.labelSmall?.copyWith(
                      color: scheme.primary,
                      fontWeight: FontWeight.w700,
                    ),
                  ),
                  const SizedBox(height: 4),
                ],
                ContentLinkText(text: widget.comment.body),
                if (widget.comment.createdAt != null) ...[
                  const SizedBox(height: 6),
                  Text(
                    _dateLabel(widget.comment.createdAt!),
                    style: Theme.of(context).textTheme.bodySmall?.copyWith(
                      color: scheme.onSurfaceVariant,
                    ),
                  ),
                ],
                const SizedBox(height: 6),
                Row(
                  mainAxisAlignment: MainAxisAlignment.end,
                  children: [
                    if (widget.replyCount > 0) ...[
                      GestureDetector(
                        onTap: widget.onToggleReplies,
                        child: Text(
                          widget.repliesExpanded
                              ? 'Hide replies'
                              : widget.replyCount == 1
                              ? 'View 1 reply'
                              : 'View ${widget.replyCount} replies',
                          style: Theme.of(context).textTheme.bodySmall
                              ?.copyWith(
                                color: scheme.onSurfaceVariant,
                                fontWeight: FontWeight.w700,
                              ),
                        ),
                      ),
                      const SizedBox(width: 14),
                    ],
                    GestureDetector(
                      onTap: widget.onReply,
                      child: Text(
                        'Reply',
                        style: Theme.of(context).textTheme.bodySmall?.copyWith(
                          color: scheme.primary,
                          fontWeight: FontWeight.w700,
                        ),
                      ),
                    ),
                    const SizedBox(width: 14),
                    GestureDetector(
                      onTap: _busy ? null : _toggleLike,
                      child: Row(
                        mainAxisSize: MainAxisSize.min,
                        children: [
                          Icon(
                            _likedByMe
                                ? Icons.favorite_rounded
                                : Icons.favorite_border_rounded,
                            size: 15,
                            color: _likedByMe
                                ? Colors.redAccent
                                : scheme.onSurfaceVariant,
                          ),
                          if (_likeCount > 0) ...[
                            const SizedBox(width: 4),
                            Text(
                              '$_likeCount',
                              style: Theme.of(context).textTheme.bodySmall
                                  ?.copyWith(color: scheme.onSurfaceVariant),
                            ),
                          ],
                        ],
                      ),
                    ),
                  ],
                ),
              ],
            ),
          ),
        ),
      ],
    );
  }
}

class _ThreadedCommentNode {
  const _ThreadedCommentNode({
    required this.comment,
    required this.depth,
    required this.replyCount,
    required this.repliesExpanded,
  });

  final ContentCommentItem comment;
  final int depth;
  final int replyCount;
  final bool repliesExpanded;
}

class _PodcastCoverFallback extends StatelessWidget {
  const _PodcastCoverFallback({required this.title});

  final String title;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return DecoratedBox(
      decoration: BoxDecoration(
        gradient: LinearGradient(
          colors: [
            scheme.primary.withValues(alpha: 0.95),
            scheme.tertiary.withValues(alpha: 0.88),
          ],
          begin: Alignment.topLeft,
          end: Alignment.bottomRight,
        ),
      ),
      child: Center(
        child: Padding(
          padding: const EdgeInsets.all(24),
          child: Text(
            title,
            textAlign: TextAlign.center,
            maxLines: 3,
            overflow: TextOverflow.ellipsis,
            style: Theme.of(context).textTheme.headlineSmall?.copyWith(
              color: Colors.white,
              fontWeight: FontWeight.w900,
            ),
          ),
        ),
      ),
    );
  }
}

class _PostAssetCarousel extends StatefulWidget {
  const _PostAssetCarousel({
    required this.assets,
    this.onOpenDetail,
    this.onOpenVideo,
    this.onDoubleTapLike,
  });

  final List<ContentAssetItem> assets;
  final VoidCallback? onOpenDetail;
  final Future<void> Function(ContentAssetItem)? onOpenVideo;
  final VoidCallback? onDoubleTapLike;

  @override
  State<_PostAssetCarousel> createState() => _PostAssetCarouselState();
}

class _PostAssetCarouselState extends State<_PostAssetCarousel> {
  final _controller = PageController();
  int _page = 0;
  bool _showLikeBurst = false;
  Timer? _likeBurstTimer;

  @override
  void dispose() {
    _likeBurstTimer?.cancel();
    _controller.dispose();
    super.dispose();
  }

  void _handleDoubleTapLike() {
    widget.onDoubleTapLike?.call();
    _likeBurstTimer?.cancel();
    setState(() => _showLikeBurst = true);
    _likeBurstTimer = Timer(const Duration(milliseconds: 700), () {
      if (mounted) {
        setState(() => _showLikeBurst = false);
      }
    });
  }

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return Column(
      children: [
        LayoutBuilder(
          builder: (context, constraints) {
            final width = constraints.maxWidth.isFinite
                ? constraints.maxWidth
                : MediaQuery.sizeOf(context).width - 32;
            final firstAsset = widget.assets.isEmpty ? null : widget.assets[0];
            final isVideo = firstAsset?.isVideo == true;
            final aspectRatio = isVideo ? 9 / 16 : 1.0;
            final viewportHeight = MediaQuery.sizeOf(context).height;
            final maxHeight = isVideo
                ? math.max(480.0, viewportHeight - 96)
                : width >= 680
                ? 520.0
                : 460.0;
            final minHeight = isVideo ? math.min(420.0, maxHeight) : 280.0;
            final height = (width / aspectRatio).clamp(minHeight, maxHeight);
            return ClipRRect(
              borderRadius: BorderRadius.circular(16),
              child: SizedBox(
                height: height,
                child: Stack(
                  fit: StackFit.expand,
                  children: [
                    PageView.builder(
                      controller: _controller,
                      itemCount: widget.assets.length,
                      onPageChanged: (value) => setState(() => _page = value),
                      itemBuilder: (context, index) {
                        final asset = widget.assets[index];
                        if (asset.isImage) {
                          return GestureDetector(
                            onTap: widget.onOpenDetail,
                            onDoubleTap: _handleDoubleTapLike,
                            child: Image.network(
                              resolveMediaUrl(asset.url),
                              fit: BoxFit.cover,
                              loadingBuilder:
                                  (context, child, loadingProgress) =>
                                      loadingProgress == null
                                      ? child
                                      : const _MediaLoadingPlaceholder(),
                              errorBuilder: (context, error, stackTrace) =>
                                  _MediaErrorPlaceholder(
                                    label: 'Could not load this photo.',
                                    actionLabel: 'Open post',
                                    onTap: widget.onOpenDetail,
                                  ),
                            ),
                          );
                        }
                        return _InlineVideoTile(
                          asset: asset,
                          onDoubleTapLike: _handleDoubleTapLike,
                          onOpenFullscreen: widget.onOpenVideo == null
                              ? null
                              : () => widget.onOpenVideo!(asset),
                        );
                      },
                    ),
                    if (widget.assets.length > 1)
                      Positioned(
                        top: 12,
                        right: 12,
                        child: DecoratedBox(
                          decoration: BoxDecoration(
                            color: Colors.black.withValues(alpha: 0.58),
                            borderRadius: BorderRadius.circular(999),
                          ),
                          child: Padding(
                            padding: const EdgeInsets.symmetric(
                              horizontal: 10,
                              vertical: 6,
                            ),
                            child: Text(
                              '${_page + 1}/${widget.assets.length}',
                              style: const TextStyle(
                                color: Colors.white,
                                fontSize: 12,
                                fontWeight: FontWeight.w700,
                              ),
                            ),
                          ),
                        ),
                      ),
                    IgnorePointer(
                      child: AnimatedOpacity(
                        duration: const Duration(milliseconds: 180),
                        opacity: _showLikeBurst ? 1 : 0,
                        child: Center(
                          child: Container(
                            width: 92,
                            height: 92,
                            decoration: BoxDecoration(
                              shape: BoxShape.circle,
                              color: Colors.black.withValues(alpha: 0.22),
                            ),
                            child: const Icon(
                              Icons.favorite_rounded,
                              color: Colors.white,
                              size: 56,
                            ),
                          ),
                        ),
                      ),
                    ),
                  ],
                ),
              ),
            );
          },
        ),
        if (widget.assets.length > 1)
          Padding(
            padding: const EdgeInsets.only(top: 10),
            child: Row(
              mainAxisAlignment: MainAxisAlignment.center,
              children: List.generate(widget.assets.length, (index) {
                final active = index == _page;
                return AnimatedContainer(
                  duration: const Duration(milliseconds: 180),
                  margin: const EdgeInsets.symmetric(horizontal: 3),
                  width: active ? 18 : 7,
                  height: 7,
                  decoration: BoxDecoration(
                    borderRadius: BorderRadius.circular(99),
                    color: active
                        ? scheme.primary
                        : scheme.outlineVariant.withValues(alpha: 0.8),
                  ),
                );
              }),
            ),
          ),
      ],
    );
  }
}

class _InlineVideoTile extends StatefulWidget {
  const _InlineVideoTile({
    required this.asset,
    this.onOpenFullscreen,
    this.onDoubleTapLike,
  });

  final ContentAssetItem asset;
  final Future<void> Function()? onOpenFullscreen;
  final VoidCallback? onDoubleTapLike;

  @override
  State<_InlineVideoTile> createState() => _InlineVideoTileState();
}

class _InlineVideoTileState extends State<_InlineVideoTile> {
  SharedVideoPlayerLease? _lease;
  bool _initializing = false;
  bool _muted = true;
  bool _manualPause = false;
  bool _fullscreenOpen = false;
  double _visibleFraction = 0;
  String? _error;
  String _prefetchedPosterUrl = '';

  VideoPlayerController? get _controller => _lease?.controller;

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    _prefetchPoster();
  }

  @override
  void didUpdateWidget(covariant _InlineVideoTile oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.asset.posterUrl != widget.asset.posterUrl) {
      _prefetchedPosterUrl = '';
      _prefetchPoster();
    }
  }

  @override
  void dispose() {
    _lease?.release();
    _lease = null;
    super.dispose();
  }

  void _prefetchPoster() {
    final posterUrl = widget.asset.posterUrl.trim();
    if (posterUrl.isEmpty || posterUrl == _prefetchedPosterUrl) {
      return;
    }
    _prefetchedPosterUrl = posterUrl;
    final imageProvider = NetworkImage(resolveMediaUrl(posterUrl));
    unawaited(precacheImage(imageProvider, context).catchError((_) {}));
  }

  Future<void> _ensureController() async {
    if ((_lease?.isInitialized ?? false) || _initializing || _error != null) {
      return;
    }
    _initializing = true;
    try {
      _lease ??= await SharedVideoPlayerPool.instance.acquire(
        source: widget.asset.url,
        surface: SharedVideoSurface.inlinePreview,
        looping: true,
        initialVolume: 0,
      );
      final controller = await _lease!.ensureInitialized();
      if (!mounted) {
        _lease?.release();
        _lease = null;
        return;
      }
      _muted = controller.value.volume <= 0.001;
      setState(() {});
      await _syncPlayback();
    } catch (_) {
      if (!mounted) return;
      setState(() => _error = 'Could not play this video.');
    } finally {
      _initializing = false;
      if (mounted) {
        setState(() {});
      }
    }
  }

  Future<void> _syncPlayback() async {
    final controller = _controller;
    if (controller == null || !controller.value.isInitialized) return;
    if (_fullscreenOpen) return;
    if (_visibleFraction >= 0.65 && !_manualPause) {
      await controller.play();
    } else {
      await controller.pause();
    }
    if (mounted) {
      setState(() {});
    }
  }

  Future<void> _handleVisibility(VisibilityInfo info) async {
    _visibleFraction = info.visibleFraction;
    if (_visibleFraction >= 0.15) {
      await _ensureController();
    }
    if (_fullscreenOpen) return;
    await _syncPlayback();
  }

  Future<void> _togglePlayback() async {
    await _ensureController();
    final controller = _controller;
    if (controller == null || !controller.value.isInitialized) return;
    if (controller.value.isPlaying) {
      _manualPause = true;
      await controller.pause();
    } else {
      _manualPause = false;
      await controller.play();
    }
    if (mounted) {
      setState(() {});
    }
  }

  Future<void> _toggleMute() async {
    final controller = _controller;
    if (controller == null || !controller.value.isInitialized) return;
    _muted = !_muted;
    await controller.setVolume(_muted ? 0 : 1);
    if (mounted) {
      setState(() {});
    }
  }

  Future<void> _openFullscreen() async {
    final openFullscreen = widget.onOpenFullscreen;
    if (openFullscreen == null) return;
    _fullscreenOpen = true;
    try {
      final controller = _controller;
      if (controller != null && controller.value.isInitialized) {
        await controller.pause();
      }
      if (mounted) {
        setState(() {});
      }
      await openFullscreen();
    } finally {
      _fullscreenOpen = false;
      if (mounted) {
        await _syncPlayback();
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    final controller = _controller;
    final ready = controller != null && controller.value.isInitialized;
    return VisibilityDetector(
      key: Key('talkiz-inline-video-${widget.asset.url.hashCode}'),
      onVisibilityChanged: (info) => unawaited(_handleVisibility(info)),
      child: GestureDetector(
        onTap: _togglePlayback,
        onDoubleTap: widget.onDoubleTapLike,
        child: Stack(
          fit: StackFit.expand,
          children: [
            if (ready)
              ColoredBox(
                color: Colors.black,
                child: FittedBox(
                  fit: BoxFit.cover,
                  clipBehavior: Clip.hardEdge,
                  child: SizedBox(
                    width: controller.value.size.width,
                    height: controller.value.size.height,
                    child: VideoPlayer(controller),
                  ),
                ),
              )
            else if (_error != null)
              _MediaErrorPlaceholder(
                label: _error!,
                actionLabel: 'Open video',
                onTap: widget.onOpenFullscreen == null ? null : _openFullscreen,
              )
            else
              _VideoPosterPlaceholder(
                imageUrl: widget.asset.posterUrl,
                label: 'Preparing video…',
              ),
            Positioned(
              top: 12,
              left: 12,
              child: IconButton.filledTonal(
                onPressed: ready ? _toggleMute : null,
                style: IconButton.styleFrom(
                  backgroundColor: Colors.black.withValues(alpha: 0.44),
                  foregroundColor: Colors.white,
                ),
                icon: Icon(
                  _muted ? Icons.volume_off_rounded : Icons.volume_up_rounded,
                ),
              ),
            ),
            if (widget.onOpenFullscreen != null)
              Positioned(
                top: 12,
                right: 12,
                child: IconButton.filledTonal(
                  onPressed: _openFullscreen,
                  style: IconButton.styleFrom(
                    backgroundColor: Colors.black.withValues(alpha: 0.44),
                    foregroundColor: Colors.white,
                  ),
                  icon: const Icon(Icons.open_in_full_rounded),
                ),
              ),
            if (!ready || !controller.value.isPlaying)
              Center(
                child: Container(
                  width: 76,
                  height: 76,
                  decoration: BoxDecoration(
                    shape: BoxShape.circle,
                    color: Colors.black.withValues(alpha: 0.34),
                  ),
                  child: Icon(
                    _initializing
                        ? Icons.hourglass_top_rounded
                        : Icons.play_arrow_rounded,
                    color: Colors.white,
                    size: 42,
                  ),
                ),
              ),
          ],
        ),
      ),
    );
  }
}

class _MediaLoadingPlaceholder extends StatelessWidget {
  const _MediaLoadingPlaceholder();

  @override
  Widget build(BuildContext context) {
    return const DecoratedBox(
      decoration: BoxDecoration(
        gradient: LinearGradient(
          colors: [Color(0xFF151515), Color(0xFF2A2A2A)],
          begin: Alignment.topLeft,
          end: Alignment.bottomRight,
        ),
      ),
      child: Center(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            SizedBox(
              width: 28,
              height: 28,
              child: CircularProgressIndicator(strokeWidth: 2.4),
            ),
            SizedBox(height: 12),
            Text(
              'Loading media…',
              style: TextStyle(
                color: Colors.white70,
                fontWeight: FontWeight.w600,
              ),
            ),
          ],
        ),
      ),
    );
  }
}

class _MediaErrorPlaceholder extends StatelessWidget {
  const _MediaErrorPlaceholder({
    required this.label,
    this.actionLabel,
    this.onTap,
  });

  final String label;
  final String? actionLabel;
  final VoidCallback? onTap;

  @override
  Widget build(BuildContext context) {
    return DecoratedBox(
      decoration: const BoxDecoration(
        gradient: LinearGradient(
          colors: [Color(0xFF201818), Color(0xFF392424)],
          begin: Alignment.topLeft,
          end: Alignment.bottomRight,
        ),
      ),
      child: Center(
        child: Padding(
          padding: const EdgeInsets.all(24),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              const Icon(Icons.broken_image_outlined, color: Colors.white70),
              const SizedBox(height: 12),
              Text(
                label,
                textAlign: TextAlign.center,
                style: const TextStyle(
                  color: Colors.white,
                  fontWeight: FontWeight.w600,
                ),
              ),
              if (onTap != null && actionLabel != null) ...[
                const SizedBox(height: 14),
                FilledButton.tonal(onPressed: onTap, child: Text(actionLabel!)),
              ],
            ],
          ),
        ),
      ),
    );
  }
}

class _VideoPreviewSheet extends ConsumerStatefulWidget {
  const _VideoPreviewSheet({
    required this.contentId,
    required this.title,
    required this.source,
    this.posterUrl = '',
  });

  final String contentId;
  final String title;
  final String source;
  final String posterUrl;

  @override
  ConsumerState<_VideoPreviewSheet> createState() => _VideoPreviewSheetState();
}

class _VideoPreviewSheetState extends ConsumerState<_VideoPreviewSheet> {
  SharedVideoPlayerLease? _lease;
  ContentTranscriptTrack? _activeTrack;
  String? _preferredSubtitleLanguageCode;
  Timer? _transcriptPollTimer;
  int? _scrubDragMs;
  bool _resumeAfterScrub = false;
  DateTime? _lastPreviewScrubSeekAt;
  String _transcriptStatus = 'none';
  String _transcriptErrorMessage = '';
  bool _loadingTranscript = false;
  bool _loading = true;
  bool _muted = false;
  String? _error;

  VideoPlayerController? get _controller => _lease?.controller;

  String get _subtitleLanguagePreferenceKey =>
      '${StorageKeys.contentSubtitleLanguagePrefix}${widget.contentId}';

  @override
  void initState() {
    super.initState();
    unawaited(
      SystemChrome.setEnabledSystemUIMode(SystemUiMode.immersiveSticky),
    );
    unawaited(_bootstrap());
    unawaited(_loadTranscript());
  }

  @override
  void dispose() {
    unawaited(SystemChrome.setEnabledSystemUIMode(SystemUiMode.edgeToEdge));
    _transcriptPollTimer?.cancel();
    _lease?.release();
    _lease = null;
    super.dispose();
  }

  Future<void> _bootstrap() async {
    try {
      _lease ??= await SharedVideoPlayerPool.instance.acquire(
        source: widget.source,
        surface: SharedVideoSurface.fullscreenPreview,
        looping: true,
        initialVolume: 1,
      );
      final controller = await _lease!.ensureInitialized();
      _muted = controller.value.volume <= 0.001;
      await controller.play();
      if (!mounted) {
        _lease?.release();
        _lease = null;
        return;
      }
      setState(() {
        _loading = false;
      });
    } catch (_) {
      if (!mounted) return;
      setState(() {
        _loading = false;
        _error = 'Could not play this video.';
      });
    }
  }

  Future<void> _loadTranscript() async {
    final contentId = widget.contentId.trim();
    if (contentId.isEmpty) return;
    setState(() => _loadingTranscript = true);
    try {
      final repo = ref.read(contentRepositoryProvider);
      final preferredLanguageCode =
          await _readPreferredSubtitleLanguageCode() ??
          _preferredSubtitleLanguageCode ??
          _activeTrack?.languageCode;
      final detail = await repo.fetchVideoDetail(contentId);
      final preferredTrack = _preferredTrackMeta(
        detail,
        preferredLanguageCode: preferredLanguageCode,
      );
      ContentTranscriptTrack? track;
      if (preferredTrack != null) {
        track = await repo.fetchVideoTranscriptTrack(
          contentId: contentId,
          languageCode: preferredTrack.languageCode,
        );
      }
      if (!mounted) return;
      setState(() {
        _preferredSubtitleLanguageCode =
            track?.languageCode ?? preferredLanguageCode;
        _activeTrack = track;
        _transcriptStatus = detail.transcriptStatus;
        _transcriptErrorMessage = detail.transcriptErrorMessage;
        _loadingTranscript = false;
      });
      _syncTranscriptPolling(detail);
      if (detail.transcripts.isEmpty && detail.transcriptStatus == 'none') {
        unawaited(_requestTranscriptGeneration());
      }
    } catch (_) {
      if (!mounted) return;
      setState(() => _loadingTranscript = false);
    }
  }

  ContentTranscriptTrack? _preferredTrackMeta(
    ContentVideoDetail detail, {
    String? preferredLanguageCode,
  }) {
    final preferredCode = preferredLanguageCode?.trim() ?? '';
    if (preferredCode.isNotEmpty) {
      for (final track in detail.transcripts) {
        if (track.languageCode == preferredCode) {
          return track;
        }
      }
    }
    return detail.transcripts.cast<ContentTranscriptTrack?>().firstWhere(
      (track) => track?.isSource == true,
      orElse: () =>
          detail.transcripts.isEmpty ? null : detail.transcripts.first,
    );
  }

  bool get _isTranscriptProcessing =>
      _transcriptStatus == 'pending' || _transcriptStatus == 'processing';

  void _syncTranscriptPolling(ContentVideoDetail detail) {
    final shouldPoll =
        detail.transcripts.isEmpty &&
        (detail.transcriptStatus == 'pending' ||
            detail.transcriptStatus == 'processing');
    if (shouldPoll) {
      _transcriptPollTimer ??= Timer(const Duration(seconds: 3), () {
        _transcriptPollTimer = null;
        unawaited(
          _pollTranscriptState(
            preferredLanguageCode:
                _preferredSubtitleLanguageCode ?? _activeTrack?.languageCode,
          ),
        );
      });
      return;
    }
    _transcriptPollTimer?.cancel();
    _transcriptPollTimer = null;
  }

  Future<void> _pollTranscriptState({String? preferredLanguageCode}) async {
    try {
      final repo = ref.read(contentRepositoryProvider);
      final detail = await repo.fetchVideoDetail(widget.contentId);
      final preferredTrack = _preferredTrackMeta(
        detail,
        preferredLanguageCode:
            preferredLanguageCode ??
            _preferredSubtitleLanguageCode ??
            _activeTrack?.languageCode,
      );
      ContentTranscriptTrack? track = _activeTrack;
      if (preferredTrack != null) {
        track = await repo.fetchVideoTranscriptTrack(
          contentId: widget.contentId,
          languageCode: preferredTrack.languageCode,
        );
      }
      if (!mounted) return;
      setState(() {
        _preferredSubtitleLanguageCode =
            track?.languageCode ??
            preferredLanguageCode ??
            _preferredSubtitleLanguageCode;
        _activeTrack = track;
        _transcriptStatus = detail.transcriptStatus;
        _transcriptErrorMessage = detail.transcriptErrorMessage;
        _loadingTranscript = false;
      });
      _syncTranscriptPolling(detail);
    } catch (_) {
      if (!mounted) return;
      setState(() => _loadingTranscript = false);
    }
  }

  Future<String?> _readPreferredSubtitleLanguageCode() async {
    final prefs = await ref.read(sharedPreferencesProvider.future);
    final value = prefs.getString(_subtitleLanguagePreferenceKey)?.trim();
    if (value == null || value.isEmpty) return null;
    return value;
  }

  Future<void> _persistPreferredSubtitleLanguageCode(
    String languageCode,
  ) async {
    final normalized = languageCode.trim();
    if (normalized.isEmpty) return;
    final prefs = await ref.read(sharedPreferencesProvider.future);
    await prefs.setString(_subtitleLanguagePreferenceKey, normalized);
  }

  void _applyTranscriptSheetResult(_TranscriptSheetResult result) {
    setState(() {
      _activeTrack = result.track;
      _preferredSubtitleLanguageCode =
          result.track?.languageCode ?? _preferredSubtitleLanguageCode;
      _transcriptStatus = result.status;
      _transcriptErrorMessage = result.errorMessage;
    });
    final languageCode = result.track?.languageCode;
    if (languageCode != null && languageCode.trim().isNotEmpty) {
      unawaited(_persistPreferredSubtitleLanguageCode(languageCode));
    }
  }

  Future<void> _requestTranscriptGeneration() async {
    if (_loadingTranscript && _isTranscriptProcessing) return;
    final contentId = widget.contentId.trim();
    if (contentId.isEmpty) return;
    try {
      final result = await ref
          .read(contentRepositoryProvider)
          .generateVideoTranscript(contentId);
      if (!mounted) return;
      if (result.isReady && result.track != null) {
        setState(() {
          _activeTrack = result.track;
          _transcriptStatus = 'ready';
          _transcriptErrorMessage = '';
          _loadingTranscript = false;
        });
        return;
      }
      await _pollTranscriptState();
    } catch (_) {
      if (!mounted) return;
      setState(() => _loadingTranscript = false);
    }
  }

  ContentTranscriptSegment? _currentCaption(VideoPlayerValue value) {
    return _captionAtMilliseconds(
      _scrubDragMs ?? value.position.inMilliseconds,
    );
  }

  ContentTranscriptSegment? _captionAtMilliseconds(int positionMs) {
    final track = _activeTrack;
    if (track == null || track.segments.isEmpty) return null;
    final effectivePositionMs = _subtitleMatchPositionMs(positionMs);
    for (final segment in track.segments) {
      if (effectivePositionMs >= segment.startMs &&
          effectivePositionMs <= segment.endMs) {
        return segment;
      }
    }
    return null;
  }

  String _formatVideoClock(Duration value) {
    final totalSeconds = value.inSeconds;
    final hours = totalSeconds ~/ 3600;
    final minutes = (totalSeconds % 3600) ~/ 60;
    final seconds = totalSeconds % 60;
    if (hours > 0) {
      return '${hours.toString()}:${minutes.toString().padLeft(2, '0')}:${seconds.toString().padLeft(2, '0')}';
    }
    return '${minutes.toString()}:${seconds.toString().padLeft(2, '0')}';
  }

  Future<void> _togglePlayback() async {
    final controller = _controller;
    if (controller == null) return;
    if (controller.value.isPlaying) {
      await controller.pause();
    } else {
      await controller.play();
    }
    if (mounted) {
      setState(() {});
    }
  }

  Future<void> _toggleMute() async {
    final controller = _controller;
    if (controller == null || !controller.value.isInitialized) return;
    _muted = !_muted;
    await controller.setVolume(_muted ? 0 : 1);
    if (mounted) {
      setState(() {});
    }
  }

  void _handleScrubStart(double value) {
    final controller = _controller;
    _resumeAfterScrub = controller?.value.isPlaying == true;
    if (controller?.value.isPlaying == true) {
      unawaited(controller!.pause());
    }
    setState(() => _scrubDragMs = value.round());
  }

  void _handleScrubChanged(double value) {
    final ms = value.round();
    setState(() => _scrubDragMs = ms);
    final controller = _controller;
    if (controller == null) return;
    final now = DateTime.now();
    if (_lastPreviewScrubSeekAt != null &&
        now.difference(_lastPreviewScrubSeekAt!).inMilliseconds < 90) {
      return;
    }
    _lastPreviewScrubSeekAt = now;
    unawaited(controller.seekTo(Duration(milliseconds: ms)));
  }

  Future<void> _handleScrubEnd(double value) async {
    final controller = _controller;
    if (controller == null) return;
    final ms = value.round();
    setState(() => _scrubDragMs = null);
    await controller.seekTo(Duration(milliseconds: ms));
    if (_resumeAfterScrub) {
      await controller.play();
    }
    _resumeAfterScrub = false;
    if (mounted) {
      setState(() {});
    }
  }

  Future<void> _openFullTranscript() async {
    final result = await showModalBottomSheet<_TranscriptSheetResult>(
      context: context,
      isScrollControlled: true,
      showDragHandle: true,
      useSafeArea: true,
      backgroundColor: Theme.of(context).colorScheme.surface,
      builder: (context) => FractionallySizedBox(
        heightFactor: 0.94,
        child: _TranscriptSheet(
          contentId: widget.contentId,
          title: widget.title,
          initialTrack: _activeTrack,
          initialStatus: _transcriptStatus,
          initialErrorMessage: _transcriptErrorMessage,
          videoController: _controller,
          onChanged: _applyTranscriptSheetResult,
        ),
      ),
    );
    if (!mounted || result == null) return;
    _applyTranscriptSheetResult(result);
  }

  Future<void> _openComments() async {
    await showModalBottomSheet<void>(
      context: context,
      isScrollControlled: true,
      showDragHandle: true,
      useSafeArea: true,
      backgroundColor: Theme.of(context).colorScheme.surface,
      builder: (context) => FractionallySizedBox(
        heightFactor: 0.94,
        child: _CommentsSheet(
          contentId: widget.contentId,
          onCommentCountChanged: (_) {},
        ),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final controller = _controller;
    final ready = controller != null && controller.value.isInitialized;
    final title = widget.title.trim();
    return LayoutBuilder(
      builder: (context, constraints) {
        final desktop = constraints.maxWidth >= 900;
        final videoFit = desktop ? BoxFit.contain : BoxFit.cover;
        final controlsMaxWidth = desktop ? 760.0 : double.infinity;
        return AnnotatedRegion<SystemUiOverlayStyle>(
          value: SystemUiOverlayStyle.light,
          child: Scaffold(
            backgroundColor: Colors.black,
            body: Column(
              children: [
                Expanded(
                  child: Stack(
                    fit: StackFit.expand,
                    children: [
                      if (_loading)
                        _VideoPosterPlaceholder(
                          imageUrl: widget.posterUrl,
                          label: 'Preparing video…',
                          expanded: true,
                        )
                      else if (_error != null || !ready)
                        _VideoPosterPlaceholder(
                          imageUrl: widget.posterUrl,
                          label: _error ?? 'Could not play this video.',
                          expanded: true,
                          showSpinner: false,
                        )
                      else
                        ColoredBox(
                          color: Colors.black,
                          child: FittedBox(
                            fit: videoFit,
                            clipBehavior: Clip.hardEdge,
                            child: SizedBox(
                              width: controller.value.size.width,
                              height: controller.value.size.height,
                              child: AbsorbPointer(
                                child: VideoPlayer(controller),
                              ),
                            ),
                          ),
                        ),
                      IgnorePointer(
                        child: DecoratedBox(
                          decoration: BoxDecoration(
                            gradient: LinearGradient(
                              begin: Alignment.topCenter,
                              end: Alignment.bottomCenter,
                              colors: [
                                Colors.black.withValues(alpha: 0.42),
                                Colors.transparent,
                                Colors.transparent,
                                Colors.black.withValues(alpha: 0.08),
                              ],
                            ),
                          ),
                        ),
                      ),
                      if (ready)
                        Positioned.fill(
                          child: GestureDetector(
                            behavior: HitTestBehavior.opaque,
                            onTap: _togglePlayback,
                          ),
                        ),
                      if (ready && !controller.value.isPlaying)
                        IgnorePointer(
                          child: Center(
                            child: Container(
                              width: 78,
                              height: 78,
                              decoration: BoxDecoration(
                                color: Colors.black.withValues(alpha: 0.48),
                                shape: BoxShape.circle,
                              ),
                              child: const Icon(
                                Icons.play_arrow_rounded,
                                color: Colors.white,
                                size: 44,
                              ),
                            ),
                          ),
                        ),
                      SafeArea(
                        child: Padding(
                          padding: const EdgeInsets.fromLTRB(12, 8, 12, 12),
                          child: Row(
                            children: [
                              IconButton.filled(
                                onPressed: () =>
                                    Navigator.of(context).maybePop(),
                                style: IconButton.styleFrom(
                                  backgroundColor: Colors.black.withValues(
                                    alpha: 0.42,
                                  ),
                                  foregroundColor: Colors.white,
                                ),
                                icon: const Icon(Icons.arrow_back_rounded),
                              ),
                              const Spacer(),
                              IconButton.filled(
                                onPressed: ready ? _toggleMute : null,
                                style: IconButton.styleFrom(
                                  backgroundColor: Colors.black.withValues(
                                    alpha: 0.42,
                                  ),
                                  foregroundColor: Colors.white,
                                ),
                                icon: Icon(
                                  _muted
                                      ? Icons.volume_off_rounded
                                      : Icons.volume_up_rounded,
                                ),
                              ),
                            ],
                          ),
                        ),
                      ),
                    ],
                  ),
                ),
                ValueListenableBuilder<VideoPlayerValue>(
                  valueListenable:
                      controller ??
                      ValueNotifier(
                        const VideoPlayerValue(duration: Duration.zero),
                      ),
                  builder: (context, value, _) {
                    final caption = ready ? _currentCaption(value) : null;
                    final subtitleText = caption?.text.trim() ?? '';
                    final showSubtitleText = subtitleText.isNotEmpty;
                    final duration = value.duration;
                    final hasDuration = duration > Duration.zero;
                    final durationMs = duration.inMilliseconds;
                    final sliderMax = durationMs <= 0
                        ? 1.0
                        : durationMs.toDouble();
                    final sliderValue =
                        (_scrubDragMs ?? value.position.inMilliseconds)
                            .clamp(0, durationMs <= 0 ? 0 : durationMs)
                            .toDouble();
                    return SafeArea(
                      top: false,
                      child: Center(
                        child: Container(
                          width: double.infinity,
                          constraints: BoxConstraints(
                            minHeight: 108,
                            maxWidth: controlsMaxWidth,
                          ),
                          padding: const EdgeInsets.fromLTRB(18, 12, 18, 16),
                          decoration: BoxDecoration(
                            color: const Color(0xFF050505),
                            border: Border(
                              top: BorderSide(
                                color: Colors.white.withValues(alpha: 0.08),
                              ),
                            ),
                          ),
                          child: Column(
                            mainAxisSize: MainAxisSize.min,
                            children: [
                              if (ready)
                                SliderTheme(
                                  data: SliderTheme.of(context).copyWith(
                                    trackHeight: 4,
                                    thumbShape: const RoundSliderThumbShape(
                                      enabledThumbRadius: 7,
                                    ),
                                    overlayShape: const RoundSliderOverlayShape(
                                      overlayRadius: 14,
                                    ),
                                  ),
                                  child: Slider(
                                    value: sliderValue.clamp(0, sliderMax),
                                    min: 0,
                                    max: sliderMax,
                                    onChangeStart: durationMs <= 0
                                        ? null
                                        : _handleScrubStart,
                                    onChanged: durationMs <= 0
                                        ? null
                                        : _handleScrubChanged,
                                    onChangeEnd: durationMs <= 0
                                        ? null
                                        : _handleScrubEnd,
                                  ),
                                ),
                              if (ready && hasDuration) ...[
                                const SizedBox(height: 8),
                                Row(
                                  children: [
                                    Text(
                                      _formatVideoClock(
                                        Duration(
                                          milliseconds:
                                              (_scrubDragMs ??
                                                      value
                                                          .position
                                                          .inMilliseconds)
                                                  .clamp(
                                                    0,
                                                    durationMs <= 0
                                                        ? 0
                                                        : durationMs,
                                                  ),
                                        ),
                                      ),
                                      style: TextStyle(
                                        color: Colors.white.withValues(
                                          alpha: 0.78,
                                        ),
                                        fontSize: 12,
                                        fontWeight: FontWeight.w600,
                                      ),
                                    ),
                                    const Spacer(),
                                    Text(
                                      _formatVideoClock(duration),
                                      style: TextStyle(
                                        color: Colors.white.withValues(
                                          alpha: 0.58,
                                        ),
                                        fontSize: 12,
                                        fontWeight: FontWeight.w600,
                                      ),
                                    ),
                                  ],
                                ),
                              ],
                              const SizedBox(height: 10),
                              AnimatedSwitcher(
                                duration: const Duration(milliseconds: 180),
                                child: showSubtitleText
                                    ? Container(
                                        key: ValueKey<String>(
                                          '${caption!.startMs}:${caption.text}',
                                        ),
                                        width: double.infinity,
                                        padding: const EdgeInsets.symmetric(
                                          horizontal: 14,
                                          vertical: 12,
                                        ),
                                        decoration: BoxDecoration(
                                          color: Colors.white.withValues(
                                            alpha: 0.08,
                                          ),
                                          borderRadius: BorderRadius.circular(
                                            18,
                                          ),
                                          border: Border.all(
                                            color: Colors.white.withValues(
                                              alpha: 0.12,
                                            ),
                                          ),
                                        ),
                                        child: Text(
                                          subtitleText,
                                          textAlign: TextAlign.center,
                                          style: const TextStyle(
                                            color: Colors.white,
                                            fontSize: 16,
                                            height: 1.35,
                                            fontWeight: FontWeight.w700,
                                          ),
                                        ),
                                      )
                                    : Column(
                                        key: ValueKey<String>(
                                          _loadingTranscript
                                              ? 'loading-transcript'
                                              : 'fallback-title',
                                        ),
                                        mainAxisSize: MainAxisSize.min,
                                        children: [
                                          if (title.isNotEmpty)
                                            Text(
                                              title,
                                              maxLines: 2,
                                              overflow: TextOverflow.ellipsis,
                                              textAlign: TextAlign.center,
                                              style: const TextStyle(
                                                color: Colors.white,
                                                fontSize: 15,
                                                fontWeight: FontWeight.w700,
                                              ),
                                            ),
                                          if (_loadingTranscript ||
                                              _isTranscriptProcessing) ...[
                                            const SizedBox(height: 10),
                                            const SizedBox(
                                              width: 18,
                                              height: 18,
                                              child: CircularProgressIndicator(
                                                strokeWidth: 2.2,
                                                color: Colors.white70,
                                              ),
                                            ),
                                          ] else if (_activeTrack == null) ...[
                                            const SizedBox(height: 8),
                                            Text(
                                              _transcriptStatus == 'failed' &&
                                                      _transcriptErrorMessage
                                                          .trim()
                                                          .isNotEmpty
                                                  ? _transcriptErrorMessage
                                                        .trim()
                                                  : 'Subtitles unavailable',
                                              textAlign: TextAlign.center,
                                              style: TextStyle(
                                                color: Colors.white.withValues(
                                                  alpha: 0.72,
                                                ),
                                                fontSize: 13,
                                                fontWeight: FontWeight.w600,
                                              ),
                                            ),
                                          ],
                                        ],
                                      ),
                              ),
                              const SizedBox(height: 12),
                              Row(
                                children: [
                                  Expanded(
                                    child: OutlinedButton.icon(
                                      onPressed: _openFullTranscript,
                                      icon: const Icon(Icons.subtitles_rounded),
                                      label: const Text('Full subtitles'),
                                    ),
                                  ),
                                  const SizedBox(width: 10),
                                  Expanded(
                                    child: OutlinedButton.icon(
                                      onPressed: _openComments,
                                      icon: const Icon(
                                        Icons.mode_comment_outlined,
                                      ),
                                      label: const Text('Comments'),
                                    ),
                                  ),
                                ],
                              ),
                            ],
                          ),
                        ),
                      ),
                    );
                  },
                ),
              ],
            ),
          ),
        );
      },
    );
  }
}

class _VideoPosterPlaceholder extends StatelessWidget {
  const _VideoPosterPlaceholder({
    required this.imageUrl,
    required this.label,
    this.expanded = false,
    this.showSpinner = true,
  });

  final String imageUrl;
  final String label;
  final bool expanded;
  final bool showSpinner;

  @override
  Widget build(BuildContext context) {
    final resolvedImageUrl = imageUrl.trim().isEmpty
        ? ''
        : resolveMediaUrl(imageUrl);
    final content = Stack(
      fit: StackFit.expand,
      children: [
        if (resolvedImageUrl.isNotEmpty)
          Image.network(
            resolvedImageUrl,
            fit: BoxFit.cover,
            loadingBuilder: (context, child, loadingProgress) =>
                loadingProgress == null ? child : const SizedBox.shrink(),
            errorBuilder: (context, error, stackTrace) =>
                const SizedBox.shrink(),
          )
        else
          const DecoratedBox(
            decoration: BoxDecoration(
              gradient: LinearGradient(
                colors: [Color(0xFF151515), Color(0xFF2A2A2A)],
                begin: Alignment.topLeft,
                end: Alignment.bottomRight,
              ),
            ),
          ),
        DecoratedBox(
          decoration: BoxDecoration(
            color: Colors.black.withValues(
              alpha: resolvedImageUrl.isNotEmpty ? 0.26 : 0,
            ),
          ),
        ),
        Center(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              if (showSpinner)
                const SizedBox(
                  width: 28,
                  height: 28,
                  child: CircularProgressIndicator(strokeWidth: 2.4),
                ),
              if (showSpinner) const SizedBox(height: 12),
              Text(
                label,
                style: const TextStyle(
                  color: Colors.white70,
                  fontWeight: FontWeight.w600,
                ),
                textAlign: TextAlign.center,
              ),
            ],
          ),
        ),
      ],
    );
    if (expanded) {
      return content;
    }
    return ColoredBox(color: Colors.black, child: content);
  }
}

class TalkizPostDetailScreen extends StatelessWidget {
  const TalkizPostDetailScreen({
    super.key,
    required this.post,
    required this.currentUser,
  });

  final UserPostItem post;
  final AppUser? currentUser;

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: const Text('Post')),
      body: _TalkizWebFrame(
        maxWidth: _talkizWebFeedMaxWidth,
        expandHeight: true,
        child: ListView(
          padding: const EdgeInsets.fromLTRB(14, 14, 14, 24),
          children: [
            _PostCard(
              post: post,
              currentUser: currentUser,
              openDetailEnabled: false,
            ),
          ],
        ),
      ),
    );
  }
}

class TalkizPodcastDetailScreen extends StatelessWidget {
  const TalkizPodcastDetailScreen({
    super.key,
    required this.item,
    required this.currentUser,
  });

  final PodcastEpisodeItem item;
  final AppUser? currentUser;

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: const Text('Podcast')),
      body: _TalkizWebFrame(
        maxWidth: _talkizWebFeedMaxWidth,
        expandHeight: true,
        child: ListView(
          padding: const EdgeInsets.fromLTRB(14, 14, 14, 24),
          children: [
            _PodcastCard(
              item: item,
              currentUser: currentUser,
              openDetailEnabled: false,
            ),
          ],
        ),
      ),
    );
  }
}

Future<void> _editContent({
  required BuildContext context,
  required WidgetRef ref,
  required String contentId,
  required String title,
  required String summary,
  required String body,
  required bool isPodcast,
  required VoidCallback onUpdated,
}) async {
  final titleController = TextEditingController(text: title);
  final summaryController = TextEditingController(text: summary);
  final bodyController = TextEditingController(text: body);
  final saved = await showModalBottomSheet<bool>(
    context: context,
    isScrollControlled: true,
    showDragHandle: true,
    builder: (context) => _TalkizWebFrame(
      maxWidth: _talkizWebSheetMaxWidth,
      child: Padding(
        padding: EdgeInsets.fromLTRB(
          16,
          8,
          16,
          MediaQuery.of(context).viewInsets.bottom + 16,
        ),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            TextField(
              controller: titleController,
              textCapitalization: TextCapitalization.sentences,
              decoration: const InputDecoration(
                labelText: 'Title',
                border: OutlineInputBorder(),
              ),
            ),
            const SizedBox(height: 12),
            if (isPodcast) ...[
              TextField(
                controller: summaryController,
                minLines: 2,
                maxLines: 4,
                textCapitalization: TextCapitalization.sentences,
                decoration: const InputDecoration(
                  labelText: 'Short description',
                  border: OutlineInputBorder(),
                ),
              ),
              const SizedBox(height: 12),
            ],
            TextField(
              controller: bodyController,
              minLines: 3,
              maxLines: 6,
              textCapitalization: TextCapitalization.sentences,
              decoration: InputDecoration(
                labelText: isPodcast ? 'Episode notes' : 'Caption',
                border: const OutlineInputBorder(),
              ),
            ),
            const SizedBox(height: 16),
            SizedBox(
              width: double.infinity,
              child: FilledButton(
                onPressed: () => Navigator.of(context).pop(true),
                child: const Text('Save changes'),
              ),
            ),
          ],
        ),
      ),
    ),
  );
  if (saved != true) {
    titleController.dispose();
    summaryController.dispose();
    bodyController.dispose();
    return;
  }
  try {
    await ref
        .read(contentRepositoryProvider)
        .editContent(
          contentId: contentId,
          title: titleController.text,
          summary: summaryController.text,
          body: bodyController.text,
        );
    onUpdated();
    if (!context.mounted) return;
    ScaffoldMessenger.of(
      context,
    ).showSnackBar(const SnackBar(content: Text('Post updated.')));
  } catch (e) {
    if (!context.mounted) return;
    ScaffoldMessenger.of(
      context,
    ).showSnackBar(SnackBar(content: Text(userFriendlyMessageFromObject(e))));
  } finally {
    titleController.dispose();
    summaryController.dispose();
    bodyController.dispose();
  }
}

Future<void> _deleteContent({
  required BuildContext context,
  required WidgetRef ref,
  required String contentId,
  required VoidCallback onUpdated,
}) async {
  final confirmed = await showDialog<bool>(
    context: context,
    builder: (context) => AlertDialog(
      title: const Text('Delete post?'),
      content: const Text('This will remove the post from the feed.'),
      actions: [
        TextButton(
          onPressed: () => Navigator.of(context).pop(false),
          child: const Text('Cancel'),
        ),
        FilledButton(
          onPressed: () => Navigator.of(context).pop(true),
          child: const Text('Delete'),
        ),
      ],
    ),
  );
  if (confirmed != true) return;
  try {
    await ref.read(contentRepositoryProvider).deleteContent(contentId);
    onUpdated();
    if (!context.mounted) return;
    ScaffoldMessenger.of(
      context,
    ).showSnackBar(const SnackBar(content: Text('Post deleted.')));
  } catch (e) {
    if (!context.mounted) return;
    ScaffoldMessenger.of(
      context,
    ).showSnackBar(SnackBar(content: Text(userFriendlyMessageFromObject(e))));
  }
}

Future<void> _hideContent({
  required BuildContext context,
  required WidgetRef ref,
  required String contentId,
  required VoidCallback onUpdated,
}) async {
  try {
    await ref.read(contentRepositoryProvider).hideContent(contentId);
    onUpdated();
    if (!context.mounted) return;
    ScaffoldMessenger.of(
      context,
    ).showSnackBar(const SnackBar(content: Text('Post hidden.')));
  } catch (e) {
    if (!context.mounted) return;
    ScaffoldMessenger.of(
      context,
    ).showSnackBar(SnackBar(content: Text(userFriendlyMessageFromObject(e))));
  }
}

// ── Live-screen-style underline tab switcher ─────────────────────────────────

class _ContentTabData {
  const _ContentTabData({
    required this.value,
    required this.label,
    required this.icon,
  });

  final _ContentSegment value;
  final String label;
  final IconData icon;
}

class _ContentTabSwitch extends StatelessWidget {
  const _ContentTabSwitch({
    required this.tabs,
    required this.selected,
    required this.onChanged,
  });

  final List<_ContentTabData> tabs;
  final _ContentSegment selected;
  final ValueChanged<_ContentSegment> onChanged;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Row(
      children: tabs.map((tab) {
        final active = tab.value == selected;
        return Expanded(
          child: InkWell(
            onTap: () => onChanged(tab.value),
            borderRadius: BorderRadius.circular(12),
            child: Padding(
              padding: const EdgeInsets.only(bottom: 2),
              child: Column(
                mainAxisSize: MainAxisSize.min,
                children: [
                  Row(
                    mainAxisAlignment: MainAxisAlignment.center,
                    children: [
                      Icon(
                        tab.icon,
                        size: 18,
                        color: active
                            ? theme.colorScheme.onSurface
                            : theme.colorScheme.onSurfaceVariant,
                      ),
                      const SizedBox(width: 7),
                      Flexible(
                        child: Text(
                          tab.label,
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                          style: theme.textTheme.titleSmall?.copyWith(
                            color: active
                                ? theme.colorScheme.onSurface
                                : theme.colorScheme.onSurfaceVariant,
                            fontWeight: FontWeight.w800,
                          ),
                        ),
                      ),
                    ],
                  ),
                  const SizedBox(height: 10),
                  AnimatedContainer(
                    duration: const Duration(milliseconds: 180),
                    curve: Curves.easeOut,
                    height: 3,
                    width: active ? 48 : 20,
                    decoration: BoxDecoration(
                      color: active
                          ? theme.colorScheme.primary
                          : theme.colorScheme.outline.withValues(alpha: 0.18),
                      borderRadius: BorderRadius.circular(999),
                    ),
                  ),
                ],
              ),
            ),
          ),
        );
      }).toList(),
    );
  }
}

// ─────────────────────────────────────────────────────────────────────────────

String _postMeta(UserPostItem post) {
  final publishedAt = post.publishedAt;
  final kind = switch (post.kind) {
    'video' => 'Video',
    'image' => post.assets.length > 1 ? 'Carousel' : 'Photo',
    _ => 'Post',
  };
  final age = publishedAt == null ? null : _relativeTimeLabel(publishedAt);
  return age == null ? kind : '$kind · $age';
}

String _podcastMeta(PodcastEpisodeItem item) {
  final publishedAt = item.publishedAt;
  final age = publishedAt == null ? null : _relativeTimeLabel(publishedAt);
  return age == null ? 'Podcast' : 'Podcast · $age';
}

String _dateLabel(DateTime time) {
  return _relativeTimeLabel(time, longForm: true);
}

String _compactCount(int value) {
  return compactCount(value);
}

String _relativeTimeLabel(DateTime time, {bool longForm = false}) {
  final delta = DateTime.now().difference(time.toLocal());
  if (delta.inMinutes < 1) {
    return longForm ? 'Just now' : 'now';
  }
  if (delta.inHours < 1) {
    return longForm
        ? '${delta.inMinutes} minute${delta.inMinutes == 1 ? '' : 's'} ago'
        : '${delta.inMinutes}m';
  }
  if (delta.inDays < 1) {
    return longForm
        ? '${delta.inHours} hour${delta.inHours == 1 ? '' : 's'} ago'
        : '${delta.inHours}h';
  }
  if (delta.inDays < 7) {
    return longForm
        ? '${delta.inDays} day${delta.inDays == 1 ? '' : 's'} ago'
        : '${delta.inDays}d';
  }
  final weeks = (delta.inDays / 7).floor();
  if (delta.inDays < 30) {
    return longForm ? '$weeks week${weeks == 1 ? '' : 's'} ago' : '${weeks}w';
  }
  final local = time.toLocal();
  final month = _monthLabel(local.month);
  if (longForm) {
    return '$month ${local.day}, ${local.year}';
  }
  return '$month ${local.day}';
}

String _monthLabel(int month) {
  const names = [
    'Jan',
    'Feb',
    'Mar',
    'Apr',
    'May',
    'Jun',
    'Jul',
    'Aug',
    'Sep',
    'Oct',
    'Nov',
    'Dec',
  ];
  return names[(month - 1).clamp(0, names.length - 1)];
}
