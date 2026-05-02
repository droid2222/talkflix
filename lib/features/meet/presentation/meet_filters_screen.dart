import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../../../app/theme/app_theme.dart';
import '../../../core/auth/session_controller.dart';
import '../../../core/network/api_client.dart';
import '../../auth/data/signup_options.dart';
import '../../upgrade/presentation/pro_access_sheet.dart';
import 'meet_filters_controller.dart';

final meetCitiesProvider =
    FutureProvider.family<List<String>, String>((ref, country) async {
      if (country.isEmpty || country == 'Any') {
        return const ['Any'];
      }

      final data = await ref.read(apiClientProvider).getJson(
        '/meta/cities',
        queryParameters: {'country': country},
      );

      final cities = (data['cities'] as List<dynamic>? ?? const [])
          .map((item) => item.toString())
          .where((item) => item.trim().isNotEmpty)
          .toList();

      return ['Any', ...cities];
    });

class MeetFiltersScreen extends ConsumerStatefulWidget {
  const MeetFiltersScreen({super.key});

  @override
  ConsumerState<MeetFiltersScreen> createState() => _MeetFiltersScreenState();
}

class _MeetFiltersScreenState extends ConsumerState<MeetFiltersScreen> {
  late String _selectedNativeLanguage;
  late String _selectedLearningLanguage;
  late String _selectedCountry;
  late String _selectedCity;
  RangeValues _ageRange = const RangeValues(18, 90);
  bool _newUsers = false;
  bool _prioritizeNearby = false;
  String _gender = 'all';

  List<String> get _languageOptions => ['Any', ...languageOptions];

  @override
  void initState() {
    super.initState();
    final filters = ref.read(meetFiltersProvider);
    _selectedNativeLanguage = filters.selectedNativeLanguage;
    _selectedLearningLanguage = filters.selectedLearningLanguage;
    _selectedCountry = filters.selectedCountry;
    _selectedCity = filters.selectedCity;
    _ageRange = RangeValues(filters.minAge.toDouble(), filters.maxAge.toDouble());
    _newUsers = filters.newUsersOnly;
    _prioritizeNearby = filters.prioritizeNearby;
    _gender = filters.selectedGender;
  }

  Future<void> _pickValue({
    required String title,
    required List<String> options,
    required String currentValue,
    required ValueChanged<String> onSelected,
    String searchHint = 'Search...',
  }) async {
    final result = await showModalBottomSheet<String>(
      context: context,
      isScrollControlled: true,
      backgroundColor: Theme.of(context).colorScheme.surface,
      shape: const RoundedRectangleBorder(
        borderRadius: BorderRadius.vertical(top: Radius.circular(28)),
      ),
      builder: (context) => _SearchPickerSheet(
        title: title,
        options: options,
        currentValue: currentValue,
        searchHint: searchHint,
      ),
    );

    if (result != null && mounted) {
      onSelected(result);
    }
  }

  Future<void> _pickCity() async {
    if (_selectedCountry == 'Any') {
      await _pickValue(
        title: 'City of language partner',
        options: const ['Any'],
        currentValue: _selectedCity,
        searchHint: 'Search city',
        onSelected: (value) => setState(() => _selectedCity = value),
      );
      return;
    }

    final cities = await ref.read(meetCitiesProvider(_selectedCountry).future);
    if (!mounted) return;

    await _pickValue(
      title: 'City of language partner',
      options: cities,
      currentValue: _selectedCity,
      searchHint: 'Search city',
      onSelected: (value) => setState(() => _selectedCity = value),
    );
  }

  void _reset(MeetFiltersController controller) {
    controller.reset();
    setState(() {
      _selectedNativeLanguage = 'Any';
      _selectedLearningLanguage = 'Any';
      _selectedCountry = 'Any';
      _selectedCity = 'Any';
      _ageRange = const RangeValues(18, 90);
      _newUsers = false;
      _prioritizeNearby = false;
      _gender = 'all';
    });
  }

  void _apply(MeetFiltersController controller, bool isProLike) {
    controller.selectNativeLanguage(_selectedNativeLanguage);
    controller.selectLearningLanguage(_selectedLearningLanguage);
    controller.selectCountry(_selectedCountry);
    controller.selectCity(_selectedCity);
    controller.selectGender(_gender);
    controller.selectAgeRange(_ageRange);
    controller.setNewUsers(_newUsers);
    controller.setPrioritizeNearby(_prioritizeNearby);
    controller.setUseProSearch(
      isProLike &&
          (_selectedCountry != 'Any' ||
              _selectedCity != 'Any' ||
              _prioritizeNearby ||
              _gender != 'all'),
    );
    context.push('/app/meet/results');
  }

  Future<void> _showProGate() async {
    await showProAccessSheet(
      context: context,
      ref: ref,
      featureName: 'Pro Search',
    );
  }

  @override
  Widget build(BuildContext context) {
    final controller = ref.read(meetFiltersProvider.notifier);
    final session = ref.watch(sessionControllerProvider);
    final theme = Theme.of(context);
    const accent = talkflixPrimary;
    final isProLike = session.user?.isProLike == true;
    final countryNames = ['Any', ...countryOptions.map((item) => item['label']!)];
    final sliderTheme = SliderTheme.of(context).copyWith(
      activeTrackColor: accent,
      inactiveTrackColor: accent.withValues(alpha: 0.18),
      thumbColor: Colors.white,
      overlayColor: accent.withValues(alpha: 0.18),
      rangeTrackShape: const RoundedRectRangeSliderTrackShape(),
      trackHeight: 5,
    );

    return Scaffold(
      appBar: AppBar(
        leading: IconButton(
          onPressed: () => Navigator.of(context).pop(),
          icon: const Icon(Icons.close_rounded, size: 28),
        ),
        title: Text(
          'Search',
          style: theme.textTheme.titleLarge?.copyWith(
            fontWeight: FontWeight.w900,
            fontSize: 20,
          ),
        ),
        centerTitle: true,
        actions: [
          TextButton(
            onPressed: () => _reset(controller),
            child: const Text('Reset'),
          ),
        ],
      ),
      body: SafeArea(
        top: false,
        child: Stack(
          children: [
            ListView(
              padding: const EdgeInsets.fromLTRB(16, 8, 16, 92),
              children: [
                _FilterCard(
                  child: _SelectionRow(
                    label: "Language partner's native language",
                    value: _selectedNativeLanguage,
                    accent: accent,
                    compact: true,
                    onTap: () => _pickValue(
                      title: "Language partner's native language",
                      options: _languageOptions,
                      currentValue: _selectedNativeLanguage,
                      searchHint: 'Search language',
                      onSelected: (value) =>
                          setState(() => _selectedNativeLanguage = value),
                    ),
                  ),
                ),
                const SizedBox(height: 12),
                _FilterCard(
                  child: _SelectionRow(
                    label: "Language partner's learning language",
                    value: _selectedLearningLanguage,
                    accent: accent,
                    compact: true,
                    onTap: () => _pickValue(
                      title: "Language partner's learning language",
                      options: _languageOptions,
                      currentValue: _selectedLearningLanguage,
                      searchHint: 'Search language',
                      onSelected: (value) =>
                          setState(() => _selectedLearningLanguage = value),
                    ),
                  ),
                ),
                const SizedBox(height: 12),
                _FilterCard(
                  child: Column(
                    children: [
                      Row(
                        children: [
                          Text(
                            'Age',
                            style: theme.textTheme.titleMedium?.copyWith(
                              fontWeight: FontWeight.w700,
                              fontSize: 16,
                            ),
                          ),
                          const Spacer(),
                          Text(
                            '${_ageRange.start.round()}-${_ageRange.end.round()}+',
                            style: theme.textTheme.titleMedium?.copyWith(
                              color: accent,
                              fontWeight: FontWeight.w700,
                              fontSize: 15,
                            ),
                          ),
                        ],
                      ),
                      const SizedBox(height: 6),
                      SliderTheme(
                        data: sliderTheme,
                        child: RangeSlider(
                          values: _ageRange,
                          min: 18,
                          max: 90,
                          divisions: 18,
                          onChanged: (value) => setState(() => _ageRange = value),
                        ),
                      ),
                    ],
                  ),
                ),
                const SizedBox(height: 12),
                _FilterCard(
                  child: _CompactToggleRow(
                    label: 'New Users',
                    value: _newUsers,
                    onChanged: (value) => setState(() => _newUsers = value),
                  ),
                ),
                const SizedBox(height: 12),
                Row(
                  children: [
                    Text(
                      'Pro Search',
                      style: theme.textTheme.titleLarge?.copyWith(
                        fontWeight: FontWeight.w900,
                        fontSize: 18,
                      ),
                    ),
                    const SizedBox(width: 10),
                    const ProFeatureBadge(compact: true),
                  ],
                ),
                const SizedBox(height: 12),
                Opacity(
                  opacity: isProLike ? 1 : 0.52,
                  child: GestureDetector(
                    behavior: HitTestBehavior.opaque,
                    onTap: isProLike ? null : _showProGate,
                    child: AbsorbPointer(
                      absorbing: !isProLike,
                      child: _FilterCard(
                        child: Column(
                          children: [
                            _CompactToggleRow(
                              label: 'Prioritize people nearby',
                              value: _prioritizeNearby,
                              onChanged: (value) =>
                                  setState(() => _prioritizeNearby = value),
                            ),
                            const SizedBox(height: 10),
                            _GenderSegmentRow(
                              value: _gender,
                              accent: accent,
                              onChanged: (value) => setState(() => _gender = value),
                            ),
                            const SizedBox(height: 10),
                            _SelectionRow(
                              label: 'Region of language partner',
                              value: _selectedCountry,
                              accent: accent,
                              compact: true,
                              onTap: () => _pickValue(
                                title: 'Region of language partner',
                                options: countryNames,
                                currentValue: _selectedCountry,
                                searchHint: 'Search country',
                                onSelected: (value) => setState(() {
                                  _selectedCountry = value;
                                  _selectedCity = 'Any';
                                }),
                              ),
                            ),
                            const SizedBox(height: 10),
                            _SelectionRow(
                              label: 'City of language partner',
                              value: _selectedCity,
                              accent: accent,
                              compact: true,
                              onTap: _pickCity,
                            ),
                          ],
                        ),
                      ),
                    ),
                  ),
                ),
              ],
            ),
            Positioned(
              left: 16,
              right: 16,
              bottom: 16,
              child: SizedBox(
                width: double.infinity,
                child: FilledButton(
                  onPressed: () => _apply(controller, isProLike),
                  style: FilledButton.styleFrom(
                    backgroundColor: accent,
                    foregroundColor: Colors.white,
                    minimumSize: const Size.fromHeight(56),
                    shape: RoundedRectangleBorder(
                      borderRadius: BorderRadius.circular(999),
                    ),
                    textStyle: const TextStyle(
                      fontSize: 18,
                      fontWeight: FontWeight.w800,
                    ),
                  ),
                  child: const Text('Search'),
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }
}

class _FilterCard extends StatelessWidget {
  const _FilterCard({required this.child});

  final Widget child;

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 14),
      decoration: BoxDecoration(
        color: Theme.of(context).colorScheme.surface,
        borderRadius: BorderRadius.circular(24),
      ),
      child: child,
    );
  }
}

class _SelectionRow extends StatelessWidget {
  const _SelectionRow({
    required this.label,
    required this.value,
    required this.accent,
    required this.onTap,
    this.compact = false,
  });

  final String label;
  final String value;
  final Color accent;
  final bool compact;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return InkWell(
      borderRadius: BorderRadius.circular(18),
      onTap: onTap,
      child: Row(
        children: [
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  label,
                  style: theme.textTheme.bodyMedium?.copyWith(
                    color: theme.colorScheme.onSurfaceVariant,
                    fontSize: compact ? 12.5 : 14,
                  ),
                ),
                SizedBox(height: compact ? 4 : 8),
                Text(
                  value,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: theme.textTheme.titleLarge?.copyWith(
                    fontWeight: FontWeight.w800,
                    fontSize: compact ? 16 : 18,
                  ),
                ),
                if (!compact) ...[
                  const SizedBox(height: 8),
                  Container(
                    width: 42,
                    height: 5,
                    decoration: BoxDecoration(
                      color: accent,
                      borderRadius: BorderRadius.circular(999),
                    ),
                  ),
                ],
              ],
            ),
          ),
          const SizedBox(width: 10),
          Icon(
            Icons.chevron_right_rounded,
            size: compact ? 26 : 30,
          ),
        ],
      ),
    );
  }
}

class _CompactToggleRow extends StatelessWidget {
  const _CompactToggleRow({
    required this.label,
    required this.value,
    required this.onChanged,
  });

  final String label;
  final bool value;
  final ValueChanged<bool> onChanged;

  @override
  Widget build(BuildContext context) {
    return Row(
      children: [
        Expanded(
          child: Text(
            label,
            style: Theme.of(context).textTheme.titleMedium?.copyWith(
              fontWeight: FontWeight.w700,
              fontSize: 16,
            ),
          ),
        ),
        Switch(
          value: value,
          activeTrackColor: const Color(0xFF64B5FF),
          activeThumbColor: Colors.white,
          onChanged: onChanged,
        ),
      ],
    );
  }
}

class _GenderSegmentRow extends StatelessWidget {
  const _GenderSegmentRow({
    required this.value,
    required this.accent,
    required this.onChanged,
  });

  final String value;
  final Color accent;
  final ValueChanged<String> onChanged;

  @override
  Widget build(BuildContext context) {
    Widget segment(String label, String key) {
      final selected = value == key;
      return Expanded(
        child: GestureDetector(
          onTap: () => onChanged(key),
          child: Container(
            padding: const EdgeInsets.symmetric(vertical: 12),
            decoration: BoxDecoration(
              color: selected ? accent : Colors.transparent,
              borderRadius: BorderRadius.circular(999),
            ),
            child: Text(
              label,
              textAlign: TextAlign.center,
              style: TextStyle(
                color: selected
                    ? Colors.white
                    : Theme.of(context).colorScheme.onSurfaceVariant,
                fontWeight: FontWeight.w800,
                fontSize: 15,
              ),
            ),
          ),
        ),
      );
    }

    return Container(
      padding: const EdgeInsets.all(4),
      decoration: BoxDecoration(
        color: Theme.of(context).scaffoldBackgroundColor,
        borderRadius: BorderRadius.circular(999),
      ),
      child: Row(
        children: [
          segment('All', 'all'),
          segment('Female', 'female'),
          segment('Male', 'male'),
        ],
      ),
    );
  }
}

class _SearchPickerSheet extends StatefulWidget {
  const _SearchPickerSheet({
    required this.title,
    required this.options,
    required this.currentValue,
    required this.searchHint,
  });

  final String title;
  final List<String> options;
  final String currentValue;
  final String searchHint;

  @override
  State<_SearchPickerSheet> createState() => _SearchPickerSheetState();
}

class _SearchPickerSheetState extends State<_SearchPickerSheet> {
  late final TextEditingController _searchController;
  String _query = '';

  @override
  void initState() {
    super.initState();
    _searchController = TextEditingController();
  }

  @override
  void dispose() {
    _searchController.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final filtered = widget.options.where((option) {
      if (_query.trim().isEmpty) return true;
      return option.toLowerCase().contains(_query.trim().toLowerCase());
    }).toList();

    return SafeArea(
      child: Padding(
        padding: const EdgeInsets.fromLTRB(20, 18, 20, 24),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Text(
              widget.title,
              style: Theme.of(context).textTheme.titleLarge?.copyWith(
                fontWeight: FontWeight.w900,
              ),
            ),
            const SizedBox(height: 14),
            TextField(
              controller: _searchController,
              onChanged: (value) => setState(() => _query = value),
              decoration: InputDecoration(
                hintText: widget.searchHint,
                prefixIcon: const Icon(Icons.search_rounded),
              ),
            ),
            const SizedBox(height: 14),
            Flexible(
              child: ListView.builder(
                shrinkWrap: true,
                itemCount: filtered.length,
                itemBuilder: (context, index) {
                  final option = filtered[index];
                  return ListTile(
                    contentPadding: EdgeInsets.zero,
                    title: Text(option),
                    trailing: option == widget.currentValue
                        ? const Icon(Icons.check_rounded)
                        : null,
                    onTap: () => Navigator.of(context).pop(option),
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
