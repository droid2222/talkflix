import 'package:flutter/material.dart';

import 'status_pill.dart';

class SessionStatusItem {
  const SessionStatusItem({required this.label, required this.value});

  final String label;
  final String value;
}

class SessionStatusBar extends StatelessWidget {
  const SessionStatusBar({
    super.key,
    required this.items,
    this.actions = const [],
    this.padding = const EdgeInsets.symmetric(horizontal: 16, vertical: 10),
    this.backgroundColor,
    this.helperText,
  });

  final List<SessionStatusItem> items;
  final List<Widget> actions;
  final EdgeInsetsGeometry padding;
  final Color? backgroundColor;
  final String? helperText;

  @override
  Widget build(BuildContext context) {
    return Container(
      width: double.infinity,
      padding: padding,
      color: backgroundColor ?? Theme.of(context).colorScheme.surfaceContainer,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Wrap(
            spacing: 8,
            runSpacing: 8,
            crossAxisAlignment: WrapCrossAlignment.center,
            children: [
              ...items.map(
                (item) => StatusPill(text: '${item.label}: ${item.value}'),
              ),
              ...actions,
            ],
          ),
          if (helperText != null) ...[
            const SizedBox(height: 8),
            Text(helperText!, style: Theme.of(context).textTheme.bodySmall),
          ],
        ],
      ),
    );
  }
}
