import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../../../core/auth/session_controller.dart';
import '../../../core/widgets/feature_scaffold.dart';
import 'qa_checklist_data.dart';

class QaChecklistScreen extends ConsumerStatefulWidget {
  const QaChecklistScreen({super.key});

  @override
  ConsumerState<QaChecklistScreen> createState() => _QaChecklistScreenState();
}

class _QaChecklistScreenState extends ConsumerState<QaChecklistScreen> {
  final Map<String, bool> _completed = <String, bool>{};
  bool _loading = true;

  @override
  void initState() {
    super.initState();
    Future<void>.microtask(_loadChecklist);
  }

  Future<void> _loadChecklist() async {
    final prefs = await ref.read(sharedPreferencesProvider.future);
    final next = <String, bool>{};
    for (
      var sectionIndex = 0;
      sectionIndex < qaSections.length;
      sectionIndex++
    ) {
      final section = qaSections[sectionIndex];
      for (var itemIndex = 0; itemIndex < section.items.length; itemIndex++) {
        final key = qaChecklistItemKey(sectionIndex, itemIndex);
        next[key] = prefs.getBool(key) ?? false;
      }
    }
    if (!mounted) return;
    setState(() {
      _completed
        ..clear()
        ..addAll(next);
      _loading = false;
    });
  }

  Future<void> _toggleItem(
    int sectionIndex,
    int itemIndex,
    bool selected,
  ) async {
    final key = qaChecklistItemKey(sectionIndex, itemIndex);
    final prefs = await ref.read(sharedPreferencesProvider.future);
    await prefs.setBool(key, selected);
    if (!mounted) return;
    setState(() => _completed[key] = selected);
    ref.invalidate(qaChecklistProgressProvider);
  }

  Future<void> _resetChecklist() async {
    final prefs = await ref.read(sharedPreferencesProvider.future);
    for (
      var sectionIndex = 0;
      sectionIndex < qaSections.length;
      sectionIndex++
    ) {
      final section = qaSections[sectionIndex];
      for (var itemIndex = 0; itemIndex < section.items.length; itemIndex++) {
        await prefs.remove(qaChecklistItemKey(sectionIndex, itemIndex));
      }
    }
    if (!mounted) return;
    setState(() {
      for (final key in _completed.keys) {
        _completed[key] = false;
      }
    });
    ref.invalidate(qaChecklistProgressProvider);
    ScaffoldMessenger.of(
      context,
    ).showSnackBar(const SnackBar(content: Text('QA checklist reset')));
  }

  @override
  Widget build(BuildContext context) {
    final totalItems = qaChecklistTotalItems;
    final completedItems = _completed.values.where((value) => value).length;
    final progress = totalItems == 0 ? 0.0 : completedItems / totalItems;

    return FeatureScaffold(
      title: 'QA checklist',
      actions: [
        IconButton(
          onPressed: _loading ? null : _resetChecklist,
          tooltip: 'Reset checklist',
          icon: const Icon(Icons.restart_alt),
        ),
      ],
      children: [
        SectionCard(
          title: 'Progress',
          subtitle:
              'Track a QA pass directly on-device and reset it when you start a new round.',
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              LinearProgressIndicator(value: _loading ? null : progress),
              const SizedBox(height: 12),
              Text(
                _loading
                    ? 'Loading checklist...'
                    : '$completedItems of $totalItems checks completed',
              ),
              const SizedBox(height: 12),
              Wrap(
                spacing: 12,
                runSpacing: 12,
                children: [
                  FilledButton.tonal(
                    onPressed: () => context.push('/app/profile/diagnostics'),
                    child: const Text('Open diagnostics'),
                  ),
                  OutlinedButton(
                    onPressed: () => context.push('/app/profile/media-preview'),
                    child: const Text('Open media preview'),
                  ),
                ],
              ),
            ],
          ),
        ),
        if (_loading)
          const SectionCard(
            title: 'Loading checklist',
            child: Center(child: CircularProgressIndicator()),
          )
        else
          for (
            var sectionIndex = 0;
            sectionIndex < qaSections.length;
            sectionIndex++
          )
            SectionCard(
              title: qaSections[sectionIndex].title,
              child: Column(
                children: [
                  for (
                    var itemIndex = 0;
                    itemIndex < qaSections[sectionIndex].items.length;
                    itemIndex++
                  )
                    CheckboxListTile(
                      value:
                          _completed[qaChecklistItemKey(
                            sectionIndex,
                            itemIndex,
                          )] ??
                          false,
                      dense: true,
                      contentPadding: EdgeInsets.zero,
                      controlAffinity: ListTileControlAffinity.leading,
                      title: Text(qaSections[sectionIndex].items[itemIndex]),
                      onChanged: (value) {
                        _toggleItem(sectionIndex, itemIndex, value ?? false);
                      },
                    ),
                ],
              ),
            ),
      ],
    );
  }
}
