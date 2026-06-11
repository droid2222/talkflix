import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';
import 'package:share_plus/share_plus.dart';
import 'package:video_player/video_player.dart';

import '../../../app/localization/app_language_controller.dart';
import '../../../core/auth/session_controller.dart';
import '../../../core/media/media_utils.dart';
import '../../../core/network/api_exception.dart';
import '../application/saved_content_controller.dart';
import '../data/content_repository.dart';
import 'content_engagement_controls.dart';
import 'content_ui_utils.dart';

const int _subtitleAdvanceLeadMs = 140;

int _subtitleMatchPositionMs(int positionMs) {
  return positionMs + _subtitleAdvanceLeadMs;
}

class ContentVideoScreen extends ConsumerStatefulWidget {
  const ContentVideoScreen({super.key, required this.videoId});

  final String videoId;

  @override
  ConsumerState<ContentVideoScreen> createState() => _ContentVideoScreenState();
}

class _ContentVideoScreenState extends ConsumerState<ContentVideoScreen> {
  ContentVideoDetail? _detail;
  ContentTranscriptTrack? _activeTrack;
  VideoPlayerController? _videoController;
  final ScrollController _transcriptScrollController = ScrollController();
  List<GlobalKey> _transcriptSegmentKeys = const <GlobalKey>[];
  Timer? _watchUsageTimer;
  Timer? _transcriptPollTimer;
  Timer? _resumeTranscriptAutoFollowTimer;
  int? _scrubDragMs;
  int? _lastAutoFollowIndex;
  bool _resumeAfterScrub = false;
  DateTime? _lastPreviewScrubSeekAt;
  bool _loading = true;
  bool _loadingTrack = false;
  bool _suspendTranscriptAutoFollow = false;
  bool _generatingTranscript = false;
  bool _autoGeneratingTranscript = false;
  bool _translatingTrack = false;
  bool _viewSynced = false;
  bool _likeBusy = false;
  int _likeCount = 0;
  int _commentCount = 0;
  int _viewCount = 0;
  bool _likedByMe = false;
  bool _savedByMe = false;
  bool _watchUsageBusy = false;
  bool _watchLimitReached = false;
  String? _error;

  @override
  void initState() {
    super.initState();
    _watchUsageTimer = Timer.periodic(const Duration(seconds: 15), (_) {
      unawaited(_recordActiveWatchSeconds(15));
    });
    unawaited(_load());
  }

  @override
  void dispose() {
    _watchUsageTimer?.cancel();
    _transcriptPollTimer?.cancel();
    _resumeTranscriptAutoFollowTimer?.cancel();
    _transcriptScrollController.dispose();
    unawaited(_videoController?.dispose());
    super.dispose();
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

  void _ensureTranscriptSegmentKeys(int count) {
    if (_transcriptSegmentKeys.length == count) return;
    _transcriptSegmentKeys = List<GlobalKey>.generate(
      count,
      (index) => GlobalKey(debugLabel: 'video-transcript-segment-$index'),
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

  bool _isTranscriptRowWithinReadingBand(BuildContext rowContext) {
    final rowBox = rowContext.findRenderObject() as RenderBox?;
    final scrollBox =
        _transcriptScrollController.position.context.storageContext
                .findRenderObject()
            as RenderBox?;
    if (rowBox == null || scrollBox == null) return false;
    final top = rowBox.localToGlobal(Offset.zero, ancestor: scrollBox).dy;
    final bottom = top + rowBox.size.height;
    final viewportHeight = scrollBox.size.height;
    final minBand = viewportHeight * 0.18;
    final maxBand = viewportHeight * 0.62;
    return top >= minBand && bottom <= maxBand;
  }

  void _scrollTranscriptSegmentIntoView(int index) {
    if (!mounted ||
        _suspendTranscriptAutoFollow ||
        !_transcriptScrollController.hasClients ||
        index < 0 ||
        index >= _transcriptSegmentKeys.length) {
      return;
    }
    final rowContext = _transcriptSegmentKeys[index].currentContext;
    if (rowContext == null) return;
    if (_isTranscriptRowWithinReadingBand(rowContext)) return;
    unawaited(
      Scrollable.ensureVisible(
        rowContext,
        alignment: 0.28,
        duration: const Duration(milliseconds: 260),
        curve: Curves.easeOutCubic,
      ),
    );
  }

  void _handleActiveTranscriptSegmentChanged(int index) {
    if (index < 0 || _lastAutoFollowIndex == index) return;
    _lastAutoFollowIndex = index;
    WidgetsBinding.instance.addPostFrameCallback((_) {
      _scrollTranscriptSegmentIntoView(index);
    });
  }

  bool _handleTranscriptScrollNotification(ScrollNotification notification) {
    if (notification is ScrollStartNotification &&
        notification.dragDetails != null) {
      _resumeTranscriptAutoFollowTimer?.cancel();
      _suspendTranscriptAutoFollow = true;
    } else if (notification is ScrollUpdateNotification &&
        notification.dragDetails != null) {
      _resumeTranscriptAutoFollowTimer?.cancel();
      _suspendTranscriptAutoFollow = true;
    } else if (notification is ScrollEndNotification &&
        _suspendTranscriptAutoFollow) {
      _resumeTranscriptAutoFollowTimer?.cancel();
      _resumeTranscriptAutoFollowTimer = Timer(
        const Duration(milliseconds: 1400),
        () {
          if (!mounted) return;
          _suspendTranscriptAutoFollow = false;
          final positionMs =
              _videoController?.value.position.inMilliseconds ?? 0;
          final activeIndex = _activeSegmentIndexAtMilliseconds(positionMs);
          if (activeIndex >= 0) {
            _lastAutoFollowIndex = activeIndex;
            WidgetsBinding.instance.addPostFrameCallback((_) {
              _scrollTranscriptSegmentIntoView(activeIndex);
            });
          }
        },
      );
    }
    return false;
  }

  bool get _isOwner {
    final userId = ref.read(sessionControllerProvider).user?.id;
    return userId != null && userId.isNotEmpty && userId == _detail?.userId;
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

  bool _shouldPollTranscript(ContentVideoDetail detail) {
    if (detail.transcripts.isNotEmpty) return false;
    return detail.transcriptStatus == 'pending' ||
        detail.transcriptStatus == 'processing';
  }

  void _syncTranscriptPolling(ContentVideoDetail detail) {
    if (_shouldPollTranscript(detail)) {
      _transcriptPollTimer ??= Timer(const Duration(seconds: 3), () {
        _transcriptPollTimer = null;
        unawaited(_pollTranscriptState());
      });
      return;
    }
    _transcriptPollTimer?.cancel();
    _transcriptPollTimer = null;
  }

  Future<void> _load({String? preferredLanguageCode}) async {
    setState(() {
      _loading = true;
      _error = null;
    });
    try {
      final repo = ref.read(contentRepositoryProvider);
      final detail = await repo.fetchVideoDetail(widget.videoId);
      final sourceTrack = _preferredTrackMeta(
        detail,
        preferredLanguageCode: preferredLanguageCode,
      );
      final selectedLanguage = sourceTrack?.languageCode ?? detail.sourceLocale;
      ContentTranscriptTrack? activeTrack;
      if (detail.transcripts.isNotEmpty) {
        activeTrack = await repo.fetchVideoTranscriptTrack(
          contentId: widget.videoId,
          languageCode: selectedLanguage,
        );
      }
      await _ensureVideoController(detail.videoUrl);
      if (!mounted) return;
      setState(() {
        _detail = detail;
        _activeTrack = activeTrack;
        _likeCount = detail.likeCount;
        _commentCount = detail.commentCount;
        _viewCount = detail.viewCount;
        _likedByMe = detail.likedByMe;
        _savedByMe = detail.savedByMe;
        _loading = false;
      });
      _syncTranscriptPolling(detail);
      unawaited(_recordViewOnce());
      if (detail.transcripts.isEmpty && detail.transcriptStatus == 'none') {
        unawaited(_requestTranscriptGeneration(showErrors: false));
      }
    } catch (error) {
      if (!mounted) return;
      setState(() {
        _error = userFriendlyMessageFromObject(error);
        _loading = false;
      });
    }
  }

  Future<void> _pollTranscriptState({String? preferredLanguageCode}) async {
    try {
      final repo = ref.read(contentRepositoryProvider);
      final detail = await repo.fetchVideoDetail(widget.videoId);
      final preferredTrack = _preferredTrackMeta(
        detail,
        preferredLanguageCode:
            preferredLanguageCode ?? _activeTrack?.languageCode,
      );
      ContentTranscriptTrack? activeTrack = _activeTrack;
      if (preferredTrack != null) {
        activeTrack = await repo.fetchVideoTranscriptTrack(
          contentId: widget.videoId,
          languageCode: preferredTrack.languageCode,
        );
      }
      if (!mounted) return;
      setState(() {
        _detail = detail;
        _activeTrack = activeTrack;
      });
      _syncTranscriptPolling(detail);
    } catch (_) {
      if (!mounted || _detail == null) return;
      _syncTranscriptPolling(_detail!);
    } finally {
      if (mounted) setState(() => _autoGeneratingTranscript = false);
    }
  }

  Future<void> _requestTranscriptGeneration({required bool showErrors}) async {
    if (_autoGeneratingTranscript || _generatingTranscript) return;
    setState(() => _autoGeneratingTranscript = true);
    try {
      final result = await ref
          .read(contentRepositoryProvider)
          .generateVideoTranscript(widget.videoId);
      if (!mounted) return;
      if (result.isReady && result.track != null) {
        await _load(preferredLanguageCode: result.track!.languageCode);
        return;
      }
      await _pollTranscriptState();
    } catch (error) {
      if (!mounted) return;
      if (showErrors) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text(userFriendlyMessageFromObject(error))),
        );
      }
      setState(() => _autoGeneratingTranscript = false);
    }
  }

  Future<void> _ensureVideoController(String videoUrl) async {
    final resolvedUrl = resolveMediaUrl(videoUrl);
    if (_videoController != null &&
        _videoController!.dataSource == resolvedUrl) {
      return;
    }
    await _videoController?.dispose();
    final controller = VideoPlayerController.networkUrl(Uri.parse(resolvedUrl));
    await controller.initialize();
    await controller.setLooping(false);
    _videoController = controller;
  }

  Future<void> _recordViewOnce() async {
    if (!mounted || _viewSynced) return;
    _viewSynced = true;
    try {
      final state = await ref
          .read(contentRepositoryProvider)
          .recordView(widget.videoId);
      if (!mounted) return;
      setState(() => _viewCount = state.viewCount);
    } catch (_) {}
  }

  Future<void> _recordActiveWatchSeconds(int seconds) async {
    if (!mounted || _watchUsageBusy || _watchLimitReached) return;
    final controller = _videoController;
    if (controller == null ||
        !controller.value.isInitialized ||
        !controller.value.isPlaying) {
      return;
    }
    _watchUsageBusy = true;
    try {
      await ref
          .read(contentRepositoryProvider)
          .recordContentWatchSeconds(seconds);
    } on ApiException catch (error) {
      if (error.statusCode == 402) {
        _watchLimitReached = true;
        await controller.pause();
        if (!mounted) return;
        final feature = Uri.encodeQueryComponent('Unlimited watch time');
        context.go('/app/upgrade?feature=$feature');
      }
    } catch (_) {
      // Watch accounting must not crash playback for transient network issues.
    } finally {
      _watchUsageBusy = false;
    }
  }

  Future<void> _toggleLike() async {
    if (_likeBusy) return;
    setState(() => _likeBusy = true);
    try {
      final repo = ref.read(contentRepositoryProvider);
      final state = _likedByMe
          ? await repo.unlikeContent(widget.videoId)
          : await repo.likeContent(widget.videoId);
      if (!mounted) return;
      setState(() {
        _likedByMe = state.likedByMe;
        _likeCount = state.likeCount;
      });
    } catch (error) {
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text(userFriendlyMessageFromObject(error))),
      );
    } finally {
      if (mounted) setState(() => _likeBusy = false);
    }
  }

  Future<void> _share(BuildContext anchorContext) async {
    try {
      final share = await ref
          .read(contentRepositoryProvider)
          .createContentShareLink(widget.videoId);
      final text = share.shareUrl.trim();
      if (text.isEmpty) return;
      await Share.share(text);
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
        ? savedState.ids.contains(widget.videoId)
        : _savedByMe;
    await ref
        .read(savedContentIdsProvider.notifier)
        .setSaved(contentId: widget.videoId, saved: !currentlySaved);
    if (!mounted) return;
    setState(() => _savedByMe = !currentlySaved);
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(
        content: Text(
          currentlySaved ? 'Video removed from saved.' : 'Video saved.',
        ),
      ),
    );
  }

  Future<void> _openComments() async {
    final result = await showModalBottomSheet<int>(
      context: context,
      isScrollControlled: true,
      showDragHandle: true,
      useSafeArea: true,
      backgroundColor: Theme.of(context).colorScheme.surface,
      builder: (context) => FractionallySizedBox(
        heightFactor: 0.94,
        child: _VideoCommentsSheet(
          contentId: widget.videoId,
          initialCommentCount: _commentCount,
        ),
      ),
    );
    if (!mounted || result == null) return;
    setState(() => _commentCount = result);
  }

  Future<void> _togglePlayback() async {
    final controller = _videoController;
    if (controller == null) return;
    if (controller.value.isPlaying) {
      await controller.pause();
    } else {
      await controller.play();
    }
    if (mounted) setState(() {});
  }

  Future<void> _selectTrackLanguage(String languageCode) async {
    if (_loadingTrack || _detail == null) return;
    setState(() => _loadingTrack = true);
    try {
      final track = await ref
          .read(contentRepositoryProvider)
          .fetchVideoTranscriptTrack(
            contentId: widget.videoId,
            languageCode: languageCode,
          );
      if (!mounted) return;
      setState(() {
        _activeTrack = track;
      });
    } catch (error) {
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text(userFriendlyMessageFromObject(error))),
      );
    } finally {
      if (mounted) setState(() => _loadingTrack = false);
    }
  }

  Future<void> _generateTranscript() async {
    if (_generatingTranscript) return;
    setState(() => _generatingTranscript = true);
    try {
      await _requestTranscriptGeneration(showErrors: true);
    } catch (error) {
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text(userFriendlyMessageFromObject(error))),
      );
    } finally {
      if (mounted) setState(() => _generatingTranscript = false);
    }
  }

  Future<void> _translateTranscript() async {
    if (_translatingTrack) return;
    final choice = await showModalBottomSheet<String>(
      context: context,
      showDragHandle: true,
      builder: (context) {
        final existingLanguages = {
          for (final track
              in _detail?.transcripts ?? const <ContentTranscriptTrack>[])
            track.languageCode,
        };
        return SafeArea(
          child: ListView(
            shrinkWrap: true,
            children: [
              for (final option in appLanguageOptions)
                if (option.locale != null)
                  ListTile(
                    title: Text(option.label),
                    trailing:
                        existingLanguages.contains(option.locale!.languageCode)
                        ? const Icon(Icons.check_circle_outline)
                        : null,
                    onTap: () =>
                        Navigator.of(context).pop(option.locale!.languageCode),
                  ),
            ],
          ),
        );
      },
    );
    if (choice == null || choice.isEmpty) return;
    setState(() => _translatingTrack = true);
    try {
      final track = await ref
          .read(contentRepositoryProvider)
          .translateVideoTranscript(
            contentId: widget.videoId,
            languageCode: choice,
          );
      if (!mounted) return;
      await _load(preferredLanguageCode: track.languageCode);
    } catch (error) {
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text(userFriendlyMessageFromObject(error))),
      );
    } finally {
      if (mounted) setState(() => _translatingTrack = false);
    }
  }

  Future<void> _seekToSegment(ContentTranscriptSegment segment) async {
    await _seekToMilliseconds(segment.startMs, playIfPaused: true);
  }

  Future<void> _seekToMilliseconds(
    int targetMs, {
    bool playIfPaused = false,
  }) async {
    final controller = _videoController;
    if (controller == null) return;
    final durationMs = controller.value.duration.inMilliseconds;
    final clamped = durationMs <= 0
        ? targetMs
        : targetMs.clamp(0, durationMs).toInt();
    await controller.seekTo(Duration(milliseconds: clamped));
    if (playIfPaused && !controller.value.isPlaying) {
      await controller.play();
    }
    if (mounted) setState(() {});
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

  void _handleScrubStart(double value) {
    final controller = _videoController;
    _resumeAfterScrub = controller?.value.isPlaying == true;
    if (controller?.value.isPlaying == true) {
      unawaited(controller!.pause());
    }
    setState(() => _scrubDragMs = value.round());
  }

  void _handleScrubChanged(double value) {
    final ms = value.round();
    setState(() => _scrubDragMs = ms);
    final controller = _videoController;
    if (controller == null) return;
    final now = DateTime.now();
    if (_lastPreviewScrubSeekAt != null &&
        now.difference(_lastPreviewScrubSeekAt!).inMilliseconds < 90) {
      return;
    }
    _lastPreviewScrubSeekAt = now;
    unawaited(_seekToMilliseconds(ms));
  }

  Future<void> _handleScrubEnd(double value) async {
    final targetMs = value.round();
    setState(() => _scrubDragMs = null);
    await _seekToMilliseconds(targetMs);
    if (_resumeAfterScrub && _videoController != null) {
      await _videoController!.play();
    }
    _resumeAfterScrub = false;
    if (mounted) setState(() {});
  }

  String _formatClock(Duration value) {
    final totalSeconds = value.inSeconds;
    final hours = totalSeconds ~/ 3600;
    final minutes = (totalSeconds % 3600) ~/ 60;
    final seconds = totalSeconds % 60;
    if (hours > 0) {
      return '${hours.toString()}:${minutes.toString().padLeft(2, '0')}:${seconds.toString().padLeft(2, '0')}';
    }
    return '${minutes.toString()}:${seconds.toString().padLeft(2, '0')}';
  }

  Future<void> _openTranscriptEditor() async {
    final detail = _detail;
    final track = _activeTrack;
    if (!_isOwner || detail == null || track == null) return;
    final updated = await Navigator.of(context).push<ContentTranscriptTrack>(
      MaterialPageRoute<ContentTranscriptTrack>(
        builder: (context) => ContentTranscriptEditorScreen(
          videoId: widget.videoId,
          title: detail.title,
          track: track,
        ),
      ),
    );
    if (!mounted || updated == null) return;
    setState(() => _activeTrack = updated);
    await _load(preferredLanguageCode: updated.languageCode);
  }

  String _formatMs(int ms) {
    final totalSeconds = ms ~/ 1000;
    final minutes = totalSeconds ~/ 60;
    final seconds = totalSeconds % 60;
    return '${minutes.toString().padLeft(2, '0')}:${seconds.toString().padLeft(2, '0')}';
  }

  Widget _buildPosterPlaceholder(String label) {
    final posterUrl = _detail?.posterUrl.trim() ?? '';
    return AspectRatio(
      aspectRatio: 16 / 9,
      child: Stack(
        fit: StackFit.expand,
        children: [
          if (posterUrl.isNotEmpty)
            Image.network(
              resolveMediaUrl(posterUrl),
              fit: BoxFit.cover,
              loadingBuilder: (context, child, loadingProgress) =>
                  loadingProgress == null ? child : const SizedBox.shrink(),
              errorBuilder: (context, error, stackTrace) => const DecoratedBox(
                decoration: BoxDecoration(color: Colors.black),
              ),
            )
          else
            const DecoratedBox(decoration: BoxDecoration(color: Colors.black)),
          DecoratedBox(
            decoration: BoxDecoration(
              color: Colors.black.withValues(
                alpha: posterUrl.isEmpty ? 0 : 0.28,
              ),
            ),
          ),
          Center(
            child: Text(
              label,
              style: TextStyle(
                color: Colors.white.withValues(alpha: 0.86),
                fontWeight: FontWeight.w700,
              ),
              textAlign: TextAlign.center,
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildVideoSurface(ColorScheme scheme) {
    final controller = _videoController;
    if (controller == null || !controller.value.isInitialized) {
      return _buildPosterPlaceholder('Video unavailable');
    }

    return ValueListenableBuilder<VideoPlayerValue>(
      valueListenable: controller,
      builder: (context, value, _) {
        final effectivePositionMs =
            _scrubDragMs ?? value.position.inMilliseconds;
        final caption = _captionAtMilliseconds(effectivePositionMs);
        return AspectRatio(
          aspectRatio: value.aspectRatio <= 0 ? 16 / 9 : value.aspectRatio,
          child: Stack(
            alignment: Alignment.bottomCenter,
            children: [
              Positioned.fill(
                child: AbsorbPointer(child: VideoPlayer(controller)),
              ),
              if (!value.isPlaying)
                Positioned.fill(
                  child: Center(
                    child: Container(
                      width: 78,
                      height: 78,
                      decoration: BoxDecoration(
                        color: Colors.black.withValues(alpha: 0.42),
                        shape: BoxShape.circle,
                      ),
                      child: const Icon(
                        Icons.play_arrow_rounded,
                        color: Colors.white,
                        size: 46,
                      ),
                    ),
                  ),
                ),
              if (caption != null)
                Positioned(
                  left: 16,
                  right: 16,
                  bottom: 22,
                  child: DecoratedBox(
                    decoration: BoxDecoration(
                      color: scheme.primaryContainer.withValues(alpha: 0.92),
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
              Positioned.fill(
                child: GestureDetector(
                  behavior: HitTestBehavior.opaque,
                  onTap: () => unawaited(_togglePlayback()),
                ),
              ),
            ],
          ),
        );
      },
    );
  }

  Widget _buildPlaybackControls({
    required ContentVideoDetail detail,
    required VideoPlayerController? controller,
    required ColorScheme scheme,
  }) {
    return Padding(
      padding: const EdgeInsets.fromLTRB(16, 12, 16, 8),
      child: ValueListenableBuilder<VideoPlayerValue>(
        valueListenable:
            controller ??
            ValueNotifier(const VideoPlayerValue(duration: Duration.zero)),
        builder: (context, value, _) {
          final durationMs = value.duration.inMilliseconds;
          final sliderMax = durationMs <= 0 ? 1.0 : durationMs.toDouble();
          final sliderValue = (_scrubDragMs ?? value.position.inMilliseconds)
              .clamp(0, durationMs <= 0 ? 0 : durationMs)
              .toDouble();
          return Column(
            children: [
              Row(
                children: [
                  IconButton(
                    onPressed: controller == null ? null : _togglePlayback,
                    icon: Icon(
                      controller?.value.isPlaying == true
                          ? Icons.pause_circle_filled_rounded
                          : Icons.play_circle_fill_rounded,
                    ),
                  ),
                  Expanded(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Text(
                          detail.title,
                          style: Theme.of(context).textTheme.titleMedium
                              ?.copyWith(fontWeight: FontWeight.w800),
                        ),
                        Text(
                          '${detail.authorName} · ${_languageLabel(detail.sourceLocale)}',
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
                  onChangeStart: durationMs <= 0 ? null : _handleScrubStart,
                  onChanged: durationMs <= 0 ? null : _handleScrubChanged,
                  onChangeEnd: durationMs <= 0 ? null : _handleScrubEnd,
                ),
              ),
              Row(
                children: [
                  Text(
                    _formatClock(
                      Duration(
                        milliseconds:
                            (_scrubDragMs ?? value.position.inMilliseconds)
                                .clamp(0, durationMs <= 0 ? 0 : durationMs),
                      ),
                    ),
                    style: Theme.of(context).textTheme.labelMedium?.copyWith(
                      color: scheme.onSurfaceVariant,
                      fontWeight: FontWeight.w700,
                    ),
                  ),
                  const Spacer(),
                  Text(
                    _formatClock(value.duration),
                    style: Theme.of(context).textTheme.labelMedium?.copyWith(
                      color: scheme.onSurfaceVariant,
                      fontWeight: FontWeight.w700,
                    ),
                  ),
                ],
              ),
            ],
          );
        },
      ),
    );
  }

  Widget _buildTranscriptControls({
    required ContentVideoDetail detail,
    required List<String> transcriptLanguages,
  }) {
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 16),
      child: Row(
        children: [
          if (detail.transcripts.isEmpty && _isOwner)
            FilledButton.icon(
              onPressed: _generatingTranscript || _autoGeneratingTranscript
                  ? null
                  : _generateTranscript,
              icon: const Icon(Icons.subtitles_rounded),
              label: Text(
                _generatingTranscript ||
                        _autoGeneratingTranscript ||
                        detail.transcriptStatus == 'pending' ||
                        detail.transcriptStatus == 'processing'
                    ? 'Generating...'
                    : 'Generate transcript',
              ),
            )
          else if (transcriptLanguages.isNotEmpty)
            Expanded(
              child: DropdownButtonFormField<String>(
                key: ValueKey<String?>(_activeTrack?.languageCode),
                initialValue:
                    transcriptLanguages.contains(_activeTrack?.languageCode)
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
          if (_isOwner) ...[
            const SizedBox(width: 12),
            OutlinedButton.icon(
              onPressed: detail.transcripts.isEmpty || _translatingTrack
                  ? null
                  : _translateTranscript,
              icon: const Icon(Icons.add_circle_outline_rounded),
              label: Text(_translatingTrack ? 'Adding...' : 'Add language'),
            ),
          ],
        ],
      ),
    );
  }

  Widget _buildEngagementSection() {
    final savedState = ref.watch(savedContentIdsProvider);
    final saved = savedState.loaded
        ? savedState.ids.contains(widget.videoId)
        : _savedByMe;
    return Padding(
      padding: const EdgeInsets.fromLTRB(16, 4, 16, 8),
      child: ContentEngagementControls(
        likedByMe: _likedByMe,
        likeCount: _likeCount,
        commentCount: _commentCount,
        viewCount: _viewCount,
        likeBusy: _likeBusy,
        saved: saved,
        onLike: _toggleLike,
        onComments: () => unawaited(_openComments()),
        onShare: _share,
        onSave: () => unawaited(_toggleSaved()),
      ),
    );
  }

  Widget _buildTranscriptPane({
    required ContentVideoDetail detail,
    required VideoPlayerController? controller,
    required ColorScheme scheme,
  }) {
    return _activeTrack == null
        ? Center(
            child: Padding(
              padding: const EdgeInsets.all(24),
              child: Text(
                detail.transcripts.isEmpty
                    ? (_autoGeneratingTranscript ||
                              detail.transcriptStatus == 'pending' ||
                              detail.transcriptStatus == 'processing'
                          ? 'Generating subtitles…'
                          : detail.transcriptStatus == 'failed' &&
                                detail.transcriptErrorMessage.trim().isNotEmpty
                          ? detail.transcriptErrorMessage.trim()
                          : 'No transcript yet.')
                    : 'Pick a transcript language to view timed captions.',
                textAlign: TextAlign.center,
                style: Theme.of(context).textTheme.bodyMedium?.copyWith(
                  color: scheme.onSurfaceVariant,
                ),
              ),
            ),
          )
        : ValueListenableBuilder<VideoPlayerValue>(
            valueListenable:
                controller ??
                ValueNotifier(const VideoPlayerValue(duration: Duration.zero)),
            builder: (context, value, _) {
              final positionMs = value.position.inMilliseconds;
              final activeIndex = _activeSegmentIndexAtMilliseconds(positionMs);
              _ensureTranscriptSegmentKeys(_activeTrack!.segments.length);
              _handleActiveTranscriptSegmentChanged(activeIndex);
              return NotificationListener<ScrollNotification>(
                onNotification: _handleTranscriptScrollNotification,
                child: ListView(
                  controller: _transcriptScrollController,
                  padding: const EdgeInsets.fromLTRB(16, 8, 16, 24),
                  children: [
                    for (
                      var index = 0;
                      index < _activeTrack!.segments.length;
                      index++
                    ) ...[
                      if (index > 0) const SizedBox(height: 8),
                      KeyedSubtree(
                        key: _transcriptSegmentKeys[index],
                        child: Builder(
                          builder: (context) {
                            final segment = _activeTrack!.segments[index];
                            final active = index == activeIndex;
                            return Material(
                              color: active
                                  ? scheme.primaryContainer
                                  : scheme.surfaceContainerLow,
                              borderRadius: BorderRadius.circular(18),
                              child: InkWell(
                                borderRadius: BorderRadius.circular(18),
                                onTap: () => _seekToSegment(segment),
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
                                      Container(
                                        width: 4,
                                        height: 44,
                                        margin: const EdgeInsets.only(top: 2),
                                        decoration: BoxDecoration(
                                          color: active
                                              ? scheme.primary
                                              : Colors.transparent,
                                          borderRadius: BorderRadius.circular(
                                            999,
                                          ),
                                        ),
                                      ),
                                      const SizedBox(width: 12),
                                      SizedBox(
                                        width: 56,
                                        child: Text(
                                          _formatMs(segment.startMs),
                                          style: Theme.of(context)
                                              .textTheme
                                              .labelMedium
                                              ?.copyWith(
                                                color: active
                                                    ? scheme.onPrimaryContainer
                                                    : scheme.onSurfaceVariant,
                                                fontWeight: FontWeight.w700,
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
                                                    ? scheme.onPrimaryContainer
                                                    : null,
                                                fontWeight: active
                                                    ? FontWeight.w700
                                                    : FontWeight.w500,
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
          );
  }

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    if (_loading) {
      return const Scaffold(body: Center(child: CircularProgressIndicator()));
    }
    if (_error != null || _detail == null) {
      return Scaffold(
        appBar: AppBar(title: const Text('Video')),
        body: Center(
          child: Padding(
            padding: const EdgeInsets.all(24),
            child: Text(_error ?? 'Could not load video.'),
          ),
        ),
      );
    }
    final detail = _detail!;
    final controller = _videoController;
    final transcriptLanguages = {
      for (final track in detail.transcripts) track.languageCode,
      if (_activeTrack != null) _activeTrack!.languageCode,
    }.toList()..sort();

    return Scaffold(
      appBar: AppBar(
        title: Text(detail.title.isEmpty ? 'Video' : detail.title),
        actions: [
          if (_isOwner && _activeTrack != null)
            TextButton.icon(
              onPressed: _openTranscriptEditor,
              icon: const Icon(Icons.edit_note_rounded),
              label: const Text('Edit subtitles'),
            ),
        ],
      ),
      body: LayoutBuilder(
        builder: (context, constraints) {
          final videoArea = Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            mainAxisSize: MainAxisSize.min,
            children: [
              _buildVideoSurface(scheme),
              _buildPlaybackControls(
                detail: detail,
                controller: controller,
                scheme: scheme,
              ),
              _buildEngagementSection(),
              _buildTranscriptControls(
                detail: detail,
                transcriptLanguages: transcriptLanguages,
              ),
              const SizedBox(height: 8),
            ],
          );

          if (constraints.maxWidth >= 900) {
            return Row(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                Expanded(
                  flex: 7,
                  child: SingleChildScrollView(
                    padding: const EdgeInsets.only(bottom: 24),
                    child: videoArea,
                  ),
                ),
                VerticalDivider(width: 1, color: scheme.outlineVariant),
                Expanded(
                  flex: 5,
                  child: _buildTranscriptPane(
                    detail: detail,
                    controller: controller,
                    scheme: scheme,
                  ),
                ),
              ],
            );
          }

          return Column(
            children: [
              videoArea,
              Expanded(
                child: _buildTranscriptPane(
                  detail: detail,
                  controller: controller,
                  scheme: scheme,
                ),
              ),
            ],
          );
        },
      ),
    );
  }
}

class _VideoCommentsSheet extends ConsumerStatefulWidget {
  const _VideoCommentsSheet({
    required this.contentId,
    required this.initialCommentCount,
  });

  final String contentId;
  final int initialCommentCount;

  @override
  ConsumerState<_VideoCommentsSheet> createState() =>
      _VideoCommentsSheetState();
}

class _VideoCommentsSheetState extends ConsumerState<_VideoCommentsSheet> {
  final _controller = TextEditingController();
  final List<ContentCommentItem> _comments = <ContentCommentItem>[];
  bool _loading = true;
  bool _submitting = false;

  @override
  void initState() {
    super.initState();
    unawaited(_load());
  }

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  Future<void> _load() async {
    try {
      final comments = await ref
          .read(contentRepositoryProvider)
          .fetchComments(widget.contentId);
      if (!mounted) return;
      setState(() {
        _comments
          ..clear()
          ..addAll(comments);
        _loading = false;
      });
    } catch (error) {
      if (!mounted) return;
      setState(() => _loading = false);
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text(userFriendlyMessageFromObject(error))),
      );
    }
  }

  Future<void> _submit() async {
    final body = _controller.text.trim();
    if (body.isEmpty || _submitting) return;
    setState(() => _submitting = true);
    try {
      final result = await ref
          .read(contentRepositoryProvider)
          .addComment(contentId: widget.contentId, body: body);
      if (!mounted) return;
      _controller.clear();
      setState(() => _comments.add(result.comment));
    } catch (error) {
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text(userFriendlyMessageFromObject(error))),
      );
    } finally {
      if (mounted) setState(() => _submitting = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final keyboardInset = MediaQuery.viewInsetsOf(context).bottom;
    final count = _loading ? widget.initialCommentCount : _comments.length;
    return Scaffold(
      resizeToAvoidBottomInset: false,
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
                  if (count > 0) ...[
                    const SizedBox(width: 8),
                    Text(
                      compactEngagementCount(count),
                      style: Theme.of(context).textTheme.titleMedium?.copyWith(
                        color: scheme.onSurfaceVariant,
                        fontWeight: FontWeight.w700,
                      ),
                    ),
                  ],
                  const Spacer(),
                  IconButton(
                    onPressed: _loading ? null : () => unawaited(_load()),
                    icon: const Icon(Icons.refresh_rounded),
                  ),
                  IconButton(
                    onPressed: () => Navigator.of(context).pop(count),
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
                  : ListView.separated(
                      padding: const EdgeInsets.fromLTRB(16, 4, 16, 12),
                      itemCount: _comments.length,
                      separatorBuilder: (context, index) =>
                          const SizedBox(height: 10),
                      itemBuilder: (context, index) {
                        final comment = _comments[index];
                        return Material(
                          color: scheme.surfaceContainerLow,
                          borderRadius: BorderRadius.circular(16),
                          child: Padding(
                            padding: const EdgeInsets.all(14),
                            child: Column(
                              crossAxisAlignment: CrossAxisAlignment.start,
                              children: [
                                Text(
                                  comment.authorName,
                                  style: Theme.of(context).textTheme.labelLarge
                                      ?.copyWith(fontWeight: FontWeight.w800),
                                ),
                                const SizedBox(height: 6),
                                Text(comment.body),
                              ],
                            ),
                          ),
                        );
                      },
                    ),
            ),
            AnimatedPadding(
              duration: const Duration(milliseconds: 180),
              curve: Curves.easeOutCubic,
              padding: EdgeInsets.only(bottom: keyboardInset),
              child: DecoratedBox(
                decoration: BoxDecoration(
                  color: scheme.surface,
                  border: Border(top: BorderSide(color: scheme.outlineVariant)),
                ),
                child: SafeArea(
                  top: false,
                  minimum: const EdgeInsets.fromLTRB(16, 8, 16, 12),
                  child: Row(
                    children: [
                      Expanded(
                        child: TextField(
                          controller: _controller,
                          minLines: 1,
                          maxLines: 4,
                          textCapitalization: TextCapitalization.sentences,
                          decoration: const InputDecoration(
                            hintText: 'Add a comment',
                            border: OutlineInputBorder(),
                          ),
                        ),
                      ),
                      const SizedBox(width: 10),
                      FilledButton(
                        onPressed: _submitting ? null : _submit,
                        child: Text(_submitting ? '...' : 'Post'),
                      ),
                    ],
                  ),
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }
}

class ContentTranscriptEditorScreen extends ConsumerStatefulWidget {
  const ContentTranscriptEditorScreen({
    super.key,
    required this.videoId,
    required this.title,
    required this.track,
    this.contentKind = 'video',
  });

  final String videoId;
  final String title;
  final ContentTranscriptTrack track;
  final String contentKind;

  @override
  ConsumerState<ContentTranscriptEditorScreen> createState() =>
      _TranscriptEditorScreenState();
}

class _TranscriptEditorScreenState
    extends ConsumerState<ContentTranscriptEditorScreen> {
  final List<TextEditingController> _controllers = <TextEditingController>[];
  bool _saving = false;

  @override
  void initState() {
    super.initState();
    for (final segment in widget.track.segments) {
      _controllers.add(TextEditingController(text: segment.text));
    }
  }

  @override
  void dispose() {
    for (final controller in _controllers) {
      controller.dispose();
    }
    super.dispose();
  }

  String _formatMs(int ms) {
    final totalSeconds = ms ~/ 1000;
    final minutes = totalSeconds ~/ 60;
    final seconds = totalSeconds % 60;
    return '${minutes.toString().padLeft(2, '0')}:${seconds.toString().padLeft(2, '0')}';
  }

  Future<void> _save() async {
    if (_saving) return;
    final editedSegments = <ContentTranscriptSegment>[];
    for (var i = 0; i < widget.track.segments.length; i++) {
      final original = widget.track.segments[i];
      final text = _controllers[i].text.trim();
      if (text.isEmpty) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text('Subtitle line ${i + 1} cannot be empty.')),
        );
        return;
      }
      editedSegments.add(
        ContentTranscriptSegment(
          index: original.index,
          startMs: original.startMs,
          endMs: original.endMs,
          text: text,
        ),
      );
    }
    setState(() => _saving = true);
    try {
      final repo = ref.read(contentRepositoryProvider);
      final expectedUpdatedAt = widget.track.updatedAt
          ?.toUtc()
          .toIso8601String();
      final updated = widget.contentKind == 'podcast'
          ? await repo.updatePodcastTranscript(
              contentId: widget.videoId,
              languageCode: widget.track.languageCode,
              segments: editedSegments,
              expectedUpdatedAt: expectedUpdatedAt,
            )
          : await repo.updateVideoTranscript(
              contentId: widget.videoId,
              languageCode: widget.track.languageCode,
              segments: editedSegments,
              expectedUpdatedAt: expectedUpdatedAt,
            );
      if (!mounted) return;
      Navigator.of(context).pop(updated);
    } catch (error) {
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text(userFriendlyMessageFromObject(error))),
      );
    } finally {
      if (mounted) setState(() => _saving = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return Scaffold(
      appBar: AppBar(
        title: Text(
          widget.title.trim().isEmpty ? 'Edit subtitles' : 'Edit subtitles',
        ),
        actions: [
          TextButton(
            onPressed: _saving ? null : _save,
            child: Text(_saving ? 'Saving…' : 'Save'),
          ),
        ],
      ),
      body: ListView(
        padding: const EdgeInsets.fromLTRB(16, 16, 16, 24),
        children: [
          DecoratedBox(
            decoration: BoxDecoration(
              color: scheme.surfaceContainerHigh,
              borderRadius: BorderRadius.circular(20),
            ),
            child: Padding(
              padding: const EdgeInsets.all(14),
              child: Text(
                'Edit the subtitle lines below. Timeline positions stay locked so playback remains accurate.',
                style: Theme.of(context).textTheme.bodyMedium?.copyWith(
                  color: scheme.onSurfaceVariant,
                  height: 1.4,
                  fontWeight: FontWeight.w600,
                ),
              ),
            ),
          ),
          const SizedBox(height: 16),
          for (var i = 0; i < widget.track.segments.length; i++) ...[
            DecoratedBox(
              decoration: BoxDecoration(
                color: scheme.surfaceContainerLow,
                borderRadius: BorderRadius.circular(20),
                border: Border.all(color: scheme.outlineVariant),
              ),
              child: Padding(
                padding: const EdgeInsets.fromLTRB(14, 12, 14, 14),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      '${_formatMs(widget.track.segments[i].startMs)} - ${_formatMs(widget.track.segments[i].endMs)}',
                      style: Theme.of(context).textTheme.labelLarge?.copyWith(
                        color: scheme.primary,
                        fontWeight: FontWeight.w800,
                      ),
                    ),
                    const SizedBox(height: 10),
                    TextField(
                      controller: _controllers[i],
                      minLines: 2,
                      maxLines: 5,
                      textCapitalization: TextCapitalization.sentences,
                      decoration: const InputDecoration(
                        border: OutlineInputBorder(),
                        labelText: 'Subtitle text',
                      ),
                    ),
                  ],
                ),
              ),
            ),
            const SizedBox(height: 12),
          ],
        ],
      ),
    );
  }
}
