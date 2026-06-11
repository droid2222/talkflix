import 'package:flutter/material.dart';
import 'package:go_router/go_router.dart';
import 'package:url_launcher/url_launcher.dart';

import '../../../core/config/app_config.dart';
import '../../../core/navigation/public_home_navigation.dart';

class SupportScreen extends StatelessWidget {
  const SupportScreen({super.key});

  Future<void> _openSupportEmail(BuildContext context) async {
    final opened = await launchUrl(AppConfig.supportEmailUri);
    if (!context.mounted || opened) return;
    ScaffoldMessenger.of(context).showSnackBar(
      const SnackBar(content: Text('Could not open your email app.')),
    );
  }

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final textTheme = Theme.of(context).textTheme;
    return Scaffold(
      backgroundColor: scheme.surface,
      appBar: AppBar(
        title: const Text('Talkflix Support'),
        leading: IconButton(
          icon: const Icon(Icons.arrow_back_rounded),
          onPressed: () {
            if (Navigator.of(context).canPop()) {
              context.pop();
            } else {
              openPublicHome(context);
            }
          },
        ),
      ),
      body: SafeArea(
        child: Center(
          child: ConstrainedBox(
            constraints: const BoxConstraints(maxWidth: 920),
            child: ListView(
              padding: const EdgeInsets.fromLTRB(20, 20, 20, 42),
              children: [
                Text(
                  'How can we help?',
                  style: textTheme.headlineMedium?.copyWith(
                    fontWeight: FontWeight.w900,
                    height: 1.08,
                  ),
                ),
                const SizedBox(height: 8),
                Text(
                  'Use this page for Talkflix account, billing, safety, privacy, and app support.',
                  style: textTheme.bodyLarge?.copyWith(
                    color: scheme.onSurfaceVariant,
                    height: 1.45,
                    fontWeight: FontWeight.w600,
                  ),
                ),
                const SizedBox(height: 24),
                _SupportCard(
                  icon: Icons.email_outlined,
                  title: 'Contact support',
                  body:
                      'Email Talkflix for account access, Pro subscription questions, billing help, direct call issues, safety reports, or technical problems. Do not send passwords or payment card details.',
                  action: FilledButton.icon(
                    onPressed: () => _openSupportEmail(context),
                    icon: const Icon(Icons.email_outlined),
                    label: const Text(AppConfig.supportEmail),
                  ),
                ),
                const SizedBox(height: 14),
                _SupportCard(
                  icon: Icons.lock_reset_rounded,
                  title: 'Account access',
                  body:
                      'If you cannot sign in, use password reset from the login screen. If email delivery fails or you no longer control the account email, contact support from an email address you can access.',
                  action: OutlinedButton.icon(
                    onPressed: () => context.go('/forgot-password'),
                    icon: const Icon(Icons.lock_reset_rounded),
                    label: const Text('Reset password'),
                  ),
                ),
                const SizedBox(height: 14),
                _SupportCard(
                  icon: Icons.verified_user_outlined,
                  title: 'Privacy and account deletion',
                  body:
                      'You can review the Privacy Policy or request account deletion. We may need to verify ownership before completing privacy or deletion requests.',
                  action: Wrap(
                    spacing: 10,
                    runSpacing: 8,
                    children: [
                      OutlinedButton.icon(
                        onPressed: () => context.go('/privacy-policy'),
                        icon: const Icon(Icons.privacy_tip_outlined),
                        label: const Text('Privacy Policy'),
                      ),
                      OutlinedButton.icon(
                        onPressed: () =>
                            context.go(AppConfig.accountDeletionPath),
                        icon: const Icon(Icons.delete_outline_rounded),
                        label: const Text('Delete account'),
                      ),
                    ],
                  ),
                ),
                const SizedBox(height: 24),
                const _InfoPanel(
                  title: 'Before contacting us',
                  items: [
                    'Include your Talkflix username and the email address on your account, if known.',
                    'Describe the device, platform, app version, and the exact issue you are seeing.',
                    'For purchase issues, include the plan name and purchase platform, but never send payment card details.',
                    'For safety reports, include the username involved and a concise description of what happened.',
                  ],
                ),
                const SizedBox(height: 14),
                _InfoPanel(
                  title: 'Legal links',
                  items: const [
                    'Terms of Service and Privacy Policy explain how Talkflix operates, handles paid features, and manages privacy requests.',
                  ],
                  footer: Wrap(
                    spacing: 10,
                    runSpacing: 8,
                    children: [
                      TextButton.icon(
                        onPressed: () => context.go('/terms-of-service'),
                        icon: const Icon(Icons.description_outlined),
                        label: const Text('Terms of Service'),
                      ),
                      TextButton.icon(
                        onPressed: () => context.go('/privacy-policy'),
                        icon: const Icon(Icons.privacy_tip_outlined),
                        label: const Text('Privacy Policy'),
                      ),
                    ],
                  ),
                ),
                const SizedBox(height: 24),
                Text(
                  '(c) 2026 Talkflix. All rights reserved.',
                  style: textTheme.bodyMedium?.copyWith(
                    color: scheme.onSurfaceVariant,
                    fontWeight: FontWeight.w700,
                  ),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}

class _SupportCard extends StatelessWidget {
  const _SupportCard({
    required this.icon,
    required this.title,
    required this.body,
    required this.action,
  });

  final IconData icon;
  final String title;
  final String body;
  final Widget action;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return DecoratedBox(
      decoration: BoxDecoration(
        color: scheme.surfaceContainerHigh,
        borderRadius: BorderRadius.circular(24),
        border: Border.all(color: scheme.outlineVariant),
      ),
      child: Padding(
        padding: const EdgeInsets.all(18),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Icon(icon, color: scheme.primary, size: 30),
            const SizedBox(height: 12),
            Text(
              title,
              style: Theme.of(
                context,
              ).textTheme.titleLarge?.copyWith(fontWeight: FontWeight.w900),
            ),
            const SizedBox(height: 8),
            Text(
              body,
              style: Theme.of(context).textTheme.bodyLarge?.copyWith(
                height: 1.5,
                color: scheme.onSurfaceVariant,
              ),
            ),
            const SizedBox(height: 16),
            action,
          ],
        ),
      ),
    );
  }
}

class _InfoPanel extends StatelessWidget {
  const _InfoPanel({required this.title, required this.items, this.footer});

  final String title;
  final List<String> items;
  final Widget? footer;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return DecoratedBox(
      decoration: BoxDecoration(
        color: scheme.surfaceContainerHighest,
        borderRadius: BorderRadius.circular(24),
        border: Border.all(color: scheme.outlineVariant),
      ),
      child: Padding(
        padding: const EdgeInsets.all(18),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(
              title,
              style: Theme.of(
                context,
              ).textTheme.titleMedium?.copyWith(fontWeight: FontWeight.w900),
            ),
            const SizedBox(height: 10),
            for (final item in items) ...[
              Row(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Padding(
                    padding: const EdgeInsets.only(top: 8),
                    child: Icon(
                      Icons.circle,
                      size: 6,
                      color: scheme.onSurfaceVariant,
                    ),
                  ),
                  const SizedBox(width: 10),
                  Expanded(
                    child: Text(
                      item,
                      style: Theme.of(context).textTheme.bodyLarge?.copyWith(
                        height: 1.5,
                        color: scheme.onSurfaceVariant,
                      ),
                    ),
                  ),
                ],
              ),
              const SizedBox(height: 8),
            ],
            if (footer != null) ...[const SizedBox(height: 8), footer!],
          ],
        ),
      ),
    );
  }
}
