import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';
import 'package:share_plus/share_plus.dart';
import 'package:url_launcher/url_launcher.dart';
import 'package:video_player/video_player.dart';

import '../../../core/auth/session_controller.dart';
import '../../../core/formatters/compact_count_formatter.dart';
import '../../../core/media/audio_message_player.dart';
import '../../../core/media/media_utils.dart';
import '../../../core/widgets/app_avatar.dart';
import '../data/content_repository.dart';
import 'content_text_widgets.dart';
import 'content_ui_utils.dart';

const int _subtitleAdvanceLeadMs = 140;

int _subtitleMatchPositionMs(int positionMs) {
  return positionMs + _subtitleAdvanceLeadMs;
}

String _loginRedirectForCurrentPage() {
  final uri = Uri.base;
  final target = uri.hasQuery ? '${uri.path}?${uri.query}' : uri.path;
  return '/login?next=${Uri.encodeComponent(target.isEmpty ? '/' : target)}';
}

String _signupRedirectForCurrentPage() {
  final uri = Uri.base;
  final target = uri.hasQuery ? '${uri.path}?${uri.query}' : uri.path;
  return '/signup?next=${Uri.encodeComponent(target.isEmpty ? '/' : target)}';
}

String _sharedCompactCount(int count) {
  return compactCount(count);
}

Future<void> _showLoginRequiredDialog({
  required BuildContext context,
  required String title,
  required String message,
}) async {
  await showDialog<void>(
    context: context,
    builder: (dialogContext) => AlertDialog(
      title: Text(title),
      content: Text(message),
      actions: [
        TextButton(
          onPressed: () => Navigator.of(dialogContext).pop(),
          child: const Text('Not now'),
        ),
        FilledButton(
          onPressed: () {
            Navigator.of(dialogContext).pop();
            context.go(_loginRedirectForCurrentPage());
          },
          child: const Text('Log in'),
        ),
      ],
    ),
  );
}

class SharedContentLinkScreen extends ConsumerStatefulWidget {
  const SharedContentLinkScreen({
    super.key,
    required this.token,
    this.forceWebPreview = false,
  });

  final String token;
  final bool forceWebPreview;

  @override
  ConsumerState<SharedContentLinkScreen> createState() =>
      _SharedContentLinkScreenState();
}

class _SharedContentLinkScreenState
    extends ConsumerState<SharedContentLinkScreen> {
  PublicSharedContentItem? _item;
  SharedLinkResolution? _resolution;
  bool _loading = true;
  bool _redirectIssued = false;
  String? _error;

  @override
  void initState() {
    super.initState();
    unawaited(_load());
  }

  Future<void> _load() async {
    setState(() {
      _loading = true;
      _error = null;
    });
    try {
      if (widget.forceWebPreview) {
        final item = await ref
            .read(contentRepositoryProvider)
            .fetchPublicSharePreview(widget.token);
        if (!mounted) return;
        setState(() {
          _item = item;
          _resolution = null;
          _loading = false;
        });
        return;
      }

      final result = await ref
          .read(contentRepositoryProvider)
          .resolveShareLink(widget.token);
      if (!mounted) return;
      setState(() {
        _item = result.item;
        _resolution = result.resolution;
        _loading = false;
      });
      _handleResolvedShare();
    } catch (error) {
      if (!mounted) return;
      setState(() {
        _error = userFriendlyMessageFromObject(error);
        _loading = false;
      });
    }
  }

  void _handleResolvedShare() {
    if (widget.forceWebPreview) {
      return;
    }

    final resolution = _resolution;
    final route = resolution?.canonicalRoute.trim() ?? '';
    if (resolution?.isFullAccess == true &&
        route.isNotEmpty &&
        !_redirectIssued) {
      _redirectIssued = true;
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (!mounted) return;
        context.go(route);
      });
    }
  }

  List<PublicSharedContentAsset> _effectivePostAssets(
    PublicSharedContentItem item,
  ) {
    if (item.assets.isNotEmpty) return item.assets;
    if (item.mediaUrl.trim().isEmpty) return const <PublicSharedContentAsset>[];
    return <PublicSharedContentAsset>[
      PublicSharedContentAsset(
        role: 'gallery_item',
        order: 0,
        url: item.mediaUrl,
        previewUrl: item.previewUrl,
        posterUrl: item.posterUrl,
        mimeType: item.mediaMimeType,
        lockedAfterSeconds: item.previewSeconds,
      ),
    ];
  }

  @override
  Widget build(BuildContext context) {
    final session = ref.watch(sessionControllerProvider);
    if (_item != null) {
      WidgetsBinding.instance.addPostFrameCallback((_) {
        _handleResolvedShare();
      });
    }

    if (_loading || (_item == null && session.isLoading)) {
      return const _SharedContentLoadingScreen();
    }

    if (_error != null) {
      return _SharedContentErrorScreen(message: _error!, onRetry: _load);
    }

    final item = _item;
    if (item == null) {
      return _SharedContentErrorScreen(
        message: 'This shared content is unavailable right now.',
        onRetry: _load,
      );
    }

    if (_resolution?.isFullAccess == true && !widget.forceWebPreview) {
      return const _SharedContentLoadingScreen(label: 'Opening in Talkflix…');
    }

    if (item.isLive) {
      return _SharedContentPreviewScreen(
        item: item,
        child: _SharedLivePreview(item: item),
      );
    }

    if (item.isProfile) {
      return _SharedContentPreviewScreen(
        item: item,
        child: _SharedProfilePreview(item: item),
      );
    }

    if (item.isVideo) {
      return _SharedContentPreviewScreen(
        item: item,
        child: _SharedVideoPreview(item: item),
      );
    }

    final postAssets = _effectivePostAssets(item);
    return _SharedContentPreviewScreen(
      item: item,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          if (item.isPodcast) ...[
            if (item.coverUrl.trim().isNotEmpty) ...[
              ClipRRect(
                borderRadius: BorderRadius.circular(24),
                child: AspectRatio(
                  aspectRatio: 1,
                  child: Image.network(
                    resolveMediaUrl(item.coverUrl),
                    fit: BoxFit.cover,
                  ),
                ),
              ),
              const SizedBox(height: 18),
            ],
            if (item.audioUrl.trim().isNotEmpty)
              AudioMessagePlayer(
                source: resolveMediaUrl(
                  item.previewUrl.trim().isNotEmpty
                      ? item.previewUrl
                      : item.audioUrl,
                ),
                durationSeconds: item.previewSeconds,
              ),
          ] else ...[
            for (final asset in postAssets) ...[
              if (asset.isImage)
                ClipRRect(
                  borderRadius: BorderRadius.circular(24),
                  child: Image.network(
                    resolveMediaUrl(asset.url),
                    fit: BoxFit.cover,
                  ),
                )
              else if (asset.isVideo)
                _SharedVideoCard(
                  source: resolveMediaUrl(
                    asset.previewUrl.trim().isNotEmpty
                        ? asset.previewUrl
                        : asset.url,
                  ),
                  posterUrl: asset.posterUrl.trim().isEmpty
                      ? null
                      : resolveMediaUrl(asset.posterUrl),
                  lockedAfterSeconds: asset.lockedAfterSeconds,
                ),
              const SizedBox(height: 16),
            ],
          ],
          if (item.body.trim().isNotEmpty) ...[
            const SizedBox(height: 16),
            ExpandableContentLinkText(
              text: item.body,
              style: Theme.of(context).textTheme.bodyLarge,
              collapsedMaxLines: 6,
            ),
          ],
        ],
      ),
    );
  }
}

class _SharedContentPreviewScreen extends StatelessWidget {
  const _SharedContentPreviewScreen({required this.item, required this.child});

  final PublicSharedContentItem item;
  final Widget child;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final title = item.isLive
        ? 'Shared live room'
        : item.isProfile
        ? 'Shared profile'
        : item.isVideo
        ? 'Shared video'
        : item.isPodcast
        ? 'Shared podcast'
        : 'Shared post';

    return Scaffold(
      appBar: AppBar(title: Text(title)),
      body: Align(
        alignment: Alignment.topCenter,
        child: ConstrainedBox(
          constraints: BoxConstraints(maxWidth: item.isVideo ? 1120 : 720),
          child: ListView(
            padding: const EdgeInsets.fromLTRB(20, 20, 20, 28),
            children: [
              Row(
                children: [
                  AppAvatar(
                    label: item.authorName,
                    imageUrl: item.authorProfilePhotoUrl,
                    radius: 26,
                  ),
                  const SizedBox(width: 14),
                  Expanded(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Text(
                          item.authorName,
                          style: Theme.of(context).textTheme.titleMedium
                              ?.copyWith(fontWeight: FontWeight.w700),
                        ),
                        const SizedBox(height: 2),
                        Text(
                          item.authorUsername.trim().isEmpty
                              ? 'Shared on Talkflix'
                              : '@${item.authorUsername}',
                          style: Theme.of(context).textTheme.bodyMedium
                              ?.copyWith(color: scheme.onSurfaceVariant),
                        ),
                      ],
                    ),
                  ),
                ],
              ),
              const SizedBox(height: 20),
              if (item.title.trim().isNotEmpty) ...[
                Text(
                  item.title,
                  style: Theme.of(context).textTheme.headlineSmall?.copyWith(
                    fontWeight: FontWeight.w800,
                  ),
                ),
                const SizedBox(height: 10),
              ],
              if (item.summary.trim().isNotEmpty) ...[
                Text(
                  item.summary,
                  style: Theme.of(context).textTheme.bodyLarge?.copyWith(
                    color: scheme.onSurfaceVariant,
                  ),
                ),
                const SizedBox(height: 16),
              ],
              child,
              const SizedBox(height: 22),
              _SharedContentCallToAction(item: item),
            ],
          ),
        ),
      ),
    );
  }
}

class _SharedVideoPreview extends StatefulWidget {
  const _SharedVideoPreview({required this.item});

  final PublicSharedContentItem item;

  @override
  State<_SharedVideoPreview> createState() => _SharedVideoPreviewState();
}

class _SharedVideoPreviewState extends State<_SharedVideoPreview> {
  bool _showTranscript = false;

  void _toggleTranscript() {
    setState(() => _showTranscript = !_showTranscript);
  }

  @override
  Widget build(BuildContext context) {
    final item = widget.item;
    final source = item.previewUrl.trim().isNotEmpty
        ? item.previewUrl
        : item.videoUrl;
    if (source.trim().isEmpty) {
      return const _SharedUnavailableMedia();
    }

    final hasTranscript = item.transcript?.segments.isNotEmpty == true;
    final videoColumn = Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        _SharedVideoCard(
          source: resolveMediaUrl(source),
          posterUrl: item.posterUrl.trim().isEmpty
              ? null
              : resolveMediaUrl(item.posterUrl),
          transcript: item.transcript,
          lockedAfterSeconds: item.previewSeconds,
        ),
        const SizedBox(height: 14),
        _SharedEngagementBar(item: item),
        const SizedBox(height: 12),
        _SharedLockedControls(
          item: item,
          transcriptVisible: _showTranscript,
          onToggleTranscript: hasTranscript ? _toggleTranscript : null,
        ),
        if (item.body.trim().isNotEmpty) ...[
          const SizedBox(height: 16),
          ExpandableContentLinkText(
            text: item.body,
            style: Theme.of(context).textTheme.bodyLarge,
            collapsedMaxLines: 6,
          ),
        ],
      ],
    );

    if (!hasTranscript || !_showTranscript) {
      return videoColumn;
    }

    return LayoutBuilder(
      builder: (context, constraints) {
        if (constraints.maxWidth >= 900) {
          return Row(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Expanded(flex: 7, child: videoColumn),
              const SizedBox(width: 20),
              Expanded(
                flex: 4,
                child: _SharedTranscriptList(track: item.transcript!),
              ),
            ],
          );
        }

        return Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            videoColumn,
            _SharedTranscriptList(track: item.transcript!),
          ],
        );
      },
    );
  }
}

class _SharedLivePreview extends StatelessWidget {
  const _SharedLivePreview({required this.item});

  final PublicSharedContentItem item;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final roomType = item.roomType.trim().isEmpty ? 'Live' : item.roomType;
    return Container(
      padding: const EdgeInsets.all(18),
      decoration: BoxDecoration(
        color: scheme.primaryContainer.withValues(alpha: 0.42),
        borderRadius: BorderRadius.circular(24),
        border: Border.all(color: scheme.outlineVariant),
      ),
      child: Row(
        children: [
          AppAvatar(
            label: item.hostName.trim().isEmpty ? 'Talkflix' : item.hostName,
            imageUrl: item.hostProfilePhotoUrl,
            radius: 30,
          ),
          const SizedBox(width: 14),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  item.title.trim().isEmpty ? 'Live room' : item.title,
                  style: Theme.of(context).textTheme.titleMedium?.copyWith(
                    fontWeight: FontWeight.w800,
                  ),
                ),
                const SizedBox(height: 4),
                Text(
                  '${roomType[0].toUpperCase()}${roomType.substring(1)} broadcast'
                  '${item.isPrivate ? ' · Private invite' : ''}',
                  style: Theme.of(context).textTheme.bodyMedium?.copyWith(
                    color: scheme.onSurfaceVariant,
                  ),
                ),
                if (item.hostName.trim().isNotEmpty) ...[
                  const SizedBox(height: 2),
                  Text(
                    'Hosted by ${item.hostName}',
                    style: Theme.of(context).textTheme.bodySmall?.copyWith(
                      color: scheme.onSurfaceVariant,
                    ),
                  ),
                ],
              ],
            ),
          ),
        ],
      ),
    );
  }
}

class _SharedProfilePreview extends StatelessWidget {
  const _SharedProfilePreview({required this.item});

  final PublicSharedContentItem item;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final displayName = item.profileName.trim().isEmpty
        ? 'Talkflix profile'
        : item.profileName.trim();
    return Container(
      padding: const EdgeInsets.all(18),
      decoration: BoxDecoration(
        color: scheme.surfaceContainerHighest.withValues(alpha: 0.72),
        borderRadius: BorderRadius.circular(24),
        border: Border.all(color: scheme.outlineVariant),
      ),
      child: Row(
        children: [
          AppAvatar(
            label: displayName,
            imageUrl: item.profilePhotoUrl,
            radius: 34,
          ),
          const SizedBox(width: 14),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  displayName,
                  style: Theme.of(
                    context,
                  ).textTheme.titleLarge?.copyWith(fontWeight: FontWeight.w800),
                ),
                if (item.profileUsername.trim().isNotEmpty) ...[
                  const SizedBox(height: 3),
                  Text(
                    '@${item.profileUsername}',
                    style: Theme.of(context).textTheme.bodyMedium?.copyWith(
                      color: scheme.onSurfaceVariant,
                    ),
                  ),
                ],
                const SizedBox(height: 6),
                Text(
                  'Open this profile in Talkflix to follow, message, and connect.',
                  style: Theme.of(context).textTheme.bodyMedium?.copyWith(
                    color: scheme.onSurfaceVariant,
                  ),
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }
}

class _SharedEngagementBar extends StatelessWidget {
  const _SharedEngagementBar({required this.item});

  final PublicSharedContentItem item;

  Future<void> _share() async {
    final url = item.shareUrl.trim().isNotEmpty
        ? item.shareUrl.trim()
        : item.webPreviewUrl.trim();
    if (url.isEmpty) return;
    await Share.share(url);
  }

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final textStyle = Theme.of(context).textTheme.labelLarge?.copyWith(
      color: scheme.onSurfaceVariant,
      fontWeight: FontWeight.w800,
    );

    return Wrap(
      spacing: 12,
      runSpacing: 10,
      crossAxisAlignment: WrapCrossAlignment.center,
      children: [
        _SharedEngagementPill(
          icon: Icons.favorite_border_rounded,
          label: _sharedCompactCount(item.likeCount),
          textStyle: textStyle,
        ),
        _SharedEngagementPill(
          icon: Icons.mode_comment_outlined,
          label: _sharedCompactCount(item.commentCount),
          textStyle: textStyle,
        ),
        OutlinedButton.icon(
          onPressed: () => unawaited(_share()),
          icon: const Icon(Icons.ios_share_rounded),
          label: const Text('Share'),
        ),
      ],
    );
  }
}

class _SharedEngagementPill extends StatelessWidget {
  const _SharedEngagementPill({
    required this.icon,
    required this.label,
    required this.textStyle,
  });

  final IconData icon;
  final String label;
  final TextStyle? textStyle;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return Container(
      height: 40,
      padding: const EdgeInsets.symmetric(horizontal: 14),
      decoration: BoxDecoration(
        color: scheme.surfaceContainerLow,
        borderRadius: BorderRadius.circular(999),
        border: Border.all(color: scheme.outlineVariant),
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          Icon(icon, size: 19, color: scheme.onSurfaceVariant),
          const SizedBox(width: 7),
          Text(label, style: textStyle),
        ],
      ),
    );
  }
}

class _SharedLockedControls extends StatelessWidget {
  const _SharedLockedControls({
    required this.item,
    required this.transcriptVisible,
    required this.onToggleTranscript,
  });

  final PublicSharedContentItem item;
  final bool transcriptVisible;
  final VoidCallback? onToggleTranscript;

  Future<void> _requireLoginForSubtitles(BuildContext context) {
    return _showLoginRequiredDialog(
      context: context,
      title: 'Log in to change subtitles',
      message:
          'You can watch this video and read the original subtitles here. Log in to switch subtitle languages.',
    );
  }

  Future<void> _requireLoginForComments(BuildContext context) {
    return _showLoginRequiredDialog(
      context: context,
      title: 'Log in to join comments',
      message:
          'You can watch this shared video while logged out. Log in to view comments or add your own.',
    );
  }

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final language = item.transcript?.languageCode.trim();
    final subtitleLabel = language == null || language.isEmpty
        ? 'Subtitles'
        : 'Subtitles: ${language.toUpperCase()}';

    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Wrap(
          spacing: 12,
          runSpacing: 10,
          children: [
            OutlinedButton.icon(
              onPressed: onToggleTranscript,
              icon: const Icon(Icons.article_outlined),
              label: Text(
                transcriptVisible
                    ? 'Hide full subtitles'
                    : 'View full subtitles',
              ),
            ),
            OutlinedButton.icon(
              onPressed: () => unawaited(_requireLoginForSubtitles(context)),
              icon: const Icon(Icons.translate_rounded),
              label: Text(subtitleLabel),
            ),
            OutlinedButton.icon(
              onPressed: () => unawaited(_requireLoginForComments(context)),
              icon: const Icon(Icons.mode_comment_outlined),
              label: Text(
                'Comments (${_sharedCompactCount(item.commentCount)})',
              ),
            ),
          ],
        ),
        const SizedBox(height: 8),
        Text(
          'Subtitle language changes and comments require login.',
          style: Theme.of(
            context,
          ).textTheme.bodySmall?.copyWith(color: scheme.onSurfaceVariant),
        ),
      ],
    );
  }
}

class _SharedTranscriptList extends StatelessWidget {
  const _SharedTranscriptList({required this.track});

  final ContentTranscriptTrack track;

  String _formatMs(int ms) {
    final duration = Duration(milliseconds: ms);
    final minutes = duration.inMinutes.remainder(60).toString().padLeft(2, '0');
    final seconds = duration.inSeconds.remainder(60).toString().padLeft(2, '0');
    return '$minutes:$seconds';
  }

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final segments = track.segments;
    if (segments.isEmpty) return const SizedBox.shrink();

    return Padding(
      padding: const EdgeInsets.only(top: 18),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(
            'Full subtitles',
            style: Theme.of(
              context,
            ).textTheme.titleMedium?.copyWith(fontWeight: FontWeight.w800),
          ),
          const SizedBox(height: 10),
          for (final segment in segments) ...[
            Container(
              width: double.infinity,
              padding: const EdgeInsets.fromLTRB(14, 12, 14, 12),
              decoration: BoxDecoration(
                color: scheme.surfaceContainerLow,
                borderRadius: BorderRadius.circular(16),
                border: Border.all(color: scheme.outlineVariant),
              ),
              child: Row(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  SizedBox(
                    width: 52,
                    child: Text(
                      _formatMs(segment.startMs),
                      style: Theme.of(context).textTheme.labelMedium?.copyWith(
                        color: scheme.onSurfaceVariant,
                        fontWeight: FontWeight.w800,
                      ),
                    ),
                  ),
                  const SizedBox(width: 10),
                  Expanded(
                    child: Text(
                      segment.text,
                      style: Theme.of(context).textTheme.bodyMedium?.copyWith(
                        height: 1.35,
                        fontWeight: FontWeight.w600,
                      ),
                    ),
                  ),
                ],
              ),
            ),
            const SizedBox(height: 8),
          ],
        ],
      ),
    );
  }
}

class _SharedUnavailableMedia extends StatelessWidget {
  const _SharedUnavailableMedia();

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return Container(
      padding: const EdgeInsets.all(20),
      decoration: BoxDecoration(
        color: scheme.surfaceContainerHighest,
        borderRadius: BorderRadius.circular(20),
      ),
      child: Text(
        'This media preview is unavailable right now.',
        style: Theme.of(
          context,
        ).textTheme.bodyMedium?.copyWith(color: scheme.onSurfaceVariant),
      ),
    );
  }
}

class _SharedContentCallToAction extends StatelessWidget {
  const _SharedContentCallToAction({required this.item});

  final PublicSharedContentItem item;

  Future<void> _openApp() async {
    final target = item.appShareUrl.trim().isNotEmpty
        ? item.appShareUrl.trim()
        : item.shareUrl.trim();
    if (target.isEmpty) return;
    await launchUrl(Uri.parse(target), mode: LaunchMode.externalApplication);
  }

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return Container(
      padding: const EdgeInsets.all(16),
      decoration: BoxDecoration(
        color: scheme.surfaceContainerHighest.withValues(alpha: 0.62),
        borderRadius: BorderRadius.circular(20),
        border: Border.all(color: scheme.outlineVariant),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Text(
            'Continue in Talkflix',
            style: Theme.of(
              context,
            ).textTheme.titleMedium?.copyWith(fontWeight: FontWeight.w800),
          ),
          const SizedBox(height: 6),
          Text(
            'Sign in or open the app to like, comment, follow, and watch full shared videos.',
            style: Theme.of(
              context,
            ).textTheme.bodyMedium?.copyWith(color: scheme.onSurfaceVariant),
          ),
          const SizedBox(height: 14),
          Row(
            children: [
              Expanded(
                child: FilledButton(
                  onPressed: _openApp,
                  child: const Text('Open app'),
                ),
              ),
              const SizedBox(width: 12),
              Expanded(
                child: OutlinedButton(
                  onPressed: () => context.go(_signupRedirectForCurrentPage()),
                  child: const Text('Sign up'),
                ),
              ),
            ],
          ),
        ],
      ),
    );
  }
}

class _SharedContentLoadingScreen extends StatelessWidget {
  const _SharedContentLoadingScreen({this.label = 'Opening shared content…'});

  final String label;

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      body: Center(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            const CircularProgressIndicator(),
            const SizedBox(height: 16),
            Text(label),
          ],
        ),
      ),
    );
  }
}

class _SharedContentErrorScreen extends StatelessWidget {
  const _SharedContentErrorScreen({
    required this.message,
    required this.onRetry,
  });

  final String message;
  final Future<void> Function() onRetry;

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: const Text('Shared content')),
      body: Center(
        child: Padding(
          padding: const EdgeInsets.all(24),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              Text(message, textAlign: TextAlign.center),
              const SizedBox(height: 16),
              FilledButton(
                onPressed: () => unawaited(onRetry()),
                child: const Text('Try again'),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

class _SharedVideoCard extends StatefulWidget {
  const _SharedVideoCard({
    required this.source,
    this.posterUrl,
    this.transcript,
    this.lockedAfterSeconds = 0,
  });

  final String source;
  final String? posterUrl;
  final ContentTranscriptTrack? transcript;
  final int lockedAfterSeconds;

  @override
  State<_SharedVideoCard> createState() => _SharedVideoCardState();
}

class _SharedVideoCardState extends State<_SharedVideoCard> {
  VideoPlayerController? _controller;
  bool _initializing = true;
  bool _playbackFailed = false;
  bool _locked = false;

  ContentTranscriptSegment? _captionAtMilliseconds(int positionMs) {
    final segments = widget.transcript?.segments ?? const [];
    if (segments.isEmpty) return null;
    final effectivePositionMs = _subtitleMatchPositionMs(positionMs);
    for (final segment in segments) {
      if (effectivePositionMs >= segment.startMs &&
          effectivePositionMs <= segment.endMs) {
        return segment;
      }
    }
    return null;
  }

  @override
  void initState() {
    super.initState();
    unawaited(_initialize());
  }

  @override
  void didUpdateWidget(covariant _SharedVideoCard oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.source != widget.source ||
        oldWidget.lockedAfterSeconds != widget.lockedAfterSeconds) {
      unawaited(_disposeController());
      unawaited(_initialize());
    }
  }

  Future<void> _initialize() async {
    setState(() {
      _initializing = true;
      _playbackFailed = false;
      _locked = false;
    });
    final controller = VideoPlayerController.networkUrl(
      Uri.parse(widget.source),
    );
    try {
      await controller.initialize();
      await controller.setLooping(true);
      controller.addListener(() {
        if (!mounted || _locked || widget.lockedAfterSeconds <= 0) return;
        final limit = Duration(seconds: widget.lockedAfterSeconds);
        if (controller.value.position < limit) return;
        unawaited(controller.pause());
        unawaited(controller.seekTo(limit));
        setState(() => _locked = true);
      });
      if (!mounted) {
        await controller.dispose();
        return;
      }
      setState(() {
        _controller = controller;
        _initializing = false;
      });
    } catch (_) {
      await controller.dispose();
      if (!mounted) return;
      setState(() {
        _playbackFailed = true;
        _initializing = false;
      });
    }
  }

  Future<void> _disposeController() async {
    final controller = _controller;
    _controller = null;
    if (controller != null) {
      await controller.dispose();
    }
  }

  Future<void> _togglePlayback() async {
    final controller = _controller;
    if (controller == null || _locked) return;
    if (controller.value.isPlaying) {
      await controller.pause();
    } else {
      await controller.play();
    }
    if (mounted) {
      setState(() {});
    }
  }

  @override
  void dispose() {
    unawaited(_disposeController());
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final controller = _controller;
    return ValueListenableBuilder<VideoPlayerValue>(
      valueListenable:
          controller ??
          ValueNotifier(const VideoPlayerValue(duration: Duration.zero)),
      builder: (context, value, _) {
        final caption = _captionAtMilliseconds(value.position.inMilliseconds);
        final scheme = Theme.of(context).colorScheme;
        return ClipRRect(
          borderRadius: BorderRadius.circular(24),
          child: Container(
            color: Colors.black,
            child: AspectRatio(
              aspectRatio: controller?.value.aspectRatio ?? (16 / 9),
              child: Stack(
                fit: StackFit.expand,
                children: [
                  if (controller != null && controller.value.isInitialized)
                    AbsorbPointer(child: VideoPlayer(controller))
                  else if ((widget.posterUrl ?? '').trim().isNotEmpty)
                    Image.network(widget.posterUrl!, fit: BoxFit.cover)
                  else
                    const DecoratedBox(
                      decoration: BoxDecoration(color: Colors.black),
                    ),
                  if (_initializing)
                    const Center(child: CircularProgressIndicator())
                  else if (_playbackFailed)
                    const Center(
                      child: Icon(
                        Icons.error_outline_rounded,
                        color: Colors.white70,
                        size: 40,
                      ),
                    )
                  else if (caption != null)
                    Positioned(
                      left: 16,
                      right: 16,
                      bottom: 18,
                      child: DecoratedBox(
                        decoration: BoxDecoration(
                          color: scheme.primaryContainer.withValues(
                            alpha: 0.92,
                          ),
                          borderRadius: BorderRadius.circular(14),
                          border: Border.all(
                            color: scheme.primary.withValues(alpha: 0.55),
                          ),
                        ),
                        child: Padding(
                          padding: const EdgeInsets.symmetric(
                            horizontal: 14,
                            vertical: 10,
                          ),
                          child: Text(
                            caption.text,
                            textAlign: TextAlign.center,
                            style: TextStyle(
                              color: scheme.onPrimaryContainer,
                              fontWeight: FontWeight.w800,
                            ),
                          ),
                        ),
                      ),
                    ),
                  if (_locked)
                    Positioned.fill(
                      child: DecoratedBox(
                        decoration: BoxDecoration(
                          color: Colors.black.withValues(alpha: 0.72),
                        ),
                        child: Center(
                          child: Padding(
                            padding: const EdgeInsets.all(20),
                            child: Column(
                              mainAxisSize: MainAxisSize.min,
                              children: [
                                const Icon(
                                  Icons.lock_rounded,
                                  color: Colors.white,
                                  size: 36,
                                ),
                                const SizedBox(height: 10),
                                Text(
                                  'Continue in Talkflix to watch the full video.',
                                  textAlign: TextAlign.center,
                                  style: Theme.of(context).textTheme.titleMedium
                                      ?.copyWith(
                                        color: Colors.white,
                                        fontWeight: FontWeight.w800,
                                      ),
                                ),
                              ],
                            ),
                          ),
                        ),
                      ),
                    )
                  else if (!_initializing && !_playbackFailed)
                    Center(
                      child: AnimatedOpacity(
                        opacity: controller?.value.isPlaying == true ? 0 : 1,
                        duration: const Duration(milliseconds: 180),
                        child: Container(
                          width: 58,
                          height: 58,
                          decoration: BoxDecoration(
                            color: scheme.primary,
                            shape: BoxShape.circle,
                          ),
                          child: const Icon(
                            Icons.play_arrow_rounded,
                            color: Colors.white,
                            size: 34,
                          ),
                        ),
                      ),
                    ),
                  if (!_initializing && !_playbackFailed && !_locked)
                    Positioned.fill(
                      child: GestureDetector(
                        behavior: HitTestBehavior.opaque,
                        onTap: () => unawaited(_togglePlayback()),
                      ),
                    ),
                ],
              ),
            ),
          ),
        );
      },
    );
  }
}
