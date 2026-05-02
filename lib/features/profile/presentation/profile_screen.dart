import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../../../app/theme/app_theme.dart';
import '../../../core/auth/app_user.dart';
import '../../../core/auth/session_controller.dart';
import '../../../core/media/audio_message_player.dart';
import '../../../core/network/api_client.dart';
import '../../../core/widgets/app_avatar.dart';

final profileProvider = FutureProvider.family<AppUser, String?>((
  ref,
  userId,
) async {
  final sessionUserId = ref.watch(
    sessionControllerProvider.select((s) => s.user?.id),
  );
  if (sessionUserId == null || sessionUserId.isEmpty) {
    throw Exception('No active session');
  }
  if (userId == null || userId.isEmpty) {
    final currentUser = ref.watch(sessionControllerProvider).user;
    if (currentUser == null) {
      throw Exception('No current user');
    }
    return currentUser;
  }

  final data = await ref.read(apiClientProvider).getJson('/users/$userId');
  return AppUser.fromJson(data['user'] as Map<String, dynamic>? ?? {});
});

class ProfileScreen extends ConsumerStatefulWidget {
  const ProfileScreen({super.key, this.userId});

  final String? userId;

  @override
  ConsumerState<ProfileScreen> createState() => _ProfileScreenState();
}

class _ProfileScreenState extends ConsumerState<ProfileScreen> {
  bool _updatingFollow = false;
  bool? _followOverride;
  int? _followersCountOverride;

  @override
  void didUpdateWidget(covariant ProfileScreen oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.userId != widget.userId) {
      _followOverride = null;
      _followersCountOverride = null;
      _updatingFollow = false;
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
      ref.invalidate(profileProvider(widget.userId));
    } finally {
      if (mounted) {
        setState(() => _updatingFollow = false);
      }
    }
  }

  Future<void> _refresh() async {
    ref.invalidate(profileProvider(widget.userId));
    if (widget.userId == null || widget.userId!.isEmpty) {
      await ref.read(sessionControllerProvider.notifier).refreshProfile();
    }
    await ref.read(profileProvider(widget.userId).future);
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;
    final me = ref.watch(sessionControllerProvider).user;
    final profile = ref.watch(profileProvider(widget.userId));

    return Scaffold(
      backgroundColor: scheme.surface,
      body: SafeArea(
        child: profile.when(
          data: (user) {
            final isOwnProfile =
                me?.id == user.id ||
                widget.userId == null ||
                widget.userId!.isEmpty;
            final viewingProfileRoute =
                widget.userId != null && widget.userId!.isNotEmpty;
            final isFollowing = _followOverride ?? user.isFollowing;
            final followersCount =
                _followersCountOverride ?? user.followersCount;
            final location = [
              if (user.city.isNotEmpty) user.city,
              if (user.country.isNotEmpty) user.country,
            ].join(', ');
            final profileFacts = <String>[
              if (location.isNotEmpty) location,
              if (user.firstLanguage.isNotEmpty ||
                  user.learnLanguage.isNotEmpty)
                'Speaks ${user.firstLanguage.isEmpty ? 'Any' : user.firstLanguage} · Learns ${user.learnLanguage.isEmpty ? 'Any' : user.learnLanguage}',
              if (user.meetLanguages.isNotEmpty)
                'Open to ${user.meetLanguages.join(', ')}',
            ];
            final bioText = user.bioText.trim();
            final hasVoiceBio =
                user.bioAudioUrl.trim().isNotEmpty && user.bioAudioDuration > 0;

            return RefreshIndicator(
              onRefresh: _refresh,
              child: CustomScrollView(
                physics: const AlwaysScrollableScrollPhysics(),
                slivers: [
                  SliverToBoxAdapter(
                    child: Padding(
                      padding: const EdgeInsets.fromLTRB(18, 8, 18, 0),
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Row(
                            children: [
                              if (viewingProfileRoute)
                                IconButton(
                                  onPressed: () {
                                    if (Navigator.of(context).canPop()) {
                                      Navigator.of(context).pop();
                                    } else {
                                      context.go('/app/profile');
                                    }
                                  },
                                  icon: const Icon(
                                    Icons.arrow_back_ios_new_rounded,
                                  ),
                                )
                              else
                                const SizedBox(width: 48),
                              Expanded(
                                child: Text(
                                  user.username,
                                  textAlign: TextAlign.center,
                                  style: theme.textTheme.titleLarge?.copyWith(
                                    fontWeight: FontWeight.w800,
                                  ),
                                ),
                              ),
                              SizedBox(
                                width: 48,
                                child: isOwnProfile
                                    ? IconButton(
                                        onPressed: () => context.push(
                                          '/app/profile/settings',
                                        ),
                                        icon: const Icon(Icons.menu_rounded),
                                      )
                                    : const SizedBox.shrink(),
                              ),
                            ],
                          ),
                          const SizedBox(height: 18),
                          Row(
                            crossAxisAlignment: CrossAxisAlignment.center,
                            children: [
                              AppAvatar(
                                label: user.displayName,
                                imageUrl: user.profilePhotoUrl,
                                radius: 42,
                              ),
                              const SizedBox(width: 24),
                              Expanded(
                                child: Row(
                                  mainAxisAlignment:
                                      MainAxisAlignment.spaceBetween,
                                  children: [
                                    _ProfileStat(
                                      label: 'posts',
                                      value: user.postsCount.toString(),
                                    ),
                                    _ProfileStat(
                                      label: 'followers',
                                      value: followersCount.toString(),
                                      onTap: () => context.push(
                                        '/app/profile/${user.id}/list/followers?name=${Uri.encodeComponent(user.displayName)}',
                                      ),
                                    ),
                                    _ProfileStat(
                                      label: 'following',
                                      value: user.followingCount.toString(),
                                      onTap: () => context.push(
                                        '/app/profile/${user.id}/list/following?name=${Uri.encodeComponent(user.displayName)}',
                                      ),
                                    ),
                                  ],
                                ),
                              ),
                            ],
                          ),
                          const SizedBox(height: 16),
                          Text(
                            user.displayName,
                            style: theme.textTheme.titleMedium?.copyWith(
                              fontWeight: FontWeight.w800,
                            ),
                          ),
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
                          if (profileFacts.isEmpty &&
                              bioText.isEmpty &&
                              !hasVoiceBio)
                            Text(
                              'Talkflix profile',
                              style: theme.textTheme.bodyMedium?.copyWith(
                                color: scheme.onSurfaceVariant,
                              ),
                            )
                          else
                            ...profileFacts.map(
                              (line) => Padding(
                                padding: const EdgeInsets.only(bottom: 3),
                                child: Text(
                                  line,
                                  style: theme.textTheme.bodyMedium?.copyWith(
                                    height: 1.25,
                                  ),
                                ),
                              ),
                            ),
                          const SizedBox(height: 14),
                          Row(
                            children: [
                              Expanded(
                                child: _ProfileActionButton(
                                  label: isOwnProfile
                                      ? (user.isProLike
                                            ? 'Talkflix Pro'
                                            : 'Talkflix Free')
                                      : _updatingFollow
                                      ? 'Updating...'
                                      : isFollowing
                                      ? 'Following'
                                      : 'Follow',
                                  filled: !isOwnProfile && !isFollowing,
                                  onTap: isOwnProfile || _updatingFollow
                                      ? null
                                      : () => _toggleFollow(user),
                                ),
                              ),
                              const SizedBox(width: 8),
                              Expanded(
                                child: _ProfileActionButton(
                                  label: isOwnProfile ? 'Settings' : 'Message',
                                  onTap: () => isOwnProfile
                                      ? context.push('/app/profile/settings')
                                      : context.push('/app/talk/${user.id}'),
                                ),
                              ),
                            ],
                          ),
                          const SizedBox(height: 16),
                          Wrap(
                            spacing: 8,
                            runSpacing: 8,
                            children: [
                              if (user.firstLanguage.isNotEmpty)
                                _ProfileMetaPill(label: user.firstLanguage),
                              if (user.learnLanguage.isNotEmpty)
                                _ProfileMetaPill(
                                  label: 'Learning ${user.learnLanguage}',
                                ),
                              _ProfileMetaPill(
                                label: user.isProLike
                                    ? 'Pro member'
                                    : 'Free member',
                              ),
                              if (user.nationalityName.isNotEmpty)
                                _ProfileMetaPill(label: user.nationalityName),
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
                  ),
                  SliverPadding(
                    padding: const EdgeInsets.fromLTRB(18, 0, 18, 28),
                    sliver: SliverToBoxAdapter(
                      child: _PostsPlaceholder(
                        isOwnProfile: isOwnProfile,
                        postsCount: user.postsCount,
                      ),
                    ),
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
                    onPressed: () =>
                        ref.invalidate(profileProvider(widget.userId)),
                    child: const Text('Retry'),
                  ),
                ],
              ),
            ),
          ),
        ),
      ),
    );
  }
}

class _ProfileStat extends StatelessWidget {
  const _ProfileStat({required this.label, required this.value, this.onTap});

  final String label;
  final String value;
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
        Text(
          label,
          style: Theme.of(context).textTheme.bodySmall?.copyWith(
            color: Theme.of(context).colorScheme.onSurfaceVariant,
          ),
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
    this.onTap,
  });

  final String label;
  final bool filled;
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
          alignment: Alignment.center,
          child: Text(
            label,
            style: Theme.of(context).textTheme.labelLarge?.copyWith(
              fontWeight: FontWeight.w700,
              color: filled ? Colors.white : scheme.onSurface,
            ),
          ),
        ),
      ),
    );
  }
}

class _ProfileMetaPill extends StatelessWidget {
  const _ProfileMetaPill({required this.label});

  final String label;

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 7),
      decoration: BoxDecoration(
        color: Theme.of(context).colorScheme.surfaceContainerHighest,
        borderRadius: BorderRadius.circular(999),
      ),
      child: Text(
        label,
        style: Theme.of(
          context,
        ).textTheme.labelMedium?.copyWith(fontWeight: FontWeight.w700),
      ),
    );
  }
}

class _PostsPlaceholder extends StatelessWidget {
  const _PostsPlaceholder({
    required this.isOwnProfile,
    required this.postsCount,
  });

  final bool isOwnProfile;
  final int postsCount;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;
    final hasPosts = postsCount > 0;

    return Container(
      width: double.infinity,
      padding: const EdgeInsets.fromLTRB(20, 30, 20, 32),
      decoration: BoxDecoration(
        color: scheme.surfaceContainerLowest,
        borderRadius: BorderRadius.circular(22),
      ),
      child: Column(
        children: [
          Container(
            width: 72,
            height: 72,
            decoration: BoxDecoration(
              shape: BoxShape.circle,
              border: Border.all(color: scheme.outlineVariant),
            ),
            child: Icon(
              hasPosts ? Icons.grid_view_rounded : Icons.photo_library_outlined,
              size: 28,
              color: scheme.onSurface,
            ),
          ),
          const SizedBox(height: 16),
          Text(
            hasPosts ? '$postsCount posts' : 'No posts yet',
            style: theme.textTheme.titleMedium?.copyWith(
              fontWeight: FontWeight.w800,
            ),
          ),
          const SizedBox(height: 8),
          Text(
            isOwnProfile
                ? 'Your future posts will show up here in an Instagram-style grid.'
                : 'This user has not shared any posts yet.',
            textAlign: TextAlign.center,
            style: theme.textTheme.bodyMedium?.copyWith(
              color: scheme.onSurfaceVariant,
            ),
          ),
        ],
      ),
    );
  }
}
