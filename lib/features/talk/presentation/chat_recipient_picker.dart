import 'package:flutter/material.dart';

import '../../../app/theme/app_theme.dart';
import '../../../core/widgets/app_avatar.dart';
import '../data/chat_thread.dart';

Future<List<ChatThread>> showChatRecipientPicker({
  required BuildContext context,
  required List<ChatThread> threads,
  Set<String> excludedPartnerIds = const <String>{},
  String title = 'Forward to',
  String actionLabel = 'Send',
}) {
  final candidates = threads
      .where(
        (thread) =>
            thread.partnerId.trim().isNotEmpty &&
            !excludedPartnerIds.contains(thread.partnerId),
      )
      .toList(growable: false);
  final selectedIds = <String>{};
  var query = '';

  return showModalBottomSheet<List<ChatThread>>(
    context: context,
    isScrollControlled: true,
    backgroundColor: Colors.transparent,
    builder: (sheetContext) {
      return StatefulBuilder(
        builder: (context, setState) {
          final scheme = Theme.of(context).colorScheme;
          final isDark = Theme.of(context).brightness == Brightness.dark;
          final bg = isDark ? const Color(0xFF17181B) : Colors.white;
          final filtered = query.trim().isEmpty
              ? candidates
              : candidates
                    .where((thread) {
                      final haystack = [
                        thread.displayName,
                        thread.username,
                        thread.country,
                      ].join(' ').toLowerCase();
                      return haystack.contains(query.trim().toLowerCase());
                    })
                    .toList(growable: false);

          return SafeArea(
            child: Padding(
              padding: EdgeInsets.only(
                left: 12,
                right: 12,
                bottom: MediaQuery.viewInsetsOf(context).bottom + 12,
              ),
              child: Container(
                constraints: BoxConstraints(
                  maxHeight: MediaQuery.sizeOf(context).height * 0.82,
                ),
                decoration: BoxDecoration(
                  color: bg,
                  borderRadius: BorderRadius.circular(24),
                ),
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    const SizedBox(height: 10),
                    Container(
                      width: 38,
                      height: 4,
                      decoration: BoxDecoration(
                        color: scheme.onSurface.withValues(alpha: 0.18),
                        borderRadius: BorderRadius.circular(2),
                      ),
                    ),
                    Padding(
                      padding: const EdgeInsets.fromLTRB(18, 18, 18, 10),
                      child: Row(
                        children: [
                          Expanded(
                            child: Text(
                              title,
                              style: Theme.of(context).textTheme.titleLarge
                                  ?.copyWith(fontWeight: FontWeight.w800),
                            ),
                          ),
                          TextButton(
                            onPressed: selectedIds.isEmpty
                                ? null
                                : () {
                                    final selected = candidates
                                        .where(
                                          (thread) => selectedIds.contains(
                                            thread.partnerId,
                                          ),
                                        )
                                        .toList(growable: false);
                                    Navigator.of(sheetContext).pop(selected);
                                  },
                            child: Text(actionLabel),
                          ),
                        ],
                      ),
                    ),
                    Padding(
                      padding: const EdgeInsets.fromLTRB(18, 0, 18, 12),
                      child: TextField(
                        autofocus: candidates.length > 8,
                        decoration: InputDecoration(
                          hintText: 'Search chats',
                          prefixIcon: const Icon(Icons.search_rounded),
                          filled: true,
                          fillColor: scheme.surfaceContainerHighest.withValues(
                            alpha: isDark ? 0.35 : 0.6,
                          ),
                          border: OutlineInputBorder(
                            borderRadius: BorderRadius.circular(16),
                            borderSide: BorderSide.none,
                          ),
                          contentPadding: const EdgeInsets.symmetric(
                            horizontal: 14,
                            vertical: 12,
                          ),
                        ),
                        onChanged: (value) => setState(() => query = value),
                      ),
                    ),
                    Flexible(
                      child: candidates.isEmpty
                          ? Padding(
                              padding: const EdgeInsets.fromLTRB(
                                24,
                                26,
                                24,
                                36,
                              ),
                              child: Text(
                                'No recent chats available.',
                                style: Theme.of(context).textTheme.bodyMedium
                                    ?.copyWith(color: scheme.onSurfaceVariant),
                              ),
                            )
                          : ListView.separated(
                              shrinkWrap: true,
                              padding: const EdgeInsets.fromLTRB(10, 0, 10, 14),
                              itemCount: filtered.length,
                              separatorBuilder: (_, _) => Divider(
                                height: 1,
                                color: scheme.outlineVariant,
                              ),
                              itemBuilder: (context, index) {
                                final thread = filtered[index];
                                final selected = selectedIds.contains(
                                  thread.partnerId,
                                );
                                return ListTile(
                                  leading: AppAvatar(
                                    label: thread.displayName,
                                    imageUrl: thread.profilePhotoUrl,
                                    radius: 22,
                                  ),
                                  title: Text(
                                    thread.displayName,
                                    maxLines: 1,
                                    overflow: TextOverflow.ellipsis,
                                    style: const TextStyle(
                                      fontWeight: FontWeight.w700,
                                    ),
                                  ),
                                  subtitle: Text(
                                    thread.username.isNotEmpty
                                        ? '@${thread.username}'
                                        : thread.country,
                                    maxLines: 1,
                                    overflow: TextOverflow.ellipsis,
                                  ),
                                  trailing: Icon(
                                    selected
                                        ? Icons.check_circle_rounded
                                        : Icons.radio_button_unchecked_rounded,
                                    color: selected
                                        ? talkflixPrimary
                                        : scheme.onSurfaceVariant,
                                  ),
                                  onTap: () {
                                    setState(() {
                                      if (selected) {
                                        selectedIds.remove(thread.partnerId);
                                      } else {
                                        selectedIds.add(thread.partnerId);
                                      }
                                    });
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
        },
      );
    },
  ).then((value) => value ?? const <ChatThread>[]);
}
