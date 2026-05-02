import 'dart:ui';

import 'package:flutter/material.dart';

import 'package:go_router/go_router.dart';

import '../../../app/theme/app_theme.dart';

class AuthShell extends StatelessWidget {
  const AuthShell({
    super.key,
    required this.cardChild,
    this.brandPanel,
    this.maxCardWidth = 440,
    this.onBack,
    this.showBackButton = false,
  });

  final Widget cardChild;
  final Widget? brandPanel;
  final double maxCardWidth;
  final VoidCallback? onBack;
  final bool showBackButton;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final isDark = theme.brightness == Brightness.dark;
    final background = theme.scaffoldBackgroundColor;

    return Scaffold(
      body: LayoutBuilder(
        builder: (context, constraints) {
          final isWide = constraints.maxWidth > 900 && brandPanel != null;
          final topInset = MediaQuery.paddingOf(context).top;
          final bottomInset = MediaQuery.paddingOf(context).bottom;

          return Container(
            decoration: BoxDecoration(
              color: background,
              gradient: RadialGradient(
                center: Alignment.topLeft,
                radius: 1.22,
                colors: [
                  talkflixPrimary.withValues(alpha: 0.18),
                  Colors.transparent,
                ],
                stops: const [0, 0.43],
              ),
            ),
            child: Stack(
              children: [
                Positioned.fill(
                  child: DecoratedBox(
                    decoration: BoxDecoration(
                      gradient: RadialGradient(
                        center: Alignment.bottomRight,
                        radius: 1.12,
                        colors: [
                          talkflixPrimary.withValues(alpha: 0.11),
                          Colors.transparent,
                        ],
                        stops: const [0, 0.38],
                      ),
                    ),
                  ),
                ),
                Center(
                  child: SingleChildScrollView(
                    padding: EdgeInsets.fromLTRB(
                      24,
                      24 + topInset,
                      24,
                      24 + bottomInset,
                    ),
                    child: ConstrainedBox(
                      constraints: BoxConstraints(
                        minHeight:
                            constraints.maxHeight -
                            (48 + topInset + bottomInset),
                        maxWidth: isWide ? 964 : maxCardWidth,
                      ),
                      child: IntrinsicHeight(
                        child: isWide
                            ? Row(
                                crossAxisAlignment: CrossAxisAlignment.center,
                                children: [
                                  Expanded(child: brandPanel!),
                                  const SizedBox(width: 24),
                                  Expanded(
                                    child: Align(
                                      alignment: Alignment.center,
                                      child: _AuthCard(
                                        maxWidth: maxCardWidth,
                                        isDark: isDark,
                                        child: cardChild,
                                      ),
                                    ),
                                  ),
                                ],
                              )
                            : Column(
                                crossAxisAlignment: CrossAxisAlignment.stretch,
                                mainAxisAlignment: MainAxisAlignment.center,
                                children: [
                                  if (brandPanel != null) ...[
                                    brandPanel!,
                                    const SizedBox(height: 24),
                                  ],
                                  Align(
                                    alignment: Alignment.center,
                                    child: _AuthCard(
                                      maxWidth: maxCardWidth,
                                      isDark: isDark,
                                      child: cardChild,
                                    ),
                                  ),
                                ],
                              ),
                      ),
                    ),
                  ),
                ),
                if (showBackButton)
                  Positioned(
                    top: topInset + 12,
                    left: 12,
                    child: IconButton.filledTonal(
                      onPressed: onBack ?? () => context.go('/login'),
                      icon: const Icon(Icons.arrow_back_ios_new_rounded),
                      tooltip: 'Back',
                    ),
                  ),
              ],
            ),
          );
        },
      ),
    );
  }
}

class AuthBrandPanel extends StatelessWidget {
  const AuthBrandPanel({
    super.key,
    required this.title,
    required this.copy,
    this.compact = false,
  });

  final String title;
  final String copy;
  final bool compact;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);

    return Padding(
      padding: EdgeInsets.fromLTRB(compact ? 4 : 24, compact ? 8 : 24, 24, 24),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        mainAxisSize: MainAxisSize.min,
        children: [
          Image.asset(
            'assets/images/talkflix_logo.png',
            width: 90,
            fit: BoxFit.contain,
          ),
          const SizedBox(height: 16),
          Text(
            title,
            style: theme.textTheme.displayMedium?.copyWith(
              fontSize: 48,
              height: 1.05,
              fontWeight: FontWeight.w900,
            ),
          ),
          const SizedBox(height: 16),
          Text(
            copy,
            style: theme.textTheme.bodyLarge?.copyWith(
              height: 1.65,
              color: theme.colorScheme.onSurfaceVariant,
            ),
          ),
        ],
      ),
    );
  }
}

class _AuthCard extends StatelessWidget {
  const _AuthCard({
    required this.child,
    required this.maxWidth,
    required this.isDark,
  });

  final Widget child;
  final double maxWidth;
  final bool isDark;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);

    return ClipRRect(
      borderRadius: BorderRadius.circular(20),
      child: BackdropFilter(
        filter: ImageFilter.blur(sigmaX: 18, sigmaY: 18),
        child: Container(
          width: double.infinity,
          constraints: BoxConstraints(maxWidth: maxWidth),
          padding: const EdgeInsets.all(32),
          decoration: BoxDecoration(
            color: theme.scaffoldBackgroundColor.withValues(alpha: 0.88),
            borderRadius: BorderRadius.circular(20),
            border: Border.all(color: theme.dividerColor),
            boxShadow: [
              BoxShadow(
                color: Colors.black.withValues(alpha: isDark ? 0.28 : 0.12),
                blurRadius: 80,
                offset: const Offset(0, 24),
              ),
            ],
          ),
          child: child,
        ),
      ),
    );
  }
}
