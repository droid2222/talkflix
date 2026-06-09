import 'package:flutter/material.dart';
import 'package:go_router/go_router.dart';

import '../../../app/theme/app_theme.dart';

class PublicHomeScreen extends StatelessWidget {
  const PublicHomeScreen({super.key});

  static const _maxWidth = 1180.0;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return Scaffold(
      backgroundColor: scheme.surface,
      body: const CustomScrollView(
        slivers: [
          SliverToBoxAdapter(child: _HeroSection()),
          SliverToBoxAdapter(child: _ServicesSection()),
          SliverToBoxAdapter(child: _WebAppSection()),
          SliverToBoxAdapter(child: _Footer()),
        ],
      ),
    );
  }
}

class _HeroSection extends StatelessWidget {
  const _HeroSection();

  @override
  Widget build(BuildContext context) {
    return DecoratedBox(
      decoration: const BoxDecoration(
        color: Color(0xFF101113),
        image: DecorationImage(
          image: AssetImage('assets/images/live_room_bg.png'),
          fit: BoxFit.cover,
          opacity: 0.2,
        ),
      ),
      child: DecoratedBox(
        decoration: BoxDecoration(color: Colors.black.withValues(alpha: 0.58)),
        child: SafeArea(
          bottom: false,
          child: Center(
            child: ConstrainedBox(
              constraints: const BoxConstraints(
                maxWidth: PublicHomeScreen._maxWidth,
                minHeight: 660,
              ),
              child: Padding(
                padding: const EdgeInsets.fromLTRB(20, 18, 20, 52),
                child: LayoutBuilder(
                  builder: (context, constraints) {
                    final desktop = constraints.maxWidth >= 900;
                    return Column(
                      crossAxisAlignment: CrossAxisAlignment.stretch,
                      children: [
                        const _TopNav(),
                        SizedBox(height: desktop ? 92 : 58),
                        if (desktop)
                          const Row(
                            crossAxisAlignment: CrossAxisAlignment.center,
                            children: [
                              Expanded(flex: 6, child: _HeroCopy()),
                              SizedBox(width: 56),
                              Expanded(flex: 4, child: _HeroPreview()),
                            ],
                          )
                        else
                          const Column(
                            crossAxisAlignment: CrossAxisAlignment.start,
                            children: [
                              _HeroCopy(),
                              SizedBox(height: 34),
                              _HeroPreview(),
                            ],
                          ),
                        const SizedBox(height: 42),
                        const _HeroPills(),
                      ],
                    );
                  },
                ),
              ),
            ),
          ),
        ),
      ),
    );
  }
}

class _TopNav extends StatelessWidget {
  const _TopNav();

  @override
  Widget build(BuildContext context) {
    return LayoutBuilder(
      builder: (context, constraints) {
        final compact = constraints.maxWidth < 520;
        return Row(
          children: [
            const _BrandMark(size: 44, dark: true),
            const Spacer(),
            if (!compact) ...[
              TextButton(
                onPressed: () => context.go('/login'),
                style: TextButton.styleFrom(foregroundColor: Colors.white),
                child: const Text('Log in'),
              ),
              const SizedBox(width: 8),
            ],
            FilledButton.icon(
              onPressed: () => context.go('/signup'),
              icon: const Icon(Icons.person_add_alt_1_rounded, size: 18),
              label: Text(compact ? 'Join' : 'Create account'),
            ),
          ],
        );
      },
    );
  }
}

class _BrandMark extends StatelessWidget {
  const _BrandMark({required this.size, this.dark = false});

  final double size;
  final bool dark;

  @override
  Widget build(BuildContext context) {
    return Row(
      mainAxisSize: MainAxisSize.min,
      children: [
        Container(
          width: size,
          height: size,
          padding: EdgeInsets.all(size * 0.14),
          decoration: BoxDecoration(
            color: Colors.white,
            borderRadius: BorderRadius.circular(8),
          ),
          child: Image.asset('assets/images/talkflix_logo.png'),
        ),
        const SizedBox(width: 12),
        Text(
          'Talkflix',
          style: TextStyle(
            color: dark
                ? Colors.white
                : Theme.of(context).colorScheme.onSurface,
            fontSize: size * 0.52,
            fontWeight: FontWeight.w900,
          ),
        ),
      ],
    );
  }
}

class _HeroCopy extends StatelessWidget {
  const _HeroCopy();

  @override
  Widget build(BuildContext context) {
    final textTheme = Theme.of(context).textTheme;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(
          'Talkflix',
          style: textTheme.displayLarge?.copyWith(
            color: Colors.white,
            fontSize: 64,
            height: 0.98,
            fontWeight: FontWeight.w900,
          ),
        ),
        const SizedBox(height: 18),
        ConstrainedBox(
          constraints: const BoxConstraints(maxWidth: 660),
          child: Text(
            'Language practice, tutors, paid partners, private coaching, and the Talkflix app experience from one responsive web home.',
            style: textTheme.headlineSmall?.copyWith(
              color: Colors.white.withValues(alpha: 0.9),
              height: 1.22,
              fontWeight: FontWeight.w700,
            ),
          ),
        ),
        const SizedBox(height: 28),
        Wrap(
          spacing: 12,
          runSpacing: 12,
          children: [
            FilledButton.icon(
              onPressed: () => context.go('/login'),
              icon: const Icon(Icons.web_rounded),
              label: const Text('Open web app'),
              style: FilledButton.styleFrom(minimumSize: const Size(168, 52)),
            ),
            OutlinedButton.icon(
              onPressed: () => context.go('/signup'),
              icon: const Icon(Icons.arrow_forward_rounded),
              label: const Text('Get started'),
              style: OutlinedButton.styleFrom(
                minimumSize: const Size(150, 52),
                foregroundColor: Colors.white,
                side: BorderSide(color: Colors.white.withValues(alpha: 0.62)),
              ),
            ),
          ],
        ),
      ],
    );
  }
}

class _HeroPreview extends StatelessWidget {
  const _HeroPreview();

  @override
  Widget build(BuildContext context) {
    return DecoratedBox(
      decoration: BoxDecoration(
        color: Colors.white.withValues(alpha: 0.1),
        border: Border.all(color: Colors.white.withValues(alpha: 0.16)),
        borderRadius: BorderRadius.circular(8),
      ),
      child: const Padding(
        padding: EdgeInsets.all(18),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            _PreviewRow(
              icon: Icons.article_outlined,
              title: 'Blog posts',
              subtitle: 'Learning guides and Talkflix updates.',
            ),
            _PreviewRow(
              icon: Icons.school_outlined,
              title: 'Language tutors',
              subtitle: 'Find help for real speaking progress.',
            ),
            _PreviewRow(
              icon: Icons.handshake_outlined,
              title: 'Paid partners',
              subtitle: 'Book reliable practice conversations.',
            ),
            _PreviewRow(
              icon: Icons.workspace_premium_outlined,
              title: 'Private coaching',
              subtitle: 'Focused support for specific goals.',
            ),
          ],
        ),
      ),
    );
  }
}

class _PreviewRow extends StatelessWidget {
  const _PreviewRow({
    required this.icon,
    required this.title,
    required this.subtitle,
  });

  final IconData icon;
  final String title;
  final String subtitle;

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 10),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Icon(icon, color: Colors.white, size: 24),
          const SizedBox(width: 12),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  title,
                  style: const TextStyle(
                    color: Colors.white,
                    fontWeight: FontWeight.w900,
                  ),
                ),
                const SizedBox(height: 3),
                Text(
                  subtitle,
                  style: TextStyle(
                    color: Colors.white.withValues(alpha: 0.72),
                    height: 1.35,
                  ),
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }
}

class _HeroPills extends StatelessWidget {
  const _HeroPills();

  @override
  Widget build(BuildContext context) {
    return const Wrap(
      spacing: 10,
      runSpacing: 10,
      children: [
        _Pill(label: 'Web app'),
        _Pill(label: 'Language tutors'),
        _Pill(label: 'Paid language partners'),
        _Pill(label: 'Private coaching'),
        _Pill(label: 'Blog posts'),
      ],
    );
  }
}

class _Pill extends StatelessWidget {
  const _Pill({required this.label});

  final String label;

  @override
  Widget build(BuildContext context) {
    return DecoratedBox(
      decoration: BoxDecoration(
        color: Colors.white.withValues(alpha: 0.1),
        border: Border.all(color: Colors.white.withValues(alpha: 0.15)),
        borderRadius: BorderRadius.circular(999),
      ),
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 9),
        child: Text(
          label,
          style: const TextStyle(
            color: Colors.white,
            fontWeight: FontWeight.w800,
          ),
        ),
      ),
    );
  }
}

class _ServicesSection extends StatelessWidget {
  const _ServicesSection();

  @override
  Widget build(BuildContext context) {
    return _SectionBand(
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          const _SectionHeader(
            eyebrow: 'Services',
            title: 'Everything starts from the web home now',
            copy:
                'Visitors can choose the app, learning content, tutor discovery, paid practice, or private coaching without being forced straight into login.',
          ),
          const SizedBox(height: 28),
          LayoutBuilder(
            builder: (context, constraints) {
              final columns = constraints.maxWidth >= 1020
                  ? 3
                  : constraints.maxWidth >= 680
                  ? 2
                  : 1;
              return GridView.count(
                crossAxisCount: columns,
                crossAxisSpacing: 16,
                mainAxisSpacing: 16,
                childAspectRatio: columns == 1 ? 1.55 : 1.08,
                shrinkWrap: true,
                physics: const NeverScrollableScrollPhysics(),
                children: const [
                  _ServiceCard(
                    icon: Icons.article_outlined,
                    title: 'Blog posts',
                    copy:
                        'Publish language guides, cultural notes, product news, and learning stories for visitors before they sign in.',
                    accent: Color(0xFF2D7FF9),
                    action: 'Coming soon',
                  ),
                  _ServiceCard(
                    icon: Icons.school_outlined,
                    title: 'Find language tutors',
                    copy:
                        'A clear path for learners who want structured help with speaking, grammar, exams, or confidence.',
                    accent: Color(0xFF0F9F6E),
                    action: 'Join to request',
                    route: '/signup',
                  ),
                  _ServiceCard(
                    icon: Icons.record_voice_over_outlined,
                    title: 'Become a tutor',
                    copy:
                        'Give qualified speakers a place to offer tutoring and build a profile for future learner matching.',
                    accent: Color(0xFF7C5CFF),
                    action: 'Apply soon',
                  ),
                  _ServiceCard(
                    icon: Icons.handshake_outlined,
                    title: 'Find a paid language partner',
                    copy:
                        'Help learners book dependable conversation practice with partners who are paid to show up.',
                    accent: Color(0xFFE09A22),
                    action: 'Join to request',
                    route: '/signup',
                  ),
                  _ServiceCard(
                    icon: Icons.workspace_premium_outlined,
                    title: 'Private 1-on-1 coaching',
                    copy:
                        'Book a focused private session for clarity, direction, and practical next steps.',
                    accent: Color(0xFFE5484D),
                    action: 'Book coaching',
                    route: '/coaching',
                  ),
                  _ServiceCard(
                    icon: Icons.forum_outlined,
                    title: 'Talkflix web app',
                    copy:
                        'Log in to use Talkiz, Live, Meet, profiles, messages, shared videos, comments, and subtitles.',
                    accent: Color(0xFF394150),
                    action: 'Log in',
                    route: '/login',
                  ),
                ],
              );
            },
          ),
        ],
      ),
    );
  }
}

class _SectionBand extends StatelessWidget {
  const _SectionBand({required this.child, this.tint = false});

  final Widget child;
  final bool tint;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return ColoredBox(
      color: tint
          ? scheme.surfaceContainerHighest.withValues(alpha: 0.45)
          : scheme.surface,
      child: Center(
        child: ConstrainedBox(
          constraints: const BoxConstraints(
            maxWidth: PublicHomeScreen._maxWidth,
          ),
          child: Padding(
            padding: const EdgeInsets.fromLTRB(20, 62, 20, 54),
            child: child,
          ),
        ),
      ),
    );
  }
}

class _SectionHeader extends StatelessWidget {
  const _SectionHeader({
    required this.eyebrow,
    required this.title,
    required this.copy,
  });

  final String eyebrow;
  final String title;
  final String copy;

  @override
  Widget build(BuildContext context) {
    final textTheme = Theme.of(context).textTheme;
    final scheme = Theme.of(context).colorScheme;
    return ConstrainedBox(
      constraints: const BoxConstraints(maxWidth: 760),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(
            eyebrow.toUpperCase(),
            style: textTheme.labelLarge?.copyWith(
              color: talkflixPrimary,
              fontWeight: FontWeight.w900,
            ),
          ),
          const SizedBox(height: 8),
          Text(
            title,
            style: textTheme.displaySmall?.copyWith(
              fontWeight: FontWeight.w900,
              height: 1.08,
            ),
          ),
          const SizedBox(height: 12),
          Text(
            copy,
            style: textTheme.bodyLarge?.copyWith(
              color: scheme.onSurfaceVariant,
              height: 1.55,
            ),
          ),
        ],
      ),
    );
  }
}

class _ServiceCard extends StatelessWidget {
  const _ServiceCard({
    required this.icon,
    required this.title,
    required this.copy,
    required this.accent,
    required this.action,
    this.route,
  });

  final IconData icon;
  final String title;
  final String copy;
  final Color accent;
  final String action;
  final String? route;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return DecoratedBox(
      decoration: BoxDecoration(
        color: scheme.surface,
        border: Border.all(color: scheme.outlineVariant),
        borderRadius: BorderRadius.circular(8),
        boxShadow: [
          BoxShadow(
            color: Colors.black.withValues(alpha: 0.04),
            blurRadius: 18,
            offset: const Offset(0, 10),
          ),
        ],
      ),
      child: Padding(
        padding: const EdgeInsets.all(18),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Container(
              width: 42,
              height: 42,
              decoration: BoxDecoration(
                color: accent.withValues(alpha: 0.12),
                borderRadius: BorderRadius.circular(8),
              ),
              child: Icon(icon, color: accent),
            ),
            const SizedBox(height: 16),
            Text(
              title,
              style: Theme.of(context).textTheme.titleMedium?.copyWith(
                fontWeight: FontWeight.w900,
                height: 1.14,
              ),
            ),
            const SizedBox(height: 8),
            Expanded(
              child: Text(
                copy,
                style: Theme.of(context).textTheme.bodyMedium?.copyWith(
                  color: scheme.onSurfaceVariant,
                  height: 1.42,
                ),
              ),
            ),
            const SizedBox(height: 10),
            Align(
              alignment: Alignment.centerLeft,
              child: TextButton.icon(
                onPressed: route == null ? null : () => context.go(route!),
                icon: Icon(
                  route == null
                      ? Icons.schedule_rounded
                      : Icons.arrow_forward_rounded,
                  size: 18,
                ),
                label: Text(action),
                style: TextButton.styleFrom(
                  foregroundColor: route == null
                      ? scheme.onSurfaceVariant
                      : accent,
                  padding: EdgeInsets.zero,
                  tapTargetSize: MaterialTapTargetSize.shrinkWrap,
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }
}

class _WebAppSection extends StatelessWidget {
  const _WebAppSection();

  @override
  Widget build(BuildContext context) {
    return _SectionBand(
      tint: true,
      child: LayoutBuilder(
        builder: (context, constraints) {
          final desktop = constraints.maxWidth >= 820;
          final content = Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              const _SectionHeader(
                eyebrow: 'App access',
                title: 'The app still works from the browser',
                copy:
                    'The iOS and Android links are not ready yet. Until those links are live, keep the web app as the working entry point for people who need Talkiz, Live, Meet, profiles, messages, subtitles, and shared videos.',
              ),
              const SizedBox(height: 22),
              Wrap(
                spacing: 12,
                runSpacing: 12,
                children: [
                  FilledButton.icon(
                    onPressed: () => context.go('/login'),
                    icon: const Icon(Icons.login_rounded),
                    label: const Text('Log in to web app'),
                  ),
                  OutlinedButton.icon(
                    onPressed: null,
                    icon: const Icon(Icons.phone_iphone_rounded),
                    label: const Text('iOS link coming soon'),
                  ),
                  OutlinedButton.icon(
                    onPressed: null,
                    icon: const Icon(Icons.android_rounded),
                    label: const Text('Android link coming soon'),
                  ),
                ],
              ),
            ],
          );
          final logo = Center(
            child: Container(
              width: desktop ? 224 : 154,
              height: desktop ? 224 : 154,
              padding: const EdgeInsets.all(24),
              decoration: BoxDecoration(
                color: Colors.white,
                border: Border.all(
                  color: Theme.of(context).colorScheme.outlineVariant,
                ),
                borderRadius: BorderRadius.circular(8),
              ),
              child: Image.asset('assets/images/talkflix_logo.png'),
            ),
          );

          if (!desktop) {
            return Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [logo, const SizedBox(height: 28), content],
            );
          }
          return Row(
            children: [
              Expanded(flex: 6, child: content),
              const SizedBox(width: 48),
              Expanded(flex: 4, child: logo),
            ],
          );
        },
      ),
    );
  }
}

class _Footer extends StatelessWidget {
  const _Footer();

  @override
  Widget build(BuildContext context) {
    return ColoredBox(
      color: const Color(0xFF111113),
      child: Center(
        child: ConstrainedBox(
          constraints: const BoxConstraints(
            maxWidth: PublicHomeScreen._maxWidth,
          ),
          child: Padding(
            padding: const EdgeInsets.fromLTRB(20, 28, 20, 28),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                Wrap(
                  spacing: 18,
                  runSpacing: 12,
                  alignment: WrapAlignment.spaceBetween,
                  crossAxisAlignment: WrapCrossAlignment.center,
                  children: [
                    const _BrandMark(size: 32, dark: true),
                    Text(
                      'Language practice, tutors, paid partners, and coaching.',
                      style: TextStyle(
                        color: Colors.white.withValues(alpha: 0.76),
                        fontWeight: FontWeight.w600,
                      ),
                    ),
                  ],
                ),
                const SizedBox(height: 18),
                Wrap(
                  spacing: 18,
                  runSpacing: 10,
                  crossAxisAlignment: WrapCrossAlignment.center,
                  children: [
                    const _FooterLink(
                      label: 'Terms of Service',
                      route: '/terms-of-service',
                    ),
                    const _FooterLink(
                      label: 'Privacy Policy',
                      route: '/privacy-policy',
                    ),
                    const _FooterLink(
                      label: 'Account Deletion',
                      route: '/account-deletion',
                    ),
                    Text(
                      '(c) 2026 Talkflix. All rights reserved.',
                      style: TextStyle(
                        color: Colors.white.withValues(alpha: 0.62),
                        fontWeight: FontWeight.w600,
                      ),
                    ),
                  ],
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}

class _FooterLink extends StatelessWidget {
  const _FooterLink({required this.label, required this.route});

  final String label;
  final String route;

  @override
  Widget build(BuildContext context) {
    return TextButton(
      onPressed: () => context.go(route),
      style: TextButton.styleFrom(
        foregroundColor: Colors.white,
        padding: EdgeInsets.zero,
        tapTargetSize: MaterialTapTargetSize.shrinkWrap,
      ),
      child: Text(label),
    );
  }
}
