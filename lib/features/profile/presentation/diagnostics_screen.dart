import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../../../core/auth/session_controller.dart';
import '../../../core/config/app_config.dart';
import '../../../core/network/api_client.dart';
import '../../../core/realtime/socket_service.dart';
import '../../../core/widgets/feature_scaffold.dart';
import 'qa_checklist_data.dart';

class DiagnosticsScreen extends ConsumerStatefulWidget {
  const DiagnosticsScreen({super.key});

  @override
  ConsumerState<DiagnosticsScreen> createState() => _DiagnosticsScreenState();
}

class _DiagnosticsScreenState extends ConsumerState<DiagnosticsScreen> {
  bool _checkingHealth = false;
  bool _refreshingProfile = false;
  String? _healthMessage;
  DateTime? _healthCheckedAt;

  Future<void> _checkBackendHealth() async {
    if (_checkingHealth) return;
    setState(() => _checkingHealth = true);
    try {
      final response = await ref.read(apiClientProvider).getJson('/health');
      final ok = response['ok'] == true;
      final db = response['db'] == true;
      setState(() {
        _healthMessage = ok && db
            ? 'Healthy (API and database look up)'
            : 'Unexpected response: $response';
        _healthCheckedAt = DateTime.now();
      });
    } catch (error) {
      setState(() {
        _healthMessage = 'Health check failed: $error';
        _healthCheckedAt = DateTime.now();
      });
    } finally {
      if (mounted) setState(() => _checkingHealth = false);
    }
  }

  Future<void> _refreshProfile() async {
    if (_refreshingProfile) return;
    setState(() => _refreshingProfile = true);
    try {
      await ref.read(sessionControllerProvider.notifier).refreshProfile();
    } finally {
      if (mounted) setState(() => _refreshingProfile = false);
    }
  }

  Future<void> _copyApiBaseUrl() async {
    await Clipboard.setData(ClipboardData(text: AppConfig.apiBaseUrl));
    if (!mounted) return;
    ScaffoldMessenger.of(
      context,
    ).showSnackBar(const SnackBar(content: Text('API base URL copied')));
  }

  Future<void> _copyUserId(String userId) async {
    await Clipboard.setData(ClipboardData(text: userId));
    if (!mounted) return;
    ScaffoldMessenger.of(
      context,
    ).showSnackBar(const SnackBar(content: Text('User ID copied')));
  }

  Future<void> _resetQaChecklist() async {
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
    ref.invalidate(qaChecklistProgressProvider);
    if (!mounted) return;
    ScaffoldMessenger.of(
      context,
    ).showSnackBar(const SnackBar(content: Text('QA checklist reset')));
  }

  @override
  Widget build(BuildContext context) {
    final session = ref.watch(sessionControllerProvider);
    final socket = ref.watch(socketServiceProvider);
    final qaProgress = ref.watch(qaChecklistProgressProvider);
    final token = session.token ?? '';
    final tokenPreview = token.isEmpty
        ? 'No token'
        : '${token.substring(0, token.length < 12 ? token.length : 12)}...';
    final theme = Theme.of(context);

    return FeatureScaffold(
      title: 'Diagnostics',
      children: [
        SectionCard(
          title: 'Environment',
          subtitle: 'Use this when testing on simulator, emulator, or devices.',
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              _InfoRow(label: 'API base URL', value: AppConfig.apiBaseUrl),
              const SizedBox(height: 12),
              _InfoRow(label: 'Session status', value: session.status.name),
              const SizedBox(height: 12),
              _InfoRow(label: 'Socket status', value: socket.status),
              const SizedBox(height: 12),
              _InfoRow(
                label: 'Socket connected',
                value: socket.isConnected ? 'Yes' : 'No',
              ),
              const SizedBox(height: 12),
              _InfoRow(label: 'Token preview', value: tokenPreview),
              const SizedBox(height: 16),
              Wrap(
                spacing: 12,
                runSpacing: 12,
                children: [
                  OutlinedButton.icon(
                    onPressed: _copyApiBaseUrl,
                    icon: const Icon(Icons.copy_all_outlined),
                    label: const Text('Copy API URL'),
                  ),
                ],
              ),
            ],
          ),
        ),
        SectionCard(
          title: 'Account',
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              _InfoRow(
                label: 'User',
                value: session.user?.displayName ?? 'Not signed in',
              ),
              const SizedBox(height: 12),
              _InfoRow(
                label: 'Email',
                value: session.user?.email ?? 'Unavailable',
              ),
              const SizedBox(height: 12),
              _InfoRow(
                label: 'User ID',
                value: session.user?.id ?? 'Unavailable',
              ),
              const SizedBox(height: 12),
              _InfoRow(
                label: 'Plan',
                value: session.user?.plan ?? 'Unavailable',
              ),
              const SizedBox(height: 16),
              Wrap(
                spacing: 12,
                runSpacing: 12,
                children: [
                  FilledButton.tonalIcon(
                    onPressed: _refreshingProfile ? null : _refreshProfile,
                    icon: const Icon(Icons.refresh),
                    label: Text(
                      _refreshingProfile ? 'Refreshing...' : 'Refresh profile',
                    ),
                  ),
                  OutlinedButton.icon(
                    onPressed: session.user == null
                        ? null
                        : () => _copyUserId(session.user!.id),
                    icon: const Icon(Icons.badge_outlined),
                    label: const Text('Copy user ID'),
                  ),
                ],
              ),
            ],
          ),
        ),
        SectionCard(
          title: 'Realtime controls',
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Wrap(
                spacing: 12,
                runSpacing: 12,
                children: [
                  FilledButton.tonalIcon(
                    onPressed: _checkingHealth ? null : _checkBackendHealth,
                    icon: const Icon(Icons.favorite_border),
                    label: Text(
                      _checkingHealth ? 'Checking...' : 'Check backend health',
                    ),
                  ),
                  FilledButton.tonalIcon(
                    onPressed: session.token == null || session.token!.isEmpty
                        ? null
                        : () => ref
                              .read(socketServiceProvider)
                              .connect(session.token!),
                    icon: const Icon(Icons.wifi_tethering),
                    label: const Text('Reconnect socket'),
                  ),
                  OutlinedButton.icon(
                    onPressed: () =>
                        ref.read(socketServiceProvider).disconnect(),
                    icon: const Icon(Icons.link_off),
                    label: const Text('Disconnect socket'),
                  ),
                ],
              ),
              if (_healthMessage != null) ...[
                const SizedBox(height: 16),
                Container(
                  width: double.infinity,
                  padding: const EdgeInsets.all(12),
                  decoration: BoxDecoration(
                    color: theme.colorScheme.surfaceContainerHighest,
                    borderRadius: BorderRadius.circular(12),
                  ),
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(_healthMessage!, style: theme.textTheme.bodyMedium),
                      if (_healthCheckedAt != null) ...[
                        const SizedBox(height: 6),
                        Text(
                          'Last checked: ${_formatTime(_healthCheckedAt!)}',
                          style: theme.textTheme.bodySmall,
                        ),
                      ],
                    ],
                  ),
                ),
              ],
            ],
          ),
        ),
        SectionCard(
          title: 'QA shortcuts',
          subtitle:
              'Jump directly into the highest-risk product flows and use copied session IDs when comparing devices or logs.',
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              qaProgress.when(
                data: (progress) => Text(
                  'Checklist progress: ${progress.completedCount}/${progress.totalCount}',
                ),
                error: (error, stackTrace) =>
                    const Text('Checklist progress unavailable'),
                loading: () => const Text('Loading checklist progress...'),
              ),
              const SizedBox(height: 12),
              Text(
                'Open media preview before call or live-room testing to verify permissions, local preview, and camera switching.',
                style: theme.textTheme.bodySmall,
              ),
              const SizedBox(height: 12),
              Wrap(
                spacing: 12,
                runSpacing: 12,
                children: [
                  FilledButton.tonal(
                    onPressed: () => context.go('/app/profile/qa-checklist'),
                    child: const Text('Open QA checklist'),
                  ),
                  FilledButton.tonal(
                    onPressed: () => context.go('/app/profile/media-preview'),
                    child: const Text('Open media preview'),
                  ),
                  OutlinedButton(
                    onPressed: _resetQaChecklist,
                    child: const Text('Reset QA checklist'),
                  ),
                  FilledButton.tonal(
                    onPressed: () => context.go('/app/talk'),
                    child: const Text('Open Talk'),
                  ),
                  FilledButton.tonal(
                    onPressed: () => context.go('/app/meet/anon'),
                    child: const Text('Open Anonymous'),
                  ),
                  FilledButton.tonal(
                    onPressed: () => context.go('/app/meet'),
                    child: const Text('Open Meet'),
                  ),
                  FilledButton.tonal(
                    onPressed: () => context.go('/app/live'),
                    child: const Text('Open Live'),
                  ),
                  FilledButton.tonal(
                    onPressed: () => context.go('/app/content'),
                    child: const Text('Open Content'),
                  ),
                ],
              ),
            ],
          ),
        ),
        const SectionCard(
          title: 'Recommended QA flow',
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text('1. Confirm API base URL matches the device setup.'),
              SizedBox(height: 8),
              Text('2. Check backend health before testing realtime features.'),
              SizedBox(height: 8),
              Text('3. Reconnect the socket here if a device drifts offline.'),
              SizedBox(height: 8),
              Text(
                '4. Then test direct chat/calls, anonymous flow, and live rooms.',
              ),
            ],
          ),
        ),
      ],
    );
  }

  String _formatTime(DateTime value) {
    final hour = value.hour.toString().padLeft(2, '0');
    final minute = value.minute.toString().padLeft(2, '0');
    final second = value.second.toString().padLeft(2, '0');
    return '$hour:$minute:$second';
  }
}

class _InfoRow extends StatelessWidget {
  const _InfoRow({required this.label, required this.value});

  final String label;
  final String value;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(label, style: theme.textTheme.labelMedium),
        const SizedBox(height: 4),
        SelectableText(value, style: theme.textTheme.bodyLarge),
      ],
    );
  }
}
