import 'package:flutter/material.dart';

class RealtimeWarningBanner extends StatelessWidget {
  const RealtimeWarningBanner({
    super.key,
    required this.status,
    required this.scopeLabel,
    this.connectingMessage,
    this.margin,
  });

  final String status;
  final String scopeLabel;
  final String? connectingMessage;
  final EdgeInsetsGeometry? margin;

  @override
  Widget build(BuildContext context) {
    final message = switch (status) {
      'connecting' => connectingMessage ?? 'Reconnecting to $scopeLabel...',
      'error' => '$scopeLabel connection error. Check the backend and network.',
      'disconnected' => '$scopeLabel disconnected. Trying to recover...',
      _ => 'Realtime status: $status',
    };

    return Container(
      width: double.infinity,
      margin: margin,
      padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 12),
      decoration: BoxDecoration(
        color: Theme.of(context).colorScheme.surfaceContainerHighest,
        borderRadius: BorderRadius.circular(16),
      ),
      child: Row(
        children: [
          const Icon(Icons.wifi_tethering_error_rounded),
          const SizedBox(width: 10),
          Expanded(child: Text(message)),
        ],
      ),
    );
  }
}
