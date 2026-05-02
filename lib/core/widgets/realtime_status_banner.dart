import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../realtime/socket_service.dart';

class RealtimeStatusBanner extends ConsumerWidget {
  const RealtimeStatusBanner({
    super.key,
    required this.compactLabel,
    this.showWhenConnected = false,
  });

  final String compactLabel;
  final bool showWhenConnected;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final socket = ref.watch(socketServiceProvider);
    if (!showWhenConnected && socket.isConnected) {
      return const SizedBox.shrink();
    }

    final theme = Theme.of(context);
    final scheme = theme.colorScheme;
    final status = socket.status;

    final (icon, color, message) = switch (status) {
      'connected' => (
        Icons.check_circle_outline,
        Colors.green.shade700,
        '$compactLabel connected',
      ),
      'connecting' => (
        Icons.sync,
        Colors.orange.shade700,
        '$compactLabel connecting...',
      ),
      'error' => (
        Icons.error_outline,
        scheme.error,
        '$compactLabel connection error',
      ),
      _ => (Icons.wifi_off_outlined, scheme.error, '$compactLabel offline'),
    };

    return Container(
      width: double.infinity,
      margin: const EdgeInsets.only(bottom: 16),
      padding: const EdgeInsets.all(12),
      decoration: BoxDecoration(
        color: color.withValues(alpha: 0.10),
        borderRadius: BorderRadius.circular(14),
        border: Border.all(color: color.withValues(alpha: 0.35)),
      ),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Icon(icon, color: color, size: 20),
          const SizedBox(width: 10),
          Expanded(
            child: Text(
              message,
              style: theme.textTheme.bodyMedium?.copyWith(color: color),
            ),
          ),
          TextButton(
            onPressed: () => context.push('/app/profile/diagnostics'),
            child: const Text('Details'),
          ),
        ],
      ),
    );
  }
}
