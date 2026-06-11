import 'dart:math' as math;

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../../../app/theme/app_theme.dart';
import '../../../core/auth/session_controller.dart';
import '../../../core/config/talkflix_icons.dart';
import '../../../core/media/media_utils.dart';
import '../../../core/network/api_client.dart';
import '../../auth/data/auth_repository.dart';
import '../../auth/data/signup_options.dart';
import '../../upgrade/presentation/pro_access_sheet.dart';
import 'meet_filters_controller.dart';
import 'meet_user_filter.dart';

final meetFeedLanguageProvider = StateProvider<String>((ref) => 'Any');

final meetUsersProvider = FutureProvider<List<Map<String, dynamic>>>((
  ref,
) async {
  final userId = ref.watch(sessionControllerProvider.select((s) => s.user?.id));
  if (userId == null || userId.isEmpty) {
    return const <Map<String, dynamic>>[];
  }
  final user = ref.watch(sessionControllerProvider.select((s) => s.user));
  final isProLike = user?.isProLike == true;
  final learningLanguage = (user?.learnLanguage ?? '').trim();
  final filters = ref.watch(meetFiltersProvider);
  final selectedLanguage = ref.watch(meetFeedLanguageProvider);
  final query = <String, String>{'limit': '40', 'offset': '0'};

  if (!isProLike && learningLanguage.isNotEmpty) {
    query['lang'] = learningLanguage;
  } else if (selectedLanguage != 'Any') {
    query['lang'] = selectedLanguage;
  }
  if (isProLike && filters.discoveryMode == MeetDiscoveryMode.nearby) {
    query['nearby'] = 'true';
  }

  final data = await ref
      .read(apiClientProvider)
      .getJson('/meet/users', queryParameters: query);

  return discoverableMeetUsers(data['users']);
});

class MeetScreen extends ConsumerStatefulWidget {
  const MeetScreen({super.key});

  @override
  ConsumerState<MeetScreen> createState() => _MeetScreenState();
}

class _MeetScreenState extends ConsumerState<MeetScreen> {
  Future<void> _handleMatchProTap() async {
    final me = ref.read(sessionControllerProvider).user;
    if (me == null) return;

    if (me.isProLike) {
      if (!mounted) return;
      context.go('/app/meet/anon');
      return;
    }

    await showProAccessSheet(
      context: context,
      ref: ref,
      featureName: 'Partner Pro',
      onUnlocked: () {
        if (!mounted) return;
        context.go('/app/meet/anon');
      },
    );
  }

  Future<void> _refreshUsers() async {
    final future = ref.refresh(meetUsersProvider.future);
    await future;
  }

  Future<void> _addLanguage() async {
    final session = ref.read(sessionControllerProvider);
    final me = session.user;
    if (me == null) return;

    if (!me.isProLike) {
      await showProAccessSheet(
        context: context,
        ref: ref,
        featureName: 'More languages',
      );
      return;
    }

    final options = [...languageOptions]
      ..sort((a, b) => a.toLowerCase().compareTo(b.toLowerCase()));
    final selected = await showModalBottomSheet<String>(
      context: context,
      isScrollControlled: true,
      backgroundColor: Theme.of(context).colorScheme.surface,
      shape: const RoundedRectangleBorder(
        borderRadius: BorderRadius.vertical(top: Radius.circular(28)),
      ),
      builder: (context) => _LanguagePickerSheet(options: options),
    );

    if (selected == null || !mounted) return;

    final controller = ref.read(meetFiltersProvider.notifier);
    controller.addAvailableLanguage(selected);

    final updatedLanguages = <String>{
      ...?session.user?.meetLanguages,
      selected,
    }.toList()..sort((a, b) => a.toLowerCase().compareTo(b.toLowerCase()));

    final updatedUser = await ref
        .read(authRepositoryProvider)
        .saveMeetLanguages(updatedLanguages);
    final sessionState = ref.read(sessionControllerProvider);
    final token = sessionState.token;
    final sessionId = sessionState.sessionId;
    if (token != null && sessionId != null && mounted) {
      await ref
          .read(sessionControllerProvider.notifier)
          .setAuthenticated(
            token: token,
            sessionId: sessionId,
            user: updatedUser,
          );
    }
    ref.read(meetFeedLanguageProvider.notifier).state = selected;
  }

  Future<void> _setDiscoveryMode(MeetDiscoveryMode mode) async {
    final me = ref.read(sessionControllerProvider).user;
    if (mode == MeetDiscoveryMode.nearby && me?.isProLike != true) {
      await showProAccessSheet(
        context: context,
        ref: ref,
        featureName: 'Nearby Partners',
      );
      return;
    }
    ref.read(meetFiltersProvider.notifier).setDiscoveryMode(mode);
    ref.invalidate(meetUsersProvider);
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;
    final session = ref.watch(sessionControllerProvider);
    final filters = ref.watch(meetFiltersProvider);
    final users = ref.watch(meetUsersProvider);
    final langOptions = filters.availableLanguages;
    final isProLike = session.user?.isProLike == true;
    final learningLanguage = (session.user?.learnLanguage ?? '').trim();
    final selectedFeedLanguage = isProLike
        ? ref.watch(meetFeedLanguageProvider)
        : learningLanguage;
    final matchSummary = session.user?.isProLike == true
        ? 'Match unlocked'
        : 'Match locked';

    return Scaffold(
      backgroundColor: scheme.surface,
      body: SafeArea(
        child: LayoutBuilder(
          builder: (context, constraints) {
            final contentWidth = math.min(constraints.maxWidth, 1280.0);
            final useGrid = contentWidth >= 760;
            final columnCount = contentWidth >= 1140 ? 3 : 2;
            final gridGap = contentWidth >= 1140 ? 18.0 : 16.0;
            final cardWidth = useGrid
                ? (contentWidth -
                          (useGrid ? 48 : 32) -
                          (gridGap * (columnCount - 1))) /
                      columnCount
                : contentWidth;

            return Align(
              alignment: Alignment.topCenter,
              child: SizedBox(
                width: contentWidth,
                child: RefreshIndicator(
                  onRefresh: _refreshUsers,
                  child: ListView(
                    padding: EdgeInsets.fromLTRB(
                      useGrid ? 24 : 16,
                      18,
                      useGrid ? 24 : 16,
                      28,
                    ),
                    children: [
                      Row(
                        children: [
                          Expanded(
                            child: Text(
                              'Find Partners',
                              style: theme.textTheme.headlineSmall?.copyWith(
                                fontWeight: FontWeight.w900,
                              ),
                            ),
                          ),
                          _HeaderIconButton(
                            icon: Icons.tune_rounded,
                            onTap: () => context.go('/app/meet/filters'),
                          ),
                        ],
                      ),
                      const SizedBox(height: 14),
                      _AnonymousChatCta(
                        subtitle: matchSummary,
                        onTap: _handleMatchProTap,
                      ),
                      const SizedBox(height: 12),
                      _MeetModeSwitch(
                        selected: filters.discoveryMode,
                        proUnlocked: isProLike,
                        onSelected: _setDiscoveryMode,
                      ),
                      const SizedBox(height: 16),
                      Container(
                        padding: const EdgeInsets.fromLTRB(12, 10, 12, 10),
                        decoration: BoxDecoration(
                          color: scheme.surfaceContainerLowest,
                          borderRadius: BorderRadius.circular(18),
                        ),
                        child: SingleChildScrollView(
                          scrollDirection: Axis.horizontal,
                          child: Row(
                            children: [
                              for (final language in langOptions)
                                Padding(
                                  padding: const EdgeInsets.only(right: 10),
                                  child: _LanguagePill(
                                    label: language,
                                    selected: selectedFeedLanguage == language,
                                    locked:
                                        !isProLike &&
                                        language != learningLanguage,
                                    onTap: !isProLike
                                        ? null
                                        : () {
                                            ref
                                                    .read(
                                                      meetFeedLanguageProvider
                                                          .notifier,
                                                    )
                                                    .state =
                                                language;
                                            ref.invalidate(meetUsersProvider);
                                          },
                                  ),
                                ),
                              _LanguagePill(
                                label: '+ Add',
                                selected: false,
                                locked: !isProLike,
                                onTap: _addLanguage,
                              ),
                            ],
                          ),
                        ),
                      ),
                      const SizedBox(height: 20),
                      users.when(
                        data: (items) {
                          if (items.isEmpty) {
                            return _EmptyMeetState(
                              onFiltersTap: () =>
                                  context.go('/app/meet/filters'),
                            );
                          }

                          return Wrap(
                            spacing: gridGap,
                            runSpacing: gridGap,
                            children: items
                                .map(
                                  (user) => SizedBox(
                                    width: useGrid
                                        ? cardWidth
                                        : double.infinity,
                                    child: _MeetUserCard(
                                      user: user,
                                      onProfile: () => context.go(
                                        '/app/profile/${user['id']}',
                                      ),
                                      onMessage: () =>
                                          context.go('/app/talk/${user['id']}'),
                                    ),
                                  ),
                                )
                                .toList(),
                          );
                        },
                        error: (error, _) => _InlineMessage(
                          text: error.toString(),
                          background: const Color(0x19E50914),
                          foreground: talkflixPrimary,
                        ),
                        loading: () => const Padding(
                          padding: EdgeInsets.only(top: 48),
                          child: Center(child: CircularProgressIndicator()),
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
    );
  }
}

class _AnonymousChatCta extends StatelessWidget {
  const _AnonymousChatCta({required this.subtitle, required this.onTap});

  final String subtitle;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Material(
      color: Colors.transparent,
      child: InkWell(
        borderRadius: BorderRadius.circular(22),
        onTap: onTap,
        child: Ink(
          padding: const EdgeInsets.fromLTRB(14, 14, 14, 14),
          decoration: BoxDecoration(
            borderRadius: BorderRadius.circular(22),
            gradient: const LinearGradient(
              begin: Alignment.topLeft,
              end: Alignment.bottomRight,
              colors: [
                Color(0xFF7C3AED),
                Color(0xFFE50914),
                Color(0xFFFF8A00),
                Color(0xFF00B8D9),
              ],
              stops: [0.0, 0.42, 0.72, 1.0],
            ),
            boxShadow: [
              BoxShadow(
                color: const Color(0xFFE50914).withValues(alpha: 0.26),
                blurRadius: 24,
                spreadRadius: 1,
                offset: const Offset(0, 12),
              ),
              BoxShadow(
                color: const Color(0xFF7C3AED).withValues(alpha: 0.18),
                blurRadius: 34,
                spreadRadius: 2,
              ),
            ],
          ),
          child: Stack(
            children: [
              Positioned(
                left: -28,
                top: -34,
                child: Container(
                  width: 110,
                  height: 110,
                  decoration: BoxDecoration(
                    shape: BoxShape.circle,
                    color: Colors.white.withValues(alpha: 0.12),
                  ),
                ),
              ),
              Positioned(
                right: 42,
                bottom: -52,
                child: Container(
                  width: 132,
                  height: 132,
                  decoration: BoxDecoration(
                    shape: BoxShape.circle,
                    color: Colors.white.withValues(alpha: 0.08),
                  ),
                ),
              ),
              Row(
                children: [
                  Container(
                    width: 44,
                    height: 44,
                    decoration: BoxDecoration(
                      color: Colors.white.withValues(alpha: 0.18),
                      shape: BoxShape.circle,
                      border: Border.all(
                        color: Colors.white.withValues(alpha: 0.24),
                      ),
                    ),
                    child: const Icon(TalkflixIcons.talks, color: Colors.white),
                  ),
                  const SizedBox(width: 12),
                  Expanded(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Text(
                          'Start anonymous chat',
                          style: theme.textTheme.titleMedium?.copyWith(
                            color: Colors.white,
                            fontWeight: FontWeight.w900,
                          ),
                        ),
                        const SizedBox(height: 2),
                        Text(
                          subtitle,
                          style: const TextStyle(
                            color: Color(0xFFFFF4F7),
                            fontWeight: FontWeight.w700,
                          ),
                        ),
                      ],
                    ),
                  ),
                  const SizedBox(width: 10),
                  Container(
                    width: 34,
                    height: 34,
                    decoration: BoxDecoration(
                      color: Colors.white.withValues(alpha: 0.17),
                      shape: BoxShape.circle,
                    ),
                    child: const Icon(
                      Icons.arrow_forward_ios_rounded,
                      color: Colors.white,
                      size: 16,
                    ),
                  ),
                ],
              ),
            ],
          ),
        ),
      ),
    );
  }
}

class _HeaderIconButton extends StatelessWidget {
  const _HeaderIconButton({required this.icon, required this.onTap});

  final IconData icon;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Material(
      color: theme.colorScheme.surfaceContainerLowest,
      borderRadius: BorderRadius.circular(18),
      child: InkWell(
        borderRadius: BorderRadius.circular(18),
        onTap: onTap,
        child: SizedBox(
          width: 52,
          height: 52,
          child: Icon(icon, color: theme.colorScheme.onSurface),
        ),
      ),
    );
  }
}

class _LanguagePill extends StatelessWidget {
  const _LanguagePill({
    required this.label,
    required this.selected,
    required this.onTap,
    this.locked = false,
  });

  final String label;
  final bool selected;
  final VoidCallback? onTap;
  final bool locked;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Material(
      color: Colors.transparent,
      child: InkWell(
        borderRadius: BorderRadius.circular(24),
        onTap: onTap,
        child: Container(
          constraints: const BoxConstraints(minWidth: 104),
          padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 13),
          decoration: BoxDecoration(
            color: selected
                ? const Color(0x26E50914)
                : theme.colorScheme.surfaceContainerHigh,
            borderRadius: BorderRadius.circular(24),
            border: Border.all(
              color: selected ? talkflixPrimary : Colors.transparent,
            ),
          ),
          child: Row(
            mainAxisSize: MainAxisSize.min,
            mainAxisAlignment: MainAxisAlignment.center,
            children: [
              if (locked) ...[
                Icon(
                  Icons.lock_rounded,
                  size: 14,
                  color: theme.colorScheme.onSurfaceVariant,
                ),
                const SizedBox(width: 6),
              ],
              Flexible(
                child: Text(
                  label,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  textAlign: TextAlign.center,
                  style: TextStyle(
                    color: selected
                        ? talkflixPrimary
                        : theme.colorScheme.onSurfaceVariant,
                    fontWeight: FontWeight.w800,
                    fontSize: 14,
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

class _MeetModeSwitch extends StatelessWidget {
  const _MeetModeSwitch({
    required this.selected,
    required this.proUnlocked,
    required this.onSelected,
  });

  final MeetDiscoveryMode selected;
  final bool proUnlocked;
  final ValueChanged<MeetDiscoveryMode> onSelected;

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.all(5),
      decoration: BoxDecoration(
        color: Theme.of(context).colorScheme.surfaceContainerHigh,
        borderRadius: BorderRadius.circular(999),
      ),
      child: Row(
        children: [
          _MeetModeSegment(
            label: 'Random',
            icon: Icons.shuffle_rounded,
            selected: selected == MeetDiscoveryMode.random,
            locked: false,
            onTap: () => onSelected(MeetDiscoveryMode.random),
          ),
          _MeetModeSegment(
            label: 'Nearby',
            icon: Icons.near_me_rounded,
            selected: selected == MeetDiscoveryMode.nearby,
            locked: !proUnlocked,
            onTap: () => onSelected(MeetDiscoveryMode.nearby),
          ),
        ],
      ),
    );
  }
}

class _MeetModeSegment extends StatelessWidget {
  const _MeetModeSegment({
    required this.label,
    required this.icon,
    required this.selected,
    required this.locked,
    required this.onTap,
  });

  final String label;
  final IconData icon;
  final bool selected;
  final bool locked;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final foreground = selected
        ? Colors.white
        : theme.colorScheme.onSurfaceVariant;
    return Expanded(
      child: InkWell(
        borderRadius: BorderRadius.circular(999),
        onTap: onTap,
        child: AnimatedContainer(
          duration: const Duration(milliseconds: 180),
          padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 11),
          decoration: BoxDecoration(
            borderRadius: BorderRadius.circular(999),
            gradient: selected
                ? const LinearGradient(
                    colors: [Color(0xFFE50914), Color(0xFFFF8A00)],
                  )
                : null,
          ),
          child: Row(
            mainAxisAlignment: MainAxisAlignment.center,
            children: [
              Icon(
                locked ? Icons.lock_rounded : icon,
                size: 17,
                color: foreground,
              ),
              const SizedBox(width: 7),
              Flexible(
                child: Text(
                  label,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: theme.textTheme.labelLarge?.copyWith(
                    color: foreground,
                    fontWeight: FontWeight.w900,
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

class _MeetUserCard extends StatelessWidget {
  const _MeetUserCard({
    required this.user,
    required this.onProfile,
    required this.onMessage,
  });

  final Map<String, dynamic> user;
  final VoidCallback onProfile;
  final VoidCallback onMessage;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;
    final displayName = user['displayName']?.toString() ?? 'User';
    final profilePhotoUrl = user['profilePhotoUrl']?.toString().trim() ?? '';
    final firstLanguage = user['firstLanguage']?.toString() ?? '';
    final learnLanguage = user['learnLanguage']?.toString() ?? '';
    final location = _locationLabel();
    final isProLike =
        user['plan']?.toString() == 'pro' ||
        user['plan']?.toString() == 'trial' ||
        user['role']?.toString() == 'admin';
    final bio = _buildBio();

    return Material(
      color: scheme.surfaceContainerLowest,
      borderRadius: BorderRadius.circular(22),
      clipBehavior: Clip.antiAlias,
      child: InkWell(
        borderRadius: BorderRadius.circular(22),
        onTap: onProfile,
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Stack(
              children: [
                AspectRatio(
                  aspectRatio: 16 / 9,
                  child: profilePhotoUrl.isNotEmpty
                      ? Image.network(
                          resolveMediaUrl(profilePhotoUrl),
                          fit: BoxFit.cover,
                          errorBuilder: (context, error, stackTrace) =>
                              _MeetCardPhotoFallback(label: displayName),
                        )
                      : _MeetCardPhotoFallback(label: displayName),
                ),
                Positioned.fill(
                  child: DecoratedBox(
                    decoration: BoxDecoration(
                      gradient: LinearGradient(
                        begin: Alignment.topCenter,
                        end: Alignment.bottomCenter,
                        colors: [
                          Colors.transparent,
                          Colors.black.withValues(alpha: 0.58),
                        ],
                        stops: const [0.48, 1],
                      ),
                    ),
                  ),
                ),
                Positioned(
                  left: 14,
                  right: 14,
                  bottom: 12,
                  child: Row(
                    crossAxisAlignment: CrossAxisAlignment.end,
                    children: [
                      Expanded(
                        child: Text(
                          displayName,
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                          style: theme.textTheme.titleLarge?.copyWith(
                            color: Colors.white,
                            fontWeight: FontWeight.w900,
                            shadows: [
                              Shadow(
                                color: Colors.black.withValues(alpha: 0.45),
                                blurRadius: 10,
                              ),
                            ],
                          ),
                        ),
                      ),
                      if (isProLike) ...[
                        const SizedBox(width: 8),
                        const ProFeatureBadge(compact: true),
                      ],
                    ],
                  ),
                ),
              ],
            ),
            Padding(
              padding: const EdgeInsets.fromLTRB(14, 14, 14, 14),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Wrap(
                    spacing: 8,
                    runSpacing: 8,
                    children: [
                      if (firstLanguage.isNotEmpty)
                        _MeetInfoChip(
                          icon: Icons.language_rounded,
                          label: 'Speaks $firstLanguage',
                          color: talkflixPrimary,
                        ),
                      if (learnLanguage.isNotEmpty)
                        _MeetInfoChip(
                          icon: Icons.school_rounded,
                          label: 'Learning $learnLanguage',
                          color: const Color(0xFF8B5CF6),
                        ),
                      if (location.isNotEmpty)
                        _MeetInfoChip(
                          icon: Icons.place_rounded,
                          label: location,
                          color: const Color(0xFF0EA5E9),
                        ),
                    ],
                  ),
                  if (bio.isNotEmpty) ...[
                    const SizedBox(height: 12),
                    Text(
                      bio,
                      maxLines: 2,
                      overflow: TextOverflow.ellipsis,
                      style: theme.textTheme.bodyMedium?.copyWith(
                        height: 1.32,
                        color: scheme.onSurfaceVariant,
                      ),
                    ),
                  ],
                  const SizedBox(height: 14),
                  Row(
                    children: [
                      Expanded(
                        child: _MeetActionButton(
                          label: 'Profile',
                          icon: Icons.person_rounded,
                          onTap: onProfile,
                        ),
                      ),
                      const SizedBox(width: 10),
                      Expanded(
                        child: _MeetActionButton(
                          label: 'Message',
                          icon: Icons.chat_bubble_rounded,
                          filled: true,
                          onTap: onMessage,
                        ),
                      ),
                    ],
                  ),
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }

  String _locationLabel() {
    final city = user['city']?.toString().trim() ?? '';
    final country = user['country']?.toString().trim() ?? '';
    if (city.isNotEmpty && country.isNotEmpty) return '$city, $country';
    if (city.isNotEmpty) return city;
    return country;
  }

  String _buildBio() {
    final customBio = user['bioText']?.toString().trim() ?? '';
    if (customBio.isNotEmpty) {
      return customBio;
    }
    return user['bio']?.toString().trim() ?? '';
  }
}

class _MeetInfoChip extends StatelessWidget {
  const _MeetInfoChip({
    required this.icon,
    required this.label,
    required this.color,
  });

  final IconData icon;
  final String label;
  final Color color;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 7),
      decoration: BoxDecoration(
        color: color.withValues(alpha: 0.11),
        borderRadius: BorderRadius.circular(999),
        border: Border.all(color: color.withValues(alpha: 0.18)),
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          Icon(icon, size: 14, color: color),
          const SizedBox(width: 6),
          Flexible(
            child: Text(
              label,
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: theme.textTheme.labelMedium?.copyWith(
                color: theme.colorScheme.onSurface,
                fontWeight: FontWeight.w800,
              ),
            ),
          ),
        ],
      ),
    );
  }
}

class _MeetActionButton extends StatelessWidget {
  const _MeetActionButton({
    required this.label,
    required this.icon,
    required this.onTap,
    this.filled = false,
  });

  final String label;
  final IconData icon;
  final VoidCallback onTap;
  final bool filled;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final foreground = filled ? Colors.white : theme.colorScheme.onSurface;
    return Material(
      color: Colors.transparent,
      child: InkWell(
        borderRadius: BorderRadius.circular(16),
        onTap: onTap,
        child: Ink(
          height: 46,
          decoration: BoxDecoration(
            color: filled ? null : theme.colorScheme.surfaceContainerHigh,
            gradient: filled
                ? const LinearGradient(
                    colors: [Color(0xFFE50914), Color(0xFFFF8A00)],
                  )
                : null,
            borderRadius: BorderRadius.circular(16),
          ),
          child: Row(
            mainAxisAlignment: MainAxisAlignment.center,
            crossAxisAlignment: CrossAxisAlignment.center,
            children: [
              Icon(icon, size: 18, color: foreground),
              const SizedBox(width: 8),
              Flexible(
                child: Text(
                  label,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: theme.textTheme.labelLarge?.copyWith(
                    color: foreground,
                    fontWeight: FontWeight.w900,
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

class _MeetCardPhotoFallback extends StatelessWidget {
  const _MeetCardPhotoFallback({required this.label});

  final String label;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final initials = label.trim().isEmpty
        ? 'U'
        : label
              .trim()
              .split(RegExp(r'\s+'))
              .take(2)
              .map((part) => part.isEmpty ? '' : part[0].toUpperCase())
              .join();
    return DecoratedBox(
      decoration: BoxDecoration(
        color: scheme.surfaceContainerHigh,
        gradient: const LinearGradient(
          colors: [Color(0xFFD61F2C), talkflixPrimary],
          begin: Alignment.topLeft,
          end: Alignment.bottomRight,
        ),
      ),
      child: Center(
        child: Text(
          initials,
          style: Theme.of(context).textTheme.headlineSmall?.copyWith(
            color: Colors.white,
            fontWeight: FontWeight.w900,
          ),
        ),
      ),
    );
  }
}

class _LanguagePickerSheet extends StatefulWidget {
  const _LanguagePickerSheet({required this.options});

  final List<String> options;

  @override
  State<_LanguagePickerSheet> createState() => _LanguagePickerSheetState();
}

class _LanguagePickerSheetState extends State<_LanguagePickerSheet> {
  String _query = '';

  @override
  Widget build(BuildContext context) {
    final filtered = widget.options
        .where((item) => item.toLowerCase().contains(_query.toLowerCase()))
        .toList();

    return SafeArea(
      child: Padding(
        padding: EdgeInsets.only(
          left: 20,
          right: 20,
          top: 18,
          bottom: MediaQuery.of(context).viewInsets.bottom + 20,
        ),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Text(
              'Add language',
              style: Theme.of(
                context,
              ).textTheme.titleLarge?.copyWith(fontWeight: FontWeight.w900),
            ),
            const SizedBox(height: 14),
            TextField(
              onChanged: (value) => setState(() => _query = value),
              decoration: InputDecoration(
                hintText: 'Search language',
                prefixIcon: const Icon(Icons.search_rounded),
                filled: true,
                fillColor: Theme.of(context).colorScheme.surface,
                border: OutlineInputBorder(
                  borderRadius: BorderRadius.circular(18),
                  borderSide: BorderSide.none,
                ),
              ),
            ),
            const SizedBox(height: 14),
            SizedBox(
              height: 360,
              child: ListView.separated(
                itemCount: filtered.length,
                separatorBuilder: (_, _) =>
                    Divider(color: Theme.of(context).dividerColor, height: 1),
                itemBuilder: (context, index) {
                  final language = filtered[index];
                  return ListTile(
                    title: Text(language),
                    onTap: () => Navigator.of(context).pop(language),
                  );
                },
              ),
            ),
          ],
        ),
      ),
    );
  }
}

class _EmptyMeetState extends StatelessWidget {
  const _EmptyMeetState({required this.onFiltersTap});

  final VoidCallback onFiltersTap;

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.all(24),
      decoration: BoxDecoration(
        color: Theme.of(context).colorScheme.surface,
        borderRadius: BorderRadius.circular(28),
      ),
      child: Column(
        children: [
          Text(
            'No partners found for this search yet.',
            style: Theme.of(
              context,
            ).textTheme.titleMedium?.copyWith(fontWeight: FontWeight.w800),
            textAlign: TextAlign.center,
          ),
          const SizedBox(height: 8),
          Text(
            'Try another language or adjust your filters.',
            style: Theme.of(context).textTheme.bodyMedium,
            textAlign: TextAlign.center,
          ),
          const SizedBox(height: 18),
          OutlinedButton(
            onPressed: onFiltersTap,
            child: const Text('Open filters'),
          ),
        ],
      ),
    );
  }
}

class _InlineMessage extends StatelessWidget {
  const _InlineMessage({
    required this.text,
    required this.background,
    required this.foreground,
  });

  final String text;
  final Color background;
  final Color foreground;

  @override
  Widget build(BuildContext context) {
    return Container(
      width: double.infinity,
      padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 12),
      decoration: BoxDecoration(
        color: background,
        borderRadius: BorderRadius.circular(14),
      ),
      child: Text(text, style: TextStyle(color: foreground)),
    );
  }
}
