import 'package:flutter/material.dart';

import '../../app/theme/app_theme.dart';

class TalkflixProBadge extends StatelessWidget {
  const TalkflixProBadge({super.key, this.compact = false});

  final bool compact;

  @override
  Widget build(BuildContext context) {
    final horizontalPadding = compact ? 10.0 : 13.0;
    final verticalPadding = compact ? 5.0 : 7.0;
    final radius = compact ? 999.0 : 999.0;
    final fontSize = compact ? 11.0 : 12.0;
    final letterSpacing = compact ? 0.7 : 0.9;

    return DecoratedBox(
      decoration: BoxDecoration(
        gradient: talkflixProGradient,
        borderRadius: BorderRadius.circular(radius),
        border: Border.all(color: Colors.white.withValues(alpha: 0.34)),
        boxShadow: [
          BoxShadow(
            color: const Color(0xFF2B6CFF).withValues(alpha: 0.20),
            blurRadius: compact ? 10 : 14,
            offset: const Offset(0, 6),
          ),
        ],
      ),
      child: Padding(
        padding: EdgeInsets.symmetric(
          horizontal: horizontalPadding,
          vertical: verticalPadding,
        ),
        child: Text(
          'PRO',
          style: Theme.of(context).textTheme.labelMedium?.copyWith(
            color: Colors.white,
            fontWeight: FontWeight.w900,
            fontSize: fontSize,
            letterSpacing: letterSpacing,
          ),
        ),
      ),
    );
  }
}
