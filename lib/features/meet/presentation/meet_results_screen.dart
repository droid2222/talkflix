import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../../../core/auth/session_controller.dart';
import '../../../core/config/privacy_settings_controller.dart';
import '../../../core/network/api_client.dart';
import '../../../core/widgets/app_avatar.dart';
import '../../upgrade/presentation/pro_access_sheet.dart';
import 'meet_filters_controller.dart';
import 'meet_user_filter.dart';
import 'meet_user_privacy.dart';

final meetResultsProvider = FutureProvider<List<Map<String, dynamic>>>((
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
  final query = <String, String>{'limit': '80', 'offset': '0'};

  if (!isProLike && learningLanguage.isNotEmpty) {
    query['lang'] = learningLanguage;
  } else if (filters.selectedNativeLanguage != 'Any') {
    query['lang'] = filters.selectedNativeLanguage;
  }
  if (isProLike && filters.selectedLearningLanguage != 'Any') {
    query['learn'] = filters.selectedLearningLanguage;
  }
  query['minAge'] = filters.minAge.toString();
  query['maxAge'] = filters.maxAge.toString();
  if (filters.newUsersOnly) {
    query['newUsers'] = 'true';
  }
  if (isProLike && filters.useProSearch && filters.selectedCountry != 'Any') {
    query['country'] = filters.selectedCountry;
  }
  if (isProLike && filters.useProSearch && filters.selectedCity != 'Any') {
    query['city'] = filters.selectedCity;
  }
  if (isProLike && filters.useProSearch && filters.selectedGender != 'all') {
    query['gender'] = filters.selectedGender;
  }
  if (isProLike &&
      (filters.discoveryMode == MeetDiscoveryMode.nearby ||
          (filters.useProSearch && filters.prioritizeNearby))) {
    query['nearby'] = 'true';
  }

  final data = await ref
      .read(apiClientProvider)
      .getJson('/meet/users', queryParameters: query);

  return discoverableMeetUsers(data['users']);
});

class MeetResultsScreen extends ConsumerWidget {
  const MeetResultsScreen({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final theme = Theme.of(context);
    final session = ref.watch(sessionControllerProvider);
    final privacySettings = ref.watch(privacySettingsControllerProvider);
    final currentUserId = session.user?.id ?? '';
    final results = ref.watch(meetResultsProvider);

    return Scaffold(
      body: SafeArea(
        child: Column(
          children: [
            Align(
              alignment: Alignment.centerLeft,
              child: IconButton(
                onPressed: () => Navigator.of(context).pop(),
                icon: const Icon(Icons.arrow_back_ios_new_rounded),
              ),
            ),
            Expanded(
              child: results.when(
                data: (items) {
                  if (items.isEmpty) {
                    return Center(
                      child: Padding(
                        padding: const EdgeInsets.all(24),
                        child: Text(
                          'No users match this search yet.',
                          style: theme.textTheme.titleMedium,
                          textAlign: TextAlign.center,
                        ),
                      ),
                    );
                  }

                  return ListView.separated(
                    padding: const EdgeInsets.fromLTRB(16, 0, 16, 16),
                    itemCount: items.length,
                    separatorBuilder: (_, _) =>
                        Divider(height: 1, color: theme.dividerColor),
                    itemBuilder: (context, index) {
                      final user = items[index];
                      final isProLike =
                          user['plan']?.toString() == 'pro' ||
                          user['plan']?.toString() == 'trial' ||
                          user['role']?.toString() == 'admin';
                      final displayName =
                          user['displayName']?.toString() ?? 'User';
                      final ageLabel = visibleMeetAgeLabel(
                        user: user,
                        currentUserId: currentUserId,
                        privacy: privacySettings,
                      );
                      final showFlag = shouldShowMeetFlag(
                        user: user,
                        currentUserId: currentUserId,
                        privacy: privacySettings,
                      );
                      final flagCode = _flagCode(
                        user['nationalityCode']?.toString() ??
                            user['countryCode']?.toString() ??
                            '',
                      );
                      final location = [
                        if ((user['city']?.toString() ?? '').isNotEmpty)
                          user['city'].toString(),
                        if ((user['country']?.toString() ?? '').isNotEmpty)
                          user['country'].toString(),
                      ].join(', ');
                      final languageLine =
                          "${user['firstLanguage'] ?? 'Any'} -> ${user['learnLanguage'] ?? 'Any'}${ageLabel.isNotEmpty ? ' • $ageLabel' : ''}";

                      return InkWell(
                        onTap: () => context.push('/app/profile/${user['id']}'),
                        child: SizedBox(
                          height: 82,
                          child: Row(
                            children: [
                              AppAvatar(
                                label: displayName,
                                imageUrl: user['profilePhotoUrl']?.toString(),
                                radius: 22,
                              ),
                              const SizedBox(width: 12),
                              Expanded(
                                child: Column(
                                  mainAxisAlignment: MainAxisAlignment.center,
                                  crossAxisAlignment: CrossAxisAlignment.start,
                                  children: [
                                    Row(
                                      children: [
                                        Flexible(
                                          child: Text(
                                            displayName,
                                            maxLines: 1,
                                            overflow: TextOverflow.ellipsis,
                                            style: theme.textTheme.titleMedium
                                                ?.copyWith(
                                                  fontWeight: FontWeight.w800,
                                                ),
                                          ),
                                        ),
                                        if (showFlag &&
                                            flagCode.isNotEmpty) ...[
                                          const SizedBox(width: 4),
                                          _FlagBadge(code: flagCode),
                                        ],
                                        if (isProLike) ...[
                                          const SizedBox(width: 6),
                                          const ProFeatureBadge(compact: true),
                                        ],
                                      ],
                                    ),
                                    const SizedBox(height: 4),
                                    Text(
                                      location,
                                      maxLines: 1,
                                      overflow: TextOverflow.ellipsis,
                                      style: theme.textTheme.bodyMedium
                                          ?.copyWith(
                                            color: theme
                                                .colorScheme
                                                .onSurfaceVariant,
                                          ),
                                    ),
                                    const SizedBox(height: 4),
                                    Text(
                                      languageLine,
                                      maxLines: 1,
                                      overflow: TextOverflow.ellipsis,
                                      style: theme.textTheme.bodySmall,
                                    ),
                                  ],
                                ),
                              ),
                            ],
                          ),
                        ),
                      );
                    },
                  );
                },
                error: (error, _) => Center(
                  child: Padding(
                    padding: const EdgeInsets.all(24),
                    child: Text(error.toString(), textAlign: TextAlign.center),
                  ),
                ),
                loading: () => const Center(child: CircularProgressIndicator()),
              ),
            ),
          ],
        ),
      ),
    );
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
              fontSize: 7,
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
