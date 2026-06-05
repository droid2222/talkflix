import 'dart:async';
import 'dart:io';
import 'dart:math' as math;
import 'dart:typed_data';
import 'dart:ui' as ui;

import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';
import 'package:image_picker/image_picker.dart';
import 'package:video_player/video_player.dart';

import '../../../app/localization/talkflix_localizations.dart';
import '../../../app/theme/app_theme.dart';
import '../../../core/auth/app_user.dart';
import '../../../core/auth/session_controller.dart';
import '../../../core/formatters/compact_count_formatter.dart';
import '../../../core/media/audio_message_player.dart';
import '../../../core/media/media_utils.dart';
import '../../../core/network/api_client.dart';
import '../../../core/widgets/app_avatar.dart';
import '../../../core/widgets/talkflix_pro_badge.dart';
import '../../auth/data/signup_options.dart';
import '../../content/data/content_repository.dart';
import '../../content/presentation/content_screen.dart'
    show
        TalkizPodcastDetailScreen,
        TalkizPostDetailScreen,
        openTalkizVideoFullscreen;
import '../../content/presentation/content_video_screen.dart'
    show ContentVideoScreen;
import '../../content/presentation/content_ui_utils.dart'
    show userFriendlyMessageFromObject;
import '../application/profile_cover_controller.dart';
import '../data/profile_repository.dart';

const int _profilePhotoLimit = 4;
const int _profileVideoLimit = 1;
const Duration _profileVideoDurationLimit = Duration(seconds: 60);

final Map<String, String> _countryNamesByCode =
    Map<String, String>.unmodifiable(
      <String, String>{
        for (final option in countryOptions)
          (option['code'] ?? '').trim().toUpperCase(): option['label'] ?? '',
      }..removeWhere((key, value) => key.isEmpty || value.trim().isEmpty),
    );

String _normalizeCountryCode(String value) {
  final normalized = value.trim().toUpperCase();
  if (normalized.length != 2) return '';
  final first = normalized.codeUnitAt(0);
  final second = normalized.codeUnitAt(1);
  if (first < 0x41 || first > 0x5A || second < 0x41 || second > 0x5A) {
    return '';
  }
  return normalized;
}

String _flagEmojiForCountryCode(String value) {
  final normalized = _normalizeCountryCode(value);
  if (normalized.isEmpty) return '';
  return String.fromCharCode(normalized.codeUnitAt(0) + 127397) +
      String.fromCharCode(normalized.codeUnitAt(1) + 127397);
}

String _countryNameForProfile({
  required String countryCode,
  required String fallback,
}) {
  final normalized = _normalizeCountryCode(countryCode);
  if (normalized.isNotEmpty) {
    return _countryNamesByCode[normalized] ?? fallback.trim();
  }
  return fallback.trim();
}

IconData _genderIconForProfile(String value) {
  final normalized = value.trim().toLowerCase();
  switch (normalized) {
    case 'male':
    case 'man':
      return Icons.male_rounded;
    case 'female':
    case 'woman':
      return Icons.female_rounded;
    default:
      return Icons.person_outline_rounded;
  }
}

final profileBaseProvider = FutureProvider.autoDispose.family<AppUser, String?>(
  (ref, userId) async {
    final sessionUser = ref.watch(
      sessionControllerProvider.select((s) => s.user),
    );
    if (sessionUser == null || sessionUser.id.isEmpty) {
      throw Exception('No active session');
    }
    if (userId == null || userId.isEmpty) {
      return sessionUser;
    }

    final data = await ref.read(apiClientProvider).getJson('/users/$userId');
    return AppUser.fromJson(data['user'] as Map<String, dynamic>? ?? {});
  },
);

final profileProvider = FutureProvider.autoDispose.family<AppUser, String?>((
  ref,
  userId,
) async {
  final baseUser = await ref.watch(profileBaseProvider(userId).future);
  final override = ref.watch(profileCoverOverrideProvider(baseUser.id));
  if (override == null) return baseUser;
  return baseUser.copyWith(
    coverPhotoUrls: override.coverPhotoUrls,
    coverPhotoThumbUrls: override.coverPhotoThumbUrls,
    coverPhotosLocked: override.coverPhotosLocked,
  );
});

final creatorProfileContentProvider = FutureProvider.autoDispose
    .family<List<_CreatorProfileContentItem>, String>((ref, userId) async {
      final repository = ref.read(contentRepositoryProvider);
      final postsFuture = repository.fetchPostsByUserId(userId);
      final podcastsFuture = repository.fetchPodcastsByUserId(userId);
      final posts = await postsFuture;
      final podcasts = await podcastsFuture;
      final items = <_CreatorProfileContentItem>[
        ...posts.map(_CreatorProfileContentItem.post),
        ...podcasts.map(_CreatorProfileContentItem.podcast),
      ];
      items.sort((a, b) {
        final publishedAtCompare = (b.publishedAt ?? DateTime(1970)).compareTo(
          a.publishedAt ?? DateTime(1970),
        );
        if (publishedAtCompare != 0) return publishedAtCompare;
        return b.id.compareTo(a.id);
      });
      return items;
    });

class ProfileScreen extends ConsumerStatefulWidget {
  const ProfileScreen({super.key, this.userId, this.previewMode = false});

  final String? userId;
  final bool previewMode;

  @override
  ConsumerState<ProfileScreen> createState() => _ProfileScreenState();
}

class _ProfileScreenState extends ConsumerState<ProfileScreen> {
  final _coverPicker = ImagePicker();
  final _profilePhotoPicker = ImagePicker();
  bool _updatingFollow = false;
  bool _updatingProfilePhoto = false;
  bool? _followOverride;
  int? _followersCountOverride;

  @override
  void didUpdateWidget(covariant ProfileScreen oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.userId != widget.userId ||
        oldWidget.previewMode != widget.previewMode) {
      _followOverride = null;
      _followersCountOverride = null;
      _updatingFollow = false;
    }
  }

  void _invalidateProfileCaches({String? userId}) {
    ref.invalidate(profileBaseProvider(widget.userId));
    ref.invalidate(profileProvider(widget.userId));
    ref.invalidate(profileBaseProvider(null));
    ref.invalidate(profileProvider(null));
    final resolvedUserId = userId ?? _profileUserId();
    if (resolvedUserId != null && resolvedUserId.isNotEmpty) {
      ref.invalidate(profileBaseProvider(resolvedUserId));
      ref.invalidate(profileProvider(resolvedUserId));
    }
  }

  Future<void> _toggleFollow(AppUser user) async {
    if (_updatingFollow) return;
    setState(() => _updatingFollow = true);
    try {
      final data = await ref
          .read(apiClientProvider)
          .postJson('/users/${user.id}/follow');
      if (!mounted) return;
      setState(() {
        _followOverride = data['following'] == true;
        _followersCountOverride =
            (data['followersCount'] as num?)?.toInt() ??
            _followersCountOverride;
      });
      _invalidateProfileCaches(userId: user.id);
    } finally {
      if (mounted) {
        setState(() => _updatingFollow = false);
      }
    }
  }

  Future<void> _refresh() async {
    final profileUserId = _profileUserId();
    if (profileUserId != null && profileUserId.isNotEmpty) {
      ref.read(profileCoverControllerProvider).clear(userId: profileUserId);
    }
    await _refreshProfileData();
  }

  Future<void> _openUpgrade() async {
    await context.push('/app/upgrade');
    if (!mounted) return;
    await _refreshProfileData();
  }

  Future<void> _refreshProfileData() async {
    _invalidateProfileCaches();
    final profileUserId = _profileUserId();
    if (profileUserId != null && profileUserId.isNotEmpty) {
      ref.invalidate(creatorProfileContentProvider(profileUserId));
    }
    if (widget.userId == null || widget.userId!.isEmpty) {
      await ref.read(sessionControllerProvider.notifier).refreshProfile();
    }
    if (!mounted) return;
    await ref.read(profileProvider(widget.userId).future);
  }

  Future<void> _openEditProfile() async {
    final updated = await context.push('/app/profile/edit');
    if (!mounted || updated != true) return;
    await _refreshProfileData();
  }

  void _showMessage(String message) {
    if (!mounted) return;
    ScaffoldMessenger.of(
      context,
    ).showSnackBar(SnackBar(content: Text(message)));
  }

  Future<void> _changeProfilePhotoFromGallery(AppUser user) async {
    if (_updatingProfilePhoto) return;
    final picked = await _profilePhotoPicker.pickImage(
      source: ImageSource.gallery,
      maxWidth: 1800,
      imageQuality: 92,
    );
    if (!mounted || picked == null) return;

    try {
      final bytes = await picked.readAsBytes();
      if (!mounted) return;
      final croppedBytes = await showDialog<Uint8List>(
        context: context,
        barrierDismissible: false,
        builder: (context) => _ProfilePhotoCropDialog(imageBytes: bytes),
      );
      if (!mounted || croppedBytes == null) return;

      setState(() => _updatingProfilePhoto = true);
      final croppedPath = await _writeCroppedProfilePhoto(croppedBytes);
      try {
        await ref
            .read(profileRepositoryProvider)
            .uploadProfilePhoto(imagePath: croppedPath);
      } finally {
        unawaited(_deleteTempFile(croppedPath));
      }
      await ref.read(sessionControllerProvider.notifier).refreshProfile();
      _invalidateProfileCaches(userId: user.id);
      if (!mounted) return;
      _showMessage('Profile photo updated.');
    } catch (e) {
      if (!mounted) return;
      _showMessage(userFriendlyMessageFromObject(e));
    } finally {
      if (mounted) {
        setState(() => _updatingProfilePhoto = false);
      }
    }
  }

  Future<void> _showProfilePhotoPreview(AppUser user) async {
    final photoUrl = user.profilePhotoUrl.trim();
    if (photoUrl.isEmpty) return;
    await showGeneralDialog<void>(
      context: context,
      barrierDismissible: true,
      barrierLabel: 'Close profile photo',
      barrierColor: Colors.black.withValues(alpha: 0.94),
      pageBuilder: (context, animation, secondaryAnimation) {
        return _FullscreenProfilePhotoView(
          imageUrl: photoUrl,
          heroTag: 'profile-photo-${user.id}',
        );
      },
      transitionBuilder: (context, animation, secondaryAnimation, child) {
        return FadeTransition(opacity: animation, child: child);
      },
    );
  }

  Future<String> _writeCroppedProfilePhoto(Uint8List bytes) async {
    final file = File(
      '${Directory.systemTemp.path}/talkflix_profile_photo_${DateTime.now().millisecondsSinceEpoch}.png',
    );
    await file.writeAsBytes(bytes, flush: true);
    return file.path;
  }

  Future<void> _deleteTempFile(String path) async {
    try {
      await File(path).delete();
    } catch (_) {}
  }

  String? _profileUserId() {
    if (widget.userId != null && widget.userId!.isNotEmpty) {
      return widget.userId;
    }
    return ref.read(sessionControllerProvider).user?.id;
  }

  String _relationshipStatusLabel(BuildContext context, String value) {
    final l10n = Localizations.of<TalkflixLocalizations>(
      context,
      TalkflixLocalizations,
    );
    return l10n?.relationshipStatusLabel(value) ?? value;
  }

  String _genderLabel(String value) {
    final normalized = value.trim().toLowerCase();
    switch (normalized) {
      case 'male':
        return 'Male';
      case 'female':
        return 'Female';
      case 'man':
        return 'Man';
      case 'woman':
        return 'Woman';
      case 'nonbinary':
      case 'non-binary':
        return 'Non-binary';
      default:
        return value.trim();
    }
  }

  Future<void> _pickAndUploadCoverPhoto({
    required String userId,
    required int slot,
    required bool replacing,
  }) async {
    if (ref.read(profileCoverBusyProvider(userId))) return;
    final file = await _coverPicker.pickImage(source: ImageSource.gallery);
    if (!mounted || file == null) return;

    try {
      await ref
          .read(profileCoverControllerProvider)
          .upload(userId: userId, imagePath: file.path, slot: slot);
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text(
            replacing ? 'Cover photo updated.' : 'Cover photo added.',
          ),
        ),
      );
    } catch (e) {
      if (!mounted) return;
      ScaffoldMessenger.of(
        context,
      ).showSnackBar(SnackBar(content: Text(userFriendlyMessageFromObject(e))));
    }
  }

  Future<void> _removeCoverPhoto({
    required String userId,
    required int slot,
  }) async {
    if (ref.read(profileCoverBusyProvider(userId))) return;
    try {
      await ref
          .read(profileCoverControllerProvider)
          .remove(userId: userId, slot: slot);
      if (!mounted) return;
      ScaffoldMessenger.of(
        context,
      ).showSnackBar(const SnackBar(content: Text('Cover photo removed.')));
    } catch (e) {
      if (!mounted) return;
      ScaffoldMessenger.of(
        context,
      ).showSnackBar(SnackBar(content: Text(userFriendlyMessageFromObject(e))));
    }
  }

  Future<void> _showCoverPhotoManager(AppUser user) async {
    if (!user.isProLike) {
      await _openUpgrade();
      return;
    }
    final action = await showModalBottomSheet<_CoverAction>(
      context: context,
      backgroundColor: Theme.of(context).colorScheme.surface,
      shape: const RoundedRectangleBorder(
        borderRadius: BorderRadius.vertical(top: Radius.circular(28)),
      ),
      builder: (sheetContext) {
        final covers = user.coverPhotoUrls;
        return SafeArea(
          top: false,
          child: Padding(
            padding: const EdgeInsets.fromLTRB(12, 12, 12, 18),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                Container(
                  width: 42,
                  height: 4,
                  margin: const EdgeInsets.only(bottom: 12),
                  decoration: BoxDecoration(
                    color: Theme.of(sheetContext).colorScheme.outlineVariant,
                    borderRadius: BorderRadius.circular(999),
                  ),
                ),
                ListTile(
                  leading: const Icon(Icons.add_photo_alternate_outlined),
                  title: Text(
                    covers.isEmpty
                        ? 'Add first cover photo'
                        : covers.length == 1
                        ? 'Add second cover photo'
                        : 'Replace cover photo 1',
                  ),
                  onTap: () {
                    final slot = covers.isEmpty
                        ? 0
                        : (covers.length == 1 ? 1 : 0);
                    Navigator.of(sheetContext).pop(
                      _CoverPickAction(
                        slot: slot,
                        replacing: slot < covers.length,
                      ),
                    );
                  },
                ),
                if (covers.isNotEmpty)
                  ListTile(
                    leading: const Icon(Icons.edit_outlined),
                    title: Text(
                      covers.length > 1
                          ? 'Replace cover photo 2'
                          : 'Replace cover photo 1',
                    ),
                    onTap: () {
                      final slot = covers.length > 1 ? 1 : 0;
                      Navigator.of(
                        sheetContext,
                      ).pop(_CoverPickAction(slot: slot, replacing: true));
                    },
                  ),
                if (covers.isNotEmpty)
                  ListTile(
                    leading: Icon(
                      Icons.delete_outline_rounded,
                      color: Theme.of(sheetContext).colorScheme.error,
                    ),
                    title: Text(
                      covers.length > 1
                          ? 'Remove cover photo 2'
                          : 'Remove cover photo 1',
                      style: TextStyle(
                        color: Theme.of(sheetContext).colorScheme.error,
                        fontWeight: FontWeight.w600,
                      ),
                    ),
                    onTap: () => Navigator.of(
                      sheetContext,
                    ).pop(_CoverRemoveAction(covers.length > 1 ? 1 : 0)),
                  ),
                if (covers.length > 1)
                  ListTile(
                    leading: Icon(
                      Icons.delete_sweep_outlined,
                      color: Theme.of(sheetContext).colorScheme.error,
                    ),
                    title: Text(
                      'Remove cover photo 1',
                      style: TextStyle(
                        color: Theme.of(sheetContext).colorScheme.error,
                        fontWeight: FontWeight.w600,
                      ),
                    ),
                    onTap: () =>
                        Navigator.of(sheetContext).pop(_CoverRemoveAction(0)),
                  ),
              ],
            ),
          ),
        );
      },
    );
    if (!mounted || action == null) return;
    await WidgetsBinding.instance.endOfFrame;
    if (!mounted) return;
    final userId = _profileUserId();
    if (userId == null || userId.isEmpty) return;
    if (action is _CoverPickAction) {
      await _pickAndUploadCoverPhoto(
        userId: userId,
        slot: action.slot,
        replacing: action.replacing,
      );
    } else if (action is _CoverRemoveAction) {
      await _removeCoverPhoto(userId: userId, slot: action.slot);
    }
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;
    final me = ref.watch(sessionControllerProvider).user;
    final profile = ref.watch(profileProvider(widget.userId));

    return Scaffold(
      backgroundColor: scheme.surface,
      body: profile.when(
        data: (user) {
          final previewingOwnProfile = widget.previewMode && me?.id == user.id;
          final isOwnProfile =
              !widget.previewMode &&
              (me?.id == user.id ||
                  widget.userId == null ||
                  widget.userId!.isEmpty);
          final canShowAge = user.age != null && (isOwnProfile || user.showAge);
          final showFollowStats = isOwnProfile || user.showFollowStats;
          final canOpenFollowLists = isOwnProfile;
          final viewingProfileRoute =
              widget.userId != null && widget.userId!.isNotEmpty;
          final isFollowing = _followOverride ?? user.isFollowing;
          final followersCount = _followersCountOverride ?? user.followersCount;
          final coverBusy = ref.watch(profileCoverBusyProvider(user.id));
          final location = [
            if (user.city.isNotEmpty) user.city,
            if (user.country.isNotEmpty) user.country,
          ].join(', ');
          final detailRows = <({IconData icon, String text})>[
            if (location.isNotEmpty)
              (icon: Icons.location_on_outlined, text: location),
            if (user.firstLanguage.isNotEmpty || user.learnLanguage.isNotEmpty)
              (
                icon: Icons.translate_rounded,
                text:
                    'Speaks ${user.firstLanguage.isEmpty ? 'Any' : user.firstLanguage} · Learns ${user.learnLanguage.isEmpty ? 'Any' : user.learnLanguage}',
              ),
            if (user.meetLanguages.isNotEmpty)
              (
                icon: Icons.forum_outlined,
                text: 'Open to ${user.meetLanguages.join(', ')}',
              ),
          ];
          final bioText = user.bioText.trim();
          final hasVoiceBio =
              user.bioAudioUrl.trim().isNotEmpty && user.bioAudioDuration > 0;
          final genderLabel = _genderLabel(user.gender);
          final genderIcon = _genderIconForProfile(user.gender);
          final flagCode = _normalizeCountryCode(user.nationalityCode);
          final flagName = _countryNameForProfile(
            countryCode: user.nationalityCode,
            fallback: user.nationalityName,
          );
          final creatorContent = user.canPublishToTalkiz
              ? ref.watch(creatorProfileContentProvider(user.id))
              : null;
          final creatorContentCount =
              creatorContent?.maybeWhen(
                data: (items) => items.length,
                orElse: () => user.postsCount,
              ) ??
              user.postsCount;
          final showPostsCount = user.canPublishToTalkiz;
          final showStatsRow = showPostsCount || showFollowStats;

          return RefreshIndicator(
            onRefresh: _refresh,
            child: CustomScrollView(
              physics: const AlwaysScrollableScrollPhysics(),
              slivers: [
                SliverToBoxAdapter(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Stack(
                        clipBehavior: Clip.none,
                        children: [
                          _ProfileCoverSection(
                            user: user,
                            isOwnProfile: isOwnProfile,
                            busy: coverBusy,
                            profilePhotoBusy: _updatingProfilePhoto,
                            onManageCovers: isOwnProfile
                                ? () {
                                    unawaited(_showCoverPhotoManager(user));
                                  }
                                : null,
                            onViewProfilePhoto:
                                user.profilePhotoUrl.trim().isEmpty
                                ? null
                                : () {
                                    unawaited(_showProfilePhotoPreview(user));
                                  },
                            onChangeProfilePhoto: isOwnProfile
                                ? () {
                                    unawaited(
                                      _changeProfilePhotoFromGallery(user),
                                    );
                                  }
                                : null,
                          ),
                          Positioned(
                            top: 0,
                            left: 0,
                            right: 0,
                            child: SafeArea(
                              bottom: false,
                              child: Padding(
                                padding: const EdgeInsets.fromLTRB(
                                  12,
                                  10,
                                  12,
                                  0,
                                ),
                                child: Row(
                                  children: [
                                    SizedBox(
                                      width: 96,
                                      child: Align(
                                        alignment: Alignment.centerLeft,
                                        child: IconButton(
                                          onPressed: () {
                                            if (Navigator.of(
                                              context,
                                            ).canPop()) {
                                              Navigator.of(context).pop();
                                            } else if (viewingProfileRoute) {
                                              context.go('/app/profile');
                                            } else {
                                              context.go('/app/content');
                                            }
                                          },
                                          icon: const Icon(
                                            Icons.arrow_back_ios_new_rounded,
                                            color: Colors.white,
                                          ),
                                        ),
                                      ),
                                    ),
                                    Expanded(
                                      child: Text(
                                        user.displayName,
                                        textAlign: TextAlign.center,
                                        maxLines: 1,
                                        overflow: TextOverflow.ellipsis,
                                        style: theme.textTheme.titleLarge
                                            ?.copyWith(
                                              color: Colors.white,
                                              fontWeight: FontWeight.w800,
                                              shadows: const [
                                                Shadow(
                                                  color: Color(0x66000000),
                                                  blurRadius: 12,
                                                ),
                                              ],
                                            ),
                                      ),
                                    ),
                                    SizedBox(
                                      width: 96,
                                      child: Row(
                                        mainAxisAlignment:
                                            MainAxisAlignment.end,
                                        children: [
                                          IconButton(
                                            onPressed: () => context.push(
                                              '/app/profile/qr/${user.id}',
                                            ),
                                            icon: const Icon(
                                              Icons.share_outlined,
                                              color: Colors.white,
                                            ),
                                          ),
                                          if (isOwnProfile)
                                            IconButton(
                                              onPressed: () => context.push(
                                                '/app/profile/settings',
                                              ),
                                              icon: const Icon(
                                                Icons.settings_outlined,
                                                color: Colors.white,
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
                        ],
                      ),
                      Padding(
                        padding: const EdgeInsets.fromLTRB(18, 0, 18, 0),
                        child: Column(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            if (showStatsRow) ...[
                              Padding(
                                padding: const EdgeInsets.only(left: 98),
                                child: Row(
                                  mainAxisAlignment: showFollowStats
                                      ? MainAxisAlignment.spaceBetween
                                      : MainAxisAlignment.start,
                                  children: [
                                    if (showPostsCount)
                                      _ProfileStat(
                                        label: 'posts',
                                        value: compactCount(
                                          creatorContentCount,
                                        ),
                                      ),
                                    if (showFollowStats) ...[
                                      _ProfileStat(
                                        label: 'followers',
                                        value: compactCount(followersCount),
                                        icon: Icons.people_alt_outlined,
                                        onTap: canOpenFollowLists
                                            ? () => context.push(
                                                '/app/profile/${user.id}/list/followers?name=${Uri.encodeComponent(user.displayName)}',
                                              )
                                            : null,
                                      ),
                                      _ProfileStat(
                                        label: 'following',
                                        value: compactCount(
                                          user.followingCount,
                                        ),
                                        icon: Icons.person_add_alt_1_outlined,
                                        onTap: canOpenFollowLists
                                            ? () => context.push(
                                                '/app/profile/${user.id}/list/following?name=${Uri.encodeComponent(user.displayName)}',
                                              )
                                            : null,
                                      ),
                                    ],
                                  ],
                                ),
                              ),
                              const SizedBox(height: 16),
                            ],
                            Text(
                              user.displayName,
                              style: theme.textTheme.titleMedium?.copyWith(
                                fontWeight: FontWeight.w800,
                              ),
                            ),
                            if (isOwnProfile && !user.isProLike) ...[
                              const SizedBox(height: 6),
                              Text(
                                'Cover photos are only visible to other users while Talkflix Pro is active.',
                                style: theme.textTheme.bodySmall?.copyWith(
                                  color: scheme.onSurfaceVariant,
                                  height: 1.3,
                                ),
                              ),
                            ],
                            const SizedBox(height: 6),
                            if (bioText.isNotEmpty) ...[
                              Text(
                                bioText,
                                style: theme.textTheme.bodyMedium?.copyWith(
                                  height: 1.35,
                                ),
                              ),
                              const SizedBox(height: 8),
                            ],
                            if (hasVoiceBio) ...[
                              AudioMessagePlayer(
                                source: user.bioAudioUrl,
                                durationSeconds: user.bioAudioDuration,
                              ),
                              const SizedBox(height: 8),
                            ],
                            if (detailRows.isEmpty &&
                                bioText.isEmpty &&
                                !hasVoiceBio)
                              Text(
                                'Talkflix profile',
                                style: theme.textTheme.bodyMedium?.copyWith(
                                  color: scheme.onSurfaceVariant,
                                ),
                              )
                            else
                              ...detailRows.map(
                                (detail) => Padding(
                                  padding: const EdgeInsets.only(bottom: 3),
                                  child: Row(
                                    crossAxisAlignment:
                                        CrossAxisAlignment.start,
                                    children: [
                                      Padding(
                                        padding: const EdgeInsets.only(
                                          top: 1,
                                          right: 8,
                                        ),
                                        child: Icon(
                                          detail.icon,
                                          size: 18,
                                          color: scheme.onSurfaceVariant,
                                        ),
                                      ),
                                      Expanded(
                                        child: Text(
                                          detail.text,
                                          style: theme.textTheme.bodyMedium
                                              ?.copyWith(height: 1.25),
                                        ),
                                      ),
                                    ],
                                  ),
                                ),
                              ),
                            const SizedBox(height: 14),
                            Row(
                              children: [
                                Expanded(
                                  child: _ProfileActionButton(
                                    label: isOwnProfile
                                        ? 'Talkflix Pro'
                                        : _updatingFollow
                                        ? 'Updating...'
                                        : isFollowing
                                        ? 'Following'
                                        : 'Follow',
                                    filled: isOwnProfile
                                        ? user.isProLike
                                        : !isFollowing,
                                    trailing: isOwnProfile
                                        ? _ProfileToggle(
                                            enabled: user.isProLike,
                                          )
                                        : null,
                                    onTap: isOwnProfile
                                        ? () {
                                            unawaited(_openUpgrade());
                                          }
                                        : previewingOwnProfile
                                        ? null
                                        : _updatingFollow
                                        ? null
                                        : () => _toggleFollow(user),
                                  ),
                                ),
                                const SizedBox(width: 8),
                                Expanded(
                                  child: _ProfileActionButton(
                                    label: isOwnProfile
                                        ? 'Preview profile'
                                        : 'Chat',
                                    leading: isOwnProfile
                                        ? null
                                        : const Icon(
                                            Icons.chat_bubble_rounded,
                                            size: 16,
                                          ),
                                    onTap: () => isOwnProfile
                                        ? context.push(
                                            '/app/profile/${user.id}?preview=1',
                                          )
                                        : previewingOwnProfile
                                        ? null
                                        : context.push('/app/talk/${user.id}'),
                                  ),
                                ),
                              ],
                            ),
                            if (isOwnProfile) ...[
                              const SizedBox(height: 8),
                              SizedBox(
                                width: double.infinity,
                                child: OutlinedButton.icon(
                                  onPressed: _openEditProfile,
                                  icon: const Icon(Icons.edit_outlined),
                                  label: const Text('Edit profile'),
                                ),
                              ),
                            ],
                            const SizedBox(height: 16),
                            Wrap(
                              spacing: 8,
                              runSpacing: 8,
                              children: [
                                if (user.firstLanguage.isNotEmpty)
                                  _ProfileMetaPill(
                                    label: user.firstLanguage,
                                    icon: Icons.language_rounded,
                                  ),
                                if (user.learnLanguage.isNotEmpty)
                                  _ProfileMetaPill(
                                    label: 'Learning ${user.learnLanguage}',
                                    icon: Icons.record_voice_over_outlined,
                                  ),
                                if (user.isProLike) const _ProfileProBadge(),
                                if (user.relationshipStatusVisible &&
                                    user.relationshipStatus.isNotEmpty)
                                  _ProfileMetaPill(
                                    label: _relationshipStatusLabel(
                                      context,
                                      user.relationshipStatus,
                                    ),
                                    icon: Icons.favorite_border_rounded,
                                  ),
                                if (canShowAge)
                                  _ProfileMetaPill(
                                    label: 'Age ${user.age}',
                                    icon: Icons.cake_outlined,
                                  ),
                                if (genderLabel.isNotEmpty)
                                  _ProfileMetaPill(
                                    label: genderLabel,
                                    icon: genderIcon,
                                  ),
                                if (user.showFlag && flagCode.isNotEmpty)
                                  _ProfileFlagPill(
                                    countryCode: flagCode,
                                    countryName: flagName,
                                  ),
                              ],
                            ),
                            const SizedBox(height: 20),
                            Divider(color: scheme.outlineVariant),
                            const SizedBox(height: 10),
                            Row(
                              mainAxisAlignment: MainAxisAlignment.center,
                              children: [
                                Icon(
                                  Icons.grid_on_rounded,
                                  color: scheme.onSurface,
                                  size: 22,
                                ),
                              ],
                            ),
                            const SizedBox(height: 18),
                          ],
                        ),
                      ),
                    ],
                  ),
                ),
                if (user.canPublishToTalkiz)
                  _ProfilePostGrid(userId: user.id, isOwnProfile: isOwnProfile)
                else
                  _ProfileMediaGrid(
                    userId: user.id,
                    isOwnProfile: isOwnProfile,
                  ),
              ],
            ),
          );
        },
        loading: () => const Center(child: CircularProgressIndicator()),
        error: (error, stackTrace) => Center(
          child: Padding(
            padding: const EdgeInsets.all(24),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                Text(error.toString(), textAlign: TextAlign.center),
                const SizedBox(height: 12),
                OutlinedButton(
                  onPressed: () {
                    ref.invalidate(profileBaseProvider(widget.userId));
                    ref.invalidate(profileProvider(widget.userId));
                  },
                  child: const Text('Retry'),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}

class _ProfilePhotoCropDialog extends StatefulWidget {
  const _ProfilePhotoCropDialog({required this.imageBytes});

  final Uint8List imageBytes;

  @override
  State<_ProfilePhotoCropDialog> createState() =>
      _ProfilePhotoCropDialogState();
}

class _ProfilePhotoCropDialogState extends State<_ProfilePhotoCropDialog> {
  final _cropKey = GlobalKey();
  bool _saving = false;

  Future<void> _usePhoto() async {
    if (_saving) return;
    setState(() => _saving = true);
    try {
      await WidgetsBinding.instance.endOfFrame;
      final boundary =
          _cropKey.currentContext?.findRenderObject() as RenderRepaintBoundary?;
      if (boundary == null) {
        if (mounted) Navigator.of(context).pop<Uint8List>();
        return;
      }
      final image = await boundary.toImage(pixelRatio: 3);
      final byteData = await image.toByteData(format: ui.ImageByteFormat.png);
      image.dispose();
      if (!mounted) return;
      Navigator.of(context).pop<Uint8List>(byteData?.buffer.asUint8List());
    } catch (_) {
      if (!mounted) return;
      setState(() => _saving = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final cropSize = math.min(MediaQuery.sizeOf(context).width - 56, 320.0);
    return Dialog(
      insetPadding: const EdgeInsets.symmetric(horizontal: 20, vertical: 24),
      child: Padding(
        padding: const EdgeInsets.fromLTRB(18, 18, 18, 14),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(
              'Fit profile photo',
              style: theme.textTheme.titleLarge?.copyWith(
                fontWeight: FontWeight.w800,
              ),
            ),
            const SizedBox(height: 6),
            Text(
              'Pinch to zoom and drag to center your photo.',
              style: theme.textTheme.bodyMedium?.copyWith(
                color: theme.colorScheme.onSurfaceVariant,
              ),
            ),
            const SizedBox(height: 18),
            Center(
              child: Stack(
                children: [
                  RepaintBoundary(
                    key: _cropKey,
                    child: SizedBox(
                      width: cropSize,
                      height: cropSize,
                      child: ClipRect(
                        child: InteractiveViewer(
                          boundaryMargin: EdgeInsets.all(cropSize),
                          minScale: 1,
                          maxScale: 4,
                          child: SizedBox(
                            width: cropSize,
                            height: cropSize,
                            child: Image.memory(
                              widget.imageBytes,
                              fit: BoxFit.cover,
                            ),
                          ),
                        ),
                      ),
                    ),
                  ),
                  Positioned.fill(
                    child: IgnorePointer(
                      child: DecoratedBox(
                        decoration: BoxDecoration(
                          border: Border.all(
                            color: Colors.white.withValues(alpha: 0.9),
                            width: 2,
                          ),
                          boxShadow: [
                            BoxShadow(
                              color: Colors.black.withValues(alpha: 0.12),
                              blurRadius: 18,
                            ),
                          ],
                        ),
                      ),
                    ),
                  ),
                ],
              ),
            ),
            const SizedBox(height: 16),
            Row(
              children: [
                TextButton(
                  onPressed: _saving ? null : () => Navigator.of(context).pop(),
                  child: const Text('Cancel'),
                ),
                const Spacer(),
                FilledButton.icon(
                  onPressed: _saving ? null : _usePhoto,
                  icon: _saving
                      ? const SizedBox(
                          width: 16,
                          height: 16,
                          child: CircularProgressIndicator(strokeWidth: 2),
                        )
                      : const Icon(Icons.check_rounded),
                  label: Text(_saving ? 'Preparing...' : 'Use photo'),
                ),
              ],
            ),
          ],
        ),
      ),
    );
  }
}

class _ProfileCoverSection extends StatelessWidget {
  const _ProfileCoverSection({
    required this.user,
    required this.isOwnProfile,
    required this.busy,
    required this.profilePhotoBusy,
    this.onManageCovers,
    this.onViewProfilePhoto,
    this.onChangeProfilePhoto,
  });

  final AppUser user;
  final bool isOwnProfile;
  final bool busy;
  final bool profilePhotoBusy;
  final VoidCallback? onManageCovers;
  final VoidCallback? onViewProfilePhoto;
  final VoidCallback? onChangeProfilePhoto;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final topInset = MediaQuery.paddingOf(context).top;
    final coverHeight = 212 + topInset + 12;
    const avatarSectionHeight = 58.0;
    final covers = user.coverPhotoUrls;
    final coverThumbs = user.coverPhotoThumbUrls;
    final hasCovers = covers.isNotEmpty;
    final showLockedPlaceholder = user.coverPhotosLocked && !isOwnProfile;
    final coverContent = showLockedPlaceholder
        ? const _LockedCoverPlaceholder()
        : !hasCovers
        ? _EmptyCoverPlaceholder(ownProfile: isOwnProfile)
        : covers.length == 1
        ? _SingleCoverHeader(
            imageUrl: covers.first,
            thumbUrl: coverThumbs.isNotEmpty ? coverThumbs.first : null,
            ownProfile: isOwnProfile,
          )
        : _MultiCoverHeader(
            key: ValueKey('multi-cover-${user.id}-${covers.join('|')}'),
            imageUrls: covers,
            thumbUrls: coverThumbs,
            ownProfile: isOwnProfile,
          );
    final avatarButton = Container(
      padding: const EdgeInsets.all(4),
      decoration: BoxDecoration(
        color: Theme.of(context).colorScheme.surface,
        shape: BoxShape.circle,
        boxShadow: [
          BoxShadow(
            color: Colors.black.withValues(alpha: 0.12),
            blurRadius: 18,
            offset: const Offset(0, 8),
          ),
        ],
      ),
      child: AppAvatar(
        label: user.displayName,
        imageUrl: user.profilePhotoUrl,
        radius: 44,
      ),
    );
    const avatarBlockSize = 102.0;

    return SizedBox(
      height: coverHeight + avatarSectionHeight,
      child: Stack(
        children: [
          Container(
            height: coverHeight,
            decoration: BoxDecoration(
              borderRadius: const BorderRadius.vertical(
                bottom: Radius.circular(28),
              ),
              color: scheme.surfaceContainerHighest,
            ),
            clipBehavior: Clip.antiAlias,
            child: Stack(
              fit: StackFit.expand,
              children: [
                coverContent,
                IgnorePointer(
                  child: DecoratedBox(
                    decoration: BoxDecoration(
                      gradient: LinearGradient(
                        begin: Alignment.topCenter,
                        end: Alignment.bottomCenter,
                        colors: [
                          Colors.black.withValues(alpha: 0.06),
                          Colors.black.withValues(alpha: 0.18),
                        ],
                      ),
                    ),
                  ),
                ),
                if (busy)
                  Positioned.fill(
                    child: AbsorbPointer(
                      child: DecoratedBox(
                        decoration: BoxDecoration(
                          color: Colors.black.withValues(alpha: 0.26),
                        ),
                        child: Center(
                          child: Container(
                            padding: const EdgeInsets.symmetric(
                              horizontal: 16,
                              vertical: 12,
                            ),
                            decoration: BoxDecoration(
                              color: Colors.black.withValues(alpha: 0.55),
                              borderRadius: BorderRadius.circular(18),
                              border: Border.all(
                                color: Colors.white.withValues(alpha: 0.12),
                              ),
                            ),
                            child: Row(
                              mainAxisSize: MainAxisSize.min,
                              children: [
                                const SizedBox(
                                  width: 18,
                                  height: 18,
                                  child: CircularProgressIndicator(
                                    strokeWidth: 2.2,
                                    valueColor: AlwaysStoppedAnimation<Color>(
                                      Colors.white,
                                    ),
                                  ),
                                ),
                                const SizedBox(width: 12),
                                Text(
                                  'Updating cover...',
                                  style: Theme.of(context).textTheme.bodyMedium
                                      ?.copyWith(
                                        color: Colors.white,
                                        fontWeight: FontWeight.w700,
                                      ),
                                ),
                              ],
                            ),
                          ),
                        ),
                      ),
                    ),
                  ),
                if (isOwnProfile)
                  Positioned(
                    top: topInset + 58,
                    right: 14,
                    child: FilledButton.tonalIcon(
                      onPressed: busy ? null : onManageCovers,
                      style: FilledButton.styleFrom(
                        backgroundColor: Colors.black.withValues(alpha: 0.42),
                        foregroundColor: Colors.white,
                        padding: const EdgeInsets.symmetric(
                          horizontal: 12,
                          vertical: 10,
                        ),
                      ),
                      icon: busy
                          ? const SizedBox(
                              width: 14,
                              height: 14,
                              child: CircularProgressIndicator(strokeWidth: 2),
                            )
                          : Icon(
                              hasCovers
                                  ? Icons.photo_library_outlined
                                  : Icons.add_a_photo_outlined,
                              size: 18,
                            ),
                      label: Text(hasCovers ? 'Manage' : 'Add cover'),
                    ),
                  ),
              ],
            ),
          ),
          Positioned(
            left: 18,
            bottom: 0,
            child: SizedBox(
              width: avatarBlockSize,
              height: avatarBlockSize,
              child: Stack(
                children: [
                  Positioned(
                    top: 0,
                    left: 0,
                    child: GestureDetector(
                      behavior: HitTestBehavior.opaque,
                      onTap: onViewProfilePhoto,
                      child: Hero(
                        tag: 'profile-photo-${user.id}',
                        child: avatarButton,
                      ),
                    ),
                  ),
                  if (isOwnProfile)
                    Positioned(
                      right: 0,
                      bottom: 0,
                      child: Material(
                        color: Theme.of(context).colorScheme.primary,
                        shape: const CircleBorder(),
                        child: SizedBox(
                          width: 44,
                          height: 44,
                          child: IconButton(
                            onPressed: profilePhotoBusy
                                ? null
                                : onChangeProfilePhoto,
                            tooltip: 'Change profile photo',
                            icon: profilePhotoBusy
                                ? const SizedBox(
                                    width: 18,
                                    height: 18,
                                    child: CircularProgressIndicator(
                                      strokeWidth: 2,
                                      valueColor: AlwaysStoppedAnimation<Color>(
                                        Colors.white,
                                      ),
                                    ),
                                  )
                                : const Icon(
                                    Icons.camera_alt_outlined,
                                    color: Colors.white,
                                    size: 18,
                                  ),
                            style: IconButton.styleFrom(
                              padding: EdgeInsets.zero,
                              minimumSize: const Size(44, 44),
                              tapTargetSize: MaterialTapTargetSize.shrinkWrap,
                              side: BorderSide(
                                color: Theme.of(context).colorScheme.surface,
                                width: 2,
                              ),
                            ),
                          ),
                        ),
                      ),
                    ),
                ],
              ),
            ),
          ),
        ],
      ),
    );
  }
}

class _FullscreenProfilePhotoView extends StatelessWidget {
  const _FullscreenProfilePhotoView({
    required this.imageUrl,
    required this.heroTag,
  });

  final String imageUrl;
  final String heroTag;

  @override
  Widget build(BuildContext context) {
    return Material(
      color: Colors.transparent,
      child: SafeArea(
        child: Stack(
          children: [
            Positioned.fill(
              child: InteractiveViewer(
                minScale: 1,
                maxScale: 4,
                child: Center(
                  child: Hero(
                    tag: heroTag,
                    child: Image.network(
                      resolveMediaUrl(imageUrl),
                      fit: BoxFit.contain,
                      gaplessPlayback: true,
                    ),
                  ),
                ),
              ),
            ),
            Positioned(
              top: 12,
              left: 12,
              child: IconButton.filled(
                onPressed: () => Navigator.of(context).pop(),
                icon: const Icon(Icons.close_rounded),
              ),
            ),
          ],
        ),
      ),
    );
  }
}

class _SingleCoverHeader extends StatelessWidget {
  const _SingleCoverHeader({
    required this.imageUrl,
    required this.thumbUrl,
    required this.ownProfile,
  });

  final String imageUrl;
  final String? thumbUrl;
  final bool ownProfile;

  @override
  Widget build(BuildContext context) {
    return _ProfileCoverImage(
      imageUrl: imageUrl,
      thumbUrl: thumbUrl,
      ownProfile: ownProfile,
    );
  }
}

class _MultiCoverHeader extends StatefulWidget {
  const _MultiCoverHeader({
    super.key,
    required this.imageUrls,
    required this.thumbUrls,
    required this.ownProfile,
  });

  final List<String> imageUrls;
  final List<String> thumbUrls;
  final bool ownProfile;

  @override
  State<_MultiCoverHeader> createState() => _MultiCoverHeaderState();
}

class _MultiCoverHeaderState extends State<_MultiCoverHeader> {
  late final PageController _pageController;
  int _page = 0;

  @override
  void initState() {
    super.initState();
    _pageController = PageController();
  }

  @override
  void dispose() {
    _pageController.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return Stack(
      fit: StackFit.expand,
      children: [
        PageView.builder(
          controller: _pageController,
          itemCount: widget.imageUrls.length,
          onPageChanged: (value) => setState(() => _page = value),
          itemBuilder: (context, index) => _ProfileCoverImage(
            imageUrl: widget.imageUrls[index],
            thumbUrl: index < widget.thumbUrls.length
                ? widget.thumbUrls[index]
                : null,
            ownProfile: widget.ownProfile,
          ),
        ),
        Positioned(
          bottom: 14,
          left: 0,
          right: 0,
          child: IgnorePointer(
            child: Row(
              mainAxisAlignment: MainAxisAlignment.center,
              children: List.generate(widget.imageUrls.length, (index) {
                final active = index == _page;
                return AnimatedContainer(
                  key: ValueKey(
                    active ? 'cover-dot-active-$index' : 'cover-dot-$index',
                  ),
                  duration: const Duration(milliseconds: 180),
                  margin: const EdgeInsets.symmetric(horizontal: 3),
                  width: active ? 18 : 7,
                  height: 7,
                  decoration: BoxDecoration(
                    color: active
                        ? Colors.white
                        : Colors.white.withValues(alpha: 0.45),
                    borderRadius: BorderRadius.circular(999),
                  ),
                );
              }),
            ),
          ),
        ),
      ],
    );
  }
}

class _ProfileCoverImage extends StatelessWidget {
  const _ProfileCoverImage({
    required this.imageUrl,
    required this.thumbUrl,
    required this.ownProfile,
  });

  final String imageUrl;
  final String? thumbUrl;
  final bool ownProfile;

  @override
  Widget build(BuildContext context) {
    final media = MediaQuery.sizeOf(context);
    final devicePixelRatio = MediaQuery.devicePixelRatioOf(context);
    final cacheWidth = (media.width * devicePixelRatio).round();
    final safeThumbUrl = thumbUrl?.trim() ?? '';
    final thumbWidget = safeThumbUrl.isEmpty
        ? _CoverImageLoadingPlaceholder(ownProfile: ownProfile)
        : Image.network(
            resolveMediaUrl(safeThumbUrl),
            fit: BoxFit.cover,
            cacheWidth: 320,
            filterQuality: FilterQuality.low,
            gaplessPlayback: true,
            errorBuilder: (context, error, stackTrace) =>
                _CoverImageLoadingPlaceholder(ownProfile: ownProfile),
          );

    return Stack(
      fit: StackFit.expand,
      children: [
        thumbWidget,
        Image.network(
          resolveMediaUrl(imageUrl),
          fit: BoxFit.cover,
          cacheWidth: cacheWidth,
          filterQuality: FilterQuality.medium,
          gaplessPlayback: true,
          frameBuilder: (context, child, frame, wasSynchronouslyLoaded) {
            return AnimatedOpacity(
              opacity: frame == null && !wasSynchronouslyLoaded ? 0 : 1,
              duration: const Duration(milliseconds: 180),
              curve: Curves.easeOut,
              child: child,
            );
          },
          loadingBuilder: (context, child, progress) {
            if (progress == null) return child;
            return Stack(
              fit: StackFit.expand,
              children: [
                child,
                Positioned.fill(
                  child: DecoratedBox(
                    decoration: BoxDecoration(
                      color: Colors.black.withValues(alpha: 0.08),
                    ),
                    child: const Center(
                      child: SizedBox(
                        width: 20,
                        height: 20,
                        child: CircularProgressIndicator(strokeWidth: 2.2),
                      ),
                    ),
                  ),
                ),
              ],
            );
          },
          errorBuilder: (context, error, stackTrace) =>
              _EmptyCoverPlaceholder(ownProfile: ownProfile),
        ),
      ],
    );
  }
}

class _CoverImageLoadingPlaceholder extends StatelessWidget {
  const _CoverImageLoadingPlaceholder({required this.ownProfile});

  final bool ownProfile;

  @override
  Widget build(BuildContext context) {
    return DecoratedBox(
      decoration: const BoxDecoration(
        gradient: LinearGradient(
          begin: Alignment.topLeft,
          end: Alignment.bottomRight,
          colors: [Color(0xFF241217), Color(0xFF4A202A), Color(0xFF8A3343)],
        ),
      ),
      child: DecoratedBox(
        decoration: BoxDecoration(
          gradient: LinearGradient(
            begin: Alignment.topCenter,
            end: Alignment.bottomCenter,
            colors: [
              Colors.white.withValues(alpha: 0.05),
              Colors.black.withValues(alpha: 0.14),
            ],
          ),
        ),
        child: Align(
          alignment: Alignment.bottomLeft,
          child: Padding(
            padding: const EdgeInsets.fromLTRB(20, 20, 20, 20),
            child: Text(
              ownProfile ? 'Loading cover...' : 'Loading profile cover...',
              style: Theme.of(context).textTheme.bodyMedium?.copyWith(
                color: Colors.white.withValues(alpha: 0.92),
                fontWeight: FontWeight.w700,
              ),
            ),
          ),
        ),
      ),
    );
  }
}

class _EmptyCoverPlaceholder extends StatelessWidget {
  const _EmptyCoverPlaceholder({required this.ownProfile});

  final bool ownProfile;

  @override
  Widget build(BuildContext context) {
    return DecoratedBox(
      decoration: const BoxDecoration(
        gradient: LinearGradient(
          begin: Alignment.topLeft,
          end: Alignment.bottomRight,
          colors: [Color(0xFF2A0F16), Color(0xFFE50914), Color(0xFFFF7A59)],
        ),
      ),
      child: Padding(
        padding: const EdgeInsets.fromLTRB(20, 20, 20, 26),
        child: Align(
          alignment: Alignment.bottomLeft,
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              const Icon(Icons.photo_library_outlined, color: Colors.white),
              const SizedBox(height: 10),
              Text(
                ownProfile
                    ? 'Add up to 2 cover photos'
                    : 'This user has not added a cover photo yet.',
                style: Theme.of(context).textTheme.titleMedium?.copyWith(
                  color: Colors.white,
                  fontWeight: FontWeight.w800,
                ),
              ),
              const SizedBox(height: 4),
              Text(
                ownProfile
                    ? 'Your cover photos appear here in a swipeable header.'
                    : 'Profile details will still appear below.',
                style: Theme.of(context).textTheme.bodyMedium?.copyWith(
                  color: Colors.white.withValues(alpha: 0.92),
                  height: 1.3,
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

class _LockedCoverPlaceholder extends StatelessWidget {
  const _LockedCoverPlaceholder();

  @override
  Widget build(BuildContext context) {
    return DecoratedBox(
      decoration: const BoxDecoration(
        gradient: LinearGradient(
          begin: Alignment.topCenter,
          end: Alignment.bottomCenter,
          colors: [Color(0xFF15161A), Color(0xFF262A31)],
        ),
      ),
      child: Center(
        child: Padding(
          padding: const EdgeInsets.symmetric(horizontal: 28),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              Container(
                width: 54,
                height: 54,
                decoration: BoxDecoration(
                  color: Colors.white.withValues(alpha: 0.12),
                  shape: BoxShape.circle,
                ),
                child: const Icon(
                  Icons.lock_outline_rounded,
                  color: Colors.white,
                ),
              ),
              const SizedBox(height: 14),
              Text(
                'Cover photos are visible with Talkflix Pro',
                textAlign: TextAlign.center,
                style: Theme.of(context).textTheme.titleMedium?.copyWith(
                  color: Colors.white,
                  fontWeight: FontWeight.w800,
                ),
              ),
              const SizedBox(height: 6),
              Text(
                'This user’s cover slider is hidden because their Pro subscription is not active.',
                textAlign: TextAlign.center,
                style: Theme.of(context).textTheme.bodyMedium?.copyWith(
                  color: Colors.white.withValues(alpha: 0.82),
                  height: 1.3,
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

class _ProfileStat extends StatelessWidget {
  const _ProfileStat({
    required this.label,
    required this.value,
    this.icon,
    this.onTap,
  });

  final String label;
  final String value;
  final IconData? icon;
  final VoidCallback? onTap;

  @override
  Widget build(BuildContext context) {
    final child = Column(
      mainAxisSize: MainAxisSize.min,
      children: [
        Text(
          value,
          style: Theme.of(
            context,
          ).textTheme.titleMedium?.copyWith(fontWeight: FontWeight.w800),
        ),
        const SizedBox(height: 2),
        Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            if (icon != null) ...[
              Icon(
                icon,
                size: 13,
                color: Theme.of(context).colorScheme.onSurfaceVariant,
              ),
              const SizedBox(width: 4),
            ],
            Text(
              label,
              style: Theme.of(context).textTheme.bodySmall?.copyWith(
                color: Theme.of(context).colorScheme.onSurfaceVariant,
              ),
            ),
          ],
        ),
      ],
    );

    if (onTap == null) return child;
    return InkWell(
      borderRadius: BorderRadius.circular(12),
      onTap: onTap,
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 4),
        child: child,
      ),
    );
  }
}

class _ProfileActionButton extends StatelessWidget {
  const _ProfileActionButton({
    required this.label,
    this.filled = false,
    this.leading,
    this.trailing,
    this.onTap,
  });

  final String label;
  final bool filled;
  final Widget? leading;
  final Widget? trailing;
  final VoidCallback? onTap;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return Material(
      color: filled ? talkflixPrimary : scheme.surfaceContainerHighest,
      borderRadius: BorderRadius.circular(10),
      child: InkWell(
        borderRadius: BorderRadius.circular(10),
        onTap: onTap,
        child: Container(
          height: 34,
          padding: EdgeInsets.symmetric(
            horizontal: leading == null && trailing == null ? 12 : 10,
          ),
          child: Row(
            mainAxisAlignment: MainAxisAlignment.center,
            children: [
              if (leading != null) ...[
                IconTheme(
                  data: IconThemeData(
                    color: filled ? Colors.white : scheme.onSurface,
                  ),
                  child: leading!,
                ),
                const SizedBox(width: 6),
              ],
              Flexible(
                child: Text(
                  label,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: Theme.of(context).textTheme.labelLarge?.copyWith(
                    fontWeight: FontWeight.w700,
                    color: filled ? Colors.white : scheme.onSurface,
                  ),
                ),
              ),
              if (trailing != null) ...[const SizedBox(width: 8), trailing!],
            ],
          ),
        ),
      ),
    );
  }
}

class _ProfileToggle extends StatelessWidget {
  const _ProfileToggle({required this.enabled});

  final bool enabled;

  @override
  Widget build(BuildContext context) {
    final knobAlignment = enabled
        ? Alignment.centerRight
        : Alignment.centerLeft;
    final trackColor = enabled
        ? Colors.white.withValues(alpha: 0.26)
        : Theme.of(context).colorScheme.outlineVariant;
    final knobColor = enabled
        ? Colors.white
        : Theme.of(context).colorScheme.surface;

    return Container(
      width: 34,
      height: 20,
      padding: const EdgeInsets.all(2),
      decoration: BoxDecoration(
        color: trackColor,
        borderRadius: BorderRadius.circular(999),
      ),
      child: AnimatedAlign(
        duration: const Duration(milliseconds: 180),
        curve: Curves.easeOut,
        alignment: knobAlignment,
        child: Container(
          width: 16,
          height: 16,
          decoration: BoxDecoration(
            color: knobColor,
            borderRadius: BorderRadius.circular(999),
          ),
        ),
      ),
    );
  }
}

class _ProfileMetaPill extends StatelessWidget {
  const _ProfileMetaPill({required this.label, this.icon});

  final String label;
  final IconData? icon;

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 7),
      decoration: BoxDecoration(
        color: Theme.of(context).colorScheme.surfaceContainerHighest,
        borderRadius: BorderRadius.circular(999),
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          if (icon != null) ...[
            Icon(
              icon,
              size: 14,
              color: Theme.of(context).colorScheme.onSurfaceVariant,
            ),
            const SizedBox(width: 6),
          ],
          Text(
            label,
            style: Theme.of(
              context,
            ).textTheme.labelMedium?.copyWith(fontWeight: FontWeight.w700),
          ),
        ],
      ),
    );
  }
}

class _ProfileFlagPill extends StatefulWidget {
  const _ProfileFlagPill({
    required this.countryCode,
    required this.countryName,
  });

  final String countryCode;
  final String countryName;

  @override
  State<_ProfileFlagPill> createState() => _ProfileFlagPillState();
}

class _ProfileFlagPillState extends State<_ProfileFlagPill> {
  bool _expanded = false;

  @override
  Widget build(BuildContext context) {
    final flagEmoji = _flagEmojiForCountryCode(widget.countryCode);
    if (flagEmoji.isEmpty) {
      return const SizedBox.shrink();
    }
    final label = widget.countryName.trim();

    return Material(
      color: Theme.of(context).colorScheme.surfaceContainerHighest,
      borderRadius: BorderRadius.circular(999),
      child: InkWell(
        borderRadius: BorderRadius.circular(999),
        onTap: label.isEmpty
            ? null
            : () => setState(() => _expanded = !_expanded),
        child: AnimatedSize(
          duration: const Duration(milliseconds: 180),
          curve: Curves.easeOut,
          child: Padding(
            padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 7),
            child: Row(
              mainAxisSize: MainAxisSize.min,
              children: [
                Text(flagEmoji, style: const TextStyle(fontSize: 16)),
                if (_expanded && label.isNotEmpty) ...[
                  const SizedBox(width: 8),
                  Text(
                    label,
                    style: Theme.of(context).textTheme.labelMedium?.copyWith(
                      fontWeight: FontWeight.w700,
                    ),
                  ),
                ],
              ],
            ),
          ),
        ),
      ),
    );
  }
}

class _ProfileProBadge extends StatelessWidget {
  const _ProfileProBadge();

  @override
  Widget build(BuildContext context) {
    return const TalkflixProBadge();
  }
}

// ── Profile media grid ───────────────────────────────────────────────────────

class _ProfileMediaGrid extends ConsumerStatefulWidget {
  const _ProfileMediaGrid({required this.userId, required this.isOwnProfile});

  final String userId;
  final bool isOwnProfile;

  @override
  ConsumerState<_ProfileMediaGrid> createState() => _ProfileMediaGridState();
}

class _ProfileMediaGridState extends ConsumerState<_ProfileMediaGrid> {
  final _picker = ImagePicker();
  bool _busy = false;

  Future<int> _durationSecondsForVideo(XFile file) async {
    final controller = VideoPlayerController.file(File(file.path));
    try {
      await controller.initialize();
      return controller.value.duration.inSeconds;
    } finally {
      await controller.dispose();
    }
  }

  void _showMessage(String message) {
    if (!mounted) return;
    ScaffoldMessenger.of(
      context,
    ).showSnackBar(SnackBar(content: Text(message)));
  }

  Future<void> _addPhotos(ProfileMediaPayload media) async {
    if (_busy) return;
    final remaining = media.remainingPhotoSlots;
    if (remaining <= 0) {
      _showMessage('You can share up to $_profilePhotoLimit profile photos.');
      return;
    }
    final picked = await _picker.pickMultiImage();
    if (!mounted || picked.isEmpty) return;
    final selected = picked.take(remaining).toList();
    setState(() => _busy = true);
    try {
      for (final file in selected) {
        await ref
            .read(profileRepositoryProvider)
            .uploadProfileMediaPhoto(imagePath: file.path);
      }
      ref.invalidate(profileMediaProvider(widget.userId));
      if (picked.length > selected.length) {
        _showMessage(
          'Added ${selected.length} photos. Profile photos are limited to $_profilePhotoLimit.',
        );
      }
    } catch (e) {
      _showMessage(userFriendlyMessageFromObject(e));
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  Future<void> _addVideo(ProfileMediaPayload media) async {
    if (_busy) return;
    if (!media.canAddVideo) {
      _showMessage('You can share only $_profileVideoLimit profile video.');
      return;
    }
    final picked = await _picker.pickVideo(
      source: ImageSource.gallery,
      maxDuration: _profileVideoDurationLimit,
    );
    if (!mounted || picked == null) return;

    setState(() => _busy = true);
    try {
      final durationSeconds = await _durationSecondsForVideo(picked);
      if (durationSeconds > _profileVideoDurationLimit.inSeconds) {
        _showMessage(
          'Profile videos must be ${_profileVideoDurationLimit.inSeconds} seconds or shorter.',
        );
        return;
      }
      await ref
          .read(profileRepositoryProvider)
          .uploadProfileMediaVideo(
            videoPath: picked.path,
            durationSeconds: durationSeconds,
          );
      ref.invalidate(profileMediaProvider(widget.userId));
    } catch (e) {
      _showMessage(userFriendlyMessageFromObject(e));
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  Future<void> _deletePhoto(ProfileMediaItem item) async {
    if (_busy || item.id.isEmpty) return;
    setState(() => _busy = true);
    try {
      await ref
          .read(profileRepositoryProvider)
          .deleteProfileMediaPhoto(item.id);
      ref.invalidate(profileMediaProvider(widget.userId));
    } catch (e) {
      _showMessage(userFriendlyMessageFromObject(e));
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  Future<void> _deleteVideo() async {
    if (_busy) return;
    setState(() => _busy = true);
    try {
      await ref.read(profileRepositoryProvider).deleteProfileMediaVideo();
      ref.invalidate(profileMediaProvider(widget.userId));
    } catch (e) {
      _showMessage(userFriendlyMessageFromObject(e));
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  void _openMedia(ProfileMediaItem item) {
    showModalBottomSheet<void>(
      context: context,
      isScrollControlled: true,
      backgroundColor: Colors.black,
      builder: (_) => _ProfileMediaPreview(item: item),
    );
  }

  @override
  Widget build(BuildContext context) {
    final media = ref.watch(profileMediaProvider(widget.userId));
    return media.when(
      loading: () => const SliverToBoxAdapter(
        child: Padding(
          padding: EdgeInsets.symmetric(vertical: 48),
          child: Center(child: CircularProgressIndicator()),
        ),
      ),
      error: (e, _) => SliverToBoxAdapter(
        child: Padding(
          padding: const EdgeInsets.fromLTRB(18, 0, 18, 28),
          child: Column(
            children: [
              if (widget.isOwnProfile) ...[
                _ProfileMediaManagePanel(
                  media: const ProfileMediaPayload(
                    photos: <ProfileMediaItem>[],
                    maxPhotos: _profilePhotoLimit,
                    maxVideos: _profileVideoLimit,
                  ),
                  busy: _busy,
                  onAddPhotos: () => _addPhotos(
                    const ProfileMediaPayload(
                      photos: <ProfileMediaItem>[],
                      maxPhotos: _profilePhotoLimit,
                      maxVideos: _profileVideoLimit,
                    ),
                  ),
                  onAddVideo: () => _addVideo(
                    const ProfileMediaPayload(
                      photos: <ProfileMediaItem>[],
                      maxPhotos: _profilePhotoLimit,
                      maxVideos: _profileVideoLimit,
                    ),
                  ),
                ),
                const SizedBox(height: 12),
              ],
              _PostsEmptyState(
                icon: Icons.error_outline_rounded,
                message: userFriendlyMessageFromObject(e),
              ),
            ],
          ),
        ),
      ),
      data: (payload) {
        final items = <_ProfileMediaGridEntry>[
          if (payload.video != null)
            _ProfileMediaGridEntry.media(payload.video!, isVideoSlot: true),
          ...payload.photos.map(_ProfileMediaGridEntry.media),
          if (widget.isOwnProfile && payload.canAddVideo)
            const _ProfileMediaGridEntry.addVideo(),
          if (widget.isOwnProfile && payload.canAddPhoto)
            const _ProfileMediaGridEntry.addPhoto(),
        ];

        if (items.isEmpty && !widget.isOwnProfile) {
          return const SliverToBoxAdapter(
            child: Padding(
              padding: EdgeInsets.fromLTRB(18, 0, 18, 28),
              child: _PostsEmptyState(
                icon: Icons.photo_library_outlined,
                message: 'No profile media yet.',
              ),
            ),
          );
        }

        return SliverToBoxAdapter(
          child: Padding(
            padding: const EdgeInsets.fromLTRB(2, 0, 2, 28),
            child: Column(
              children: [
                if (widget.isOwnProfile) ...[
                  Padding(
                    padding: const EdgeInsets.fromLTRB(16, 0, 16, 14),
                    child: _ProfileMediaManagePanel(
                      media: payload,
                      busy: _busy,
                      onAddPhotos: () => _addPhotos(payload),
                      onAddVideo: () => _addVideo(payload),
                    ),
                  ),
                ],
                if (items.isEmpty)
                  const Padding(
                    padding: EdgeInsets.fromLTRB(16, 0, 16, 0),
                    child: _PostsEmptyState(
                      icon: Icons.photo_library_outlined,
                      message:
                          'Add up to $_profilePhotoLimit photos and one short video to your profile.',
                    ),
                  )
                else
                  GridView.builder(
                    shrinkWrap: true,
                    physics: const NeverScrollableScrollPhysics(),
                    itemCount: items.length,
                    gridDelegate:
                        const SliverGridDelegateWithFixedCrossAxisCount(
                          crossAxisCount: 3,
                          crossAxisSpacing: 2,
                          mainAxisSpacing: 2,
                        ),
                    itemBuilder: (context, index) {
                      final entry = items[index];
                      return _ProfileMediaTile(
                        entry: entry,
                        busy: _busy,
                        onTap: switch (entry.action) {
                          _ProfileMediaGridAction.addPhoto => () => _addPhotos(
                            payload,
                          ),
                          _ProfileMediaGridAction.addVideo => () => _addVideo(
                            payload,
                          ),
                          _ProfileMediaGridAction.view => () => _openMedia(
                            entry.item!,
                          ),
                        },
                        onDelete: !widget.isOwnProfile || entry.item == null
                            ? null
                            : entry.isVideoSlot
                            ? _deleteVideo
                            : () => _deletePhoto(entry.item!),
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

enum _ProfileMediaGridAction { view, addPhoto, addVideo }

class _ProfileMediaManagePanel extends StatelessWidget {
  const _ProfileMediaManagePanel({
    required this.media,
    required this.busy,
    required this.onAddPhotos,
    required this.onAddVideo,
  });

  final ProfileMediaPayload media;
  final bool busy;
  final VoidCallback onAddPhotos;
  final VoidCallback onAddVideo;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return Container(
      width: double.infinity,
      padding: const EdgeInsets.all(14),
      decoration: BoxDecoration(
        color: scheme.surfaceContainerLow,
        borderRadius: BorderRadius.circular(16),
        border: Border.all(color: scheme.outlineVariant),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(
            'Profile media',
            style: Theme.of(
              context,
            ).textTheme.titleSmall?.copyWith(fontWeight: FontWeight.w800),
          ),
          const SizedBox(height: 4),
          Text(
            '${media.photos.length}/${media.maxPhotos} photos · ${media.video == null ? 0 : 1}/${media.maxVideos} video',
            style: Theme.of(
              context,
            ).textTheme.bodySmall?.copyWith(color: scheme.onSurfaceVariant),
          ),
          const SizedBox(height: 12),
          Row(
            children: [
              Expanded(
                child: OutlinedButton.icon(
                  onPressed: busy || !media.canAddPhoto ? null : onAddPhotos,
                  icon: const Icon(Icons.add_photo_alternate_outlined),
                  label: const Text('Add photos'),
                ),
              ),
              const SizedBox(width: 10),
              Expanded(
                child: OutlinedButton.icon(
                  onPressed: busy || !media.canAddVideo ? null : onAddVideo,
                  icon: const Icon(Icons.video_call_outlined),
                  label: const Text('Add video'),
                ),
              ),
            ],
          ),
        ],
      ),
    );
  }
}

class _ProfileMediaGridEntry {
  const _ProfileMediaGridEntry.media(this.item, {this.isVideoSlot = false})
    : action = _ProfileMediaGridAction.view;

  const _ProfileMediaGridEntry.addPhoto()
    : item = null,
      isVideoSlot = false,
      action = _ProfileMediaGridAction.addPhoto;

  const _ProfileMediaGridEntry.addVideo()
    : item = null,
      isVideoSlot = true,
      action = _ProfileMediaGridAction.addVideo;

  final ProfileMediaItem? item;
  final bool isVideoSlot;
  final _ProfileMediaGridAction action;
}

class _ProfileMediaTile extends StatelessWidget {
  const _ProfileMediaTile({
    required this.entry,
    required this.busy,
    required this.onTap,
    required this.onDelete,
  });

  final _ProfileMediaGridEntry entry;
  final bool busy;
  final VoidCallback onTap;
  final VoidCallback? onDelete;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final item = entry.item;
    final isAdd = item == null;
    final imageUrl = item?.thumbnailUrl.isNotEmpty == true
        ? item!.thumbnailUrl
        : item?.url ?? '';

    Widget content;
    if (isAdd) {
      content = DecoratedBox(
        decoration: BoxDecoration(color: scheme.surfaceContainerHighest),
        child: Center(
          child: Icon(
            entry.action == _ProfileMediaGridAction.addVideo
                ? Icons.video_call_outlined
                : Icons.add_photo_alternate_outlined,
            color: scheme.onSurfaceVariant,
            size: 30,
          ),
        ),
      );
    } else if (imageUrl.isNotEmpty) {
      content = Image.network(
        resolveMediaUrl(imageUrl),
        fit: BoxFit.cover,
        errorBuilder: (_, error, stackTrace) => _TileIcon(
          icon: item.isVideo
              ? Icons.play_circle_outline_rounded
              : Icons.broken_image_outlined,
          color: Colors.white70,
          bg: scheme.surfaceContainerHighest,
        ),
      );
    } else {
      content = _TileIcon(
        icon: item.isVideo
            ? Icons.play_circle_outline_rounded
            : Icons.photo_outlined,
        color: Colors.white70,
        bg: scheme.surfaceContainerHighest,
      );
    }

    return GestureDetector(
      onTap: busy ? null : onTap,
      child: Stack(
        fit: StackFit.expand,
        children: [
          content,
          if (item?.isVideo == true ||
              entry.action == _ProfileMediaGridAction.addVideo)
            const Positioned(
              left: 6,
              bottom: 6,
              child: Icon(
                Icons.play_circle_fill_rounded,
                size: 20,
                color: Colors.white,
                shadows: [Shadow(color: Colors.black54, blurRadius: 4)],
              ),
            ),
          if (onDelete != null)
            Positioned(
              top: 4,
              right: 4,
              child: GestureDetector(
                onTap: busy ? null : onDelete,
                child: Container(
                  width: 26,
                  height: 26,
                  decoration: BoxDecoration(
                    color: Colors.black.withValues(alpha: 0.62),
                    shape: BoxShape.circle,
                  ),
                  child: const Icon(
                    Icons.close_rounded,
                    color: Colors.white,
                    size: 16,
                  ),
                ),
              ),
            ),
          if (busy)
            ColoredBox(
              color: Colors.black.withValues(alpha: 0.18),
              child: const Center(
                child: SizedBox(
                  width: 22,
                  height: 22,
                  child: CircularProgressIndicator(strokeWidth: 2.4),
                ),
              ),
            ),
        ],
      ),
    );
  }
}

class _ProfileMediaPreview extends StatefulWidget {
  const _ProfileMediaPreview({required this.item});

  final ProfileMediaItem item;

  @override
  State<_ProfileMediaPreview> createState() => _ProfileMediaPreviewState();
}

class _ProfileMediaPreviewState extends State<_ProfileMediaPreview> {
  VideoPlayerController? _controller;
  Future<void>? _initializeFuture;

  @override
  void initState() {
    super.initState();
    if (widget.item.isVideo) {
      final controller = VideoPlayerController.networkUrl(
        Uri.parse(resolveMediaUrl(widget.item.url)),
      );
      _controller = controller;
      _initializeFuture = controller.initialize().then((_) {
        controller
          ..setLooping(true)
          ..play();
        if (mounted) setState(() {});
      });
    }
  }

  @override
  void dispose() {
    _controller?.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final item = widget.item;
    return SafeArea(
      child: SizedBox(
        height: MediaQuery.sizeOf(context).height * 0.82,
        child: Stack(
          children: [
            Center(
              child: item.isVideo
                  ? FutureBuilder<void>(
                      future: _initializeFuture,
                      builder: (context, snapshot) {
                        final controller = _controller;
                        if (controller == null ||
                            snapshot.connectionState != ConnectionState.done) {
                          return const CircularProgressIndicator();
                        }
                        return AspectRatio(
                          aspectRatio: controller.value.aspectRatio == 0
                              ? 16 / 9
                              : controller.value.aspectRatio,
                          child: VideoPlayer(controller),
                        );
                      },
                    )
                  : InteractiveViewer(
                      child: Image.network(
                        resolveMediaUrl(item.url),
                        fit: BoxFit.contain,
                      ),
                    ),
            ),
            Positioned(
              top: 8,
              right: 8,
              child: IconButton.filled(
                onPressed: () => Navigator.of(context).pop(),
                icon: const Icon(Icons.close_rounded),
              ),
            ),
          ],
        ),
      ),
    );
  }
}

// ── Profile post grid ─────────────────────────────────────────────────────────

// ignore: unused_element
class _ProfilePostGrid extends ConsumerWidget {
  const _ProfilePostGrid({required this.userId, required this.isOwnProfile});

  final String userId;
  final bool isOwnProfile;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final contentItems = ref.watch(creatorProfileContentProvider(userId));

    return contentItems.when(
      loading: () => const SliverToBoxAdapter(
        child: Padding(
          padding: EdgeInsets.symmetric(vertical: 48),
          child: Center(child: CircularProgressIndicator()),
        ),
      ),
      error: (e, _) => SliverToBoxAdapter(
        child: Padding(
          padding: const EdgeInsets.fromLTRB(18, 0, 18, 28),
          child: _PostsEmptyState(
            icon: Icons.error_outline_rounded,
            message: userFriendlyMessageFromObject(e),
          ),
        ),
      ),
      data: (items) {
        if (items.isEmpty) {
          return SliverToBoxAdapter(
            child: Padding(
              padding: const EdgeInsets.fromLTRB(18, 0, 18, 28),
              child: _PostsEmptyState(
                icon: Icons.photo_library_outlined,
                message: isOwnProfile
                    ? 'Share your first post or podcast from the Content tab.'
                    : 'No posts or podcasts yet.',
              ),
            ),
          );
        }
        return SliverPadding(
          padding: const EdgeInsets.fromLTRB(2, 0, 2, 28),
          sliver: SliverGrid(
            delegate: SliverChildBuilderDelegate(
              (context, index) => _CreatorContentGridTile(
                item: items[index],
                onTap: () => _showContentDetail(context, ref, items[index]),
              ),
              childCount: items.length,
            ),
            gridDelegate: const SliverGridDelegateWithFixedCrossAxisCount(
              crossAxisCount: 3,
              crossAxisSpacing: 2,
              mainAxisSpacing: 2,
            ),
          ),
        );
      },
    );
  }

  Future<void> _showContentDetail(
    BuildContext context,
    WidgetRef ref,
    _CreatorProfileContentItem item,
  ) async {
    final podcast = item.podcast;
    if (podcast != null) {
      await Navigator.of(context, rootNavigator: true).push(
        MaterialPageRoute<void>(
          builder: (context) => TalkizPodcastDetailScreen(
            item: podcast,
            currentUser: ref.read(sessionControllerProvider).user,
          ),
        ),
      );
      return;
    }
    final post = item.post;
    if (post == null) return;
    final videoAsset = post.assets
        .where((asset) => asset.isVideo && asset.url.trim().isNotEmpty)
        .firstOrNull;
    if (videoAsset != null) {
      await openTalkizVideoFullscreen(
        context: context,
        contentId: post.id,
        title: post.title,
        source: videoAsset.url,
        posterUrl: videoAsset.posterUrl,
      );
      return;
    }
    if (post.kind.trim().toLowerCase() == 'video') {
      await Navigator.of(context, rootNavigator: true).push(
        MaterialPageRoute<void>(
          builder: (context) => ContentVideoScreen(videoId: post.id),
        ),
      );
      return;
    }
    await Navigator.of(context, rootNavigator: true).push(
      MaterialPageRoute<void>(
        builder: (context) => TalkizPostDetailScreen(
          post: post,
          currentUser: ref.read(sessionControllerProvider).user,
        ),
      ),
    );
  }
}

// ── Grid tile ─────────────────────────────────────────────────────────────────

class _CreatorContentGridTile extends StatelessWidget {
  const _CreatorContentGridTile({required this.item, required this.onTap});

  final _CreatorProfileContentItem item;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final post = item.post;
    final podcast = item.podcast;
    final firstImage = post?.assets
        .where((a) => a.isImage)
        .map((a) => a.url)
        .firstOrNull;
    final firstVideoPoster =
        post?.assets
            .where((a) => a.isVideo)
            .map((a) => a.posterUrl)
            .firstWhere((url) => url.trim().isNotEmpty, orElse: () => '') ??
        '';
    final isPodcastTile = podcast != null;
    final isVideoTile =
        post != null &&
        (post.kind.trim().toLowerCase() == 'video' ||
            post.assets.any((asset) => asset.isVideo));

    Widget content;
    if (isPodcastTile && podcast.coverUrl.trim().isNotEmpty) {
      content = Image.network(
        resolveMediaUrl(podcast.coverUrl),
        fit: BoxFit.cover,
        errorBuilder: (_, error, stackTrace) => const _TileIcon(
          icon: Icons.podcasts_rounded,
          color: Colors.white70,
          bg: Color(0xFF122033),
        ),
      );
    } else if (firstImage != null && firstImage.isNotEmpty) {
      content = Image.network(
        resolveMediaUrl(firstImage),
        fit: BoxFit.cover,
        errorBuilder: (_, error, stackTrace) => _TileIcon(
          icon: Icons.broken_image_outlined,
          color: scheme.onSurfaceVariant,
          bg: scheme.surfaceContainerHighest,
        ),
      );
    } else if (firstVideoPoster.isNotEmpty) {
      content = Image.network(
        resolveMediaUrl(firstVideoPoster),
        fit: BoxFit.cover,
        errorBuilder: (_, error, stackTrace) => const _TileIcon(
          icon: Icons.play_circle_outline_rounded,
          color: Colors.white70,
          bg: Color(0xFF0D0D1A),
        ),
      );
    } else {
      final (icon, bg) = switch (post?.kind) {
        'audio' => (Icons.music_note_rounded, const Color(0xFF1A1A2E)),
        'video' => (Icons.play_circle_outline_rounded, const Color(0xFF0D0D1A)),
        _ when isPodcastTile => (
          Icons.podcasts_rounded,
          const Color(0xFF122033),
        ),
        _ => (Icons.article_outlined, scheme.surfaceContainerHighest),
      };
      content = _TileIcon(icon: icon, color: Colors.white70, bg: bg);
      // For text posts, overlay a snippet
      if (post != null && (post.kind == 'text' || post.kind == '')) {
        content = Stack(
          fit: StackFit.expand,
          children: [
            DecoratedBox(
              decoration: BoxDecoration(color: scheme.surfaceContainerHighest),
            ),
            Padding(
              padding: const EdgeInsets.all(8),
              child: Text(
                post.body.isNotEmpty ? post.body : post.title,
                maxLines: 5,
                overflow: TextOverflow.fade,
                style: Theme.of(context).textTheme.bodySmall?.copyWith(
                  color: scheme.onSurface,
                  height: 1.3,
                ),
              ),
            ),
          ],
        );
      }
    }

    // Multi-image badge
    final hasMultiple = (post?.assets.length ?? 0) > 1;

    return GestureDetector(
      onTap: onTap,
      child: Stack(
        fit: StackFit.expand,
        children: [
          content,
          if (isPodcastTile)
            const Center(
              child: Icon(
                Icons.podcasts_rounded,
                size: 30,
                color: Colors.white,
                shadows: [Shadow(color: Colors.black87, blurRadius: 8)],
              ),
            ),
          if (isVideoTile)
            const Center(
              child: Icon(
                Icons.play_circle_fill_rounded,
                size: 34,
                color: Colors.white,
                shadows: [Shadow(color: Colors.black87, blurRadius: 8)],
              ),
            ),
          if (hasMultiple)
            const Positioned(
              top: 6,
              right: 6,
              child: Icon(
                Icons.collections_rounded,
                size: 16,
                color: Colors.white,
                shadows: [Shadow(color: Colors.black54, blurRadius: 4)],
              ),
            ),
        ],
      ),
    );
  }
}

class _CreatorProfileContentItem {
  _CreatorProfileContentItem.post(UserPostItem post)
    : this._(post: post, podcast: null, publishedAt: post.publishedAt);

  _CreatorProfileContentItem.podcast(PodcastEpisodeItem podcast)
    : this._(post: null, podcast: podcast, publishedAt: podcast.publishedAt);

  const _CreatorProfileContentItem._({
    required this.post,
    required this.podcast,
    required this.publishedAt,
  });

  final UserPostItem? post;
  final PodcastEpisodeItem? podcast;
  final DateTime? publishedAt;

  String get id => post?.id ?? podcast?.id ?? '';
}

class _TileIcon extends StatelessWidget {
  const _TileIcon({required this.icon, required this.color, required this.bg});

  final IconData icon;
  final Color color;
  final Color bg;

  @override
  Widget build(BuildContext context) {
    return DecoratedBox(
      decoration: BoxDecoration(color: bg),
      child: Center(child: Icon(icon, color: color, size: 28)),
    );
  }
}

// ── Post detail sheet ─────────────────────────────────────────────────────────

class _PostDetailSheet extends ConsumerStatefulWidget {
  const _PostDetailSheet({required this.post, required this.scrollController});

  final UserPostItem post;
  final ScrollController scrollController;

  @override
  ConsumerState<_PostDetailSheet> createState() => _PostDetailSheetState();
}

class _PostDetailSheetState extends ConsumerState<_PostDetailSheet> {
  late int _likeCount;
  late bool _likedByMe;
  bool _likeBusy = false;

  // Comments state
  final List<ContentCommentItem> _comments = [];
  final Set<String> _expandedReplyParentIds = <String>{};
  bool _commentsLoading = true;
  bool _submitting = false;
  final _commentController = TextEditingController();
  final _commentFocusNode = FocusNode();
  ContentCommentItem? _replyingTo;

  @override
  void initState() {
    super.initState();
    _likeCount = widget.post.likeCount;
    _likedByMe = widget.post.likedByMe;
    Future<void>.microtask(_loadComments);
  }

  @override
  void dispose() {
    _commentController.dispose();
    _commentFocusNode.dispose();
    super.dispose();
  }

  Future<void> _loadComments() async {
    try {
      final items = await ref
          .read(contentRepositoryProvider)
          .fetchComments(widget.post.id);
      if (!mounted) return;
      setState(() {
        _comments
          ..clear()
          ..addAll(items);
        _commentsLoading = false;
      });
    } catch (_) {
      if (!mounted) return;
      setState(() => _commentsLoading = false);
    }
  }

  Future<void> _submitComment() async {
    final body = _commentController.text.trim();
    if (body.isEmpty || _submitting) return;
    setState(() => _submitting = true);
    final replyTarget = _replyingTo;
    try {
      final result = await ref
          .read(contentRepositoryProvider)
          .addComment(
            contentId: widget.post.id,
            body: body,
            parentId: _replyingTo?.id,
          );
      if (!mounted) return;
      _commentController.clear();
      setState(() {
        _comments.add(result.comment);
        if (replyTarget != null) {
          _expandedReplyParentIds.add(replyTarget.id);
        }
        _replyingTo = null;
      });
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
    _commentFocusNode.requestFocus();
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
    } catch (_) {
    } finally {
      if (mounted) setState(() => _likeBusy = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;
    final post = widget.post;
    final hasAssets = post.assets.isNotEmpty;
    final showBody = post.body.trim().isNotEmpty;
    final commentNodes = _flattenComments();
    final currentUser = ref.watch(sessionControllerProvider).user;

    return Column(
      children: [
        Expanded(
          child: ListView(
            controller: widget.scrollController,
            padding: const EdgeInsets.fromLTRB(18, 0, 18, 20),
            children: [
              // Author row
              Row(
                children: [
                  CircleAvatar(
                    radius: 20,
                    backgroundColor: scheme.primaryContainer,
                    child: Text(
                      post.authorName.trim().isEmpty
                          ? 'U'
                          : post.authorName.trim()[0].toUpperCase(),
                      style: TextStyle(
                        color: scheme.onPrimaryContainer,
                        fontWeight: FontWeight.w800,
                      ),
                    ),
                  ),
                  const SizedBox(width: 12),
                  Expanded(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Text(
                          post.authorName,
                          style: theme.textTheme.titleSmall?.copyWith(
                            fontWeight: FontWeight.w800,
                          ),
                        ),
                        if (post.publishedAt != null)
                          Text(
                            _dateLabel(post.publishedAt!),
                            style: theme.textTheme.bodySmall?.copyWith(
                              color: scheme.onSurfaceVariant,
                            ),
                          ),
                      ],
                    ),
                  ),
                ],
              ),
              const SizedBox(height: 14),
              if (showBody) ...[
                const SizedBox(height: 8),
                if (hasAssets)
                  _ExpandableBody(
                    text: post.body,
                    style: theme.textTheme.bodyMedium?.copyWith(height: 1.45),
                  )
                else
                  Text(
                    post.body,
                    style: theme.textTheme.bodyMedium?.copyWith(height: 1.45),
                  ),
              ],
              // Assets carousel
              if (hasAssets) ...[
                const SizedBox(height: 14),
                _SheetAssetCarousel(assets: post.assets),
              ],
              const SizedBox(height: 16),
              // Like row
              Row(
                children: [
                  GestureDetector(
                    onTap: _likeBusy ? null : _toggleLike,
                    child: Icon(
                      _likedByMe
                          ? Icons.favorite_rounded
                          : Icons.favorite_border_rounded,
                      color: _likedByMe ? Colors.redAccent : null,
                      size: 26,
                    ),
                  ),
                  const SizedBox(width: 6),
                  Text(
                    compactCount(_likeCount),
                    style: theme.textTheme.labelLarge?.copyWith(
                      fontWeight: FontWeight.w700,
                    ),
                  ),
                  const SizedBox(width: 16),
                  Icon(
                    Icons.remove_red_eye_outlined,
                    size: 20,
                    color: scheme.onSurfaceVariant,
                  ),
                  const SizedBox(width: 6),
                  Text(
                    compactCount(post.viewCount),
                    style: theme.textTheme.labelLarge?.copyWith(
                      fontWeight: FontWeight.w700,
                      color: scheme.onSurfaceVariant,
                    ),
                  ),
                ],
              ),

              // ── Comments section ──────────────────────────────────────
              const SizedBox(height: 20),
              const Divider(),
              const SizedBox(height: 4),
              Text(
                'Comments',
                style: theme.textTheme.titleMedium?.copyWith(
                  fontWeight: FontWeight.w800,
                ),
              ),
              const SizedBox(height: 12),
              if (_commentsLoading)
                const Padding(
                  padding: EdgeInsets.symmetric(vertical: 20),
                  child: Center(child: CircularProgressIndicator()),
                )
              else if (_comments.isEmpty)
                Padding(
                  padding: const EdgeInsets.symmetric(vertical: 16),
                  child: Text(
                    'No comments yet. Be the first!',
                    style: theme.textTheme.bodyMedium?.copyWith(
                      color: scheme.onSurfaceVariant,
                    ),
                  ),
                )
              else
                ...List.generate(commentNodes.length, (i) {
                  final node = commentNodes[i];
                  final indent = (node.depth * 18).clamp(0, 54).toDouble();
                  return Padding(
                    padding: EdgeInsets.only(left: indent, bottom: 12),
                    child: _InlineCommentTile(
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
                }),
            ],
          ),
        ),
        SafeArea(
          top: false,
          child: Container(
            padding: EdgeInsets.fromLTRB(
              18,
              12,
              18,
              MediaQuery.of(context).viewInsets.bottom + 12,
            ),
            decoration: BoxDecoration(
              color: scheme.surface,
              border: Border(top: BorderSide(color: scheme.outlineVariant)),
            ),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                if (_replyingTo != null) ...[
                  Row(
                    children: [
                      Text(
                        'Replying to ${_replyingTo!.authorName}',
                        style: theme.textTheme.bodySmall?.copyWith(
                          color: scheme.primary,
                          fontWeight: FontWeight.w700,
                        ),
                      ),
                      const Spacer(),
                      GestureDetector(
                        onTap: () => setState(() => _replyingTo = null),
                        child: Icon(
                          Icons.close,
                          size: 16,
                          color: scheme.onSurfaceVariant,
                        ),
                      ),
                    ],
                  ),
                  const SizedBox(height: 8),
                ],
                Row(
                  crossAxisAlignment: CrossAxisAlignment.end,
                  children: [
                    AppAvatar(
                      label: currentUser?.displayName ?? 'You',
                      imageUrl: currentUser?.profilePhotoUrl,
                      radius: 18,
                    ),
                    const SizedBox(width: 10),
                    Expanded(
                      child: TextField(
                        controller: _commentController,
                        focusNode: _commentFocusNode,
                        minLines: 1,
                        maxLines: 4,
                        textCapitalization: TextCapitalization.sentences,
                        decoration: const InputDecoration(
                          hintText: 'Add a comment…',
                          border: OutlineInputBorder(),
                          contentPadding: EdgeInsets.symmetric(
                            horizontal: 14,
                            vertical: 10,
                          ),
                        ),
                      ),
                    ),
                    const SizedBox(width: 10),
                    FilledButton(
                      onPressed: _submitting ? null : _submitComment,
                      child: Text(_submitting ? '…' : 'Post'),
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

  String _dateLabel(DateTime dt) {
    final local = dt.toLocal();
    const months = [
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
    return '${months[local.month - 1]} ${local.day}, ${local.year}';
  }
}

// ── Inline comment tile (used in _PostDetailSheet) ────────────────────────────

class _InlineCommentTile extends ConsumerStatefulWidget {
  const _InlineCommentTile({
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
  ConsumerState<_InlineCommentTile> createState() => _InlineCommentTileState();
}

class _InlineCommentTileState extends ConsumerState<_InlineCommentTile> {
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
    final theme = Theme.of(context);
    final initial = widget.comment.authorName.trim().isEmpty
        ? 'U'
        : widget.comment.authorName.trim()[0].toUpperCase();
    return Row(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        CircleAvatar(
          radius: 17,
          backgroundColor: scheme.primaryContainer,
          child: Text(
            initial,
            style: TextStyle(
              color: scheme.onPrimaryContainer,
              fontWeight: FontWeight.w800,
              fontSize: 13,
            ),
          ),
        ),
        const SizedBox(width: 10),
        Expanded(
          child: Container(
            padding: const EdgeInsets.fromLTRB(12, 10, 12, 10),
            decoration: BoxDecoration(
              color: widget.depth == 0
                  ? scheme.surfaceContainerLow
                  : scheme.surfaceContainerHighest,
              borderRadius: BorderRadius.circular(16),
            ),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  widget.comment.authorName,
                  style: theme.textTheme.labelMedium?.copyWith(
                    fontWeight: FontWeight.w800,
                  ),
                ),
                const SizedBox(height: 3),
                if (widget.comment.replyToName?.trim().isNotEmpty == true) ...[
                  Text(
                    'Replying to ${widget.comment.replyToName!.trim()}',
                    style: theme.textTheme.labelSmall?.copyWith(
                      color: scheme.primary,
                      fontWeight: FontWeight.w700,
                    ),
                  ),
                  const SizedBox(height: 4),
                ],
                Text(
                  widget.comment.body,
                  style: theme.textTheme.bodySmall?.copyWith(height: 1.4),
                ),
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
                          style: theme.textTheme.bodySmall?.copyWith(
                            color: scheme.onSurfaceVariant,
                            fontWeight: FontWeight.w700,
                          ),
                        ),
                      ),
                      const SizedBox(width: 12),
                    ],
                    GestureDetector(
                      onTap: widget.onReply,
                      child: Text(
                        'Reply',
                        style: theme.textTheme.bodySmall?.copyWith(
                          color: scheme.primary,
                          fontWeight: FontWeight.w700,
                        ),
                      ),
                    ),
                    const SizedBox(width: 12),
                    GestureDetector(
                      onTap: _busy ? null : _toggleLike,
                      child: Row(
                        mainAxisSize: MainAxisSize.min,
                        children: [
                          Icon(
                            _likedByMe
                                ? Icons.favorite_rounded
                                : Icons.favorite_border_rounded,
                            size: 14,
                            color: _likedByMe
                                ? Colors.redAccent
                                : scheme.onSurfaceVariant,
                          ),
                          if (_likeCount > 0) ...[
                            const SizedBox(width: 4),
                            Text(
                              compactCount(_likeCount),
                              style: theme.textTheme.bodySmall?.copyWith(
                                color: scheme.onSurfaceVariant,
                              ),
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

class _SheetAssetCarousel extends StatefulWidget {
  const _SheetAssetCarousel({required this.assets});
  final List<ContentAssetItem> assets;

  @override
  State<_SheetAssetCarousel> createState() => _SheetAssetCarouselState();
}

class _SheetAssetCarouselState extends State<_SheetAssetCarousel> {
  final _ctrl = PageController();
  int _page = 0;

  @override
  void dispose() {
    _ctrl.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return Column(
      children: [
        ClipRRect(
          borderRadius: BorderRadius.circular(20),
          child: SizedBox(
            height: 300,
            child: PageView.builder(
              controller: _ctrl,
              itemCount: widget.assets.length,
              onPageChanged: (v) => setState(() => _page = v),
              itemBuilder: (context, i) {
                final a = widget.assets[i];
                if (a.isImage) {
                  return Image.network(
                    resolveMediaUrl(a.url),
                    fit: BoxFit.cover,
                  );
                }
                return const DecoratedBox(
                  decoration: BoxDecoration(color: Colors.black87),
                  child: Center(
                    child: Icon(
                      Icons.play_circle_outline_rounded,
                      color: Colors.white,
                      size: 56,
                    ),
                  ),
                );
              },
            ),
          ),
        ),
        if (widget.assets.length > 1) ...[
          const SizedBox(height: 10),
          Row(
            mainAxisAlignment: MainAxisAlignment.center,
            children: List.generate(widget.assets.length, (i) {
              final active = i == _page;
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
        ],
      ],
    );
  }
}

// ── Empty state ───────────────────────────────────────────────────────────────

class _PostsEmptyState extends StatelessWidget {
  const _PostsEmptyState({required this.icon, required this.message});

  final IconData icon;
  final String message;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return Container(
      width: double.infinity,
      padding: const EdgeInsets.fromLTRB(20, 30, 20, 32),
      decoration: BoxDecoration(
        color: scheme.surfaceContainerLowest,
        borderRadius: BorderRadius.circular(22),
      ),
      child: Column(
        children: [
          Icon(icon, size: 34, color: scheme.onSurfaceVariant),
          const SizedBox(height: 14),
          Text(
            message,
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

class _ExpandableBody extends StatefulWidget {
  const _ExpandableBody({required this.text, required this.style});

  final String text;
  final TextStyle? style;

  @override
  State<_ExpandableBody> createState() => _ExpandableBodyState();
}

class _ExpandableBodyState extends State<_ExpandableBody> {
  bool _expanded = false;

  bool _overflows(BoxConstraints constraints) {
    final style = widget.style ?? const TextStyle();
    final painter = TextPainter(
      text: TextSpan(text: widget.text, style: style),
      maxLines: 3,
      textDirection: TextDirection.ltr,
    )..layout(maxWidth: constraints.maxWidth);
    return painter.didExceedMaxLines;
  }

  @override
  Widget build(BuildContext context) {
    final style = widget.style;
    return LayoutBuilder(
      builder: (context, constraints) {
        final overflows = _overflows(constraints);
        return Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(
              widget.text,
              style: style,
              maxLines: _expanded ? null : 3,
              overflow: _expanded
                  ? TextOverflow.visible
                  : TextOverflow.ellipsis,
            ),
            if (overflows || _expanded) ...[
              const SizedBox(height: 4),
              GestureDetector(
                onTap: () => setState(() => _expanded = !_expanded),
                child: Text(
                  _expanded ? 'See less' : 'See more',
                  style: (style ?? Theme.of(context).textTheme.bodyMedium)
                      ?.copyWith(
                        color: Theme.of(context).colorScheme.primary,
                        fontWeight: FontWeight.w600,
                      ),
                ),
              ),
            ],
          ],
        );
      },
    );
  }
}

sealed class _CoverAction {}

final class _CoverPickAction extends _CoverAction {
  _CoverPickAction({required this.slot, required this.replacing});
  final int slot;
  final bool replacing;
}

final class _CoverRemoveAction extends _CoverAction {
  _CoverRemoveAction(this.slot);
  final int slot;
}
