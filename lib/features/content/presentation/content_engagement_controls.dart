import 'dart:async';

import 'package:flutter/material.dart';

import '../../../core/formatters/compact_count_formatter.dart';

String compactEngagementCount(int count) {
  return compactCount(count);
}

class ContentEngagementControls extends StatelessWidget {
  const ContentEngagementControls({
    super.key,
    required this.likedByMe,
    required this.likeCount,
    required this.commentCount,
    required this.viewCount,
    required this.likeBusy,
    required this.saved,
    required this.onLike,
    required this.onComments,
    required this.onShare,
    required this.onSave,
  });

  final bool likedByMe;
  final int likeCount;
  final int commentCount;
  final int viewCount;
  final bool likeBusy;
  final bool saved;
  final VoidCallback onLike;
  final VoidCallback onComments;
  final Future<void> Function(BuildContext context) onShare;
  final VoidCallback onSave;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Row(
          children: [
            _EngagementActionButton(
              icon: likedByMe
                  ? Icons.favorite_rounded
                  : Icons.favorite_border_rounded,
              activeColor: Colors.redAccent,
              active: likedByMe,
              disabled: likeBusy,
              onTap: onLike,
            ),
            Text(
              compactEngagementCount(likeCount),
              style: Theme.of(
                context,
              ).textTheme.labelLarge?.copyWith(fontWeight: FontWeight.w700),
            ),
            const SizedBox(width: 14),
            _EngagementActionButton(
              icon: Icons.mode_comment_outlined,
              onTap: onComments,
            ),
            Text(
              compactEngagementCount(commentCount),
              style: Theme.of(
                context,
              ).textTheme.labelLarge?.copyWith(fontWeight: FontWeight.w700),
            ),
            const SizedBox(width: 14),
            Builder(
              builder: (buttonContext) => _EngagementActionButton(
                icon: Icons.share_outlined,
                onTap: () => unawaited(onShare(buttonContext)),
              ),
            ),
            const Spacer(),
            _EngagementActionButton(
              icon: saved
                  ? Icons.bookmark_rounded
                  : Icons.bookmark_border_rounded,
              active: saved,
              onTap: onSave,
            ),
          ],
        ),
        const SizedBox(height: 8),
        Text(
          '${compactEngagementCount(viewCount)} views',
          style: Theme.of(context).textTheme.bodySmall?.copyWith(
            color: scheme.onSurfaceVariant,
            fontWeight: FontWeight.w700,
          ),
        ),
        if (commentCount > 0) ...[
          const SizedBox(height: 6),
          GestureDetector(
            onTap: onComments,
            child: Text(
              commentCount == 1
                  ? 'View 1 comment'
                  : 'View all $commentCount comments',
              style: Theme.of(context).textTheme.bodySmall?.copyWith(
                color: scheme.onSurfaceVariant,
                fontWeight: FontWeight.w600,
              ),
            ),
          ),
        ],
      ],
    );
  }
}

class _EngagementActionButton extends StatelessWidget {
  const _EngagementActionButton({
    required this.icon,
    required this.onTap,
    this.active = false,
    this.disabled = false,
    this.activeColor,
  });

  final IconData icon;
  final VoidCallback onTap;
  final bool active;
  final bool disabled;
  final Color? activeColor;

  @override
  Widget build(BuildContext context) {
    final color = active
        ? (activeColor ?? Theme.of(context).colorScheme.primary)
        : null;
    return IconButton(
      onPressed: disabled ? null : onTap,
      visualDensity: VisualDensity.compact,
      icon: Icon(icon, color: color),
    );
  }
}
