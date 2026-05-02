import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../../../app/theme/app_theme.dart';
import '../../../core/auth/session_controller.dart';
import '../../../core/network/api_client.dart';
import '../../../core/widgets/app_avatar.dart';
import '../../auth/data/auth_repository.dart';
import '../../auth/data/signup_options.dart';
import '../../upgrade/presentation/pro_access_sheet.dart';
import 'meet_filters_controller.dart';

final meetFeedLanguageProvider = StateProvider<String>((ref) => 'Any');

final meetUsersProvider = FutureProvider<List<Map<String, dynamic>>>((
  ref,
) async {
  final userId = ref.watch(sessionControllerProvider.select((s) => s.user?.id));
  if (userId == null || userId.isEmpty) {
    return const <Map<String, dynamic>>[];
  }
  final selectedLanguage = ref.watch(meetFeedLanguageProvider);
  final query = <String, String>{'limit': '40', 'offset': '0'};

  if (selectedLanguage != 'Any') {
    query['lang'] = selectedLanguage;
  }

  final data = await ref
      .read(apiClientProvider)
      .getJson('/meet/users', queryParameters: query);

  return (data['users'] as List<dynamic>? ?? const [])
      .whereType<Map<String, dynamic>>()
      .toList();
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
    final token = ref.read(sessionControllerProvider).token;
    if (token != null && mounted) {
      await ref
          .read(sessionControllerProvider.notifier)
          .setAuthenticated(token: token, user: updatedUser);
    }
    ref.read(meetFeedLanguageProvider.notifier).state = selected;
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;
    final session = ref.watch(sessionControllerProvider);
    final filters = ref.watch(meetFiltersProvider);
    final users = ref.watch(meetUsersProvider);
    final langOptions = filters.availableLanguages;
    final selectedFeedLanguage = ref.watch(meetFeedLanguageProvider);
    final matchSummary = session.user?.isProLike == true
        ? 'Match unlocked'
        : session.user?.trialUsed == false
        ? 'Free trial available'
        : 'Match locked';

    return Scaffold(
      backgroundColor: scheme.surface,
      body: SafeArea(
        child: RefreshIndicator(
          onRefresh: _refreshUsers,
          child: ListView(
            padding: const EdgeInsets.fromLTRB(16, 12, 16, 24),
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
              const SizedBox(height: 12),
              _AnonymousChatCta(
                subtitle: matchSummary,
                onTap: _handleMatchProTap,
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
                            onTap: () =>
                                ref.read(meetFeedLanguageProvider.notifier).state =
                                    language,
                          ),
                        ),
                      _LanguagePill(
                        label: '+ Add',
                        selected: false,
                        onTap: _addLanguage,
                      ),
                    ],
                  ),
                ),
              ),
              const SizedBox(height: 18),
              users.when(
                data: (items) {
                  if (items.isEmpty) {
                    return _EmptyMeetState(
                      onFiltersTap: () => context.go('/app/meet/filters'),
                    );
                  }

                  return Column(
                    children: items
                        .map(
                          (user) => Padding(
                            padding: const EdgeInsets.only(bottom: 12),
                            child: _MeetUserCard(
                              user: user,
                              onChat: () => context.go('/app/talk/${user['id']}'),
                              onProfile: () =>
                                  context.go('/app/profile/${user['id']}'),
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
              colors: [Color(0xFFB0000B), Color(0xFFE50914)],
            ),
            boxShadow: [
              BoxShadow(
                color: talkflixPrimary.withValues(alpha: 0.28),
                blurRadius: 16,
                offset: const Offset(0, 8),
              ),
            ],
          ),
          child: Row(
            children: [
              Container(
                width: 44,
                height: 44,
                decoration: BoxDecoration(
                  color: Colors.white.withValues(alpha: 0.14),
                  shape: BoxShape.circle,
                ),
                child: const Icon(Icons.forum_rounded, color: Colors.white),
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
                      color: Color(0xFFFFE6E8),
                      fontWeight: FontWeight.w600,
                    ),
                  ),
                  ],
                ),
              ),
              const SizedBox(width: 10),
              const Icon(
                Icons.arrow_forward_ios_rounded,
                color: Colors.white,
                size: 18,
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
  });

  final String label;
  final bool selected;
  final VoidCallback onTap;

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
      ),
    );
  }
}

class _MeetUserCard extends StatelessWidget {
  const _MeetUserCard({
    required this.user,
    required this.onChat,
    required this.onProfile,
  });

  final Map<String, dynamic> user;
  final VoidCallback onChat;
  final VoidCallback onProfile;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final displayName = user['displayName']?.toString() ?? 'User';
    final city = user['city']?.toString() ?? '';
    final country = user['country']?.toString() ?? '';
    final firstLanguage = user['firstLanguage']?.toString() ?? '';
    final learnLanguage = user['learnLanguage']?.toString() ?? '';
    final isProLike =
        user['plan']?.toString() == 'pro' ||
        user['plan']?.toString() == 'trial' ||
        user['role']?.toString() == 'admin';
    final flagCode = _flagCode(
      user['nationalityCode']?.toString() ??
          user['countryCode']?.toString() ??
          '',
    );

    final chips = <String>[
      if (firstLanguage.isNotEmpty) firstLanguage,
      if (learnLanguage.isNotEmpty && learnLanguage != firstLanguage)
        learnLanguage,
      if (country.isNotEmpty) country,
    ].take(2).toList();

    return Container(
      padding: const EdgeInsets.all(12),
      decoration: BoxDecoration(
        color: theme.colorScheme.surfaceContainerLowest,
        borderRadius: BorderRadius.circular(18),
      ),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          GestureDetector(
            onTap: onProfile,
            child: SizedBox(
              width: 64,
              child: AppAvatar(
                label: displayName,
                imageUrl: user['profilePhotoUrl']?.toString(),
                radius: 24,
              ),
            ),
          ),
          const SizedBox(width: 12),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Row(
                  children: [
                    Flexible(
                      child: GestureDetector(
                        onTap: onProfile,
                        child: Text(
                          displayName,
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                          style: theme.textTheme.headlineSmall?.copyWith(
                            fontWeight: FontWeight.w900,
                            fontSize: 19,
                          ),
                        ),
                      ),
                    ),
                    if (flagCode.isNotEmpty)
                      Padding(
                        padding: const EdgeInsets.only(left: 4),
                        child: _FlagBadge(code: flagCode),
                      ),
                    if (isProLike)
                      const Padding(
                        padding: EdgeInsets.only(left: 6),
                        child: ProFeatureBadge(compact: true),
                      ),
                  ],
                ),
                const SizedBox(height: 6),
                Row(
                  children: [
                    _LanguageMeter(
                      code: firstLanguage.isEmpty
                          ? '--'
                          : firstLanguage
                                .substring(
                                  0,
                                  firstLanguage.length < 2
                                      ? firstLanguage.length
                                      : 2,
                                )
                                .toUpperCase(),
                      activeColor: talkflixPrimary,
                    ),
                    const Padding(
                      padding: EdgeInsets.symmetric(horizontal: 10),
                      child: Icon(
                        Icons.swap_horiz_rounded,
                        color: Color(0xFF6F6F73),
                      ),
                    ),
                    _LanguageMeter(
                      code: learnLanguage.isEmpty
                          ? '--'
                          : learnLanguage
                                .substring(
                                  0,
                                  learnLanguage.length < 2
                                      ? learnLanguage.length
                                      : 2,
                                )
                                .toUpperCase(),
                      activeColor: const Color(0xFF8B5CF6),
                    ),
                  ],
                ),
                const SizedBox(height: 10),
                Text(
                  [
                    if (city.isNotEmpty) city,
                    if (country.isNotEmpty) country,
                  ].join(', '),
                  style: theme.textTheme.titleMedium?.copyWith(
                    color: theme.colorScheme.onSurfaceVariant,
                  ),
                ),
                const SizedBox(height: 8),
                Text(
                  _buildBio(
                    firstLanguage: firstLanguage,
                    learnLanguage: learnLanguage,
                  ),
                  maxLines: 2,
                  overflow: TextOverflow.ellipsis,
                  style: theme.textTheme.bodyMedium?.copyWith(height: 1.28),
                ),
                const SizedBox(height: 10),
                Wrap(
                  spacing: 8,
                  runSpacing: 8,
                  children: chips
                      .map(
                        (chip) => Container(
                          padding: const EdgeInsets.symmetric(
                            horizontal: 12,
                            vertical: 8,
                          ),
                          decoration: BoxDecoration(
                            color: theme.colorScheme.surface,
                            borderRadius: BorderRadius.circular(18),
                          ),
                          child: Text(
                            chip,
                            style: theme.textTheme.bodyMedium?.copyWith(
                              color: theme.colorScheme.onSurfaceVariant,
                            ),
                          ),
                        ),
                      )
                      .toList(),
                ),
              ],
            ),
          ),
          const SizedBox(width: 12),
          Padding(
            padding: const EdgeInsets.only(top: 4),
            child: GestureDetector(
              onTap: onChat,
              child: Container(
                width: 58,
                height: 58,
                decoration: BoxDecoration(
                  borderRadius: BorderRadius.circular(20),
                  gradient: const LinearGradient(
                    colors: [Color(0xFFC00110), talkflixPrimary],
                  ),
                ),
                child: const Icon(
                  Icons.waving_hand_rounded,
                  color: Colors.white,
                  size: 26,
                ),
              ),
            ),
          ),
        ],
      ),
    );
  }

  String _buildBio({
    required String firstLanguage,
    required String learnLanguage,
  }) {
    if (firstLanguage.isEmpty && learnLanguage.isEmpty) {
      return 'Open to meeting new people and starting a conversation.';
    }
    if (firstLanguage.isEmpty) {
      return 'Currently focused on learning $learnLanguage and meeting language partners.';
    }
    if (learnLanguage.isEmpty) {
      return 'Native in $firstLanguage and open to meeting people worldwide.';
    }
    return 'Native $firstLanguage speaker learning $learnLanguage and open to meaningful conversations.';
  }
}

class _FlagBadge extends StatelessWidget {
  const _FlagBadge({required this.code});

  final String code;

  @override
  Widget build(BuildContext context) {
    return Container(
      width: 26,
      height: 18,
      clipBehavior: Clip.hardEdge,
      decoration: const BoxDecoration(),
      child: Image.network(
        'https://flagcdn.com/w40/${code.toLowerCase()}.png',
        fit: BoxFit.cover,
        errorBuilder: (context, error, stackTrace) => Container(
          color: Theme.of(context).colorScheme.surface,
          alignment: Alignment.center,
          child: Text(
            code,
            style: const TextStyle(
              fontSize: 8,
              fontWeight: FontWeight.w800,
              height: 1,
            ),
          ),
        ),
      ),
    );
  }
}

String _flagCode(String code) {
  final normalized = code.trim().toUpperCase();
  if (normalized.length != 2) return '';
  final first = normalized.codeUnitAt(0);
  final second = normalized.codeUnitAt(1);
  if (first < 0x41 || first > 0x5A || second < 0x41 || second > 0x5A) {
    return '';
  }
  return normalized;
}

class _LanguageMeter extends StatelessWidget {
  const _LanguageMeter({required this.code, required this.activeColor});

  final String code;
  final Color activeColor;

  @override
  Widget build(BuildContext context) {
    return Text(
      code,
      style: Theme.of(context).textTheme.titleMedium?.copyWith(
        fontWeight: FontWeight.w900,
        color: activeColor,
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
